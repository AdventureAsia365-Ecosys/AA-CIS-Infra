-- Migration 368: AA-1036 (R3 slice 3, S267) — clear shared.tenants.api_key_hash: tenant API keys are gone.
--
-- Why. Root ADR 0019 d6: "All tenant API-key code and data go too ... shared.tenants.api_key_hash is set to NULL, then
-- dropped under the destructive-ops DRY RUN." The AA-1036 code PR (deployed before this file is applied) answers
-- POST /auth/tenant-login with 410 Gone, removed verify_tenant_api_key, generate-key, GET /v1/account/api-key and the
-- REVOKED_ offboarding marker (offboarding sets account_status), and no code path reads or writes the column any more
-- (tests/unit/test_aa1036_no_tenant_api_keys.py). The stored sha256 values (and the REVOKED_<id> markers) are now
-- credentials nothing accepts: this file removes them so no copy of a key hash outlives the feature.
--
-- What (one transaction, run as the owner of the CIS schemas, cis_owner since X1 S20/S21):
--   1. Guard: the column is absent (already dropped by the later destructive file) -> nothing to do but register.
--   2. Snapshot of the lifecycle columns of every row whose hash is set (account_status, is_active, cancelled_at,
--      suspend_reason, updated_at) into a temp table.
--   3. UPDATE shared.tenants SET api_key_hash = NULL WHERE api_key_hash IS NOT NULL. updated_at is left as it was (no
--      account changed). The BEFORE trigger tenants_account_status_sync (CIS 354) runs for each row but only derives
--      columns that are already consistent; the AFTER triggers fire only for their own columns (none here).
--   4. Post-check: no hash left, and the lifecycle columns of every updated row are byte-identical to the snapshot
--      (a trigger that rewrote an account state would roll the whole file back).
--   5. COMMENT ON COLUMN marks it retired; register 368 with the number of rows cleared.
--
-- Rows on Dev (04/11/2026, docs/architecture/db-schema-reference.md: ~11 tenants): every agency, demo and E2E test
-- tenant that ever had a key or an offboarding marker. The count is in the schema_versions description.
--
-- Class: contract (root ADR 0017 d3): an UPDATE of rows of an existing table and a comment on an existing column.
-- MIG-4: migration-only PR, applied by Infra Migration Apply (root ADR 0017a) once every job table is idle, AFTER the
-- AA-1036 code PR is deployed (the code that wrote the column is gone, so nothing writes a hash back). No
-- REQUIRED_CIS_SCHEMA bump: no code needs this file. Reversible only in the sense that nothing is lost: a key hash is
-- useless without the removed code, and the raw keys were never stored.
-- Next: the column DROP is a separate `-- migrate: destructive` file (DRY RUN, snapshot, tech lead approval).
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/; keep the two byte-identical.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
DECLARE
    has_col boolean;
    cleared integer := 0;
    drift   integer;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM pg_attribute
         WHERE attrelid = 'shared.tenants'::regclass AND attname = 'api_key_hash' AND NOT attisdropped
    ) INTO has_col;

    IF has_col THEN
        CREATE TEMP TABLE m368_before ON COMMIT DROP AS
            SELECT tenant_id, account_status, is_active, cancelled_at, suspend_reason, updated_at
              FROM shared.tenants
             WHERE api_key_hash IS NOT NULL;

        UPDATE shared.tenants SET api_key_hash = NULL WHERE api_key_hash IS NOT NULL;
        GET DIAGNOSTICS cleared = ROW_COUNT;

        IF EXISTS (SELECT 1 FROM shared.tenants WHERE api_key_hash IS NOT NULL) THEN
            RAISE EXCEPTION 'migration 368: shared.tenants.api_key_hash still holds a value after the UPDATE';
        END IF;

        SELECT count(*) INTO drift
          FROM m368_before b
          JOIN shared.tenants t USING (tenant_id)
         WHERE (t.account_status, t.is_active, t.cancelled_at, t.suspend_reason, t.updated_at)
               IS DISTINCT FROM (b.account_status, b.is_active, b.cancelled_at, b.suspend_reason, b.updated_at);
        IF drift > 0 THEN
            RAISE EXCEPTION 'migration 368: % tenant row(s) changed state while clearing the key hash', drift;
        END IF;

        COMMENT ON COLUMN shared.tenants.api_key_hash IS
            'Retired (AA-1036 R3 slice 3, root ADR 0019 d6): tenant API keys are gone; always NULL (CIS 368). '
            'Dropped by a later destructive migration.';
        RAISE NOTICE 'migration 368: cleared api_key_hash on % tenant row(s)', cleared;
    ELSE
        RAISE NOTICE 'migration 368: shared.tenants.api_key_hash is absent; nothing to clear';
    END IF;

    INSERT INTO shared.schema_versions (version, applied_at, description)
    VALUES ('368', now(), format('AA-1036: shared.tenants.api_key_hash set NULL (tenant API keys removed, root ADR '
                                 '0019 d6); rows cleared: %s', cleared))
    ON CONFLICT (version) DO NOTHING;
END $$;

COMMIT;
