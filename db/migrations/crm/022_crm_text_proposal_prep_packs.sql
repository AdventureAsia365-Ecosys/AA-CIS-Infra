-- Migration crm-022: AA-951 (partner CRM, design v3 card CRM-22) — Module 4 text proposal and the "Before you go"
-- day: the cache of AA-authored content from CIS (prep packs, starter templates), the packs an agent picks for the day 0
-- of a builder proposal version (R38), and the agency's message template library seeded from AA's starter templates
-- (R9).
--
-- Owner: AA-Partner (api/migrations/022_crm_text_proposal_prep_packs.sql). AA-CIS-Infra db/migrations/crm/ holds the
-- byte copy DB Migrate applies (Migration Copy Guard). Key crm-022. crm.erase_subject below is the crm-021 text plus
-- this file's two tenant tables; a later key that replaces it starts from THIS text. crm.erase_held is unchanged:
-- crm.prep_pack_selection carries trip_id (the trip scope of crm.hold_trip reaches it) and crm.message_template is
-- agency settings (the agency hold only, like crm.saved_reply). crm.lifecycle_purge_expired is unchanged (crm-018).
--
-- Why. Design v3 §6.3 card CRM-22 (deps CRM-21a, CRM-B5; implements M4, R38, R9), §2.7 F3.4 ("the Before you go
-- day 0 (R38)") / F4 (A-05 send: visual link, email text or WhatsApp text, all three share one price_hash), §3.3 group
-- E (prep_pack_selection) and group G (message_template), §5.9 (CRM-B5: AA-authored content in CIS served through
-- catalog.http.v1 1.2, AA-977), Q1 2.3 (AA writes prep packs; visa = the official link only). Card R: a differing
-- price_hash blocks the send (the API compares the rendered hash with the version's). Card E: a trip without AA lines
-- renders without packs (the API suggests packs from the version's AA items only).
--
-- What (DM-7 rows: crm.prep_pack_selection and crm.message_template have theirs since v1.3; crm.aa_content needs a
-- row added with this key, root data standards Part B §7):
--   1. crm.aa_content (platform table, no tenant, no personal data): the latest published version of each AA content
--      item CIS lists (kinds prep_pack and starter_template are synced; one row per content_id, one locale each, EN
--      and VI copies paired by group_key), with its body, applies_to and content_hash; listed = still in CIS's list
--      (a retired item stays, unlisted). Written only by crm_catalog_sync (app/catalog/content.py); crm_app SELECT,
--      INSERT, UPDATE.
--   2. crm.prep_pack_selection (base template): one AA prep pack (one locale) picked for one builder proposal version,
--      a copy of the pinned version (content_id + content_version, title, body, applies_to, content_hash), so a
--      published or sent version keeps the text it was sent with when CIS publishes a newer one (CRM-B5 card E).
--      Changes only while its proposal is a draft (crm.guard_proposal_draft, CRM35); the trip hold guard.
--   3. crm.message_template (base template): the agency's template library (R9): title, locale, body under the
--      agency mail DEK (agents may write names into it, as crm.saved_reply), source agency | aa_starter (copied from
--      a CIS starter template: aa_group_key + aa_content_id + aa_version; one copy per group and locale).
--   4. crm.erase_subject (the crm-021 text) + prep_pack_selection (trip and agency scopes, before the proposals) and
--      message_template (agency scope).
--   SQLSTATEs: none new (the next key starts at CRM38).
--
-- Order: after crm-021 (AA-950); Guard 0 refuses to run before it is registered (erase_subject builds on its text).
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL. Idempotent (IF NOT EXISTS, DROP …
-- IF EXISTS, CREATE OR REPLACE, ON CONFLICT DO NOTHING). Rollback: a forward crm- file (MIG-14); before the AA-951
-- code deploys nothing reads these objects, and the code merges only after this file is applied (S249 lesson).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '15min';

-- ── Guard 0: runs as the owner, after crm-021 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-022: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-021') THEN
        RAISE EXCEPTION 'crm-022: crm-021 (AA-950 client proposal) lands first';
    END IF;
    IF to_regclass('crm.proposal_day') IS NULL OR to_regclass('crm.metric_event') IS NULL
       OR to_regprocedure('crm.guard_proposal_draft()') IS NULL
       OR to_regprocedure('crm.guard_held_change()') IS NULL
       OR to_regprocedure('crm.erase_rows(text,text,uuid,uuid,boolean,text)') IS NULL THEN
        RAISE EXCEPTION 'crm-022: crm.proposal_day / crm.guard_proposal_draft (crm-019), crm.metric_event (crm-021) or crm.guard_held_change / crm.erase_rows (crm-010) missing';
    END IF;
END $$;

-- ── 1. crm.aa_content (platform cache of CIS AA-authored content) ────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.aa_content (
    content_id    UUID PRIMARY KEY,
    kind          TEXT NOT NULL,
    locale        TEXT NOT NULL,
    group_key     TEXT,
    version       INTEGER NOT NULL,
    title         TEXT NOT NULL,
    body_markdown TEXT NOT NULL,
    applies_to    JSONB NOT NULL DEFAULT '{}'::jsonb,
    content_hash  TEXT NOT NULL,
    published_at  TIMESTAMPTZ NOT NULL,
    listed        BOOLEAN NOT NULL DEFAULT true,
    fetched_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    checked_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT aa_content_values_chk CHECK (
        kind IN ('prep_pack', 'starter_template', 'campaign_block')
        AND locale IN ('en', 'vi')
        AND (group_key IS NULL OR group_key ~ '^[a-z0-9][a-z0-9-]{1,79}$')
        AND version >= 1
        AND char_length(title) BETWEEN 1 AND 300 AND title !~ '[[:cntrl:]]'
        AND octet_length(body_markdown) <= 200000
        AND jsonb_typeof(applies_to) = 'object'
        AND char_length(content_hash) BETWEEN 1 AND 100
    )
);
CREATE INDEX IF NOT EXISTS aa_content_kind_idx ON crm.aa_content (kind, locale, group_key) WHERE listed;
REVOKE DELETE, TRUNCATE ON crm.aa_content FROM crm_app;
GRANT SELECT, INSERT, UPDATE ON crm.aa_content TO crm_app;
COMMENT ON TABLE crm.aa_content IS 'AA-951 (crm-022; design v3 §5.9, CRM-B5 / AA-977, R38, R9): the latest published version of each AA-authored content item CIS lists over catalog.http.v1 1.2 (/aa-content): prep packs and starter templates, one locale per content_id (EN and VI copies share group_key). No tenant column, no personal data (AA''s own text). listed = still in CIS''s list (false once retired; the row stays). Written only by the hourly crm_catalog_sync (app/catalog/content.py); crm_app SELECT, INSERT, UPDATE. An agency keeps its own copy of what it uses (crm.prep_pack_selection, crm.message_template), so this cache can lag or lose a row without changing a sent proposal. Kept while the CRM runs.';
COMMENT ON COLUMN crm.aa_content.applies_to IS 'AA-951 (crm-022): the contract''s applies_to: country_codes (ISO 3166-1 alpha-2) and / or tours ({source_system: cis, source_id}); {} = everywhere (templates)';

-- ── 2. crm.prep_pack_selection ───────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.prep_pack_selection (
    prep_pack_selection_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id              UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                           REFERENCES crm.tenant (tenant_id),
    trip_id                UUID NOT NULL,
    proposal_id            UUID NOT NULL,
    group_key              TEXT NOT NULL,
    locale                 TEXT NOT NULL,
    content_id             UUID NOT NULL,
    content_version        INTEGER NOT NULL,
    title                  TEXT NOT NULL,
    body_markdown          TEXT NOT NULL,
    applies_to             JSONB NOT NULL DEFAULT '{}'::jsonb,
    content_hash           TEXT NOT NULL,
    sort_order             SMALLINT NOT NULL DEFAULT 0,
    source_selection_id    UUID,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by             TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at             TIMESTAMPTZ,
    deleted_by             TEXT,
    purge_after            TIMESTAMPTZ,
    CONSTRAINT prep_pack_selection_tenant_id_uq UNIQUE (tenant_id, prep_pack_selection_id),
    CONSTRAINT prep_pack_selection_pack_uq UNIQUE (tenant_id, proposal_id, group_key, locale),
    CONSTRAINT prep_pack_selection_proposal_fk FOREIGN KEY (tenant_id, proposal_id, trip_id)
        REFERENCES crm.proposal (tenant_id, proposal_id, trip_id),
    CONSTRAINT prep_pack_selection_values_chk CHECK (
        group_key ~ '^[a-z0-9][a-z0-9-]{1,79}$'
        AND locale IN ('en', 'vi')
        AND content_version >= 1
        AND char_length(title) BETWEEN 1 AND 300 AND title !~ '[[:cntrl:]]'
        AND octet_length(body_markdown) <= 200000
        AND jsonb_typeof(applies_to) = 'object'
        AND char_length(content_hash) BETWEEN 1 AND 100
        AND sort_order BETWEEN 0 AND 99
    ),
    CONSTRAINT prep_pack_selection_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE INDEX IF NOT EXISTS prep_pack_selection_proposal_idx ON crm.prep_pack_selection (tenant_id, proposal_id,
                                                                                     sort_order);
CREATE INDEX IF NOT EXISTS prep_pack_selection_trip_idx ON crm.prep_pack_selection (tenant_id, trip_id);
COMMENT ON TABLE crm.prep_pack_selection IS 'AA-951 (crm-022; design v3 group E, R38, CRM-B5 card E): one AA prep pack (one locale of one group_key) the agent picked for the "Before you go" day 0 of a builder proposal version: a copy of the pinned CIS version (content_id + content_version, title, body, applies_to, content_hash), so a published or sent version keeps its text when CIS publishes a newer one. AA content, no personal data. Changes only while its proposal is a draft (crm.guard_proposal_draft, CRM35); a working copy copies them (source_selection_id). Erased with its trip / agency (crm.erase_subject)';
COMMENT ON COLUMN crm.prep_pack_selection.body_markdown IS 'AA-951 (crm-022): the pack text as CIS published it (AA-authored, no personal data). Rendering keeps only the official links of a visa section (Q1 2.3: visa = the official link only)';

-- ── 3. crm.message_template ──────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.message_template (
    message_template_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                        REFERENCES crm.tenant (tenant_id),
    locale              TEXT NOT NULL,
    title               TEXT NOT NULL,
    body_enc            BYTEA NOT NULL,
    source              TEXT NOT NULL DEFAULT 'agency',
    aa_group_key        TEXT,
    aa_content_id       UUID,
    aa_version          INTEGER,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by          TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at          TIMESTAMPTZ,
    deleted_by          TEXT,
    purge_after         TIMESTAMPTZ,
    CONSTRAINT message_template_tenant_id_uq UNIQUE (tenant_id, message_template_id),
    CONSTRAINT message_template_values_chk CHECK (
        locale IN ('en', 'vi')
        AND char_length(btrim(title)) BETWEEN 1 AND 120 AND title !~ '[[:cntrl:]]'
        AND octet_length(body_enc) BETWEEN 30 AND 65536
        AND source IN ('agency', 'aa_starter')
        AND CASE source
            WHEN 'aa_starter' THEN aa_group_key ~ '^[a-z0-9][a-z0-9-]{1,79}$' AND aa_content_id IS NOT NULL
                                   AND aa_version >= 1
            ELSE num_nonnulls(aa_group_key, aa_content_id, aa_version) = 0
        END
    ),
    CONSTRAINT message_template_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS message_template_aa_uq ON crm.message_template (tenant_id, aa_group_key, locale)
    WHERE aa_group_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS message_template_tenant_idx ON crm.message_template (tenant_id, locale, title)
    WHERE deleted_at IS NULL;
COMMENT ON TABLE crm.message_template IS 'AA-951 (crm-022; design v3 group G, R9, M4): the agency''s message template library (one locale each, title in clear, body under the agency mail DEK), written by the owner (WORKFLOW_EDIT), used by every role to start a message (the A-05 text proposal intro). source aa_starter = copied from a CIS starter template (aa_group_key, aa_content_id, aa_version; at most one copy per group and locale, so the import converges), then the agency''s own text. Deleted for good by the owner (agency text, no client data by design). Erased with the agency.';
COMMENT ON COLUMN crm.message_template.body_enc IS 'pii:free_text; the template text with merge fields ({{traveller_first_name}}, {{trip_name}}, {{agency_name}}, {{agent_name}}, {{destination}}, {{departure_date}}, {{proposal}}), AES-256-GCM under the tenant mail DEK (agents may write names into it)';

-- ── RLS, triggers and the guards on the two tenant tables ────────────────────────────────────────
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['prep_pack_selection', 'message_template'] LOOP
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
    END LOOP;
    -- A published / sent version's packs never change (CRM35), whatever path writes.
    EXECUTE 'CREATE OR REPLACE TRIGGER prep_pack_selection_draft_only BEFORE INSERT OR UPDATE OR DELETE '
            'ON crm.prep_pack_selection FOR EACH ROW EXECUTE FUNCTION crm.guard_proposal_draft()';
    EXECUTE 'DROP TRIGGER IF EXISTS prep_pack_selection_hold_guard ON crm.prep_pack_selection';
    EXECUTE 'CREATE TRIGGER prep_pack_selection_hold_guard BEFORE DELETE OR UPDATE ON crm.prep_pack_selection '
            'FOR EACH ROW EXECUTE FUNCTION crm.guard_held_change(''trip_id'')';
    -- crm_app: the default privileges gave table-wide DML; no TRUNCATE.
    EXECUTE 'REVOKE TRUNCATE ON crm.prep_pack_selection, crm.message_template FROM crm_app';
    EXECUTE 'GRANT SELECT, INSERT, UPDATE, DELETE ON crm.prep_pack_selection, crm.message_template TO crm_app';
END $$;

-- ── 4. crm.erase_subject: the crm-021 text plus prep_pack_selection and message_template ─────────
-- A later key that replaces it starts from THIS text.
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
    -- the lifecycle counts and the holds (ids and codes only).
    c_keep CONSTANT text[] := ARRAY['tenant', 'tenant_key', 'audit_event', 'audit_export_tenant',
                                    'audit_export_manifest', 'erasure_request', 'lifecycle_run', 'legal_hold'];
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
        FOREACH v_step SLICE 1 IN ARRAY ARRAY[
            ['metric_event', 'trip_id = $1', ''],
            ['signature_request', 'trip_id = $1', ''],
            ['otp_challenge', 'trip_id = $1', ''],
            ['traveler_access', 'trip_id = $1', ''],
            ['payment', 'trip_id = $1', ''],
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
        FOREACH v_step SLICE 1 IN ARRAY ARRAY[
            ['proposal', 'accepted_name_enc IS NOT NULL AND link_id IN (SELECT l.link_id FROM crm.client_link l '
                         'WHERE l.traveler_id = $1)', 'accepted_name_enc = NULL, accepted_name_erased_at = now()'],
            ['signature_request', 'traveler_id = $1', ''],
            ['otp_challenge', 'traveler_id = $1', ''],
            ['traveler_access', 'traveler_id = $1', ''],
            ['meeting_slot', 'traveler_id = $1 OR form_submission_id IN (SELECT s.submission_id '
                             'FROM crm.form_submission s WHERE s.traveler_id = $1)', ''],
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
        FOREACH v_step SLICE 1 IN ARRAY ARRAY[
            ['membership_inbox', ''], ['inbox_events', ''], ['booking_feed_state', ''], ['metric_event', ''],
            ['signature_request', ''], ['otp_challenge', ''], ['traveler_access', ''], ['payment', ''],
            ['payment_schedule', ''], ['selection', ''], ['option_rule', ''], ['option', ''], ['option_block', ''],
            ['proposal_day', ''], ['prep_pack_selection', ''], ['proposal', ''], ['agreement_doc', ''],
            ['dispatch_queue', ''], ['message', ''], ['conversation', ''],
            ['trip_commitment', ''], ['aa_request', ''], ['booking_line_money', ''], ['booking_line', ''],
            ['agency_supplier', ''], ['document', ''], ['traveler_health', ''],
            ['note', ''], ['task', ''], ['trip_stage_history', ''], ['trip_party', ''], ['trip_traveler', ''],
            ['traveler_relation', ''], ['consent', ''], ['meeting_slot', ''], ['form_submission', ''],
            ['client_link', ''], ['profile_history', ''],
            ['traveler_profile', ''], ['placeholder_map', 'optional'], ['llm_call', ''], ['trip', ''],
            ['traveler', 'unlink'], ['traveler', ''], ['intake_form', ''], ['form_definition', ''],
            ['saved_reply', ''], ['message_template', ''], ['mail_import', ''], ['ingest_address', ''], ['channel_account', ''],
            ['integration_credential', ''], ['fx_rate_override', ''], ['tenant_settings', ''],
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

COMMENT ON FUNCTION crm.erase_subject(text, uuid, uuid, boolean) IS 'AA-942 (crm-010, design §4.10, Fix B16), extended by AA-943 (crm-012) to client_link and meeting_slot, by AA-978 (crm-013) to membership_inbox (agency scope), by AA-944 (crm-014) to the ledger (trip and agency scopes: booking_line_money, booking_line; agency scope: agency_supplier, fx_rate_override; new scopes booking_line and agency_supplier for the trash purge), by AA-945 (crm-015) to mail (trip, traveller and agency scopes: message, conversation; agency scope: saved_reply, mail_import, ingest_address, channel_account; new scope conversation for the trash purge), by AA-946 (crm-016) to the lifecycle tables (trip and agency scopes: signature_request, otp_challenge, traveler_access, payment, payment_schedule, proposal; traveller scope: signature_request, otp_challenge, traveler_access, and the typed acceptance name of the proposals their links carried (accepted_name_enc := NULL); agency scope: agreement_doc) by AA-947 (crm-017) to the AA lines (trip, booking_line and agency scopes: aa_request; agency scope: inbox_events, booking_feed_state) by AA-949 (crm-019) to the proposal builder (trip and agency scopes: selection, option_rule, option, option_block, proposal_day) by AA-950 (crm-021) to crm.metric_event (trip and agency scopes) and by AA-951 (crm-022) to crm.prep_pack_selection (trip and agency scopes) and crm.message_template (agency scope): the only hard-delete path of agency data. Scopes trip, traveler (needs the decrypted F2 profile token), task, note, document, relation, booking_line, agency_supplier, conversation, tenant (status offboarding, except a dry run; every tenant table except the keep list). Used by the trash purge and by erasure / offboarding (which skip the trash). Refuses: CRM10 legal_hold (the hold rule: any held row among those the erase would delete or update, crm.erase_held), CRM11 delete_blocked, CRM12 traveler_on_trip, CRM13 subject_not_found, CRM14 tenant_not_offboarding, CRM15 profile token, CRM16 erase_incomplete, CRM22 the Adventure Asia supplier row, CRM27 a supplier lines name. Never touches audit_event. Takes LOCK TABLE crm.legal_hold IN SHARE MODE first (serialised with hold placement). EXECUTE: crm_eraser only (SET LOCAL ROLE inside the lifecycle context).';

-- ── Guard 1: the shape this file promises ────────────────────────────────────────────────────────
DO $$
DECLARE
    t text;
    r text;
    p text;
BEGIN
    FOREACH t IN ARRAY ARRAY['crm.prep_pack_selection', 'crm.message_template'] LOOP
        IF NOT (SELECT relrowsecurity AND relforcerowsecurity FROM pg_catalog.pg_class WHERE oid = t::regclass) THEN
            RAISE EXCEPTION 'crm-022: % must have ENABLE + FORCE row level security', t;
        END IF;
        FOREACH r IN ARRAY ARRAY['crm_ai_reader', 'crm_insights', 'crm_support_reader', 'crm_eraser'] LOOP
            FOREACH p IN ARRAY ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'] LOOP
                IF pg_catalog.has_table_privilege(r, t, p) THEN
                    RAISE EXCEPTION 'crm-022: reader % may % on %', r, p, t;
                END IF;
            END LOOP;
        END LOOP;
    END LOOP;
    IF pg_catalog.has_table_privilege('crm_app', 'crm.aa_content', 'DELETE')
       OR NOT pg_catalog.has_table_privilege('crm_app', 'crm.aa_content', 'UPDATE')
       OR NOT pg_catalog.has_table_privilege('crm_app', 'crm.aa_content', 'INSERT') THEN
        RAISE EXCEPTION 'crm-022: crm_app reads, inserts and updates crm.aa_content, never deletes';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_policy pol JOIN pg_catalog.pg_class c ON c.oid = pol.polrelid
               WHERE c.relnamespace = 'crm'::regnamespace AND 0 = ANY (pol.polroles)) THEN
        RAISE EXCEPTION 'crm-022: a crm policy applies TO PUBLIC (catalogue rule b); name the CRM roles';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger WHERE tgname = 'prep_pack_selection_draft_only'
                   AND tgrelid = 'crm.prep_pack_selection'::regclass) THEN
        RAISE EXCEPTION 'crm-022: crm.prep_pack_selection must change only in a draft (crm.guard_proposal_draft)';
    END IF;
    IF pg_catalog.has_function_privilege('crm_app', 'crm.erase_subject(text,uuid,uuid,boolean)', 'EXECUTE')
       OR NOT pg_catalog.has_function_privilege('crm_eraser', 'crm.erase_subject(text,uuid,uuid,boolean)', 'EXECUTE')
       OR pg_catalog.has_function_privilege('public', 'crm.erase_subject(text,uuid,uuid,boolean)', 'EXECUTE') THEN
        RAISE EXCEPTION 'crm-022: crm.erase_subject must be executable by crm_eraser only';
    END IF;
    -- Every table an earlier key taught erase_subject, and this key's.
    FOREACH t IN ARRAY ARRAY['prep_pack_selection', 'message_template', 'metric_event', 'selection', 'option_rule',
                             'option', 'option_block', 'proposal_day', 'aa_request', 'inbox_events',
                             'booking_feed_state', 'signature_request', 'otp_challenge', 'traveler_access', 'payment',
                             'payment_schedule', 'proposal', 'agreement_doc', 'message', 'conversation',
                             'saved_reply', 'mail_import', 'ingest_address', 'channel_account',
                             'booking_line_money', 'booking_line', 'agency_supplier', 'fx_rate_override',
                             'membership_inbox', 'client_link', 'meeting_slot'] LOOP
        IF position(quote_literal(t) IN (SELECT prosrc FROM pg_catalog.pg_proc
                     WHERE oid = 'crm.erase_subject(text,uuid,uuid,boolean)'::regprocedure)) = 0 THEN
            RAISE EXCEPTION 'crm-022: crm.erase_subject does not erase crm.%', t;
        END IF;
    END LOOP;
    IF position('accepted_name_erased_at' IN (SELECT prosrc FROM pg_catalog.pg_proc
                 WHERE oid = 'crm.erase_subject(text,uuid,uuid,boolean)'::regprocedure)) = 0 THEN
        RAISE EXCEPTION 'crm-022: crm.erase_subject lost the crm-016 typed acceptance name step';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-022', now(), 'AA-951: CRM-22 text proposal + Before you go (crm.aa_content platform cache of CIS prep packs and starter templates; crm.prep_pack_selection, the packs of a builder version, draft-only; crm.message_template, the agency template library; erase_subject + the two tenant tables)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
