-- Migration 243: AA-852 (X1 step S4) — the Booking and TripPlanner owner roles bk_owner / tp_owner may
-- register their own migrations in shared.schema_versions, and only their own keys.
--
-- Why. X1 moves the booking and tripplanner schemas from the RDS master (aa_cis_admin) to the NOLOGIN
-- owner roles bk_owner / tp_owner (Infra role bootstrap rl-001 creates them; bk-014 / tp-013 transfer the
-- objects). From that transfer on, DB Migrate runs every booking/ and tripplanner/ file as the live owner
-- of the dir's anchor schema (AA-CIS-Infra db/run_migration.py, X1 plan XD8), so those files register
-- themselves AS bk_owner / tp_owner, and the runner refuses a switched file (exit 8) unless the owner holds
-- USAGE on schema shared + INSERT on shared.schema_versions (its CAN_REGISTER check). Three needs, all on a
-- CIS object, so they live in a CIS migration (schema-ownership rule 1):
--   * USAGE on schema shared: today only aa_app_user, catalog_owner and tripplanner have it (schema
--     reference 16/10), so the first file run as bk_owner would fail on its own registration with
--     "permission denied for schema shared";
--   * INSERT on shared.schema_versions: the self-registration (MIG-2);
--   * SELECT on shared.schema_versions: booking.v_schema_versions (Booking readiness,
--     AA-Booking backend/app/db.py) is a view and reads its base table with its OWNER's rights, which
--     become bk_owner's with bk-014; ON CONFLICT (version) DO NOTHING reads the key too.
-- Registry integrity (X1 review A6). DB Migrate decides "already applied" by the version key alone
-- (run_migration.py: SELECT applied_at … WHERE version = $1). A Booking or TripPlanner file that inserted a
-- CIS key ('246') or a roles/ key ('rl-002') would make DB Migrate skip that owner's real, never-run file.
-- A BEFORE INSERT trigger therefore refuses by default: a member of the registry's owner (the master today;
-- cis_owner and db_migrator after X1 S20/S21, both members of cis_owner) inserts any key, bk_owner only bk-
-- keys, tp_owner only tp- keys, and every other role nothing. Refuse-by-default matters because the INSERT
-- privilege is not the only way in: booking.v_schema_versions (bk-014 makes bk_owner its owner) is a simple,
-- auto-updatable view, so an INSERT through it is checked on the base table as the view owner (bk_owner),
-- while inside the trigger current_user is the caller (e.g. the runtime role booking, should a later file
-- hand it INSERT on the view through GRANT … ON ALL TABLES or a TABLES default ACL). It also backs up
-- CIS 244's REVOKE of the registry writes from cis_app. A trigger, not RLS: RLS on the registry would also
-- filter every non-owner reader (cis_app after X1 S18, the Booking view). bk_owner and tp_owner get no
-- UPDATE / DELETE / TRUNCATE / REFERENCES / TRIGGER, no column privilege beyond that and no grant option:
-- a file cannot rewrite or remove any registry row nor pass INSERT on to another role.
--
-- What.
--   1. GRANT USAGE ON SCHEMA shared TO bk_owner, tp_owner;
--   2. GRANT SELECT, INSERT ON shared.schema_versions TO bk_owner, tp_owner;
--      Cross-owner grants, unguarded (schema-ownership rule 5, MIG-8): rl-001 must be applied first, and
--      guard 0 says so instead of the bare "role does not exist".
--   3. FUNCTION shared.schema_versions_key_guard() (plpgsql, NOT security definer, search_path pinned,
--      EXECUTE revoked from PUBLIC per SEC-4: a firing trigger does not check EXECUTE, the owner keeps it)
--      and TRIGGER schema_versions_key_guard BEFORE INSERT FOR EACH ROW on shared.schema_versions, both
--      CREATE OR REPLACE. current_user is the role the INSERT runs as: under DB Migrate's switch that is
--      the owner role (SET LOCAL ROLE), while session_user stays the login role. The registry's owner is
--      read at fire time (pg_class.relowner of TG_RELID), so CIS 245's transfer to cis_owner needs no
--      change here. A BEFORE INSERT row trigger fires before the ON CONFLICT check, so a refused key
--      raises even when it is already registered. Raises SQLSTATE 23514 (check_violation).
--   No privilege for cis_app here (CIS 244 grants the runtime and revokes its registry writes).
--
-- Guards (RAISE on failure, nothing changes):
--   0. before: bk_owner and tp_owner exist and are NOLOGIN (rl-001), shared.schema_versions exists and the
--      runner owns it or is a member of its owner (CREATE TRIGGER and GRANT need the owner);
--   1. after, by shape: both roles have USAGE on shared and SELECT + INSERT on shared.schema_versions, both
--      without grant option, and no UPDATE / DELETE / TRUNCATE / REFERENCES / TRIGGER on it, nor UPDATE /
--      REFERENCES on any of its columns; exactly one enabled user trigger on the table, BEFORE INSERT FOR
--      EACH ROW (tgtype 7) calling shared.schema_versions_key_guard(), which is not SECURITY DEFINER and
--      not executable by PUBLIC.
--   The trigger's behaviour needs a switch to bk_owner / tp_owner, which the X1 role lint does not allow in
--   a cis/ file (SET LOCAL ROLE only to catalog_owner, cis_owner, cis_app). It is proven by the CI test
--   tests/integration/test_aa852_migration_243.py (the plan's '246' as bk_owner case, a runtime role
--   inserting through a bk_owner-owned view or with a direct grant, and the rest) and on Dev by the probe
--   files bk-015 / tp-014 (X1 step S9), which DB Migrate runs as bk_owner / tp_owner.
--
-- Locks. shared.schema_versions (~240 rows): CREATE TRIGGER takes SHARE ROW EXCLUSIVE for milliseconds
-- (it does not block the readers, e.g. the Booking readiness view; it waits for nothing but a writer, and
-- only DB Migrate writes). GRANT takes no table lock. lock_timeout 5s below. Not destructive, no
-- `migrate:` directive. Re-running is a no-op.
--
-- Order (X1 step S8 train): roles/001_x1_owner_roles.sql (rl-001) → this file → booking/014 (bk-014) →
-- tripplanner/013 (tp-013). Runs as the login role (aa_cis_admin): shared is owned by it, no switch.
-- Merge order: this file on AA-CIS-App main → the rl-001 Infra PR merged and applied → the Infra copy of
-- this file merged and applied (Copy Guard is red until the first step). The Booking/TripPlanner
-- migration freeze starts at the first of these merges.
--
-- After apply: regenerate docs/architecture/db-schema-reference.md (DB Schema Dump workflow); expect
-- bk_owner / tp_owner: USAGE on schema shared, grants SELECT, INSERT on shared.schema_versions, trigger
-- schema_versions_key_guard, and the function list at 16 (CIS 245 transfers this function to cis_owner
-- like the other shared functions).
--
-- Rollback (forward file; only before bk-014 / tp-013 are applied — after them the Booking readiness view
-- and DB Migrate's registration as bk_owner / tp_owner depend on these grants):
--   DROP TRIGGER IF EXISTS schema_versions_key_guard ON shared.schema_versions;
--   DROP FUNCTION IF EXISTS shared.schema_versions_key_guard();
--   REVOKE SELECT, INSERT ON shared.schema_versions FROM bk_owner, tp_owner;
--   REVOKE USAGE ON SCHEMA shared FROM bk_owner, tp_owner;

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '15min';

-- ── Guard 0: the owner roles exist (rl-001) and the runner may alter the registry ───────────────
DO $$
DECLARE
    r           text;
    owner_name  text;
BEGIN
    FOREACH r IN ARRAY ARRAY['bk_owner', 'tp_owner'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r) THEN
            RAISE EXCEPTION 'migration 243: role % does not exist — apply the Infra role bootstrap roles/001_x1_owner_roles.sql (rl-001) first', r;
        END IF;
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r AND rolcanlogin) THEN
            RAISE EXCEPTION 'migration 243: role % can log in; owner roles are NOLOGIN (rl-001, DM-8.1)', r;
        END IF;
    END LOOP;
    IF to_regclass('shared.schema_versions') IS NULL THEN
        RAISE EXCEPTION 'migration 243: shared.schema_versions does not exist';
    END IF;
    SELECT pg_catalog.pg_get_userbyid(relowner) INTO owner_name
      FROM pg_catalog.pg_class WHERE oid = 'shared.schema_versions'::regclass;
    IF NOT pg_catalog.pg_has_role(current_user, owner_name, 'MEMBER') THEN
        RAISE EXCEPTION 'migration 243: shared.schema_versions is owned by %, not by the runner % (CREATE TRIGGER and GRANT need the owner)',
            owner_name, current_user;
    END IF;
END $$;

-- ── 1–2. What the owner roles need to register their own files ───────────────────────────────────
GRANT USAGE ON SCHEMA shared TO bk_owner, tp_owner;
GRANT SELECT, INSERT ON shared.schema_versions TO bk_owner, tp_owner;

-- ── 3. Registry integrity: each owner role registers only its own key prefix ────────────────────
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
       OR (NEW.version LIKE 'tp-%' AND current_user = 'tp_owner') THEN
        RETURN NEW;
    END IF;
    RAISE EXCEPTION USING
        ERRCODE = 'check_violation',
        MESSAGE = format('shared.schema_versions: %s may not register %L', current_user, NEW.version),
        HINT    = 'CIS 243 key guard: members of the registry owner insert any key, bk_owner only bk- keys, '
                  'tp_owner only tp- keys, every other role none; another owner''s key would make DB Migrate '
                  'skip that owner''s real file.';
END;
$$;
REVOKE ALL ON FUNCTION shared.schema_versions_key_guard() FROM PUBLIC;
COMMENT ON FUNCTION shared.schema_versions_key_guard() IS 'AA-852 (243, X1 S4): BEFORE INSERT trigger on shared.schema_versions; members of the table owner insert any key, bk_owner only bk- keys, tp_owner only tp- keys, every other role none.';

CREATE OR REPLACE TRIGGER schema_versions_key_guard
    BEFORE INSERT ON shared.schema_versions
    FOR EACH ROW EXECUTE FUNCTION shared.schema_versions_key_guard();

-- ── Guard 1: the result, by shape ────────────────────────────────────────────────────────────────
DO $$
DECLARE
    r       text;
    p       text;
    n_trig  int;
    n_ours  int;
BEGIN
    FOREACH r IN ARRAY ARRAY['bk_owner', 'tp_owner'] LOOP
        IF NOT pg_catalog.has_schema_privilege(r, 'shared', 'USAGE') THEN
            RAISE EXCEPTION 'migration 243: % has no USAGE on schema shared', r;
        END IF;
        FOREACH p IN ARRAY ARRAY['SELECT', 'INSERT'] LOOP
            IF NOT pg_catalog.has_table_privilege(r, 'shared.schema_versions', p) THEN
                RAISE EXCEPTION 'migration 243: % has no % on shared.schema_versions', r, p;
            END IF;
        END LOOP;
        -- A grant option would let bk_owner pass INSERT on to its runtime role (the trigger refuses that
        -- role, but the grant must not exist). Column grants count too: has_table_privilege ignores them.
        FOREACH p IN ARRAY ARRAY['SELECT WITH GRANT OPTION', 'INSERT WITH GRANT OPTION',
                                 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER'] LOOP
            IF pg_catalog.has_table_privilege(r, 'shared.schema_versions', p) THEN
                RAISE EXCEPTION 'migration 243: % holds % on shared.schema_versions; an owner role may only read and insert registry rows', r, p;
            END IF;
        END LOOP;
        FOREACH p IN ARRAY ARRAY['UPDATE', 'REFERENCES'] LOOP
            IF pg_catalog.has_any_column_privilege(r, 'shared.schema_versions', p) THEN
                RAISE EXCEPTION 'migration 243: % holds column-level % on shared.schema_versions; an owner role may only read and insert registry rows', r, p;
            END IF;
        END LOOP;
    END LOOP;

    SELECT count(*),
           count(*) FILTER (WHERE tgfoid = 'shared.schema_versions_key_guard()'::regprocedure
                              AND tgname = 'schema_versions_key_guard'
                              AND tgtype = 7            -- ROW (1) | BEFORE (2) | INSERT (4)
                              AND tgenabled = 'O')
      INTO n_trig, n_ours
      FROM pg_catalog.pg_trigger
     WHERE tgrelid = 'shared.schema_versions'::regclass AND NOT tgisinternal;
    IF n_ours <> 1 OR n_trig <> 1 THEN
        RAISE EXCEPTION 'migration 243: expected exactly one user trigger on shared.schema_versions (schema_versions_key_guard, BEFORE INSERT FOR EACH ROW, enabled), found % trigger(s), % matching',
            n_trig, n_ours;
    END IF;

    IF EXISTS (SELECT 1 FROM pg_catalog.pg_proc
                WHERE oid = 'shared.schema_versions_key_guard()'::regprocedure AND prosecdef) THEN
        RAISE EXCEPTION 'migration 243: shared.schema_versions_key_guard() must not be SECURITY DEFINER (MIG-6)';
    END IF;
    IF pg_catalog.has_function_privilege('public', 'shared.schema_versions_key_guard()', 'EXECUTE') THEN
        RAISE EXCEPTION 'migration 243: shared.schema_versions_key_guard() is executable by PUBLIC (SEC-4)';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('243', now(), 'AA-852 (X1 S4): bk_owner/tp_owner USAGE on shared + SELECT, INSERT on shared.schema_versions; BEFORE INSERT key guard (registry owner members any key, bk_owner only bk- keys, tp_owner only tp- keys, others none)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
