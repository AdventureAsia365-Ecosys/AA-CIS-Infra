-- Migration crm-055: AA-1070 (S275 study of a tour and travel app, root docs/research/2026-11-10-odoo-tour-travel-
-- plugin-comparison.md, items crm-15, crm-16 and crm-21; behaviour only, no plugin code) — the changes to existing
-- objects the travel ops of crm-054 need.
--
-- Owner: AA-Partner (api/migrations/055_crm_travel_ops_settings.sql). AA-CIS-Infra db/migrations/crm/ holds the byte
-- copy DB Migrate applies (Migration Copy Guard). Key crm-055: crm-054 (the travel ops tables, expand) comes first; if
-- main moves, renumber: file name, this header, Guard 0 and the registration below, app/db.py
-- REQUIRED_SCHEMA_VERSIONS and the tests that name it (git grep '055_' and 'crm-055').
--
-- What:
--   1. crm.tenant_settings.passport_valid_months (SMALLINT NOT NULL DEFAULT 6, 0..24): a traveller's passport must
--      be valid until the trip's end date plus this many months (item crm-15; the common entry rule of the region is
--      six months). The Stage 3 passport check reads it; the owner changes it in Settings.
--   2. crm.document: kinds + confirmation_pdf and proposal_pdf (item crm-21: the server-side PDFs of the trip
--      confirmation and the proposal; invoice_pdf and voucher exist), uploader + system (a PDF the crm_pdf_render job
--      wrote on a member's request). The two CHECKs are widened, nothing else changes (a passport scan is still the
--      only write-only kind).
--   3. crm.status_transition rows of crm.visa_application (crm-054): to_do -> collecting | submitted | not_needed |
--      cancelled; collecting -> to_do | submitted | not_needed | cancelled; submitted -> approved | refused |
--      collecting | cancelled; refused -> collecting | cancelled; not_needed -> to_do; approved -> cancelled (the trip
--      is cancelled or the visa is given up; the record stays).
--
-- Behaviour on apply: none. Every agency reads 6 months (the default the API used before has none: the check is new);
-- no document has a new kind and no application exists until the AA-Partner code PR deploys.
--
-- Class: contract (ALTER of crm.tenant_settings and two widened CHECKs on crm.document, config rows in
-- crm.status_transition). MIG-4: this migration-only PR (batch crm 054-055), then the code PR once both are applied
-- on Dev. DM-7.1: no new table (the column follows the settings row). No crm.erase_subject change.
--
-- Rollback (a NEW forward migration, after the code is reverted): DELETE FROM crm.status_transition WHERE table_name =
-- 'visa_application'; put back the crm-006 document kind and uploader CHECKs (after the rows of the new values are
-- deleted or re-kinded 'other' / 'member'); ALTER TABLE crm.tenant_settings DROP COLUMN passport_valid_months.
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL. Re-runnable (IF NOT EXISTS, DROP …
-- IF EXISTS before each ADD, ON CONFLICT DO NOTHING).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '5min';

-- ── Guard 0: runs as the owner, after crm-054 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-055: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-054') THEN
        RAISE EXCEPTION 'crm-055: crm-054 (AA-1070 travel ops tables) lands first';
    END IF;
    IF to_regclass('crm.tenant_settings') IS NULL OR to_regclass('crm.document') IS NULL
       OR to_regclass('crm.visa_application') IS NULL OR to_regclass('crm.status_transition') IS NULL THEN
        RAISE EXCEPTION 'crm-055: crm.tenant_settings, crm.document, crm.visa_application or crm.status_transition is missing';
    END IF;
END $$;

-- ── 1. crm.tenant_settings.passport_valid_months ─────────────────────────────────────────────────
ALTER TABLE crm.tenant_settings ADD COLUMN IF NOT EXISTS passport_valid_months SMALLINT NOT NULL DEFAULT 6;
ALTER TABLE crm.tenant_settings DROP CONSTRAINT IF EXISTS tenant_settings_passport_valid_chk;
ALTER TABLE crm.tenant_settings ADD CONSTRAINT tenant_settings_passport_valid_chk
    CHECK (passport_valid_months BETWEEN 0 AND 24);
COMMENT ON COLUMN crm.tenant_settings.passport_valid_months IS 'AA-1070 (crm-055, item crm-15): a traveller''s passport must be valid until the trip''s end date plus this many months (0..24, default 6); the Stage 3 passport check, the trip party badge, the pipeline filter and the passport task read it';

-- ── 2. crm.document: two PDF kinds, the system uploader ──────────────────────────────────────────
ALTER TABLE crm.document DROP CONSTRAINT IF EXISTS document_kind_chk;
ALTER TABLE crm.document ADD CONSTRAINT document_kind_chk CHECK (
    kind IN ('passport_scan', 'waiver_pdf', 'terms_pdf', 'ticket', 'voucher', 'invoice_pdf', 'supplier_confirmation',
             'other', 'confirmation_pdf', 'proposal_pdf')
);
ALTER TABLE crm.document DROP CONSTRAINT IF EXISTS document_uploader_chk;
ALTER TABLE crm.document ADD CONSTRAINT document_uploader_chk CHECK (
    uploaded_by_kind IN ('member', 'traveler', 'aa_booking', 'mail', 'system')
);

-- ── 3. crm.status_transition rows of crm.visa_application ────────────────────────────────────────
INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('visa_application', 'to_do', 'collecting'),
    ('visa_application', 'to_do', 'submitted'),
    ('visa_application', 'to_do', 'not_needed'),
    ('visa_application', 'to_do', 'cancelled'),
    ('visa_application', 'collecting', 'to_do'),
    ('visa_application', 'collecting', 'submitted'),
    ('visa_application', 'collecting', 'not_needed'),
    ('visa_application', 'collecting', 'cancelled'),
    ('visa_application', 'submitted', 'approved'),
    ('visa_application', 'submitted', 'refused'),
    ('visa_application', 'submitted', 'collecting'),
    ('visa_application', 'submitted', 'cancelled'),
    ('visa_application', 'refused', 'collecting'),
    ('visa_application', 'refused', 'cancelled'),
    ('visa_application', 'not_needed', 'to_do'),
    ('visa_application', 'approved', 'cancelled')
ON CONFLICT DO NOTHING;

-- ── Post-checks ──────────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF (SELECT count(*) FROM crm.status_transition WHERE table_name = 'visa_application') < 16 THEN
        RAISE EXCEPTION 'crm-055: the visa_application transitions are missing';
    END IF;
    IF NOT has_column_privilege('crm_app', 'crm.tenant_settings', 'passport_valid_months', 'UPDATE')
       OR NOT has_column_privilege('crm_app', 'crm.tenant_settings', 'passport_valid_months', 'SELECT') THEN
        RAISE EXCEPTION 'crm-055: crm_app is missing a privilege on crm.tenant_settings.passport_valid_months';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-055', now(), 'AA-1070: crm.tenant_settings.passport_valid_months (default 6), crm.document kinds confirmation_pdf / proposal_pdf and uploader system, crm.status_transition rows of crm.visa_application')
ON CONFLICT (version) DO NOTHING;

COMMIT;
