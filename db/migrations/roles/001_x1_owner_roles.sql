-- Migration rl-001: AA-852 (X1 plan S3) — role bootstrap: owner roles bk_owner and tp_owner (NOLOGIN),
-- the CIS runtime role cis_app (LOGIN, no password yet), and the N3 connection limits moved here (MIG-6).
--
-- Why. Data standards DM-8.1 / MIG-6 / SEC-1: every app gets a NOLOGIN owner role and LOGIN runtime
-- roles with a CONNECTION LIMIT, defined in git in the Infra role bootstrap (db/migrations/roles/, runs
-- only as the RDS master aa_cis_admin, db/owners.yaml). This is the first file of that bootstrap
-- (X1 plan AA-Ecosys docs/audits/2026-10-17-S241-x1/x1-plan.md §5 S3, applied first in the S8 train).
--
-- What.
--   * CREATE ROLE bk_owner NOLOGIN, tp_owner NOLOGIN (if missing). They own nothing yet: bk-014 / tp-013
--     move the booking / tripplanner objects to them (S6, S7); CIS 243 gives them USAGE on shared and
--     SELECT, INSERT on shared.schema_versions (S4) before that.
--   * GRANT bk_owner, tp_owner TO aa_cis_admin: PostgreSQL 15 needs membership of the new owner for
--     ALTER … OWNER TO, the DB Migrate live-owner switch (XD8) needs it for SET ROLE, and break-glass.
--   * CREATE ROLE cis_app LOGIN … CONNECTION LIMIT 90 without a password (if missing). It cannot log in
--     until Nghiệp writes aa-cis/dev/rds-cis-app and DB Migrate mode=set-password runs (S17). 90 is the
--     floor; the measured budget (XD6, S15) raises it in a later roles/ file before S18 if needed.
--   * GRANT cis_app TO aa_cis_admin: only so CIS 244's guard block can SET LOCAL ROLE cis_app. Harmless:
--     policies TO cis_app exist only on ENABLE-without-FORCE tables, where the master is owner-exempt.
--   * Restate the N3 limits of CIS 234 (same values, no behaviour change): tripplanner 30, booking 15,
--     aa_app_user 15. 234 was the single interim MIG-6 exception; the attributes now live here.
--   Never granted here (X1 plan §1.4, lesson S236): aa_app_user or catalog_owner to anyone. A policy
--   TO r also applies to the members of r.
--
-- Not here: passwords (never in git, SEC-2), cis_owner and db_migrator (rl-002, S20), any object
-- ownership. Role attributes are set only through CREATE ROLE / CONNECTION LIMIT / NOLOGIN: on
-- PostgreSQL 15 a non-superuser CREATEROLE role (the RDS master) cannot name SUPERUSER, REPLICATION
-- or BYPASSRLS in ALTER ROLE, so the guard checks those instead of restating them.
-- Cross-owner roles (tripplanner, booking, aa_app_user) are not guarded by IF EXISTS (schema-ownership
-- rule 5): they exist on Dev and in every CI that replays CIS 234. Idempotent: re-running changes nothing.
--
-- Rollback (only before the S8 train moves any ownership): a later roles/ file with
--   DROP ROLE IF EXISTS cis_app, tp_owner, bk_owner;
-- and the N3 limits stay (they are 234's values). No down migration (MIG-14).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '2min';

DO $$
BEGIN
    IF session_user <> 'aa_cis_admin' THEN
        RAISE EXCEPTION 'rl-001: roles/ files run only as the RDS master aa_cis_admin (session user is %)',
            session_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bk_owner') THEN
        CREATE ROLE bk_owner NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'tp_owner') THEN
        CREATE ROLE tp_owner NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cis_app') THEN
        CREATE ROLE cis_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS CONNECTION LIMIT 90;
    END IF;
END $$;

ALTER ROLE bk_owner NOLOGIN;
ALTER ROLE tp_owner NOLOGIN;
ALTER ROLE cis_app LOGIN CONNECTION LIMIT 90;

GRANT bk_owner, tp_owner TO aa_cis_admin;
GRANT cis_app TO aa_cis_admin;

-- N3 limits (CIS 234, data standards C2.2 / C2.3a), restated in the bootstrap.
ALTER ROLE tripplanner CONNECTION LIMIT 30;
ALTER ROLE booking CONNECTION LIMIT 15;
ALTER ROLE aa_app_user CONNECTION LIMIT 15;

-- Guards: the roles have exactly the shape X1 needs.
DO $$
DECLARE
    bad text;
BEGIN
    SELECT string_agg(rolname, ', ' ORDER BY rolname) INTO bad
      FROM pg_roles
     WHERE rolname IN ('bk_owner', 'tp_owner')
       AND (rolcanlogin OR rolsuper OR rolbypassrls OR rolcreaterole OR rolcreatedb OR rolreplication);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'rl-001: owner role(s) % must be NOLOGIN, no SUPERUSER/BYPASSRLS/CREATEROLE/CREATEDB/REPLICATION', bad;
    END IF;
    IF (SELECT count(*) FROM pg_roles WHERE rolname IN ('bk_owner', 'tp_owner', 'cis_app')) <> 3 THEN
        RAISE EXCEPTION 'rl-001: bk_owner, tp_owner or cis_app missing';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles
                    WHERE rolname = 'cis_app' AND rolcanlogin AND rolconnlimit = 90
                      AND NOT (rolsuper OR rolbypassrls OR rolcreaterole OR rolcreatedb OR rolreplication)) THEN
        RAISE EXCEPTION 'rl-001: cis_app must be LOGIN, CONNECTION LIMIT 90, no SUPERUSER/BYPASSRLS/CREATEROLE/CREATEDB/REPLICATION';
    END IF;
    -- The new roles are members of nothing (no inherited rights, no policy TO r reaching them).
    SELECT string_agg(m.member::regrole::text || ' in ' || m.roleid::regrole::text, ', ') INTO bad
      FROM pg_auth_members m
     WHERE m.member IN (SELECT oid FROM pg_roles WHERE rolname IN ('bk_owner', 'tp_owner', 'cis_app'));
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'rl-001: new roles must not be members of any role: %', bad;
    END IF;
    IF NOT (pg_has_role('aa_cis_admin', 'bk_owner', 'MEMBER') AND pg_has_role('aa_cis_admin', 'tp_owner', 'MEMBER')
            AND pg_has_role('aa_cis_admin', 'cis_app', 'MEMBER')) THEN
        RAISE EXCEPTION 'rl-001: aa_cis_admin must be a member of bk_owner, tp_owner and cis_app';
    END IF;
    -- §1.4: the master never becomes a member of the tenant pool role or the catalog view owner.
    IF pg_has_role('aa_cis_admin', 'aa_app_user', 'MEMBER') OR pg_has_role('aa_cis_admin', 'catalog_owner', 'MEMBER') THEN
        RAISE EXCEPTION 'rl-001: aa_cis_admin must not be a member of aa_app_user or catalog_owner (policies TO r reach members)';
    END IF;
    SELECT string_agg(rolname || '=' || rolconnlimit, ', ' ORDER BY rolname) INTO bad
      FROM pg_roles
     WHERE rolname IN ('tripplanner', 'booking', 'aa_app_user')
       AND (rolname, rolconnlimit) NOT IN (('tripplanner', 30), ('booking', 15), ('aa_app_user', 15));
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'rl-001: N3 connection limits not applied: %', bad;
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('rl-001', now(),
    'AA-852 (X1 S3): role bootstrap — bk_owner, tp_owner NOLOGIN (granted to aa_cis_admin); cis_app LOGIN '
    'CONNECTION LIMIT 90, no password (granted to aa_cis_admin for the 244 guards); N3 limits restated from 234 '
    '(tripplanner 30, booking 15, aa_app_user 15)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
