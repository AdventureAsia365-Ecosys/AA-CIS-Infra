-- =============================================================================
-- Migration 007b: Create aa_app_user role for RLS enforcement
-- Run BEFORE test_007_rls_isolation.py
-- =============================================================================
-- Purpose:
--   aa_cis_admin has SUPERUSER/BYPASSRLS → RLS policies don't apply to it.
--   aa_app_user is the runtime application role — RLS IS enforced.
--   This is the proper separation needed for S7 RLS verification.
-- =============================================================================

BEGIN;

-- Create app user role (no superuser, no bypassrls)
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'aa_app_user') THEN
        CREATE ROLE aa_app_user
            LOGIN
            PASSWORD 'cisappuser2026'
            NOSUPERUSER
            NOCREATEDB
            NOCREATEROLE
            NOINHERIT
            NOBYPASSRLS;

        RAISE NOTICE 'Created role: aa_app_user';
    ELSE
        RAISE NOTICE 'Role aa_app_user already exists — skipping';
    END IF;
END $$;

-- Grant CONNECT on database
GRANT CONNECT ON DATABASE aa_cis_dev TO aa_app_user;

-- Grant USAGE on schemas
GRANT USAGE ON SCHEMA shared TO aa_app_user;
GRANT USAGE ON SCHEMA silver_aa_internal TO aa_app_user;
GRANT USAGE ON SCHEMA gold_aa_internal TO aa_app_user;

-- Grant SELECT on all relevant tables (app user reads only via RLS)
GRANT SELECT, INSERT, UPDATE ON shared.pipeline_runs TO aa_app_user;
GRANT SELECT ON shared.tenants TO aa_app_user;
GRANT SELECT ON shared.tenant_brand_rules TO aa_app_user;
GRANT SELECT ON shared.tenant_seo_config TO aa_app_user;
GRANT SELECT ON shared.tenant_export_config TO aa_app_user;
GRANT SELECT ON silver_aa_internal.raw_tours TO aa_app_user;
GRANT SELECT ON silver_aa_internal.seo_context TO aa_app_user;
GRANT SELECT ON silver_aa_internal.generated_content TO aa_app_user;
GRANT SELECT ON silver_aa_internal.quality_scores TO aa_app_user;
GRANT SELECT ON gold_aa_internal.published_tours TO aa_app_user;
GRANT SELECT ON gold_aa_internal.content_exports TO aa_app_user;
GRANT SELECT ON gold_aa_internal.webhook_deliveries TO aa_app_user;

-- Grant SELECT on future tables automatically
ALTER DEFAULT PRIVILEGES IN SCHEMA shared
    GRANT SELECT ON TABLES TO aa_app_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA silver_aa_internal
    GRANT SELECT ON TABLES TO aa_app_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA gold_aa_internal
    GRANT SELECT ON TABLES TO aa_app_user;

-- Also grant to test tenant schemas (created in 007)
DO $$
DECLARE
    schema_name TEXT;
BEGIN
    FOR schema_name IN
        SELECT s.schema_name
        FROM information_schema.schemata s
        WHERE s.schema_name LIKE 'silver_%' OR s.schema_name LIKE 'gold_%'
    LOOP
        EXECUTE format('GRANT USAGE ON SCHEMA %I TO aa_app_user', schema_name);
        EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO aa_app_user', schema_name);
        RAISE NOTICE 'Granted access on schema: %', schema_name;
    END LOOP;
END $$;

-- Verify
DO $$
DECLARE
    v_exists BOOLEAN;
    v_bypassrls BOOLEAN;
BEGIN
    SELECT EXISTS(SELECT 1 FROM pg_roles WHERE rolname = 'aa_app_user')
        INTO v_exists;
    SELECT rolbypassrls FROM pg_roles WHERE rolname = 'aa_app_user'
        INTO v_bypassrls;

    RAISE NOTICE '=== Role Verification ===';
    RAISE NOTICE 'aa_app_user exists: %', v_exists;
    RAISE NOTICE 'aa_app_user BYPASSRLS: % (must be false)', v_bypassrls;

    IF v_exists AND NOT v_bypassrls THEN
        RAISE NOTICE '=== 007b PASSED — aa_app_user ready for RLS testing ===';
    ELSE
        RAISE EXCEPTION '007b FAILED — role misconfigured';
    END IF;
END $$;

COMMIT;
