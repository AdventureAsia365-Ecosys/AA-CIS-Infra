-- Migration crm-026: AA-967 CRM-35 Module 18 portability + deletion (design v3 §4.10, Fix B16, spec module 18, Q 3.7,
-- errata S247 "data-request log") — the agency's portability exports (a whole-agency or one-client export as a crm.job
-- with progress, a ZIP of JSON + CSV per table, the documents and their manifest, a schema version and SHA-256
-- checksums, sealed under the agency export DEK, owner download through a short-lived single-use link), the agency's
-- data-request log (requests its clients make: received, kind, due date, closed), and the cool-off window between the
-- owner's typed confirmation of an agency deletion and the erase.
--
-- Owner: AA-Partner (api/migrations/026_crm_portability_requests.sql). AA-CIS-Infra db/migrations/crm/ holds the byte
-- copy DB Migrate applies (Migration Copy Guard). Key crm-026. crm.erase_subject below is the crm-025 text with two
-- names added to its keep list (item 4); a later key that replaces it starts from THIS text. crm.erase_held,
-- crm.lifecycle_purge_expired and crm.trip_delete_blockers are unchanged.
--
-- What (DM-7: root data standards Part B §7, the "kept: audit evidence and erasure receipts" row, which already names
-- crm.export_job and gains crm.data_request in the root PR merged before the Infra copy):
--   1. crm.export_job (base template): one portability export of the agency (scope tenant, subject = the agency) or of
--      one client (scope traveler, subject = the traveller id, no foreign key: the row outlives the client's erasure).
--      queued -> building -> ready -> expired | cancelled, or failed; progress_done / progress_total while building;
--      the sealed object exports/tenants/<tenant>/portability/<export>.zip.enc (the 7-day exports/ bucket rule), its
--      SHA-256 (object_sha256) and the SHA-256 of the ZIP the owner downloads (content_sha256, the checksum the page
--      shows), size, per-table row counts, documents included / skipped, expires_at (7 days). The download link:
--      link_sha256 = SHA-256 of a random token, link_expires_at (minutes); only a ready export carries one; the
--      download clears it (single use). One open (queued / building) export per scope and subject. Ids, codes, counts,
--      hashes and times only: no personal data, so the row is kept like an erasure receipt (agency erase keep list).
--   2. crm.data_request (base template): the agency's log of the data requests its clients make (errata S247: received,
--      type, due date, done). kind access | portability | erasure | rectification | restriction | objection | other;
--      channel email | phone | in_person | post | client_portal | aa_forwarded | other; the client (traveler_id, no
--      foreign key: the log entry outlives the erasure it records); received_on, due_on (at most 92 days after
--      receipt: one month, extendable by two, GDPR art. 12(3)); open -> extended -> done | refused | withdrawn with an
--      outcome code and closed_at / closed_by; the export and the erasure receipt that answered it. No free text, so no
--      personal data beyond the client id: kept like the erasure receipts.
--   3. crm.erasure_request + erase_not_before (the cool-off: the agency erase job does not start before it; set with
--      confirmed_by only), verified_at (when the post-erase verification passed: rows gone, keys destroyed, a sealed
--      canary unreadable), UNIQUE (tenant_id, request_id) for the same-agency key from crm.data_request.
--   4. crm.erase_subject (the crm-025 text): the agency keep list + export_job, data_request (the offboarding code deletes
--      the export objects before the erase; the rows hold no personal data). No scope changes.
--   5. RLS (ENABLE + FORCE, tenant_isolation TO the CRM roles), crm_app SELECT + INSERT + UPDATE (no DELETE, no
--      TRUNCATE), no reader grant (AA support and the AI readers never see either table); status moves in
--      crm.status_transition.
--   SQLSTATE: none new (CRM41 stays the next key).
--
-- Class: contract (ADR 0017 §3: a replaced crm.erase_subject, new constraints on crm.erasure_request), so no
-- `-- migrate: expand` header: MIG-4 order, this file's PR first, the Infra copy, a manual DB Migrate apply, then the
-- code PR (adds crm-026 to REQUIRED_SCHEMA_VERSIONS).
--
-- Order: after crm-025 (AA-955 e-sign v1); Guard 0 refuses to run before it is registered (erase_subject builds on its
-- text).
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL. Idempotent (IF NOT EXISTS, DROP …
-- IF EXISTS, CREATE OR REPLACE, ON CONFLICT DO NOTHING). Rollback: a forward crm- file (MIG-14); the code before AA-967
-- never reads the new tables or columns, and the new keep-list names only matter once rows exist, so it runs
-- unchanged on this schema.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '15min';

-- ── Guard 0: runs as the owner, after crm-025 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-026: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-025') THEN
        RAISE EXCEPTION 'crm-026: crm-025 (AA-955 e-sign v1) lands first';
    END IF;
    IF to_regclass('crm.erasure_request') IS NULL OR to_regclass('crm.signature_event') IS NULL
       OR to_regprocedure('crm.erase_rows(text,text,uuid,uuid,boolean,text)') IS NULL
       OR to_regprocedure('crm.enforce_status_transition()') IS NULL
       OR to_regprocedure('crm.set_updated_at()') IS NULL
       OR position('signature_event_kept' IN (SELECT prosrc FROM pg_catalog.pg_proc
                    WHERE oid = 'crm.erase_subject(text,uuid,uuid,boolean)'::regprocedure)) = 0 THEN
        RAISE EXCEPTION 'crm-026: crm.erasure_request (crm-010), crm.signature_event or the crm-025 erase_subject text missing';
    END IF;
END $$;

-- ── 3a. crm.erasure_request: the same-agency key ─────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint WHERE conrelid = 'crm.erasure_request'::regclass
                    AND conname = 'erasure_request_tenant_id_uq') THEN
        ALTER TABLE crm.erasure_request ADD CONSTRAINT erasure_request_tenant_id_uq UNIQUE (tenant_id, request_id);
    END IF;
END $$;

-- ── 2. crm.data_request ──────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.data_request (
    data_request_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                        REFERENCES crm.tenant (tenant_id),
    kind                TEXT NOT NULL,
    channel             TEXT NOT NULL,
    traveler_id         UUID,
    received_on         DATE NOT NULL,
    due_on              DATE NOT NULL,
    status              TEXT NOT NULL DEFAULT 'open',
    outcome             TEXT,
    closed_at           TIMESTAMPTZ,
    closed_by           TEXT,
    erasure_request_id  UUID,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by          TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at          TIMESTAMPTZ,
    deleted_by          TEXT,
    purge_after         TIMESTAMPTZ,
    CONSTRAINT data_request_tenant_id_uq UNIQUE (tenant_id, data_request_id),
    CONSTRAINT data_request_erasure_fk FOREIGN KEY (tenant_id, erasure_request_id)
        REFERENCES crm.erasure_request (tenant_id, request_id),
    CONSTRAINT data_request_kind_chk CHECK (
        kind IN ('access', 'portability', 'erasure', 'rectification', 'restriction', 'objection', 'other')
    ),
    CONSTRAINT data_request_channel_chk CHECK (
        channel IN ('email', 'phone', 'in_person', 'post', 'client_portal', 'aa_forwarded', 'other')
    ),
    CONSTRAINT data_request_due_chk CHECK (due_on >= received_on AND due_on <= received_on + 92),
    CONSTRAINT data_request_status_chk CHECK (status IN ('open', 'extended', 'done', 'refused', 'withdrawn')),
    CONSTRAINT data_request_closed_chk CHECK (
        (status IN ('done', 'refused', 'withdrawn')) = (closed_at IS NOT NULL)
        AND (closed_at IS NULL) = (closed_by IS NULL)
        AND (closed_at IS NULL) = (outcome IS NULL)
        AND (closed_by IS NULL OR closed_by ~ '^[A-Za-z0-9:_-]{1,80}$')
    ),
    CONSTRAINT data_request_outcome_chk CHECK (
        outcome IS NULL
        OR (status = 'done' AND outcome IN ('fulfilled', 'partly_fulfilled', 'no_data'))
        OR (status = 'refused' AND outcome IN ('identity_not_verified', 'exempt', 'manifestly_unfounded'))
        OR (status = 'withdrawn' AND outcome = 'withdrawn_by_subject')
    ),
    CONSTRAINT data_request_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE INDEX IF NOT EXISTS data_request_open_idx ON crm.data_request (tenant_id, due_on)
    WHERE status IN ('open', 'extended');
CREATE INDEX IF NOT EXISTS data_request_traveler_idx ON crm.data_request (tenant_id, traveler_id)
    WHERE traveler_id IS NOT NULL;
COMMENT ON TABLE crm.data_request IS 'AA-967 (crm-026; errata S247 CRM-35 "data-request log", design v3 §4.10, Q 3.7): the agency''s log of the data requests its clients make (the agency is the controller; AA forwards what it receives). kind access | portability | erasure | rectification | restriction | objection | other; channel; the client (traveler_id, no foreign key: the entry outlives the erasure it records); received_on, due_on (<= received_on + 92 days: one month, extendable by two); open -> extended -> done | refused | withdrawn with an outcome code; the erasure receipt that answered it (an export names its request on crm.export_job). No free text, no personal data beyond the client id: kept like the erasure receipts (agency erase keep list). Owner only (the API)';
COMMENT ON COLUMN crm.data_request.traveler_id IS 'AA-967 (crm-026): the client the request is about, when the agency knows them (NULL: not in the CRM, or not identified yet). No foreign key: after the client''s erasure the id names nothing and the entry stays as the record that the request was answered';
COMMENT ON COLUMN crm.data_request.due_on IS 'AA-967 (crm-026): the reply deadline; the API defaults it to received_on + 30 days and an extension moves it up to received_on + 92 days (GDPR art. 12(3); the agency''s own law may be stricter)';

-- ── 1. crm.export_job ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.export_job (
    export_job_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                        REFERENCES crm.tenant (tenant_id),
    scope               TEXT NOT NULL,
    subject_id          UUID NOT NULL,
    status              TEXT NOT NULL DEFAULT 'queued',
    schema_version      SMALLINT NOT NULL DEFAULT 1,
    progress_done       INTEGER NOT NULL DEFAULT 0,
    progress_total      INTEGER NOT NULL DEFAULT 0,
    object_key          TEXT,
    object_sha256       TEXT,
    content_sha256      TEXT,
    size_bytes          BIGINT,
    row_counts          JSONB NOT NULL DEFAULT '{}'::jsonb,
    documents_included  INTEGER NOT NULL DEFAULT 0,
    documents_skipped   INTEGER NOT NULL DEFAULT 0,
    completed_at        TIMESTAMPTZ,
    expires_at          TIMESTAMPTZ,
    downloaded_at       TIMESTAMPTZ,
    download_count      INTEGER NOT NULL DEFAULT 0,
    link_sha256         BYTEA,
    link_expires_at     TIMESTAMPTZ,
    failure_class       TEXT,
    data_request_id     UUID,
    requested_by        TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by          TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at          TIMESTAMPTZ,
    deleted_by          TEXT,
    purge_after         TIMESTAMPTZ,
    CONSTRAINT export_job_tenant_id_uq UNIQUE (tenant_id, export_job_id),
    CONSTRAINT export_job_data_request_fk FOREIGN KEY (tenant_id, data_request_id)
        REFERENCES crm.data_request (tenant_id, data_request_id),
    CONSTRAINT export_job_scope_chk CHECK (
        scope IN ('tenant', 'traveler') AND (scope <> 'tenant' OR subject_id = tenant_id)
    ),
    CONSTRAINT export_job_status_chk CHECK (
        status IN ('queued', 'building', 'ready', 'failed', 'cancelled', 'expired')
    ),
    CONSTRAINT export_job_version_chk CHECK (schema_version BETWEEN 1 AND 99),
    CONSTRAINT export_job_progress_chk CHECK (
        progress_done >= 0 AND progress_total >= 0 AND progress_done <= progress_total
        AND documents_included >= 0 AND documents_skipped >= 0 AND download_count >= 0
    ),
    CONSTRAINT export_job_object_chk CHECK (
        (object_key IS NULL) = (object_sha256 IS NULL)
        AND (object_key IS NULL OR object_key ~ '^exports/tenants/[0-9a-f-]{36}/portability/[0-9a-f-]{36}\.zip\.enc$')
        AND (object_sha256 IS NULL OR object_sha256 ~ '^[0-9a-f]{64}$')
        AND (content_sha256 IS NULL OR content_sha256 ~ '^[0-9a-f]{64}$')
        AND (size_bytes IS NULL OR size_bytes >= 0)
    ),
    CONSTRAINT export_job_ready_chk CHECK (
        status <> 'ready'
        OR (object_key IS NOT NULL AND content_sha256 IS NOT NULL AND size_bytes IS NOT NULL
            AND completed_at IS NOT NULL AND expires_at IS NOT NULL)
    ),
    CONSTRAINT export_job_open_chk CHECK (
        status NOT IN ('queued', 'building') OR (object_key IS NULL AND completed_at IS NULL)
    ),
    CONSTRAINT export_job_link_chk CHECK (
        (link_sha256 IS NULL) = (link_expires_at IS NULL)
        AND (link_sha256 IS NULL OR (octet_length(link_sha256) = 32 AND status = 'ready'))
    ),
    CONSTRAINT export_job_counts_chk CHECK (
        jsonb_typeof(row_counts) = 'object' AND octet_length(row_counts::text) <= 8192
    ),
    CONSTRAINT export_job_failure_chk CHECK (
        (status <> 'failed' OR failure_class IS NOT NULL)
        AND (failure_class IS NULL OR failure_class ~ '^[A-Za-z][A-Za-z0-9_:]{0,63}$')
    ),
    CONSTRAINT export_job_actor_chk CHECK (requested_by ~ '^[A-Za-z0-9:_-]{1,80}$'),
    CONSTRAINT export_job_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS export_job_open_uq ON crm.export_job (tenant_id, scope, subject_id)
    WHERE status IN ('queued', 'building');
CREATE INDEX IF NOT EXISTS export_job_created_idx ON crm.export_job (tenant_id, created_at DESC);
COMMENT ON TABLE crm.export_job IS 'AA-967 (crm-026; design v3 §4.10 "Export", module 18, group J export_job): one portability export of the agency (scope tenant, subject = the agency) or of one client (scope traveler; no foreign key, the row outlives the erasure), built by a crm_data_export job. queued -> building (progress_done / progress_total) -> ready (the ZIP: manifest.json with schema_version, JSON + CSV per table, documents/manifest.csv and the files, SHA256SUMS; sealed under the agency export DEK at object_key, 7-day bucket rule, expires_at) -> expired | cancelled; or failed (failure_class). content_sha256 = SHA-256 of the ZIP the owner downloads. The download link: link_sha256 / link_expires_at (a random token''s SHA-256, minutes; single use, owner only, audited). Ids, codes, counts, hashes and times only: kept like an erasure receipt (agency erase keep list; the offboarding code deletes the objects)';
COMMENT ON COLUMN crm.export_job.content_sha256 IS 'AA-967 (crm-026): SHA-256 (hex) of the ZIP exactly as downloaded: the checksum the Settings page shows so the owner can check the file';
COMMENT ON COLUMN crm.export_job.link_sha256 IS 'AA-967 (crm-026): SHA-256 of the short-lived download link token (the token is shown once to the owner who asked for the link, never stored); cleared by the download (single use) or replaced by a new link';

-- ── 3b. crm.erasure_request: the cool-off and the verification ──────────────────────────────────
ALTER TABLE crm.erasure_request
    ADD COLUMN IF NOT EXISTS erase_not_before TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS verified_at TIMESTAMPTZ;
ALTER TABLE crm.erasure_request DROP CONSTRAINT IF EXISTS erasure_request_cool_off_chk;
ALTER TABLE crm.erasure_request ADD CONSTRAINT erasure_request_cool_off_chk CHECK (
    (erase_not_before IS NULL OR confirmed_by IS NOT NULL) AND (verified_at IS NULL OR status = 'erased')
);
COMMENT ON COLUMN crm.erasure_request.erase_not_before IS 'AA-967 (crm-026): the end of the cool-off of an agency deletion: the owner''s typed confirmation sets it (with confirmed_by) and queues the erase job for that time; until then the agency works as before and the owner may cancel. NULL = no cool-off (a request confirmed before AA-967, or a traveller erasure)';
COMMENT ON COLUMN crm.erasure_request.verified_at IS 'AA-967 (crm-026): when the post-erase verification passed (agency scope: no row left, every DEK destroyed, a canary sealed before the destroy no longer opens; traveller scope: the subject is gone). The receipt holds the details';

-- ── 5. Status moves, RLS, grants, triggers ───────────────────────────────────────────────────────
INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('export_job', 'queued', 'building'),
    ('export_job', 'queued', 'failed'),
    ('export_job', 'queued', 'cancelled'),
    ('export_job', 'building', 'ready'),
    ('export_job', 'building', 'failed'),
    ('export_job', 'building', 'cancelled'),
    ('export_job', 'ready', 'expired'),
    ('export_job', 'ready', 'cancelled'),
    ('data_request', 'open', 'extended'),
    ('data_request', 'open', 'done'),
    ('data_request', 'open', 'refused'),
    ('data_request', 'open', 'withdrawn'),
    ('data_request', 'extended', 'done'),
    ('data_request', 'extended', 'refused'),
    ('data_request', 'extended', 'withdrawn')
ON CONFLICT DO NOTHING;

DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['data_request', 'export_job'] LOOP
        EXECUTE format('ALTER TABLE crm.%I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE crm.%I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON crm.%I', t);
        EXECUTE format(
            'CREATE POLICY tenant_isolation ON crm.%I '
            'TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser '
            'USING (tenant_id = NULLIF(current_setting(''app.tenant_id'', true), '''')::uuid) '
            'WITH CHECK (tenant_id = NULLIF(current_setting(''app.tenant_id'', true), '''')::uuid)', t);
        EXECUTE format(
            'CREATE OR REPLACE TRIGGER %I BEFORE UPDATE ON crm.%I FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at()',
            t || '_set_updated_at', t);
        EXECUTE format(
            'CREATE OR REPLACE TRIGGER %I BEFORE UPDATE OF status ON crm.%I '
            'FOR EACH ROW EXECUTE FUNCTION crm.enforce_status_transition()', t || '_status_transition', t);
        -- crm_app reads and writes; it never deletes or truncates (receipts). No reader role is granted anything.
        EXECUTE format('REVOKE DELETE, TRUNCATE ON crm.%I FROM crm_app', t);
        EXECUTE format('GRANT SELECT, INSERT, UPDATE ON crm.%I TO crm_app', t);
    END LOOP;
END $$;

-- ── 4. crm.erase_subject: the crm-025 text, keep list + export_job, data_request ─────────────────
CREATE OR REPLACE FUNCTION crm.erase_subject(p_scope text, p_subject uuid, p_profile_token uuid DEFAULT NULL,
                                             p_dry_run boolean DEFAULT true) RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_tenant uuid := NULLIF(current_setting('app.tenant_id', true), '')::uuid;
    v_actor text := COALESCE(current_setting('app.actor', true), '');
    v_counts jsonb := '{}'::jsonb;
    v_blockers text[];
    v_status text;
    v_has_token boolean;
    v_step text[];
    v_left text[] := '{}';
    r record;
    -- Tables an agency erase keeps: the agency row (status offboarded), the destroyed key rows, the audit and its
    -- export registry and chain (crm-007: they leave with the partition drops / the archive), the erasure receipts,
    -- the lifecycle counts and the holds (ids and codes only), and (crm-026, AA-967) the portability export records
    -- and the data-request log (ids, codes, hashes and dates only; the offboarding code deletes the export objects).
    c_keep CONSTANT text[] := ARRAY['tenant', 'tenant_key', 'audit_event', 'audit_export_tenant',
                                    'audit_export_manifest', 'erasure_request', 'lifecycle_run', 'legal_hold',
                                    'export_job', 'data_request'];
BEGIN
    IF v_tenant IS NULL THEN
        RAISE EXCEPTION 'crm: erase_subject needs app.tenant_id' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF p_dry_run IS NULL OR p_subject IS NULL THEN
        RAISE EXCEPTION 'crm: erase_subject needs a subject and dry_run true or false'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF p_scope NOT IN ('trip', 'traveler', 'task', 'note', 'document', 'relation', 'booking_line', 'agency_supplier',
                       'conversation', 'tenant') THEN
        RAISE EXCEPTION 'crm: erase_subject scope % is unknown', p_scope USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- Hold rule 4g: serialise with hold placement. SHARE conflicts with the ROW EXCLUSIVE of an INSERT / UPDATE on
    -- crm.legal_hold: a hold placed now waits until this transaction ends; a hold being placed makes this wait, then
    -- the check below (a new snapshot: this function is VOLATILE) sees it.
    LOCK TABLE crm.legal_hold IN SHARE MODE;

    -- The subject must exist in this agency (FORCE RLS: crm_owner sees app.tenant_id's rows only).
    IF p_scope = 'trip' THEN
        -- FOR UPDATE: a row that would reference the subject (FOR KEY SHARE of its foreign key) waits until this erase
        -- ends, so nothing is attached to it between the hold check and the deletes (the hold guard triggers catch
        -- any other change).
        PERFORM 1 FROM crm.trip WHERE trip_id = p_subject FOR UPDATE;
    ELSIF p_scope = 'traveler' THEN
        SELECT profile_token_enc IS NOT NULL INTO v_has_token FROM crm.traveler WHERE traveler_id = p_subject
           FOR UPDATE;
    ELSIF p_scope = 'task' THEN
        PERFORM 1 FROM crm.task WHERE task_id = p_subject;
    ELSIF p_scope = 'note' THEN
        PERFORM 1 FROM crm.note WHERE note_id = p_subject;
    ELSIF p_scope = 'document' THEN
        PERFORM 1 FROM crm.document WHERE document_id = p_subject;
    ELSIF p_scope = 'relation' THEN
        PERFORM 1 FROM crm.traveler_relation WHERE relation_id = p_subject;
    ELSIF p_scope = 'booking_line' THEN
        PERFORM 1 FROM crm.booking_line WHERE booking_line_id = p_subject FOR UPDATE;
    ELSIF p_scope = 'agency_supplier' THEN
        SELECT kind INTO v_status FROM crm.agency_supplier WHERE agency_supplier_id = p_subject FOR UPDATE;
    ELSIF p_scope = 'conversation' THEN
        PERFORM 1 FROM crm.conversation WHERE conversation_id = p_subject FOR UPDATE;
    ELSE
        IF p_subject <> v_tenant THEN
            RAISE EXCEPTION 'crm: subject_not_found (a tenant erase names the agency of app.tenant_id)'
                USING ERRCODE = 'CRM13';
        END IF;
        SELECT status INTO v_status FROM crm.tenant WHERE tenant_id = v_tenant;
    END IF;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'crm: subject_not_found (% %)', p_scope, p_subject USING ERRCODE = 'CRM13';
    END IF;

    -- Hold rule 4e: any held row among those this erase would delete or update refuses it, dry run included.
    IF crm.erase_held(p_scope, p_subject, p_profile_token) THEN
        RAISE EXCEPTION 'crm: legal_hold (an active legal hold reaches a row the erase of % % would change)',
            p_scope, p_subject USING ERRCODE = 'CRM10';
    END IF;

    IF p_scope = 'trip' THEN
        v_blockers := crm.trip_delete_blockers(p_subject);
        IF cardinality(v_blockers) > 0 THEN
            RAISE EXCEPTION 'crm: delete_blocked %', array_to_string(v_blockers, ',') USING ERRCODE = 'CRM11';
        END IF;
    ELSIF p_scope = 'traveler' THEN
        IF EXISTS (SELECT 1 FROM crm.trip_traveler tt JOIN crm.trip t ON t.trip_id = tt.trip_id
                    WHERE tt.traveler_id = p_subject AND t.deleted_at IS NULL) THEN
            RAISE EXCEPTION 'crm: traveler_on_trip (delete or erase the client''s live trips first)'
                USING ERRCODE = 'CRM12';
        END IF;
        IF v_has_token AND p_profile_token IS NULL THEN
            RAISE EXCEPTION 'crm: profile_token_required' USING ERRCODE = 'CRM15';
        END IF;
        -- Consistency guard (the database cannot open the encrypted pointer; the caller decrypted it from this row,
        -- bound by its AAD): every party row of the token is the F2 twin of one of the traveller's own party rows
        -- (same trip, same role).
        IF p_profile_token IS NOT NULL AND EXISTS (
            SELECT 1 FROM crm.trip_party p
             WHERE p.traveler_token = p_profile_token
               AND NOT EXISTS (SELECT 1 FROM crm.trip_traveler tt
                                WHERE tt.trip_id = p.trip_id AND tt.traveler_id = p_subject AND tt.role = p.role)) THEN
            RAISE EXCEPTION 'crm: profile_token_mismatch' USING ERRCODE = 'CRM15';
        END IF;
    ELSIF p_scope = 'agency_supplier' THEN
        -- crm-014: the built-in Adventure Asia row leaves only with the agency; a supplier lines still name stays.
        IF v_status = 'aa' THEN
            RAISE EXCEPTION 'crm: aa_supplier_builtin (the Adventure Asia row leaves with the agency only)'
                USING ERRCODE = 'CRM22';
        END IF;
        IF EXISTS (SELECT 1 FROM crm.booking_line l WHERE l.agency_supplier_id = p_subject) THEN
            RAISE EXCEPTION 'crm: supplier_in_use (booking lines name this supplier)' USING ERRCODE = 'CRM27';
        END IF;
    ELSIF p_scope = 'tenant' AND NOT p_dry_run AND v_status <> 'offboarding' THEN
        -- A dry run (the counts the owner sees before confirming) works on an active agency.
        RAISE EXCEPTION 'crm: tenant_not_offboarding (status %)', v_status USING ERRCODE = 'CRM14';
    END IF;

    IF NOT p_dry_run THEN
        PERFORM set_config('app.erasing', 'on', true);
    END IF;

    IF p_scope = 'trip' THEN
        -- crm-012: the trip's submissions let go of the trip and of its links first, then the links and slots go.
        -- crm-014: the trip's line money, then its lines. crm-015: the messages of its conversations, then those.
        -- crm-016: signatures, codes, portal access, payments, schedule rows and proposals before the links.
        -- crm-017: the trip's AA requests (the outage queue) before its lines.
        -- crm-019: the builder rows (picks, rules, options, blocks, days) before the proposals.
        -- crm-021: the trip's metric events (they name its proposals) first.
        -- crm-022: the version's prep packs before the proposals.
        -- crm-023: the dispatch attempts of the trip's dispatch rows before those rows.
        -- crm-024: the refund requests (they name payments) before the payments, the invoice lines and invoices after
        -- them (payments name invoices) and before the schedule rows and proposals.
        -- crm-025: the signed evidence (terms_acceptance, signature_event) has no key on the trip and stays (DM-7
        -- claim-period exception); the receipt counts it (*_kept). crm.lifecycle_purge_expired deletes it later.
        v_counts := jsonb_build_object(
            'terms_acceptance_kept', (SELECT count(*) FROM crm.terms_acceptance WHERE trip_id = p_subject),
            'signature_event_kept', (SELECT count(*) FROM crm.signature_event WHERE trip_id = p_subject));
        FOREACH v_step SLICE 1 IN ARRAY ARRAY[
            ['metric_event', 'trip_id = $1', ''],
            ['signature_request', 'trip_id = $1', ''],
            ['otp_challenge', 'trip_id = $1', ''],
            ['traveler_access', 'trip_id = $1', ''],
            ['refund_request', 'trip_id = $1', ''],
            ['payment', 'trip_id = $1', ''],
            ['invoice_line', 'trip_id = $1', ''],
            ['invoice', 'trip_id = $1', ''],
            ['payment_schedule', 'trip_id = $1', ''],
            ['selection', 'trip_id = $1', ''],
            ['option_rule', 'trip_id = $1', ''],
            ['option', 'trip_id = $1', ''],
            ['option_block', 'trip_id = $1', ''],
            ['proposal_day', 'trip_id = $1', ''],
            ['prep_pack_selection', 'trip_id = $1', ''],
            ['proposal', 'trip_id = $1', ''],
            ['form_submission', 'trip_id = $1', 'trip_id = NULL, client_link_id = NULL'],
            ['client_link', 'trip_id = $1', ''],
            ['meeting_slot', 'trip_id = $1', ''],
            ['dispatch_attempt', 'dispatch_id IN (SELECT q.dispatch_id FROM crm.dispatch_queue q '
                                 'WHERE q.trip_id = $1)', ''],
            ['dispatch_queue', 'trip_id = $1', ''],
            ['message', 'conversation_id IN (SELECT c.conversation_id FROM crm.conversation c WHERE c.trip_id = $1)', ''],
            ['conversation', 'trip_id = $1', ''],
            ['trip_commitment', 'trip_id = $1', ''],
            ['aa_request', 'trip_id = $1', ''],
            ['booking_line_money', 'booking_line_id IN (SELECT l.booking_line_id FROM crm.booking_line l '
                                   'WHERE l.trip_id = $1)', ''],
            ['booking_line', 'trip_id = $1', ''],
            ['document', 'trip_id = $1', ''],
            ['note', 'trip_id = $1', ''],
            ['task', 'trip_id = $1', ''],
            ['trip_stage_history', 'trip_id = $1', ''],
            ['trip_party', 'trip_id = $1', ''],
            ['trip_traveler', 'trip_id = $1', ''],
            ['trip', 'trip_id = $1', '']
        ] LOOP
            v_counts := v_counts || jsonb_build_object(
                v_step[1] || CASE WHEN v_step[3] <> '' THEN '_unlinked' ELSE '' END,
                crm.erase_rows(v_step[1], v_step[2], p_subject, NULL, p_dry_run, NULLIF(v_step[3], '')));
        END LOOP;
    ELSIF p_scope = 'traveler' THEN
        -- crm-012: their call slots (also those their submissions booked) before the submissions, their links after.
        -- crm-015: the messages of their conversations, then those. crm-016: the name they typed to accept a proposal
        -- (the proposal's link names them; before their links go), their signatures, codes and portal access.
        -- crm-023: the dispatch attempts of their dispatch rows before those rows.
        -- crm-025: also the signatures they signed as a guardian (their access signed them); the signed evidence
        -- (terms_acceptance, signature_event) stays (DM-7 claim-period exception) and the receipt counts it.
        v_counts := jsonb_build_object(
            'terms_acceptance_kept', (SELECT count(*) FROM crm.terms_acceptance WHERE traveler_id = p_subject),
            'signature_event_kept', (SELECT count(*) FROM crm.signature_event
                                      WHERE traveler_id = p_subject OR signer_traveler_id = p_subject));
        FOREACH v_step SLICE 1 IN ARRAY ARRAY[
            ['proposal', 'accepted_name_enc IS NOT NULL AND link_id IN (SELECT l.link_id FROM crm.client_link l '
                         'WHERE l.traveler_id = $1)', 'accepted_name_enc = NULL, accepted_name_erased_at = now()'],
            ['signature_request', 'traveler_id = $1 OR signer_traveler_id = $1', ''],
            ['otp_challenge', 'traveler_id = $1', ''],
            ['traveler_access', 'traveler_id = $1', ''],
            ['meeting_slot', 'traveler_id = $1 OR form_submission_id IN (SELECT s.submission_id '
                             'FROM crm.form_submission s WHERE s.traveler_id = $1)', ''],
            ['dispatch_attempt', 'dispatch_id IN (SELECT q.dispatch_id FROM crm.dispatch_queue q '
                                 'WHERE q.traveler_id = $1)', ''],
            ['dispatch_queue', 'traveler_id = $1', ''],
            ['message', 'conversation_id IN (SELECT c.conversation_id FROM crm.conversation c '
                        'WHERE c.traveler_id = $1)', ''],
            ['conversation', 'traveler_id = $1', ''],
            ['traveler_health', 'traveler_id = $1', ''],
            ['document', 'traveler_id = $1', ''],
            ['note', 'traveler_id = $1', ''],
            ['traveler_relation', 'from_traveler_id = $1 OR to_traveler_id = $1', ''],
            ['trip_traveler', 'traveler_id = $1', ''],
            ['trip_party', 'traveler_token = $2', ''],
            ['profile_history', 'traveler_token = $2', ''],
            ['traveler_profile', 'traveler_token = $2', ''],
            ['consent', 'traveler_id = $1', ''],
            ['form_submission', 'traveler_id = $1', ''],
            ['client_link', 'traveler_id = $1', ''],
            ['traveler', 'referrer_traveler_id = $1', 'referrer_traveler_id = NULL'],
            ['traveler', 'traveler_id = $1', '']
        ] LOOP
            v_counts := v_counts || jsonb_build_object(
                v_step[1] || CASE WHEN v_step[3] = '' THEN '' WHEN v_step[1] = 'proposal' THEN '_acceptance_name_erased'
                                  ELSE '_referrer_unlinked' END,
                crm.erase_rows(v_step[1], v_step[2], p_subject, p_profile_token, p_dry_run, NULLIF(v_step[3], '')));
        END LOOP;
    ELSIF p_scope IN ('task', 'note', 'document') THEN
        v_counts := jsonb_build_object(p_scope,
            crm.erase_rows(p_scope, p_scope || '_id = $1', p_subject, NULL, p_dry_run));
    ELSIF p_scope = 'relation' THEN
        v_counts := jsonb_build_object('traveler_relation',
            crm.erase_rows('traveler_relation', 'relation_id = $1', p_subject, NULL, p_dry_run));
    ELSIF p_scope = 'booking_line' THEN
        -- crm-014: the trash purge of a planning line: its money, then the line. crm-017: its AA requests first (an
        -- agency line has none; an AA line never reaches the trash, the guard refuses it).
        v_counts := jsonb_build_object(
            'aa_request', crm.erase_rows('aa_request', 'booking_line_id = $1', p_subject, NULL, p_dry_run),
            'booking_line_money', crm.erase_rows('booking_line_money', 'booking_line_id = $1', p_subject, NULL, p_dry_run),
            'booking_line', crm.erase_rows('booking_line', 'booking_line_id = $1', p_subject, NULL, p_dry_run));
    ELSIF p_scope = 'agency_supplier' THEN
        v_counts := jsonb_build_object('agency_supplier',
            crm.erase_rows('agency_supplier', 'agency_supplier_id = $1', p_subject, NULL, p_dry_run));
    ELSIF p_scope = 'conversation' THEN
        -- crm-015: the trash purge of a conversation (an Unmatched one the agent deleted): its messages, then it. Kept
        -- attachments are documents of the trip / traveller and stay with them.
        v_counts := jsonb_build_object(
            'message', crm.erase_rows('message', 'conversation_id = $1', p_subject, NULL, p_dry_run),
            'conversation', crm.erase_rows('conversation', 'conversation_id = $1', p_subject, NULL, p_dry_run));
    ELSE
        -- The whole agency. Memberships are deleted as a platform action (crm-008 guard_member_write lets only an
        -- unscoped or platform context delete a member); the caller's actor is restored afterwards.
        PERFORM set_config('app.actor', 'platform:crm_offboarding', true);
        -- crm-013: the agency's CIS membership feed records (ids and codes) go first.
        -- crm-014: line money, lines and suppliers before the trips; the FX overrides before the members (set_by).
        -- crm-015: messages and conversations before the trips and travellers; saved replies, imports, the forward-in
        -- address and the mailboxes before the credentials and the members.
        -- crm-016: signatures, codes, portal access, payments, schedule rows, proposals and agreement versions first.
        -- crm-017: the Booking feed records and cursor, then the AA requests before the lines.
        -- crm-019: the builder rows before the proposals. crm-021: the metric events before the proposals and members.
        -- crm-022: the prep packs before the proposals; the message templates with the agency's mail settings.
        -- crm-023: the dispatch attempts before the dispatch rows.
        -- crm-024: refund requests, payments, invoice lines, invoices before the schedule rows; the payment methods and
        -- the invoice number sequence with the agency's settings.
        -- crm-025: the signed evidence (terms_acceptance, signature_event) leaves with the agency, before the
        -- signatures and the agreement versions.
        FOREACH v_step SLICE 1 IN ARRAY ARRAY[
            ['membership_inbox', ''], ['inbox_events', ''], ['booking_feed_state', ''], ['metric_event', ''],
            ['terms_acceptance', ''], ['signature_event', ''], ['signature_request', ''], ['otp_challenge', ''], ['traveler_access', ''],
            ['refund_request', ''], ['payment', ''], ['invoice_line', ''], ['invoice', ''],
            ['payment_schedule', ''], ['selection', ''], ['option_rule', ''], ['option', ''], ['option_block', ''],
            ['proposal_day', ''], ['prep_pack_selection', ''], ['proposal', ''], ['agreement_doc', ''],
            ['dispatch_attempt', ''], ['dispatch_queue', ''], ['message', ''], ['conversation', ''],
            ['trip_commitment', ''], ['aa_request', ''], ['booking_line_money', ''], ['booking_line', ''],
            ['agency_supplier', ''], ['document', ''], ['traveler_health', ''],
            ['note', ''], ['task', ''], ['trip_stage_history', ''], ['trip_party', ''], ['trip_traveler', ''],
            ['traveler_relation', ''], ['consent', ''], ['meeting_slot', ''], ['form_submission', ''],
            ['client_link', ''], ['profile_history', ''],
            ['traveler_profile', ''], ['placeholder_map', 'optional'], ['llm_call', ''], ['trip', ''],
            ['traveler', 'unlink'], ['traveler', ''], ['intake_form', ''], ['form_definition', ''],
            ['saved_reply', ''], ['message_template', ''], ['mail_import', ''], ['ingest_address', ''], ['channel_account', ''],
            ['integration_credential', ''], ['fx_rate_override', ''],
            ['payment_provider_account', ''], ['invoice_sequence', ''], ['tenant_settings', ''],
            ['member_invitation', 'optional'], ['owner_recovery_request', 'optional'],
            ['tenant_entitlement', 'optional'], ['member', '']
        ] LOOP
            CONTINUE WHEN v_step[2] = 'optional' AND to_regclass('crm.' || v_step[1]) IS NULL;
            IF v_step[2] = 'unlink' THEN
                v_counts := v_counts || jsonb_build_object('traveler_referrer_unlinked',
                    crm.erase_rows('traveler', 'referrer_traveler_id IS NOT NULL', p_subject, NULL, p_dry_run,
                                   'referrer_traveler_id = NULL'));
            ELSE
                v_counts := v_counts || jsonb_build_object(v_step[1],
                    crm.erase_rows(v_step[1], 'true', p_subject, NULL, p_dry_run));
            END IF;
        END LOOP;
        PERFORM set_config('app.actor', v_actor, true);
        -- Nothing of the agency may be left in a tenant table outside the keep list: a table added later that this
        -- function does not know fails the erase (rolled back) instead of keeping personal data silently.
        IF NOT p_dry_run THEN
            FOR r IN SELECT c.relname::text AS name
                       FROM pg_catalog.pg_class c
                       JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped
                      WHERE c.relnamespace = 'crm'::regnamespace AND c.relkind IN ('r', 'p') AND NOT c.relispartition
                        AND c.relname <> ALL (c_keep) AND c.relname NOT LIKE 'audit_event%'
                      ORDER BY 1 LOOP
                IF NOT (SELECT relforcerowsecurity FROM pg_catalog.pg_class WHERE oid = ('crm.' || quote_ident(r.name))::regclass) THEN
                    v_left := v_left || r.name;  -- without FORCE RLS the owner would see every agency: refuse
                ELSE
                    EXECUTE format('SELECT EXISTS (SELECT 1 FROM crm.%I)', r.name) INTO v_has_token;
                    IF v_has_token THEN
                        v_left := v_left || r.name;
                    END IF;
                END IF;
            END LOOP;
            IF cardinality(v_left) > 0 THEN
                RAISE EXCEPTION 'crm: erase_incomplete (rows left in %)', array_to_string(v_left, ', ')
                    USING ERRCODE = 'CRM16';
            END IF;
        END IF;
    END IF;

    IF NOT p_dry_run THEN
        PERFORM set_config('app.erasing', '', true);
    END IF;
    RETURN jsonb_build_object('scope', p_scope, 'dry_run', p_dry_run, 'counts', v_counts);
END;
$$;
REVOKE ALL ON FUNCTION crm.erase_subject(text, uuid, uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.erase_subject(text, uuid, uuid, boolean) TO crm_eraser;

COMMENT ON FUNCTION crm.erase_subject(text, uuid, uuid, boolean) IS 'AA-942 (crm-010, design §4.10, Fix B16), extended by AA-943 (crm-012) to client_link and meeting_slot, by AA-978 (crm-013) to membership_inbox (agency scope), by AA-944 (crm-014) to the ledger (trip and agency scopes: booking_line_money, booking_line; agency scope: agency_supplier, fx_rate_override; new scopes booking_line and agency_supplier for the trash purge), by AA-945 (crm-015) to mail (trip, traveller and agency scopes: message, conversation; agency scope: saved_reply, mail_import, ingest_address, channel_account; new scope conversation for the trash purge), by AA-946 (crm-016) to the lifecycle tables (trip and agency scopes: signature_request, otp_challenge, traveler_access, payment, payment_schedule, proposal; traveller scope: signature_request, otp_challenge, traveler_access, and the typed acceptance name of the proposals their links carried (accepted_name_enc := NULL); agency scope: agreement_doc) by AA-947 (crm-017) to the AA lines (trip, booking_line and agency scopes: aa_request; agency scope: inbox_events, booking_feed_state) by AA-949 (crm-019) to the proposal builder (trip and agency scopes: selection, option_rule, option, option_block, proposal_day) by AA-950 (crm-021) to crm.metric_event (trip and agency scopes) by AA-951 (crm-022) to crm.prep_pack_selection (trip and agency scopes) and crm.message_template (agency scope) by AA-993 G4b (crm-023) to crm.dispatch_attempt (trip, traveller and agency scopes, before crm.dispatch_queue) and by AA-952 (crm-024) to the invoices and payments (trip and agency scopes: crm.refund_request before crm.payment, crm.invoice_line and crm.invoice after it and before crm.payment_schedule; agency scope: crm.payment_provider_account, crm.invoice_sequence) and by AA-955 (crm-025) to the signed evidence (agency scope: crm.terms_acceptance, crm.signature_event; trip and traveller scopes KEEP them, DM-7 claim-period exception, and count them as terms_acceptance_kept / signature_event_kept; traveller scope also erases the signatures the traveller signed as a guardian) and by AA-967 (crm-026) to the keep list of the agency scope (crm.export_job, crm.data_request: receipts without personal data): the only hard-delete path of agency data. Scopes trip, traveler (needs the decrypted F2 profile token), task, note, document, relation, booking_line, agency_supplier, conversation, tenant (status offboarding, except a dry run; every tenant table except the keep list). Used by the trash purge and by erasure / offboarding (which skip the trash). Refuses: CRM10 legal_hold (the hold rule: any held row among those the erase would delete or update, crm.erase_held), CRM11 delete_blocked, CRM12 traveler_on_trip, CRM13 subject_not_found, CRM14 tenant_not_offboarding, CRM15 profile token, CRM16 erase_incomplete, CRM22 the Adventure Asia supplier row, CRM27 a supplier lines name. Never touches audit_event. Takes LOCK TABLE crm.legal_hold IN SHARE MODE first (serialised with hold placement). EXECUTE: crm_eraser only (SET LOCAL ROLE inside the lifecycle context).';

-- ── Guard 1: the shape this file promises ────────────────────────────────────────────────────────
DO $$
DECLARE
    t text;
    r text;
    p text;
    v_src text;
BEGIN
    FOREACH t IN ARRAY ARRAY['data_request', 'export_job'] LOOP
        IF NOT (SELECT relrowsecurity AND relforcerowsecurity FROM pg_catalog.pg_class
                 WHERE oid = ('crm.' || t)::regclass) THEN
            RAISE EXCEPTION 'crm-026: crm.% must have ENABLE + FORCE row level security', t;
        END IF;
        FOREACH r IN ARRAY ARRAY['crm_ai_reader', 'crm_insights', 'crm_support_reader', 'crm_eraser'] LOOP
            FOREACH p IN ARRAY ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'] LOOP
                IF pg_catalog.has_table_privilege(r, 'crm.' || t, p) THEN
                    RAISE EXCEPTION 'crm-026: reader % may % on crm.%', r, p, t;
                END IF;
            END LOOP;
        END LOOP;
        IF pg_catalog.has_table_privilege('crm_app', 'crm.' || t, 'TRUNCATE')
           OR pg_catalog.has_table_privilege('crm_app', 'crm.' || t, 'DELETE')
           OR NOT pg_catalog.has_table_privilege('crm_app', 'crm.' || t, 'INSERT')
           OR NOT pg_catalog.has_table_privilege('crm_app', 'crm.' || t, 'UPDATE') THEN
            RAISE EXCEPTION 'crm-026: crm_app must have SELECT, INSERT, UPDATE and no DELETE / TRUNCATE on crm.%', t;
        END IF;
    END LOOP;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_policy pol JOIN pg_catalog.pg_class c ON c.oid = pol.polrelid
               WHERE c.relnamespace = 'crm'::regnamespace AND 0 = ANY (pol.polroles)) THEN
        RAISE EXCEPTION 'crm-026: a crm policy applies TO PUBLIC (catalogue rule b); name the CRM roles';
    END IF;
    IF pg_catalog.has_function_privilege('crm_app', 'crm.erase_subject(text,uuid,uuid,boolean)', 'EXECUTE')
       OR NOT pg_catalog.has_function_privilege('crm_eraser', 'crm.erase_subject(text,uuid,uuid,boolean)', 'EXECUTE')
       OR pg_catalog.has_function_privilege('public', 'crm.erase_subject(text,uuid,uuid,boolean)', 'EXECUTE') THEN
        RAISE EXCEPTION 'crm-026: crm.erase_subject must be executable by crm_eraser only';
    END IF;
    SELECT prosrc INTO v_src FROM pg_catalog.pg_proc WHERE oid = 'crm.erase_subject(text,uuid,uuid,boolean)'::regprocedure;
    -- Every table an earlier key taught erase_subject (the crm-025 text kept whole), and this key's keep-list names.
    FOREACH t IN ARRAY ARRAY['terms_acceptance', 'signature_event', 'refund_request', 'invoice_line', 'invoice',
                             'payment_provider_account', 'invoice_sequence', 'dispatch_attempt', 'dispatch_queue',
                             'prep_pack_selection', 'message_template', 'metric_event', 'selection', 'option_rule',
                             'option', 'option_block', 'proposal_day', 'aa_request', 'inbox_events',
                             'booking_feed_state', 'signature_request', 'otp_challenge', 'traveler_access', 'payment',
                             'payment_schedule', 'proposal', 'agreement_doc', 'message', 'conversation',
                             'saved_reply', 'mail_import', 'ingest_address', 'channel_account', 'booking_line_money',
                             'booking_line', 'agency_supplier', 'fx_rate_override', 'membership_inbox', 'client_link',
                             'meeting_slot', 'export_job', 'data_request'] LOOP
        IF position(quote_literal(t) IN v_src) = 0 THEN
            RAISE EXCEPTION 'crm-026: crm.erase_subject does not name crm.%', t;
        END IF;
    END LOOP;
    IF position('accepted_name_erased_at' IN v_src) = 0 OR position('signature_event_kept' IN v_src) = 0 THEN
        RAISE EXCEPTION 'crm-026: crm.erase_subject lost the crm-016 typed acceptance name or the crm-025 kept evidence step';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint WHERE conrelid = 'crm.erasure_request'::regclass
                    AND conname = 'erasure_request_tenant_id_uq') THEN
        RAISE EXCEPTION 'crm-026: crm.erasure_request needs UNIQUE (tenant_id, request_id)';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-026', now(), 'AA-967 CRM-35 module 18: portability exports (crm.export_job), the data-request log (crm.data_request), the agency-deletion cool-off and verification on crm.erasure_request, erase_subject keep list + the two tables')
ON CONFLICT (version) DO NOTHING;

COMMIT;
