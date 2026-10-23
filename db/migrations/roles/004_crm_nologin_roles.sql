-- Migration rl-004: AA-932 — the partner CRM's NOLOGIN roles that crm_app reaches only by SET LOCAL ROLE
-- (design v3 §3.1 and §4.3, ADR 0010 decision 3, data standards DM-6.8): crm_ai_reader (F2 and AI views),
-- crm_insights (the insight-fact view), crm_support_reader (L2 support: non-F1 tables + audit insert) and
-- crm_eraser (crm.erase_subject() only).
--
-- Why. The CRM API runs every tenant request in tenant_tx() (AA-933). A request that feeds the AI, the insight
-- rollup, an owner-granted support window or an erasure narrows its rights for one transaction with
-- SET LOCAL ROLE <reader>; what each reader may read is granted by the owner's own crm-NNN files (CRM-06, CRM-09,
-- CRM-13a, CRM-33a), and the isolation probe asserts 42501 for every reader on the F1 vault tables (design §4.3).
-- Role DDL and role membership live only in roles/ (X1 role lint), so the roles and the memberships are here,
-- the object grants are not.
--
-- What.
--   * CREATE ROLE crm_ai_reader, crm_insights, crm_support_reader, crm_eraser NOLOGIN (if missing).
--   * ALTER ROLE crm_app NOINHERIT, then GRANT the four readers TO crm_app. NOINHERIT on PostgreSQL 15 is a
--     property of the member: crm_app can SET ROLE to a reader but never holds a reader's privileges in its own
--     session, and a row-level policy TO <reader> does not apply to crm_app either (policy roles are checked with
--     has_privs_of_role, which follows only INHERIT memberships; lesson S236: a policy TO r reaches the members
--     of r). crm_app is a member of nothing else (rl-003 guard), so NOINHERIT takes nothing away from it.
--   Never granted: a reader to any role but crm_app, any role to a reader, crm_owner to crm_app.
--
-- Depends on: rl-003 (crm_owner, crm_app, schema crm). Runs as the RDS master aa_cis_admin (roles/ file).
-- Not here: object grants to the readers (crm-NNN files), passwords (readers never log in).
-- Idempotent: re-running changes nothing.
--
-- Rollback: a forward roles/ file (MIG-14) that refuses while a reader owns anything or holds a grant, then
-- REVOKE <readers> FROM crm_app, DROP ROLE each reader, ALTER ROLE crm_app INHERIT.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '2min';

DO $$
DECLARE
    r text;
BEGIN
    IF session_user <> 'aa_cis_admin' THEN
        RAISE EXCEPTION 'rl-004: roles/ files run only as the RDS master aa_cis_admin (session user is %)',
            session_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'crm_app')
       OR (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'crm') IS DISTINCT FROM 'crm_owner' THEN
        RAISE EXCEPTION 'rl-004: apply roles/003_crm_roles.sql (rl-003) first: crm_app and schema crm owned by crm_owner';
    END IF;
    FOREACH r IN ARRAY ARRAY['crm_ai_reader', 'crm_insights', 'crm_support_reader', 'crm_eraser'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
            EXECUTE format('CREATE ROLE %I NOLOGIN', r);
        END IF;
    END LOOP;
END $$;

ALTER ROLE crm_ai_reader NOLOGIN;
ALTER ROLE crm_insights NOLOGIN;
ALTER ROLE crm_support_reader NOLOGIN;
ALTER ROLE crm_eraser NOLOGIN;
ALTER ROLE crm_app NOINHERIT;

GRANT crm_ai_reader, crm_insights, crm_support_reader, crm_eraser TO crm_app;

-- Guards: exactly the shape design v3 §3.1 asks for.
DO $$
DECLARE
    readers text[] := ARRAY['crm_ai_reader', 'crm_eraser', 'crm_insights', 'crm_support_reader'];
    bad text;
BEGIN
    SELECT string_agg(x, ', ') INTO bad
      FROM unnest(readers) AS x
     WHERE NOT EXISTS (SELECT 1 FROM pg_roles r
                        WHERE r.rolname = x AND NOT r.rolcanlogin
                          AND NOT (r.rolsuper OR r.rolbypassrls OR r.rolcreaterole OR r.rolcreatedb OR r.rolreplication));
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'rl-004: % must exist, NOLOGIN, no SUPERUSER/BYPASSRLS/CREATEROLE/CREATEDB/REPLICATION', bad;
    END IF;
    -- The readers are members of nothing (no inherited rights reach them) …
    SELECT string_agg(m.member::regrole::text || ' in ' || m.roleid::regrole::text, ', ') INTO bad
      FROM pg_auth_members m
     WHERE m.member::regrole::text = ANY(readers);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'rl-004: reader roles must not be members of any role: %', bad;
    END IF;
    -- … and are granted to crm_app only. PostgreSQL 16+ records the creating CREATEROLE role (the master) as an
    -- ADMIN member of every role it creates; PostgreSQL 15 (RDS today) does not. Only that row is tolerated.
    SELECT string_agg(m.member::regrole::text || ' -> ' || m.roleid::regrole::text, ', ') INTO bad
      FROM pg_auth_members m
     WHERE m.roleid::regrole::text = ANY(readers)
       AND m.member NOT IN ('crm_app'::regrole, 'aa_cis_admin'::regrole);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'rl-004: reader roles may be granted to crm_app only (found %)', bad;
    END IF;
    -- crm_app: NOINHERIT, member of exactly the four readers, still LOGIN with its limit, never of crm_owner.
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'crm_app' AND rolcanlogin AND NOT rolinherit
                      AND rolconnlimit = 6) THEN
        RAISE EXCEPTION 'rl-004: crm_app must be LOGIN, NOINHERIT, CONNECTION LIMIT 6';
    END IF;
    IF (SELECT array_agg(m.roleid::regrole::text ORDER BY m.roleid::regrole::text COLLATE "C")
          FROM pg_auth_members m WHERE m.member = 'crm_app'::regrole) IS DISTINCT FROM readers THEN
        RAISE EXCEPTION 'rl-004: crm_app must be a member of exactly %', readers;
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('rl-004', now(),
    'AA-932: partner CRM NOLOGIN roles crm_ai_reader, crm_insights, crm_support_reader, crm_eraser '
    '(granted to crm_app only; crm_app NOINHERIT, reaches them by SET LOCAL ROLE)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
