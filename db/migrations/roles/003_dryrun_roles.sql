-- Migration rl-003: AA-826 — role bootstrap for the new owner dryrun (ADR 0008 playbook step 3), rendered from
-- db/templates/new_owner_roles.sql.tmpl by db/templates/render_new_owner_roles.py: owner role dr_owner (NOLOGIN),
-- runtime role dryrun_app (LOGIN, CONNECTION LIMIT 10, no password yet) and the empty anchor schema dryrun.
--
-- Why. Data standards DM-8.1 / MIG-6 / SEC-1: every app gets a NOLOGIN owner role and LOGIN runtime roles with a
-- CONNECTION LIMIT, defined in git in the Infra role bootstrap (db/migrations/roles/, runs only as the RDS master
-- aa_cis_admin). DB Migrate runs each dryrun/ file as the live owner of the anchor schema dryrun (XD8): the
-- schema has to exist, owned by dr_owner, before the owner's first file: with no anchor schema the runner
-- does not switch, and the first file would run as the DB Migrate login db_migrator, which must not own app objects.
--
-- What.
--   * CREATE ROLE dr_owner NOLOGIN and dryrun_app LOGIN … CONNECTION LIMIT 10 (if missing).
--   * CREATE SCHEMA dryrun AUTHORIZATION dr_owner (if missing): empty; the owner's first migration
--     (dr-001) creates the objects, the grants to dryrun_app and its default privileges.
--   * GRANT dr_owner TO aa_cis_admin (break-glass, ALTER … OWNER TO) and TO db_migrator (SET ROLE for the
--     live-owner switch is checked against the session user; db/owners.yaml migrator_member_of lists it).
--   Never granted (X1 plan §1.4, lesson S236: a policy TO r also applies to the members of r): dryrun_app to
--   anyone, any role to dr_owner or dryrun_app; aa_app_user and catalog_owner are not touched.
--
-- Not here: passwords (never in git, SEC-2: Nghiệp writes the DSN secret by hand, then DB Migrate mode=set-password
-- role=dryrun_app, which needs dryrun_app in db/owners.yaml password_roles), object grants, default
-- privileges, a job table (the owner's own migrations). Role attributes are set only through CREATE ROLE / NOLOGIN /
-- CONNECTION LIMIT: on PostgreSQL 15 a non-superuser CREATEROLE role (the RDS master) cannot name SUPERUSER,
-- REPLICATION or BYPASSRLS in ALTER ROLE, so the guard checks those instead. Idempotent: re-running changes nothing.
--
-- Rollback: a forward roles/ file (MIG-14, no down migration) that refuses while dr_owner owns anything but
-- the empty schema or dryrun_app has a session, then DROP SCHEMA dryrun, DROP OWNED BY and DROP ROLE.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '2min';

DO $$
BEGIN
    IF session_user <> 'aa_cis_admin' THEN
        RAISE EXCEPTION 'rl-003: roles/ files run only as the RDS master aa_cis_admin (session user is %)',
            session_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dr_owner') THEN
        CREATE ROLE dr_owner NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dryrun_app') THEN
        CREATE ROLE dryrun_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS CONNECTION LIMIT 10;
    END IF;
END $$;

ALTER ROLE dr_owner NOLOGIN;
ALTER ROLE dryrun_app LOGIN CONNECTION LIMIT 10;

GRANT dr_owner TO aa_cis_admin;
GRANT dr_owner TO db_migrator;

CREATE SCHEMA IF NOT EXISTS dryrun AUTHORIZATION dr_owner;

-- Guards: the roles and the schema have exactly the shape the playbook needs.
DO $$
DECLARE
    bad text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles
                    WHERE rolname = 'dr_owner' AND NOT rolcanlogin
                      AND NOT (rolsuper OR rolbypassrls OR rolcreaterole OR rolcreatedb OR rolreplication)) THEN
        RAISE EXCEPTION 'rl-003: dr_owner must exist, NOLOGIN, no SUPERUSER/BYPASSRLS/CREATEROLE/CREATEDB/REPLICATION';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles
                    WHERE rolname = 'dryrun_app' AND rolcanlogin AND rolconnlimit = 10
                      AND NOT (rolsuper OR rolbypassrls OR rolcreaterole OR rolcreatedb OR rolreplication)) THEN
        RAISE EXCEPTION 'rl-003: dryrun_app must be LOGIN, CONNECTION LIMIT 10, no SUPERUSER/BYPASSRLS/CREATEROLE/CREATEDB/REPLICATION';
    END IF;
    -- Both roles are members of nothing (no inherited rights, no policy TO r reaching them) …
    SELECT string_agg(m.member::regrole::text || ' in ' || m.roleid::regrole::text, ', ') INTO bad
      FROM pg_auth_members m
     WHERE m.member IN ('dr_owner'::regrole, 'dryrun_app'::regrole);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'rl-003: new roles must not be members of any role: %', bad;
    END IF;
    -- … and the runtime role is granted to nobody. PostgreSQL 16+ records the creating CREATEROLE role (the master)
    -- as an ADMIN member of every role it creates; PostgreSQL 15 (RDS today) does not. Only that row is tolerated.
    SELECT string_agg(m.member::regrole::text, ', ') INTO bad
      FROM pg_auth_members m
     WHERE m.roleid = 'dryrun_app'::regrole AND m.member <> 'aa_cis_admin'::regrole;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'rl-003: dryrun_app must not be granted to any role (granted to %)', bad;
    END IF;
    IF NOT (pg_has_role('aa_cis_admin', 'dr_owner', 'MEMBER') AND pg_has_role('db_migrator', 'dr_owner', 'MEMBER')) THEN
        RAISE EXCEPTION 'rl-003: aa_cis_admin and db_migrator must be members of dr_owner';
    END IF;
    IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'dryrun') IS DISTINCT FROM 'dr_owner' THEN
        RAISE EXCEPTION 'rl-003: schema dryrun must exist, owned by dr_owner';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('rl-003', now(),
    'AA-826: role bootstrap for owner dryrun — dr_owner NOLOGIN (granted to aa_cis_admin, db_migrator), '
    'dryrun_app LOGIN CONNECTION LIMIT 10 (no password), schema dryrun owned by dr_owner')
ON CONFLICT (version) DO NOTHING;

COMMIT;
