-- Migration 265: AA-859 wave 4 — the Slate / planning tables and tenant_tour_pages under RLS for the tenant pool, the
-- platform read allowlist (7 relations without a tenant column), and USAGE on acp_contract for aa_app_user.
--
-- Why. Wave 4 moves the tenant routes that read and write these tables to the aa_app_user tenant pool, each group
-- behind its own fail-closed flag (api/core/aa544_tenant_pool.py): GET /v1/angle-gate/requests/{id} and the choose /
-- reopen re-read (ANGLE_GATE_READ_FLAG), GET /v1/slate (SLATE_READS_FLAG), POST /v1/subjects/{id}/pick and /cut
-- (SUBJECT_DECIDE_FLAG), the trip-reallocation suggest / confirm (TRIP_REALLOCATION_FLAG) and the T10 review list /
-- detail (REVIEWS_FLAG). The five tables below hold every tenant's rows and have no RLS today, so 241 left the tenant
-- role no privilege on them (no privilege without RLS, AA-859 plan D1): the tenant pool cannot read them at all, and
-- granting it back without RLS would hand every tenant's Slate and plans to a query that forgets its WHERE. The
-- Subject header, the Slate rows and the pick read seven platform relations with no tenant column at all (Routes,
-- Segments, place cards); they become the PLATFORM_READ_ALLOWLIST (tests/integration/_rls_fixture_helpers.py).
--
-- What.
--   0. CI only: acp_deliver.tenant_tour_pages with the 078 DDL when it is missing (078 fails in the CI replay). A no-op
--      on Dev, where 078 created it (and its owner cis_owner owns the schema).
--   1. ENABLE ROW LEVEL SECURITY (never FORCE: the owner cis_owner stays exempt, decision D2 of 229) on
--      acp_shared.subject, quarter_plan, quarter_plan_version, year_plan and acp_deliver.tenant_tour_pages.
--   2. POLICY tenant_isolation AS PERMISSIVE FOR ALL TO aa_app_user, USING = WITH CHECK:
--        subject / quarter_plan / year_plan: the 229 template, tenant_id = NULLIF(current_setting('app.tenant_id',
--          true), '')::uuid ('' = no tenant, 0 rows, no error);
--        quarter_plan_version (no tenant column): through its parent quarter_plan (the angle_gate_option pattern of
--          241); the subquery reads quarter_plan as aa_app_user, through that table's own policy;
--        tenant_tour_pages (tenant_id is text): tenant_id = NULLIF(current_setting('app.tenant_id', true), ''), a
--          text compare without a cast; plus aa_app_user_aa_master_read FOR SELECT TO aa_app_user USING (tenant_id =
--          the AA master tenant), the 239 shape: a tenant's trip shows the master's public trip page.
--   3. POLICY <table>_cis_app_all AS PERMISSIVE FOR ALL TO cis_app USING (true) WITH CHECK (true) on all five, the X1
--      parity policy (CIS 244): the api main pool, the worker (t7_slate proposes Subjects, the admin Slate / plan
--      pages, the public trip page and publish write tenant_tour_pages) and ECS-exec scripts log in as cis_app, which
--      is not the owner: without it they read 0 rows the moment RLS is on, with no error.
--   4. Grants to aa_app_user, the exact set the moved statements need (REVOKE ALL first, so a re-run gives the same):
--        subject:              SELECT; UPDATE (state)    (pick / cut; SELECT ... FOR UPDATE needs an UPDATE column)
--        year_plan:            SELECT; INSERT (tenant_id, year)
--        quarter_plan:         SELECT; INSERT (tenant_id, year, quarter, year_plan_id); UPDATE (year_plan_id,
--                              current_version_id)     (the ON CONFLICT upsert and the approve's pointer move)
--        quarter_plan_version: SELECT; INSERT (plan_id, version_no, payload, source, approval_status);
--                              UPDATE (approval_status, approved_by, approved_at)
--        tenant_tour_pages:    SELECT                    (the trip page of the tenant trip query; writes stay on MAIN)
--      plan_id / version_id / year_plan_id / subject_id / created_at are column defaults (092, 112, 133). tenant_id
--      is never updatable; no DELETE, no TRUNCATE (which RLS does not filter).
--   5. GRANT USAGE ON SCHEMA acp_contract TO aa_app_user, and SELECT (nothing else) on the platform read allowlist:
--      table level on acp_contract.route, atom_segment, atom_segment_member, atom_segment_alias,
--      acp_shared.place_card_alias, atom_place_card; column level on acp_shared.place_card (card_id, status: the
--      columns of the one tenant-pool statement, subject_seed._ALIAS_SQL; verified_by (a staff user id), cost_usd,
--      naming_note and facts stay unreadable). None has a tenant column or an owner_scope (guard 1): every row is
--      AA's shared, tenant-neutral derivation (ADR 0001 / 0003, CONTEXT.md cross-tenant table). hub, atom_ranking
--      and route_pick are not granted (the route hub is retired in the same wave). The acp_contract views
--      (v_active_tour_atoms, v_trip_registry: owner rights, RLS bypassed) stay revoked (guard 5).
--   6. Register 265.
--   Not here: acp_contract.tour_atoms is 266 (its own file: worker-hot, ACCESS EXCLUSIVE on ~32k rows read by every
--   A3 job and the catalog views). acp_shared.tenant_config and shared.tenants stay MAIN-only (D2: the routes read the
--   tenant's own config on the main pool first); tenant_atom_state / marketplace_portfolios stay revoked and dead.
--
-- Who else reads these tables, and why nothing changes for them. On Dev only cis_owner (owner) and cis_app hold
-- privileges on them (schema reference, 22/10/2026); cis_app gets the parity policy here. acp_contract.v_trip_registry
-- reads tenant_tour_pages as its owner cis_owner (exempt). RLS does not apply to foreign-key actions or checks
-- (quarter_plan_version -> quarter_plan, subject -> shared.tenants / atom_segment / route).
--
-- Guards (RAISE rolls the whole file back; nothing changes):
--   1. before: aa_app_user and cis_app exist; aa_app_user is not superuser / BYPASSRLS, has no members and is a member
--      of no role; per table: it exists with the expected key column (tenant_id uuid NOT NULL; tenant_tour_pages:
--      tenant_id text NOT NULL; quarter_plan_version: plan_id uuid NOT NULL), the runner owns it (or is superuser /
--      BYPASSRLS), it is not FORCEd; then it is locked (ACCESS EXCLUSIVE, the lock ENABLE / CREATE POLICY take
--      anyway, so no write slips in between the checks below and the apply); its policies are a subset of the ones
--      this file manages, no PUBLIC grant, no other grantee (table or column level) that could read it (a role that
--      can log in or has members, other than the owner, aa_app_user and cis_app), no dependent view owned by a role
--      RLS would filter; every tenant_tour_pages.tenant_id is a canonical lower-case uuid text (a text-compare policy
--      silently matches nothing otherwise); the 7 platform relations exist, have no RLS and neither a tenant_id nor
--      an owner_scope column. Then count;
--   2. after, as the runner: RLS is not active for it and it still counts every row under a foreign GUC;
--   3. policy shape: exactly the managed set per table, each PERMISSIVE, its command, its role and its expression;
--      RLS on, not FORCEd;
--   4. aa_app_user's exact privileges on the 5 tables (table and column level), exactly SELECT on the 6 table-level
--      platform relations and SELECT (card_id), SELECT (status) on place_card, USAGE on acp_contract;
--   5. the AA-859 invariant, version 2 (NO_PRIVILEGE_WITHOUT_RLS_SQL_V2 in tests/integration/_rls_fixture_helpers.py):
--      no aa_app_user privilege on any relation without RLS, the catalog contract and the platform read allowlist
--      excepted; none on any view of acp_contract; acp_contract is newly reachable by aa_app_user, so no PUBLIC grant
--      (table or column level, any privilege) on a relation of acp_contract without RLS (241's PUBLIC check covered
--      only the schemas the tenant role could already use, and V2 looks only at grants to aa_app_user), and no
--      SECURITY DEFINER function in acp_contract that aa_app_user can execute (EXECUTE is PUBLIC by default);
--   6. by behaviour, when the file runs the DB Migrate way (current_user cis_owner, login a member of cis_app):
--      cis_app counts every row of the 5 tables without a GUC and under a foreign one (parity). Elsewhere (the CI
--      replay as a superuser) a NOTICE says it was skipped.
--   aa_app_user's isolation by behaviour cannot run here (the role lint allows no SET ROLE aa_app_user in a cis/ file):
--   it is proven by tests/integration/test_aa817_rls_tenant_isolation.py, test_aa859_migration_265.py and
--   test_aa859_wave4_pool_routes.py in CI, and on Dev by the nightly isolation probe (tenant tables; the probe does
--   not cover quarter_plan_version, a child table, nor text master rows: an Infra follow-up).
--
-- Read-only preflight (before the apply, as cis_app through the S3-mediated ECS exec; expected: rls f/f, owner
-- cis_owner, grantees cis_app only, no policy, tenant_tour_pages ids canonical, invariant V1 0 rows, job tables idle):
--   SELECT c.oid::regclass, c.relrowsecurity, c.relforcerowsecurity, pg_get_userbyid(c.relowner),
--          (SELECT string_agg(DISTINCT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END
--                             || ':' || a.privilege_type, ', ') FROM aclexplode(c.relacl) a) AS grants,
--          (SELECT count(*) FROM pg_policy p WHERE p.polrelid = c.oid) AS policies
--     FROM pg_class c WHERE c.oid IN ('acp_shared.subject'::regclass, 'acp_shared.quarter_plan'::regclass,
--          'acp_shared.quarter_plan_version'::regclass, 'acp_shared.year_plan'::regclass,
--          'acp_deliver.tenant_tour_pages'::regclass);
--   SELECT count(*) FROM acp_deliver.tenant_tour_pages
--    WHERE tenant_id !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';      -- 0
--   A ready-made script: root .tmp-session/aa859_w4_preflight.py (S247), `pre-265` / `post-265`.
--
-- Locks. ENABLE ROW LEVEL SECURITY and DROP / CREATE POLICY take ACCESS EXCLUSIVE on five small tables (Dev: ~417
-- subjects, ~6 plans, 0 versions, 0 pages) that the t7_slate job, the Slate / plan routes and the public trip page
-- (/v1/trip/{id}, an UPDATE on tenant_tour_pages that may wait up to lock_timeout) touch. lock_timeout 10s gives up
-- instead of queueing them. Apply through AA-CIS-Infra DB Migrate (byte copy in db/migrations/cis/) with shared.job
-- and booking.job idle (DM-11.4).
--
-- X1. One BEGIN … COMMIT block. DB Migrate runs cis/ files as cis_owner (login db_migrator); the only role switch is
-- guard 6's SET LOCAL ROLE cis_app and back to cis_owner (both on the cis/ allowlist), inside a block that runs only
-- when current_user is cis_owner. Literal set_config names only. No RESET ROLE, no role DDL, no SECURITY DEFINER.
--
-- Order with the code. The wave-4 flags are ON from the first deploy (a missing key is ON, S241 D-12): `SET` all six
-- aa859:*_pool wave-4 keys `false` on Dev before the wave-4 deploy, apply 265 (and 266), then flip them one by one.
-- The code works with every flag OFF without 265.
--
-- After apply: let the DB Schema Dump PR regenerate docs/architecture/db-schema-reference.md (five tables: RLS on,
-- their policies, the grants above; the 7 relations: aa_app_user SELECT); rerun the isolation probe
-- (tenant.aa_app_user_isolation, rls.enable_only_has_cis_app_policy); smoke the admin Slate / Tenant 360 pages
-- (main pool) and a t7_slate proposal (worker, cis_app parity).
--
-- Rollback (through DB Migrate, Nghiệp approves). STEP 0: `SET aa859:slate_reads_pool false`, and the same for
-- aa859:angle_gate_read_pool, aa859:subject_decide_pool, aa859:trip_reallocation_pool, aa859:reviews_pool (NOT DEL: a
-- missing key means ON); list them in the api env var TENANT_POOL_FORCE_ADMIN_FLAGS so it survives a Redis restart;
-- confirm used_tenant_pool=False in Logs Insights. The angle-gate choose / reopen re-read follows
-- aa859:angle_gate_read_pool (on the decide's own connection while aa859:angle_gate_decide_pool is on too): taking
-- choose / reopen fully off the tenant pool needs BOTH keys set false. Then, per table t of the five:
--   BEGIN;
--   REVOKE ALL ON <t> FROM aa_app_user;                                 -- also the column grants
--   DROP POLICY IF EXISTS tenant_isolation ON <t>;
--   DROP POLICY IF EXISTS aa_app_user_aa_master_read ON acp_deliver.tenant_tour_pages;
--   DROP POLICY IF EXISTS <table>_cis_app_all ON <t>;
--   ALTER TABLE <t> DISABLE ROW LEVEL SECURITY;
--   REVOKE ALL ON acp_contract.route, acp_contract.atom_segment, acp_contract.atom_segment_member,
--                 acp_contract.atom_segment_alias, acp_shared.place_card, acp_shared.place_card_alias,
--                 acp_shared.atom_place_card FROM aa_app_user;
--   REVOKE USAGE ON SCHEMA acp_contract FROM aa_app_user;               -- only after 266 is rolled back too
--   DELETE FROM shared.schema_versions WHERE version = '265';
--   COMMIT;
--   (REVOKE before or with DISABLE: a grant on a table without RLS breaks the 241 invariant.)

BEGIN;

SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '2min';

-- ── 0. CI only: the 078 table (a no-op where it exists) ──────────────────────────────────────────
CREATE TABLE IF NOT EXISTS acp_deliver.tenant_tour_pages (
    tenant_id        TEXT NOT NULL,
    tour_id          UUID NOT NULL,
    url              TEXT NOT NULL,
    published_at     TIMESTAMPTZ,
    url_alive        BOOLEAN DEFAULT true,
    last_checked_at  TIMESTAMPTZ,
    PRIMARY KEY (tenant_id, tour_id)
);

-- ── Guard 1: the state this file expects; lock; counts before ─────────────────────────────────────
DO $$
DECLARE
    tables      constant text[] := ARRAY['acp_shared.subject', 'acp_shared.quarter_plan',
                                         'acp_shared.quarter_plan_version', 'acp_shared.year_plan',
                                         'acp_deliver.tenant_tour_pages'];
    platform    constant text[] := ARRAY['acp_contract.route', 'acp_contract.atom_segment',
                                         'acp_contract.atom_segment_member', 'acp_contract.atom_segment_alias',
                                         'acp_shared.place_card', 'acp_shared.place_card_alias',
                                         'acp_shared.atom_place_card'];
    t           text;
    tname       text;
    tbl         regclass;
    app         oid;
    privileged  boolean;
    owner_ok    boolean;
    forced      boolean;
    rls         boolean;
    key_col     text;
    key_type    regtype;
    managed     text[];
    bad         text;
    n           bigint;
BEGIN
    IF to_regrole('aa_app_user') IS NULL OR to_regrole('cis_app') IS NULL THEN
        RAISE EXCEPTION 'migration 265: role aa_app_user or cis_app does not exist (007b / Infra rl-001; CI: conftest)';
    END IF;
    app := 'aa_app_user'::regrole;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE oid = app AND (rolsuper OR rolbypassrls)) THEN
        RAISE EXCEPTION 'migration 265: aa_app_user is superuser or BYPASSRLS: RLS does not apply to it';
    END IF;
    SELECT string_agg(m.member::regrole::text, ', ') INTO bad FROM pg_auth_members m WHERE m.roleid = app;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 265: % are members of aa_app_user: the tenant policies would apply to their '
                        'sessions too', bad;
    END IF;
    SELECT string_agg(m.roleid::regrole::text, ', ') INTO bad FROM pg_auth_members m WHERE m.member = app;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 265: aa_app_user is a member of %: privileges it inherits are out of this '
                        'file''s exact grant check', bad;
    END IF;
    SELECT rolsuper OR rolbypassrls INTO privileged FROM pg_roles WHERE rolname = current_user;

    FOREACH t IN ARRAY tables LOOP
        tbl := to_regclass(t);
        IF tbl IS NULL THEN
            RAISE EXCEPTION 'migration 265: % does not exist', t;
        END IF;
        tname := split_part(t, '.', 2);
        key_col := CASE WHEN tname = 'quarter_plan_version' THEN 'plan_id' ELSE 'tenant_id' END;
        key_type := CASE WHEN tname = 'tenant_tour_pages' THEN 'text'::regtype ELSE 'uuid'::regtype END;
        IF NOT EXISTS (SELECT 1 FROM pg_attribute
                        WHERE attrelid = tbl AND attname = key_col AND atttypid = key_type
                          AND attnotnull AND NOT attisdropped) THEN
            RAISE EXCEPTION 'migration 265: %.% is not a % NOT NULL column (the policy compares it)', t, key_col,
                            key_type;
        END IF;
        SELECT pg_has_role(current_user, c.relowner, 'USAGE'), c.relforcerowsecurity
          INTO owner_ok, forced
          FROM pg_class c WHERE c.oid = tbl;
        IF NOT owner_ok AND NOT privileged THEN
            RAISE EXCEPTION 'migration 265: % neither owns % nor bypasses RLS: ENABLE ROW LEVEL SECURITY would hide '
                            'its rows from this runner', current_user, t;
        END IF;
        IF forced THEN
            RAISE EXCEPTION 'migration 265: % has FORCE ROW LEVEL SECURITY: the owner would be filtered too', t;
        END IF;
        -- Lock before the checks below (the lock ENABLE / CREATE POLICY take anyway): no write between a check
        -- and the apply (review S247).
        EXECUTE format('LOCK TABLE %s IN ACCESS EXCLUSIVE MODE', tbl);
        managed := ARRAY['tenant_isolation', tname || '_cis_app_all'];
        IF tname = 'tenant_tour_pages' THEN
            managed := managed || 'aa_app_user_aa_master_read'::text;
        END IF;
        SELECT string_agg(polname::text, ', ') INTO bad
          FROM pg_policy
         WHERE polrelid = tbl AND NOT (polname::text = ANY (managed));
        IF bad IS NOT NULL THEN
            RAISE EXCEPTION 'migration 265: % has policies % this file does not manage: a permissive one would OR '
                            'into the tenant''s view; a human must look', t, bad;
        END IF;
        -- Every other role that can read the table (table or column grant) would read 0 rows once RLS is on (no
        -- policy reaches it). A role that cannot log in and has no members cannot open a session (CI's legacy
        -- app_user from 005).
        SELECT string_agg(DISTINCT CASE WHEN g.grantee = 0 THEN 'PUBLIC' ELSE g.grantee::regrole::text END, ', ')
          INTO bad
          FROM (SELECT a.grantee FROM pg_class c, aclexplode(c.relacl) a WHERE c.oid = tbl
                UNION
                SELECT a.grantee FROM pg_attribute att, aclexplode(att.attacl) a
                 WHERE att.attrelid = tbl AND att.attacl IS NOT NULL AND NOT att.attisdropped) g
         WHERE g.grantee <> (SELECT relowner FROM pg_class WHERE oid = tbl)
           AND g.grantee NOT IN (app, 'cis_app'::regrole)
           AND (g.grantee = 0
                OR EXISTS (SELECT 1 FROM pg_roles r WHERE r.oid = g.grantee AND r.rolcanlogin)
                OR EXISTS (SELECT 1 FROM pg_auth_members m WHERE m.roleid = g.grantee));
        IF bad IS NOT NULL THEN
            RAISE EXCEPTION 'migration 265: % hold privileges on %: with RLS on and no policy for them they would '
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
            RAISE EXCEPTION 'migration 265: views % read % as an owner RLS would filter (0 rows after this file)',
                            bad, t;
        END IF;
    END LOOP;

    -- tenant_tour_pages compares text: an id that is not the canonical lower-case uuid would match no tenant.
    SELECT string_agg(DISTINCT tenant_id, ', ') INTO bad
      FROM (SELECT tenant_id FROM acp_deliver.tenant_tour_pages
             WHERE tenant_id !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' LIMIT 20) x;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 265: acp_deliver.tenant_tour_pages holds non-canonical tenant ids (%): the text '
                        'policy would hide those rows from every tenant; fix them first', bad;
    END IF;

    -- the platform read allowlist: no tenant data, by construction
    FOREACH t IN ARRAY platform LOOP
        tbl := to_regclass(t);
        IF tbl IS NULL THEN
            RAISE EXCEPTION 'migration 265: platform relation % does not exist', t;
        END IF;
        SELECT c.relrowsecurity INTO rls FROM pg_class c WHERE c.oid = tbl;
        IF rls THEN
            RAISE EXCEPTION 'migration 265: platform relation % has ROW LEVEL SECURITY: it is not a platform read any '
                            'more, take it out of the allowlist', t;
        END IF;
        IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = tbl AND attname IN ('tenant_id', 'owner_scope')
                                                AND NOT attisdropped) THEN
            RAISE EXCEPTION 'migration 265: platform relation % has a tenant_id / owner_scope column: a table-level '
                            'SELECT would hand every tenant''s rows to the tenant pool', t;
        END IF;
    END LOOP;

    FOREACH t IN ARRAY tables LOOP
        tbl := to_regclass(t);
        -- (locked in the first loop) literal set_config names only (the X1 role lint refuses a computed one)
        EXECUTE format('SELECT count(*) FROM %s', tbl) INTO n;
        IF t = 'acp_shared.subject' THEN
            PERFORM set_config('aa265.n_subject', n::text, true);
        ELSIF t = 'acp_shared.quarter_plan' THEN
            PERFORM set_config('aa265.n_quarter_plan', n::text, true);
        ELSIF t = 'acp_shared.quarter_plan_version' THEN
            PERFORM set_config('aa265.n_quarter_plan_version', n::text, true);
        ELSIF t = 'acp_shared.year_plan' THEN
            PERFORM set_config('aa265.n_year_plan', n::text, true);
        ELSE
            PERFORM set_config('aa265.n_tenant_tour_pages', n::text, true);
        END IF;
    END LOOP;
END $$;

-- ── 1. RLS (never FORCE: 229 decision D2, the owner stays exempt) ────────────────────────────────
ALTER TABLE acp_shared.subject ENABLE ROW LEVEL SECURITY;
ALTER TABLE acp_shared.quarter_plan ENABLE ROW LEVEL SECURITY;
ALTER TABLE acp_shared.quarter_plan_version ENABLE ROW LEVEL SECURITY;
ALTER TABLE acp_shared.year_plan ENABLE ROW LEVEL SECURITY;
ALTER TABLE acp_deliver.tenant_tour_pages ENABLE ROW LEVEL SECURITY;

-- ── 2. tenant_isolation ───────────────────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS tenant_isolation ON acp_shared.subject;
CREATE POLICY tenant_isolation ON acp_shared.subject AS PERMISSIVE FOR ALL TO aa_app_user
    USING      (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
COMMENT ON POLICY tenant_isolation ON acp_shared.subject IS
    'AA-859 (265): the tenant pool (aa_app_user) reads and writes only rows of app.tenant_id; '''' or unset = no '
    'rows. Owner exempt (no FORCE).';

DROP POLICY IF EXISTS tenant_isolation ON acp_shared.quarter_plan;
CREATE POLICY tenant_isolation ON acp_shared.quarter_plan AS PERMISSIVE FOR ALL TO aa_app_user
    USING      (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
COMMENT ON POLICY tenant_isolation ON acp_shared.quarter_plan IS
    'AA-859 (265): the tenant pool (aa_app_user) reads and writes only rows of app.tenant_id; '''' or unset = no '
    'rows. Owner exempt (no FORCE).';

DROP POLICY IF EXISTS tenant_isolation ON acp_shared.year_plan;
CREATE POLICY tenant_isolation ON acp_shared.year_plan AS PERMISSIVE FOR ALL TO aa_app_user
    USING      (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
COMMENT ON POLICY tenant_isolation ON acp_shared.year_plan IS
    'AA-859 (265): the tenant pool (aa_app_user) reads and writes only rows of app.tenant_id; '''' or unset = no '
    'rows. Owner exempt (no FORCE).';

DROP POLICY IF EXISTS tenant_isolation ON acp_shared.quarter_plan_version;
CREATE POLICY tenant_isolation ON acp_shared.quarter_plan_version AS PERMISSIVE FOR ALL TO aa_app_user
    USING (EXISTS (SELECT 1 FROM acp_shared.quarter_plan qp
                    WHERE qp.plan_id = quarter_plan_version.plan_id
                      AND qp.tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid))
    WITH CHECK (EXISTS (SELECT 1 FROM acp_shared.quarter_plan qp
                         WHERE qp.plan_id = quarter_plan_version.plan_id
                           AND qp.tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid));
COMMENT ON POLICY tenant_isolation ON acp_shared.quarter_plan_version IS
    'AA-859 (265): the tenant pool (aa_app_user) reads and writes only versions of plans of app.tenant_id (through '
    'acp_shared.quarter_plan and its own policy); '''' or unset = no rows. Owner exempt (no FORCE).';

DROP POLICY IF EXISTS tenant_isolation ON acp_deliver.tenant_tour_pages;
CREATE POLICY tenant_isolation ON acp_deliver.tenant_tour_pages AS PERMISSIVE FOR ALL TO aa_app_user
    USING      (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
COMMENT ON POLICY tenant_isolation ON acp_deliver.tenant_tour_pages IS
    'AA-859 (265): the tenant pool (aa_app_user) reads only rows of app.tenant_id (text compare, no cast); '''' or '
    'unset = no rows. Owner exempt (no FORCE).';
DROP POLICY IF EXISTS aa_app_user_aa_master_read ON acp_deliver.tenant_tour_pages;
CREATE POLICY aa_app_user_aa_master_read ON acp_deliver.tenant_tour_pages AS PERMISSIVE FOR SELECT TO aa_app_user
    USING (tenant_id = '00000000-0000-0000-0000-000000000001');
COMMENT ON POLICY aa_app_user_aa_master_read ON acp_deliver.tenant_tour_pages IS
    'AA-859 (265): the tenant pool (aa_app_user) reads the AA master tenant''s public trip pages under any '
    'app.tenant_id (the 239 shape, read only).';

-- ── 3. X1 parity for the CIS runtime (CIS 244) ───────────────────────────────────────────────────
DROP POLICY IF EXISTS subject_cis_app_all ON acp_shared.subject;
CREATE POLICY subject_cis_app_all ON acp_shared.subject AS PERMISSIVE FOR ALL TO cis_app
    USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS quarter_plan_cis_app_all ON acp_shared.quarter_plan;
CREATE POLICY quarter_plan_cis_app_all ON acp_shared.quarter_plan AS PERMISSIVE FOR ALL TO cis_app
    USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS quarter_plan_version_cis_app_all ON acp_shared.quarter_plan_version;
CREATE POLICY quarter_plan_version_cis_app_all ON acp_shared.quarter_plan_version AS PERMISSIVE FOR ALL TO cis_app
    USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS year_plan_cis_app_all ON acp_shared.year_plan;
CREATE POLICY year_plan_cis_app_all ON acp_shared.year_plan AS PERMISSIVE FOR ALL TO cis_app
    USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS tenant_tour_pages_cis_app_all ON acp_deliver.tenant_tour_pages;
CREATE POLICY tenant_tour_pages_cis_app_all ON acp_deliver.tenant_tour_pages AS PERMISSIVE FOR ALL TO cis_app
    USING (true) WITH CHECK (true);

-- ── 4. Grants the tenant-pool routes need (exact set: start from nothing) ─────────────────────────
GRANT USAGE ON SCHEMA acp_shared, acp_deliver TO aa_app_user;
REVOKE ALL ON acp_shared.subject FROM aa_app_user;
GRANT SELECT, UPDATE (state) ON acp_shared.subject TO aa_app_user;
REVOKE ALL ON acp_shared.year_plan FROM aa_app_user;
GRANT SELECT, INSERT (tenant_id, year) ON acp_shared.year_plan TO aa_app_user;
REVOKE ALL ON acp_shared.quarter_plan FROM aa_app_user;
GRANT SELECT, INSERT (tenant_id, year, quarter, year_plan_id), UPDATE (year_plan_id, current_version_id)
    ON acp_shared.quarter_plan TO aa_app_user;
REVOKE ALL ON acp_shared.quarter_plan_version FROM aa_app_user;
GRANT SELECT, INSERT (plan_id, version_no, payload, source, approval_status),
      UPDATE (approval_status, approved_by, approved_at)
    ON acp_shared.quarter_plan_version TO aa_app_user;
REVOKE ALL ON acp_deliver.tenant_tour_pages FROM aa_app_user;
GRANT SELECT ON acp_deliver.tenant_tour_pages TO aa_app_user;

-- ── 5. The platform read allowlist (table-level SELECT only) and acp_contract USAGE ───────────────
GRANT USAGE ON SCHEMA acp_contract TO aa_app_user;
REVOKE ALL ON acp_contract.route, acp_contract.atom_segment, acp_contract.atom_segment_member,
              acp_contract.atom_segment_alias, acp_shared.place_card, acp_shared.place_card_alias,
              acp_shared.atom_place_card FROM aa_app_user;
GRANT SELECT ON acp_contract.route, acp_contract.atom_segment, acp_contract.atom_segment_member,
                acp_contract.atom_segment_alias, acp_shared.place_card_alias, acp_shared.atom_place_card
    TO aa_app_user;
-- place_card: only the columns subject_seed._ALIAS_SQL reads (verified_by, cost_usd, naming_note, facts stay out)
GRANT SELECT (card_id, status) ON acp_shared.place_card TO aa_app_user;

-- ── Guards 2-5 ────────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    tables      constant text[] := ARRAY['acp_shared.subject', 'acp_shared.quarter_plan',
                                         'acp_shared.quarter_plan_version', 'acp_shared.year_plan',
                                         'acp_deliver.tenant_tour_pages'];
    platform    constant text[] := ARRAY['acp_contract.route', 'acp_contract.atom_segment',
                                         'acp_contract.atom_segment_member', 'acp_contract.atom_segment_alias',
                                         'acp_shared.place_card', 'acp_shared.place_card_alias',
                                         'acp_shared.atom_place_card'];
    foreign_guc constant text := '00000000-0000-0000-0000-00000000dead';
    uuid_qual   constant text := '(tenant_id = (NULLIF(current_setting(''app.tenant_id''::text, true), ''''::text))::uuid)';
    text_qual   constant text := '(tenant_id = NULLIF(current_setting(''app.tenant_id''::text, true), ''''::text))';
    master_qual constant text := '(tenant_id = ''00000000-0000-0000-0000-000000000001''::text)';
    t           text;
    tbl         regclass;
    tname       text;
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
        n_before := current_setting('aa265.n_' || tname)::bigint;

        -- 2. the runner is still exempt
        PERFORM set_config('app.tenant_id', foreign_guc, true);
        IF row_security_active(tbl) THEN
            RAISE EXCEPTION 'migration 265: RLS is active for the runner % on %', current_user, t;
        END IF;
        EXECUTE format('SELECT count(*) FROM %s', tbl) INTO n;
        IF n <> n_before THEN
            RAISE EXCEPTION 'migration 265: the runner sees % of % rows of % under a foreign tenant', n, n_before, t;
        END IF;

        -- 3. policy shape
        IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = tbl AND relrowsecurity AND NOT relforcerowsecurity) THEN
            RAISE EXCEPTION 'migration 265: % must have RLS enabled and not forced', t;
        END IF;
        SELECT array_agg(polname::text ORDER BY polname::text COLLATE "C") INTO pols FROM pg_policy WHERE polrelid = tbl;
        expected := ARRAY[tname || '_cis_app_all', 'tenant_isolation'];
        IF tname = 'tenant_tour_pages' THEN
            expected := expected || 'aa_app_user_aa_master_read'::text;
        END IF;
        SELECT array_agg(x ORDER BY x COLLATE "C") INTO expected FROM unnest(expected) x;
        IF pols IS DISTINCT FROM expected THEN
            RAISE EXCEPTION 'migration 265: % has policies % (expected %)', t, pols, expected;
        END IF;
        IF tname = 'quarter_plan_version' THEN
            IF NOT EXISTS (SELECT 1 FROM pg_policy p
                            WHERE p.polrelid = tbl AND p.polname = 'tenant_isolation' AND p.polpermissive
                              AND p.polcmd = '*' AND p.polroles = ARRAY['aa_app_user'::regrole::oid]
                              AND pg_get_expr(p.polqual, p.polrelid) ILIKE
                                  '%acp_shared.quarter_plan qp%qp.plan_id = quarter_plan_version.plan_id%'
                                  'qp.tenant_id = (NULLIF(current_setting(''app.tenant_id''%'
                              AND pg_get_expr(p.polwithcheck, p.polrelid) = pg_get_expr(p.polqual, p.polrelid)) THEN
                RAISE EXCEPTION 'migration 265: policy tenant_isolation on % is not PERMISSIVE FOR ALL TO aa_app_user '
                                'through acp_shared.quarter_plan on the NULLIF''d app.tenant_id with WITH CHECK = '
                                'USING', t;
            END IF;
        ELSIF NOT EXISTS (SELECT 1 FROM pg_policy p
                           WHERE p.polrelid = tbl AND p.polname = 'tenant_isolation' AND p.polpermissive
                             AND p.polcmd = '*' AND p.polroles = ARRAY['aa_app_user'::regrole::oid]
                             AND pg_get_expr(p.polqual, p.polrelid)
                                 = CASE WHEN tname = 'tenant_tour_pages' THEN text_qual ELSE uuid_qual END
                             AND pg_get_expr(p.polwithcheck, p.polrelid) = pg_get_expr(p.polqual, p.polrelid)) THEN
            RAISE EXCEPTION 'migration 265: policy tenant_isolation on % is not the NULLIF template (PERMISSIVE FOR ALL '
                            'TO aa_app_user, USING = WITH CHECK)', t;
        END IF;
        IF tname = 'tenant_tour_pages'
           AND NOT EXISTS (SELECT 1 FROM pg_policy p
                            WHERE p.polrelid = tbl AND p.polname = 'aa_app_user_aa_master_read' AND p.polpermissive
                              AND p.polcmd = 'r' AND p.polroles = ARRAY['aa_app_user'::regrole::oid]
                              AND pg_get_expr(p.polqual, p.polrelid) = master_qual
                              AND p.polwithcheck IS NULL) THEN
            RAISE EXCEPTION 'migration 265: policy aa_app_user_aa_master_read on % is not PERMISSIVE FOR SELECT TO '
                            'aa_app_user USING %', t, master_qual;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_policy p
                        WHERE p.polrelid = tbl AND p.polname = tname || '_cis_app_all' AND p.polpermissive
                          AND p.polcmd = '*' AND p.polroles = ARRAY['cis_app'::regrole::oid]
                          AND pg_get_expr(p.polqual, p.polrelid) = 'true'
                          AND pg_get_expr(p.polwithcheck, p.polrelid) = 'true') THEN
            RAISE EXCEPTION 'migration 265: policy %_cis_app_all on % is not the X1 parity policy (PERMISSIVE FOR ALL '
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
        expected := CASE tname
            WHEN 'subject' THEN ARRAY['SELECT', 'UPDATE(state)']
            WHEN 'year_plan' THEN ARRAY['SELECT', 'INSERT(tenant_id)', 'INSERT(year)']
            WHEN 'quarter_plan' THEN ARRAY['SELECT', 'INSERT(tenant_id)', 'INSERT(year)', 'INSERT(quarter)',
                                           'INSERT(year_plan_id)', 'UPDATE(year_plan_id)', 'UPDATE(current_version_id)']
            WHEN 'quarter_plan_version' THEN ARRAY['SELECT', 'INSERT(plan_id)', 'INSERT(version_no)', 'INSERT(payload)',
                                                   'INSERT(source)', 'INSERT(approval_status)',
                                                   'UPDATE(approval_status)', 'UPDATE(approved_by)',
                                                   'UPDATE(approved_at)']
            ELSE ARRAY['SELECT'] END;
        SELECT array_agg(p ORDER BY p) INTO expected FROM unnest(expected) p;
        IF got IS DISTINCT FROM expected THEN
            RAISE EXCEPTION 'migration 265: aa_app_user holds % on % (expected %)', got, t, expected;
        END IF;
    END LOOP;
    PERFORM set_config('app.tenant_id', '', true);

    -- 4b. exactly SELECT on the platform relations (table level; place_card: SELECT (card_id, status) only), USAGE
    -- on acp_contract
    FOREACH t IN ARRAY platform LOOP
        SELECT array_agg(p ORDER BY p) INTO got FROM (
            SELECT a.privilege_type AS p FROM pg_class c, aclexplode(c.relacl) a
             WHERE c.oid = t::regclass AND a.grantee = 'aa_app_user'::regrole
            UNION ALL
            SELECT a.privilege_type || '(' || att.attname || ')'
              FROM pg_attribute att, aclexplode(att.attacl) a
             WHERE att.attrelid = t::regclass AND att.attacl IS NOT NULL AND NOT att.attisdropped
               AND a.grantee = 'aa_app_user'::regrole) x;
        expected := CASE WHEN t = 'acp_shared.place_card' THEN ARRAY['SELECT(card_id)', 'SELECT(status)']
                         ELSE ARRAY['SELECT'] END;
        IF got IS DISTINCT FROM expected THEN
            RAISE EXCEPTION 'migration 265: aa_app_user holds % on platform relation % (expected %)', got, t, expected;
        END IF;
    END LOOP;
    IF NOT has_schema_privilege('aa_app_user', 'acp_contract', 'USAGE') THEN
        RAISE EXCEPTION 'migration 265: aa_app_user has no USAGE on schema acp_contract';
    END IF;

    -- 5. the AA-859 invariant, version 2 (same text as NO_PRIVILEGE_WITHOUT_RLS_SQL_V2 / 266 guard 5)
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
        RAISE EXCEPTION 'migration 265: aa_app_user holds privileges on relations without RLS: % (AA-859 invariant, '
                        '241; v2 with the platform read allowlist)', bad;
    END IF;
    SELECT string_agg(c.oid::regclass::text, ', ') INTO bad
      FROM pg_class c
     WHERE c.relnamespace = 'acp_contract'::regnamespace AND c.relkind IN ('v', 'm')
       AND (has_table_privilege('aa_app_user', c.oid, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
            OR has_any_column_privilege('aa_app_user', c.oid, 'SELECT, INSERT, UPDATE, REFERENCES'));
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 265: aa_app_user holds privileges on the acp_contract views % (owner rights, RLS '
                        'bypassed)', bad;
    END IF;
    -- acp_contract is reachable by aa_app_user for the first time (USAGE above). A PUBLIC grant on a relation
    -- there without RLS now reaches the tenant pool, and V2 looks only at grants to aa_app_user: any privilege,
    -- table or column level, SELECT included (241's queries, raised instead of a NOTICE: no such grant on Dev).
    SELECT string_agg(DISTINCT format('%s %s', g.rel, g.priv), '; ') INTO bad
      FROM (SELECT c.oid::regclass::text AS rel, a.privilege_type AS priv
              FROM pg_class c, aclexplode(c.relacl) a
             WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f') AND NOT c.relrowsecurity AND a.grantee = 0
               AND c.relnamespace = 'acp_contract'::regnamespace
            UNION ALL
            SELECT c.oid::regclass::text, a.privilege_type || '(' || att.attname || ')'
              FROM pg_class c JOIN pg_attribute att ON att.attrelid = c.oid AND att.attacl IS NOT NULL
                                                    AND NOT att.attisdropped,
                   aclexplode(att.attacl) a
             WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f') AND NOT c.relrowsecurity AND a.grantee = 0
               AND c.relnamespace = 'acp_contract'::regnamespace) g;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 265: PUBLIC holds privileges on acp_contract relations without RLS, which the '
                        'tenant pool now reaches: %', bad;
    END IF;
    -- A SECURITY DEFINER function runs with its owner's rights (RLS bypassed for the owner) and EXECUTE is PUBLIC
    -- by default: with USAGE on the schema the tenant role could call it.
    SELECT string_agg(p.oid::regprocedure::text, ', ') INTO bad
      FROM pg_proc p
     WHERE p.pronamespace = 'acp_contract'::regnamespace AND p.prosecdef
       AND has_function_privilege('aa_app_user', p.oid, 'EXECUTE');
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 265: aa_app_user may execute SECURITY DEFINER functions in acp_contract: % '
                        '(owner rights; REVOKE EXECUTE first)', bad;
    END IF;
END $$;

-- ── Guard 6: cis_app parity by behaviour (the DB Migrate way only) ──────────────────────────────────
DO $$
DECLARE
    tables      constant text[] := ARRAY['acp_shared.subject', 'acp_shared.quarter_plan',
                                         'acp_shared.quarter_plan_version', 'acp_shared.year_plan',
                                         'acp_deliver.tenant_tour_pages'];
    foreign_guc constant text := '00000000-0000-0000-0000-00000000dead';
    t           text;
    n_plain     bigint;
    n_forged    bigint;
    n_before    bigint;
BEGIN
    IF current_user <> 'cis_owner' OR NOT pg_has_role(session_user, 'cis_app', 'MEMBER')
       OR NOT has_table_privilege('cis_app', 'acp_shared.subject', 'SELECT')
       OR NOT has_table_privilege('cis_app', 'acp_shared.quarter_plan', 'SELECT')
       OR NOT has_table_privilege('cis_app', 'acp_shared.quarter_plan_version', 'SELECT')
       OR NOT has_table_privilege('cis_app', 'acp_shared.year_plan', 'SELECT')
       OR NOT has_table_privilege('cis_app', 'acp_deliver.tenant_tour_pages', 'SELECT') THEN
        RAISE NOTICE 'migration 265: guard 6 (cis_app parity by behaviour) skipped: runs only as cis_owner under a '
                     'login that is a member of cis_app, with cis_app''s 244 grants (the DB Migrate way)';
        RETURN;
    END IF;
    FOREACH t IN ARRAY tables LOOP
        n_before := current_setting('aa265.n_' || split_part(t, '.', 2))::bigint;
        PERFORM set_config('app.tenant_id', '', true);
        SET LOCAL ROLE cis_app;
        EXECUTE format('SELECT count(*) FROM %s', t) INTO n_plain;
        PERFORM set_config('app.tenant_id', foreign_guc, true);
        EXECUTE format('SELECT count(*) FROM %s', t) INTO n_forged;
        SET LOCAL ROLE cis_owner;
        IF n_plain <> n_before OR n_forged <> n_before THEN
            RAISE EXCEPTION 'migration 265: cis_app reads % (no GUC) / % (foreign GUC) of % rows of %: the main pool '
                            'and the worker would lose rows', n_plain, n_forged, n_before, t;
        END IF;
    END LOOP;
    PERFORM set_config('app.tenant_id', '', true);
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('265', now(),
    'AA-859 wave 4: acp_shared.subject / quarter_plan / quarter_plan_version / year_plan and '
    'acp_deliver.tenant_tour_pages on RLS (ENABLE without FORCE; tenant_isolation TO aa_app_user on the NULLIF GUC '
    'with WITH CHECK, through quarter_plan for the versions, text compare + master read for the pages; the X1 parity '
    'policy TO cis_app); aa_app_user: the column grants of the pick / cut / trip-reallocation statements, SELECT on '
    'the pages, USAGE on acp_contract and SELECT on the platform read allowlist (route, atom_segment, '
    'atom_segment_member, atom_segment_alias, place_card_alias, atom_place_card; place_card (card_id, status) only)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
