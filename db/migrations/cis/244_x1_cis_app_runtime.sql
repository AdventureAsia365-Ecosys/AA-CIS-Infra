-- Migration 244: AA-860 (X1 step S16) — everything the CIS runtime role cis_app needs before api + worker
-- switch to it (X1 S18): schema-wide grants and default privileges in the 11 CIS schemas, and a permissive
-- parity policy TO cis_app on every RLS table (8 ENABLE-only + 8 FORCE).
-- migrate: lock_timeout=5s
--
-- Why. Today the CIS api, worker and DB Migrate all log in as the RDS master aa_cis_admin, which owns every
-- CIS object and is a member of rds_superuser. X1 moves api + worker to cis_app (LOGIN, created by the Infra
-- role bootstrap rl-001 with no password, CONNECTION LIMIT 90): no ownership, no BYPASSRLS, not in
-- rds_superuser, no membership at all. cis_app must see and change exactly what the master sees and changes
-- today, and nothing outside CIS (P0-9: booking.* / tripplanner.* → 42501).
--
-- RLS, measured (S243 correction of x1-plan §1.4 / S16 item 3). The plan assumed FORCE RLS filters the
-- master, so a non-owner cis_app would need no policy on the FORCE tables. The live AA-817 probe says
-- otherwise (root docs/audits/2026-10-16-S239-in-progress-audit/aa817-done-evidence/probe_v2_after_239.json):
-- for aa_cis_admin, foreign-tenant GUC count == total on every FORCE table (published_tours 892/892,
-- raw_tours 987/987, generated_content 1481/1481, …), lesson S236. And most CIS code (~69 files) reads these
-- tables without setting app.tenant_id. So the master is NOT filtered on any RLS table, and cis_app needs a
-- permissive USING (true) WITH CHECK (true) policy on all 16 to keep today's behaviour:
--   * ENABLE-only (D2; the master is exempt as owner, cis_app would match no policy → 0 rows, writes
--     refused): acp_shared.acp_output_rules, angle_gate_option, angle_gate_request, content_piece, facts,
--     publish_log; gold_aa_internal.tenant_tour_versions; shared.tenant_integrations;
--   * FORCE (the master reads them through rds_superuser; cis_app would match only tenant_isolation TO
--     public → 0 rows without a GUC): gold_aa_internal.published_tours, content_exports,
--     webhook_deliveries; silver_aa_internal.raw_tours, generated_content, quality_scores, seo_context;
--     shared.pipeline_runs.
-- Tenant isolation is unchanged: it is enforced on the tenant pool (aa_app_user, its own policies). Nobody
-- is made a member of aa_app_user or catalog_owner (§1.4 warning: a policy TO r reaches r's members).
--
-- What.
--   1. For the 11 owners.yaml CIS schemas except catalog (acp_contract, acp_deliver, acp_gold_output,
--      acp_shared, acp_silver_s2, acp_silver_s3, acp_silver_s4, geo, gold_aa_internal, shared,
--      silver_aa_internal): USAGE on the schema; SELECT, INSERT, UPDATE, DELETE on all tables (views and
--      matviews included); USAGE, SELECT, UPDATE on all sequences; EXECUTE on all functions, then EXECUTE
--      revoked again on trigger functions (a firing trigger checks no EXECUTE; SEC-4, and the 243 key guard
--      must stay unexecutable by the runtime). Then REVOKE INSERT, UPDATE, DELETE ON shared.schema_versions
--      (the runtime must not edit the migration registry; 243's key guard backs this up). Nothing on
--      booking, tripplanner, catalog (CIS code reads no catalog.* view) or public.
--   2. ALTER DEFAULT PRIVILEGES FOR ROLE aa_cis_admin IN SCHEMA <the 11>: tables DML, sequences USAGE /
--      SELECT / UPDATE, functions EXECUTE → cis_app (= owners.yaml runtime_privileges.cis_app.default_acl;
--      XD3). 245 restates them FOR ROLE cis_owner. They do not touch the existing shared.schema_versions.
--   3. A policy <table>_cis_app_all AS PERMISSIVE FOR ALL TO cis_app USING (true) WITH CHECK (true) on each
--      of the 16 RLS tables above. Order: (a) DROP POLICY IF EXISTS on the 16 (re-runnable), (b) count(*)
--      of every FORCE table and tenant_tour_versions as the master, without a GUC and under a forged foreign
--      GUC, kept in transaction-local settings x1_244.*, (c) CREATE POLICY. (b) must come before (c): the
--      master is a member of cis_app (rl-001), and a policy TO cis_app applies to its members too, so after
--      (c) the master always matches it and a later measurement would prove nothing. (Harmless for the
--      master, which reads these tables unfiltered anyway; it also means db_migrator, a member of cis_app
--      from S20, matches these policies — but under DB Migrate's SET ROLE cis_owner the current user is
--      cis_owner, which is not a member: 245 must handle cis_owner on the FORCE tables, plan S21.)
--   4. Register 244.
--   5. Guards, LAST (after the registration), RAISE on failure:
--      a. the RLS tables of the 11 schemas are exactly the 8 ENABLE-only + 8 FORCE names above (a new RLS
--         table fails loudly: decide its cis_app policy in its own migration), and each has a permissive
--         FOR ALL policy TO cis_app with USING (true) WITH CHECK (true);
--      b. cis_app: LOGIN, no SUPERUSER / BYPASSRLS / CREATEROLE / CREATEDB, member of no role; USAGE on the
--         11 schemas, none on booking / tripplanner / catalog; SELECT on every relation, DML on every
--         table, USAGE on every sequence, EXECUTE on every non-trigger function and no own grant on a
--         trigger function, in the 11 schemas; SELECT but no INSERT / UPDATE / DELETE on
--         shared.schema_versions; the default ACL rows of item 2 in each schema;
--      c. behaviour (SET LOCAL ROLE cis_app, the last statement before COMMIT, so nothing else runs as
--         cis_app; DB Migrate's own reads after COMMIT run as the login role again): for every FORCE table
--         and tenant_tour_versions, cis_app's count(*) without a GUC and under the same forged foreign GUC
--         equals the master's from 3b = parity; cis_app may UPDATE shared.job; INSERT and
--         DELETE on shared.schema_versions raise insufficient_privilege; SELECT on booking.customers and
--         tripplanner.sessions raises insufficient_privilege (checked where those tables exist: on Dev
--         always; CI builds stand-ins in tests/integration/test_aa860_migration_244.py).
--
-- Dev order (S243). 244 is numbered before 247–249 but is applied on Dev AFTER 247 (identity), 248
-- (AA-884 audit chain + cost snapshot) and 249 (AA-878 viewer). That is safe by construction: the GRANT …
-- ON ALL statements cover every object that exists at apply time (incl. shared.staff_app_grant and
-- 248's objects; EXECUTE on 248's trigger functions is revoked again with the others), and the default
-- privileges cover what the master creates afterwards. The CI replay runs files in numeric order as a
-- superuser, so in CI 247/248 objects get no cis_app grant from this file (superuser-created objects are
-- outside FOR ROLE aa_cis_admin); tests/integration/test_x1_cis_app_privileges.py therefore re-applies 244
-- after the full replay, which is exactly the Dev order, and test_aa860_migration_244.py models both.
--
-- Runs as the login role (aa_cis_admin owns schema shared: no switch). The runner's reach check passes
-- because rl-001 made the master a member of cis_app (SET LOCAL ROLE checks the session user).
--
-- Locks. CREATE / DROP POLICY take ACCESS EXCLUSIVE on each of the 16 tables for milliseconds; GRANT takes
-- no table lock. Apply only with shared.job / booking.job idle (DB Migrate's idle check); lock_timeout 5s.
-- No runtime effect: CIS keeps running as the master until S18 (the policies apply to cis_app only).
--
-- After apply: regenerate docs/architecture/db-schema-reference.md (DB Schema Dump): 16 policies
-- <table>_cis_app_all TO cis_app, cis_app grants in the 11 schemas, default privileges FOR ROLE
-- aa_cis_admin → cis_app. Then the isolation probe: runtime_grants.cis / default_acl.cis pass.
--
-- Rollback (forward file, only before S18 switches the runtime; after S18 it would cut the runtime off):
--   DROP POLICY IF EXISTS <table>_cis_app_all ON <table>;   -- the 16 tables
--   ALTER DEFAULT PRIVILEGES FOR ROLE aa_cis_admin IN SCHEMA <the 11> REVOKE ALL ON TABLES / SEQUENCES /
--     FUNCTIONS FROM cis_app;
--   REVOKE ALL ON ALL TABLES / SEQUENCES / FUNCTIONS IN SCHEMA <the 11> FROM cis_app;
--   REVOKE USAGE ON SCHEMA <the 11> FROM cis_app;

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '15min';

-- ── Guard 0: cis_app exists (rl-001) ────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'cis_app') THEN
        RAISE EXCEPTION 'migration 244: role cis_app does not exist — apply the Infra role bootstrap roles/001_x1_owner_roles.sql (rl-001) first';
    END IF;
END $$;

-- ── 1. Grants on what exists now ───────────────────────────────────────────────────────────────────
GRANT USAGE ON SCHEMA acp_contract, acp_deliver, acp_gold_output, acp_shared, acp_silver_s2, acp_silver_s3,
    acp_silver_s4, geo, gold_aa_internal, shared, silver_aa_internal TO cis_app;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA acp_contract, acp_deliver, acp_gold_output,
    acp_shared, acp_silver_s2, acp_silver_s3, acp_silver_s4, geo, gold_aa_internal, shared,
    silver_aa_internal TO cis_app;

GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA acp_contract, acp_deliver, acp_gold_output,
    acp_shared, acp_silver_s2, acp_silver_s3, acp_silver_s4, geo, gold_aa_internal, shared,
    silver_aa_internal TO cis_app;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA acp_contract, acp_deliver, acp_gold_output, acp_shared,
    acp_silver_s2, acp_silver_s3, acp_silver_s4, geo, gold_aa_internal, shared, silver_aa_internal TO cis_app;

-- Trigger functions: no EXECUTE for the runtime (a firing trigger does not check it; SEC-4).
DO $$
DECLARE
    fn regprocedure;
BEGIN
    FOR fn IN
        SELECT p.oid::regprocedure
          FROM pg_catalog.pg_proc p
          JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = ANY (ARRAY['acp_contract', 'acp_deliver', 'acp_gold_output', 'acp_shared',
                                      'acp_silver_s2', 'acp_silver_s3', 'acp_silver_s4', 'geo',
                                      'gold_aa_internal', 'shared', 'silver_aa_internal'])
           AND p.prorettype = 'pg_catalog.trigger'::pg_catalog.regtype
    LOOP
        EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM cis_app', fn);
    END LOOP;
END $$;

-- The runtime reads the migration registry but never writes it.
REVOKE INSERT, UPDATE, DELETE ON shared.schema_versions FROM cis_app;

-- ── 2. Default privileges for what the master creates later (XD3) ───────────────────────────────────
ALTER DEFAULT PRIVILEGES FOR ROLE aa_cis_admin IN SCHEMA acp_contract, acp_deliver, acp_gold_output,
    acp_shared, acp_silver_s2, acp_silver_s3, acp_silver_s4, geo, gold_aa_internal, shared, silver_aa_internal
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO cis_app;
ALTER DEFAULT PRIVILEGES FOR ROLE aa_cis_admin IN SCHEMA acp_contract, acp_deliver, acp_gold_output,
    acp_shared, acp_silver_s2, acp_silver_s3, acp_silver_s4, geo, gold_aa_internal, shared, silver_aa_internal
    GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO cis_app;
ALTER DEFAULT PRIVILEGES FOR ROLE aa_cis_admin IN SCHEMA acp_contract, acp_deliver, acp_gold_output,
    acp_shared, acp_silver_s2, acp_silver_s3, acp_silver_s4, geo, gold_aa_internal, shared, silver_aa_internal
    GRANT EXECUTE ON FUNCTIONS TO cis_app;

-- ── 3a. Re-runnable: drop the parity policies first ────────────────────────────────────────────────
DROP POLICY IF EXISTS acp_output_rules_cis_app_all ON acp_shared.acp_output_rules;
DROP POLICY IF EXISTS angle_gate_option_cis_app_all ON acp_shared.angle_gate_option;
DROP POLICY IF EXISTS angle_gate_request_cis_app_all ON acp_shared.angle_gate_request;
DROP POLICY IF EXISTS content_piece_cis_app_all ON acp_shared.content_piece;
DROP POLICY IF EXISTS facts_cis_app_all ON acp_shared.facts;
DROP POLICY IF EXISTS publish_log_cis_app_all ON acp_shared.publish_log;
DROP POLICY IF EXISTS tenant_tour_versions_cis_app_all ON gold_aa_internal.tenant_tour_versions;
DROP POLICY IF EXISTS tenant_integrations_cis_app_all ON shared.tenant_integrations;
DROP POLICY IF EXISTS content_exports_cis_app_all ON gold_aa_internal.content_exports;
DROP POLICY IF EXISTS published_tours_cis_app_all ON gold_aa_internal.published_tours;
DROP POLICY IF EXISTS webhook_deliveries_cis_app_all ON gold_aa_internal.webhook_deliveries;
DROP POLICY IF EXISTS pipeline_runs_cis_app_all ON shared.pipeline_runs;
DROP POLICY IF EXISTS generated_content_cis_app_all ON silver_aa_internal.generated_content;
DROP POLICY IF EXISTS quality_scores_cis_app_all ON silver_aa_internal.quality_scores;
DROP POLICY IF EXISTS raw_tours_cis_app_all ON silver_aa_internal.raw_tours;
DROP POLICY IF EXISTS seo_context_cis_app_all ON silver_aa_internal.seo_context;

-- ── 3b. What the master reads today, measured BEFORE the policies exist ────────────────────────────
-- The master is a member of cis_app (rl-001), so a policy TO cis_app also applies to it: measured after 3c,
-- the master would always match cis_app and the parity guard (5c) would prove nothing. The counts travel to
-- 5c in transaction-local custom settings.
DO $$
DECLARE
    parity_tables  text[] := ARRAY['gold_aa_internal.content_exports', 'gold_aa_internal.published_tours',
                                   'gold_aa_internal.webhook_deliveries', 'shared.pipeline_runs',
                                   'silver_aa_internal.generated_content', 'silver_aa_internal.quality_scores',
                                   'silver_aa_internal.raw_tours', 'silver_aa_internal.seo_context',
                                   'gold_aa_internal.tenant_tour_versions'];
    forged         text := gen_random_uuid()::text;
    plain_counts   bigint[] := '{}';
    forged_counts  bigint[] := '{}';
    n              bigint;
    i              int;
BEGIN
    PERFORM set_config('app.tenant_id', '', true);
    FOR i IN 1 .. array_length(parity_tables, 1) LOOP
        EXECUTE format('SELECT count(*) FROM %s', parity_tables[i]) INTO n;
        plain_counts := plain_counts || n;
    END LOOP;
    PERFORM set_config('app.tenant_id', forged, true);
    FOR i IN 1 .. array_length(parity_tables, 1) LOOP
        EXECUTE format('SELECT count(*) FROM %s', parity_tables[i]) INTO n;
        forged_counts := forged_counts || n;
    END LOOP;
    PERFORM set_config('app.tenant_id', '', true);
    PERFORM set_config('x1_244.tables', array_to_string(parity_tables, ','), true);
    PERFORM set_config('x1_244.forged', forged, true);
    PERFORM set_config('x1_244.master_plain', array_to_string(plain_counts, ','), true);
    PERFORM set_config('x1_244.master_forged', array_to_string(forged_counts, ','), true);
END $$;

-- ── 3c. The parity policies ────────────────────────────────────────────────────────────────────────
-- ENABLE-only (D2): the master is exempt as owner.
CREATE POLICY acp_output_rules_cis_app_all ON acp_shared.acp_output_rules
    AS PERMISSIVE FOR ALL TO cis_app USING (true) WITH CHECK (true);
CREATE POLICY angle_gate_option_cis_app_all ON acp_shared.angle_gate_option
    AS PERMISSIVE FOR ALL TO cis_app USING (true) WITH CHECK (true);
CREATE POLICY angle_gate_request_cis_app_all ON acp_shared.angle_gate_request
    AS PERMISSIVE FOR ALL TO cis_app USING (true) WITH CHECK (true);
CREATE POLICY content_piece_cis_app_all ON acp_shared.content_piece
    AS PERMISSIVE FOR ALL TO cis_app USING (true) WITH CHECK (true);
CREATE POLICY facts_cis_app_all ON acp_shared.facts
    AS PERMISSIVE FOR ALL TO cis_app USING (true) WITH CHECK (true);
CREATE POLICY publish_log_cis_app_all ON acp_shared.publish_log
    AS PERMISSIVE FOR ALL TO cis_app USING (true) WITH CHECK (true);
CREATE POLICY tenant_tour_versions_cis_app_all ON gold_aa_internal.tenant_tour_versions
    AS PERMISSIVE FOR ALL TO cis_app USING (true) WITH CHECK (true);
CREATE POLICY tenant_integrations_cis_app_all ON shared.tenant_integrations
    AS PERMISSIVE FOR ALL TO cis_app USING (true) WITH CHECK (true);

-- FORCE (S243 correction): the master reads them unfiltered through rds_superuser (AA-817 probe v2).
CREATE POLICY content_exports_cis_app_all ON gold_aa_internal.content_exports
    AS PERMISSIVE FOR ALL TO cis_app USING (true) WITH CHECK (true);
CREATE POLICY published_tours_cis_app_all ON gold_aa_internal.published_tours
    AS PERMISSIVE FOR ALL TO cis_app USING (true) WITH CHECK (true);
CREATE POLICY webhook_deliveries_cis_app_all ON gold_aa_internal.webhook_deliveries
    AS PERMISSIVE FOR ALL TO cis_app USING (true) WITH CHECK (true);
CREATE POLICY pipeline_runs_cis_app_all ON shared.pipeline_runs
    AS PERMISSIVE FOR ALL TO cis_app USING (true) WITH CHECK (true);
CREATE POLICY generated_content_cis_app_all ON silver_aa_internal.generated_content
    AS PERMISSIVE FOR ALL TO cis_app USING (true) WITH CHECK (true);
CREATE POLICY quality_scores_cis_app_all ON silver_aa_internal.quality_scores
    AS PERMISSIVE FOR ALL TO cis_app USING (true) WITH CHECK (true);
CREATE POLICY raw_tours_cis_app_all ON silver_aa_internal.raw_tours
    AS PERMISSIVE FOR ALL TO cis_app USING (true) WITH CHECK (true);
CREATE POLICY seo_context_cis_app_all ON silver_aa_internal.seo_context
    AS PERMISSIVE FOR ALL TO cis_app USING (true) WITH CHECK (true);

-- ── 4. Register ────────────────────────────────────────────────────────────────────────────────────
INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('244', now(), 'AA-860 (X1 S16): cis_app USAGE/DML/sequences/EXECUTE (no trigger fns) in the 11 CIS schemas + default privileges FOR ROLE aa_cis_admin; registry read-only; permissive parity policy TO cis_app on the 8 ENABLE-only + 8 FORCE RLS tables')
ON CONFLICT (version) DO NOTHING;

-- ── 5a–b. Guards by shape ──────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    cis_schemas   text[] := ARRAY['acp_contract', 'acp_deliver', 'acp_gold_output', 'acp_shared', 'acp_silver_s2',
                                  'acp_silver_s3', 'acp_silver_s4', 'geo', 'gold_aa_internal', 'shared',
                                  'silver_aa_internal'];
    enable_only   text[] := ARRAY['acp_shared.acp_output_rules', 'acp_shared.angle_gate_option',
                                  'acp_shared.angle_gate_request', 'acp_shared.content_piece', 'acp_shared.facts',
                                  'acp_shared.publish_log', 'gold_aa_internal.tenant_tour_versions',
                                  'shared.tenant_integrations'];
    forced        text[] := ARRAY['gold_aa_internal.content_exports', 'gold_aa_internal.published_tours',
                                  'gold_aa_internal.webhook_deliveries', 'shared.pipeline_runs',
                                  'silver_aa_internal.generated_content', 'silver_aa_internal.quality_scores',
                                  'silver_aa_internal.raw_tours', 'silver_aa_internal.seo_context'];
    found_enable  text[];
    found_force   text[];
    bad           text;
    s             text;
    r             record;
BEGIN
    -- a. the RLS table set, and a parity policy on each
    SELECT coalesce(array_agg(t ORDER BY t) FILTER (WHERE NOT force), '{}'),
           coalesce(array_agg(t ORDER BY t) FILTER (WHERE force), '{}')
      INTO found_enable, found_force
      FROM (SELECT n.nspname || '.' || c.relname AS t, c.relforcerowsecurity AS force
              FROM pg_catalog.pg_class c
              JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
             WHERE c.relrowsecurity AND n.nspname = ANY (cis_schemas)) x;
    IF found_enable IS DISTINCT FROM (SELECT array_agg(t ORDER BY t) FROM unnest(enable_only) t) THEN
        RAISE EXCEPTION 'migration 244: ENABLE-only RLS tables are % (expected %); a new RLS table needs its cis_app policy decided in its own migration',
            found_enable, enable_only;
    END IF;
    IF found_force IS DISTINCT FROM (SELECT array_agg(t ORDER BY t) FROM unnest(forced) t) THEN
        RAISE EXCEPTION 'migration 244: FORCE RLS tables are % (expected %)', found_force, forced;
    END IF;
    SELECT string_agg(n.nspname || '.' || c.relname, ', ' ORDER BY n.nspname, c.relname)
      INTO bad
      FROM pg_catalog.pg_class c
      JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
     WHERE c.relrowsecurity AND n.nspname = ANY (cis_schemas)
       AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_policy p
                        WHERE p.polrelid = c.oid AND p.polpermissive AND p.polcmd = '*'
                          AND 'cis_app'::regrole::oid = ANY (p.polroles)
                          AND pg_catalog.pg_get_expr(p.polqual, p.polrelid) = 'true'
                          AND pg_catalog.pg_get_expr(p.polwithcheck, p.polrelid) = 'true');
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 244: RLS table(s) without a permissive FOR ALL USING (true) WITH CHECK (true) policy TO cis_app: %', bad;
    END IF;

    -- b. the role itself
    SELECT * INTO r FROM pg_catalog.pg_roles WHERE rolname = 'cis_app';
    IF NOT r.rolcanlogin OR r.rolsuper OR r.rolbypassrls OR r.rolcreaterole OR r.rolcreatedb THEN
        RAISE EXCEPTION 'migration 244: cis_app must be LOGIN, NOSUPERUSER, NOBYPASSRLS, NOCREATEROLE, NOCREATEDB';
    END IF;
    SELECT string_agg(pg_catalog.pg_get_userbyid(m.roleid), ', ') INTO bad
      FROM pg_catalog.pg_auth_members m WHERE m.member = 'cis_app'::regrole::oid;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 244: cis_app is a member of % (it must be a member of no role; a policy TO r reaches r''s members)', bad;
    END IF;

    -- b. schemas
    FOREACH s IN ARRAY cis_schemas LOOP
        IF NOT pg_catalog.has_schema_privilege('cis_app', s, 'USAGE') THEN
            RAISE EXCEPTION 'migration 244: cis_app has no USAGE on schema %', s;
        END IF;
    END LOOP;
    FOREACH s IN ARRAY ARRAY['booking', 'tripplanner', 'catalog'] LOOP
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_namespace WHERE nspname = s)
           AND pg_catalog.has_schema_privilege('cis_app', s, 'USAGE') THEN
            RAISE EXCEPTION 'migration 244: cis_app has USAGE on schema % (outside the CIS runtime scope)', s;
        END IF;
    END LOOP;

    -- b. existing objects
    SELECT string_agg(c.oid::regclass::text, ', ' ORDER BY c.oid::regclass::text) INTO bad
      FROM pg_catalog.pg_class c
      JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = ANY (cis_schemas)
       AND ((c.relkind IN ('r', 'p', 'v', 'm', 'f')
             AND NOT pg_catalog.has_table_privilege('cis_app', c.oid, 'SELECT'))
            OR (c.relkind IN ('r', 'p') AND c.oid <> 'shared.schema_versions'::regclass
                AND NOT (pg_catalog.has_table_privilege('cis_app', c.oid, 'INSERT')
                         AND pg_catalog.has_table_privilege('cis_app', c.oid, 'UPDATE')
                         AND pg_catalog.has_table_privilege('cis_app', c.oid, 'DELETE')))
            OR (c.relkind = 'S' AND NOT pg_catalog.has_sequence_privilege('cis_app', c.oid, 'USAGE')));
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 244: cis_app lacks SELECT / DML / sequence USAGE on: %', bad;
    END IF;
    SELECT string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text) INTO bad
      FROM pg_catalog.pg_proc p
      JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = ANY (cis_schemas)
       AND ((p.prorettype <> 'pg_catalog.trigger'::pg_catalog.regtype
             AND NOT pg_catalog.has_function_privilege('cis_app', p.oid, 'EXECUTE'))
            OR (p.prorettype = 'pg_catalog.trigger'::pg_catalog.regtype
                AND EXISTS (SELECT 1 FROM aclexplode(p.proacl) x WHERE x.grantee = 'cis_app'::regrole::oid)));
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 244: function grants to cis_app wrong (EXECUTE missing on a function, or granted on a trigger function): %', bad;
    END IF;
    IF NOT pg_catalog.has_table_privilege('cis_app', 'shared.schema_versions', 'SELECT')
       OR pg_catalog.has_table_privilege('cis_app', 'shared.schema_versions', 'INSERT')
       OR pg_catalog.has_table_privilege('cis_app', 'shared.schema_versions', 'UPDATE')
       OR pg_catalog.has_table_privilege('cis_app', 'shared.schema_versions', 'DELETE') THEN
        RAISE EXCEPTION 'migration 244: cis_app must read shared.schema_versions and never write it';
    END IF;

    -- b. default privileges FOR ROLE aa_cis_admin (owners.yaml runtime_privileges.cis_app.default_acl)
    FOR r IN
        SELECT s2 AS schema_name, o.objtype, o.privs
          FROM unnest(cis_schemas) s2,
               (VALUES ('r'::"char", ARRAY['DELETE', 'INSERT', 'SELECT', 'UPDATE']),
                       ('S'::"char", ARRAY['SELECT', 'UPDATE', 'USAGE']),
                       ('f'::"char", ARRAY['EXECUTE'])) AS o(objtype, privs)
    LOOP
        IF (SELECT array_agg(x.privilege_type::text ORDER BY x.privilege_type::text)
              FROM pg_catalog.pg_default_acl d, aclexplode(d.defaclacl) x
             WHERE d.defaclrole = 'aa_cis_admin'::regrole::oid
               AND d.defaclnamespace = r.schema_name::regnamespace::oid
               AND d.defaclobjtype = r.objtype
               AND x.grantee = 'cis_app'::regrole::oid) IS DISTINCT FROM r.privs THEN
            RAISE EXCEPTION 'migration 244: default privileges FOR ROLE aa_cis_admin IN SCHEMA % (type %) to cis_app are not %',
                r.schema_name, r.objtype, r.privs;
        END IF;
    END LOOP;
END $$;

-- ── 5c. Behaviour as cis_app (last: SET LOCAL ROLE lasts until COMMIT) ──────────────────────────────
DO $$
DECLARE
    parity_tables  text[] := string_to_array(current_setting('x1_244.tables'), ',');
    forged         text := current_setting('x1_244.forged');
    master_plain   bigint[] := string_to_array(current_setting('x1_244.master_plain'), ',')::bigint[];
    master_forged  bigint[] := string_to_array(current_setting('x1_244.master_forged'), ',')::bigint[];
    n              bigint;
    i              int;
    -- catalog lookups, not to_regclass(): name resolution would need USAGE on the other app's schema
    has_customers  boolean := EXISTS (SELECT 1 FROM pg_catalog.pg_class c
                                        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
                                       WHERE n.nspname = 'booking' AND c.relname = 'customers');
    has_sessions   boolean := EXISTS (SELECT 1 FROM pg_catalog.pg_class c
                                        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
                                       WHERE n.nspname = 'tripplanner' AND c.relname = 'sessions');
BEGIN
    SET LOCAL ROLE cis_app;

    PERFORM set_config('app.tenant_id', forged, true);
    FOR i IN 1 .. array_length(parity_tables, 1) LOOP
        EXECUTE format('SELECT count(*) FROM %s', parity_tables[i]) INTO n;
        IF n <> master_forged[i] THEN
            RAISE EXCEPTION 'migration 244: parity: cis_app reads % row(s) of % under a foreign app.tenant_id, the master % before 244',
                n, parity_tables[i], master_forged[i];
        END IF;
    END LOOP;
    PERFORM set_config('app.tenant_id', '', true);
    FOR i IN 1 .. array_length(parity_tables, 1) LOOP
        EXECUTE format('SELECT count(*) FROM %s', parity_tables[i]) INTO n;
        IF n <> master_plain[i] THEN
            RAISE EXCEPTION 'migration 244: parity: cis_app reads % row(s) of % without app.tenant_id, the master % before 244',
                n, parity_tables[i], master_plain[i];
        END IF;
    END LOOP;

    UPDATE shared.job SET status = status WHERE false;      -- the runtime writes the job table

    BEGIN
        INSERT INTO shared.schema_versions (version, applied_at, description)
        VALUES ('zz-244-guard', now(), 'must be refused');
        RAISE EXCEPTION 'migration 244: cis_app can INSERT into shared.schema_versions';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
        DELETE FROM shared.schema_versions WHERE false;
        RAISE EXCEPTION 'migration 244: cis_app can DELETE from shared.schema_versions';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;

    IF has_customers THEN
        BEGIN
            EXECUTE 'SELECT 1 FROM booking.customers LIMIT 1';
            RAISE EXCEPTION 'migration 244: cis_app reads booking.customers';
        EXCEPTION WHEN insufficient_privilege THEN NULL;
        END;
    ELSE
        RAISE NOTICE 'migration 244: booking.customers absent, cross-app read check skipped (Dev has it)';
    END IF;
    IF has_sessions THEN
        BEGIN
            EXECUTE 'SELECT 1 FROM tripplanner.sessions LIMIT 1';
            RAISE EXCEPTION 'migration 244: cis_app reads tripplanner.sessions';
        EXCEPTION WHEN insufficient_privilege THEN NULL;
        END;
    ELSE
        RAISE NOTICE 'migration 244: tripplanner.sessions absent, cross-app read check skipped (Dev has it)';
    END IF;
END $$;

COMMIT;
