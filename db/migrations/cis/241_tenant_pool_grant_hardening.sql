-- Migration 241: AA-859 — the tenant role (aa_app_user) holds no privilege on any CIS relation without
-- RLS (catalog contract kept), acp_shared.angle_gate_option goes under RLS through its parent request,
-- and the tenant pool may write the columns the integration connect / test routes write.
--
-- Why.
--   * Item 5. aa_app_user is the role of the API tenant pool (secret aa-cis/dev/rds-app-user). On a
--     table without RLS a grant to it is a grant on every tenant's rows: a tenant-pool query that
--     forgets its WHERE tenant_id reads (or writes) them all. 239 took the writes away on three
--     acp_shared tables; Dev still has SELECT on ~30 relations without RLS (S240 grants probe):
--     shared.tenants (api_key_hash), tenant_export_config (auth_header), tenant_brand_rules,
--     tenant_seo_config, llm_call_log, decision_log, job, ... and the owner-rights view
--     acp_contract.v_active_tour_atoms (reads every tenant's atoms as its owner). No tenant-pool route
--     reads any of them (acquire_scoped_conn callers, S240: publish-log list / pending, latest-piece,
--     get-piece, integration disconnect; they read publish_log, content_piece, angle_gate_request,
--     tenant_integrations, all RLS, and angle_gate_option, which gets RLS here). Revoking
--     v_active_tour_atoms now also matters for later: 243 grants USAGE on acp_contract.
--   * W3. The angle-gate choose / reopen routes (PR-D3) UPDATE angle_gate_option.chosen on the tenant
--     pool. The table has no tenant column; a request's options belong to the request's tenant.
--   * W9. Connect (INSERT ... ON CONFLICT DO UPDATE) and test-connection (UPDATE) move to the tenant
--     pool (PR-I). 237 already put shared.tenant_integrations under a FOR ALL policy with WITH CHECK;
--     it granted only SELECT and DELETE.
--
-- What.
--   1. The rule (AA-859 plan D1): REVOKE ALL FROM aa_app_user on every relation (table, partitioned
--      table, view, matview, foreign table; column privileges go with the table's) that has no RLS,
--      whose owner the runner can act for, whose owner is not catalog_owner / tripplanner / booking
--      (the CI runner is a superuser, for whom pg_has_role is always true), outside the other apps'
--      schemas tripplanner / booking (schema-ownership rule 1). Sequences are out of the rule (no
--      tenant data). Guard 0 computes that set once; the loop revokes exactly it.
--      Kept: the cross-app catalog contract, SELECT on the catalog.v_* views owned by catalog_owner
--      (225 / 228, granted by catalog_owner; aa_cis_admin is deliberately not a member, so it could not
--      revoke them anyway). Dev, S240 probe: 13 views, v_destination, v_destination_photo, v_graph_edge,
--      v_graph_node, v_tour, v_tour_component, v_tour_day, v_tour_day_route, v_tour_junction,
--      v_tour_leg, v_tour_photo, v_tour_place, v_tour_stop.
--      Revoked on Dev (confirmed 16/10/2026 by the AA-859 P0 preflight, aclexplode on relacl/attacl with
--      owner and grantor: 33 relations, class (c) empty, every grantor = owner, 13 catalog_owner views
--      kept; root docs/audits/2026-10-16-S240-aa859/p0_preflight.json): SELECT on
--        acp_contract.v_active_tour_atoms; acp_shared.angle_gate_option (re-granted in 2),
--        tenant_atom_state, year_plan; INSERT/SELECT/UPDATE on acp_shared.marketplace_portfolios;
--        SELECT on shared.cost_explorer_snapshot, decision_cache_hits_daily, decision_log,
--        decision_question, destinations, dfs_balance_snapshot, dfs_call_log, jev_credit_topup,
--        jev_tenant_allowlist, job, job_worker, llm_call_log, llm_model_catalog, llm_role_config,
--        llm_shadow_log, place_photo, prompt_eval_runs, rerun_wave, spend_budget, tenant_brand_rules,
--        tenant_brand_rules_deleted_aa404, tenant_export_config, tenant_rewrite_usage,
--        tenant_seo_config, tenants, unmapped_market_requests, and the views v_destination_photos,
--        v_tour_photos. What was really revoked (relation and privileges, column ones as PRIV(col)) and
--        the PUBLIC SELECTs kept are written into this file's shared.schema_versions description: DB
--        Migrate (db/run_migration.py) registers no asyncpg log listener, so the apply's NOTICEs never
--        reach its log.
--   2. angle_gate_option: ENABLE ROW LEVEL SECURITY (no FORCE: the owner, i.e. the main pool and the
--      worker's T8 INSERT, stays exempt), POLICY tenant_isolation FOR ALL TO aa_app_user, USING and
--      WITH CHECK "the parent angle_gate_request belongs to app.tenant_id" (NULLIF: '' = no tenant).
--      The policy's subquery reads angle_gate_request as aa_app_user, through that table's own
--      tenant_isolation (229). GRANT SELECT and UPDATE (chosen) only: INSERT stays with the T8 worker.
--   3. shared.tenant_integrations: column INSERT (tenant_id, integration_type, config, secret_key,
--      connected_at) and column UPDATE (config, secret_key, updated_at, last_verified_at,
--      last_verify_error), the columns the WordPress / Facebook connect UPSERT and the test-connection
--      UPDATE write (api/routers/v1_integrations.py). id / created_at / updated_at on INSERT are
--      defaults. tenant_id and integration_type are not updatable, so a row cannot be moved to another
--      tenant or channel even inside the tenant's own rows.
--
-- Unchanged for every other reader. Only aa_app_user loses privileges; it has no members (guarded).
-- The main pool, the worker and DB Migrate (aa_cis_admin) own the tables. tripplanner / booking /
-- catalog_owner grants are not touched; the catalog views run as catalog_owner, unaffected.
--
-- Not destructive (no row is changed or removed), so no `migrate:` header directive.
--
-- Guards (lesson S236: check RLS by behaviour, not by role attributes):
--   0. before: aa_app_user is not superuser / BYPASSRLS, has no member but the runner and is a member of
--      no role (an inherited role's grants are out of the loop's reach: the scope and guard 4 look at
--      aa_app_user's own aclitems only);
--      angle_gate_option exists, the runner owns it (or bypasses RLS), it is not FORCEd, only the
--      owner and aa_app_user hold privileges on it, its policies are a subset of {tenant_isolation},
--      RLS is not active for the runner; every aa_app_user aclitem the loop will revoke was granted
--      by the relation's owner (a REVOKE run as the owner skips other grantors' aclitems silently);
--      every aa_app_user aclitem on a relation without RLS that the loop will NOT touch is the
--      catalog contract (schema catalog, owner catalog_owner, table-level SELECT); no PUBLIC
--      INSERT / UPDATE / DELETE / TRUNCATE on a relation without RLS in a schema aa_app_user may use
--      (PUBLIC SELECT: NOTICE only). Then lock angle_gate_option and count it under a foreign tenant;
--   1. after, as the runner: RLS not active, same count under a foreign tenant;
--   2. policy shape: exactly {tenant_isolation}, PERMISSIVE, FOR ALL, TO aa_app_user, USING and WITH
--      CHECK through angle_gate_request on the NULLIF'd GUC, WITH CHECK identical to USING (guard 3
--      tests USING by behaviour; it cannot reach WITH CHECK, since INSERT has no grant and its UPDATEs
--      touch 0 rows); RLS on, not FORCEd;
--   3. as aa_app_user (the runner is made a member for this transaction only when it may not SET ROLE
--      aa_app_user already, then the membership is revoked, as in 225/229/237): under a foreign and
--      an empty GUC it reads 0 options and a WHERE-less UPDATE SET chosen = chosen touches 0; under the
--      busiest tenant (through the parent, counted by the runner) it reads exactly that tenant's
--      options; INSERT is refused by the missing grant. On an empty table (CI) one request and one
--      option are seeded in a sub-transaction that is rolled back;
--   4. the invariant: no aa_app_user privilege on any relation without RLS except the catalog
--      contract (the query is NO_PRIVILEGE_WITHOUT_RLS_SQL in tests/integration/_rls_fixture_helpers.py
--      and the AA-859 probe v3, kept identical); aa_app_user holds on angle_gate_option exactly
--      SELECT + UPDATE (chosen), and on tenant_integrations exactly SELECT, DELETE (237) and the
--      column INSERT / UPDATE above (no TRUNCATE, which RLS does not filter).
--
-- Cross-owner grants are not guarded by IF EXISTS(role) (schema-ownership rule 5): aa_app_user must
-- exist (007b on Dev, conftest in CI). Idempotent: the scope is empty on a re-run (or holds only grants
-- re-added since), the policy is dropped by name and recreated, GRANTs of held privileges are no-ops.
--
-- Locks. ENABLE ROW LEVEL SECURITY and DROP/CREATE POLICY take ACCESS EXCLUSIVE on angle_gate_option
-- (33 rows on Dev; the angle-gate routes and the T8 worker use it). GRANT / REVOKE take no lock on the
-- relation (they rewrite its catalog row), so hot tables (shared.job, llm_call_log) are not blocked.
-- lock_timeout 10s gives up instead of queueing. Apply through AA-CIS-Infra DB Migrate (byte copy in
-- db/migrations/cis/), with shared.job idle (no queued or running job).
--
-- Before apply (hard precondition): AA-859 P0 #1 (docs/audits/2026-10-16-S240-aa859/p0_preflight.py)
-- has run on Dev and its JSON is saved in that folder, with class (c) empty, no class (a) item from a
-- grantor other than the owner, no PUBLIC write and aa_app_user a member of no role. Anything there
-- makes guard 0 raise (safe, but the apply is blocked); the JSON is also the before-picture of the ACLs.
--
-- After apply: rerun the AA-859 probe v3 (expected: angle_gate_option row 0 FAIL;
-- no_privilege_without_rls_violations == []; the catalog contract rows unchanged), smoke the five
-- flagged tenant-pool routes for tenant A (publish-log list, pending, latest-piece, get-piece,
-- disconnect: they LEFT JOIN angle_gate_option) and the TripPlanner browse, then let the schema-dump
-- PR regenerate docs/architecture/db-schema-reference.md.
--
-- Rollback (through DB Migrate, Nghiệp approves):
--   STEP 0, before the SQL: DEL every Redis flag that depends on 241, then confirm in Logs Insights q3
--   that they see no new traffic. Today: aa859:angle_gate_decide_pool (W3 choose / reopen) and
--   aa859:integration_connect_pool (W9 connect / test), plus any later flag marked "depends on 241" in
--   the AA-859 plan D7. Otherwise choose / connect / test fail with 42501 -> 500 the moment the grants
--   go.
--   BEGIN;
--   DROP POLICY IF EXISTS tenant_isolation ON acp_shared.angle_gate_option;
--   ALTER TABLE acp_shared.angle_gate_option DISABLE ROW LEVEL SECURITY;
--   REVOKE UPDATE (chosen) ON acp_shared.angle_gate_option FROM aa_app_user;   -- SELECT kept (pre-241)
--   REVOKE INSERT, UPDATE ON shared.tenant_integrations FROM aa_app_user;      -- also the column grants
--   GRANT SELECT, DELETE ON shared.tenant_integrations TO aa_app_user;         -- 237 state
--   DELETE FROM shared.schema_versions WHERE version = '241';
--   COMMIT;
--   The SELECTs the loop revoked are NOT restored: they were the leak. Restore one only if a route
--   proves to need it (one GRANT); the revoked set is in the 241 schema_versions description (read it
--   before the DELETE above) and in the P0 #1 JSON.

BEGIN;

SET LOCAL lock_timeout = '10s';

-- ── Guard 0: the state this file expects; the revoke scope; lock; count ───────────────────────────
DO $$
DECLARE
    app         constant oid := 'aa_app_user'::regrole;
    tbl         constant regclass := to_regclass('acp_shared.angle_gate_option');
    privileged  boolean;
    owner_ok    boolean;
    forced      boolean;
    pols        text[];
    bad         text;
    scope       oid[];
    revoked     text;
    foreign_guc constant text := '00000000-0000-0000-0000-00000000dead';
BEGIN
    -- 0a. the tenant role is filtered by RLS and no other session is it
    IF EXISTS (SELECT 1 FROM pg_roles WHERE oid = app AND (rolsuper OR rolbypassrls)) THEN
        RAISE EXCEPTION 'migration 241: aa_app_user is superuser or BYPASSRLS: RLS does not apply to it';
    END IF;
    SELECT string_agg(m.member::regrole::text, ', ') INTO bad
      FROM pg_auth_members m
     WHERE m.roleid = app
       AND m.member <> (SELECT oid FROM pg_roles WHERE rolname = current_user);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 241: % are members of aa_app_user: the angle_gate_option policy would '
                        'apply to their sessions too', bad;
    END IF;
    SELECT string_agg(m.roleid::regrole::text, ', ') INTO bad
      FROM pg_auth_members m
     WHERE m.member = app;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 241: aa_app_user is a member of %: privileges it inherits (or may SET ROLE '
                        'to) are out of this file''s revoke and invariant, which read its own aclitems', bad;
    END IF;

    -- 0b. angle_gate_option: the 229/237 preconditions for ENABLE without FORCE
    IF tbl IS NULL THEN
        RAISE EXCEPTION 'migration 241: acp_shared.angle_gate_option does not exist';
    END IF;
    SELECT rolsuper OR rolbypassrls INTO privileged FROM pg_roles WHERE rolname = current_user;
    SELECT pg_has_role(current_user, c.relowner, 'USAGE'), c.relforcerowsecurity
      INTO owner_ok, forced
      FROM pg_class c WHERE c.oid = tbl;
    IF NOT owner_ok AND NOT privileged THEN
        RAISE EXCEPTION 'migration 241: % neither owns acp_shared.angle_gate_option nor bypasses RLS: '
                        'ENABLE ROW LEVEL SECURITY would hide its rows from the main pool and the worker',
                        current_user;
    END IF;
    IF forced THEN
        RAISE EXCEPTION 'migration 241: acp_shared.angle_gate_option has FORCE ROW LEVEL SECURITY: with a '
                        'policy TO aa_app_user only, the owner (main pool, T8 worker) would read 0 rows';
    END IF;
    SELECT string_agg(DISTINCT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END, ', ')
      INTO bad
      FROM pg_class c, aclexplode(c.relacl) a
     WHERE c.oid = tbl AND a.grantee <> c.relowner AND a.grantee <> app;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 241: % hold privileges on acp_shared.angle_gate_option: with RLS on and a '
                        'policy TO aa_app_user only they would read 0 rows', bad;
    END IF;
    SELECT array_agg(policyname::text ORDER BY policyname) INTO pols
      FROM pg_policies WHERE schemaname = 'acp_shared' AND tablename = 'angle_gate_option';
    IF NOT coalesce(pols, '{}') <@ ARRAY['tenant_isolation'] THEN
        RAISE EXCEPTION 'migration 241: acp_shared.angle_gate_option has policies % (expected a subset of '
                        '{tenant_isolation}): an unknown permissive policy would OR into the tenant''s view', pols;
    END IF;
    IF row_security_active(tbl) THEN
        RAISE EXCEPTION 'migration 241: RLS is active for the runner % on acp_shared.angle_gate_option',
                        current_user;
    END IF;

    -- 0c. the revoke scope (item 5): computed once here, revoked exactly by the loop below
    SELECT coalesce(array_agg(c.oid ORDER BY c.oid::regclass::text), '{}') INTO scope
      FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
     WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
       AND NOT c.relrowsecurity
       AND ns.nspname NOT IN ('pg_catalog', 'information_schema', 'tripplanner', 'booking')
       AND ns.nspname NOT LIKE 'pg_toast%'
       AND pg_has_role(current_user, c.relowner, 'USAGE')                      -- the runner acts as the owner
       AND c.relowner NOT IN (SELECT oid FROM pg_roles
                               WHERE rolname IN ('catalog_owner', 'tripplanner', 'booking'))  -- CI: superuser
       AND (EXISTS (SELECT 1 FROM aclexplode(c.relacl) a WHERE a.grantee = app)
            OR EXISTS (SELECT 1 FROM pg_attribute att, aclexplode(att.attacl) a
                        WHERE att.attrelid = c.oid AND att.attacl IS NOT NULL AND a.grantee = app));

    -- every aclitem in scope was granted by the owner: REVOKE, run as the owner, removes only those
    SELECT string_agg(DISTINCT format('%s (%s granted by %s)', g.rel, g.priv, g.grantor), '; ') INTO bad
      FROM (SELECT c.oid::regclass::text AS rel, a.privilege_type AS priv,
                   a.grantor::regrole::text AS grantor, a.grantor <> c.relowner AS foreign_grantor
              FROM pg_class c, aclexplode(c.relacl) a
             WHERE c.oid = ANY (scope) AND a.grantee = app
            UNION ALL
            SELECT c.oid::regclass::text, a.privilege_type || '(' || att.attname || ')',
                   a.grantor::regrole::text, a.grantor <> c.relowner
              FROM pg_class c JOIN pg_attribute att ON att.attrelid = c.oid AND att.attacl IS NOT NULL,
                   aclexplode(att.attacl) a
             WHERE c.oid = ANY (scope) AND a.grantee = app) g
     WHERE g.foreign_grantor;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 241: aa_app_user privileges granted by a role other than the owner: %. '
                        'REVOKE ALL would leave them in place; look before applying', bad;
    END IF;

    -- out of the loop's reach: only the catalog contract may remain
    SELECT string_agg(DISTINCT format('%s %s%s (owner %s)', g.rel, g.priv,
                                      coalesce('(' || g.col || ')', ''), g.owner), '; ') INTO bad
      FROM (SELECT c.oid::regclass::text AS rel, ns.nspname AS nsp, c.relowner, c.relowner::regrole::text AS owner,
                   a.privilege_type AS priv, NULL::text AS col
              FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace, aclexplode(c.relacl) a
             WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f') AND NOT c.relrowsecurity
               AND ns.nspname NOT IN ('pg_catalog', 'information_schema') AND ns.nspname NOT LIKE 'pg_toast%'
               AND NOT c.oid = ANY (scope) AND a.grantee = app
            UNION ALL
            SELECT c.oid::regclass::text, ns.nspname, c.relowner, c.relowner::regrole::text,
                   a.privilege_type, att.attname::text
              FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
                   JOIN pg_attribute att ON att.attrelid = c.oid AND att.attacl IS NOT NULL,
                   aclexplode(att.attacl) a
             WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f') AND NOT c.relrowsecurity
               AND ns.nspname NOT IN ('pg_catalog', 'information_schema') AND ns.nspname NOT LIKE 'pg_toast%'
               AND NOT c.oid = ANY (scope) AND a.grantee = app) g
     WHERE NOT (g.nsp = 'catalog' AND g.relowner IS NOT DISTINCT FROM to_regrole('catalog_owner')
                AND g.col IS NULL AND g.priv = 'SELECT');
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 241: aa_app_user holds privileges this file cannot revoke on relations '
                        'without RLS, outside the catalog contract: %', bad;
    END IF;

    -- PUBLIC: a write grant on a relation without RLS reaches aa_app_user too
    SELECT string_agg(DISTINCT format('%s %s', g.rel, g.priv), '; ') INTO bad
      FROM (SELECT c.oid::regclass::text AS rel, a.privilege_type AS priv
              FROM pg_class c, aclexplode(c.relacl) a
             WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f') AND NOT c.relrowsecurity AND a.grantee = 0
               AND c.relnamespace NOT IN ('pg_catalog'::regnamespace, 'information_schema'::regnamespace)
               AND has_schema_privilege(app, c.relnamespace, 'USAGE')
            UNION ALL
            SELECT c.oid::regclass::text, a.privilege_type || '(' || att.attname || ')'
              FROM pg_class c JOIN pg_attribute att ON att.attrelid = c.oid AND att.attacl IS NOT NULL,
                   aclexplode(att.attacl) a
             WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f') AND NOT c.relrowsecurity AND a.grantee = 0
               AND c.relnamespace NOT IN ('pg_catalog'::regnamespace, 'information_schema'::regnamespace)
               AND has_schema_privilege(app, c.relnamespace, 'USAGE')) g
     WHERE g.priv NOT LIKE 'SELECT%';
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 241: PUBLIC holds write privileges on relations without RLS in schemas '
                        'aa_app_user may use: %', bad;
    END IF;
    SELECT string_agg(DISTINCT c.oid::regclass::text, ', ') INTO bad
      FROM pg_class c, aclexplode(c.relacl) a
     WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f') AND NOT c.relrowsecurity AND a.grantee = 0
       AND a.privilege_type = 'SELECT' AND has_schema_privilege(app, c.relnamespace, 'USAGE')
       AND c.relnamespace NOT IN ('pg_catalog'::regnamespace, 'information_schema'::regnamespace);
    IF bad IS NOT NULL THEN
        RAISE NOTICE 'migration 241: PUBLIC may SELECT (kept, listed by the AA-859 probe): %', bad;
    END IF;
    PERFORM set_config('aa241.public_select', coalesce(bad, ''), true);

    -- what the loop will revoke, per relation, for the schema_versions row (NOTICEs are not logged)
    SELECT string_agg(format('%s (%s)', g.rel, g.privs), '; ' ORDER BY g.rel) INTO revoked
      FROM (SELECT s.rel, string_agg(DISTINCT s.priv, ', ') AS privs
              FROM (SELECT c.oid::regclass::text AS rel, a.privilege_type AS priv
                      FROM pg_class c, aclexplode(c.relacl) a
                     WHERE c.oid = ANY (scope) AND a.grantee = app
                    UNION ALL
                    SELECT c.oid::regclass::text, a.privilege_type || '(' || att.attname || ')'
                      FROM pg_class c JOIN pg_attribute att ON att.attrelid = c.oid AND att.attacl IS NOT NULL,
                           aclexplode(att.attacl) a
                     WHERE c.oid = ANY (scope) AND a.grantee = app) s
             GROUP BY s.rel) g;
    PERFORM set_config('aa241.revoked', coalesce(revoked, ''), true);

    PERFORM set_config('aa241.scope', scope::text, true);

    -- Take the lock ENABLE / CREATE POLICY need anyway before counting, so no option can be added or
    -- removed between this count and guard 1 (the T8 worker inserts options).
    LOCK TABLE acp_shared.angle_gate_option IN ACCESS EXCLUSIVE MODE;
    PERFORM set_config('app.tenant_id', foreign_guc, true);
    PERFORM set_config('aa241.n_before', (SELECT count(*) FROM acp_shared.angle_gate_option)::text, true);
    PERFORM set_config('app.tenant_id', '', true);
END $$;

-- ── 1. item 5: no tenant-role privilege on a CIS relation without RLS (scope from guard 0) ────────
DO $$
DECLARE
    rel regclass;
    n   int := 0;
BEGIN
    FOREACH rel IN ARRAY current_setting('aa241.scope')::oid[]::regclass[] LOOP
        EXECUTE format('REVOKE ALL ON %s FROM aa_app_user', rel);
        RAISE NOTICE 'migration 241: revoked every privilege of aa_app_user on %', rel;
        n := n + 1;
    END LOOP;
    RAISE NOTICE 'migration 241: % relations revoked', n;
END $$;

-- ── 2. W3: angle_gate_option under RLS through its parent request (no tenant column) ──────────────
ALTER TABLE acp_shared.angle_gate_option ENABLE ROW LEVEL SECURITY;
-- deliberately NO "FORCE ROW LEVEL SECURITY": the owner (main pool, T8 worker) stays exempt

DROP POLICY IF EXISTS tenant_isolation ON acp_shared.angle_gate_option;
CREATE POLICY tenant_isolation ON acp_shared.angle_gate_option AS PERMISSIVE FOR ALL TO aa_app_user
    USING (EXISTS (SELECT 1 FROM acp_shared.angle_gate_request r
                    WHERE r.request_id = angle_gate_option.request_id
                      AND r.tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid))
    WITH CHECK (EXISTS (SELECT 1 FROM acp_shared.angle_gate_request r
                         WHERE r.request_id = angle_gate_option.request_id
                           AND r.tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid));
COMMENT ON POLICY tenant_isolation ON acp_shared.angle_gate_option IS
    'AA-859 (241): the tenant pool (aa_app_user) reads and updates only options of requests of '
    'app.tenant_id; '''' or unset = no rows. Owner exempt (no FORCE).';

GRANT SELECT ON acp_shared.angle_gate_option TO aa_app_user;
GRANT UPDATE (chosen) ON acp_shared.angle_gate_option TO aa_app_user;   -- INSERT stays with T8 (main)

-- ── 3. W9 connect / test: the columns the UPSERT and the verify UPDATE write (237: FOR ALL + CHECK) ─
GRANT INSERT (tenant_id, integration_type, config, secret_key, connected_at)
    ON shared.tenant_integrations TO aa_app_user;
GRANT UPDATE (config, secret_key, updated_at, last_verified_at, last_verify_error)
    ON shared.tenant_integrations TO aa_app_user;

-- ── Guards 1-4 ────────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    app         constant oid := 'aa_app_user'::regrole;
    tbl         constant regclass := 'acp_shared.angle_gate_option'::regclass;
    n_before    constant bigint := current_setting('aa241.n_before')::bigint;
    n           bigint;
    n_own       bigint;
    n_expected  bigint;
    own         uuid;
    own_req     uuid;
    seed_req    uuid;
    guc         text;
    bad         text;
    pols        text[];
    privs       text[];
    expected    text[];
    granted     boolean := false;
    seeded      boolean := false;
    foreign_guc constant text := '00000000-0000-0000-0000-00000000dead';
BEGIN
    -- 1. the runner is still exempt: RLS inactive, every option under a foreign tenant
    PERFORM set_config('app.tenant_id', foreign_guc, true);
    IF row_security_active(tbl) THEN
        RAISE EXCEPTION 'migration 241: RLS is active for the runner % on acp_shared.angle_gate_option',
                        current_user;
    END IF;
    SELECT count(*) INTO n FROM acp_shared.angle_gate_option;
    IF n <> n_before THEN
        RAISE EXCEPTION 'migration 241: the runner sees % of % rows of acp_shared.angle_gate_option under a '
                        'foreign tenant', n, n_before;
    END IF;
    PERFORM set_config('app.tenant_id', '', true);

    -- 2. policy shape: exactly the policy created above
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = tbl AND relrowsecurity AND NOT relforcerowsecurity) THEN
        RAISE EXCEPTION 'migration 241: acp_shared.angle_gate_option is not ENABLE (without FORCE) ROW LEVEL '
                        'SECURITY';
    END IF;
    SELECT array_agg(policyname::text ORDER BY policyname) INTO pols
      FROM pg_policies WHERE schemaname = 'acp_shared' AND tablename = 'angle_gate_option';
    IF pols IS DISTINCT FROM ARRAY['tenant_isolation'] THEN
        RAISE EXCEPTION 'migration 241: acp_shared.angle_gate_option has policies %, expected {tenant_isolation}',
                        pols;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policies
                    WHERE schemaname = 'acp_shared' AND tablename = 'angle_gate_option'
                      AND policyname = 'tenant_isolation' AND permissive = 'PERMISSIVE' AND cmd = 'ALL'
                      AND roles = ARRAY['aa_app_user']::name[]
                      AND qual ILIKE '%angle_gate_request r%r.request_id = angle_gate_option.request_id%'
                                     'r.tenant_id = (NULLIF(current_setting(''app.tenant_id''%'
                      AND with_check = qual) THEN                -- WITH CHECK: guard 3 cannot reach it
        RAISE EXCEPTION 'migration 241: policy tenant_isolation on acp_shared.angle_gate_option is not PERMISSIVE '
                        'FOR ALL TO aa_app_user with USING through angle_gate_request on the NULLIF''d '
                        'app.tenant_id and WITH CHECK identical to USING';
    END IF;

    -- 4. the invariant (NO_PRIVILEGE_WITHOUT_RLS_SQL, tests/integration/_rls_fixture_helpers.py)
    SELECT string_agg(format('%s %s%s', v.rel, v.privilege_type, coalesce('(' || v.column_name || ')', '')), '; ')
      INTO bad
      FROM (
SELECT c.oid::regclass::text AS rel, a.privilege_type, NULL::text AS column_name
  FROM pg_class c
  JOIN pg_namespace ns ON ns.oid = c.relnamespace
 CROSS JOIN LATERAL aclexplode(c.relacl) a
 WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
   AND NOT c.relrowsecurity
   AND ns.nspname NOT IN ('pg_catalog', 'information_schema')
   AND ns.nspname NOT LIKE 'pg_toast%'
   AND a.grantee = 'aa_app_user'::regrole
   AND NOT (ns.nspname = 'catalog'
            AND c.relowner IS NOT DISTINCT FROM to_regrole('catalog_owner')
            AND a.privilege_type = 'SELECT')
UNION ALL
SELECT c.oid::regclass::text, a.privilege_type, att.attname::text
  FROM pg_class c
  JOIN pg_namespace ns ON ns.oid = c.relnamespace
  JOIN pg_attribute att ON att.attrelid = c.oid AND att.attacl IS NOT NULL AND NOT att.attisdropped
 CROSS JOIN LATERAL aclexplode(att.attacl) a
 WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
   AND NOT c.relrowsecurity
   AND ns.nspname NOT IN ('pg_catalog', 'information_schema')
   AND ns.nspname NOT LIKE 'pg_toast%'
   AND a.grantee = 'aa_app_user'::regrole
ORDER BY 1, 3, 2
           ) v;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 241: aa_app_user still holds privileges on relations without RLS: %', bad;
    END IF;

    -- 4. exact tenant-role privileges on the two tables this file grants on (column ones as priv(col))
    SELECT array_agg(p) INTO privs FROM (
        SELECT a.privilege_type AS p FROM pg_class c, aclexplode(c.relacl) a
         WHERE c.oid = tbl AND a.grantee = app
        UNION ALL
        SELECT a.privilege_type || '(' || att.attname || ')'
          FROM pg_attribute att, aclexplode(att.attacl) a
         WHERE att.attrelid = tbl AND att.attacl IS NOT NULL AND NOT att.attisdropped AND a.grantee = app) s;
    expected := ARRAY['SELECT', 'UPDATE(chosen)'];
    IF NOT (coalesce(privs, '{}') <@ expected AND expected <@ coalesce(privs, '{}')) THEN
        RAISE EXCEPTION 'migration 241: aa_app_user holds % on acp_shared.angle_gate_option (expected %)',
                        privs, expected;
    END IF;
    SELECT array_agg(p) INTO privs FROM (
        SELECT a.privilege_type AS p FROM pg_class c, aclexplode(c.relacl) a
         WHERE c.oid = 'shared.tenant_integrations'::regclass AND a.grantee = app
        UNION ALL
        SELECT a.privilege_type || '(' || att.attname || ')'
          FROM pg_attribute att, aclexplode(att.attacl) a
         WHERE att.attrelid = 'shared.tenant_integrations'::regclass AND att.attacl IS NOT NULL
           AND NOT att.attisdropped AND a.grantee = app) s;
    expected := ARRAY['SELECT', 'DELETE',
                      'INSERT(tenant_id)', 'INSERT(integration_type)', 'INSERT(config)', 'INSERT(secret_key)',
                      'INSERT(connected_at)',
                      'UPDATE(config)', 'UPDATE(secret_key)', 'UPDATE(updated_at)', 'UPDATE(last_verified_at)',
                      'UPDATE(last_verify_error)'];
    IF NOT (coalesce(privs, '{}') <@ expected AND expected <@ coalesce(privs, '{}')) THEN
        RAISE EXCEPTION 'migration 241: aa_app_user holds % on shared.tenant_integrations (expected %; no '
                        'TRUNCATE, which RLS does not filter)', privs, expected;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = 'shared.tenant_integrations'::regclass AND relrowsecurity) THEN
        RAISE EXCEPTION 'migration 241: shared.tenant_integrations has no ROW LEVEL SECURITY (237)';
    END IF;

    -- 3. aa_app_user is isolated on angle_gate_option. The runner becomes a member for this
    --    transaction only when it may not SET ROLE aa_app_user already (RDS: aa_cis_admin has
    --    CREATEROLE), revoked below.
    BEGIN
        SET LOCAL ROLE aa_app_user;                         -- already allowed (CI superuser)?
        RESET ROLE;
    EXCEPTION WHEN insufficient_privilege THEN
        EXECUTE format('GRANT aa_app_user TO %I', current_user);
        granted := true;
    END;
    BEGIN                                                   -- sub-transaction: a seed is rolled back
        IF n_before = 0 THEN                                -- CI: seed one request and one option
            SELECT tenant_id INTO own FROM shared.tenants ORDER BY tenant_id LIMIT 1;
            IF own IS NOT NULL THEN
                INSERT INTO acp_shared.angle_gate_request (tenant_id, atom_id, status)
                VALUES (own, 'aa241-guard', 'pending_choice') RETURNING request_id INTO seed_req;
                INSERT INTO acp_shared.angle_gate_option (request_id, idx, name, why_it_works, formula_fit,
                                                          best_final_style)
                VALUES (seed_req, 0, 'aa241-guard', 'x', 'x', 'x');
                seeded := true;
            ELSE
                RAISE NOTICE 'migration 241: no tenant and no option: guard 3 checks nothing (guard 2 shape only)';
            END IF;
        END IF;
        -- the busiest tenant through the parent, counted as the (exempt) runner
        own := NULL;
        SELECT r.tenant_id, count(*) INTO own, n_own
          FROM acp_shared.angle_gate_option o JOIN acp_shared.angle_gate_request r ON r.request_id = o.request_id
         GROUP BY r.tenant_id ORDER BY count(*) DESC, r.tenant_id LIMIT 1;
        FOREACH guc IN ARRAY ARRAY[foreign_guc, '', own::text] LOOP
            CONTINUE WHEN guc IS NULL;                      -- empty table: no own tenant to check
            PERFORM set_config('app.tenant_id', guc, true);
            SET LOCAL ROLE aa_app_user;
            SELECT count(*) INTO n FROM acp_shared.angle_gate_option;       -- no WHERE on purpose
            RESET ROLE;
            n_expected := CASE WHEN guc = own::text THEN n_own ELSE 0 END;
            IF n <> n_expected THEN
                RAISE EXCEPTION 'migration 241: aa_app_user reads % rows of acp_shared.angle_gate_option with '
                                'app.tenant_id=''%'' (expected %)', n, guc, n_expected;
            END IF;
            CONTINUE WHEN guc = own::text;                  -- never write a real row, even in a guard
            SET LOCAL ROLE aa_app_user;
            UPDATE acp_shared.angle_gate_option SET chosen = chosen;        -- no WHERE on purpose
            GET DIAGNOSTICS n = ROW_COUNT;
            RESET ROLE;
            IF n <> 0 THEN                                  -- raising rolls the whole apply back
                RAISE EXCEPTION 'migration 241: aa_app_user updated % rows of acp_shared.angle_gate_option with '
                                'app.tenant_id=''%''', n, guc;
            END IF;
        END LOOP;
        -- INSERT is refused by the missing grant, not by the policy: under the own tenant, for an own
        -- request, WITH CHECK would pass
        IF own IS NOT NULL THEN
            SELECT o.request_id INTO own_req
              FROM acp_shared.angle_gate_option o JOIN acp_shared.angle_gate_request r ON r.request_id = o.request_id
             WHERE r.tenant_id = own LIMIT 1;
            PERFORM set_config('app.tenant_id', own::text, true);
            BEGIN
                SET LOCAL ROLE aa_app_user;
                INSERT INTO acp_shared.angle_gate_option (request_id, idx, name, why_it_works, formula_fit,
                                                          best_final_style)
                VALUES (own_req, 2, 'aa241-guard', 'x', 'x', 'x');
                RAISE EXCEPTION 'migration 241: aa_app_user inserted into acp_shared.angle_gate_option';
            EXCEPTION
                WHEN insufficient_privilege THEN
                    IF SQLERRM NOT LIKE 'permission denied%' THEN
                        RAISE EXCEPTION 'migration 241: INSERT into acp_shared.angle_gate_option as aa_app_user '
                                        'was refused by "%", not by the missing grant', SQLERRM;
                    END IF;
                WHEN unique_violation THEN
                    RAISE EXCEPTION 'migration 241: aa_app_user may INSERT into acp_shared.angle_gate_option';
            END;
        END IF;
        PERFORM set_config('app.tenant_id', '', true);
        IF seeded THEN
            RAISE EXCEPTION USING ERRCODE = 'AA241', MESSAGE = 'migration 241: roll the guard seed back';
        END IF;
    EXCEPTION WHEN SQLSTATE 'AA241' THEN
        NULL;                                               -- the seed is gone, the checks passed
    END;
    PERFORM set_config('app.tenant_id', '', true);

    IF granted THEN
        EXECUTE format('REVOKE aa_app_user FROM %I', current_user);
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('241', now(),
    'AA-859: aa_app_user loses every privilege on CIS relations without RLS (catalog_owner catalog.* '
    'SELECT contract kept); angle_gate_option RLS through the parent request (SELECT + UPDATE(chosen) '
    'to aa_app_user); tenant_integrations column INSERT/UPDATE to aa_app_user for connect/test. '
    'Revoked from aa_app_user: ' || coalesce(nullif(current_setting('aa241.revoked'), ''), 'nothing')
    || '. PUBLIC SELECT kept on relations without RLS: '
    || coalesce(nullif(current_setting('aa241.public_select'), ''), 'none') || '.')
ON CONFLICT (version) DO NOTHING;

COMMIT;
