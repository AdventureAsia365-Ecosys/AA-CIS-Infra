-- Migration crm-025: AA-955 CRM-25 Module 12 contracts and waivers (design v3 group E, M12, R34, R13 decline; §2.4
-- C-04 / C-08, §2.7 F6.3 / F8, §3.6 retention "claim-period exception", §5.7 e-sign) — e-sign v1 on top of the CRM-18
-- v0 tables (crm-016): versioned agreements with a third kind (the insurance declination), one signing envelope per
-- traveller (booking terms + waiver + insurance declination, merge fields rendered, sealed with the platform `seal`
-- key), per-adult signing with the lead signing as guardian for a minor, the booking-terms acceptance as its own record
-- pinned to the terms version and the `price_hash` (R34), and a signing event log (an expired code is refused AND
-- logged). The signed evidence (crm.terms_acceptance, crm.signature_event) is the DM-7 "signed agreements" class: it
-- outlives a trip or traveller erasure until trip end + 3 years (design Fix B16), then crm.lifecycle_purge_expired
-- deletes it; an agency offboarding takes it with everything else.
--
-- Owner: AA-Partner (api/migrations/025_crm_contracts_waivers.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- DB Migrate applies (Migration Copy Guard). Key crm-025. crm.erase_subject below is the crm-024 text plus this file's
-- changes; a later key that replaces it starts from THIS text. crm.lifecycle_purge_expired below is the crm-018 text
-- plus this file's two tables; a later key that replaces it starts from THIS text. crm.erase_held is unchanged: the
-- kept evidence is never deleted by a trip or traveller erase, and a guardian's signature of a minor carries the
-- minor's trip_id and traveler_id, so its hold guard (crm-016, trip_id + traveler_id) still refuses a held row.
-- crm.trip_delete_blockers is unchanged: a signature still writes its crm.trip_commitment row (kind signature).
--
-- What (DM-7: root data standards Part B §7, the "signed agreements" row, merged before the Infra copy):
--   1. crm.agreement_doc.kind + insurance_declination (R13: "I decline travel insurance", signed with the waiver).
--      The body may hold merge fields ({{agency.name}}, {{trip.title}}, {{trip.start_date}}, {{trip.end_date}},
--      {{signer.name}}, {{signer.role}}, {{signed.date}}); the API checks them at draft and renders them at signing.
--   2. crm.signature_request (crm-016) + the v1 envelope: signer_traveler_id (the adult who signs for a minor; NULL =
--      the traveller signs for themselves), signer_role self | guardian, access_traveler_id (generated: the traveller
--      whose portal access signed, so the crm-016 access key now names the signer), the booking terms and the
--      insurance declination versions in the envelope with their SHA-256 (terms_doc_id / terms_sha256,
--      declination_doc_id / declination_sha256), insurance_choice insured | declined, envelope_sha256 (SHA-256 of the
--      rendered, sealed envelope) and seal_alg. All sealed once signed (CRM31).
--   3. crm.terms_acceptance (append-only): one row per acceptance of a booking terms version: at the proposal accept
--      (source proposal), a re-accept after the agency published a newer version (source reaccept, design §2.11 E:
--      "terms updated after viewing -> re-accept before payment") and inside a signing envelope (source envelope).
--      Pinned: the version and its SHA-256, the proposal's price_hash (R34), the link, the SHA-256 of the typed name,
--      the client address and user agent (vault DEK), the canonical evidence record and its SHA-256, keep_until.
--      No foreign key to trip, proposal, traveller or link: the row outlives their erasure (claim-period exception).
--   4. crm.signature_event (append-only): the signing log: code_sent, code_refused (reason code_expired |
--      code_invalid | code_missing | attempts_exhausted; card R "an expired code is refused and logged"), signed (the
--      evidence record, the rendered envelope under the tenant docs DEK, its SHA-256, the seal: algorithm, key
--      reference, value; the client address and user agent under the vault DEK). Same no-foreign-key rule as 3.
--   5. RLS (ENABLE + FORCE, tenant_isolation TO the CRM roles), crm_app SELECT + INSERT only (crm.ledger_append_only:
--      UPDATE / TRUNCATE refused, DELETE only as crm_owner with app.erasing on), no reader grant.
--   6. crm.erase_subject (the crm-024 text): traveller scope also takes the signatures the traveller signed as a
--      guardian (signer_traveler_id); trip and traveller scopes KEEP terms_acceptance / signature_event and report
--      them in the receipt (terms_acceptance_kept, signature_event_kept); agency scope deletes both before
--      agreement_doc.
--   7. crm.lifecycle_purge_expired (the crm-018 text): + terms_acceptance and signature_event past keep_until whose
--      trip is gone or ended more than 3 years ago, never a held row.
--   SQLSTATE: none new (CRM41 stays the next key).
--
-- Class: contract (ADR 0017 §3: a widened CHECK, a replaced foreign key and sealed-row trigger on crm.signature_request,
-- replaced crm.erase_subject and crm.lifecycle_purge_expired), so no `-- migrate: expand` header: MIG-4 order, this
-- file's PR first, the Infra copy, a manual DB Migrate apply, then the code PR (adds crm-025 to
-- REQUIRED_SCHEMA_VERSIONS).
--
-- Order: after crm-024 (AA-952 invoices); Guard 0 refuses to run before it is registered (erase_subject builds on its
-- text).
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL. Idempotent (IF NOT EXISTS, DROP …
-- IF EXISTS, CREATE OR REPLACE, ON CONFLICT DO NOTHING). Rollback: a forward crm- file (MIG-14); the code before
-- AA-955 never reads the new tables or columns (their defaults describe a v0 signature: self, no envelope), so it runs
-- unchanged on this schema. Adding the generated column rewrites crm.signature_request (Dev: a few rows).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '15min';

-- ── Guard 0: runs as the owner, after crm-024 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-025: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-024') THEN
        RAISE EXCEPTION 'crm-025: crm-024 (AA-952 invoices and payments) lands first';
    END IF;
    IF to_regclass('crm.signature_request') IS NULL OR to_regclass('crm.agreement_doc') IS NULL
       OR to_regclass('crm.traveler_access') IS NULL OR to_regclass('crm.invoice') IS NULL
       OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint WHERE conrelid = 'crm.traveler_access'::regclass
                        AND contype IN ('u', 'p')
                        AND pg_catalog.pg_get_constraintdef(oid) LIKE '%(tenant_id, access_id, trip_id, traveler_id)%')
       OR to_regprocedure('crm.erase_rows(text,text,uuid,uuid,boolean,text)') IS NULL
       OR to_regprocedure('crm.ledger_append_only()') IS NULL OR to_regprocedure('crm.guard_sealed_row()') IS NULL
       OR to_regprocedure('crm.hold_row(uuid,uuid)') IS NULL
       OR to_regprocedure('crm.lifecycle_purge_expired(boolean)') IS NULL THEN
        RAISE EXCEPTION 'crm-025: crm.signature_request / agreement_doc / traveler_access key (crm-016), crm.invoice (crm-024), crm.erase_rows / hold_row (crm-010), crm.ledger_append_only (crm-014) or crm.lifecycle_purge_expired missing';
    END IF;
END $$;

-- ── 1. crm.agreement_doc: the insurance declination kind ─────────────────────────────────────────
ALTER TABLE crm.agreement_doc DROP CONSTRAINT IF EXISTS agreement_doc_kind_chk;
ALTER TABLE crm.agreement_doc ADD CONSTRAINT agreement_doc_kind_chk
    CHECK (kind IN ('booking_terms', 'waiver', 'insurance_declination'));
COMMENT ON COLUMN crm.agreement_doc.kind IS 'booking_terms (accepted with a proposal, R34; also in each signing envelope) | waiver (signed per traveller in the portal, M12) | insurance_declination (AA-955 crm-025, R13: signed in the same envelope by a traveller who declines travel insurance). One published version per kind. The body may hold the merge fields the API lists (app.proposals.agreements MERGE_FIELDS), rendered at signing';

-- ── 2. crm.signature_request: the v1 envelope ────────────────────────────────────────────────────
ALTER TABLE crm.signature_request
    ADD COLUMN IF NOT EXISTS signer_traveler_id UUID,
    ADD COLUMN IF NOT EXISTS signer_role TEXT NOT NULL DEFAULT 'self',
    ADD COLUMN IF NOT EXISTS terms_doc_id UUID,
    ADD COLUMN IF NOT EXISTS terms_sha256 BYTEA,
    ADD COLUMN IF NOT EXISTS declination_doc_id UUID,
    ADD COLUMN IF NOT EXISTS declination_sha256 BYTEA,
    ADD COLUMN IF NOT EXISTS insurance_choice TEXT,
    ADD COLUMN IF NOT EXISTS envelope_sha256 BYTEA,
    ADD COLUMN IF NOT EXISTS seal_alg TEXT;
ALTER TABLE crm.signature_request
    ADD COLUMN IF NOT EXISTS access_traveler_id UUID GENERATED ALWAYS AS (coalesce(signer_traveler_id, traveler_id)) STORED;
-- The crm-016 key named the traveller's own access; a guardian signs from their own access for the minor.
ALTER TABLE crm.signature_request DROP CONSTRAINT IF EXISTS signature_request_access_fk;
ALTER TABLE crm.signature_request ADD CONSTRAINT signature_request_access_fk
    FOREIGN KEY (tenant_id, access_id, trip_id, access_traveler_id)
    REFERENCES crm.traveler_access (tenant_id, access_id, trip_id, traveler_id);
ALTER TABLE crm.signature_request DROP CONSTRAINT IF EXISTS signature_request_terms_fk;
ALTER TABLE crm.signature_request ADD CONSTRAINT signature_request_terms_fk
    FOREIGN KEY (tenant_id, terms_doc_id) REFERENCES crm.agreement_doc (tenant_id, doc_id);
ALTER TABLE crm.signature_request DROP CONSTRAINT IF EXISTS signature_request_declination_fk;
ALTER TABLE crm.signature_request ADD CONSTRAINT signature_request_declination_fk
    FOREIGN KEY (tenant_id, declination_doc_id) REFERENCES crm.agreement_doc (tenant_id, doc_id);
ALTER TABLE crm.signature_request DROP CONSTRAINT IF EXISTS signature_request_signer_chk;
ALTER TABLE crm.signature_request ADD CONSTRAINT signature_request_signer_chk CHECK (
    signer_role IN ('self', 'guardian')
    AND (signer_role = 'guardian') = (signer_traveler_id IS NOT NULL)
    AND signer_traveler_id IS DISTINCT FROM traveler_id
);
ALTER TABLE crm.signature_request DROP CONSTRAINT IF EXISTS signature_request_envelope_chk;
ALTER TABLE crm.signature_request ADD CONSTRAINT signature_request_envelope_chk CHECK (
    (terms_doc_id IS NULL) = (terms_sha256 IS NULL)
    AND (declination_doc_id IS NULL) = (declination_sha256 IS NULL)
    AND coalesce(octet_length(terms_sha256), 32) = 32 AND coalesce(octet_length(declination_sha256), 32) = 32
    AND coalesce(octet_length(envelope_sha256), 32) = 32
    AND (insurance_choice IS NULL OR insurance_choice IN ('insured', 'declined'))
    -- R13: a declination version is in the envelope exactly when the traveller declined.
    AND (declination_doc_id IS NOT NULL) = (insurance_choice IS NOT DISTINCT FROM 'declined')
    AND (envelope_sha256 IS NULL) = (seal_alg IS NULL)
    AND (envelope_sha256 IS NULL OR status = 'signed')
    AND (seal_alg IS NULL OR seal_alg IN ('kms-rsassa-pss-sha256', 'dev-stub-hmac-sha256'))
);
CREATE INDEX IF NOT EXISTS signature_request_signer_idx ON crm.signature_request (tenant_id, signer_traveler_id)
    WHERE signer_traveler_id IS NOT NULL;
COMMENT ON COLUMN crm.signature_request.signer_traveler_id IS 'AA-955 (crm-025, O-6): the adult who signed for this traveller (the lead, as guardian of a minor: under 18 on the trip start date); NULL = the traveller signed for themselves. The signature still counts for traveler_id (the waiver gate is per traveller)';
COMMENT ON COLUMN crm.signature_request.access_traveler_id IS 'AA-955 (crm-025): generated, coalesce(signer_traveler_id, traveler_id): the traveller whose portal access (access_id) signed; the access key signature_request_access_fk names it';
COMMENT ON COLUMN crm.signature_request.envelope_sha256 IS 'AA-955 (crm-025, e-sign v1): SHA-256 of the rendered envelope exactly as sealed (booking terms, waiver, insurance declination with merge fields filled in, then the audit page); the envelope itself and its seal are on the crm.signature_event row kind signed; NULL on a v0 signature';
COMMENT ON COLUMN crm.signature_request.seal_alg IS 'AA-955 (crm-025): kms-rsassa-pss-sha256 (the platform seal key alias/crm-<env>/seal) | dev-stub-hmac-sha256 (dev / test / local without a seal key: not a legal seal)';
COMMENT ON COLUMN crm.signature_request.insurance_choice IS 'AA-955 (crm-025, R13): insured | declined (then declination_doc_id / declination_sha256 name the signed declination) | NULL when the agency publishes no insurance declination';
DROP TRIGGER IF EXISTS signature_request_sealed ON crm.signature_request;
CREATE TRIGGER signature_request_sealed BEFORE UPDATE ON crm.signature_request FOR EACH ROW
    EXECUTE FUNCTION crm.guard_sealed_row('pending', 'trip_id', 'traveler_id', 'access_id', 'doc_id', 'doc_sha256',
                                          'signed_at', 'signed_name_enc', 'code_delivery', 'evidence_record',
                                          'evidence_sha256', 'signer_traveler_id', 'signer_role', 'terms_doc_id',
                                          'terms_sha256', 'declination_doc_id', 'declination_sha256',
                                          'insurance_choice', 'envelope_sha256', 'seal_alg', 'tenant_id');

-- ── 3. crm.terms_acceptance ──────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.terms_acceptance (
    acceptance_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id         UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                      REFERENCES crm.tenant (tenant_id),
    -- No foreign key on the trip, proposal, traveller or link ids (claim-period exception: the row outlives them).
    trip_id           UUID NOT NULL,
    proposal_id       UUID,
    traveler_id       UUID,
    link_id           UUID,
    request_id        UUID,
    source            TEXT NOT NULL,
    doc_id            UUID NOT NULL,
    doc_sha256        BYTEA NOT NULL,
    price_hash        BYTEA,
    typed_name_sha256 BYTEA NOT NULL,
    client_ip_enc     BYTEA,
    user_agent_enc    BYTEA,
    evidence_record   BYTEA NOT NULL,
    evidence_sha256   BYTEA NOT NULL,
    accepted_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    keep_until        DATE NOT NULL,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by        TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    CONSTRAINT terms_acceptance_tenant_id_uq UNIQUE (tenant_id, acceptance_id),
    CONSTRAINT terms_acceptance_doc_fk FOREIGN KEY (tenant_id, doc_id) REFERENCES crm.agreement_doc (tenant_id, doc_id),
    CONSTRAINT terms_acceptance_source_chk CHECK (source IN ('proposal', 'reaccept', 'envelope')),
    CONSTRAINT terms_acceptance_subject_chk CHECK (
        (source = 'envelope') = (request_id IS NOT NULL)
        AND (source = 'envelope' OR proposal_id IS NOT NULL)
    ),
    CONSTRAINT terms_acceptance_hash_chk CHECK (
        octet_length(doc_sha256) = 32 AND coalesce(octet_length(price_hash), 32) = 32
        AND octet_length(typed_name_sha256) = 32
        AND coalesce(octet_length(client_ip_enc), 30) >= 30 AND coalesce(octet_length(user_agent_enc), 30) >= 30
    ),
    CONSTRAINT terms_acceptance_evidence_chk CHECK (
        octet_length(evidence_record) BETWEEN 2 AND 4096 AND sha256(evidence_record) = evidence_sha256
    ),
    CONSTRAINT terms_acceptance_keep_chk CHECK (keep_until >= accepted_at::date)
);
CREATE INDEX IF NOT EXISTS terms_acceptance_trip_idx ON crm.terms_acceptance (tenant_id, trip_id, accepted_at DESC);
CREATE INDEX IF NOT EXISTS terms_acceptance_keep_idx ON crm.terms_acceptance (keep_until);
COMMENT ON TABLE crm.terms_acceptance IS 'AA-955 (crm-025; design v3 group E, M12, R34): one acceptance of one booking terms version: at the proposal accept (source proposal, the proposal''s price_hash), a re-accept of a newer published version before the deposit (source reaccept, design §2.11 E), or inside a signing envelope (source envelope, request_id). Pinned: the version and its SHA-256, the price_hash, the link, the SHA-256 of the typed name, the client address and user agent (vault DEK), the canonical evidence record (ids, hashes, time; no PII) and its SHA-256. Append-only (crm.ledger_append_only). No foreign key on trip / proposal / traveller / link: DM-7 claim-period exception (design Fix B16): kept through a trip or traveller erasure until keep_until (trip end + 3 years, est.; counsel confirms), then crm.lifecycle_purge_expired deletes it; offboarding (agency scope) deletes it.';
COMMENT ON COLUMN crm.terms_acceptance.client_ip_enc IS 'pii:online_id; the client address the acceptance came from (the API''s client_address), AES-256-GCM under the tenant vault DEK; its SHA-256 is in the evidence record';
COMMENT ON COLUMN crm.terms_acceptance.user_agent_enc IS 'pii:online_id; the browser user agent (at most 400 characters), AES-256-GCM under the tenant vault DEK; its SHA-256 is in the evidence record';
COMMENT ON COLUMN crm.terms_acceptance.keep_until IS 'the end of the claim period: the trip end (else start, else the day of acceptance) + 3 years, set at write; crm.lifecycle_purge_expired also keeps a row while its trip ends less than 3 years ago';

-- ── 4. crm.signature_event ───────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.signature_event (
    event_id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id          UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                       REFERENCES crm.tenant (tenant_id),
    -- No foreign key on the request, trip, traveller or access ids (claim-period exception, as crm.terms_acceptance).
    request_id         UUID,
    trip_id            UUID NOT NULL,
    traveler_id        UUID NOT NULL,
    signer_traveler_id UUID,
    access_id          UUID NOT NULL,
    kind               TEXT NOT NULL,
    reason             TEXT,
    evidence_record    BYTEA,
    evidence_sha256    BYTEA,
    envelope_enc       BYTEA,
    envelope_sha256    BYTEA,
    seal_alg           TEXT,
    seal_key_ref       TEXT,
    seal_value         BYTEA,
    client_ip_enc      BYTEA,
    user_agent_enc     BYTEA,
    occurred_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    keep_until         DATE NOT NULL,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by         TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    CONSTRAINT signature_event_tenant_id_uq UNIQUE (tenant_id, event_id),
    CONSTRAINT signature_event_kind_chk CHECK (kind IN ('code_sent', 'code_refused', 'signed')),
    CONSTRAINT signature_event_reason_chk CHECK (
        (kind = 'code_refused') = (reason IS NOT NULL)
        AND (reason IS NULL OR reason IN ('code_expired', 'code_invalid', 'code_missing', 'attempts_exhausted'))
    ),
    CONSTRAINT signature_event_signed_chk CHECK (
        (kind = 'signed') = (request_id IS NOT NULL AND evidence_record IS NOT NULL AND envelope_enc IS NOT NULL
                             AND envelope_sha256 IS NOT NULL AND seal_alg IS NOT NULL AND seal_value IS NOT NULL)
        AND (evidence_record IS NULL) = (evidence_sha256 IS NULL)
        AND (envelope_enc IS NULL) = (envelope_sha256 IS NULL)
        AND (seal_alg IS NULL) = (seal_value IS NULL)
        AND (seal_alg IS NULL) = (seal_key_ref IS NULL)
    ),
    CONSTRAINT signature_event_hash_chk CHECK (
        coalesce(octet_length(envelope_sha256), 32) = 32
        AND coalesce(octet_length(envelope_enc), 30) BETWEEN 30 AND 2097152
        AND (evidence_record IS NULL
             OR (octet_length(evidence_record) BETWEEN 2 AND 4096 AND sha256(evidence_record) = evidence_sha256))
        AND (seal_alg IS NULL OR seal_alg IN ('kms-rsassa-pss-sha256', 'dev-stub-hmac-sha256'))
        AND coalesce(octet_length(seal_value), 32) BETWEEN 32 AND 1024
        AND coalesce(length(seal_key_ref), 1) BETWEEN 1 AND 300
        AND coalesce(octet_length(client_ip_enc), 30) >= 30 AND coalesce(octet_length(user_agent_enc), 30) >= 30
    ),
    CONSTRAINT signature_event_keep_chk CHECK (keep_until >= occurred_at::date)
);
CREATE INDEX IF NOT EXISTS signature_event_trip_idx ON crm.signature_event (tenant_id, trip_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS signature_event_request_idx ON crm.signature_event (tenant_id, request_id)
    WHERE request_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS signature_event_keep_idx ON crm.signature_event (keep_until);
COMMENT ON TABLE crm.signature_event IS 'AA-955 (crm-025; design v3 group E, M12, §5.7): the signing log of one traveller''s envelope: code_sent (a signing code went out), code_refused (reason code_expired | code_invalid | code_missing | attempts_exhausted: card R, an expired code is refused and logged), signed (the canonical evidence record and its SHA-256, the rendered envelope under the tenant docs DEK and its SHA-256, the platform seal: algorithm, key reference, value over the envelope SHA-256; the client address and user agent under the vault DEK). Append-only (crm.ledger_append_only). No foreign key on request / trip / traveller / access: DM-7 claim-period exception (design Fix B16): kept through a trip or traveller erasure until keep_until (trip end + 3 years, est.), then crm.lifecycle_purge_expired deletes it; offboarding (agency scope) deletes it.';
COMMENT ON COLUMN crm.signature_event.envelope_enc IS 'pii:name; the rendered envelope exactly as sealed (UTF-8 text: the documents with merge fields filled in, the typed name, then the audit page), AES-256-GCM under the tenant docs DEK (AAD = signature_event, envelope, event id); at most 2 MiB';
COMMENT ON COLUMN crm.signature_event.seal_value IS 'the seal over envelope_sha256: RSASSA-PSS SHA-256 by the KMS key seal_key_ref (kms-rsassa-pss-sha256; verify with kms:Verify or its public key) or an HMAC-SHA256 dev stub (dev-stub-hmac-sha256, not a legal seal)';
COMMENT ON COLUMN crm.signature_event.client_ip_enc IS 'pii:online_id; the client address of the signing, AES-256-GCM under the tenant vault DEK; its SHA-256 is in the evidence record';
COMMENT ON COLUMN crm.signature_event.user_agent_enc IS 'pii:online_id; the browser user agent of the signing (at most 400 characters), AES-256-GCM under the tenant vault DEK; its SHA-256 is in the evidence record';

-- ── 5. RLS, grants and the append-only rule on the new tables ────────────────────────────────────
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['terms_acceptance', 'signature_event'] LOOP
        EXECUTE format('ALTER TABLE crm.%I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE crm.%I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON crm.%I', t);
        EXECUTE format(
            'CREATE POLICY tenant_isolation ON crm.%I '
            'TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser '
            'USING (tenant_id = NULLIF(current_setting(''app.tenant_id'', true), '''')::uuid) '
            'WITH CHECK (tenant_id = NULLIF(current_setting(''app.tenant_id'', true), '''')::uuid)', t);
        -- Append-only: crm_app reads and inserts; DELETE only inside crm.erase_subject (agency scope) and
        -- crm.lifecycle_purge_expired (past keep_until), as crm_owner with app.erasing on.
        EXECUTE format('REVOKE UPDATE, DELETE, TRUNCATE ON crm.%I FROM crm_app', t);
        EXECUTE format('GRANT SELECT, INSERT ON crm.%I TO crm_app', t);
        EXECUTE format('CREATE OR REPLACE TRIGGER %I BEFORE UPDATE OR DELETE ON crm.%I FOR EACH ROW '
                       'EXECUTE FUNCTION crm.ledger_append_only()', t || '_append_only', t);
        EXECUTE format('CREATE OR REPLACE TRIGGER %I BEFORE TRUNCATE ON crm.%I FOR EACH STATEMENT '
                       'EXECUTE FUNCTION crm.ledger_append_only()', t || '_no_truncate', t);
    END LOOP;
END $$;

-- ── 6. crm.erase_subject: the crm-024 text plus the signed evidence ───────────────────────────────
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

COMMENT ON FUNCTION crm.erase_subject(text, uuid, uuid, boolean) IS 'AA-942 (crm-010, design §4.10, Fix B16), extended by AA-943 (crm-012) to client_link and meeting_slot, by AA-978 (crm-013) to membership_inbox (agency scope), by AA-944 (crm-014) to the ledger (trip and agency scopes: booking_line_money, booking_line; agency scope: agency_supplier, fx_rate_override; new scopes booking_line and agency_supplier for the trash purge), by AA-945 (crm-015) to mail (trip, traveller and agency scopes: message, conversation; agency scope: saved_reply, mail_import, ingest_address, channel_account; new scope conversation for the trash purge), by AA-946 (crm-016) to the lifecycle tables (trip and agency scopes: signature_request, otp_challenge, traveler_access, payment, payment_schedule, proposal; traveller scope: signature_request, otp_challenge, traveler_access, and the typed acceptance name of the proposals their links carried (accepted_name_enc := NULL); agency scope: agreement_doc) by AA-947 (crm-017) to the AA lines (trip, booking_line and agency scopes: aa_request; agency scope: inbox_events, booking_feed_state) by AA-949 (crm-019) to the proposal builder (trip and agency scopes: selection, option_rule, option, option_block, proposal_day) by AA-950 (crm-021) to crm.metric_event (trip and agency scopes) by AA-951 (crm-022) to crm.prep_pack_selection (trip and agency scopes) and crm.message_template (agency scope) by AA-993 G4b (crm-023) to crm.dispatch_attempt (trip, traveller and agency scopes, before crm.dispatch_queue) and by AA-952 (crm-024) to the invoices and payments (trip and agency scopes: crm.refund_request before crm.payment, crm.invoice_line and crm.invoice after it and before crm.payment_schedule; agency scope: crm.payment_provider_account, crm.invoice_sequence) and by AA-955 (crm-025) to the signed evidence (agency scope: crm.terms_acceptance, crm.signature_event; trip and traveller scopes KEEP them, DM-7 claim-period exception, and count them as terms_acceptance_kept / signature_event_kept; traveller scope also erases the signatures the traveller signed as a guardian): the only hard-delete path of agency data. Scopes trip, traveler (needs the decrypted F2 profile token), task, note, document, relation, booking_line, agency_supplier, conversation, tenant (status offboarding, except a dry run; every tenant table except the keep list). Used by the trash purge and by erasure / offboarding (which skip the trash). Refuses: CRM10 legal_hold (the hold rule: any held row among those the erase would delete or update, crm.erase_held), CRM11 delete_blocked, CRM12 traveler_on_trip, CRM13 subject_not_found, CRM14 tenant_not_offboarding, CRM15 profile token, CRM16 erase_incomplete, CRM22 the Adventure Asia supplier row, CRM27 a supplier lines name. Never touches audit_event. Takes LOCK TABLE crm.legal_hold IN SHARE MODE first (serialised with hold placement). EXECUTE: crm_eraser only (SET LOCAL ROLE inside the lifecycle context).';


-- ── 7. crm.lifecycle_purge_expired: the crm-018 text plus the signed evidence ──────────────────────
CREATE OR REPLACE FUNCTION crm.lifecycle_purge_expired(p_dry_run boolean DEFAULT true) RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_tenant uuid := NULLIF(current_setting('app.tenant_id', true), '')::uuid;
    n bigint;
    m bigint := 0;
    i bigint;
    ta bigint;
    se bigint;
BEGIN
    IF v_tenant IS NULL OR p_dry_run IS NULL THEN
        RAISE EXCEPTION 'crm: lifecycle_purge_expired needs app.tenant_id and dry_run'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    LOCK TABLE crm.legal_hold IN SHARE MODE;  -- hold rule 4g
    -- llm_call and membership_inbox name no trip or traveller: the agency hold only (4c, 4f).
    IF crm.hold_row(NULL, NULL) THEN
        RETURN jsonb_build_object('llm_call', 0, 'placeholder_map', 0, 'membership_inbox', 0, 'terms_acceptance', 0,
                                  'signature_event', 0, 'held', 1);
    END IF;
    IF NOT p_dry_run THEN
        PERFORM set_config('app.erasing', 'on', true);
    END IF;
    -- crm-009 placeholder_map_call_fk: a map of a call this purge deletes goes first (a 24 h map the hourly
    -- crm_placeholder_purge has not removed yet). Skipped while crm-009 is not applied (crm-010 may land first).
    IF to_regclass('crm.placeholder_map') IS NOT NULL THEN
        m := crm.erase_rows('placeholder_map',
                            'llm_call_id IN (SELECT l.llm_call_id FROM crm.llm_call l '
                            'WHERE l.at < now() - interval ''180 days'')',
                            NULL, NULL, p_dry_run);
    END IF;
    n := crm.erase_rows('llm_call', 'at < now() - interval ''180 days''', NULL, NULL, p_dry_run);
    -- crm-018: the CIS membership events this agency received more than 90 days ago (DM-7; created_at = received).
    i := crm.erase_rows('membership_inbox', 'created_at < now() - interval ''90 days''', NULL, NULL, p_dry_run);
    -- crm-025: the signed evidence past its claim period (DM-7, design Fix B16): keep_until passed, and its trip is
    -- gone or ended (else started) more than 3 years ago (a trip moved later keeps its evidence longer); never a row
    -- under a trip or traveller hold.
    ta := crm.erase_rows('terms_acceptance',
                         'keep_until < current_date AND NOT crm.hold_row(trip_id, traveler_id) AND NOT EXISTS ('
                         'SELECT 1 FROM crm.trip t WHERE t.trip_id = terms_acceptance.trip_id '
                         'AND coalesce(t.end_date, t.start_date, current_date) + interval ''3 years'' >= current_date)',
                         NULL, NULL, p_dry_run);
    se := crm.erase_rows('signature_event',
                         'keep_until < current_date AND NOT crm.hold_row(trip_id, traveler_id) AND NOT EXISTS ('
                         'SELECT 1 FROM crm.trip t WHERE t.trip_id = signature_event.trip_id '
                         'AND coalesce(t.end_date, t.start_date, current_date) + interval ''3 years'' >= current_date)',
                         NULL, NULL, p_dry_run);
    IF NOT p_dry_run THEN
        PERFORM set_config('app.erasing', '', true);
    END IF;
    RETURN jsonb_build_object('llm_call', n, 'placeholder_map', m, 'membership_inbox', i, 'terms_acceptance', ta,
                              'signature_event', se, 'held', 0);
END;
$$;
REVOKE ALL ON FUNCTION crm.lifecycle_purge_expired(boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.lifecycle_purge_expired(boolean) TO crm_eraser;
COMMENT ON FUNCTION crm.lifecycle_purge_expired(boolean) IS 'AA-942 (crm-010, design §3.6) + AA-978 (crm-018, DM-7) + AA-955 (crm-025, DM-7 claim-period exception): deletes the agency''s crm.llm_call rows older than 180 days (crm.llm_usage_daily keeps the rollup), first the crm-009 placeholder maps of those calls, its crm.membership_inbox rows received more than 90 days ago, and its signed evidence (crm.terms_acceptance, crm.signature_event) past keep_until whose trip is gone or ended more than 3 years ago; nothing under an agency legal hold, no evidence row under a trip or traveller hold. Dry run counts only. Returns {llm_call, placeholder_map, membership_inbox, terms_acceptance, signature_event, held}. EXECUTE: crm_eraser only.';

-- ── Guard 1: the shape this file promises ────────────────────────────────────────────────────────
DO $$
DECLARE
    t text;
    r text;
    p text;
    src text;
BEGIN
    FOREACH t IN ARRAY ARRAY['terms_acceptance', 'signature_event'] LOOP
        IF NOT (SELECT relrowsecurity AND relforcerowsecurity FROM pg_catalog.pg_class
                 WHERE oid = ('crm.' || t)::regclass) THEN
            RAISE EXCEPTION 'crm-025: crm.% must have ENABLE + FORCE row level security', t;
        END IF;
        FOREACH r IN ARRAY ARRAY['crm_ai_reader', 'crm_insights', 'crm_support_reader', 'crm_eraser'] LOOP
            FOREACH p IN ARRAY ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'] LOOP
                IF pg_catalog.has_table_privilege(r, 'crm.' || t, p) THEN
                    RAISE EXCEPTION 'crm-025: reader % may % on crm.%', r, p, t;
                END IF;
            END LOOP;
        END LOOP;
        IF pg_catalog.has_table_privilege('crm_app', 'crm.' || t, 'UPDATE')
           OR pg_catalog.has_table_privilege('crm_app', 'crm.' || t, 'DELETE')
           OR pg_catalog.has_table_privilege('crm_app', 'crm.' || t, 'TRUNCATE')
           OR NOT pg_catalog.has_table_privilege('crm_app', 'crm.' || t, 'INSERT')
           OR NOT pg_catalog.has_table_privilege('crm_app', 'crm.' || t, 'SELECT') THEN
            RAISE EXCEPTION 'crm-025: crm_app only reads and inserts crm.% (append-only)', t;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger WHERE tgname = t || '_append_only'
                       AND tgrelid = ('crm.' || t)::regclass) THEN
            RAISE EXCEPTION 'crm-025: crm.% lost its append-only trigger', t;
        END IF;
        -- The claim-period exception: no foreign key reaches the trip, proposal, traveller, link or request.
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_constraint WHERE conrelid = ('crm.' || t)::regclass AND contype = 'f'
                   AND confrelid NOT IN ('crm.tenant'::regclass, 'crm.agreement_doc'::regclass)) THEN
            RAISE EXCEPTION 'crm-025: crm.% must not reference a trip, traveller or request (it outlives them)', t;
        END IF;
    END LOOP;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger WHERE tgname = 'signature_request_sealed'
                   AND tgrelid = 'crm.signature_request'::regclass
                   AND position('envelope_sha256' IN pg_catalog.pg_get_triggerdef(oid)) > 0) THEN
        RAISE EXCEPTION 'crm-025: crm.signature_request_sealed must seal the v1 envelope columns';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_policy pol JOIN pg_catalog.pg_class c ON c.oid = pol.polrelid
               WHERE c.relnamespace = 'crm'::regnamespace AND 0 = ANY (pol.polroles)) THEN
        RAISE EXCEPTION 'crm-025: a crm policy applies TO PUBLIC (catalogue rule b); name the CRM roles';
    END IF;
    IF pg_catalog.has_function_privilege('crm_app', 'crm.erase_subject(text,uuid,uuid,boolean)', 'EXECUTE')
       OR NOT pg_catalog.has_function_privilege('crm_eraser', 'crm.erase_subject(text,uuid,uuid,boolean)', 'EXECUTE')
       OR pg_catalog.has_function_privilege('public', 'crm.erase_subject(text,uuid,uuid,boolean)', 'EXECUTE') THEN
        RAISE EXCEPTION 'crm-025: crm.erase_subject must be executable by crm_eraser only';
    END IF;
    IF pg_catalog.has_function_privilege('crm_app', 'crm.lifecycle_purge_expired(boolean)', 'EXECUTE')
       OR pg_catalog.has_function_privilege('public', 'crm.lifecycle_purge_expired(boolean)', 'EXECUTE')
       OR NOT pg_catalog.has_function_privilege('crm_eraser', 'crm.lifecycle_purge_expired(boolean)', 'EXECUTE')
       OR NOT (SELECT prosecdef FROM pg_catalog.pg_proc
                WHERE oid = 'crm.lifecycle_purge_expired(boolean)'::regprocedure) THEN
        RAISE EXCEPTION 'crm-025: crm.lifecycle_purge_expired must stay SECURITY DEFINER, executable by crm_eraser only';
    END IF;
    SELECT prosrc INTO src FROM pg_catalog.pg_proc WHERE oid = 'crm.lifecycle_purge_expired(boolean)'::regprocedure;
    IF position('''membership_inbox''' IN src) = 0 OR position('''terms_acceptance''' IN src) = 0
       OR position('''signature_event''' IN src) = 0 THEN
        RAISE EXCEPTION 'crm-025: crm.lifecycle_purge_expired lost a table (membership_inbox, terms_acceptance, signature_event)';
    END IF;
    SELECT prosrc INTO src FROM pg_catalog.pg_proc WHERE oid = 'crm.erase_subject(text,uuid,uuid,boolean)'::regprocedure;
    -- Every table an earlier key taught erase_subject, and this key's.
    FOREACH t IN ARRAY ARRAY['terms_acceptance', 'signature_event', 'refund_request', 'invoice_line', 'invoice',
                             'payment_provider_account', 'invoice_sequence', 'dispatch_attempt', 'dispatch_queue',
                             'prep_pack_selection', 'message_template', 'metric_event', 'selection', 'option_rule',
                             'option', 'option_block', 'proposal_day', 'aa_request', 'inbox_events',
                             'booking_feed_state', 'signature_request', 'otp_challenge', 'traveler_access', 'payment',
                             'payment_schedule', 'proposal', 'agreement_doc', 'message', 'conversation', 'saved_reply',
                             'mail_import', 'ingest_address', 'channel_account', 'booking_line_money', 'booking_line',
                             'agency_supplier', 'fx_rate_override', 'membership_inbox', 'client_link',
                             'meeting_slot'] LOOP
        IF position(quote_literal(t) IN src) = 0 THEN
            RAISE EXCEPTION 'crm-025: crm.erase_subject does not erase crm.%', t;
        END IF;
    END LOOP;
    IF position('accepted_name_erased_at' IN src) = 0 OR position('signer_traveler_id = $1' IN src) = 0
       OR position('signature_event_kept' IN src) = 0 THEN
        RAISE EXCEPTION 'crm-025: crm.erase_subject lost the typed acceptance name step, the guardian signatures or the kept-evidence receipt';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-025', now(), 'AA-955 CRM-25 Module 12 e-sign v1: agreement kind insurance_declination, crm.signature_request envelope (guardian signer, terms + declination versions, envelope hash, seal), crm.terms_acceptance and crm.signature_event (append-only, DM-7 claim-period exception: kept through trip / traveller erasure, purged after trip end + 3 years), erase_subject + lifecycle_purge_expired')
ON CONFLICT (version) DO NOTHING;

COMMIT;
