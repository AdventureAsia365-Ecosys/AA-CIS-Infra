-- Migration 245: AA-860 (X1 step S21) — every CIS schema and the objects in it move from the RDS master aa_cis_admin
-- to the NOLOGIN owner role cis_owner; cis_owner reads the 8 FORCE RLS tables like the master; the default
-- privileges of cis_app are restated FOR ROLE cis_owner.
-- migrate: lock_timeout=5s
--
-- Why (ADR 0008 decision 6, data standards SEC-1, DM-1.3; AA-Ecosys docs/audits/2026-10-17-S241-x1/x1-plan.md S21).
-- After X1 S18 the CIS runtime logs in as cis_app and owns nothing, but every CIS object is still owned by the RDS
-- master, which is also the DB Migrate login until S22. 245 gives the objects to cis_owner (created by the Infra
-- role bootstrap rl-002, X1 S20, which also makes the master and db_migrator members of it). From the commit of this
-- file DB Migrate runs every later cis/ file as cis_owner, because it reads the live owner of schema shared before
-- each file (AA-CIS-Infra db/run_migration.py, plan XD8); S22 then switches the DB Migrate login to db_migrator.
-- Ownership only: the master keeps every owner right through its membership of cis_owner (break-glass, DM-8.9).
--
-- RLS (the "own design pass" the S243 amendments of the plan ask for before 245). The master reads the 8 FORCE RLS
-- tables unfiltered (rds_superuser; AA-817 probe v2, lesson S236), so it is not filtered as their owner today.
-- cis_owner is a plain NOLOGIN role with no BYPASSRLS and is not in rds_superuser, so as the new owner it would be
-- filtered by FORCE: only tenant_isolation TO public would match, 0 rows without app.tenant_id. Two things run with
-- cis_owner's rights after this file and would silently change:
--   * every later cis/ file (DB Migrate SET ROLE cis_owner): a data migration or guard on raw_tours,
--     published_tours, … would see 0 rows and update nothing;
--   * every view in the CIS schemas (not security_invoker: it reads its base tables, RLS included, as its OWNER):
--     acp_contract.v_active_tour_atoms (read by TripPlanner and the runtime) and v_trip_registry read
--     published_tours / raw_tours; the shared.* views; the catalog_owner views that read them.
-- Chosen: a permissive policy <table>_cis_owner_all FOR ALL TO cis_owner USING (true) WITH CHECK (true) on the 8
-- FORCE tables, the same shape as 244's cis_app policies. It keeps FORCE (SEC-7 wants FORCE on CIS tables after the
-- split) and reaches only cis_owner and its members: the master (reads unfiltered already) and db_migrator (whose
-- results are never tenant-isolation evidence; the isolation probe uses each runtime role's own DSN). Rejected:
-- ALTER TABLE … NO FORCE ROW LEVEL SECURITY on the 8 tables (the owner would be exempt, but every later member of
-- cis_owner and any future owner-run code would bypass tenant_isolation with no policy to show it, and FORCE would
-- have to be re-added at the SEC-7 follow-up). The ENABLE-only tables need nothing: the owner is exempt there.
-- Nobody but the master and db_migrator may be a member of cis_owner (guards 0 and 8g): a member reads every tenant.
--
-- What.
--   0. Guard: the master runs this, before the transfer; cis_owner exists with rl-002's shape (NOLOGIN, no special
--      attribute, member of nothing, CREATE on the database for ALTER SCHEMA … OWNER), the master is a member of
--      cis_owner and of cis_app, cis_owner has no other member than the master and db_migrator, 244 is applied.
--   1. LOCK TABLE every table of the 11 runtime schemas IN ACCESS EXCLUSIVE MODE, one statement, shared.job first:
--      all locks before anything changes (lock_timeout 5s), and nothing writes between the counts of step 2 and the
--      checks of step 9. The views are not locked (no data; their base tables are).
--   2. Snapshots, as the master, kept in transaction-local settings x1_245.*: the privileges of every role other than
--      the owner on the 12 schemas and everything in them (relations, columns, routines, types), owner-independent;
--      every RLS policy; count(*) without app.tenant_id and under a forged foreign one of each FORCE table and
--      tenant_tour_versions, and of every view of the 12 schemas the master can read (the catalog_owner views need
--      pg_read_all_data, which the master has through rds_superuser; a view it cannot read is skipped with a
--      NOTICE). Taken BEFORE step 5: the master is a member of cis_owner, and a policy TO cis_owner applies to it.
--   3. ALTER SCHEMA … OWNER TO cis_owner for the 12 owners.yaml CIS schemas (acp_contract, acp_deliver,
--      acp_gold_output, acp_shared, acp_silver_s2, acp_silver_s3, acp_silver_s4, catalog, geo, gold_aa_internal,
--      shared, silver_aa_internal). Schemas first: the new owner needs CREATE on them.
--   4. Every object the master owns in the 11 runtime schemas (not in catalog: its 14 views stay catalog_owner's,
--      only the schema moves) goes to cis_owner, read from the catalog at apply time: tables, partitioned tables,
--      views, materialized views, foreign tables (their indexes, row types and owned / identity sequences follow),
--      standalone sequences, standalone composite types, enum / domain / range types (their array types follow),
--      functions, procedures, aggregates, extended statistics, collations, conversions, text search dictionaries and
--      configurations. Extension members (pg_depend deptype e) and public.* stay with the master (they belong to
--      Infra roles/, owners.yaml). One NOTICE per object and a total, so the DB Migrate log lists what moved.
--      Catalog-driven on purpose (AA-860 S21 notes): the schema reference lists tables, views, functions and enum
--      names but not standalone sequences, type owners, domains, ranges or statistics, and CIS 247–250 (applied on
--      Dev before this file) add objects a hand list would have to chase. Guard 8a is the strict backstop: any object
--      left behind, or owned by a third role, fails the file. The read-only AA-CIS-Infra run-script
--      db/scripts/x1_245_cis_owner_objects.py prints the same list from Dev before apply.
--   5. The 8 FORCE-table policies <table>_cis_owner_all (see RLS above), DROP IF EXISTS first (re-runnable).
--   6. Default privileges: ALTER DEFAULT PRIVILEGES FOR ROLE cis_owner IN SCHEMA <the 11 runtime schemas> GRANT the
--      244 rows to cis_app (tables DML, sequences USAGE / SELECT / UPDATE, functions EXECUTE; owners.yaml
--      runtime_privileges.cis_app.default_acl, XD3), and REVOKE the same rows FOR ROLE aa_cis_admin: the master
--      creates nothing in these schemas any more, and objects a later cis/ file creates as cis_owner reach cis_app.
--      REVOKE INSERT, UPDATE, DELETE ON shared.schema_versions FROM cis_app restated (244; default privileges never
--      touch an existing table, the ownership change keeps the ACL).
--   7. Register 245.
--   8. Guards (after the registration), RAISE on failure:
--      a. ownership: every schema of the 12 and every object in the 11 runtime schemas (extension members aside)
--         belongs to cis_owner; every relation in schema catalog belongs to catalog_owner (14 views today) and every
--         other object there to cis_owner; so 0 CIS objects belong to the master;
--      b. no SECURITY DEFINER routine in the 12 schemas (the owner change would change who it runs as);
--      c. the privilege snapshot of step 2 is unchanged (ALTER … OWNER rewrites grantor and owner entries only):
--         aa_app_user, tripplanner, booking, catalog_owner, bk_owner, tp_owner, cis_app and PUBLIC keep exactly
--         their grants, column grants included;
--      d. the policies are step 2's plus exactly the 8 <table>_cis_owner_all, and no other policy names cis_owner;
--         the FORCE RLS tables of the 12 schemas are exactly the 8 (a new FORCE table needs its cis_owner policy
--         decided in its own migration);
--      e. default privileges in the 12 schemas: no row FOR ROLE other than cis_owner, and FOR ROLE cis_owner exactly
--         the 33 rows of step 6, to cis_app only;
--      f. catalog: catalog_owner keeps USAGE on every schema and SELECT on every relation a catalog.* view reads
--         (its views read their base tables as catalog_owner; the master is not a member of catalog_owner and must
--         never become one, so this file never switches to it — XD9);
--      g. cis_owner is NOLOGIN, member of nothing, and its only members are the master and db_migrator; cis_app
--         reads shared.schema_versions and never writes it.
--   9. Behaviour, last (SET LOCAL ROLE lasts until COMMIT, so nothing else runs as the switched role; DB Migrate's own
--      reads after COMMIT run as the login role again):
--      a. as the master: every view counted in step 2 returns the same count, without a GUC and under the forged
--         one (each view now reads its base tables as cis_owner, or as catalog_owner);
--      b. SET LOCAL ROLE cis_owner: each FORCE table and tenant_tour_versions returns the master's step-2 count, both
--         ways (parity for later cis/ files); booking.customers / tripplanner.sessions raise insufficient_privilege;
--      c. SET LOCAL ROLE cis_app: the same parity (244 still holds after the transfer); cis_app may UPDATE shared.job;
--         INSERT / DELETE on shared.schema_versions and SELECT on booking.customers / tripplanner.sessions raise
--         insufficient_privilege (checked where those tables exist: on Dev always; CI builds stand-ins).
--
-- Dev order (S243). 245 is numbered before 247–250 but is applied on Dev after them (and after 244). Step 4 reads the
-- catalog at apply time, so their objects (shared.staff_app_grant, 248's audit triggers and cost snapshot, …) move
-- too, and guard 8c keeps the grants 244 gave on them. The conftest replay skips 245 (like 244: its policies trip the
-- exact-policy guards 229/237/239/241, which their tests re-apply); tests/integration/test_aa860_migration_245.py
-- applies it after the full replay as an RDS-like master, the Dev order, and removes it at teardown.
--
-- Runs as the login role: when the file starts, schema shared still belongs to the master, so DB Migrate does not
-- switch (XD8). The runner's reach check passes because rl-002 made the master a member of cis_owner and rl-001 a
-- member of cis_app (SET LOCAL ROLE checks the session user). Idempotent only as the master (CI re-runs it): after
-- the transfer DB Migrate would run it as cis_owner and guard 0 refuses; a forced redo or the undo is a roles/ file.
--
-- Locks. ACCESS EXCLUSIVE on every CIS table (step 1) and on every view, sequence, function and type it alters, held
-- until COMMIT: CIS api and worker requests, TripPlanner browse (published_tours, atoms, catalog.*) and Booking's
-- catalog reads wait for the file — a few seconds, mostly the view counts (catalog.v_tour_place scans every live
-- tour, ~1 s per count). Apply only with shared.job / booking.job idle and no wave (DB Migrate's idle check);
-- lock_timeout 5s: if any lock is not free in time the file fails before changing anything. Retry when it is quiet.
--
-- Freeze (plan S21). CIS migration freeze from the Infra copy of this file until S22's 246 probe passes: no other CIS
-- file is copied to Infra or applied in between, so the first file to run as cis_owner is the 246 probe.
--
-- After apply: regenerate docs/architecture/db-schema-reference.md (DB Schema Dump): schemas and objects owned by
-- cis_owner, 8 policies <table>_cis_owner_all, default privileges FOR ROLE cis_owner → cis_app and none FOR ROLE
-- aa_cis_admin in the CIS schemas. Isolation probe: ownership.cis, runtime_grants.cis and default_acl.cis expected
-- (state key 245 + shared owned by cis_owner) and passing.
--
-- Rollback: not a cis/ file (it would run as cis_owner, which cannot give objects to the master). A prepared, unmerged
-- Infra-native roles/ undo (key rl-NNN), AA-Ecosys docs/audits/2026-10-17-S241-x1/s21-undo/: owners back to the
-- master (catalog-driven, so objects created after 245 go back too), the 8 cis_owner policies dropped, the default
-- privileges back FOR ROLE aa_cis_admin. Applying it turns the runner back to the master for cis/ automatically and
-- the probe's CIS ownership cells back to pending. Never key 246 (the S22 probe key).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '15min';

-- ── 0. Guard: who runs this, and rl-002 / 244 are in place ──────────────────────────────────────────
DO $$
DECLARE
    r    record;
    bad  text;
BEGIN
    IF current_user <> 'aa_cis_admin' OR session_user <> current_user THEN
        RAISE EXCEPTION 'migration 245: runs only as the RDS master aa_cis_admin before the transfer (current_user %, session_user %); a redo after it is a roles/ file',
            current_user, session_user;
    END IF;
    SELECT * INTO r FROM pg_catalog.pg_roles WHERE rolname = 'cis_owner';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'migration 245: role cis_owner does not exist — apply the Infra role bootstrap roles/002 (rl-002, X1 S20) first';
    END IF;
    IF r.rolcanlogin OR r.rolsuper OR r.rolbypassrls OR r.rolcreaterole OR r.rolcreatedb OR r.rolreplication THEN
        RAISE EXCEPTION 'migration 245: cis_owner must be NOLOGIN, no SUPERUSER / BYPASSRLS / CREATEROLE / CREATEDB / REPLICATION (rl-002)';
    END IF;
    SELECT string_agg(pg_catalog.pg_get_userbyid(m.roleid), ', ') INTO bad
      FROM pg_catalog.pg_auth_members m WHERE m.member = r.oid;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 245: cis_owner is a member of % (it must be a member of no role; a policy TO x reaches x''s members)', bad;
    END IF;
    IF NOT pg_catalog.pg_has_role(current_user, 'cis_owner', 'MEMBER') THEN
        RAISE EXCEPTION 'migration 245: % is not a member of cis_owner (rl-002 grants it to aa_cis_admin; ALTER … OWNER TO needs it)', current_user;
    END IF;
    IF NOT pg_catalog.pg_has_role(current_user, 'cis_app', 'MEMBER') THEN
        RAISE EXCEPTION 'migration 245: % is not a member of cis_app (rl-001; the behavioural block switches to it)', current_user;
    END IF;
    IF NOT pg_catalog.has_database_privilege('cis_owner', pg_catalog.current_database(), 'CREATE') THEN
        RAISE EXCEPTION 'migration 245: cis_owner has no CREATE on the database (rl-002; ALTER SCHEMA … OWNER TO needs it)';
    END IF;
    -- A member of cis_owner reads every tenant of the FORCE tables after this file (policies TO cis_owner).
    SELECT string_agg(x.rolname, ', ' ORDER BY x.rolname) INTO bad
      FROM pg_catalog.pg_roles x
     WHERE pg_catalog.pg_has_role(x.oid, 'cis_owner', 'MEMBER')
       AND x.rolname NOT IN ('cis_owner', 'aa_cis_admin', 'db_migrator') AND NOT x.rolsuper;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 245: only aa_cis_admin and db_migrator may be members of cis_owner, found also %', bad;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '244') THEN
        RAISE EXCEPTION 'migration 245: CIS 244 (cis_app grants, default privileges, parity policies) is not applied';
    END IF;
END $$;

-- ── 1. Every table lock, up front, in one statement ────────────────────────────────────────────────
DO $$
DECLARE
    stmt text;
BEGIN
    SELECT 'LOCK TABLE ' || string_agg(pg_catalog.format('%I.%I', n.nspname, c.relname), ', '
                                       ORDER BY (n.nspname = 'shared' AND c.relname = 'job') DESC,
                                                n.nspname, c.relname)
           || ' IN ACCESS EXCLUSIVE MODE'
      INTO stmt
      FROM pg_catalog.pg_class c
      JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = ANY (ARRAY['acp_contract', 'acp_deliver', 'acp_gold_output', 'acp_shared', 'acp_silver_s2',
                                  'acp_silver_s3', 'acp_silver_s4', 'geo', 'gold_aa_internal', 'shared',
                                  'silver_aa_internal'])
       AND c.relkind IN ('r', 'p');
    EXECUTE stmt;
END $$;

-- ── 2. Snapshots, before anything changes ──────────────────────────────────────────────────────────
-- Privileges of every role other than the owner, owner-independent (grantor and owner entries left out). Compared
-- in guard 8c with the same query.
SELECT pg_catalog.set_config('x1_245.privileges', coalesce(string_agg(p, E'\n' ORDER BY p), ''), true)
FROM (
    SELECT pg_catalog.format('schema %I: %s %s %s', n.nspname, a.grantee::regrole, a.privilege_type, a.is_grantable) AS p
      FROM pg_catalog.pg_namespace n,
           pg_catalog.aclexplode(coalesce(n.nspacl, pg_catalog.acldefault('n', n.nspowner))) a
     WHERE n.nspname = ANY (ARRAY['acp_contract', 'acp_deliver', 'acp_gold_output', 'acp_shared', 'acp_silver_s2',
                                  'acp_silver_s3', 'acp_silver_s4', 'catalog', 'geo', 'gold_aa_internal', 'shared',
                                  'silver_aa_internal'])
       AND a.grantee <> n.nspowner
    UNION ALL
    SELECT pg_catalog.format('rel %I.%I: %s %s %s', n.nspname, c.relname, a.grantee::regrole, a.privilege_type, a.is_grantable)
      FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace,
           pg_catalog.aclexplode(coalesce(c.relacl, pg_catalog.acldefault(
               CASE WHEN c.relkind = 'S' THEN 's'::"char" ELSE 'r'::"char" END, c.relowner))) a
     WHERE n.nspname = ANY (ARRAY['acp_contract', 'acp_deliver', 'acp_gold_output', 'acp_shared', 'acp_silver_s2',
                                  'acp_silver_s3', 'acp_silver_s4', 'catalog', 'geo', 'gold_aa_internal', 'shared',
                                  'silver_aa_internal'])
       AND c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S') AND a.grantee <> c.relowner
    UNION ALL
    SELECT pg_catalog.format('col %I.%I.%I: %s %s %s', n.nspname, c.relname, t.attname, a.grantee::regrole,
                             a.privilege_type, a.is_grantable)
      FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_catalog.pg_attribute t ON t.attrelid = c.oid,
           pg_catalog.aclexplode(t.attacl) a
     WHERE n.nspname = ANY (ARRAY['acp_contract', 'acp_deliver', 'acp_gold_output', 'acp_shared', 'acp_silver_s2',
                                  'acp_silver_s3', 'acp_silver_s4', 'catalog', 'geo', 'gold_aa_internal', 'shared',
                                  'silver_aa_internal'])
       AND t.attacl IS NOT NULL AND a.grantee <> c.relowner
    UNION ALL
    SELECT pg_catalog.format('routine %I.%I(%s): %s %s %s', n.nspname, f.proname,
                             pg_catalog.pg_get_function_identity_arguments(f.oid), a.grantee::regrole,
                             a.privilege_type, a.is_grantable)
      FROM pg_catalog.pg_proc f JOIN pg_catalog.pg_namespace n ON n.oid = f.pronamespace,
           pg_catalog.aclexplode(coalesce(f.proacl, pg_catalog.acldefault('f', f.proowner))) a
     WHERE n.nspname = ANY (ARRAY['acp_contract', 'acp_deliver', 'acp_gold_output', 'acp_shared', 'acp_silver_s2',
                                  'acp_silver_s3', 'acp_silver_s4', 'catalog', 'geo', 'gold_aa_internal', 'shared',
                                  'silver_aa_internal'])
       AND a.grantee <> f.proowner
    UNION ALL
    SELECT pg_catalog.format('type %I.%I: %s %s %s', n.nspname, y.typname, a.grantee::regrole, a.privilege_type,
                             a.is_grantable)
      FROM pg_catalog.pg_type y JOIN pg_catalog.pg_namespace n ON n.oid = y.typnamespace,
           pg_catalog.aclexplode(coalesce(y.typacl, pg_catalog.acldefault('T', y.typowner))) a
     WHERE n.nspname = ANY (ARRAY['acp_contract', 'acp_deliver', 'acp_gold_output', 'acp_shared', 'acp_silver_s2',
                                  'acp_silver_s3', 'acp_silver_s4', 'catalog', 'geo', 'gold_aa_internal', 'shared',
                                  'silver_aa_internal'])
       AND a.grantee <> y.typowner
) s;

-- Every RLS policy of the database but the <table>_cis_owner_all ones (a re-run finds them; guard 8d: unchanged).
SELECT pg_catalog.set_config('x1_245.policies', coalesce(string_agg(p, E'\n' ORDER BY p), ''), true)
FROM (
    SELECT pg_catalog.format('%I.%I %I %s %s %s USING %s CHECK %s', n.nspname, c.relname, y.polname,
                             CASE WHEN y.polpermissive THEN 'permissive' ELSE 'restrictive' END, y.polcmd,
                             (SELECT string_agg(rn, ',' ORDER BY rn)
                                FROM (SELECT CASE WHEN x = 0 THEN 'public'
                                                  ELSE pg_catalog.pg_get_userbyid(x)::text END AS rn
                                        FROM unnest(y.polroles) x) rx),
                             coalesce(pg_catalog.pg_get_expr(y.polqual, y.polrelid), '-'),
                             coalesce(pg_catalog.pg_get_expr(y.polwithcheck, y.polrelid), '-')) AS p
      FROM pg_catalog.pg_policy y
      JOIN pg_catalog.pg_class c ON c.oid = y.polrelid
      JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
     WHERE y.polname NOT LIKE '%\_cis\_owner\_all'
) s;

-- What the master reads today: each FORCE table and tenant_tour_versions (compared as cis_owner and cis_app in 9b /
-- 9c), and every view of the 12 schemas it can read (compared as the master in 9a: each view then reads its base
-- tables with its new owner's rights). Without a GUC and under a forged foreign tenant.
DO $$
DECLARE
    parity_tables  text[] := ARRAY['gold_aa_internal.content_exports', 'gold_aa_internal.published_tours',
                                   'gold_aa_internal.webhook_deliveries', 'shared.pipeline_runs',
                                   'silver_aa_internal.generated_content', 'silver_aa_internal.quality_scores',
                                   'silver_aa_internal.raw_tours', 'silver_aa_internal.seo_context',
                                   'gold_aa_internal.tenant_tour_versions'];
    views          text[] := '{}';
    v              record;
    forged         text := gen_random_uuid()::text;
    plain_counts   bigint[] := '{}';
    forged_counts  bigint[] := '{}';
    vplain         bigint[] := '{}';
    vforged        bigint[] := '{}';
    n              bigint;
    i              int;
BEGIN
    FOR v IN
        SELECT pg_catalog.format('%I.%I', ns.nspname, c.relname) AS name,
               pg_catalog.has_table_privilege(c.oid, 'SELECT') AS readable
          FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace ns ON ns.oid = c.relnamespace
         WHERE ns.nspname = ANY (ARRAY['acp_contract', 'acp_deliver', 'acp_gold_output', 'acp_shared', 'acp_silver_s2',
                                       'acp_silver_s3', 'acp_silver_s4', 'catalog', 'geo', 'gold_aa_internal',
                                       'shared', 'silver_aa_internal'])
           AND c.relkind = 'v'
         ORDER BY 1
    LOOP
        IF v.readable THEN
            views := views || v.name;
        ELSE
            RAISE NOTICE 'migration 245: % is not readable by %, its count parity is skipped (the probe and the S21 live checks cover it)',
                v.name, current_user;
        END IF;
    END LOOP;

    PERFORM pg_catalog.set_config('app.tenant_id', '', true);
    FOR i IN 1 .. coalesce(array_length(parity_tables, 1), 0) LOOP
        EXECUTE pg_catalog.format('SELECT count(*) FROM %s', parity_tables[i]) INTO n;
        plain_counts := plain_counts || n;
    END LOOP;
    FOR i IN 1 .. coalesce(array_length(views, 1), 0) LOOP
        EXECUTE pg_catalog.format('SELECT count(*) FROM %s', views[i]) INTO n;
        vplain := vplain || n;
    END LOOP;
    PERFORM pg_catalog.set_config('app.tenant_id', forged, true);
    FOR i IN 1 .. coalesce(array_length(parity_tables, 1), 0) LOOP
        EXECUTE pg_catalog.format('SELECT count(*) FROM %s', parity_tables[i]) INTO n;
        forged_counts := forged_counts || n;
    END LOOP;
    FOR i IN 1 .. coalesce(array_length(views, 1), 0) LOOP
        EXECUTE pg_catalog.format('SELECT count(*) FROM %s', views[i]) INTO n;
        vforged := vforged || n;
    END LOOP;
    PERFORM pg_catalog.set_config('app.tenant_id', '', true);

    PERFORM pg_catalog.set_config('x1_245.forged', forged, true);
    PERFORM pg_catalog.set_config('x1_245.tables', array_to_string(parity_tables, ','), true);
    PERFORM pg_catalog.set_config('x1_245.master_plain', array_to_string(plain_counts, ','), true);
    PERFORM pg_catalog.set_config('x1_245.master_forged', array_to_string(forged_counts, ','), true);
    PERFORM pg_catalog.set_config('x1_245.views', array_to_string(views, ','), true);
    PERFORM pg_catalog.set_config('x1_245.views_plain', array_to_string(vplain, ','), true);
    PERFORM pg_catalog.set_config('x1_245.views_forged', array_to_string(vforged, ','), true);
END $$;

-- ── 3. The schemas ─────────────────────────────────────────────────────────────────────────────────
ALTER SCHEMA acp_contract OWNER TO cis_owner;
ALTER SCHEMA acp_deliver OWNER TO cis_owner;
ALTER SCHEMA acp_gold_output OWNER TO cis_owner;
ALTER SCHEMA acp_shared OWNER TO cis_owner;
ALTER SCHEMA acp_silver_s2 OWNER TO cis_owner;
ALTER SCHEMA acp_silver_s3 OWNER TO cis_owner;
ALTER SCHEMA acp_silver_s4 OWNER TO cis_owner;
ALTER SCHEMA catalog OWNER TO cis_owner;
ALTER SCHEMA geo OWNER TO cis_owner;
ALTER SCHEMA gold_aa_internal OWNER TO cis_owner;
ALTER SCHEMA shared OWNER TO cis_owner;
ALTER SCHEMA silver_aa_internal OWNER TO cis_owner;

-- ── 4. Every object the master owns in the 11 runtime schemas ─────────────────────────────────────
DO $$
DECLARE
    o      record;
    moved  int := 0;
BEGIN
    FOR o IN
        WITH s AS (
            SELECT ns.oid, ns.nspname FROM pg_catalog.pg_namespace ns
             WHERE ns.nspname = ANY (ARRAY['acp_contract', 'acp_deliver', 'acp_gold_output', 'acp_shared',
                                           'acp_silver_s2', 'acp_silver_s3', 'acp_silver_s4', 'geo',
                                           'gold_aa_internal', 'shared', 'silver_aa_internal'])),
        ext AS (SELECT d.classid, d.objid FROM pg_catalog.pg_depend d WHERE d.deptype = 'e'),
        master AS (SELECT r.oid FROM pg_catalog.pg_roles r WHERE r.rolname = 'aa_cis_admin'),
        objects AS (
            -- relations; indexes, toast, row types and owned / identity sequences follow their table
            SELECT 1 AS ord,
                   CASE c.relkind WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW' WHEN 'f' THEN 'FOREIGN TABLE'
                                  WHEN 'S' THEN 'SEQUENCE' WHEN 'c' THEN 'TYPE' ELSE 'TABLE' END AS kind,
                   pg_catalog.format('%I.%I', s.nspname, c.relname) AS name
              FROM pg_catalog.pg_class c JOIN s ON s.oid = c.relnamespace
             WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S', 'c')
               AND c.relowner = (SELECT oid FROM master)
               AND NOT EXISTS (SELECT 1 FROM ext WHERE ext.classid = 'pg_catalog.pg_class'::regclass AND ext.objid = c.oid)
               AND NOT (c.relkind = 'S' AND EXISTS (
                        SELECT 1 FROM pg_catalog.pg_depend d
                         WHERE d.classid = 'pg_catalog.pg_class'::regclass AND d.objid = c.oid
                           AND d.refclassid = 'pg_catalog.pg_class'::regclass AND d.deptype IN ('a', 'i')))
            UNION ALL
            -- enum, domain and range types (their array types follow; composite row types are relations above)
            SELECT 2, CASE y.typtype WHEN 'd' THEN 'DOMAIN' ELSE 'TYPE' END, pg_catalog.format('%I.%I', s.nspname, y.typname)
              FROM pg_catalog.pg_type y JOIN s ON s.oid = y.typnamespace
             WHERE y.typtype IN ('e', 'd', 'r') AND y.typowner = (SELECT oid FROM master)
               AND NOT EXISTS (SELECT 1 FROM ext WHERE ext.classid = 'pg_catalog.pg_type'::regclass AND ext.objid = y.oid)
            UNION ALL
            SELECT 3, CASE f.prokind WHEN 'p' THEN 'PROCEDURE' WHEN 'a' THEN 'AGGREGATE' ELSE 'FUNCTION' END,
                   pg_catalog.format('%I.%I(%s)', s.nspname, f.proname, pg_catalog.pg_get_function_identity_arguments(f.oid))
              FROM pg_catalog.pg_proc f JOIN s ON s.oid = f.pronamespace
             WHERE f.proowner = (SELECT oid FROM master)
               AND NOT EXISTS (SELECT 1 FROM ext WHERE ext.classid = 'pg_catalog.pg_proc'::regclass AND ext.objid = f.oid)
            UNION ALL
            SELECT 4, 'STATISTICS', pg_catalog.format('%I.%I', s.nspname, x.stxname)
              FROM pg_catalog.pg_statistic_ext x JOIN s ON s.oid = x.stxnamespace
             WHERE x.stxowner = (SELECT oid FROM master)
            UNION ALL
            SELECT 5, 'COLLATION', pg_catalog.format('%I.%I', s.nspname, x.collname)
              FROM pg_catalog.pg_collation x JOIN s ON s.oid = x.collnamespace
             WHERE x.collowner = (SELECT oid FROM master)
               AND NOT EXISTS (SELECT 1 FROM ext WHERE ext.classid = 'pg_catalog.pg_collation'::regclass AND ext.objid = x.oid)
            UNION ALL
            SELECT 6, 'CONVERSION', pg_catalog.format('%I.%I', s.nspname, x.conname)
              FROM pg_catalog.pg_conversion x JOIN s ON s.oid = x.connamespace
             WHERE x.conowner = (SELECT oid FROM master)
               AND NOT EXISTS (SELECT 1 FROM ext WHERE ext.classid = 'pg_catalog.pg_conversion'::regclass AND ext.objid = x.oid)
            UNION ALL
            SELECT 7, 'TEXT SEARCH DICTIONARY', pg_catalog.format('%I.%I', s.nspname, x.dictname)
              FROM pg_catalog.pg_ts_dict x JOIN s ON s.oid = x.dictnamespace
             WHERE x.dictowner = (SELECT oid FROM master)
               AND NOT EXISTS (SELECT 1 FROM ext WHERE ext.classid = 'pg_catalog.pg_ts_dict'::regclass AND ext.objid = x.oid)
            UNION ALL
            SELECT 8, 'TEXT SEARCH CONFIGURATION', pg_catalog.format('%I.%I', s.nspname, x.cfgname)
              FROM pg_catalog.pg_ts_config x JOIN s ON s.oid = x.cfgnamespace
             WHERE x.cfgowner = (SELECT oid FROM master)
               AND NOT EXISTS (SELECT 1 FROM ext WHERE ext.classid = 'pg_catalog.pg_ts_config'::regclass AND ext.objid = x.oid))
        SELECT kind, name FROM objects ORDER BY ord, name
    LOOP
        EXECUTE pg_catalog.format('ALTER %s %s OWNER TO cis_owner', o.kind, o.name);
        moved := moved + 1;
        RAISE NOTICE 'migration 245: % % -> cis_owner', lower(o.kind), o.name;
    END LOOP;
    RAISE NOTICE 'migration 245: % object(s) moved to cis_owner (plus the 12 schemas)', moved;
END $$;

-- ── 5. cis_owner reads the FORCE tables like the master (see RLS in the header) ───────────────────
DROP POLICY IF EXISTS content_exports_cis_owner_all ON gold_aa_internal.content_exports;
DROP POLICY IF EXISTS published_tours_cis_owner_all ON gold_aa_internal.published_tours;
DROP POLICY IF EXISTS webhook_deliveries_cis_owner_all ON gold_aa_internal.webhook_deliveries;
DROP POLICY IF EXISTS pipeline_runs_cis_owner_all ON shared.pipeline_runs;
DROP POLICY IF EXISTS generated_content_cis_owner_all ON silver_aa_internal.generated_content;
DROP POLICY IF EXISTS quality_scores_cis_owner_all ON silver_aa_internal.quality_scores;
DROP POLICY IF EXISTS raw_tours_cis_owner_all ON silver_aa_internal.raw_tours;
DROP POLICY IF EXISTS seo_context_cis_owner_all ON silver_aa_internal.seo_context;

CREATE POLICY content_exports_cis_owner_all ON gold_aa_internal.content_exports
    AS PERMISSIVE FOR ALL TO cis_owner USING (true) WITH CHECK (true);
CREATE POLICY published_tours_cis_owner_all ON gold_aa_internal.published_tours
    AS PERMISSIVE FOR ALL TO cis_owner USING (true) WITH CHECK (true);
CREATE POLICY webhook_deliveries_cis_owner_all ON gold_aa_internal.webhook_deliveries
    AS PERMISSIVE FOR ALL TO cis_owner USING (true) WITH CHECK (true);
CREATE POLICY pipeline_runs_cis_owner_all ON shared.pipeline_runs
    AS PERMISSIVE FOR ALL TO cis_owner USING (true) WITH CHECK (true);
CREATE POLICY generated_content_cis_owner_all ON silver_aa_internal.generated_content
    AS PERMISSIVE FOR ALL TO cis_owner USING (true) WITH CHECK (true);
CREATE POLICY quality_scores_cis_owner_all ON silver_aa_internal.quality_scores
    AS PERMISSIVE FOR ALL TO cis_owner USING (true) WITH CHECK (true);
CREATE POLICY raw_tours_cis_owner_all ON silver_aa_internal.raw_tours
    AS PERMISSIVE FOR ALL TO cis_owner USING (true) WITH CHECK (true);
CREATE POLICY seo_context_cis_owner_all ON silver_aa_internal.seo_context
    AS PERMISSIVE FOR ALL TO cis_owner USING (true) WITH CHECK (true);

-- ── 6. Default privileges: 244's rows, restated for the new creator ──────────────────────────────
ALTER DEFAULT PRIVILEGES FOR ROLE cis_owner IN SCHEMA acp_contract, acp_deliver, acp_gold_output, acp_shared,
    acp_silver_s2, acp_silver_s3, acp_silver_s4, geo, gold_aa_internal, shared, silver_aa_internal
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO cis_app;
ALTER DEFAULT PRIVILEGES FOR ROLE cis_owner IN SCHEMA acp_contract, acp_deliver, acp_gold_output, acp_shared,
    acp_silver_s2, acp_silver_s3, acp_silver_s4, geo, gold_aa_internal, shared, silver_aa_internal
    GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO cis_app;
ALTER DEFAULT PRIVILEGES FOR ROLE cis_owner IN SCHEMA acp_contract, acp_deliver, acp_gold_output, acp_shared,
    acp_silver_s2, acp_silver_s3, acp_silver_s4, geo, gold_aa_internal, shared, silver_aa_internal
    GRANT EXECUTE ON FUNCTIONS TO cis_app;

ALTER DEFAULT PRIVILEGES FOR ROLE aa_cis_admin IN SCHEMA acp_contract, acp_deliver, acp_gold_output, acp_shared,
    acp_silver_s2, acp_silver_s3, acp_silver_s4, geo, gold_aa_internal, shared, silver_aa_internal
    REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLES FROM cis_app;
ALTER DEFAULT PRIVILEGES FOR ROLE aa_cis_admin IN SCHEMA acp_contract, acp_deliver, acp_gold_output, acp_shared,
    acp_silver_s2, acp_silver_s3, acp_silver_s4, geo, gold_aa_internal, shared, silver_aa_internal
    REVOKE USAGE, SELECT, UPDATE ON SEQUENCES FROM cis_app;
ALTER DEFAULT PRIVILEGES FOR ROLE aa_cis_admin IN SCHEMA acp_contract, acp_deliver, acp_gold_output, acp_shared,
    acp_silver_s2, acp_silver_s3, acp_silver_s4, geo, gold_aa_internal, shared, silver_aa_internal
    REVOKE EXECUTE ON FUNCTIONS FROM cis_app;

-- The runtime reads the migration registry but never writes it (244, restated).
REVOKE INSERT, UPDATE, DELETE ON shared.schema_versions FROM cis_app;

-- ── 7. Register ────────────────────────────────────────────────────────────────────────────────────
INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('245', now(), 'AA-860 (X1 S21): the 12 CIS schemas and every master-owned object in the 11 runtime schemas owned by cis_owner (catalog.* views stay catalog_owner); permissive policy TO cis_owner on the 8 FORCE RLS tables; default privileges of cis_app restated FOR ROLE cis_owner, FOR ROLE aa_cis_admin rows revoked')
ON CONFLICT (version) DO NOTHING;

-- ── 8. Guards by shape ─────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    all_schemas   text[] := ARRAY['acp_contract', 'acp_deliver', 'acp_gold_output', 'acp_shared', 'acp_silver_s2',
                                  'acp_silver_s3', 'acp_silver_s4', 'catalog', 'geo', 'gold_aa_internal', 'shared',
                                  'silver_aa_internal'];
    run_schemas   text[] := ARRAY['acp_contract', 'acp_deliver', 'acp_gold_output', 'acp_shared', 'acp_silver_s2',
                                  'acp_silver_s3', 'acp_silver_s4', 'geo', 'gold_aa_internal', 'shared',
                                  'silver_aa_internal'];
    forced        text[] := ARRAY['gold_aa_internal.content_exports', 'gold_aa_internal.published_tours',
                                  'gold_aa_internal.webhook_deliveries', 'shared.pipeline_runs',
                                  'silver_aa_internal.generated_content', 'silver_aa_internal.quality_scores',
                                  'silver_aa_internal.raw_tours', 'silver_aa_internal.seo_context'];
    bad           text;
    after_text    text;
    found_force   text[];
    r             record;
BEGIN
    -- a. ownership: everything with an owner in the 12 schemas (extension members aside)
    SELECT string_agg(o, ', ' ORDER BY o) INTO bad FROM (
        WITH s AS (SELECT ns.oid, ns.nspname, ns.nspowner FROM pg_catalog.pg_namespace ns
                    WHERE ns.nspname = ANY (all_schemas)),
        ext AS (SELECT d.classid, d.objid FROM pg_catalog.pg_depend d WHERE d.deptype = 'e'),
        owned AS (
            SELECT 'schema' AS kind, s.nspname::text AS name, s.nspowner AS owner, false AS in_catalog_rel, s.oid AS objid,
                   'pg_catalog.pg_namespace'::regclass AS classid
              FROM s
            UNION ALL
            SELECT 'relation ' || c.relkind::text, s.nspname || '.' || c.relname, c.relowner, s.nspname = 'catalog', c.oid,
                   'pg_catalog.pg_class'::regclass
              FROM pg_catalog.pg_class c JOIN s ON s.oid = c.relnamespace
             WHERE c.relkind NOT IN ('i', 'I')
            UNION ALL
            SELECT 'routine', s.nspname || '.' || f.proname, f.proowner, false, f.oid, 'pg_catalog.pg_proc'::regclass
              FROM pg_catalog.pg_proc f JOIN s ON s.oid = f.pronamespace
            UNION ALL
            SELECT 'type', s.nspname || '.' || y.typname, y.typowner, false, y.oid, 'pg_catalog.pg_type'::regclass
              FROM pg_catalog.pg_type y JOIN s ON s.oid = y.typnamespace
             WHERE y.typrelid = 0 AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_type a WHERE a.typarray = y.oid)
            UNION ALL
            SELECT 'statistics', s.nspname || '.' || x.stxname, x.stxowner, false, x.oid,
                   'pg_catalog.pg_statistic_ext'::regclass
              FROM pg_catalog.pg_statistic_ext x JOIN s ON s.oid = x.stxnamespace
            UNION ALL
            SELECT 'operator', s.nspname || '.' || x.oprname, x.oprowner, false, x.oid, 'pg_catalog.pg_operator'::regclass
              FROM pg_catalog.pg_operator x JOIN s ON s.oid = x.oprnamespace
            UNION ALL
            SELECT 'operator class', s.nspname || '.' || x.opcname, x.opcowner, false, x.oid,
                   'pg_catalog.pg_opclass'::regclass
              FROM pg_catalog.pg_opclass x JOIN s ON s.oid = x.opcnamespace
            UNION ALL
            SELECT 'operator family', s.nspname || '.' || x.opfname, x.opfowner, false, x.oid,
                   'pg_catalog.pg_opfamily'::regclass
              FROM pg_catalog.pg_opfamily x JOIN s ON s.oid = x.opfnamespace
            UNION ALL
            SELECT 'collation', s.nspname || '.' || x.collname, x.collowner, false, x.oid,
                   'pg_catalog.pg_collation'::regclass
              FROM pg_catalog.pg_collation x JOIN s ON s.oid = x.collnamespace
            UNION ALL
            SELECT 'conversion', s.nspname || '.' || x.conname, x.conowner, false, x.oid,
                   'pg_catalog.pg_conversion'::regclass
              FROM pg_catalog.pg_conversion x JOIN s ON s.oid = x.connamespace
            UNION ALL
            SELECT 'text search dictionary', s.nspname || '.' || x.dictname, x.dictowner, false, x.oid,
                   'pg_catalog.pg_ts_dict'::regclass
              FROM pg_catalog.pg_ts_dict x JOIN s ON s.oid = x.dictnamespace
            UNION ALL
            SELECT 'text search configuration', s.nspname || '.' || x.cfgname, x.cfgowner, false, x.oid,
                   'pg_catalog.pg_ts_config'::regclass
              FROM pg_catalog.pg_ts_config x JOIN s ON s.oid = x.cfgnamespace)
        SELECT pg_catalog.format('%s %s (%s)', kind, name, pg_catalog.pg_get_userbyid(owner)) AS o
          FROM owned
         WHERE NOT EXISTS (SELECT 1 FROM ext WHERE ext.classid = owned.classid AND ext.objid = owned.objid)
           AND pg_catalog.pg_get_userbyid(owner) <> CASE WHEN in_catalog_rel THEN 'catalog_owner' ELSE 'cis_owner' END
    ) x;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 245: objects with the wrong owner after the transfer (a third owner, or a kind step 4 does not move; catalog.* relations must stay catalog_owner''s): %', bad;
    END IF;

    -- b. no SECURITY DEFINER routine changes whose rights it runs with
    SELECT string_agg(n.nspname || '.' || f.proname, ', ') INTO bad
      FROM pg_catalog.pg_proc f JOIN pg_catalog.pg_namespace n ON n.oid = f.pronamespace
     WHERE n.nspname = ANY (all_schemas) AND f.prosecdef;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 245: SECURITY DEFINER routine(s) % would now run as cis_owner (MIG-6)', bad;
    END IF;

    -- c. privileges of every non-owner role unchanged (same query as step 2)
    SELECT coalesce(string_agg(p, E'\n' ORDER BY p), '') INTO after_text
    FROM (
        SELECT pg_catalog.format('schema %I: %s %s %s', n.nspname, a.grantee::regrole, a.privilege_type, a.is_grantable) AS p
          FROM pg_catalog.pg_namespace n,
               pg_catalog.aclexplode(coalesce(n.nspacl, pg_catalog.acldefault('n', n.nspowner))) a
         WHERE n.nspname = ANY (all_schemas) AND a.grantee <> n.nspowner
        UNION ALL
        SELECT pg_catalog.format('rel %I.%I: %s %s %s', n.nspname, c.relname, a.grantee::regrole, a.privilege_type, a.is_grantable)
          FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace,
               pg_catalog.aclexplode(coalesce(c.relacl, pg_catalog.acldefault(
                   CASE WHEN c.relkind = 'S' THEN 's'::"char" ELSE 'r'::"char" END, c.relowner))) a
         WHERE n.nspname = ANY (all_schemas) AND c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S') AND a.grantee <> c.relowner
        UNION ALL
        SELECT pg_catalog.format('col %I.%I.%I: %s %s %s', n.nspname, c.relname, t.attname, a.grantee::regrole,
                                 a.privilege_type, a.is_grantable)
          FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
          JOIN pg_catalog.pg_attribute t ON t.attrelid = c.oid,
               pg_catalog.aclexplode(t.attacl) a
         WHERE n.nspname = ANY (all_schemas) AND t.attacl IS NOT NULL AND a.grantee <> c.relowner
        UNION ALL
        SELECT pg_catalog.format('routine %I.%I(%s): %s %s %s', n.nspname, f.proname,
                                 pg_catalog.pg_get_function_identity_arguments(f.oid), a.grantee::regrole,
                                 a.privilege_type, a.is_grantable)
          FROM pg_catalog.pg_proc f JOIN pg_catalog.pg_namespace n ON n.oid = f.pronamespace,
               pg_catalog.aclexplode(coalesce(f.proacl, pg_catalog.acldefault('f', f.proowner))) a
         WHERE n.nspname = ANY (all_schemas) AND a.grantee <> f.proowner
        UNION ALL
        SELECT pg_catalog.format('type %I.%I: %s %s %s', n.nspname, y.typname, a.grantee::regrole, a.privilege_type,
                                 a.is_grantable)
          FROM pg_catalog.pg_type y JOIN pg_catalog.pg_namespace n ON n.oid = y.typnamespace,
               pg_catalog.aclexplode(coalesce(y.typacl, pg_catalog.acldefault('T', y.typowner))) a
         WHERE n.nspname = ANY (all_schemas) AND a.grantee <> y.typowner
    ) s;
    IF after_text IS DISTINCT FROM current_setting('x1_245.privileges') THEN
        SELECT string_agg(x, '; ') INTO bad FROM (
            (SELECT '-' || x FROM unnest(string_to_array(current_setting('x1_245.privileges'), E'\n')) x
             EXCEPT SELECT '-' || y FROM unnest(string_to_array(after_text, E'\n')) y)
            UNION ALL
            (SELECT '+' || y FROM unnest(string_to_array(after_text, E'\n')) y
             EXCEPT SELECT '+' || x FROM unnest(string_to_array(current_setting('x1_245.privileges'), E'\n')) x)) d(x);
        RAISE EXCEPTION 'migration 245: privileges of a non-owner role changed with the transfer: %', bad;
    END IF;

    -- d. policies: step 2's plus exactly the 8 cis_owner ones; the FORCE set is exactly the 8
    SELECT coalesce(string_agg(p, E'\n' ORDER BY p), '') INTO after_text
    FROM (
        SELECT pg_catalog.format('%I.%I %I %s %s %s USING %s CHECK %s', n.nspname, c.relname, y.polname,
                                 CASE WHEN y.polpermissive THEN 'permissive' ELSE 'restrictive' END, y.polcmd,
                                 (SELECT string_agg(rn, ',' ORDER BY rn)
                                    FROM (SELECT CASE WHEN x = 0 THEN 'public'
                                                      ELSE pg_catalog.pg_get_userbyid(x)::text END AS rn
                                            FROM unnest(y.polroles) x) rx),
                                 coalesce(pg_catalog.pg_get_expr(y.polqual, y.polrelid), '-'),
                                 coalesce(pg_catalog.pg_get_expr(y.polwithcheck, y.polrelid), '-')) AS p
          FROM pg_catalog.pg_policy y
          JOIN pg_catalog.pg_class c ON c.oid = y.polrelid
          JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
         WHERE y.polname NOT LIKE '%\_cis\_owner\_all'
    ) s;
    IF after_text IS DISTINCT FROM current_setting('x1_245.policies') THEN
        RAISE EXCEPTION 'migration 245: RLS policies other than <table>_cis_owner_all changed with the transfer';
    END IF;
    SELECT coalesce(array_agg(n.nspname || '.' || c.relname ORDER BY n.nspname || '.' || c.relname), '{}') INTO found_force
      FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = ANY (all_schemas) AND c.relrowsecurity AND c.relforcerowsecurity;
    IF found_force IS DISTINCT FROM (SELECT array_agg(t ORDER BY t) FROM unnest(forced) t) THEN
        RAISE EXCEPTION 'migration 245: FORCE RLS tables are % (expected %); a new FORCE table needs its cis_owner policy decided in its own migration',
            found_force, forced;
    END IF;
    SELECT string_agg(n.nspname || '.' || c.relname, ', ' ORDER BY n.nspname || '.' || c.relname) INTO bad
      FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = ANY (all_schemas) AND c.relrowsecurity AND c.relforcerowsecurity
       AND ((SELECT count(*) FROM pg_catalog.pg_policy p
              WHERE p.polrelid = c.oid AND 'cis_owner'::regrole::oid = ANY (p.polroles)) <> 1
            OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_policy p
                            WHERE p.polrelid = c.oid AND p.polname = c.relname || '_cis_owner_all' AND p.polpermissive
                              AND p.polcmd = '*' AND p.polroles = ARRAY['cis_owner'::regrole::oid]
                              AND pg_catalog.pg_get_expr(p.polqual, p.polrelid) = 'true'
                              AND pg_catalog.pg_get_expr(p.polwithcheck, p.polrelid) = 'true'));
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 245: FORCE RLS table(s) without exactly one permissive FOR ALL USING (true) WITH CHECK (true) policy <table>_cis_owner_all TO cis_owner: %', bad;
    END IF;
    SELECT string_agg(pg_catalog.format('%I.%I %I', n.nspname, c.relname, p.polname), ', ') INTO bad
      FROM pg_catalog.pg_policy p
      JOIN pg_catalog.pg_class c ON c.oid = p.polrelid
      JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
     WHERE (p.polname LIKE '%\_cis\_owner\_all' OR 'cis_owner'::regrole::oid = ANY (p.polroles))
       AND NOT (c.relforcerowsecurity AND n.nspname = ANY (all_schemas));
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 245: policies TO cis_owner outside the FORCE tables: %', bad;
    END IF;

    -- e. default privileges in the 12 schemas: FOR ROLE cis_owner only, exactly 244's rows to cis_app
    SELECT string_agg(pg_catalog.format('%s in %s', pg_catalog.pg_get_userbyid(d.defaclrole), n.nspname), ', ') INTO bad
      FROM pg_catalog.pg_default_acl d JOIN pg_catalog.pg_namespace n ON n.oid = d.defaclnamespace
     WHERE n.nspname = ANY (all_schemas) AND d.defaclrole <> 'cis_owner'::regrole;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 245: default privileges FOR ROLE other than cis_owner remain: %', bad;
    END IF;
    SELECT string_agg(pg_catalog.format('%s %s %s', n.nspname, d.defaclobjtype, a.grantee::regrole), ', ') INTO bad
      FROM pg_catalog.pg_default_acl d JOIN pg_catalog.pg_namespace n ON n.oid = d.defaclnamespace,
           pg_catalog.aclexplode(d.defaclacl) a
     WHERE n.nspname = ANY (all_schemas) AND a.grantee <> 'cis_app'::regrole;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 245: default privileges FOR ROLE cis_owner to roles other than cis_app: %', bad;
    END IF;
    FOR r IN
        SELECT s2 AS schema_name, o.objtype, o.privs
          FROM unnest(run_schemas) s2,
               (VALUES ('r'::"char", ARRAY['DELETE', 'INSERT', 'SELECT', 'UPDATE']),
                       ('S'::"char", ARRAY['SELECT', 'UPDATE', 'USAGE']),
                       ('f'::"char", ARRAY['EXECUTE'])) AS o(objtype, privs)
    LOOP
        IF (SELECT array_agg(x.privilege_type::text ORDER BY x.privilege_type::text)
              FROM pg_catalog.pg_default_acl d, pg_catalog.aclexplode(d.defaclacl) x
             WHERE d.defaclrole = 'cis_owner'::regrole::oid
               AND d.defaclnamespace = r.schema_name::regnamespace::oid
               AND d.defaclobjtype = r.objtype
               AND x.grantee = 'cis_app'::regrole::oid) IS DISTINCT FROM r.privs THEN
            RAISE EXCEPTION 'migration 245: default privileges FOR ROLE cis_owner IN SCHEMA % (type %) to cis_app are not %',
                r.schema_name, r.objtype, r.privs;
        END IF;
    END LOOP;
    IF (SELECT count(*) FROM pg_catalog.pg_default_acl d JOIN pg_catalog.pg_namespace n ON n.oid = d.defaclnamespace
         WHERE n.nspname = ANY (all_schemas)) <> 33 THEN
        RAISE EXCEPTION 'migration 245: expected exactly 33 default-privilege rows (11 schemas x tables, sequences, functions) in the CIS schemas';
    END IF;

    -- f. catalog_owner still reaches every relation its views read (and the schemas they are in)
    SELECT string_agg(DISTINCT pg_catalog.format('%I.%I', bn.nspname, b.relname), ', ') INTO bad
      FROM pg_catalog.pg_class v
      JOIN pg_catalog.pg_namespace vn ON vn.oid = v.relnamespace
      JOIN pg_catalog.pg_rewrite w ON w.ev_class = v.oid
      JOIN pg_catalog.pg_depend d ON d.classid = 'pg_catalog.pg_rewrite'::regclass AND d.objid = w.oid
                                 AND d.refclassid = 'pg_catalog.pg_class'::regclass AND d.refobjid <> v.oid
      JOIN pg_catalog.pg_class b ON b.oid = d.refobjid
      JOIN pg_catalog.pg_namespace bn ON bn.oid = b.relnamespace
     WHERE vn.nspname = 'catalog' AND v.relkind = 'v'
       AND (NOT pg_catalog.has_schema_privilege('catalog_owner', bn.oid, 'USAGE')
            OR NOT pg_catalog.has_table_privilege('catalog_owner', b.oid, 'SELECT'));
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 245: catalog_owner lost USAGE or SELECT on relation(s) its catalog.* views read: %', bad;
    END IF;

    -- g. the roles
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles x
                WHERE x.rolname = 'cis_owner'
                  AND (x.rolcanlogin OR x.rolsuper OR x.rolbypassrls OR x.rolcreaterole OR x.rolcreatedb OR x.rolreplication))
       OR EXISTS (SELECT 1 FROM pg_catalog.pg_auth_members m WHERE m.member = 'cis_owner'::regrole::oid) THEN
        RAISE EXCEPTION 'migration 245: cis_owner must be NOLOGIN with no special attribute and a member of no role';
    END IF;
    SELECT string_agg(x.rolname, ', ' ORDER BY x.rolname) INTO bad
      FROM pg_catalog.pg_roles x
     WHERE pg_catalog.pg_has_role(x.oid, 'cis_owner', 'MEMBER')
       AND x.rolname NOT IN ('cis_owner', 'aa_cis_admin', 'db_migrator') AND NOT x.rolsuper;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 245: only aa_cis_admin and db_migrator may be members of cis_owner, found also %', bad;
    END IF;
    IF NOT pg_catalog.has_table_privilege('cis_app', 'shared.schema_versions', 'SELECT')
       OR pg_catalog.has_table_privilege('cis_app', 'shared.schema_versions', 'INSERT')
       OR pg_catalog.has_table_privilege('cis_app', 'shared.schema_versions', 'UPDATE')
       OR pg_catalog.has_table_privilege('cis_app', 'shared.schema_versions', 'DELETE') THEN
        RAISE EXCEPTION 'migration 245: cis_app must read shared.schema_versions and never write it';
    END IF;
END $$;

-- ── 9. Behaviour (last: SET LOCAL ROLE lasts until COMMIT) ─────────────────────────────────────────
DO $$
DECLARE
    forged         text := current_setting('x1_245.forged');
    parity_tables  text[] := string_to_array(current_setting('x1_245.tables'), ',');
    master_plain   bigint[] := string_to_array(current_setting('x1_245.master_plain'), ',')::bigint[];
    master_forged  bigint[] := string_to_array(current_setting('x1_245.master_forged'), ',')::bigint[];
    views          text[] := string_to_array(nullif(current_setting('x1_245.views'), ''), ',');
    views_plain    bigint[] := string_to_array(nullif(current_setting('x1_245.views_plain'), ''), ',')::bigint[];
    views_forged   bigint[] := string_to_array(nullif(current_setting('x1_245.views_forged'), ''), ',')::bigint[];
    who            text;
    n              bigint;
    i              int;
    -- catalog lookups, not to_regclass(): name resolution would need USAGE on the other app's schema
    has_customers  boolean := EXISTS (SELECT 1 FROM pg_catalog.pg_class c
                                        JOIN pg_catalog.pg_namespace ns ON ns.oid = c.relnamespace
                                       WHERE ns.nspname = 'booking' AND c.relname = 'customers');
    has_sessions   boolean := EXISTS (SELECT 1 FROM pg_catalog.pg_class c
                                        JOIN pg_catalog.pg_namespace ns ON ns.oid = c.relnamespace
                                       WHERE ns.nspname = 'tripplanner' AND c.relname = 'sessions');
BEGIN
    -- a. as the master: each view now reads its base tables with its new owner's rights
    PERFORM pg_catalog.set_config('app.tenant_id', '', true);
    FOR i IN 1 .. coalesce(array_length(views, 1), 0) LOOP
        EXECUTE pg_catalog.format('SELECT count(*) FROM %s', views[i]) INTO n;
        IF n <> views_plain[i] THEN
            RAISE EXCEPTION 'migration 245: parity: view % returns % row(s) without app.tenant_id after the transfer, % before',
                views[i], n, views_plain[i];
        END IF;
    END LOOP;
    PERFORM pg_catalog.set_config('app.tenant_id', forged, true);
    FOR i IN 1 .. coalesce(array_length(views, 1), 0) LOOP
        EXECUTE pg_catalog.format('SELECT count(*) FROM %s', views[i]) INTO n;
        IF n <> views_forged[i] THEN
            RAISE EXCEPTION 'migration 245: parity: view % returns % row(s) under a foreign app.tenant_id after the transfer, % before',
                views[i], n, views_forged[i];
        END IF;
    END LOOP;

    -- b. as cis_owner (every later cis/ file), then c. as cis_app (the runtime)
    FOREACH who IN ARRAY ARRAY['cis_owner', 'cis_app'] LOOP
        IF who = 'cis_owner' THEN
            SET LOCAL ROLE cis_owner;
        ELSE
            SET LOCAL ROLE cis_app;
        END IF;
        PERFORM pg_catalog.set_config('app.tenant_id', forged, true);
        FOR i IN 1 .. array_length(parity_tables, 1) LOOP
            EXECUTE pg_catalog.format('SELECT count(*) FROM %s', parity_tables[i]) INTO n;
            IF n <> master_forged[i] THEN
                RAISE EXCEPTION 'migration 245: parity: % reads % row(s) of % under a foreign app.tenant_id, the master % before the transfer',
                    who, n, parity_tables[i], master_forged[i];
            END IF;
        END LOOP;
        PERFORM pg_catalog.set_config('app.tenant_id', '', true);
        FOR i IN 1 .. array_length(parity_tables, 1) LOOP
            EXECUTE pg_catalog.format('SELECT count(*) FROM %s', parity_tables[i]) INTO n;
            IF n <> master_plain[i] THEN
                RAISE EXCEPTION 'migration 245: parity: % reads % row(s) of % without app.tenant_id, the master % before the transfer',
                    who, n, parity_tables[i], master_plain[i];
            END IF;
        END LOOP;
        IF has_customers THEN
            BEGIN
                EXECUTE 'SELECT 1 FROM booking.customers LIMIT 1';
                RAISE EXCEPTION 'migration 245: % reads booking.customers', who;
            EXCEPTION WHEN insufficient_privilege THEN NULL;
            END;
        ELSE
            RAISE NOTICE 'migration 245: booking.customers absent, cross-app read check skipped (Dev has it)';
        END IF;
        IF has_sessions THEN
            BEGIN
                EXECUTE 'SELECT 1 FROM tripplanner.sessions LIMIT 1';
                RAISE EXCEPTION 'migration 245: % reads tripplanner.sessions', who;
            EXCEPTION WHEN insufficient_privilege THEN NULL;
            END;
        ELSE
            RAISE NOTICE 'migration 245: tripplanner.sessions absent, cross-app read check skipped (Dev has it)';
        END IF;
    END LOOP;

    -- c. the runtime still writes the job table and never the registry
    UPDATE shared.job SET status = status WHERE false;
    BEGIN
        -- EXECUTE keeps this refused probe row out of the Infra copy guard's registration parser.
        EXECUTE pg_catalog.format('INSERT INTO shared.schema_versions (version, applied_at, description) VALUES (%L, now(), %L)',
                                  'zz-245-guard', 'must be refused');
        RAISE EXCEPTION 'migration 245: cis_app can INSERT into shared.schema_versions';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
        DELETE FROM shared.schema_versions WHERE false;
        RAISE EXCEPTION 'migration 245: cis_app can DELETE from shared.schema_versions';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
END $$;

COMMIT;
