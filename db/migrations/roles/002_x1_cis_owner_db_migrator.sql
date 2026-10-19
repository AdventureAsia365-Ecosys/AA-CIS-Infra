-- Migration rl-002: AA-860 (X1 plan S20, Wave 5) — role bootstrap part 2: the CIS owner role cis_owner (NOLOGIN)
-- and the DB Migrate login db_migrator (LOGIN, CONNECTION LIMIT 5, no password yet).
--
-- Why. Data standards DM-8.1 / MIG-6 / SEC-1: every app gets a NOLOGIN owner role, and migrations run under a
-- dedicated login that is not the RDS master (DM-8.9: the master becomes break-glass). CIS is the last owner without
-- one: its objects are still owned by aa_cis_admin. X1 plan AA-Ecosys docs/audits/2026-10-17-S241-x1/x1-plan.md
-- §5 S20 (this file), S21 (CIS 245 moves the CIS objects to cis_owner), S22 (DB Migrate logs in as db_migrator).
--
-- What.
--   * CREATE ROLE cis_owner NOLOGIN (if missing). It owns nothing yet: CIS 245 (S21) gives it the 12 CIS schemas
--     and their objects. GRANT CREATE ON DATABASE aa_cis_dev TO cis_owner: CIS migrations create schemas, and from
--     245 on DB Migrate runs cis/ files as cis_owner (live-owner switch, XD8).
--   * GRANT cis_owner TO aa_cis_admin: PostgreSQL 15 needs membership of the new owner for ALTER … OWNER TO (245),
--     the runner's SET ROLE cis_owner while the master is still the DB Migrate login (S21 → S22), and break-glass.
--   * CREATE ROLE db_migrator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS CONNECTION LIMIT 5 without a
--     password (if missing). It cannot log in until Nghiệp writes aa-cis/dev/db-migrator and DB Migrate
--     mode=set-password role=db_migrator runs; DB Migrate keeps the master login until S22. Limit 5, not 3: DB
--     Migrate (also run-script / set-password), DB Schema Dump and the isolation probe have separate concurrency
--     groups and can overlap (X1 review B10). NOCREATEROLE: password changes and roles/ files stay on the master.
--   * GRANT bk_owner, tp_owner, cis_owner, catalog_owner, cis_app TO db_migrator: PostgreSQL checks SET ROLE against
--     the SESSION user, so the S22 login must be a member of every role a file can be switched to — each owner role
--     (XD8), catalog_owner (S22 catalog-view recipe), cis_app (244-style guard blocks, review C3). Equals
--     db/owners.yaml migrator_member_of minus pg_read_all_stats (db/tests/test_roles_files.py).
--   * GRANT pg_read_all_stats TO db_migrator: without it pg_stat_activity hides state/query of other roles'
--     sessions, and the schema dump's Connections table and the probe's session cells go blank.
--   Never granted (X1 plan §1.4, lesson S236: a policy TO r also applies to the members of r): aa_app_user to
--   anyone; catalog_owner to anyone but db_migrator; cis_owner never joins catalog_owner (SET ROLE is checked
--   against db_migrator, the session user). db_migrator stays INHERIT (review A1: NOINHERIT would also cut
--   pg_read_all_stats and the owner roles' catalog visibility the schema dump needs). db_migrator's query results
--   are never tenant-isolation evidence (member of catalog_owner and cis_app); the probe uses each runtime role's
--   own login for those cells.
--
-- Not here: passwords (never in git, SEC-2), object ownership (245), default privileges FOR ROLE cis_owner (245),
-- the migrator task definition's DSN secret (S22, hand edit). Role attributes are set only through CREATE ROLE /
-- NOLOGIN / CONNECTION LIMIT: on PostgreSQL 15 a non-superuser CREATEROLE role (the RDS master) cannot name
-- SUPERUSER, REPLICATION or BYPASSRLS in ALTER ROLE, so the guard checks those instead of restating them.
-- Roles from rl-001 / CIS 225 (bk_owner, tp_owner, cis_app, catalog_owner) are not guarded by IF EXISTS: they exist
-- on Dev. Idempotent: re-running changes nothing.
--
-- Rollback: a forward roles/ file (MIG-14, no down migration), prepared in AA-Ecosys
-- docs/audits/2026-10-17-S241-x1/s20-undo/0NN_x1_rl002_undo.sql: refuses while cis_owner owns anything (apply the
-- 245 undo first), db_migrator holds any privilege or has a session (roll S22 back first); then DROP OWNED BY
-- cis_owner (revokes CREATE on the database) and DROP ROLE db_migrator, cis_owner.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '2min';

DO $$
BEGIN
    IF session_user <> 'aa_cis_admin' THEN
        RAISE EXCEPTION 'rl-002: roles/ files run only as the RDS master aa_cis_admin (session user is %)',
            session_user;
    END IF;
    IF current_database() <> 'aa_cis_dev' THEN
        RAISE EXCEPTION 'rl-002: written for database aa_cis_dev (GRANT CREATE ON DATABASE below), connected to %',
            current_database();
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cis_owner') THEN
        CREATE ROLE cis_owner NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'db_migrator') THEN
        CREATE ROLE db_migrator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS CONNECTION LIMIT 5;
    END IF;
END $$;

ALTER ROLE cis_owner NOLOGIN;
ALTER ROLE db_migrator LOGIN CONNECTION LIMIT 5;

GRANT CREATE ON DATABASE aa_cis_dev TO cis_owner;
GRANT cis_owner TO aa_cis_admin;

GRANT bk_owner, tp_owner, cis_owner, catalog_owner, cis_app TO db_migrator;
GRANT pg_read_all_stats TO db_migrator;

-- Guards: the roles have exactly the shape X1 needs.
DO $$
DECLARE
    bad      text;
    r        text;
    expected text[] := ARRAY['bk_owner', 'catalog_owner', 'cis_app', 'cis_owner', 'pg_read_all_stats', 'tp_owner'];
    direct   text[];
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles
                    WHERE rolname = 'cis_owner' AND NOT rolcanlogin
                      AND NOT (rolsuper OR rolbypassrls OR rolcreaterole OR rolcreatedb OR rolreplication)) THEN
        RAISE EXCEPTION 'rl-002: cis_owner must exist, NOLOGIN, no SUPERUSER/BYPASSRLS/CREATEROLE/CREATEDB/REPLICATION';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles
                    WHERE rolname = 'db_migrator' AND rolcanlogin AND rolinherit AND rolconnlimit = 5
                      AND NOT (rolsuper OR rolbypassrls OR rolcreaterole OR rolcreatedb OR rolreplication)) THEN
        RAISE EXCEPTION 'rl-002: db_migrator must be LOGIN, INHERIT, CONNECTION LIMIT 5, no SUPERUSER/BYPASSRLS/CREATEROLE/CREATEDB/REPLICATION';
    END IF;

    -- cis_owner: member of nothing (it never joins catalog_owner, §1.4); can create schemas; the master reaches it.
    SELECT string_agg(m.roleid::regrole::text, ', ') INTO bad
      FROM pg_auth_members m
     WHERE m.member = 'cis_owner'::regrole;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'rl-002: cis_owner must not be a member of any role (is a member of %)', bad;
    END IF;
    IF NOT has_database_privilege('cis_owner', current_database(), 'CREATE') THEN
        RAISE EXCEPTION 'rl-002: cis_owner needs CREATE on database % (CIS migrations create schemas)', current_database();
    END IF;
    IF NOT pg_has_role('aa_cis_admin', 'cis_owner', 'MEMBER') THEN
        RAISE EXCEPTION 'rl-002: aa_cis_admin must be a member of cis_owner (ALTER … OWNER TO in 245, break-glass)';
    END IF;

    -- db_migrator: direct memberships exactly db/owners.yaml migrator_member_of, each one inherited (USAGE).
    SELECT array_agg(g.name ORDER BY g.name COLLATE "C") INTO direct
      FROM (SELECT DISTINCT m.roleid::regrole::text AS name
              FROM pg_auth_members m
             WHERE m.member = 'db_migrator'::regrole) g;
    IF direct IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'rl-002: db_migrator must be a direct member of exactly % (db/owners.yaml migrator_member_of), is a member of %',
            expected, direct;
    END IF;
    FOREACH r IN ARRAY expected LOOP
        IF NOT pg_has_role('db_migrator', r, 'USAGE') THEN
            RAISE EXCEPTION 'rl-002: db_migrator does not have the privileges of % (INHERIT)', r;
        END IF;
    END LOOP;
    -- …and never, even through a chain, the tenant pool role, the master or a bypass role (§1.4, SEC-1).
    FOREACH r IN ARRAY ARRAY['aa_app_user', 'aa_cis_admin', 'rds_superuser', 'pg_read_all_data', 'pg_write_all_data'] LOOP
        IF to_regrole(r) IS NOT NULL AND pg_has_role('db_migrator', r, 'MEMBER') THEN
            RAISE EXCEPTION 'rl-002: db_migrator must not be a member of % (directly or through a chain)', r;
        END IF;
    END LOOP;

    -- Members of the new roles: cis_owner only the master and db_migrator; db_migrator nobody but the master
    -- (PostgreSQL 16+ records the creating role there with ADMIN; 15 records nothing). A policy TO r reaches
    -- its members.
    SELECT string_agg(m.member::regrole::text || ' in ' || m.roleid::regrole::text, ', ') INTO bad
      FROM pg_auth_members m
     WHERE (m.roleid = 'cis_owner'::regrole AND m.member NOT IN ('aa_cis_admin'::regrole, 'db_migrator'::regrole))
        OR (m.roleid = 'db_migrator'::regrole AND m.member <> 'aa_cis_admin'::regrole);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'rl-002: unexpected member(s) of the new roles: %', bad;
    END IF;

    -- §1.4 (restated from rl-001): the master never becomes a member of the tenant pool role or the catalog view owner.
    IF pg_has_role('aa_cis_admin', 'aa_app_user', 'MEMBER') OR pg_has_role('aa_cis_admin', 'catalog_owner', 'MEMBER') THEN
        RAISE EXCEPTION 'rl-002: aa_cis_admin must not be a member of aa_app_user or catalog_owner (policies TO r reach members)';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('rl-002', now(),
    'AA-860 (X1 S20): role bootstrap part 2 — cis_owner NOLOGIN (CREATE on the database, granted to aa_cis_admin); '
    'db_migrator LOGIN CONNECTION LIMIT 5, NOCREATEROLE, no password, member of bk_owner, tp_owner, cis_owner, '
    'catalog_owner, cis_app and pg_read_all_stats')
ON CONFLICT (version) DO NOTHING;

COMMIT;
