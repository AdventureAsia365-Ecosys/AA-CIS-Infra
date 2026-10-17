-- Migration 237: AA-817 (scope addition 1) — shared.tenant_integrations on the migration-229 RLS
-- template, plus the SELECT/DELETE grants the tenant-pool disconnect route needs.
--
-- Why. DELETE /v1/integrations/{wordpress|facebook} (api/routers/v1_integrations.py _disconnect, AA-815)
-- already runs through acquire_scoped_conn behind the flag aa544:integration_disconnect_pool, which
-- must stay off (api/core/aa544_tenant_pool.py): on Dev the table has no RLS and aa_app_user holds only
-- SELECT on it (from 007b's default privileges, which 229 stopped for new tables). With the flag on,
-- the DELETE would fail after the secret was already tombstoned, and without RLS a tenant-pool query
-- that forgot its WHERE tenant_id would read every tenant's integration rows (secret_key names).
-- The S237 probe (AA-Ecosys/docs/audits/2026-10-14-S237-lane-backlog/aa817/probe.json and
-- probe-after-229.json): owner aa_cis_admin, rls false, force false, privileges aa_app_user = S only.
--
-- What. The 229 template, unchanged:
--     ENABLE ROW LEVEL SECURITY (no FORCE, decision D2: the owner stays exempt)
--     POLICY tenant_isolation AS PERMISSIVE FOR ALL TO aa_app_user
--         USING      (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
--         WITH CHECK (same)
--     GRANT SELECT, DELETE ON shared.tenant_integrations TO aa_app_user
-- SELECT: _disconnect reads secret_key first, and a DELETE ... WHERE needs SELECT on the columns it
-- filters. DELETE: the disconnect itself. No INSERT/UPDATE: connect and test-connection stay on the
-- main pool; a later migration grants them when those routes move (the FOR ALL policy with WITH
-- CHECK already covers them). '' must mean "no tenant" (0 rows, no error): a pooled connection holds
-- '' after any set_config(..., true) transaction (lesson of 225).
--
-- Unchanged for every other reader. The main pool (API, worker, DB Migrate: aa_cis_admin) owns the
-- table and stays exempt, so publish/unpublish (v1_publish.py), connect/test (v1_integrations.py), the
-- WordPress/Facebook publishers, offboard and the shared.tenants ON DELETE CASCADE are untouched (RLS
-- does not apply to foreign-key actions). No other role holds a privilege on the table (guard 1
-- refuses to run if one does: ENABLE with a policy TO aa_app_user only would hide every row from it).
--
-- Guards (lesson S236: check RLS by behaviour, not by role attributes), the 229 set for one table:
--   1. before: the table exists, the runner owns it (or is superuser/BYPASSRLS), it is not FORCEd, no
--      role other than the owner and aa_app_user holds a privilege on it; lock, then count;
--   2. after, as the runner: RLS is not active for it and it still counts every row under a foreign
--      app.tenant_id;
--   3. after, as aa_app_user (the runner is made a member for this transaction only when it may not
--      SET ROLE aa_app_user already, then the membership is revoked, as in 225/229): a foreign or empty
--      GUC reads 0 rows and a WHERE-less DELETE under them deletes 0 rows; the busiest tenant reads
--      exactly its own rows;
--   4. the policy set is exactly {tenant_isolation}, TO aa_app_user only, FOR ALL, with USING and WITH
--      CHECK on the NULLIF'd GUC (checked by shape: on an empty table guard 3's counts prove nothing,
--      and Dev had 0 rows when this was written, S239);
--   5. aa_app_user has SELECT and DELETE and no TRUNCATE (TRUNCATE is not filtered by RLS).
--
-- Cross-owner grants are not guarded by IF EXISTS(role) (schema-ownership rule 5): aa_app_user must
-- exist (007b on Dev, conftest in CI). GRANT USAGE ON SCHEMA shared is a no-op on Dev (007b/008) and
-- needed in CI, which skips 007b/008. Idempotent: the policy is dropped by name and recreated.
--
-- Locks. ENABLE ROW LEVEL SECURITY and DROP/CREATE POLICY take ACCESS EXCLUSIVE on a small table that
-- only the integrations/publish routes and the publishers read; lock_timeout 10s gives up instead of
-- queueing those requests. Apply in a window with no publish job queued or running (shared.job idle,
-- the DB Migrate rule). The code does not need 237 to run: the flag stays off until an observed
-- window after it is applied.
--
-- After apply: rerun the AA-817 probe (expected for shared.tenant_integrations: rls true, force false,
-- aa_app_user S+D; as aa_app_user foreign 0/0, empty 0/0, own n/1), then regenerate
-- docs/architecture/db-schema-reference.md.
--
-- Rollback (restores the pre-237 state). First turn the flag OFF: `SET aa544:integration_disconnect_pool
-- false` (NOT DEL: since S241 D-12 a missing key means ON) plus the api env var
-- TENANT_POOL_FORCE_ADMIN_FLAGS so it survives a Redis restart, and confirm used_tenant_pool=False in Logs
-- Insights; the code works either way only while the flag is OFF:
--   DROP POLICY IF EXISTS tenant_isolation ON shared.tenant_integrations;
--   ALTER TABLE shared.tenant_integrations DISABLE ROW LEVEL SECURITY;
--   REVOKE DELETE ON shared.tenant_integrations FROM aa_app_user;   -- SELECT predates 237 (007b)
--   DELETE FROM shared.schema_versions WHERE version = '237';

BEGIN;

SET LOCAL lock_timeout = '10s';

-- ── Guard 1: exists, owned by the runner, not FORCEd, no other grantee; lock, then count ─────────
DO $$
DECLARE
    owner_ok   boolean;
    forced     boolean;
    privileged boolean;
    others     text;
BEGIN
    IF to_regclass('shared.tenant_integrations') IS NULL THEN
        RAISE EXCEPTION 'migration 237: shared.tenant_integrations does not exist';
    END IF;
    SELECT rolsuper OR rolbypassrls INTO privileged FROM pg_roles WHERE rolname = current_user;
    SELECT pg_has_role(current_user, c.relowner, 'USAGE'), c.relforcerowsecurity
      INTO owner_ok, forced
      FROM pg_class c WHERE c.oid = 'shared.tenant_integrations'::regclass;
    IF NOT owner_ok AND NOT privileged THEN
        RAISE EXCEPTION 'migration 237: % neither owns shared.tenant_integrations nor bypasses RLS: '
                        'ENABLE ROW LEVEL SECURITY would hide its rows from the main pool', current_user;
    END IF;
    IF forced THEN
        RAISE EXCEPTION 'migration 237: shared.tenant_integrations has FORCE ROW LEVEL SECURITY: with a '
                        'policy TO aa_app_user only, the owner (main pool) would read 0 rows (decision D2)';
    END IF;
    SELECT string_agg(DISTINCT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END, ', ')
      INTO others
      FROM pg_class c, aclexplode(c.relacl) a
     WHERE c.oid = 'shared.tenant_integrations'::regclass
       AND a.grantee <> c.relowner
       AND a.grantee <> (SELECT oid FROM pg_roles WHERE rolname = 'aa_app_user');
    IF others IS NOT NULL THEN
        RAISE EXCEPTION 'migration 237: % hold privileges on shared.tenant_integrations: with RLS on and a '
                        'policy TO aa_app_user only they would read 0 rows', others;
    END IF;
    -- Take the lock ENABLE / CREATE POLICY need anyway before counting, so no row can be added or
    -- removed between this count and guard 2 (a concurrent connect/disconnect would otherwise abort
    -- the apply on a false "runner is filtered").
    LOCK TABLE shared.tenant_integrations IN ACCESS EXCLUSIVE MODE;
    PERFORM set_config('aa237.n_before', (SELECT count(*) FROM shared.tenant_integrations)::text, true);
END $$;

-- ── The 229 template ───────────────────────────────────────────────────────────────────────────
ALTER TABLE shared.tenant_integrations ENABLE ROW LEVEL SECURITY;
-- deliberately NO "FORCE ROW LEVEL SECURITY" (D2)

DROP POLICY IF EXISTS tenant_isolation ON shared.tenant_integrations;
CREATE POLICY tenant_isolation ON shared.tenant_integrations AS PERMISSIVE FOR ALL TO aa_app_user
    USING      (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
COMMENT ON POLICY tenant_isolation ON shared.tenant_integrations IS
    'AA-817 (237): the tenant pool (aa_app_user) reads and deletes only rows of app.tenant_id; '''' or '
    'unset = no rows. Owner exempt (no FORCE).';

-- ── Grants the tenant-pool disconnect route needs (DELETE /v1/integrations/{type}) ──────────────
GRANT USAGE ON SCHEMA shared TO aa_app_user;
GRANT SELECT, DELETE ON shared.tenant_integrations TO aa_app_user;

-- ── Guards 2-5 ─────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    n_before    bigint := current_setting('aa237.n_before')::bigint;
    n           bigint;
    n_own       bigint;
    n_expected  bigint;
    own         uuid;
    guc         text;
    granted     boolean := false;
    pols        text[];
    bad_roles   bigint;
    foreign_guc constant text := '00000000-0000-0000-0000-00000000dead';
BEGIN
    -- 2. the runner is still exempt: RLS inactive, every row under a foreign tenant
    PERFORM set_config('app.tenant_id', foreign_guc, true);
    IF row_security_active('shared.tenant_integrations'::regclass) THEN
        RAISE EXCEPTION 'migration 237: RLS is active for the runner % on shared.tenant_integrations',
                        current_user;
    END IF;
    SELECT count(*) INTO n FROM shared.tenant_integrations;
    IF n <> n_before THEN
        RAISE EXCEPTION 'migration 237: the runner sees % of % rows of shared.tenant_integrations under a '
                        'foreign tenant', n, n_before;
    END IF;

    -- 4. exactly the policy created above, TO aa_app_user only
    SELECT array_agg(policyname::text ORDER BY policyname),
           count(*) FILTER (WHERE roles <> ARRAY['aa_app_user']::name[])
      INTO pols, bad_roles
      FROM pg_policies WHERE schemaname = 'shared' AND tablename = 'tenant_integrations';
    IF pols IS DISTINCT FROM ARRAY['tenant_isolation'] OR bad_roles <> 0 THEN
        RAISE EXCEPTION 'migration 237: shared.tenant_integrations has policies % with % not TO aa_app_user '
                        'only (expected {tenant_isolation}, TO aa_app_user)', pols, bad_roles;
    END IF;
    -- and it is the template: FOR ALL, USING and WITH CHECK both compare tenant_id to the NULLIF'd GUC.
    -- Checked by shape too, because guard 3 counts rows and the table may be empty (Dev, S239: 0 rows).
    IF NOT EXISTS (SELECT 1 FROM pg_policies
                    WHERE schemaname = 'shared' AND tablename = 'tenant_integrations'
                      AND policyname = 'tenant_isolation' AND cmd = 'ALL'
                      AND qual ILIKE '%tenant_id = (NULLIF(current_setting(''app.tenant_id''%'
                      AND with_check ILIKE '%tenant_id = (NULLIF(current_setting(''app.tenant_id''%') THEN
        RAISE EXCEPTION 'migration 237: policy tenant_isolation on shared.tenant_integrations is not the 229 '
                        'template (FOR ALL, USING and WITH CHECK tenant_id = NULLIF(app.tenant_id))';
    END IF;

    -- 5. the grants the disconnect route needs, and no TRUNCATE (not filtered by RLS)
    IF NOT has_table_privilege('aa_app_user', 'shared.tenant_integrations', 'SELECT')
       OR NOT has_table_privilege('aa_app_user', 'shared.tenant_integrations', 'DELETE') THEN
        RAISE EXCEPTION 'migration 237: aa_app_user lacks SELECT or DELETE on shared.tenant_integrations';
    END IF;
    IF has_table_privilege('aa_app_user', 'shared.tenant_integrations', 'TRUNCATE') THEN
        RAISE EXCEPTION 'migration 237: aa_app_user has TRUNCATE on shared.tenant_integrations (bypasses RLS)';
    END IF;

    -- 3. aa_app_user is isolated. The runner becomes a member for this transaction only when it may
    --    not SET ROLE aa_app_user already (RDS: aa_cis_admin has CREATEROLE), revoked below.
    BEGIN
        SET LOCAL ROLE aa_app_user;                         -- already allowed (CI superuser)?
        RESET ROLE;
    EXCEPTION WHEN insufficient_privilege THEN
        EXECUTE format('GRANT aa_app_user TO %I', current_user);
        granted := true;
    END;
    -- the busiest tenant and its row count, counted as the (exempt) runner
    SELECT tenant_id, count(*) INTO own, n_own
      FROM shared.tenant_integrations GROUP BY tenant_id ORDER BY count(*) DESC, tenant_id LIMIT 1;
    FOREACH guc IN ARRAY ARRAY[foreign_guc, '', own::text] LOOP
        CONTINUE WHEN guc IS NULL;                          -- empty table: no own tenant to check
        PERFORM set_config('app.tenant_id', guc, true);
        SET LOCAL ROLE aa_app_user;
        SELECT count(*) INTO n FROM shared.tenant_integrations;     -- no WHERE on purpose
        RESET ROLE;
        n_expected := CASE WHEN guc = own::text THEN n_own ELSE 0 END;
        IF n <> n_expected THEN
            RAISE EXCEPTION 'migration 237: aa_app_user reads % rows of shared.tenant_integrations with '
                            'app.tenant_id=''%'' (expected %)', n, guc, n_expected;
        END IF;
        CONTINUE WHEN guc = own::text;                      -- never delete a real row, even in a guard
        SET LOCAL ROLE aa_app_user;
        DELETE FROM shared.tenant_integrations;             -- no WHERE on purpose: must delete nothing
        GET DIAGNOSTICS n = ROW_COUNT;
        RESET ROLE;
        IF n <> 0 THEN                                      -- raising rolls the whole apply back
            RAISE EXCEPTION 'migration 237: aa_app_user deleted % rows of shared.tenant_integrations with '
                            'app.tenant_id=''%''', n, guc;
        END IF;
    END LOOP;
    PERFORM set_config('app.tenant_id', '', true);

    IF granted THEN
        EXECUTE format('REVOKE aa_app_user FROM %I', current_user);
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('237', now(),
    'AA-817: shared.tenant_integrations on the 229 RLS template (ENABLE without FORCE, tenant_isolation '
    'TO aa_app_user, NULLIF app.tenant_id, WITH CHECK); SELECT/DELETE to aa_app_user for the '
    'tenant-pool disconnect route')
ON CONFLICT (version) DO NOTHING;

COMMIT;
