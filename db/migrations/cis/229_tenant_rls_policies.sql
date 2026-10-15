-- Migration 229: AA-817 — one RLS policy template for the tenant-pool tables, RLS on
-- gold_aa_internal.tenant_tour_versions for the tenant role, no platform-fact writes by tenants, and no
-- more automatic grants to aa_app_user.
--
-- Why. The tenant pool (api/core/aa544_tenant_pool.py) connects as aa_app_user and sets
-- app.tenant_id LOCAL to the request's transaction; RLS is what keeps one tenant out of another's rows
-- when a query forgets its WHERE tenant_id. The S237 probe of Dev
-- (AA-Ecosys/docs/audits/2026-10-14-S237-lane-backlog/aa817/probe.json) found:
--   * the runner aa_cis_admin (API main pool, worker, DB Migrate) owns every table here and is exempt
--     (RLS ENABLE without FORCE); aa_app_user is filtered correctly where it has grants;
--   * policies drift between the live DB and the repo: gold_aa_internal.tenant_tour_versions already
--     has RLS ENABLED with a live-only policy tenant_tour_versions_isolation (TO public, text compare),
--     and acp_shared.acp_output_rules has a live-only output_rules_rls on the other GUC name
--     app.current_tenant. Neither exists in any migration;
--   * the 113/115/116/145 policies compare tenant_id::text to the GUC, are TO public and FOR ALL with
--     no WITH CHECK;
--   * acp_shared.facts (145) admits `scope = 'platform' OR own tenant` for every command, and 147
--     grants INSERT/UPDATE to aa_app_user: a tenant session could rewrite or add platform facts that
--     every tenant's T9 cites;
--   * aa_app_user has no privilege on tenant_tour_versions (stage-2 routes need SELECT/INSERT/UPDATE);
--   * 007b's ALTER DEFAULT PRIVILEGES gives aa_app_user SELECT on every NEW table in shared,
--     silver_aa_internal and gold_aa_internal, RLS or not (data-architecture review N7).
--
-- What. For the five tenant-pool tables (scope below) every existing policy is dropped by name and
-- one policy is created per table, all on the template of the data standards (review 4.4):
--     TO aa_app_user  FOR ALL
--     USING      (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
--     WITH CHECK (same)
-- '' must mean "no tenant" (0 rows, no error): a pooled connection holds '' after any
-- set_config(..., true) transaction (lesson of 225). app.tenant_id is the only GUC name.
-- facts gets the template restricted to scope = 'tenant' plus a second, SELECT-only policy for
-- platform rows: tenants still read platform facts, but can neither write one nor turn one into
-- theirs (an UPDATE needs the FOR ALL policy's USING, which platform rows fail).
--
-- Decision D2 (S237): ENABLE ROW LEVEL SECURITY without FORCE. The owner stays exempt, so the main
-- pool (worker T2/T9 writes, admin lists, every /v1 route not yet on the tenant pool) is unchanged.
-- With FORCE the owner would match no policy here (they are TO aa_app_user) and read 0 rows; guard 1
-- refuses to run if any table in scope is FORCEd.
--
-- Out of scope (unchanged): published_tours / raw_tours / generated_content / quality_scores /
-- seo_context / content_exports / webhook_deliveries / pipeline_runs keep their 004/008/225 policies
-- (FORCE, TO public; tripplanner and catalog_owner read published_tours/raw_tours through them, and
-- the CI RDS-like owner test relies on them). acp_output_rules keeps RLS ENABLED with no policy: only
-- its owner reads it (v1_rules.py, rule_adapter.py on the main pool), so non-owners are denied.
--
-- Not a behaviour change for existing tables' grants: REVOKE on default privileges only affects
-- tables created afterwards. A new table the tenant pool needs gets an explicit GRANT in its own
-- migration (data standards: "grants are per object").
--
-- Guards (lesson S236: check RLS by behaviour, not by role attributes):
--   1. before: every table in scope exists, the runner owns it (or is superuser/BYPASSRLS), none is
--      FORCEd; row counts are recorded;
--   2. after, as the runner: RLS is not active for it and it still counts every row under a foreign
--      app.tenant_id;
--   3. after, as aa_app_user (the runner is made a member for this transaction only when it is not
--      one already, then the membership is revoked, like catalog_owner in 225): a foreign or empty
--      GUC returns 0 rows (facts: only platform rows), the busiest tenant gets exactly its own rows,
--      and a platform fact can be neither updated nor inserted;
--   4. the policy set of each table is exactly the one created here, all TO aa_app_user;
--   5. no default privilege of the runner grants aa_app_user anything.
--
-- Cross-owner grants are not guarded by IF EXISTS(role) (schema-ownership rule 5): aa_app_user must
-- exist (007b on Dev, conftest in CI). Idempotent: every policy is dropped by name and recreated.
--
-- Apply in a window with no t2_rewrite / t9_write job queued or running. Afterwards smoke one admin
-- tour-versions list and rerun the AA-817 probe (expected: aa_app_user tenant_tour_versions
-- foreign 0/0, empty 0/0, own n/1).
--
-- Rollback (restores the pre-229 policy behaviour; the code works either way):
--   DROP POLICY IF EXISTS tenant_isolation ON <each table>;
--   DROP POLICY IF EXISTS facts_platform_read ON acp_shared.facts;
--   CREATE POLICY tenant_isolation ON acp_shared.{angle_gate_request,content_piece,publish_log}
--       USING (tenant_id::text = current_setting('app.tenant_id', true));
--   CREATE POLICY tenant_isolation ON acp_shared.facts
--       USING (scope = 'platform' OR tenant_id::text = current_setting('app.tenant_id', true));
--   REVOKE SELECT, INSERT, UPDATE ON gold_aa_internal.tenant_tour_versions FROM aa_app_user;
--   DELETE FROM shared.schema_versions WHERE version = '229';
--   (tenant_tour_versions_isolation / output_rules_rls are not restored: drift, never in git.)

BEGIN;

-- ALTER TABLE ... ENABLE ROW LEVEL SECURITY and DROP/CREATE POLICY take ACCESS EXCLUSIVE locks on
-- tables the API reads all the time: give up instead of queueing every request behind a long query.
-- Guard 1 takes those locks up front (one table at a time, in the order below) and they are held
-- to COMMIT, so the counts it records cannot drift before guard 2 compares against them.
SET LOCAL lock_timeout = '10s';

-- ── Guard 1: the runner owns every table in scope, none is FORCEd; counts before ───────────────────
DO $$
DECLARE
    t      text;
    owner_ok boolean;
    forced boolean;
    privileged boolean;
BEGIN
    SELECT rolsuper OR rolbypassrls INTO privileged FROM pg_roles WHERE rolname = current_user;
    FOREACH t IN ARRAY ARRAY['acp_shared.angle_gate_request', 'acp_shared.content_piece',
                             'acp_shared.publish_log', 'acp_shared.facts',
                             'gold_aa_internal.tenant_tour_versions'] LOOP
        IF to_regclass(t) IS NULL THEN
            RAISE EXCEPTION 'migration 229: % does not exist', t;
        END IF;
        SELECT pg_has_role(current_user, c.relowner, 'USAGE'), c.relforcerowsecurity
          INTO owner_ok, forced
          FROM pg_class c WHERE c.oid = t::regclass;
        IF NOT owner_ok AND NOT privileged THEN
            RAISE EXCEPTION 'migration 229: % neither owns % nor bypasses RLS: ENABLE ROW LEVEL SECURITY '
                            'would hide its rows from the main pool', current_user, t;
        END IF;
        IF forced THEN
            RAISE EXCEPTION 'migration 229: % has FORCE ROW LEVEL SECURITY: with policies TO aa_app_user '
                            'only, the owner (main pool) would read 0 rows (decision D2: no FORCE)', t;
        END IF;
        -- Take the lock ENABLE / CREATE POLICY need anyway before counting: no row can be added
        -- between this count and guard 2, which compares against it (a concurrent write would
        -- otherwise abort the apply on a false "runner is filtered").
        EXECUTE format('LOCK TABLE %s IN ACCESS EXCLUSIVE MODE', t);
        EXECUTE format('SELECT set_config(%L, (SELECT count(*) FROM %s)::text, true)',
                       'aa229.n_' || replace(t, '.', '__'), t);
    END LOOP;
END $$;

-- ── Drift policies (live only, never in git) ────────────────────────────────────────────────────
DROP POLICY IF EXISTS tenant_tour_versions_isolation ON gold_aa_internal.tenant_tour_versions;
DO $$
BEGIN
    IF to_regclass('acp_shared.acp_output_rules') IS NOT NULL THEN
        DROP POLICY IF EXISTS output_rules_rls ON acp_shared.acp_output_rules;
    END IF;
END $$;

-- ── One policy per table, TO aa_app_user, NULLIF GUC, explicit WITH CHECK ───────────────────────
ALTER TABLE gold_aa_internal.tenant_tour_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE acp_shared.angle_gate_request ENABLE ROW LEVEL SECURITY;
ALTER TABLE acp_shared.content_piece ENABLE ROW LEVEL SECURITY;
ALTER TABLE acp_shared.publish_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE acp_shared.facts ENABLE ROW LEVEL SECURITY;
-- deliberately NO "FORCE ROW LEVEL SECURITY" (D2)

DO $$
DECLARE
    t    text;
    expr constant text := 'tenant_id = NULLIF(current_setting(''app.tenant_id'', true), '''')::uuid';
BEGIN
    FOREACH t IN ARRAY ARRAY['gold_aa_internal.tenant_tour_versions', 'acp_shared.angle_gate_request',
                             'acp_shared.content_piece', 'acp_shared.publish_log'] LOOP
        EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON %s', t);
        EXECUTE format('CREATE POLICY tenant_isolation ON %s AS PERMISSIVE FOR ALL TO aa_app_user '
                       'USING (%s) WITH CHECK (%s)', t, expr, expr);
        EXECUTE format('COMMENT ON POLICY tenant_isolation ON %s IS %L', t,
                       'AA-817 (229): the tenant pool (aa_app_user) reads and writes only rows of '
                       'app.tenant_id; '''' or unset = no rows. Owner exempt (no FORCE).');
    END LOOP;
END $$;

DROP POLICY IF EXISTS tenant_isolation ON acp_shared.facts;
CREATE POLICY tenant_isolation ON acp_shared.facts AS PERMISSIVE FOR ALL TO aa_app_user
    USING      (scope = 'tenant' AND tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (scope = 'tenant' AND tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
COMMENT ON POLICY tenant_isolation ON acp_shared.facts IS
    'AA-817 (229): the tenant pool (aa_app_user) reads, writes and updates only its own scope=tenant '
    'facts. Platform facts are readable through facts_platform_read, never writable. Owner exempt.';
DROP POLICY IF EXISTS facts_platform_read ON acp_shared.facts;
CREATE POLICY facts_platform_read ON acp_shared.facts AS PERMISSIVE FOR SELECT TO aa_app_user
    USING (scope = 'platform');
COMMENT ON POLICY facts_platform_read ON acp_shared.facts IS
    'AA-817 (229): every tenant reads the shared platform facts (AA-529); SELECT only.';

-- ── Grants the stage-2 tenant routes need (v1_tours: read, rewrite INSERT, PATCH edit, retry) ───
GRANT USAGE ON SCHEMA gold_aa_internal TO aa_app_user;
GRANT SELECT, INSERT, UPDATE ON gold_aa_internal.tenant_tour_versions TO aa_app_user;

-- ── N7: no automatic SELECT to aa_app_user on new tables (007b) ────────────────────────────────
-- Same form as 007b (no FOR ROLE): the default ACL belongs to the role that ran 007b, the runner.
ALTER DEFAULT PRIVILEGES IN SCHEMA shared REVOKE SELECT ON TABLES FROM aa_app_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA silver_aa_internal REVOKE SELECT ON TABLES FROM aa_app_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA gold_aa_internal REVOKE SELECT ON TABLES FROM aa_app_user;

-- ── Guards 2-5 ──────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    t           text;
    n_before    bigint;
    n           bigint;
    n_platform  bigint;
    n_own       bigint;
    n_expected  bigint;
    own         uuid;
    guc         text;
    granted     boolean := false;
    pols        text[];
    expected    text[];
    bad_roles   bigint;
    foreign_guc constant text := '00000000-0000-0000-0000-00000000dead';
    tables      constant text[] := ARRAY['acp_shared.angle_gate_request', 'acp_shared.content_piece',
                                         'acp_shared.publish_log', 'acp_shared.facts',
                                         'gold_aa_internal.tenant_tour_versions'];
BEGIN
    -- 2. the runner is still exempt: RLS inactive, every row under a foreign tenant
    PERFORM set_config('app.tenant_id', foreign_guc, true);
    FOREACH t IN ARRAY tables LOOP
        IF row_security_active(t::regclass) THEN
            RAISE EXCEPTION 'migration 229: RLS is active for the runner % on %', current_user, t;
        END IF;
        n_before := current_setting('aa229.n_' || replace(t, '.', '__'))::bigint;
        EXECUTE format('SELECT count(*) FROM %s', t) INTO n;
        IF n <> n_before THEN
            RAISE EXCEPTION 'migration 229: the runner sees % of % rows of % under a foreign tenant',
                            n, n_before, t;
        END IF;

        -- 4. exactly the policies created above, all TO aa_app_user
        expected := CASE WHEN t = 'acp_shared.facts' THEN ARRAY['facts_platform_read', 'tenant_isolation']
                         ELSE ARRAY['tenant_isolation'] END;
        SELECT array_agg(policyname::text ORDER BY policyname),
               count(*) FILTER (WHERE roles <> ARRAY['aa_app_user']::name[])
          INTO pols, bad_roles
          FROM pg_policies WHERE schemaname || '.' || tablename = t;
        IF pols IS DISTINCT FROM expected OR bad_roles <> 0 THEN
            RAISE EXCEPTION 'migration 229: % has policies % with % not TO aa_app_user only '
                            '(expected %, all TO aa_app_user)', t, pols, bad_roles, expected;
        END IF;
    END LOOP;

    -- 3. aa_app_user is isolated. The runner becomes a member for this transaction only when it may
    --    not SET ROLE aa_app_user already (RDS: aa_cis_admin has CREATEROLE), and that membership is
    --    revoked below.
    BEGIN
        SET LOCAL ROLE aa_app_user;                         -- already allowed (CI superuser)?
        RESET ROLE;
    EXCEPTION WHEN insufficient_privilege THEN
        EXECUTE format('GRANT aa_app_user TO %I', current_user);
        granted := true;
    END;
    SELECT count(*) INTO n_platform FROM acp_shared.facts WHERE scope = 'platform';
    FOREACH t IN ARRAY tables LOOP
        -- the busiest tenant of the table and its row count, counted as the (exempt) runner
        EXECUTE format('SELECT tenant_id, count(*) FROM %s WHERE tenant_id IS NOT NULL '
                       'GROUP BY tenant_id ORDER BY count(*) DESC, tenant_id LIMIT 1', t) INTO own, n_own;
        FOREACH guc IN ARRAY ARRAY[foreign_guc, '', own::text] LOOP
            CONTINUE WHEN guc IS NULL;                      -- empty table: no own tenant to check
            n_expected := CASE WHEN guc = own::text THEN n_own ELSE 0 END
                        + CASE WHEN t = 'acp_shared.facts' THEN n_platform ELSE 0 END;
            PERFORM set_config('app.tenant_id', guc, true);
            SET LOCAL ROLE aa_app_user;
            EXECUTE format('SELECT count(*) FROM %s', t) INTO n;
            RESET ROLE;
            IF n <> n_expected THEN
                RAISE EXCEPTION 'migration 229: aa_app_user reads % rows of % with app.tenant_id=''%'' '
                                '(expected %)', n, t, guc, n_expected;
            END IF;
        END LOOP;
    END LOOP;

    -- facts: a tenant session can neither update nor insert a platform fact
    PERFORM set_config('app.tenant_id', foreign_guc, true);
    SET LOCAL ROLE aa_app_user;
    UPDATE acp_shared.facts SET body = body WHERE scope = 'platform';
    GET DIAGNOSTICS n = ROW_COUNT;
    IF n <> 0 THEN
        RAISE EXCEPTION 'migration 229: aa_app_user updated % platform facts', n;
    END IF;
    BEGIN
        INSERT INTO acp_shared.facts (fact_id, scope, tenant_id, title, body, provenance)
        VALUES ('fact_aa229guard', 'platform', NULL, 'guard', 'guard', 'AA-817 migration 229 guard');
        RAISE EXCEPTION 'migration 229: aa_app_user inserted a platform fact';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;                                               -- refused by WITH CHECK, as intended
    END;
    RESET ROLE;
    PERFORM set_config('app.tenant_id', '', true);

    IF granted THEN
        EXECUTE format('REVOKE aa_app_user FROM %I', current_user);
    END IF;

    -- 5. no default privilege of the runner hands aa_app_user anything on future objects
    IF EXISTS (SELECT 1 FROM pg_default_acl d, aclexplode(d.defaclacl) a
                WHERE d.defaclrole = (SELECT oid FROM pg_roles WHERE rolname = current_user)
                  AND a.grantee = (SELECT oid FROM pg_roles WHERE rolname = 'aa_app_user')) THEN
        RAISE EXCEPTION 'migration 229: a default privilege of % still grants aa_app_user', current_user;
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('229', now(),
    'AA-817: tenant-pool RLS template (TO aa_app_user, NULLIF app.tenant_id, WITH CHECK) on '
    'tenant_tour_versions, angle_gate_request, content_piece, publish_log, facts (platform rows '
    'read-only); drop drift policies; SELECT/INSERT/UPDATE on tenant_tour_versions to aa_app_user; '
    'no default privileges to aa_app_user. ENABLE without FORCE (owner exempt)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
