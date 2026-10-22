-- Migration 262: AA-859 wave 3 — shared.tenant_brand_rules and shared.tenant_seo_config on the 229 RLS template,
-- plus the grants the tenant-pool brand identity routes need.
--
-- Why. GET / POST /admin/brand-identity with a tenant Bearer (the portal Brand page, BrandTab) move to the
-- aa_app_user tenant pool behind BRAND_IDENTITY_FLAG (aa859:brand_identity_pool, api/core/aa544_tenant_pool.py).
-- The GET reads the tenant's brand rows; the POST deactivates them, inserts the next version and upserts the
-- tenant's markets into tenant_seo_config. Both tables hold every tenant's rows and have no RLS today: 241 revoked
-- aa_app_user's SELECT on them (no privilege without RLS, AA-859 plan D1), so the tenant pool cannot read them at
-- all, and granting it back without RLS would hand every tenant's brand prompts to a query that forgets its WHERE.
--
-- What.
--   1. Both tables: ENABLE ROW LEVEL SECURITY (no FORCE: the owner cis_owner stays exempt, decision D2 of 229);
--      POLICY tenant_isolation AS PERMISSIVE FOR ALL TO aa_app_user, USING and WITH CHECK
--      tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid ('' = no tenant, 0 rows, no error).
--   2. Both tables: POLICY <table>_cis_app_all AS PERMISSIVE FOR ALL TO cis_app USING (true) WITH CHECK (true),
--      the X1 parity policy (CIS 244, CONTEXT.md "The CIS runtime role is cis_app"): the api main pool, the worker
--      (T2 / T8 / T9 read the brand rows; T2 / T7 read target_market) and ECS-exec scripts log in as cis_app,
--      which is not the owner, so without it they would read 0 rows the moment RLS is on, with no error.
--   3. Grants to aa_app_user (start from nothing, so a re-run gives the same exact set):
--        tenant_brand_rules: SELECT; INSERT on the 16 columns the POST writes (tenant_id, system_prompt,
--          style_guide, forbidden_words, version, is_active, updated_at, brand_name, brand_type, core_idea,
--          customer_segment, customer_mindset, voice_examples, good_examples, target_markets, default_cta);
--          UPDATE (is_active) — the POST's "deactivate the previous versions". No DELETE, no TRUNCATE.
--        tenant_seo_config: SELECT (the upsert's ON CONFLICT (tenant_id) needs SELECT on tenant_id); INSERT
--          (tenant_id, target_market); UPDATE (target_market, updated_at). seo_provider / custom_keywords /
--          overrides stay admin-only (PATCH /admin/settings/seo, main pool).
--      tenant_id is never updatable: a row cannot be handed to another tenant even inside the own rows, and the
--      WITH CHECK refuses an INSERT for another tenant.
--   4. Register 262.
--   No other table: publish (PUBLISH_FLAG) needs nothing new (publish_log / content_piece / angle_gate_* /
--   tenant_integrations already carry RLS and the grants it uses, 229 / 237 / 241).
--
-- Who else reads these tables, and why nothing changes for them. On Dev only cis_owner (owner) and cis_app hold
-- privileges on them (schema reference, 22/10/2026); cis_app gets the parity policy here. Views reading them run
-- as their owner: guard 1 refuses the apply if a view that depends on them is owned by a role that would now be
-- filtered. RLS does not apply to foreign-key actions (shared.tenants ON DELETE CASCADE, offboarding).
--
-- Guards (RAISE rolls the whole file back; nothing changes):
--   1. before: aa_app_user and cis_app exist; aa_app_user is not superuser / BYPASSRLS, has no members and is a
--      member of no role (a policy TO r reaches r's members); per table: it exists with a uuid NOT NULL tenant_id,
--      the runner owns it (or is superuser / BYPASSRLS), it is not FORCEd, its policies are a subset of the two
--      this file creates, no PUBLIC grant, no other grantee that could read it (a role that can log in or has
--      members, other than the owner, aa_app_user and cis_app), no dependent view owned by a role that RLS would
--      filter. Then lock both tables (ACCESS EXCLUSIVE, the lock ENABLE / CREATE POLICY take anyway) and count;
--   2. after, as the runner: RLS is not active for it and it still counts every row under a foreign GUC;
--   3. policy shape: exactly {tenant_isolation, <table>_cis_app_all}; tenant_isolation PERMISSIVE FOR ALL TO
--      aa_app_user with USING = WITH CHECK = the NULLIF form; the parity policy PERMISSIVE FOR ALL TO cis_app with
--      USING (true) WITH CHECK (true); RLS on, not FORCEd;
--   4. aa_app_user's privileges on the two tables are exactly the sets of What 3 (table and column level);
--   5. the AA-859 invariant (241 guard 4, NO_PRIVILEGE_WITHOUT_RLS_SQL in tests/integration/_rls_fixture_helpers.py,
--      the probe v3 verdict): no aa_app_user privilege on any relation without RLS, the catalog contract excepted;
--   6. by behaviour, when the file runs the DB Migrate way (current_user cis_owner, login a member of cis_app):
--      cis_app counts every row of both tables without a GUC and under a foreign one (parity). Elsewhere (the CI
--      replay as a superuser, where cis_app has no grants) a NOTICE says it was skipped.
--   aa_app_user's isolation by behaviour (foreign / empty GUC reads and writes 0 rows, own tenant only) cannot run
--   here: the role lint allows no SET ROLE aa_app_user in a cis/ file and cis_owner may not join it. It is proven by
--   tests/integration/test_aa817_rls_tenant_isolation.py (TENANT_TABLES) and test_aa859_migration_262.py in CI, and
--   on Dev by the nightly isolation probe (cell tenant.aa_app_user_isolation picks up every RLS table).
--
-- Read-only preflight (run before the apply, as cis_app through the S3-mediated ECS exec, or as any reader of
-- pg_catalog; expected: rls f/f, owner cis_owner, grantees cis_app only, no policy, no dependent view, 0 violations):
--   SELECT c.oid::regclass, c.relrowsecurity, c.relforcerowsecurity, pg_get_userbyid(c.relowner),
--          (SELECT string_agg(DISTINCT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END
--                             || ':' || a.privilege_type, ', ') FROM aclexplode(c.relacl) a) AS grants,
--          (SELECT count(*) FROM pg_policy p WHERE p.polrelid = c.oid) AS policies,
--          (SELECT string_agg(DISTINCT v.oid::regclass::text || '@' || pg_get_userbyid(v.relowner), ', ')
--             FROM pg_depend d JOIN pg_rewrite rw ON rw.oid = d.objid JOIN pg_class v ON v.oid = rw.ev_class
--            WHERE d.classid = 'pg_rewrite'::regclass AND d.refobjid = c.oid AND v.oid <> c.oid) AS views
--     FROM pg_class c WHERE c.oid IN ('shared.tenant_brand_rules'::regclass, 'shared.tenant_seo_config'::regclass);
--   plus the invariant query of guard 5 (0 rows) and SELECT tenant_id, count(*) per table (the rows that stay).
--   A ready-made script: root .tmp-session/aa859_262_preflight.py (S247).
--
-- Locks. ENABLE ROW LEVEL SECURITY and DROP / CREATE POLICY take ACCESS EXCLUSIVE on two small tables (Dev: ~1 and
-- a handful of rows) that the T-pipeline jobs and the brand / settings routes read. lock_timeout 10s gives up
-- instead of queueing them. Apply through AA-CIS-Infra DB Migrate (byte copy in db/migrations/cis/), with
-- shared.job idle (DM-11.4).
--
-- X1. One BEGIN … COMMIT block. DB Migrate runs cis/ files as cis_owner (login db_migrator); the only role switch is
-- guard 6's SET LOCAL ROLE cis_app and back to cis_owner (both on the cis/ allowlist), inside a block that runs
-- only when current_user is cis_owner. No RESET ROLE, no role DDL, no SECURITY DEFINER.
--
-- Order with the code. The brand identity routes need this file once their flag is ON (a missing key is ON, S241
-- D-12): apply 262 before the wave-3 deploy, or `SET aa859:brand_identity_pool false` before the deploy and flip
-- it after the apply. The code works with the flag OFF without 262.
--
-- After apply: let the DB Schema Dump PR regenerate docs/architecture/db-schema-reference.md (both tables: RLS on,
-- two policies, the grants above); rerun the isolation probe (tenant.aa_app_user_isolation,
-- rls.enable_only_has_cis_app_policy); smoke the admin Brand Identity page (staff path, main pool) and a worker T2
-- rewrite still picking up the tenant's brand rules (cis_app parity).
--
-- Rollback (through DB Migrate, Nghiệp approves). STEP 0: `SET aa859:brand_identity_pool false` (NOT DEL: a missing
-- key means ON) and list it in the api env var TENANT_POOL_FORCE_ADMIN_FLAGS so it survives a Redis restart;
-- confirm used_tenant_pool=False for aa859_brand_identity in Logs Insights. Then:
--   BEGIN;
--   DROP POLICY IF EXISTS tenant_isolation ON shared.tenant_brand_rules;
--   DROP POLICY IF EXISTS tenant_brand_rules_cis_app_all ON shared.tenant_brand_rules;
--   ALTER TABLE shared.tenant_brand_rules DISABLE ROW LEVEL SECURITY;
--   REVOKE ALL ON shared.tenant_brand_rules FROM aa_app_user;           -- also the column grants
--   DROP POLICY IF EXISTS tenant_isolation ON shared.tenant_seo_config;
--   DROP POLICY IF EXISTS tenant_seo_config_cis_app_all ON shared.tenant_seo_config;
--   ALTER TABLE shared.tenant_seo_config DISABLE ROW LEVEL SECURITY;
--   REVOKE ALL ON shared.tenant_seo_config FROM aa_app_user;
--   DELETE FROM shared.schema_versions WHERE version = '262';
--   COMMIT;
--   (REVOKE before or with DISABLE: a grant on a table without RLS breaks the 241 invariant.)

BEGIN;

SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '2min';

-- ── Guard 1: the state this file expects; lock; counts before ─────────────────────────────────────
DO $$
DECLARE
    tables      constant text[] := ARRAY['shared.tenant_brand_rules', 'shared.tenant_seo_config'];
    t           text;
    tbl         regclass;
    app         oid;
    privileged  boolean;
    owner_ok    boolean;
    forced      boolean;
    bad         text;
    n           bigint;
BEGIN
    IF to_regrole('aa_app_user') IS NULL OR to_regrole('cis_app') IS NULL THEN
        RAISE EXCEPTION 'migration 262: role aa_app_user or cis_app does not exist (007b / Infra rl-001; CI: conftest)';
    END IF;
    app := 'aa_app_user'::regrole;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE oid = app AND (rolsuper OR rolbypassrls)) THEN
        RAISE EXCEPTION 'migration 262: aa_app_user is superuser or BYPASSRLS: RLS does not apply to it';
    END IF;
    SELECT string_agg(m.member::regrole::text, ', ') INTO bad FROM pg_auth_members m WHERE m.roleid = app;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 262: % are members of aa_app_user: the tenant policies would apply to their '
                        'sessions too', bad;
    END IF;
    SELECT string_agg(m.roleid::regrole::text, ', ') INTO bad FROM pg_auth_members m WHERE m.member = app;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 262: aa_app_user is a member of %: privileges it inherits are out of this '
                        'file''s exact grant check', bad;
    END IF;
    SELECT rolsuper OR rolbypassrls INTO privileged FROM pg_roles WHERE rolname = current_user;

    FOREACH t IN ARRAY tables LOOP
        tbl := to_regclass(t);
        IF tbl IS NULL THEN
            RAISE EXCEPTION 'migration 262: % does not exist', t;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_attribute
                        WHERE attrelid = tbl AND attname = 'tenant_id' AND atttypid = 'uuid'::regtype
                          AND attnotnull AND NOT attisdropped) THEN
            RAISE EXCEPTION 'migration 262: %.tenant_id is not a uuid NOT NULL column (the policy casts the GUC to uuid)', t;
        END IF;
        SELECT pg_has_role(current_user, c.relowner, 'USAGE'), c.relforcerowsecurity
          INTO owner_ok, forced
          FROM pg_class c WHERE c.oid = tbl;
        IF NOT owner_ok AND NOT privileged THEN
            RAISE EXCEPTION 'migration 262: % neither owns % nor bypasses RLS: ENABLE ROW LEVEL SECURITY would hide '
                            'its rows from this runner', current_user, t;
        END IF;
        IF forced THEN
            RAISE EXCEPTION 'migration 262: % has FORCE ROW LEVEL SECURITY: the owner would be filtered too', t;
        END IF;
        SELECT string_agg(polname::text, ', ') INTO bad
          FROM pg_policy
         WHERE polrelid = tbl
           AND polname::text NOT IN ('tenant_isolation', split_part(t, '.', 2) || '_cis_app_all');
        IF bad IS NOT NULL THEN
            RAISE EXCEPTION 'migration 262: % has policies % this file does not manage: a permissive one would OR '
                            'into the tenant''s view; a human must look', t, bad;
        END IF;
        -- Every other role that can read the table would read 0 rows once RLS is on (no policy reaches it). A role
        -- that cannot log in and has no members cannot open a session (CI's legacy app_user from 005).
        SELECT string_agg(DISTINCT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END, ', ')
          INTO bad
          FROM pg_class c, aclexplode(c.relacl) a
         WHERE c.oid = tbl
           AND a.grantee <> c.relowner
           AND a.grantee NOT IN (app, 'cis_app'::regrole)
           AND (a.grantee = 0
                OR EXISTS (SELECT 1 FROM pg_roles r WHERE r.oid = a.grantee AND r.rolcanlogin)
                OR EXISTS (SELECT 1 FROM pg_auth_members m WHERE m.roleid = a.grantee));
        IF bad IS NOT NULL THEN
            RAISE EXCEPTION 'migration 262: % hold privileges on %: with RLS on and no policy for them they would '
                            'read 0 rows', bad, t;
        END IF;
        -- A view reads as its owner: one owned by a role RLS filters here would silently go empty.
        SELECT string_agg(DISTINCT v.oid::regclass::text || ' (owner ' || pg_get_userbyid(v.relowner) || ')', ', ')
          INTO bad
          FROM pg_depend d
          JOIN pg_rewrite rw ON rw.oid = d.objid
          JOIN pg_class v ON v.oid = rw.ev_class
          JOIN pg_class c ON c.oid = d.refobjid
         WHERE d.classid = 'pg_rewrite'::regclass AND d.refclassid = 'pg_class'::regclass
           AND d.refobjid = tbl AND v.oid <> tbl
           AND NOT pg_has_role(v.relowner, c.relowner, 'USAGE')
           AND NOT EXISTS (SELECT 1 FROM pg_roles r WHERE r.oid = v.relowner AND (r.rolsuper OR r.rolbypassrls));
        IF bad IS NOT NULL THEN
            RAISE EXCEPTION 'migration 262: views % read % as an owner RLS would filter (0 rows after this file)',
                            bad, t;
        END IF;
        EXECUTE format('LOCK TABLE %s IN ACCESS EXCLUSIVE MODE', tbl);
        -- literal set_config names only (the X1 role lint refuses a computed one)
        EXECUTE format('SELECT count(*) FROM %s', tbl) INTO n;
        IF t = 'shared.tenant_brand_rules' THEN
            PERFORM set_config('aa262.n_tenant_brand_rules', n::text, true);
        ELSE
            PERFORM set_config('aa262.n_tenant_seo_config', n::text, true);
        END IF;
    END LOOP;
END $$;

-- ── 1. RLS, the 229 template ─────────────────────────────────────────────────────────────────────
ALTER TABLE shared.tenant_brand_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE shared.tenant_seo_config ENABLE ROW LEVEL SECURITY;
-- deliberately NO "FORCE ROW LEVEL SECURITY" (229 decision D2: the owner stays exempt)

DROP POLICY IF EXISTS tenant_isolation ON shared.tenant_brand_rules;
CREATE POLICY tenant_isolation ON shared.tenant_brand_rules AS PERMISSIVE FOR ALL TO aa_app_user
    USING      (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
COMMENT ON POLICY tenant_isolation ON shared.tenant_brand_rules IS
    'AA-859 (262): the tenant pool (aa_app_user) reads and writes only rows of app.tenant_id; '''' or unset = no '
    'rows. Owner exempt (no FORCE).';

DROP POLICY IF EXISTS tenant_isolation ON shared.tenant_seo_config;
CREATE POLICY tenant_isolation ON shared.tenant_seo_config AS PERMISSIVE FOR ALL TO aa_app_user
    USING      (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
COMMENT ON POLICY tenant_isolation ON shared.tenant_seo_config IS
    'AA-859 (262): the tenant pool (aa_app_user) reads and writes only rows of app.tenant_id; '''' or unset = no '
    'rows. Owner exempt (no FORCE).';

-- ── 2. X1 parity for the CIS runtime (CIS 244) ───────────────────────────────────────────────────
DROP POLICY IF EXISTS tenant_brand_rules_cis_app_all ON shared.tenant_brand_rules;
CREATE POLICY tenant_brand_rules_cis_app_all ON shared.tenant_brand_rules AS PERMISSIVE FOR ALL TO cis_app
    USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS tenant_seo_config_cis_app_all ON shared.tenant_seo_config;
CREATE POLICY tenant_seo_config_cis_app_all ON shared.tenant_seo_config AS PERMISSIVE FOR ALL TO cis_app
    USING (true) WITH CHECK (true);

-- ── 3. Grants the tenant-pool brand identity routes need (exact set: start from nothing) ────────────
GRANT USAGE ON SCHEMA shared TO aa_app_user;
REVOKE ALL ON shared.tenant_brand_rules FROM aa_app_user;
GRANT SELECT ON shared.tenant_brand_rules TO aa_app_user;
GRANT INSERT (tenant_id, system_prompt, style_guide, forbidden_words, version, is_active, updated_at, brand_name,
              brand_type, core_idea, customer_segment, customer_mindset, voice_examples, good_examples,
              target_markets, default_cta)
    ON shared.tenant_brand_rules TO aa_app_user;
GRANT UPDATE (is_active) ON shared.tenant_brand_rules TO aa_app_user;
REVOKE ALL ON shared.tenant_seo_config FROM aa_app_user;
GRANT SELECT ON shared.tenant_seo_config TO aa_app_user;
GRANT INSERT (tenant_id, target_market), UPDATE (target_market, updated_at) ON shared.tenant_seo_config TO aa_app_user;

-- ── Guards 2-5 ────────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    tables      constant text[] := ARRAY['shared.tenant_brand_rules', 'shared.tenant_seo_config'];
    foreign_guc constant text := '00000000-0000-0000-0000-00000000dead';
    nullif_qual constant text := '(tenant_id = (NULLIF(current_setting(''app.tenant_id''::text, true), ''''::text))::uuid)';
    t           text;
    tbl         regclass;
    tname         text;
    n           bigint;
    n_before    bigint;
    pols        text[];
    got         text[];
    expected    text[];
    bad         text;
BEGIN
    FOREACH t IN ARRAY tables LOOP
        tbl := to_regclass(t);
        tname := split_part(t, '.', 2);
        n_before := current_setting('aa262.n_' || tname)::bigint;

        -- 2. the runner is still exempt
        PERFORM set_config('app.tenant_id', foreign_guc, true);
        IF row_security_active(tbl) THEN
            RAISE EXCEPTION 'migration 262: RLS is active for the runner % on %', current_user, t;
        END IF;
        EXECUTE format('SELECT count(*) FROM %s', tbl) INTO n;
        IF n <> n_before THEN
            RAISE EXCEPTION 'migration 262: the runner sees % of % rows of % under a foreign tenant', n, n_before, t;
        END IF;

        -- 3. policy shape
        IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = tbl AND relrowsecurity AND NOT relforcerowsecurity) THEN
            RAISE EXCEPTION 'migration 262: % must have RLS enabled and not forced', t;
        END IF;
        SELECT array_agg(polname::text ORDER BY polname::text COLLATE "C") INTO pols FROM pg_policy WHERE polrelid = tbl;
        SELECT array_agg(x ORDER BY x COLLATE "C") INTO expected FROM unnest(ARRAY[tname || '_cis_app_all', 'tenant_isolation']) x;
        IF pols IS DISTINCT FROM expected THEN
            RAISE EXCEPTION 'migration 262: % has policies % (expected {%_cis_app_all, tenant_isolation})', t, pols, tname;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_policy p
                        WHERE p.polrelid = tbl AND p.polname = 'tenant_isolation' AND p.polpermissive
                          AND p.polcmd = '*' AND p.polroles = ARRAY['aa_app_user'::regrole::oid]
                          AND pg_get_expr(p.polqual, p.polrelid) = nullif_qual
                          AND pg_get_expr(p.polwithcheck, p.polrelid) = nullif_qual) THEN
            RAISE EXCEPTION 'migration 262: policy tenant_isolation on % is not the 229 template (PERMISSIVE FOR ALL '
                            'TO aa_app_user, USING = WITH CHECK = %)', t, nullif_qual;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_policy p
                        WHERE p.polrelid = tbl AND p.polname = tname || '_cis_app_all' AND p.polpermissive
                          AND p.polcmd = '*' AND p.polroles = ARRAY['cis_app'::regrole::oid]
                          AND pg_get_expr(p.polqual, p.polrelid) = 'true'
                          AND pg_get_expr(p.polwithcheck, p.polrelid) = 'true') THEN
            RAISE EXCEPTION 'migration 262: policy %_cis_app_all on % is not the X1 parity policy (PERMISSIVE FOR ALL '
                            'TO cis_app USING (true) WITH CHECK (true))', tname, t;
        END IF;

        -- 4. aa_app_user's exact privileges ('PRIV' table level, 'PRIV(column)' column level)
        SELECT array_agg(p ORDER BY p) INTO got FROM (
            SELECT a.privilege_type AS p FROM pg_class c, aclexplode(c.relacl) a
             WHERE c.oid = tbl AND a.grantee = 'aa_app_user'::regrole
            UNION ALL
            SELECT a.privilege_type || '(' || att.attname || ')'
              FROM pg_attribute att, aclexplode(att.attacl) a
             WHERE att.attrelid = tbl AND att.attacl IS NOT NULL AND NOT att.attisdropped
               AND a.grantee = 'aa_app_user'::regrole) x;
        IF tname = 'tenant_brand_rules' THEN
            SELECT array_agg(p ORDER BY p) INTO expected FROM unnest(ARRAY[
                'SELECT', 'UPDATE(is_active)',
                'INSERT(tenant_id)', 'INSERT(system_prompt)', 'INSERT(style_guide)', 'INSERT(forbidden_words)',
                'INSERT(version)', 'INSERT(is_active)', 'INSERT(updated_at)', 'INSERT(brand_name)',
                'INSERT(brand_type)', 'INSERT(core_idea)', 'INSERT(customer_segment)', 'INSERT(customer_mindset)',
                'INSERT(voice_examples)', 'INSERT(good_examples)', 'INSERT(target_markets)', 'INSERT(default_cta)'])
                AS p;
        ELSE
            SELECT array_agg(p ORDER BY p) INTO expected FROM unnest(ARRAY[
                'SELECT', 'INSERT(tenant_id)', 'INSERT(target_market)', 'UPDATE(target_market)',
                'UPDATE(updated_at)']) AS p;
        END IF;
        IF got IS DISTINCT FROM expected THEN
            RAISE EXCEPTION 'migration 262: aa_app_user holds % on % (expected %)', got, t, expected;
        END IF;
    END LOOP;
    PERFORM set_config('app.tenant_id', '', true);

    -- 5. the AA-859 invariant (same text as 241 guard 4 / NO_PRIVILEGE_WITHOUT_RLS_SQL / probe v3)
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
        RAISE EXCEPTION 'migration 262: aa_app_user holds privileges on relations without RLS: % (AA-859 invariant, 241)',
                        bad;
    END IF;
END $$;

-- ── Guard 6: cis_app parity by behaviour (the DB Migrate way only) ──────────────────────────────────
DO $$
DECLARE
    tables      constant text[] := ARRAY['shared.tenant_brand_rules', 'shared.tenant_seo_config'];
    foreign_guc constant text := '00000000-0000-0000-0000-00000000dead';
    t           text;
    n_plain     bigint;
    n_forged    bigint;
    n_before    bigint;
BEGIN
    IF current_user <> 'cis_owner' OR NOT pg_has_role(session_user, 'cis_app', 'MEMBER')
       OR NOT has_table_privilege('cis_app', 'shared.tenant_brand_rules', 'SELECT')
       OR NOT has_table_privilege('cis_app', 'shared.tenant_seo_config', 'SELECT') THEN
        RAISE NOTICE 'migration 262: guard 6 (cis_app parity by behaviour) skipped: runs only as cis_owner under a '
                     'login that is a member of cis_app, with cis_app''s 244 grants (the DB Migrate way)';
        RETURN;
    END IF;
    FOREACH t IN ARRAY tables LOOP
        n_before := current_setting('aa262.n_' || split_part(t, '.', 2))::bigint;
        PERFORM set_config('app.tenant_id', '', true);
        SET LOCAL ROLE cis_app;
        EXECUTE format('SELECT count(*) FROM %s', t) INTO n_plain;
        PERFORM set_config('app.tenant_id', foreign_guc, true);
        EXECUTE format('SELECT count(*) FROM %s', t) INTO n_forged;
        SET LOCAL ROLE cis_owner;
        IF n_plain <> n_before OR n_forged <> n_before THEN
            RAISE EXCEPTION 'migration 262: cis_app reads % (no GUC) / % (foreign GUC) of % rows of %: the main pool '
                            'and the worker would lose brand rows', n_plain, n_forged, n_before, t;
        END IF;
    END LOOP;
    PERFORM set_config('app.tenant_id', '', true);
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('262', now(),
    'AA-859 wave 3: shared.tenant_brand_rules and shared.tenant_seo_config on the 229 RLS template (ENABLE without '
    'FORCE, tenant_isolation TO aa_app_user on the NULLIF GUC, WITH CHECK) plus the X1 parity policy TO cis_app; '
    'aa_app_user: brand rules SELECT + INSERT (16 columns) + UPDATE (is_active), seo config SELECT + INSERT '
    '(tenant_id, target_market) + UPDATE (target_market, updated_at), for the tenant-pool brand identity routes')
ON CONFLICT (version) DO NOTHING;

COMMIT;
