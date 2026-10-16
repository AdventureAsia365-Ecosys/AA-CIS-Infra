-- Migration 239: AA-817 — the tenant pool (aa_app_user) reads AA master rows of published_tours /
-- raw_tours / seo_context, '' means "no tenant" on every legacy FORCE-RLS policy, and the tenant pool
-- can no longer write tables that have no RLS.
--
-- Why.
--   * Master read. Tenant routes join the tenant's own rows to AA master content (tenant
--     00000000-0000-0000-0000-000000000001: every row of published_tours / raw_tours / seo_context on
--     Dev). Under aa_app_user with the tenant's app.tenant_id, tenant_isolation (TO public, FORCE) hides
--     every master row, so a T2 route moved to the tenant pool would return nothing (AA-817 plan §3,
--     S239). The S237 probe after 229 (AA-Ecosys/docs/audits/2026-10-14-S237-lane-backlog/aa817/
--     probe-after-229.json): aa_app_user reads 892 / 987 / 918 rows with GUC = master, 0 with any
--     other tenant.
--   * NULLIF. generated_content, quality_scores, seo_context, content_exports, webhook_deliveries and
--     pipeline_runs keep the 004/006/008 policy `tenant_id = current_setting('app.tenant_id', true)::uuid`:
--     on a pooled connection that holds '' (after any set_config(..., true) transaction) every read by a
--     filtered role raises 22P02 "invalid input syntax for type uuid" instead of returning no rows (same
--     probe: aa_app_user ERR on all six under ''). 225 already fixed published_tours / raw_tours.
--   * No writes without RLS (AA-817 plan critique C1). aa_app_user holds INSERT/UPDATE on
--     acp_shared.angle_gate_option, acp_shared.tenant_atom_state and acp_shared.year_plan (098/147), none
--     of which has RLS: a tenant-pool connection could write any tenant's rows there. No route writes
--     them through the tenant pool (acquire_scoped_conn callers, S239: v1_publish publish-log list and
--     pending, v1_integrations disconnect, content_writing latest-piece and get-piece; the only one of
--     the three they touch is angle_gate_option, read only). SELECT stays (the publish-log list and the
--     latest-piece read join angle_gate_option). Each table gets its writes back with its own RLS, in the
--     migration of the wave that moves its routes.
--
-- What.
--   * GRANT USAGE on gold_aa_internal / silver_aa_internal and SELECT on published_tours, raw_tours,
--     seo_context to aa_app_user (no-ops on Dev, 007b/008; needed in CI, which skips them).
--   * POLICY aa_app_user_aa_master_read ON each of the three AS PERMISSIVE FOR SELECT TO aa_app_user
--     USING (tenant_id = AA master) — the 225 catalog_owner_aa_master_read shape for the tenant role.
--     Not filtered on master_status: a tenant's version of a tour deactivated later must still render
--     (the queries filter themselves). SELECT only: an UPDATE/DELETE needs the FOR ALL tenant_isolation,
--     which master rows fail, so master rows stay read-only for tenants even if a write grant appears.
--     generated_content / quality_scores are left out (AA-796: admin-only on the tenant side).
--   * ALTER POLICY tenant_isolation ... USING (tenant_id = NULLIF(current_setting('app.tenant_id', true),
--     '')::uuid) on the six tables still without NULLIF (and WITH CHECK, if one exists). Same name, TO
--     public, FOR ALL, FORCE kept: TripPlanner and catalog_owner read published_tours / raw_tours through
--     tenant_isolation (229 decision); only '' changes, from an error to no rows, as NULL already did.
--   * REVOKE INSERT, UPDATE, DELETE, TRUNCATE on angle_gate_option, tenant_atom_state, year_plan FROM
--     aa_app_user (DELETE/TRUNCATE are not held on Dev; revoked so the guard can state "no write").
--   * Not here: aa_app_user CONNECTION LIMIT (234 set 15). Raising it is a C2.2 budget decision for the
--     X1 role bootstrap (234's single MIG-6 exception); the tenant pool sizing is handled in code
--     (AA-817 critique C4), not by this file.
--
-- Unchanged for every other reader. The runner (aa_cis_admin: API main pool, worker, DB Migrate) is not
-- filtered by RLS on these eight tables on Dev (probe: row_security_active false, a foreign GUC counts
-- every row, through RDS's rds_superuser — not the owner exemption, the tables are FORCEd; AA-817
-- critique A4); guard 1 refuses to run otherwise, because then '' would turn a loud worker error into
-- silent empty reads. The new policies are TO aa_app_user, which has no members (guarded). tripplanner
-- and catalog_owner read the same rows before and after (guarded by counts when the runner may SET ROLE
-- them; no membership in another app's role is ever granted). Owner-rights views (v_trip_registry,
-- v_active_tour_atoms, catalog.*) read as their owner, unaffected.
--
-- Not destructive (no row is changed or removed), so no `migrate:` header directive.
--
-- Guards (lesson S236: check RLS by behaviour, not by role attributes):
--   1. before: the eight tables exist with RLS on and a uuid tenant_id; tenant_isolation is TO public,
--      FOR ALL, permissive, and its USING (and WITH CHECK, if any) is either the 004/006/008 or the NULLIF
--      form — anything else is drift a human must look at; no policy outside the expected set (an unknown
--      permissive policy would OR into the tenant's view); the runner is not filtered; aa_app_user is
--      not superuser/BYPASSRLS and has no members; the three REVOKE tables exist without RLS (with RLS
--      a later wave owns their grants); acp_shared.acp_output_rules, when present, stays deny-all for
--      aa_app_user (RLS on, no policy, no privilege). Then lock the eight tables (ACCESS EXCLUSIVE, the
--      lock ALTER/CREATE POLICY take anyway) and record the runner's count under a foreign GUC and the
--      tripplanner / catalog_owner counts on published_tours / raw_tours;
--   2. after, as the runner: still not filtered, same counts under a foreign GUC;
--   3. policy shapes: tenant_isolation is the NULLIF form on all eight; aa_app_user_aa_master_read is
--      FOR SELECT TO aa_app_user on the master tenant; each table's policy set is exactly the expected one;
--   4. after, as aa_app_user (the runner is made a member for this transaction only when it may not SET
--      ROLE aa_app_user already, then the membership is revoked, as in 225/229/237), on every table it
--      may read, under a foreign, an empty, the master and the busiest non-master tenant's GUC: the
--      count is exactly the runner's count of that tenant plus, on the three master-read tables, the
--      master rows; 0 rows of any other tenant; where it may UPDATE (Dev: pipeline_runs), a WHERE-less
--      UPDATE under a foreign or empty GUC touches 0 rows;
--   5. grants: aa_app_user has SELECT on the three master-read tables, no DELETE/TRUNCATE on any of the
--      eight (TRUNCATE is not filtered by RLS), no INSERT/UPDATE/DELETE/TRUNCATE on the three REVOKE
--      tables; tripplanner / catalog_owner counts unchanged.
--
-- Cross-owner grants are not guarded by IF EXISTS(role) (schema-ownership rule 5): aa_app_user must
-- exist (007b on Dev, conftest in CI). Idempotent: the new policy is dropped by name and recreated, the
-- ALTERs run only on the old form, REVOKE of a privilege not held is a no-op.
--
-- Locks. ALTER/CREATE POLICY take ACCESS EXCLUSIVE on tables the worker and TripPlanner read all the
-- time: lock_timeout 10s gives up instead of queueing every reader. Apply with shared.job idle (the DB
-- Migrate rule; no t2_rewrite / t9_write / pipeline job queued or running).
--
-- After apply: rerun the AA-817 probe v2 (expected: aa_app_user pt/rt/sc = master rows under foreign /
-- '' / own, 0 non-master rows; generated_content, quality_scores, content_exports, webhook_deliveries,
-- pipeline_runs '' = 0/0, no error), then regenerate docs/architecture/db-schema-reference.md.
--
-- Rollback (restores the pre-239 state; no code depends on 239 yet):
--   DROP POLICY IF EXISTS aa_app_user_aa_master_read ON gold_aa_internal.published_tours;   -- and raw_tours,
--                                                                                         -- seo_context
--   ALTER POLICY tenant_isolation ON <each of the six>
--       USING (tenant_id = current_setting('app.tenant_id', true)::uuid);
--   GRANT INSERT, UPDATE ON acp_shared.angle_gate_option, acp_shared.tenant_atom_state, acp_shared.year_plan
--       TO aa_app_user;
--   DELETE FROM shared.schema_versions WHERE version = '239';
--   (The SELECT / USAGE grants predate 239 on Dev, 007b/008: leave them.)

BEGIN;

SET LOCAL lock_timeout = '10s';

-- ── Guard 1: the state this file expects; lock; counts before ─────────────────────────────────────
DO $$
DECLARE
    t           text;
    r           text;
    g           text;
    pol         record;
    pols        text[];
    expected    text[];
    rls         boolean;
    n           bigint;
    bad         text;
    master      constant text := '00000000-0000-0000-0000-000000000001';
    foreign_guc constant text := '00000000-0000-0000-0000-00000000dead';
    old_qual    constant text := '(tenant_id = (current_setting(''app.tenant_id''::text, true))::uuid)';
    new_qual    constant text := '(tenant_id = (NULLIF(current_setting(''app.tenant_id''::text, true), '''''
                                 '::text))::uuid)';
    legacy      constant text[] := ARRAY['gold_aa_internal.published_tours', 'silver_aa_internal.raw_tours',
                                         'silver_aa_internal.seo_context', 'silver_aa_internal.generated_content',
                                         'silver_aa_internal.quality_scores', 'gold_aa_internal.content_exports',
                                         'gold_aa_internal.webhook_deliveries', 'shared.pipeline_runs'];
BEGIN
    FOREACH t IN ARRAY legacy LOOP
        IF to_regclass(t) IS NULL THEN
            RAISE EXCEPTION 'migration 239: % does not exist', t;
        END IF;
        SELECT c.relrowsecurity INTO rls FROM pg_class c WHERE c.oid = t::regclass;
        IF NOT rls THEN
            RAISE EXCEPTION 'migration 239: % has no ROW LEVEL SECURITY (expected ENABLE, 004/006/008)', t;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = t::regclass AND attname = 'tenant_id'
                          AND atttypid = 'uuid'::regtype AND NOT attisdropped) THEN
            RAISE EXCEPTION 'migration 239: %.tenant_id is not a uuid column', t;
        END IF;

        SELECT * INTO pol FROM pg_policies
         WHERE schemaname || '.' || tablename = t AND policyname = 'tenant_isolation';
        IF NOT FOUND THEN
            RAISE EXCEPTION 'migration 239: policy tenant_isolation missing on %', t;
        END IF;
        IF pol.roles <> ARRAY['public']::name[] OR pol.cmd <> 'ALL' OR pol.permissive <> 'PERMISSIVE' THEN
            RAISE EXCEPTION 'migration 239: tenant_isolation on % is % % TO %, expected PERMISSIVE ALL TO public',
                            t, pol.permissive, pol.cmd, pol.roles;
        END IF;
        IF pol.qual NOT IN (old_qual, new_qual)
           OR (pol.with_check IS NOT NULL AND pol.with_check NOT IN (old_qual, new_qual)) THEN
            RAISE EXCEPTION 'migration 239: tenant_isolation on % is USING % WITH CHECK % (expected the '
                            '004/006/008 or the NULLIF form): drift, look before applying', t, pol.qual, pol.with_check;
        END IF;

        expected := CASE
            WHEN t IN ('gold_aa_internal.published_tours', 'silver_aa_internal.raw_tours')
                THEN ARRAY['aa_app_user_aa_master_read', 'catalog_owner_aa_master_read', 'tenant_isolation']
            WHEN t = 'silver_aa_internal.seo_context'
                THEN ARRAY['aa_app_user_aa_master_read', 'tenant_isolation']
            ELSE ARRAY['tenant_isolation'] END;
        SELECT array_agg(policyname::text ORDER BY policyname) INTO pols
          FROM pg_policies WHERE schemaname || '.' || tablename = t;
        IF NOT pols <@ expected THEN
            RAISE EXCEPTION 'migration 239: % has policies % (expected a subset of %): an unknown permissive '
                            'policy would OR into the tenant''s view', t, pols, expected;
        END IF;

        -- The premise "the main pool is unaffected": the runner is not filtered here (RDS rds_superuser
        -- on Dev, superuser in CI). If it were, '' would turn its errors into silent empty reads.
        IF row_security_active(t::regclass) THEN
            RAISE EXCEPTION 'migration 239: RLS is active for the runner % on %: changing what '''' means '
                            'would change the main pool / worker, decide first (AA-817 critique A4)', current_user, t;
        END IF;

        -- Take the lock ALTER/CREATE POLICY need anyway before counting, so no row can be added or
        -- removed between this count and guard 2.
        EXECUTE format('LOCK TABLE %s IN ACCESS EXCLUSIVE MODE', t);
        PERFORM set_config('app.tenant_id', foreign_guc, true);
        EXECUTE format('SELECT count(*) FROM %s', t) INTO n;
        PERFORM set_config('aa239.n_' || replace(t, '.', '__'), n::text, true);
    END LOOP;

    -- the new policies reach aa_app_user sessions only
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'aa_app_user' AND (rolsuper OR rolbypassrls)) THEN
        RAISE EXCEPTION 'migration 239: aa_app_user is superuser or BYPASSRLS: RLS does not apply to it';
    END IF;
    SELECT string_agg(m.member::regrole::text, ', ') INTO bad
      FROM pg_auth_members m
     WHERE m.roleid = 'aa_app_user'::regrole
       AND m.member <> (SELECT oid FROM pg_roles WHERE rolname = current_user);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 239: % are members of aa_app_user: aa_app_user_aa_master_read would apply '
                        'to their sessions too', bad;
    END IF;

    -- the three tables losing tenant-pool writes have no RLS yet (with RLS, a later wave owns their grants)
    FOREACH t IN ARRAY ARRAY['acp_shared.angle_gate_option', 'acp_shared.tenant_atom_state',
                             'acp_shared.year_plan'] LOOP
        IF to_regclass(t) IS NULL THEN
            RAISE EXCEPTION 'migration 239: % does not exist', t;
        END IF;
        SELECT c.relrowsecurity INTO rls FROM pg_class c WHERE c.oid = t::regclass;
        IF rls THEN
            RAISE EXCEPTION 'migration 239: % already has ROW LEVEL SECURITY: its tenant-pool grants belong to '
                            'the migration that enabled it, take it out of this REVOKE', t;
        END IF;
    END LOOP;

    -- acp_output_rules (live-only table, not created by any CIS migration): deny-all for aa_app_user
    IF to_regclass('acp_shared.acp_output_rules') IS NOT NULL THEN
        SELECT c.relrowsecurity INTO rls FROM pg_class c WHERE c.oid = 'acp_shared.acp_output_rules'::regclass;
        IF NOT rls
           OR EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'acp_shared' AND tablename = 'acp_output_rules')
           OR has_table_privilege('aa_app_user', 'acp_shared.acp_output_rules',
                                  'SELECT, INSERT, UPDATE, DELETE, TRUNCATE') THEN
            RAISE EXCEPTION 'migration 239: acp_shared.acp_output_rules is no longer deny-all for aa_app_user '
                            '(expected RLS on, no policy, no privilege; 229)';
        END IF;
    END IF;

    -- tripplanner / catalog_owner read published_tours / raw_tours through tenant_isolation and
    -- catalog_owner_aa_master_read: count what they see now, compared in guard 5. Only when the runner
    -- may SET ROLE them (RDS: yes; CI: superuser); no membership in another app's role is granted.
    FOREACH r IN ARRAY ARRAY['tripplanner', 'catalog_owner'] LOOP
        FOREACH t IN ARRAY ARRAY['gold_aa_internal.published_tours', 'silver_aa_internal.raw_tours'] LOOP
            FOREACH g IN ARRAY ARRAY[master, foreign_guc] LOOP
                n := NULL;
                BEGIN
                    PERFORM set_config('app.tenant_id', g, true);
                    EXECUTE format('SET LOCAL ROLE %I', r);
                    EXECUTE format('SELECT count(tour_id) FROM %s', t) INTO n;   -- tripplanner: column grant
                    RESET ROLE;
                EXCEPTION WHEN insufficient_privilege OR invalid_parameter_value THEN
                    RESET ROLE;                                     -- no SET ROLE or no grant: not compared
                END;
                PERFORM set_config(format('aa239.%s__%s__%s', r, replace(t, '.', '__'), right(g, 4)),
                                   coalesce(n::text, ''), true);
            END LOOP;
        END LOOP;
    END LOOP;
    PERFORM set_config('app.tenant_id', '', true);
END $$;

-- ── (a) master read for the tenant role ───────────────────────────────────────────────────────────
GRANT USAGE ON SCHEMA gold_aa_internal, silver_aa_internal TO aa_app_user;
GRANT SELECT ON gold_aa_internal.published_tours, silver_aa_internal.raw_tours, silver_aa_internal.seo_context
    TO aa_app_user;

DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['gold_aa_internal.published_tours', 'silver_aa_internal.raw_tours',
                             'silver_aa_internal.seo_context'] LOOP
        EXECUTE format('DROP POLICY IF EXISTS aa_app_user_aa_master_read ON %s', t);
        EXECUTE format('CREATE POLICY aa_app_user_aa_master_read ON %s AS PERMISSIVE FOR SELECT TO aa_app_user '
                       'USING (tenant_id = %L::uuid)', t, '00000000-0000-0000-0000-000000000001');
        EXECUTE format('COMMENT ON POLICY aa_app_user_aa_master_read ON %s IS %L', t,
                       'AA-817 (239): the tenant pool (aa_app_user) reads AA master-tenant rows under any '
                       'app.tenant_id (T2 joins own versions to master content). SELECT only.');
    END LOOP;
END $$;

-- ── (b) tenant_isolation: '' means "no tenant", not an error ─────────────────────────────────────
DO $$
DECLARE
    t        text;
    pol      record;
    old_qual constant text := '(tenant_id = (current_setting(''app.tenant_id''::text, true))::uuid)';
    expr     constant text := 'tenant_id = NULLIF(current_setting(''app.tenant_id'', true), '''')::uuid';
BEGIN
    FOREACH t IN ARRAY ARRAY['silver_aa_internal.seo_context', 'silver_aa_internal.generated_content',
                             'silver_aa_internal.quality_scores', 'gold_aa_internal.content_exports',
                             'gold_aa_internal.webhook_deliveries', 'shared.pipeline_runs'] LOOP
        SELECT qual, with_check INTO pol FROM pg_policies
         WHERE schemaname || '.' || tablename = t AND policyname = 'tenant_isolation';
        IF pol.qual = old_qual THEN
            EXECUTE format('ALTER POLICY tenant_isolation ON %s USING (%s)', t, expr);
        END IF;
        IF pol.with_check = old_qual THEN
            EXECUTE format('ALTER POLICY tenant_isolation ON %s WITH CHECK (%s)', t, expr);
        END IF;
    END LOOP;
END $$;

-- ── (c) no tenant-pool writes on tables without RLS ───────────────────────────────────────────────
REVOKE INSERT, UPDATE, DELETE, TRUNCATE
    ON acp_shared.angle_gate_option, acp_shared.tenant_atom_state, acp_shared.year_plan
    FROM aa_app_user;

-- ── Guards 2-5 ────────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    t           text;
    r           text;
    g           text;
    guc         text;
    own         uuid;
    pols        text[];
    expected    text[];
    n           bigint;
    n_before    text;
    n_master    bigint;
    n_tenant    bigint;
    n_expected  bigint;
    granted     boolean := false;
    is_master_read boolean;
    master      constant text := '00000000-0000-0000-0000-000000000001';
    foreign_guc constant text := '00000000-0000-0000-0000-00000000dead';
    new_qual    constant text := '(tenant_id = (NULLIF(current_setting(''app.tenant_id''::text, true), '''''
                                 '::text))::uuid)';
    master_qual constant text := '(tenant_id = ''00000000-0000-0000-0000-000000000001''::uuid)';
    legacy      constant text[] := ARRAY['gold_aa_internal.published_tours', 'silver_aa_internal.raw_tours',
                                         'silver_aa_internal.seo_context', 'silver_aa_internal.generated_content',
                                         'silver_aa_internal.quality_scores', 'gold_aa_internal.content_exports',
                                         'gold_aa_internal.webhook_deliveries', 'shared.pipeline_runs'];
    master_read constant text[] := ARRAY['gold_aa_internal.published_tours', 'silver_aa_internal.raw_tours',
                                         'silver_aa_internal.seo_context'];
BEGIN
    FOREACH t IN ARRAY legacy LOOP
        -- 2. the runner: still not filtered, same rows under a foreign tenant
        IF row_security_active(t::regclass) THEN
            RAISE EXCEPTION 'migration 239: RLS is active for the runner % on %', current_user, t;
        END IF;
        PERFORM set_config('app.tenant_id', foreign_guc, true);
        EXECUTE format('SELECT count(*) FROM %s', t) INTO n;
        IF n <> current_setting('aa239.n_' || replace(t, '.', '__'))::bigint THEN
            RAISE EXCEPTION 'migration 239: the runner sees % of % rows of % under a foreign tenant',
                            n, current_setting('aa239.n_' || replace(t, '.', '__')), t;
        END IF;

        -- 3. policy shapes and sets
        is_master_read := t = ANY (master_read);
        IF NOT EXISTS (SELECT 1 FROM pg_policies
                        WHERE schemaname || '.' || tablename = t AND policyname = 'tenant_isolation'
                          AND roles = ARRAY['public']::name[] AND cmd = 'ALL' AND permissive = 'PERMISSIVE'
                          AND qual = new_qual AND (with_check IS NULL OR with_check = new_qual)) THEN
            RAISE EXCEPTION 'migration 239: tenant_isolation on % is not PERMISSIVE ALL TO public USING the '
                            'NULLIF form', t;
        END IF;
        IF is_master_read AND NOT EXISTS (
                SELECT 1 FROM pg_policies
                 WHERE schemaname || '.' || tablename = t AND policyname = 'aa_app_user_aa_master_read'
                   AND roles = ARRAY['aa_app_user']::name[] AND cmd = 'SELECT' AND permissive = 'PERMISSIVE'
                   AND qual = master_qual AND with_check IS NULL) THEN
            RAISE EXCEPTION 'migration 239: aa_app_user_aa_master_read on % is not FOR SELECT TO aa_app_user '
                            'USING the master tenant', t;
        END IF;
        expected := CASE
            WHEN t IN ('gold_aa_internal.published_tours', 'silver_aa_internal.raw_tours')
                THEN ARRAY['aa_app_user_aa_master_read', 'catalog_owner_aa_master_read', 'tenant_isolation']
            WHEN t = 'silver_aa_internal.seo_context'
                THEN ARRAY['aa_app_user_aa_master_read', 'tenant_isolation']
            ELSE ARRAY['tenant_isolation'] END;
        SELECT array_agg(policyname::text ORDER BY policyname) INTO pols
          FROM pg_policies WHERE schemaname || '.' || tablename = t;
        IF pols IS DISTINCT FROM expected THEN
            RAISE EXCEPTION 'migration 239: % has policies %, expected %', t, pols, expected;
        END IF;

        -- 5a. no DELETE / TRUNCATE for the tenant role on the eight (TRUNCATE is not filtered by RLS)
        IF has_table_privilege('aa_app_user', t, 'DELETE, TRUNCATE') THEN
            RAISE EXCEPTION 'migration 239: aa_app_user has DELETE or TRUNCATE on %', t;
        END IF;
        IF is_master_read AND NOT has_table_privilege('aa_app_user', t, 'SELECT') THEN
            RAISE EXCEPTION 'migration 239: aa_app_user lacks SELECT on %', t;
        END IF;
    END LOOP;

    -- 5b. no write on the three tables without RLS; SELECT kept where it was
    FOREACH t IN ARRAY ARRAY['acp_shared.angle_gate_option', 'acp_shared.tenant_atom_state',
                             'acp_shared.year_plan'] LOOP
        IF has_table_privilege('aa_app_user', t, 'INSERT, UPDATE, DELETE, TRUNCATE') THEN
            RAISE EXCEPTION 'migration 239: aa_app_user can still write %', t;
        END IF;
    END LOOP;

    -- 4. aa_app_user is isolated, and reads the master rows of the three master-read tables. The runner
    --    becomes a member for this transaction only when it may not SET ROLE aa_app_user already (RDS:
    --    aa_cis_admin has CREATEROLE), revoked below.
    BEGIN
        SET LOCAL ROLE aa_app_user;                         -- already allowed (RDS, CI superuser)?
        RESET ROLE;
    EXCEPTION WHEN insufficient_privilege THEN
        EXECUTE format('GRANT aa_app_user TO %I', current_user);
        granted := true;
    END;
    FOREACH t IN ARRAY legacy LOOP
        CONTINUE WHEN NOT has_table_privilege('aa_app_user', t, 'SELECT');   -- no read path to check
        is_master_read := t = ANY (master_read);
        -- counted as the (unfiltered) runner
        EXECUTE format('SELECT count(*) FROM %s WHERE tenant_id = %L::uuid', t, master) INTO n_master;
        EXECUTE format('SELECT tenant_id FROM %s WHERE tenant_id <> %L::uuid GROUP BY tenant_id '
                       'ORDER BY count(*) DESC, tenant_id LIMIT 1', t, master) INTO own;
        FOREACH guc IN ARRAY ARRAY[foreign_guc, '', master, own::text] LOOP
            CONTINUE WHEN guc IS NULL;                      -- no non-master tenant in the table
            IF guc = '' THEN
                n_tenant := 0;
            ELSE
                EXECUTE format('SELECT count(*) FROM %s WHERE tenant_id = %L::uuid', t, guc) INTO n_tenant;
            END IF;
            n_expected := n_tenant + CASE WHEN is_master_read AND guc <> master THEN n_master ELSE 0 END;

            PERFORM set_config('app.tenant_id', guc, true);
            SET LOCAL ROLE aa_app_user;
            EXECUTE format('SELECT count(*) FROM %s', t) INTO n;                       -- no WHERE on purpose
            RESET ROLE;
            IF n <> n_expected THEN
                RAISE EXCEPTION 'migration 239: aa_app_user reads % rows of % with app.tenant_id=''%'' '
                                '(expected %)', n, t, guc, n_expected;
            END IF;
            SET LOCAL ROLE aa_app_user;
            EXECUTE format('SELECT count(*) FROM %s WHERE tenant_id <> %L::uuid '
                           'AND tenant_id IS DISTINCT FROM NULLIF(%L, '''')::uuid', t, master, guc) INTO n;
            RESET ROLE;
            IF n <> 0 THEN
                RAISE EXCEPTION 'migration 239: aa_app_user reads % rows of another tenant in % with '
                                'app.tenant_id=''%''', n, t, guc;
            END IF;
            -- the write side of '' and of a forged tenant: a WHERE-less UPDATE touches nothing
            CONTINUE WHEN guc NOT IN (foreign_guc, '') OR NOT has_table_privilege('aa_app_user', t, 'UPDATE');
            SET LOCAL ROLE aa_app_user;
            EXECUTE format('UPDATE %s SET tenant_id = tenant_id', t);                  -- no WHERE on purpose
            GET DIAGNOSTICS n = ROW_COUNT;
            RESET ROLE;
            IF n <> 0 THEN                                  -- raising rolls the whole apply back
                RAISE EXCEPTION 'migration 239: aa_app_user updated % rows of % with app.tenant_id=''%''',
                                n, t, guc;
            END IF;
        END LOOP;
    END LOOP;
    PERFORM set_config('app.tenant_id', '', true);
    IF granted THEN
        EXECUTE format('REVOKE aa_app_user FROM %I', current_user);
    END IF;

    -- 5c. tripplanner / catalog_owner see what they saw before (compared only where guard 1 counted)
    FOREACH r IN ARRAY ARRAY['tripplanner', 'catalog_owner'] LOOP
        FOREACH t IN ARRAY ARRAY['gold_aa_internal.published_tours', 'silver_aa_internal.raw_tours'] LOOP
            FOREACH g IN ARRAY ARRAY[master, foreign_guc] LOOP
                n_before := current_setting(format('aa239.%s__%s__%s', r, replace(t, '.', '__'), right(g, 4)));
                CONTINUE WHEN n_before = '';
                PERFORM set_config('app.tenant_id', g, true);
                EXECUTE format('SET LOCAL ROLE %I', r);
                EXECUTE format('SELECT count(tour_id) FROM %s', t) INTO n;
                RESET ROLE;
                IF n <> n_before::bigint THEN
                    RAISE EXCEPTION 'migration 239: % reads % rows of % with app.tenant_id=''%'' (% before)',
                                    r, n, t, g, n_before;
                END IF;
            END LOOP;
        END LOOP;
    END LOOP;
    PERFORM set_config('app.tenant_id', '', true);
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('239', now(),
    'AA-817: aa_app_user_aa_master_read (FOR SELECT TO aa_app_user, AA master tenant) on published_tours, '
    'raw_tours, seo_context + SELECT grants; tenant_isolation NULLIF on seo_context, generated_content, '
    'quality_scores, content_exports, webhook_deliveries, pipeline_runs (empty app.tenant_id = no rows); '
    'REVOKE INSERT/UPDATE/DELETE/TRUNCATE on angle_gate_option, tenant_atom_state, year_plan from aa_app_user')
ON CONFLICT (version) DO NOTHING;

COMMIT;
