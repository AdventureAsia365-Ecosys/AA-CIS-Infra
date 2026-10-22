-- Migration 266: AA-859 wave 4 — acp_contract.tour_atoms under RLS for the tenant pool (platform atoms plus the tenant's
-- own, read only), with keep-alive policies for its other readers.
--
-- Why. The wave-4 tenant routes read atoms on the aa_app_user tenant pool: the T10 review list / detail (REVIEWS_FLAG),
-- the marketplace (MARKETPLACE_FLAG), the trip-reallocation suggest / confirm (TRIP_REALLOCATION_FLAG) and the Slate
-- pick (SUBJECT_DECIDE_FLAG, the Segment / Route members). tour_atoms has no RLS today, so 241 left the tenant role no
-- privilege on it (and revoked it on the owner-rights view acp_contract.v_active_tour_atoms). An atom belongs to the
-- platform (owner_scope 'platform', AA's shared, tenant-neutral derivation, ADR 0001 / 0003: every live atom on Dev
-- today) or to one tenant (owner_scope = that tenant's uuid, from its own T5 rewrite): a tenant may read the first kind
-- and its own, never another tenant's. Its own file (not 265): the table is worker-hot (A3 atomize, ranking, matching;
-- ~32k rows, the catalog views TripPlanner / Booking read) and the apply takes ACCESS EXCLUSIVE on it.
--
-- What.
--   1. ENABLE ROW LEVEL SECURITY (no FORCE: the owner cis_owner stays exempt, so the owner-rights views
--      acp_contract.v_active_tour_atoms and v_trip_registry read as before, and TripPlanner's 216 column grants on
--      the view keep working).
--   2. Policies, every one PERMISSIVE:
--        atoms_platform_read FOR SELECT TO aa_app_user USING (owner_scope = 'platform');
--        tenant_isolation    FOR SELECT TO aa_app_user USING (owner_scope = NULLIF(current_setting('app.tenant_id',
--                            true), ''))  (text, no cast; '' = no tenant = platform atoms only);
--        tour_atoms_cis_app_all FOR ALL TO cis_app USING (true) WITH CHECK (true)  (X1 parity: api main pool, worker,
--                            ECS exec read and write every atom, as before);
--        catalog_owner_read  FOR SELECT TO catalog_owner USING (true)  (the catalog.* views of 225 / 228 / 235 / 253 /
--                            256 run as catalog_owner and read every live atom, as before: what TripPlanner, Booking
--                            and aa_app_user see through catalog.v_tour_place / v_tour_component is unchanged; D9: no
--                            non-platform atom sits on a live master tour, guard 1).
--      FOR SELECT only for the tenant role: no tenant route writes atoms (PR-J, CONTEXT.md "/admin/atoms* is staff
--      only").
--   3. aa_app_user: SELECT on the table (REVOKE ALL first). No column grant, no write.
--   4. Register 266.
--
-- Keep-alive matrix (every reader of tour_atoms and how it reads after this file):
--   cis_owner       owner, exempt (no FORCE): v_active_tour_atoms, v_trip_registry, every cis/ migration.
--   cis_app         tour_atoms_cis_app_all: api main pool, worker, ECS exec.
--   catalog_owner   catalog_owner_read: catalog.v_tour_place / v_tour_component and the other catalog views.
--   tripplanner     no grant left after CIS 254 (AA-847), which guard 1 requires (its 180 column grant would read 0 rows
--                   with RLS on; TripPlanner no longer reads the table, its extraction checks read catalog.v_tour).
--   aa_app_user     atoms_platform_read + tenant_isolation: the wave-4 routes.
--
-- Guards (RAISE rolls the whole file back; nothing changes):
--   1. before: aa_app_user, cis_app and catalog_owner exist; aa_app_user is not superuser / BYPASSRLS, has no members
--      and is a member of no role; the runner owns the table (or is superuser / BYPASSRLS); it is not FORCEd; then it
--      is locked (ACCESS EXCLUSIVE, the lock ENABLE / CREATE POLICY take anyway: no write between the checks below and
--      the apply); its policies are a subset of the four this file manages; no PUBLIC grant; the grantees are a subset of {owner,
--      cis_app, catalog_owner, aa_app_user} (tripplanner holding any privilege: "apply CIS 254 first"; any other role
--      that can log in or has members would read 0 rows); every dependent view is owned by a role that owns the table
--      (or bypasses RLS) or by catalog_owner (which gets its policy here); every owner_scope is 'platform' or a
--      canonical lower-case uuid; D9: no live (not deleted, not an empty marker) non-platform atom on a live master
--      tour (P0 recorded 0; otherwise the catalog views already expose tenant atoms to every consumer: Q4, a root ADR,
--      not this file). Then count; the DB
--      Migrate way only (current_user cis_owner), also count as catalog_owner (tour_atoms, catalog.v_tour_place,
--      catalog.v_tour_component) and as cis_app;
--   2. after, as the runner: RLS is not active for it and it still counts every row under a foreign GUC;
--   3. policy shape: exactly the four policies, each PERMISSIVE with its command, its role and its expression; RLS on,
--      not FORCEd;
--   4. aa_app_user's privileges on the table are exactly {SELECT} (no column grant);
--   5. the AA-859 invariant, version 2 (as 265 guard 5, NO_PRIVILEGE_WITHOUT_RLS_SQL_V2);
--   6. by behaviour, the DB Migrate way only: catalog_owner counts the same rows of tour_atoms and of the two catalog
--      views as before the file, and cis_app every row without a GUC and under a foreign one. Elsewhere (the CI replay
--      as a superuser) a NOTICE says it was skipped.
--   aa_app_user's isolation by behaviour (platform + own, never another tenant's, '' = platform only, no write) is
--   proven in CI by tests/integration/test_aa817_rls_tenant_isolation.py and test_aa859_migration_266.py.
--
-- Read-only preflight (before the apply, as cis_app through the S3-mediated ECS exec; expected: rls f/f, owner
-- cis_owner, grantees {catalog_owner, cis_app} (no tripplanner: 254 applied), no policy, D9 = 0, owner_scope all
-- 'platform' or canonical, invariant V1 0 rows, job tables idle):
--   SELECT c.relrowsecurity, c.relforcerowsecurity, pg_get_userbyid(c.relowner),
--          (SELECT string_agg(DISTINCT a.grantee::regrole::text || ':' || a.privilege_type, ', ')
--             FROM aclexplode(c.relacl) a) AS grants,
--          (SELECT string_agg(DISTINCT a.grantee::regrole::text, ', ') FROM pg_attribute att,
--                  aclexplode(att.attacl) a WHERE att.attrelid = c.oid) AS column_grantees,
--          (SELECT count(*) FROM pg_policy p WHERE p.polrelid = c.oid) AS policies
--     FROM pg_class c WHERE c.oid = 'acp_contract.tour_atoms'::regclass;
--   SELECT count(*) FROM acp_contract.tour_atoms ta JOIN gold_aa_internal.published_tours pt ON pt.tour_id = ta.tour_id
--    WHERE ta.owner_scope <> 'platform' AND NOT ta.deleted AND NOT ta.is_empty_marker
--      AND pt.master_status = 'active' AND pt.deleted_at IS NULL;                                     -- D9: 0
--   Before and after (lesson S238): EXPLAIN (ANALYZE) TripPlanner's catalog.v_tour_place / v_tour_component read with
--   `= ANY($1)` as catalog_owner's consumer, and one worker query that reads tour_atoms directly as cis_app.
--   A ready-made script: root .tmp-session/aa859_w4_preflight.py (S247), `pre-266` / `post-266`.
--
-- Locks. ACCESS EXCLUSIVE on tour_atoms for the length of the file (guards included, a few seconds): A3 atomize /
-- ranking / matching and TripPlanner / Booking reads of the catalog views queue behind it. lock_timeout 10s gives up
-- instead of queueing them for longer. Apply through AA-CIS-Infra DB Migrate (byte copy in db/migrations/cis/) with
-- shared.job and booking.job idle and no wave open (DM-11.4), after 254 and 265.
--
-- X1. One BEGIN … COMMIT block. DB Migrate runs cis/ files as cis_owner (login db_migrator, a member of catalog_owner
-- since S22 and of cis_app); the only role switches are guards 1 / 6's SET LOCAL ROLE catalog_owner / cis_app and back
-- to cis_owner (all on the cis/ allowlist), inside blocks that run only when current_user is cis_owner. Literal
-- set_config names only. No RESET ROLE, no role DDL, no SECURITY DEFINER.
--
-- Order with the code. MARKETPLACE_FLAG, REVIEWS_FLAG, TRIP_REALLOCATION_FLAG and SUBJECT_DECIDE_FLAG need this file:
-- keep them `false` on Dev until it is applied (a missing key is ON, S241 D-12).
--
-- After apply: let the DB Schema Dump PR regenerate docs/architecture/db-schema-reference.md (RLS on, four policies,
-- aa_app_user SELECT); rerun the isolation probe; TripPlanner browse smoke (catalog views), one A3 job on the worker.
--
-- Rollback (through DB Migrate, Nghiệp approves). STEP 0: `SET` aa859:reviews_pool, aa859:subject_decide_pool,
-- aa859:trip_reallocation_pool and aa859:marketplace_pool `false` (NOT DEL) and list them in
-- TENANT_POOL_FORCE_ADMIN_FLAGS; confirm used_tenant_pool=False. Then:
--   BEGIN;
--   REVOKE ALL ON acp_contract.tour_atoms FROM aa_app_user;
--   DROP POLICY IF EXISTS atoms_platform_read ON acp_contract.tour_atoms;
--   DROP POLICY IF EXISTS tenant_isolation ON acp_contract.tour_atoms;
--   DROP POLICY IF EXISTS tour_atoms_cis_app_all ON acp_contract.tour_atoms;
--   DROP POLICY IF EXISTS catalog_owner_read ON acp_contract.tour_atoms;
--   ALTER TABLE acp_contract.tour_atoms DISABLE ROW LEVEL SECURITY;
--   DELETE FROM shared.schema_versions WHERE version = '266';
--   COMMIT;
--   (REVOKE before or with DISABLE: a grant on a table without RLS breaks the 241 invariant.)

BEGIN;

SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '2min';

-- ── Guard 1: the state this file expects; lock; counts before ─────────────────────────────────────
DO $$
DECLARE
    tbl         constant regclass := to_regclass('acp_contract.tour_atoms');
    app         oid;
    privileged  boolean;
    owner_ok    boolean;
    forced      boolean;
    bad         text;
    n           bigint;
BEGIN
    IF to_regrole('aa_app_user') IS NULL OR to_regrole('cis_app') IS NULL OR to_regrole('catalog_owner') IS NULL THEN
        RAISE EXCEPTION 'migration 266: role aa_app_user, cis_app or catalog_owner does not exist (007b / Infra rl-001 / '
                        'CIS 225; CI: conftest)';
    END IF;
    IF tbl IS NULL THEN
        RAISE EXCEPTION 'migration 266: acp_contract.tour_atoms does not exist';
    END IF;
    app := 'aa_app_user'::regrole;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE oid = app AND (rolsuper OR rolbypassrls)) THEN
        RAISE EXCEPTION 'migration 266: aa_app_user is superuser or BYPASSRLS: RLS does not apply to it';
    END IF;
    SELECT string_agg(m.member::regrole::text, ', ') INTO bad FROM pg_auth_members m WHERE m.roleid = app;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 266: % are members of aa_app_user: the tenant policies would apply to their '
                        'sessions too', bad;
    END IF;
    SELECT string_agg(m.roleid::regrole::text, ', ') INTO bad FROM pg_auth_members m WHERE m.member = app;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 266: aa_app_user is a member of %: privileges it inherits are out of this '
                        'file''s exact grant check', bad;
    END IF;
    SELECT rolsuper OR rolbypassrls INTO privileged FROM pg_roles WHERE rolname = current_user;
    SELECT pg_has_role(current_user, c.relowner, 'USAGE'), c.relforcerowsecurity INTO owner_ok, forced
      FROM pg_class c WHERE c.oid = tbl;
    IF NOT owner_ok AND NOT privileged THEN
        RAISE EXCEPTION 'migration 266: % neither owns acp_contract.tour_atoms nor bypasses RLS: ENABLE ROW LEVEL '
                        'SECURITY would hide its rows from this runner', current_user;
    END IF;
    IF forced THEN
        RAISE EXCEPTION 'migration 266: acp_contract.tour_atoms has FORCE ROW LEVEL SECURITY: the owner (and its '
                        'views) would be filtered too';
    END IF;
    -- Lock before the checks below (the lock ENABLE / CREATE POLICY take anyway): no atom written between the
    -- owner_scope / D9 checks and the apply (review S247).
    LOCK TABLE acp_contract.tour_atoms IN ACCESS EXCLUSIVE MODE;
    SELECT string_agg(polname::text, ', ') INTO bad
      FROM pg_policy
     WHERE polrelid = tbl
       AND polname::text NOT IN ('atoms_platform_read', 'tenant_isolation', 'tour_atoms_cis_app_all',
                                 'catalog_owner_read');
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 266: acp_contract.tour_atoms has policies % this file does not manage: a permissive '
                        'one would OR into the tenant''s view; a human must look', bad;
    END IF;
    -- TripPlanner's 180 column grants (revoked by CIS 254, AA-847): with RLS on and no policy for it, a read would
    -- return 0 rows. 254 first; no keep-alive policy for a reader that no longer reads.
    IF to_regrole('tripplanner') IS NOT NULL
       AND (has_table_privilege('tripplanner', tbl, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
            OR has_any_column_privilege('tripplanner', tbl, 'SELECT, INSERT, UPDATE, REFERENCES')) THEN
        RAISE EXCEPTION 'migration 266: tripplanner still holds privileges on acp_contract.tour_atoms: apply CIS 254 '
                        '(AA-847) first';
    END IF;
    -- Every other role that can read the table (table or column grant) would read 0 rows once RLS is on.
    SELECT string_agg(DISTINCT CASE WHEN g.grantee = 0 THEN 'PUBLIC' ELSE g.grantee::regrole::text END, ', ')
      INTO bad
      FROM (SELECT a.grantee FROM pg_class c, aclexplode(c.relacl) a WHERE c.oid = tbl
            UNION
            SELECT a.grantee FROM pg_attribute att, aclexplode(att.attacl) a
             WHERE att.attrelid = tbl AND att.attacl IS NOT NULL AND NOT att.attisdropped) g
     WHERE g.grantee <> (SELECT relowner FROM pg_class WHERE oid = tbl)
       AND g.grantee NOT IN (app, 'cis_app'::regrole, 'catalog_owner'::regrole)
       AND (g.grantee = 0
            OR EXISTS (SELECT 1 FROM pg_roles r WHERE r.oid = g.grantee AND r.rolcanlogin)
            OR EXISTS (SELECT 1 FROM pg_auth_members m WHERE m.roleid = g.grantee));
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 266: % hold privileges on acp_contract.tour_atoms: with RLS on and no policy for them '
                        'they would read 0 rows', bad;
    END IF;
    -- A view reads as its owner: only the table owner (exempt) and catalog_owner (policy below) may own one.
    SELECT string_agg(DISTINCT v.oid::regclass::text || ' (owner ' || pg_get_userbyid(v.relowner) || ')', ', ')
      INTO bad
      FROM pg_depend d
      JOIN pg_rewrite rw ON rw.oid = d.objid
      JOIN pg_class v ON v.oid = rw.ev_class
      JOIN pg_class c ON c.oid = d.refobjid
     WHERE d.classid = 'pg_rewrite'::regclass AND d.refclassid = 'pg_class'::regclass
       AND d.refobjid = tbl AND v.oid <> tbl
       AND NOT pg_has_role(v.relowner, c.relowner, 'USAGE')
       AND v.relowner <> 'catalog_owner'::regrole
       AND NOT EXISTS (SELECT 1 FROM pg_roles r WHERE r.oid = v.relowner AND (r.rolsuper OR r.rolbypassrls));
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 266: views % read acp_contract.tour_atoms as an owner RLS would filter (0 rows after '
                        'this file)', bad;
    END IF;
    -- owner_scope compares as text: anything but 'platform' or a canonical lower-case uuid matches no tenant.
    SELECT string_agg(DISTINCT owner_scope, ', ') INTO bad
      FROM (SELECT owner_scope FROM acp_contract.tour_atoms
             WHERE owner_scope <> 'platform'
               AND owner_scope !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' LIMIT 20) x;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 266: acp_contract.tour_atoms holds owner_scope values % (neither ''platform'' nor a '
                        'canonical uuid): fix them first', bad;
    END IF;
    -- D9 (AA-859 plan): the catalog views read every live atom of a live master tour; a tenant-owned one there would
    -- already reach every catalog consumer. 0 is the accepted state; anything else is Q4 (a root ADR), not this file.
    SELECT count(*) INTO n
      FROM acp_contract.tour_atoms ta
     WHERE ta.owner_scope <> 'platform' AND NOT ta.deleted AND NOT ta.is_empty_marker
       AND EXISTS (SELECT 1 FROM gold_aa_internal.published_tours pt
                    WHERE pt.tour_id = ta.tour_id AND pt.master_status = 'active' AND pt.deleted_at IS NULL);
    IF n > 0 THEN
        RAISE EXCEPTION 'migration 266: D9: % live tenant-owned atoms sit on live master tours (the catalog views expose '
                        'them); AA-859 Q4 decides, not this file', n;
    END IF;

    SELECT count(*) INTO n FROM acp_contract.tour_atoms;
    PERFORM set_config('aa266.n_tour_atoms', n::text, true);

    -- the DB Migrate way: what catalog_owner reads before the file (guard 6 compares)
    IF current_user = 'cis_owner' AND pg_has_role(session_user, 'catalog_owner', 'MEMBER') THEN
        PERFORM set_config('app.tenant_id', '', true);
        SET LOCAL ROLE catalog_owner;
        SELECT count(*) INTO n FROM acp_contract.tour_atoms;
        PERFORM set_config('aa266.n_catalog_atoms', n::text, true);
        IF to_regclass('catalog.v_tour_place') IS NOT NULL THEN
            SELECT count(*) INTO n FROM catalog.v_tour_place;
            PERFORM set_config('aa266.n_catalog_place', n::text, true);
        END IF;
        IF to_regclass('catalog.v_tour_component') IS NOT NULL THEN
            SELECT count(*) INTO n FROM catalog.v_tour_component;
            PERFORM set_config('aa266.n_catalog_component', n::text, true);
        END IF;
        SET LOCAL ROLE cis_owner;
    END IF;
END $$;

-- ── 1. RLS (no FORCE: the owner and its views stay exempt) ───────────────────────────────────────
ALTER TABLE acp_contract.tour_atoms ENABLE ROW LEVEL SECURITY;

-- ── 2. Policies ───────────────────────────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS atoms_platform_read ON acp_contract.tour_atoms;
CREATE POLICY atoms_platform_read ON acp_contract.tour_atoms AS PERMISSIVE FOR SELECT TO aa_app_user
    USING (owner_scope = 'platform');
COMMENT ON POLICY atoms_platform_read ON acp_contract.tour_atoms IS
    'AA-859 (266): the tenant pool (aa_app_user) reads every platform atom (AA''s shared, tenant-neutral derivation).';

DROP POLICY IF EXISTS tenant_isolation ON acp_contract.tour_atoms;
CREATE POLICY tenant_isolation ON acp_contract.tour_atoms AS PERMISSIVE FOR SELECT TO aa_app_user
    USING (owner_scope = NULLIF(current_setting('app.tenant_id', true), ''));
COMMENT ON POLICY tenant_isolation ON acp_contract.tour_atoms IS
    'AA-859 (266): the tenant pool (aa_app_user) also reads atoms owned by app.tenant_id (text compare, no cast); '
    ''''' or unset = platform atoms only. No tenant write.';

DROP POLICY IF EXISTS tour_atoms_cis_app_all ON acp_contract.tour_atoms;
CREATE POLICY tour_atoms_cis_app_all ON acp_contract.tour_atoms AS PERMISSIVE FOR ALL TO cis_app
    USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS catalog_owner_read ON acp_contract.tour_atoms;
CREATE POLICY catalog_owner_read ON acp_contract.tour_atoms AS PERMISSIVE FOR SELECT TO catalog_owner
    USING (true);
COMMENT ON POLICY catalog_owner_read ON acp_contract.tour_atoms IS
    'AA-859 (266): the catalog.* views (225 / 228 / 235 / 253 / 256) run as catalog_owner and read every atom as '
    'before; D9 = 0 (no live tenant atom on a live master tour) is guarded at apply.';

-- ── 3. aa_app_user: SELECT only ───────────────────────────────────────────────────────────────────
GRANT USAGE ON SCHEMA acp_contract TO aa_app_user;
REVOKE ALL ON acp_contract.tour_atoms FROM aa_app_user;
GRANT SELECT ON acp_contract.tour_atoms TO aa_app_user;

-- ── Guards 2-5 ────────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    tbl         constant regclass := 'acp_contract.tour_atoms'::regclass;
    foreign_guc constant text := '00000000-0000-0000-0000-00000000dead';
    own_qual    constant text := '(owner_scope = NULLIF(current_setting(''app.tenant_id''::text, true), ''''::text))';
    n           bigint;
    n_before    bigint := current_setting('aa266.n_tour_atoms')::bigint;
    pols        text[];
    got         text[];
    bad         text;
BEGIN
    -- 2. the runner is still exempt
    PERFORM set_config('app.tenant_id', foreign_guc, true);
    IF row_security_active(tbl) THEN
        RAISE EXCEPTION 'migration 266: RLS is active for the runner % on acp_contract.tour_atoms', current_user;
    END IF;
    SELECT count(*) INTO n FROM acp_contract.tour_atoms;
    IF n <> n_before THEN
        RAISE EXCEPTION 'migration 266: the runner sees % of % atoms under a foreign tenant', n, n_before;
    END IF;
    PERFORM set_config('app.tenant_id', '', true);

    -- 3. policy shape
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = tbl AND relrowsecurity AND NOT relforcerowsecurity) THEN
        RAISE EXCEPTION 'migration 266: acp_contract.tour_atoms must have RLS enabled and not forced';
    END IF;
    SELECT array_agg(polname::text ORDER BY polname::text COLLATE "C") INTO pols FROM pg_policy WHERE polrelid = tbl;
    IF pols IS DISTINCT FROM ARRAY['atoms_platform_read', 'catalog_owner_read', 'tenant_isolation',
                                   'tour_atoms_cis_app_all'] THEN
        RAISE EXCEPTION 'migration 266: acp_contract.tour_atoms has policies % (expected {atoms_platform_read, '
                        'catalog_owner_read, tenant_isolation, tour_atoms_cis_app_all})', pols;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policy p
                    WHERE p.polrelid = tbl AND p.polname = 'atoms_platform_read' AND p.polpermissive
                      AND p.polcmd = 'r' AND p.polroles = ARRAY['aa_app_user'::regrole::oid]
                      AND pg_get_expr(p.polqual, p.polrelid) = '(owner_scope = ''platform''::text)'
                      AND p.polwithcheck IS NULL)
       OR NOT EXISTS (SELECT 1 FROM pg_policy p
                       WHERE p.polrelid = tbl AND p.polname = 'tenant_isolation' AND p.polpermissive
                         AND p.polcmd = 'r' AND p.polroles = ARRAY['aa_app_user'::regrole::oid]
                         AND pg_get_expr(p.polqual, p.polrelid) = own_qual AND p.polwithcheck IS NULL)
       OR NOT EXISTS (SELECT 1 FROM pg_policy p
                       WHERE p.polrelid = tbl AND p.polname = 'tour_atoms_cis_app_all' AND p.polpermissive
                         AND p.polcmd = '*' AND p.polroles = ARRAY['cis_app'::regrole::oid]
                         AND pg_get_expr(p.polqual, p.polrelid) = 'true'
                         AND pg_get_expr(p.polwithcheck, p.polrelid) = 'true')
       OR NOT EXISTS (SELECT 1 FROM pg_policy p
                       WHERE p.polrelid = tbl AND p.polname = 'catalog_owner_read' AND p.polpermissive
                         AND p.polcmd = 'r' AND p.polroles = ARRAY['catalog_owner'::regrole::oid]
                         AND pg_get_expr(p.polqual, p.polrelid) = 'true' AND p.polwithcheck IS NULL) THEN
        RAISE EXCEPTION 'migration 266: the policies on acp_contract.tour_atoms are not the shapes this file creates '
                        '(aa_app_user: FOR SELECT platform / own owner_scope; cis_app: FOR ALL true; catalog_owner: FOR '
                        'SELECT true)';
    END IF;

    -- 4. aa_app_user's exact privileges
    SELECT array_agg(p ORDER BY p) INTO got FROM (
        SELECT a.privilege_type AS p FROM pg_class c, aclexplode(c.relacl) a
         WHERE c.oid = tbl AND a.grantee = 'aa_app_user'::regrole
        UNION ALL
        SELECT a.privilege_type || '(' || att.attname || ')'
          FROM pg_attribute att, aclexplode(att.attacl) a
         WHERE att.attrelid = tbl AND att.attacl IS NOT NULL AND NOT att.attisdropped
           AND a.grantee = 'aa_app_user'::regrole) x;
    IF got IS DISTINCT FROM ARRAY['SELECT'] THEN
        RAISE EXCEPTION 'migration 266: aa_app_user holds % on acp_contract.tour_atoms (expected {SELECT})', got;
    END IF;

    -- 5. the AA-859 invariant, version 2 (same text as 265 guard 5 / NO_PRIVILEGE_WITHOUT_RLS_SQL_V2)
    SELECT string_agg(rel || ' ' || privilege_type || COALESCE('(' || column_name || ')', ''), ', ') INTO bad FROM (
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
   AND NOT (ns.nspname || '.' || c.relname = ANY (ARRAY['acp_contract.route', 'acp_contract.atom_segment',
                                                        'acp_contract.atom_segment_member',
                                                        'acp_contract.atom_segment_alias',
                                                        'acp_shared.place_card_alias', 'acp_shared.atom_place_card'])
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
   AND NOT (ns.nspname || '.' || c.relname = 'acp_shared.place_card'
            AND att.attname IN ('card_id', 'status')
            AND a.privilege_type = 'SELECT')
ORDER BY 1, 3, 2
    ) v;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 266: aa_app_user holds privileges on relations without RLS: % (AA-859 invariant, '
                        '241; v2 with the platform read allowlist)', bad;
    END IF;
END $$;

-- ── Guard 6: catalog_owner and cis_app read as before, by behaviour (the DB Migrate way only) ───────
DO $$
DECLARE
    foreign_guc constant text := '00000000-0000-0000-0000-00000000dead';
    n_before    bigint := current_setting('aa266.n_tour_atoms')::bigint;
    n_plain     bigint;
    n_forged    bigint;
    n_cat       bigint;
    n_place     bigint;
    n_component bigint;
BEGIN
    IF current_user <> 'cis_owner' OR NOT pg_has_role(session_user, 'cis_app', 'MEMBER')
       OR NOT pg_has_role(session_user, 'catalog_owner', 'MEMBER')
       OR NOT has_table_privilege('cis_app', 'acp_contract.tour_atoms', 'SELECT') THEN
        RAISE NOTICE 'migration 266: guard 6 (catalog_owner / cis_app read as before, by behaviour) skipped: runs only '
                     'as cis_owner under a login that is a member of cis_app and catalog_owner (the DB Migrate way)';
        RETURN;
    END IF;
    PERFORM set_config('app.tenant_id', '', true);
    SET LOCAL ROLE catalog_owner;
    SELECT count(*) INTO n_cat FROM acp_contract.tour_atoms;
    IF to_regclass('catalog.v_tour_place') IS NOT NULL THEN
        SELECT count(*) INTO n_place FROM catalog.v_tour_place;
    END IF;
    IF to_regclass('catalog.v_tour_component') IS NOT NULL THEN
        SELECT count(*) INTO n_component FROM catalog.v_tour_component;
    END IF;
    SET LOCAL ROLE cis_app;
    SELECT count(*) INTO n_plain FROM acp_contract.tour_atoms;
    PERFORM set_config('app.tenant_id', foreign_guc, true);
    SELECT count(*) INTO n_forged FROM acp_contract.tour_atoms;
    SET LOCAL ROLE cis_owner;
    PERFORM set_config('app.tenant_id', '', true);
    IF n_cat <> current_setting('aa266.n_catalog_atoms')::bigint
       OR n_place IS DISTINCT FROM NULLIF(current_setting('aa266.n_catalog_place', true), '')::bigint
       OR n_component IS DISTINCT FROM NULLIF(current_setting('aa266.n_catalog_component', true), '')::bigint THEN
        RAISE EXCEPTION 'migration 266: catalog_owner reads % atoms / % v_tour_place / % v_tour_component rows after the '
                        'file, % / % / % before: the catalog views would change for TripPlanner and Booking',
                        n_cat, n_place, n_component, current_setting('aa266.n_catalog_atoms'),
                        current_setting('aa266.n_catalog_place', true),
                        current_setting('aa266.n_catalog_component', true);
    END IF;
    IF n_plain <> n_before OR n_forged <> n_before THEN
        RAISE EXCEPTION 'migration 266: cis_app reads % (no GUC) / % (foreign GUC) of % atoms: the main pool and the '
                        'worker would lose atoms', n_plain, n_forged, n_before;
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('266', now(),
    'AA-859 wave 4: acp_contract.tour_atoms on RLS (ENABLE without FORCE): aa_app_user reads platform atoms and its own '
    '(FOR SELECT, owner_scope text compare on the NULLIF GUC), cis_app parity (FOR ALL true), catalog_owner_read (FOR '
    'SELECT true, the catalog views unchanged; D9 = 0 guarded); aa_app_user: SELECT. Needs CIS 254 (no tripplanner '
    'grant left)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
