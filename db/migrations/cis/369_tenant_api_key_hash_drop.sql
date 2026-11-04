-- migrate: destructive
-- Migration 369: AA-1036 (R3 slice 3, S267) — drop shared.tenants.api_key_hash (tenant API keys are gone).
--
-- Why. Root ADR 0019 d6: "shared.tenants.api_key_hash is set to NULL, then dropped under the destructive-ops DRY RUN."
-- CIS 368 cleared every value; the AA-1036 code PR removed every reader and writer, and
-- tests/unit/test_aa1036_no_tenant_api_keys.py keeps production code from naming the column again.
--
-- DRY RUN (read-only, before the apply): scripts/aa1036/key_hash_dry_run.py through the S3-mediated ECS exec
-- (cis_app). Its output goes into the AA-1036 Linear comment and must say `verdict ready=true`: 368 registered, no
-- value left, no view / index / constraint / policy / trigger naming the column. Then the tech lead approves this file
-- (destructive-ops step 4); it is NOT part of the AA-1036 code or contract PRs.
--
-- What (one transaction, run by DB Migrate as the owner of the CIS schemas, cis_owner):
--   1. Guard: absent already -> register only. Otherwise 368 must be registered and no row may hold a value (a value
--      means something wrote a hash after 368: stop and find the writer).
--   2. ALTER TABLE shared.tenants DROP COLUMN api_key_hash (RESTRICT, the default: a view that grew a dependency on the
--      column stops the drop and rolls the file back). Column grants go with the column.
--   3. Register 369.
--
-- Archive. The header `migrate: destructive` makes DB Migrate take an RDS snapshot before the apply
-- (db-migrate-369-<run>-<attempt>). The column holds no value after 368, so the snapshot keeps only the definition.
-- Record the snapshot id in AA-Ecosys docs/architecture/dead-table-registry.md.
--
-- Lock: DROP COLUMN takes ACCESS EXCLUSIVE on shared.tenants for a catalog-only change (no rewrite). Apply while the
-- job tables are idle (DB Migrate waits for that); lock_timeout 5s, retry on a timeout.
--
-- Before this file can merge, every test fixture that still names the column must stop doing so (the CI replay
-- drops it before the tests run): tests/integration/conftest.py, test_007_rls_isolation.py, test_aa741_brand_markets.py,
-- test_aa741_offboard.py, test_aa761_tenant_account_sql.py, test_aa764_t7_t8_jobs.py, test_aa840_tenant_config_channels.py,
-- test_aa1028_tenant_provision.py, test_aa1028_migration_356.py, test_aa1028_migration_361.py,
-- test_aa1028_migrations_353_355.py, test_aa978_migration_276.py, test_aa1036_migration_368.py; and the migration
-- tests that RE-APPLY an older file whose body inserts the column (354, 355 self-test blocks) need a stand-in or a
-- skip after 369. scripts/aa729/common.py only lists the name in a scrub list (harmless).
--
-- Rollback: none in SQL (the values were already NULL). Restore the definition from the pre-apply snapshot if needed.
-- No REQUIRED_CIS_SCHEMA bump: no code needs it.
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/; keep the two byte-identical.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_attribute
                WHERE attrelid = 'shared.tenants'::regclass AND attname = 'api_key_hash' AND NOT attisdropped) THEN
        IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '368') THEN
            RAISE EXCEPTION 'migration 369: needs 368 (api_key_hash set NULL) first';
        END IF;
        IF EXISTS (SELECT 1 FROM shared.tenants WHERE api_key_hash IS NOT NULL) THEN
            RAISE EXCEPTION 'migration 369: shared.tenants.api_key_hash holds a value written after 368; find the writer';
        END IF;
        ALTER TABLE shared.tenants DROP COLUMN api_key_hash;
        RAISE NOTICE 'migration 369: dropped shared.tenants.api_key_hash';
    ELSE
        RAISE NOTICE 'migration 369: shared.tenants.api_key_hash is already absent';
    END IF;

    INSERT INTO shared.schema_versions (version, applied_at, description)
    VALUES ('369', now(), 'AA-1036: drop shared.tenants.api_key_hash (tenant API keys removed, root ADR 0019 d6)')
    ON CONFLICT (version) DO NOTHING;
END $$;

COMMIT;
