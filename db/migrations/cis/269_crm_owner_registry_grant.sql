-- Migration 269: AA-932 (partner CRM, design v3 card CRM-04) — the CRM owner role crm_owner may register its own
-- crm- files in shared.schema_versions, the way CIS 243 lets bk_owner / tp_owner register theirs.
--
-- Why. The partner CRM is a separate app (ADR 0008a, ADR 0010) whose migrations crm-NNN live in AA-Partner and are
-- applied by DB Migrate from the Infra byte copy. The Infra role bootstrap rl-003 creates crm_owner (NOLOGIN) and the
-- empty schema crm owned by it, so DB Migrate runs the very first file crm-001 as crm_owner (live-owner switch, XD8).
-- Every owner file registers itself (MIG-2) with INSERT INTO shared.schema_versions, as the role it runs as, and the
-- runner refuses a switched file (exit 8) unless that role holds USAGE on shared and INSERT on the registry
-- (Infra run_migration.py CAN_REGISTER_SQL). The CIS 243 key guard refuses every role but the registry owner's
-- members, bk_owner (bk- keys) and tp_owner (tp- keys), so crm_owner needs both the grants and its own branch.
--
-- What:
--   1. GRANT USAGE ON SCHEMA shared TO crm_owner;
--   2. GRANT SELECT, INSERT ON shared.schema_versions TO crm_owner;
--   3. CREATE OR REPLACE shared.schema_versions_key_guard(): unchanged except one more branch, crm_owner may insert
--      crm- keys only. Every other rule of 243 stays: members of the registry owner insert any key, every other role
--      none (so crm_app, the CRM runtime, can never write the registry, even through a crm_owner-owned view).
--   Nothing else is granted to any CRM role (ADR 0008a decision 1: no cross-schema grant in either direction).
--
-- Order (Dev): Infra roles/003_crm_roles.sql (rl-003, creates crm_owner) → this file → crm/001 (crm-001).
-- Runs as cis_owner (live owner of shared since 245, DB Migrate switch); owns schema shared, the registry and the
-- guard function, so GRANT and CREATE OR REPLACE need nothing more.
--
-- Rollback (forward file; only before crm-001 is applied — crm-001 registers itself as crm_owner):
--   REVOKE SELECT, INSERT ON shared.schema_versions FROM crm_owner; REVOKE USAGE ON SCHEMA shared FROM crm_owner;
--   then the 243 body of shared.schema_versions_key_guard() (without the crm_owner branch).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '15min';

-- ── Guard 0: crm_owner exists (rl-003), is NOLOGIN, and the runner owns the registry ────────────────
DO $$
DECLARE
    owner_name text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'crm_owner') THEN
        RAISE EXCEPTION 'migration 269: role crm_owner does not exist — apply the Infra role bootstrap roles/003_crm_roles.sql (rl-003) first';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'crm_owner' AND rolcanlogin) THEN
        RAISE EXCEPTION 'migration 269: role crm_owner can log in; owner roles are NOLOGIN (rl-003, DM-8.1)';
    END IF;
    IF to_regprocedure('shared.schema_versions_key_guard()') IS NULL THEN
        RAISE EXCEPTION 'migration 269: shared.schema_versions_key_guard() does not exist (CIS 243)';
    END IF;
    SELECT pg_catalog.pg_get_userbyid(relowner) INTO owner_name
      FROM pg_catalog.pg_class WHERE oid = 'shared.schema_versions'::regclass;
    IF NOT pg_catalog.pg_has_role(current_user, owner_name, 'MEMBER') THEN
        RAISE EXCEPTION 'migration 269: shared.schema_versions is owned by %, not by the runner % (GRANT and the guard need the owner)',
            owner_name, current_user;
    END IF;
END $$;

-- ── 1–2. What crm_owner needs to register its own files ──────────────────────────────────────────
GRANT USAGE ON SCHEMA shared TO crm_owner;
GRANT SELECT, INSERT ON shared.schema_versions TO crm_owner;

-- ── 3. Registry integrity: one more owner prefix ──────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION shared.schema_versions_key_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    -- Members of the registry's owner (the master; cis_owner / db_migrator after X1 S20/S21) insert any key.
    IF pg_catalog.pg_has_role(current_user,
                              (SELECT c.relowner FROM pg_catalog.pg_class c WHERE c.oid = TG_RELID),
                              'MEMBER') THEN
        RETURN NEW;
    END IF;
    -- An owner role registers only its own prefix, and only as that role (not through a view it owns).
    IF (NEW.version LIKE 'bk-%' AND current_user = 'bk_owner')
       OR (NEW.version LIKE 'tp-%' AND current_user = 'tp_owner')
       OR (NEW.version LIKE 'crm-%' AND current_user = 'crm_owner') THEN
        RETURN NEW;
    END IF;
    RAISE EXCEPTION USING
        ERRCODE = 'check_violation',
        MESSAGE = format('shared.schema_versions: %s may not register %L', current_user, NEW.version),
        HINT    = 'CIS 243/269 key guard: members of the registry owner insert any key, bk_owner only bk- keys, '
                  'tp_owner only tp- keys, crm_owner only crm- keys, every other role none; another owner''s key '
                  'would make DB Migrate skip that owner''s real file.';
END;
$$;
REVOKE ALL ON FUNCTION shared.schema_versions_key_guard() FROM PUBLIC;
COMMENT ON FUNCTION shared.schema_versions_key_guard() IS 'AA-852 (243, X1 S4) + AA-932 (269): BEFORE INSERT trigger on shared.schema_versions; members of the table owner insert any key, bk_owner only bk- keys, tp_owner only tp- keys, crm_owner only crm- keys, every other role none.';

-- ── Guard 1: the result, by shape ────────────────────────────────────────────────────────────────
DO $$
DECLARE
    p text;
BEGIN
    IF NOT pg_catalog.has_schema_privilege('crm_owner', 'shared', 'USAGE') THEN
        RAISE EXCEPTION 'migration 269: crm_owner has no USAGE on schema shared';
    END IF;
    IF pg_catalog.has_schema_privilege('crm_owner', 'shared', 'CREATE') THEN
        RAISE EXCEPTION 'migration 269: crm_owner holds CREATE on schema shared';
    END IF;
    FOREACH p IN ARRAY ARRAY['SELECT', 'INSERT'] LOOP
        IF NOT pg_catalog.has_table_privilege('crm_owner', 'shared.schema_versions', p) THEN
            RAISE EXCEPTION 'migration 269: crm_owner has no % on shared.schema_versions', p;
        END IF;
    END LOOP;
    -- No grant option, no write beyond INSERT (column grants count too: has_table_privilege ignores them).
    FOREACH p IN ARRAY ARRAY['SELECT WITH GRANT OPTION', 'INSERT WITH GRANT OPTION',
                             'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER'] LOOP
        IF pg_catalog.has_table_privilege('crm_owner', 'shared.schema_versions', p) THEN
            RAISE EXCEPTION 'migration 269: crm_owner holds % on shared.schema_versions; an owner role may only read and insert registry rows', p;
        END IF;
    END LOOP;
    FOREACH p IN ARRAY ARRAY['UPDATE', 'REFERENCES'] LOOP
        IF pg_catalog.has_any_column_privilege('crm_owner', 'shared.schema_versions', p) THEN
            RAISE EXCEPTION 'migration 269: crm_owner holds column-level % on shared.schema_versions', p;
        END IF;
    END LOOP;
    -- The CRM runtime and NOLOGIN roles get nothing in shared (ADR 0008a decision 1). They may not exist yet.
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles r
                WHERE r.rolname IN ('crm_app', 'crm_ai_reader', 'crm_insights', 'crm_support_reader', 'crm_eraser')
                  AND pg_catalog.has_schema_privilege(r.oid, 'shared', 'USAGE')) THEN
        RAISE EXCEPTION 'migration 269: a CRM runtime or NOLOGIN role holds USAGE on schema shared';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger
                    WHERE tgrelid = 'shared.schema_versions'::regclass AND NOT tgisinternal
                      AND tgname = 'schema_versions_key_guard' AND tgenabled = 'O'
                      AND tgfoid = 'shared.schema_versions_key_guard()'::regprocedure) THEN
        RAISE EXCEPTION 'migration 269: trigger schema_versions_key_guard (CIS 243) is missing or disabled';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_proc
                WHERE oid = 'shared.schema_versions_key_guard()'::regprocedure AND prosecdef) THEN
        RAISE EXCEPTION 'migration 269: shared.schema_versions_key_guard() must not be SECURITY DEFINER (MIG-6)';
    END IF;
    IF pg_catalog.has_function_privilege('public', 'shared.schema_versions_key_guard()', 'EXECUTE') THEN
        RAISE EXCEPTION 'migration 269: shared.schema_versions_key_guard() is executable by PUBLIC (SEC-4)';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('269', now(), 'AA-932: crm_owner USAGE on shared + SELECT, INSERT on shared.schema_versions; key guard: crm_owner registers crm- keys only')
ON CONFLICT (version) DO NOTHING;

COMMIT;
