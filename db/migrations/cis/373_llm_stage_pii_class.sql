-- Migration 373: AA-1039 (R6, S268) — shared.llm_role_config.pii_class: the data class of each gateway stage, so
-- personal data stays on our own AWS accounts and in the US.
--
-- Why. Root ADR 0019 d12 (TL-12): "Each gateway stage declares a pii_class: PII routes to us, and content may route to
-- global." Root ADR 0009 decision 10 adds the inference geography per stage, and the S267 amendment of decision 5
-- ("AWS preferred, not AWS only", CIS 366) lists "the per-stage pii_class it plans" among the protections that stay.
-- The stage data policy already exists as data: allowed_scopes (CIS 311; aws_only = our Bedrock accounts,
-- vendor_direct = a vendor API). pii_class builds on it instead of a parallel rule: a 'pii' stage is held to
-- {aws_only} by a CHECK, and the gateway (shared/llm_client/vendor_route.deployment_plan) calls it only on a US
-- deployment (a Bedrock `us.` profile or an in-region model id on a us-* connection, never a `global.` profile).
--
-- What.
--   1. ADD COLUMN pii_class text NOT NULL DEFAULT 'content' (PostgreSQL 11+: a constant default fills every row
--      without a rewrite). Every row of today is 'content': no CIS stage receives personal data. The A-series and
--      place stages write AA catalogue text; the T-series stages write tenant content (brand text, no traveller
--      data); tp_compose narrates a plan built from catalogue tours; the embed stages embed catalogue text and search
--      words. The CRM stages that read traveller messages (crm_draft_reply) run in the CRM's own gateway after its PII
--      scrub (root ADR 0008a section 5) and have no row here.
--   2. CHECK llm_role_config_pii_class_check: pii_class IN ('content', 'pii').
--   3. CHECK llm_role_config_pii_scope_check: a 'pii' stage has allowed_scopes = {aws_only} exactly (not NULL: NULL is
--      "no stage policy", which lets a vendor API be a model's first deployment). A later migration that opens every
--      writer to vendor APIs (as 366 did) therefore fails on a pii stage instead of moving its data.
--   4. Migration-only, like allowed_scopes: cis_app keeps its column grants (311 / 326), which do not include
--      pii_class; the admin GET /admin/llm-config shows it read-only (AI gateway > Routing > Routing by data class).
--   5. Register 373.
--
-- Guards (RAISE rolls the whole file back): shared.llm_role_config has allowed_scopes (311); after the change no row
-- breaks either CHECK (both are added VALID).
--
-- Behaviour. None on apply: every stage is 'content', and the gateway applies the US-only rule to 'pii' stages only,
-- so every call is the one it was. The code reads the column with a fallback when it is missing (role_config: no
-- column = 'content'), so code and file may ship in either order.
--
-- Class: contract (root ADR 0017): ALTER TABLE ADD COLUMN and ADD CONSTRAINT on an existing table. No migrate
-- directive line: Infra Migration Apply applies it once every job table is idle (root ADR 0017a).
--
-- Number. 371 is the highest on main (04/11); 372 is held by the parallel AA-1045 lane of S268. Renumber to main
-- max + 1 if needed (git grep '373_' and 'CIS 373' / 'migration 373').
--
-- Rollback (a NEW forward migration, after the code is reverted; the code treats a missing column as 'content'):
--   ALTER TABLE shared.llm_role_config DROP CONSTRAINT llm_role_config_pii_scope_check;
--   ALTER TABLE shared.llm_role_config DROP CONSTRAINT llm_role_config_pii_class_check;
--   ALTER TABLE shared.llm_role_config DROP COLUMN pii_class;          (a destructive file, DRY RUN)
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of schema shared.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF to_regclass('shared.llm_role_config') IS NULL THEN
        RAISE EXCEPTION 'migration 373: shared.llm_role_config (137) is missing';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'shared' AND table_name = 'llm_role_config'
                      AND column_name = 'allowed_scopes') THEN
        RAISE EXCEPTION 'migration 373: shared.llm_role_config.allowed_scopes (311) is missing';
    END IF;
END $$;

ALTER TABLE shared.llm_role_config ADD COLUMN IF NOT EXISTS pii_class text NOT NULL DEFAULT 'content';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'llm_role_config_pii_class_check'
                      AND conrelid = 'shared.llm_role_config'::regclass) THEN
        ALTER TABLE shared.llm_role_config ADD CONSTRAINT llm_role_config_pii_class_check
            CHECK (pii_class IN ('content', 'pii'));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'llm_role_config_pii_scope_check'
                      AND conrelid = 'shared.llm_role_config'::regclass) THEN
        ALTER TABLE shared.llm_role_config ADD CONSTRAINT llm_role_config_pii_scope_check
            CHECK (pii_class <> 'pii' OR (allowed_scopes IS NOT NULL AND allowed_scopes = ARRAY['aws_only']::text[]));
    END IF;
END $$;

COMMENT ON COLUMN shared.llm_role_config.pii_class IS
    'AA-1039 (CIS 373, root ADR 0019 d12): the data class of the stage. content = no personal data (any allowed '
    'route, global profiles included); pii = personal data: allowed_scopes must be {aws_only} (CHECK '
    'llm_role_config_pii_scope_check) and the gateway calls only US deployments (Bedrock us. profiles or in-region '
    'ids on a us-* connection, never global.). Migration-only.';
COMMENT ON CONSTRAINT llm_role_config_pii_scope_check ON shared.llm_role_config IS
    'AA-1039 (CIS 373): a pii stage stays on our AWS accounts (allowed_scopes = {aws_only}, not NULL).';

DO $$
DECLARE
    n_pii integer;
BEGIN
    SELECT count(*) INTO n_pii FROM shared.llm_role_config WHERE pii_class = 'pii';
    RAISE NOTICE 'migration 373: stages with pii_class pii: %', n_pii;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('373', now(), 'AA-1039: shared.llm_role_config.pii_class (content | pii; a pii stage stays aws_only and US)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
