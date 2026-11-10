-- Migration tp-028: AA-1038 (R5, the FORCE slice, root ADR 0019 d10) — tenant row-level security on
-- tripplanner.sessions, trip_drafts, trip_events and outbox becomes enforcing: FORCE ROW LEVEL SECURITY, a strict
-- tenant policy for the runtime role, an explicit system scope for the jobs Lambda and an owner read path for the
-- owner-owned views.
--
-- Class: contract (root ADR 0017 / 0017a). The file has no directive line on purpose: it drops and adds policies on
-- existing tables, forces their row security, changes a column default and an existing view's options, which the
-- expand classifier refuses. On Dev, AA-CIS-Infra Migration Apply runs it in contract mode once every job table is
-- idle (byte-identical copy db/migrations/tripplanner/028_force_tenant_rls.sql), as tp_owner, the live owner of
-- schema tripplanner since tp-013 (XD8). Never run it from a laptop.
--
-- Order (the code goes first, then this file). The code that works under this file ships before it is applied and
-- works under tp-025 as well: the assembly Lambda binds a tenant on every request since tp-025 (slice 1) and the
-- jobs Lambda opens the system scope (backend/shared/tenant.py system_scope) for the two kinds that touch the outbox
-- (tp_retention_outbox_redact, tp_lead_deliver); under tp-025 that setting is read by no policy. Applied before that
-- jobs code is live, the two kinds would see no outbox row (no error, nothing redacted) until it deploys.
--
-- Why. tp-025 (shadow) let a connection without a tenant context see and write every tenant's rows (the policy's
-- unset-GUC branch) and left the owner outside row security (ENABLE, not FORCE). A request path that forgot to bind a
-- tenant, or bound '' after a failed unbind, read across tenants. After this file no context = no row.
--
-- What, in this order:
--   1. guard: the file runs as tp_owner, the four tables carry tenant_id (tp-025), role tripplanner does not bypass
--      row security;
--   2. LOCK the four tables (ACCESS EXCLUSIVE, the order the assembly Lambda touches them, as tp-025);
--   3. column default NULLIF(current_setting('app.tenant_id', true), '')::uuid: the bound tenant, no demo fallback
--      any more. NOT NULL stays (tp-025), so an INSERT without a tenant context fails instead of landing in the demo
--      tenant;
--   4. DROP POLICY IF EXISTS <table>_tenant_shadow (tp-025);
--   5. three permissive policies per table, each created only when missing (a re-run leaves them as they are):
--        <table>_tenant      FOR ALL TO tripplanner:
--                              USING / WITH CHECK  tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid
--                            (unset or '' = NULL = no row; another tenant's row fails WITH CHECK; a context that is
--                            not a uuid fails the statement, it never widens the read);
--        <table>_system      FOR ALL TO tripplanner, tp_owner:
--                              USING / WITH CHECK  NULLIF(current_setting('app.tenant_scope', true), '') = 'system'
--                            (the jobs Lambda's cross-tenant path, opened per run by tenant.system_scope; a later
--                            tp- file that must rewrite rows as tp_owner opens it with set_config('app.tenant_scope',
--                            'system', true) first, else its UPDATE reaches no row);
--        <table>_owner_read  FOR SELECT TO tp_owner:
--                              USING  NULLIF(current_setting('app.tenant_id', true), '') IS NULL
--                                     OR tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid
--                            (the owner-owned views run as tp_owner: v_ops_* read by cis_app, which binds no
--                            TripPlanner tenant, keep every row; under a bound tenant they show only its rows; the
--                            guards of later files read every row). Owner writes go through <table>_system only;
--   6. ENABLE and FORCE ROW LEVEL SECURITY (FORCE: the owner tp_owner, and so every owner-owned view, is filtered by
--      the policies above instead of bypassing them);
--   7. ALTER VIEW tripplanner.v_inquiry_outbox SET (security_invoker = true): the retired inquiry view (tp-008, no
--      consumer since tp-027) is still granted to tripplanner with DML (tp-008 + the tp_owner default privileges),
--      and as an owner view it would answer under <outbox>_owner_read, i.e. every tenant's traveller data to a
--      connection without a tenant. As an invoker view the runtime role's own policies apply through it;
--   8. comments (columns, policies);
--   9. guards (RAISE, the transaction rolls back): row security enabled AND forced on the four; exactly the three
--      policies on each, of their shape (permissive, command, roles, the GUC they read, no unset branch in
--      <table>_tenant), none TO PUBLIC; the default has no demo fallback; no row without a tenant; the view is an
--      invoker view; registration.
--
-- RLS catalogue guard (AA-CIS-App tests/integration/rls_catalogue_rules.py, Dev nightly dump): rule a (RLS on, a
-- policy reading app.tenant_id), b (no policy TO PUBLIC), d (every current_setting('app.tenant_id') inside
-- NULLIF(..., '')) and t (no bare true) all hold; app.tenant_scope is not a tenant GUC for those rules.
--
-- Out of scope (unchanged): narration_cache and ai_rate_counter (no tenant_id, keys are hashes), customers and
-- traveller_accounts (frozen since R0, retired later), job (system queue), component_id_map (global id map). The
-- v_ops_* views stay owner views (their consumer cis_app holds no table grant).
--
-- Locks: ACCESS EXCLUSIVE on the four small tables (~125 sessions, ~120 drafts, ~600 events, ~10 outbox rows on Dev)
-- for the length of the file, catalog work only (no row is rewritten). A Lambda request waits behind it; past the
-- runner's lock_timeout the file rolls back whole and can be re-run.
-- Re-runnable (test_replay_twice_pg.py): the same default, DROP POLICY IF EXISTS, policies only when missing, the same
-- ENABLE / FORCE / view option / comments, ON CONFLICT DO NOTHING. tp-025 cannot run again after this file (its
-- guard refuses a forced table): test_replay_twice_pg.py lists it in SUPERSEDED_BY_DROP.
-- Undo: a later tp- file (contract): NO FORCE ROW LEVEL SECURITY, drop the three policies and recreate the tp-025
-- shadow policies, the demo default back, the view option reset; only after the jobs code stops depending on it.

BEGIN;

-- 1. guards before any change

DO $$
DECLARE
    missing text;
BEGIN
    IF current_user <> 'tp_owner' THEN
        RAISE EXCEPTION 'tp-028: expected to run as tp_owner (live owner of schema tripplanner), running as %', current_user;
    END IF;
    SELECT string_agg(r, ', ' ORDER BY r) INTO missing
      FROM unnest(ARRAY['sessions', 'trip_drafts', 'trip_events', 'outbox']) AS r
     WHERE NOT EXISTS (SELECT 1 FROM pg_attribute a
                        WHERE a.attrelid = ('tripplanner.' || r)::regclass AND a.attname = 'tenant_id'
                          AND NOT a.attisdropped AND a.attnotnull AND a.atttypid = 'uuid'::regtype);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'tp-028: tenant_id (NOT NULL uuid, tp-025) missing on tripplanner.%', missing;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'tripplanner' AND (rolbypassrls OR rolsuper)) THEN
        RAISE EXCEPTION 'tp-028: role tripplanner bypasses row-level security';
    END IF;
END $$;

-- 2. locks

LOCK TABLE tripplanner.sessions, tripplanner.trip_drafts, tripplanner.trip_events, tripplanner.outbox
    IN ACCESS EXCLUSIVE MODE;

-- 3. the column default: the bound tenant only

ALTER TABLE tripplanner.sessions
    ALTER COLUMN tenant_id SET DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid;
ALTER TABLE tripplanner.trip_drafts
    ALTER COLUMN tenant_id SET DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid;
ALTER TABLE tripplanner.trip_events
    ALTER COLUMN tenant_id SET DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid;
ALTER TABLE tripplanner.outbox
    ALTER COLUMN tenant_id SET DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid;

-- 4. the tp-025 shadow policies go

DROP POLICY IF EXISTS sessions_tenant_shadow ON tripplanner.sessions;
DROP POLICY IF EXISTS trip_drafts_tenant_shadow ON tripplanner.trip_drafts;
DROP POLICY IF EXISTS trip_events_tenant_shadow ON tripplanner.trip_events;
DROP POLICY IF EXISTS outbox_tenant_shadow ON tripplanner.outbox;

-- 5. the enforcing policies (created only when missing)

DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['sessions', 'trip_drafts', 'trip_events', 'outbox'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'tripplanner' AND tablename = t
                                                   AND policyname = t || '_tenant') THEN
            EXECUTE format(
                'CREATE POLICY %I ON tripplanner.%I AS PERMISSIVE FOR ALL TO tripplanner '
                'USING (tenant_id = NULLIF(current_setting(''app.tenant_id'', true), '''')::uuid) '
                'WITH CHECK (tenant_id = NULLIF(current_setting(''app.tenant_id'', true), '''')::uuid)',
                t || '_tenant', t);
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'tripplanner' AND tablename = t
                                                   AND policyname = t || '_system') THEN
            EXECUTE format(
                'CREATE POLICY %I ON tripplanner.%I AS PERMISSIVE FOR ALL TO tripplanner, tp_owner '
                'USING (NULLIF(current_setting(''app.tenant_scope'', true), '''') = ''system'') '
                'WITH CHECK (NULLIF(current_setting(''app.tenant_scope'', true), '''') = ''system'')',
                t || '_system', t);
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'tripplanner' AND tablename = t
                                                   AND policyname = t || '_owner_read') THEN
            EXECUTE format(
                'CREATE POLICY %I ON tripplanner.%I AS PERMISSIVE FOR SELECT TO tp_owner '
                'USING (NULLIF(current_setting(''app.tenant_id'', true), '''') IS NULL '
                'OR tenant_id = NULLIF(current_setting(''app.tenant_id'', true), '''')::uuid)',
                t || '_owner_read', t);
        END IF;
    END LOOP;
END $$;

-- 6. row-level security enabled and forced

ALTER TABLE tripplanner.sessions    ENABLE ROW LEVEL SECURITY;
ALTER TABLE tripplanner.trip_drafts ENABLE ROW LEVEL SECURITY;
ALTER TABLE tripplanner.trip_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE tripplanner.outbox      ENABLE ROW LEVEL SECURITY;
ALTER TABLE tripplanner.sessions    FORCE ROW LEVEL SECURITY;
ALTER TABLE tripplanner.trip_drafts FORCE ROW LEVEL SECURITY;
ALTER TABLE tripplanner.trip_events FORCE ROW LEVEL SECURITY;
ALTER TABLE tripplanner.outbox      FORCE ROW LEVEL SECURITY;

-- 7. the retired inquiry view answers with the caller's policies

ALTER VIEW tripplanner.v_inquiry_outbox SET (security_invoker = true);

-- 8. comments

COMMENT ON COLUMN tripplanner.sessions.tenant_id IS
    'tp-025 (AA-1038 R5): owning tenant, soft key to shared.tenants.tenant_id (no FK, another owner). tp-028: FORCE row-level security; policies sessions_tenant (TO tripplanner, the bound app.tenant_id only), sessions_system (app.tenant_scope = system, the jobs Lambda) and sessions_owner_read (tp_owner views). Default: the bound app.tenant_id (none = the insert fails).';
COMMENT ON COLUMN tripplanner.trip_drafts.tenant_id IS
    'tp-025 (AA-1038 R5): owning tenant, soft key to shared.tenants.tenant_id (no FK, another owner). tp-028: FORCE row-level security; policies trip_drafts_tenant (TO tripplanner, the bound app.tenant_id only), trip_drafts_system (app.tenant_scope = system, the jobs Lambda) and trip_drafts_owner_read (tp_owner views). Default: the bound app.tenant_id (none = the insert fails).';
COMMENT ON COLUMN tripplanner.trip_events.tenant_id IS
    'tp-025 (AA-1038 R5): owning tenant, soft key to shared.tenants.tenant_id (no FK, another owner). tp-028: FORCE row-level security; policies trip_events_tenant (TO tripplanner, the bound app.tenant_id only), trip_events_system (app.tenant_scope = system, the jobs Lambda) and trip_events_owner_read (tp_owner views). Default: the bound app.tenant_id (none = the insert fails).';
COMMENT ON COLUMN tripplanner.outbox.tenant_id IS
    'tp-025 (AA-1038 R5): owning tenant, soft key to shared.tenants.tenant_id (no FK, another owner). tp-028: FORCE row-level security; policies outbox_tenant (TO tripplanner, the bound app.tenant_id only), outbox_system (app.tenant_scope = system, the jobs Lambda) and outbox_owner_read (tp_owner views). Default: the bound app.tenant_id (none = the insert fails). Not in v_inquiry_outbox (its column list is fixed).';

DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['sessions', 'trip_drafts', 'trip_events', 'outbox'] LOOP
        EXECUTE format('COMMENT ON POLICY %I ON tripplanner.%I IS %L', t || '_tenant', t,
                       'tp-028 (AA-1038): the runtime role sees and writes only the rows of the bound app.tenant_id; '
                       'no tenant context = no row.');
        EXECUTE format('COMMENT ON POLICY %I ON tripplanner.%I IS %L', t || '_system', t,
                       'tp-028 (AA-1038): every row while app.tenant_scope = system; opened only by the jobs Lambda '
                       '(backend/shared/tenant.py system_scope) and by a later tp- file that rewrites rows.');
        EXECUTE format('COMMENT ON POLICY %I ON tripplanner.%I IS %L', t || '_owner_read', t,
                       'tp-028 (AA-1038): reads of the owner-owned views (v_ops_* for cis_app) and of the migration '
                       'guards: every row without a bound tenant, the bound tenant''s rows with one.');
    END LOOP;
END $$;

-- 9. guards

DO $$
DECLARE
    bad text;
BEGIN
    -- row-level security enabled AND forced on all four
    SELECT string_agg(c.relname::text || ' (enabled=' || c.relrowsecurity || ', forced=' || c.relforcerowsecurity
                      || ')', ', ' ORDER BY c.relname) INTO bad
      FROM pg_class c
     WHERE c.relnamespace = 'tripplanner'::regnamespace
       AND c.relname IN ('sessions', 'trip_drafts', 'trip_events', 'outbox')
       AND NOT (c.relrowsecurity AND c.relforcerowsecurity);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'tp-028: expected row-level security enabled and forced on tripplanner.%', bad;
    END IF;

    -- exactly the three policies on each table (the shadow policy gone, nothing added by hand)
    SELECT string_agg(r || ' (' || coalesce(n::text, '0') || ')', ', ' ORDER BY r) INTO bad
      FROM (SELECT r, (SELECT count(*) FROM pg_policies p WHERE p.schemaname = 'tripplanner' AND p.tablename = r) AS n,
                   (SELECT array_agg(p.policyname::text ORDER BY p.policyname) FROM pg_policies p
                     WHERE p.schemaname = 'tripplanner' AND p.tablename = r) AS names
              FROM unnest(ARRAY['sessions', 'trip_drafts', 'trip_events', 'outbox']) AS r) x
     WHERE names IS DISTINCT FROM ARRAY[r || '_owner_read', r || '_system', r || '_tenant'];
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'tp-028: expected exactly <table>_tenant, <table>_system and <table>_owner_read on '
                        'tripplanner.% (policy count in brackets)', bad;
    END IF;

    -- the shape of each policy
    SELECT string_agg(r, ', ' ORDER BY r) INTO bad
      FROM unnest(ARRAY['sessions', 'trip_drafts', 'trip_events', 'outbox']) AS r
     WHERE NOT EXISTS (SELECT 1 FROM pg_policies p
                        WHERE p.schemaname = 'tripplanner' AND p.tablename = r AND p.policyname = r || '_tenant'
                          AND p.permissive = 'PERMISSIVE' AND p.cmd = 'ALL'
                          AND p.roles = ARRAY['tripplanner']::name[]
                          AND p.qual = p.with_check
                          AND p.qual LIKE '%tenant_id = (NULLIF(current_setting(''app.tenant_id''%'
                          AND p.qual NOT LIKE '%IS NULL%' AND p.qual NOT LIKE '%OR %')
        OR NOT EXISTS (SELECT 1 FROM pg_policies p
                        WHERE p.schemaname = 'tripplanner' AND p.tablename = r AND p.policyname = r || '_system'
                          AND p.permissive = 'PERMISSIVE' AND p.cmd = 'ALL'
                          AND (SELECT array_agg(x ORDER BY x) FROM unnest(p.roles) x)
                              = ARRAY['tp_owner', 'tripplanner']::name[]
                          AND p.qual = p.with_check
                          AND p.qual LIKE '%NULLIF(current_setting(''app.tenant_scope''%''system''%'
                          AND p.qual NOT LIKE '%app.tenant_id%')
        OR NOT EXISTS (SELECT 1 FROM pg_policies p
                        WHERE p.schemaname = 'tripplanner' AND p.tablename = r AND p.policyname = r || '_owner_read'
                          AND p.permissive = 'PERMISSIVE' AND p.cmd = 'SELECT'
                          AND p.roles = ARRAY['tp_owner']::name[]
                          AND p.with_check IS NULL
                          AND p.qual LIKE '%NULLIF(current_setting(''app.tenant_id''%');
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'tp-028: a policy of another shape on tripplanner.%', bad;
    END IF;

    -- the default has no demo fallback
    SELECT string_agg(c.relname::text, ', ' ORDER BY c.relname) INTO bad
      FROM pg_attrdef d
      JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
      JOIN pg_class c ON c.oid = d.adrelid
     WHERE c.relnamespace = 'tripplanner'::regnamespace
       AND c.relname IN ('sessions', 'trip_drafts', 'trip_events', 'outbox')
       AND a.attname = 'tenant_id'
       AND (pg_get_expr(d.adbin, d.adrelid) LIKE '%00000000-0000-0000-0000-000000000002%'
            OR pg_get_expr(d.adbin, d.adrelid) LIKE '%COALESCE%');
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'tp-028: tenant_id default still falls back to the demo tenant on tripplanner.%', bad;
    END IF;

    -- no row without a tenant (read as tp_owner through <table>_owner_read, no tenant bound: every row)
    IF EXISTS (SELECT 1 FROM tripplanner.sessions WHERE tenant_id IS NULL)
       OR EXISTS (SELECT 1 FROM tripplanner.trip_drafts WHERE tenant_id IS NULL)
       OR EXISTS (SELECT 1 FROM tripplanner.trip_events WHERE tenant_id IS NULL)
       OR EXISTS (SELECT 1 FROM tripplanner.outbox WHERE tenant_id IS NULL) THEN
        RAISE EXCEPTION 'tp-028: rows without tenant_id';
    END IF;

    -- the retired inquiry view applies the caller's policies
    IF NOT EXISTS (SELECT 1 FROM pg_class c
                    WHERE c.oid = 'tripplanner.v_inquiry_outbox'::regclass
                      AND 'security_invoker=true' = ANY (coalesce(c.reloptions, '{}'))) THEN
        RAISE EXCEPTION 'tp-028: tripplanner.v_inquiry_outbox is not a security_invoker view';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('tp-028', now(), 'AA-1038 R5: FORCE row-level security and enforcing tenant policies on sessions, '
                         'trip_drafts, trip_events, outbox; system scope for the jobs Lambda')
ON CONFLICT (version) DO NOTHING;

COMMIT;
