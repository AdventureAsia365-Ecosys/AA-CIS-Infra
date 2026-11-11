-- Migration 397: AA-1080 — the tenant pool may write the brand's signature words (shared.tenant_brand_rules
-- .custom_validators) when it saves a new brand-identity version.
--
-- Why. AA-741 phase 3 (S276): every audit brand had 0 explicit signature words (AA-800), because no save path wrote
-- custom_validators: the Brand Identity POST inserts a new version without the column, so even a value an admin set
-- was dropped on the next tenant save. AA-1080 maps the signature words from the T0 brief and lets the agency edit
-- them in the form; the POST then writes custom_validators on the tenant pool (aa_app_user, CIS 262), which holds
-- INSERT on 16 named columns only.
--
-- What.
--   1. GRANT INSERT (custom_validators) ON shared.tenant_brand_rules TO aa_app_user. INSERT only: the POST never
--      updates a version in place (it inserts version n + 1 and flips is_active, the UPDATE (is_active) grant of
--      262). The value is built by the API (the previous version's object with only its signature_words key
--      replaced), never sent as raw jsonb by the client.
--   2. Register 397.
--
-- Class: contract (root ADR 0017 decision 3; no '-- migrate:' directive line): a privilege change on an existing
-- table. MIG-4: this migration-only PR, applied on Dev by Infra Migration Apply when every job table is idle (ADR
-- 0017a), then the code PR that writes the column and raises readiness to 397 (REQUIRED_CIS_ABOVE_GAP). Before 397
-- a tenant save that writes the column would fail with "permission denied", so the code PR must not ship first.
-- No new table, so no DM-7.1 retention row.
--
-- PII (DM-6.1). None: the brand's own marketing words.
--
-- RLS. Unchanged: tenant_isolation (262) still limits the tenant pool to its own rows, WITH CHECK included; the
-- 241 / 262 invariant (no tenant-pool privilege on a table without RLS) holds, the table has RLS on.
--
-- Note. Re-running 262 alone ("start from nothing") would revoke this column grant; a 262 re-run must be followed by
-- 397 (tests/integration/test_aa1080_migration_397.py checks the set after both).
--
-- Guards (RAISE rolls the whole file back): before — 262 registered, the table and the roles present. After — the
-- tenant role holds INSERT on custom_validators and still no UPDATE on it, no DELETE / TRUNCATE.
--
-- Number. 395 is the highest on main (11/11); 396 is held by another lane of the same wave (flag_fix
-- ceiling), so this lane takes 397. If another file takes 397 first, renumber to the new main max + 1:
-- the file name, this header, the
-- registration below, tests/integration/test_aa1080_migration_397.py, api/core/readiness.py,
-- tests/unit/test_aa884_health.py and docs/implementation-notes/AA-1080.md (git grep '397_' and git grep '397').
--
-- Locks. GRANT takes a brief lock on the catalog row of a 27-row table. lock_timeout 5s, statement_timeout 1min.
-- Idempotent (GRANT is), one transaction, self-registering.
--
-- Rollback (a new forward migration, after the code that writes the column is reverted):
-- REVOKE INSERT (custom_validators) ON shared.tenant_brand_rules FROM aa_app_user;
--
-- X1. One BEGIN … COMMIT block, no role switch. Migration Apply runs cis/ files as cis_owner, the owner of the table.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';
SELECT set_config('aa.actor', 'migration:397', true);

-- ── Preconditions ──────────────────────────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '262') THEN
        RAISE EXCEPTION 'migration 397: apply 262 (tenant brand / seo RLS and grants) first';
    END IF;
    IF to_regclass('shared.tenant_brand_rules') IS NULL THEN
        RAISE EXCEPTION 'migration 397: shared.tenant_brand_rules is missing';
    END IF;
    IF to_regrole('aa_app_user') IS NULL THEN
        RAISE EXCEPTION 'migration 397: role aa_app_user does not exist (007b / Infra rl-001; CI: conftest)';
    END IF;
END $$;

-- ── 1. the column grant ────────────────────────────────────────────────────────────────────────────────────────────
GRANT INSERT (custom_validators) ON shared.tenant_brand_rules TO aa_app_user;

-- ── Postconditions ─────────────────────────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT has_column_privilege('aa_app_user', 'shared.tenant_brand_rules', 'custom_validators', 'INSERT') THEN
        RAISE EXCEPTION 'migration 397: aa_app_user still lacks INSERT (custom_validators)';
    END IF;
    IF has_column_privilege('aa_app_user', 'shared.tenant_brand_rules', 'custom_validators', 'UPDATE') THEN
        RAISE EXCEPTION 'migration 397: aa_app_user must not UPDATE custom_validators';
    END IF;
    IF has_table_privilege('aa_app_user', 'shared.tenant_brand_rules', 'DELETE, TRUNCATE') THEN
        RAISE EXCEPTION 'migration 397: aa_app_user must not DELETE / TRUNCATE shared.tenant_brand_rules';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('397', now(), 'AA-1080: tenant pool INSERT (custom_validators) on shared.tenant_brand_rules (signature words)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
