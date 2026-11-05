-- Migration tp-025: AA-1038 (R5 slice 1, root ADR 0019 d10) — a tenant_id column and shadow row-level security on
-- the four trip-state tables: tripplanner.sessions, trip_drafts, trip_events, outbox.
--
-- Class: contract (root ADR 0017 / 0017a). The file has no directive line on purpose: it adds a column to existing
-- tables, rewrites their rows (the backfill UPDATE), changes column defaults and NOT NULL, and adds policies to
-- existing tables, which the expand classifier refuses. Merge order MIG-4: this migration-only PR first; the code PR
-- that binds the tenant context (assembly Lambda) follows once this file is applied on Dev. On Dev, AA-CIS-Infra
-- Migration Apply runs it in contract mode once every job table is idle (byte-identical copy
-- db/migrations/tripplanner/025_tenant_id_shadow_rls.sql), as tp_owner, the live owner of schema tripplanner since
-- tp-013 (XD8). Never run it from a laptop.
--
-- Why. ADR 0019 d10 makes TripPlanner a white-label product of each agency tenant. Every trip row needs an owning
-- tenant before the per-tenant path (/{slug}, the catalog view contract) can ship, and the database must be able to
-- filter by it. This slice is the "shadow" step: the column, the backfill and the policies exist, the runtime keeps
-- working without a tenant context, and the next code PR binds the demo tenant on every assembly request so the
-- filtering path runs in production before anything depends on it.
--
-- Tenant of the existing rows: the TripPlanner demo tenant, tenant_id 00000000-0000-0000-0000-000000000002 (slug
-- aa-tripplanner, kind demo; the CIS seed of shared.tenants uses the same fixed id). Every row written so far came from
-- the AA-hosted demo planner, so it belongs to that tenant. The column is a soft key to shared.tenants.tenant_id: no
-- foreign key, because shared is another owner's schema (RLS catalogue rule e, data standards DM-2).
--
-- What, for each of the four tables, in this order:
--   1. ADD COLUMN IF NOT EXISTS tenant_id uuid (nullable, no default: no table rewrite);
--   2. UPDATE ... SET tenant_id = <demo> WHERE tenant_id IS NULL (the backfill; created_at / updated_at untouched, so
--      the retention kinds keep their clocks);
--   3. SET DEFAULT COALESCE(NULLIF(current_setting('app.tenant_id', true), '')::uuid, <demo>): code that does not bind
--      a tenant yet keeps inserting demo rows, and once a tenant is bound an INSERT without tenant_id takes it;
--   4. SET NOT NULL;
--   5. a non-unique index: sessions (tenant_id), trip_drafts (tenant_id, session_id), trip_events (tenant_id, trip_id),
--      outbox (tenant_id);
--   6. ENABLE ROW LEVEL SECURITY, not FORCE: tp_owner (owner of the tables) bypasses, so the owner-owned views read by
--      other apps (v_inquiry_outbox for booking, v_ops_* for cis_app) keep every row;
--   7. one permissive policy <table>_tenant_shadow FOR ALL TO tripplanner (the runtime role of the three Lambdas):
--      USING and WITH CHECK
--        NULLIF(current_setting('app.tenant_id', true), '') IS NULL
--        OR tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid
--      i.e. no tenant context (unset or '') = every row (the jobs Lambda and today's code), a tenant context = that
--      tenant's rows only, for reads and writes. A context that is not a uuid fails the statement (cast error), it
--      never widens the read. Created in a DO block guarded by pg_policies, so a re-run changes nothing;
--   8. a column comment (tp-025, the soft key, the shadow phase).
-- Then guards (RAISE, the transaction rolls back): no NULL tenant_id; RLS on and not forced on all four; the shadow
-- policy present on all four with its shape (permissive, ALL, TO tripplanner, reads app.tenant_id). Then the
-- registration.
--
-- RLS catalogue guard (AA-CIS-App tests/integration/rls_catalogue_rules.py, Dev nightly dump): rule a (RLS on and a
-- policy reading app.tenant_id), b (TO tripplanner, never PUBLIC), d (every current_setting inside NULLIF(..., '')),
-- t (no bare true) all hold.
--
-- Out of scope (later R5 slices): FORCE, the strict policy (no unset branch), dropping the COALESCE default and a
-- system path for the jobs Lambda (the FORCE slice); narration_cache and ai_rate_counter (their key changes belong to
-- the per-tenant AI cap slice); customers and traveller_accounts (frozen, retired later under a DRY RUN); job (system
-- queue); component_id_map (global id map); the outbox event CHECK (the lead.submitted.v1 slice).
--
-- Locks: ACCESS EXCLUSIVE on the four tables for the length of the file (small tables: ~100 sessions, ~120 drafts,
-- ~560 events, ~10 outbox rows on Dev), taken up front in one LOCK statement in the order the assembly Lambda touches
-- them. A Lambda request waits behind it; past the runner's lock_timeout the file rolls back whole and can be re-run.
-- Re-runnable (test_replay_twice_pg.py): IF NOT EXISTS on the column and indexes, the UPDATE only touches NULL rows
-- (none on a re-run), the same default / NOT NULL / ENABLE / comment again, the policy only when missing,
-- ON CONFLICT DO NOTHING.
-- Undo: a later tp- file: DROP POLICY <table>_tenant_shadow and DISABLE ROW LEVEL SECURITY (contract), then DROP
-- COLUMN tenant_id with its index (destructive header, DRY RUN first) once no code reads or binds it.

BEGIN;

LOCK TABLE tripplanner.sessions, tripplanner.trip_drafts, tripplanner.trip_events, tripplanner.outbox
    IN ACCESS EXCLUSIVE MODE;

-- 1-4. column, backfill, default, NOT NULL

ALTER TABLE tripplanner.sessions ADD COLUMN IF NOT EXISTS tenant_id uuid;
UPDATE tripplanner.sessions SET tenant_id = '00000000-0000-0000-0000-000000000002' WHERE tenant_id IS NULL;
ALTER TABLE tripplanner.sessions
    ALTER COLUMN tenant_id SET DEFAULT COALESCE(NULLIF(current_setting('app.tenant_id', true), '')::uuid,
                                                '00000000-0000-0000-0000-000000000002'::uuid),
    ALTER COLUMN tenant_id SET NOT NULL;

ALTER TABLE tripplanner.trip_drafts ADD COLUMN IF NOT EXISTS tenant_id uuid;
UPDATE tripplanner.trip_drafts SET tenant_id = '00000000-0000-0000-0000-000000000002' WHERE tenant_id IS NULL;
ALTER TABLE tripplanner.trip_drafts
    ALTER COLUMN tenant_id SET DEFAULT COALESCE(NULLIF(current_setting('app.tenant_id', true), '')::uuid,
                                                '00000000-0000-0000-0000-000000000002'::uuid),
    ALTER COLUMN tenant_id SET NOT NULL;

ALTER TABLE tripplanner.trip_events ADD COLUMN IF NOT EXISTS tenant_id uuid;
UPDATE tripplanner.trip_events SET tenant_id = '00000000-0000-0000-0000-000000000002' WHERE tenant_id IS NULL;
ALTER TABLE tripplanner.trip_events
    ALTER COLUMN tenant_id SET DEFAULT COALESCE(NULLIF(current_setting('app.tenant_id', true), '')::uuid,
                                                '00000000-0000-0000-0000-000000000002'::uuid),
    ALTER COLUMN tenant_id SET NOT NULL;

ALTER TABLE tripplanner.outbox ADD COLUMN IF NOT EXISTS tenant_id uuid;
UPDATE tripplanner.outbox SET tenant_id = '00000000-0000-0000-0000-000000000002' WHERE tenant_id IS NULL;
ALTER TABLE tripplanner.outbox
    ALTER COLUMN tenant_id SET DEFAULT COALESCE(NULLIF(current_setting('app.tenant_id', true), '')::uuid,
                                                '00000000-0000-0000-0000-000000000002'::uuid),
    ALTER COLUMN tenant_id SET NOT NULL;

-- 5. indexes (non-unique)

CREATE INDEX IF NOT EXISTS sessions_tenant_idx    ON tripplanner.sessions (tenant_id);
CREATE INDEX IF NOT EXISTS trip_drafts_tenant_idx ON tripplanner.trip_drafts (tenant_id, session_id);
CREATE INDEX IF NOT EXISTS trip_events_tenant_idx ON tripplanner.trip_events (tenant_id, trip_id);
CREATE INDEX IF NOT EXISTS outbox_tenant_idx      ON tripplanner.outbox (tenant_id);

-- 6. row-level security on, not forced (the owner tp_owner and its views keep every row)

ALTER TABLE tripplanner.sessions    ENABLE ROW LEVEL SECURITY;
ALTER TABLE tripplanner.trip_drafts ENABLE ROW LEVEL SECURITY;
ALTER TABLE tripplanner.trip_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE tripplanner.outbox      ENABLE ROW LEVEL SECURITY;

-- 7. the shadow policies (created only when missing: a re-run leaves them as they are)

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'tripplanner' AND tablename = 'sessions'
                                               AND policyname = 'sessions_tenant_shadow') THEN
        CREATE POLICY sessions_tenant_shadow ON tripplanner.sessions AS PERMISSIVE FOR ALL TO tripplanner
            USING (NULLIF(current_setting('app.tenant_id', true), '') IS NULL
                   OR tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
            WITH CHECK (NULLIF(current_setting('app.tenant_id', true), '') IS NULL
                        OR tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'tripplanner' AND tablename = 'trip_drafts'
                                               AND policyname = 'trip_drafts_tenant_shadow') THEN
        CREATE POLICY trip_drafts_tenant_shadow ON tripplanner.trip_drafts AS PERMISSIVE FOR ALL TO tripplanner
            USING (NULLIF(current_setting('app.tenant_id', true), '') IS NULL
                   OR tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
            WITH CHECK (NULLIF(current_setting('app.tenant_id', true), '') IS NULL
                        OR tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'tripplanner' AND tablename = 'trip_events'
                                               AND policyname = 'trip_events_tenant_shadow') THEN
        CREATE POLICY trip_events_tenant_shadow ON tripplanner.trip_events AS PERMISSIVE FOR ALL TO tripplanner
            USING (NULLIF(current_setting('app.tenant_id', true), '') IS NULL
                   OR tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
            WITH CHECK (NULLIF(current_setting('app.tenant_id', true), '') IS NULL
                        OR tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'tripplanner' AND tablename = 'outbox'
                                               AND policyname = 'outbox_tenant_shadow') THEN
        CREATE POLICY outbox_tenant_shadow ON tripplanner.outbox AS PERMISSIVE FOR ALL TO tripplanner
            USING (NULLIF(current_setting('app.tenant_id', true), '') IS NULL
                   OR tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
            WITH CHECK (NULLIF(current_setting('app.tenant_id', true), '') IS NULL
                        OR tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
    END IF;
END $$;

-- 8. column comments

COMMENT ON COLUMN tripplanner.sessions.tenant_id IS
    'tp-025 (AA-1038 R5): owning tenant, soft key to shared.tenants.tenant_id (no FK, another owner). Shadow phase: RLS enabled, not forced; policy sessions_tenant_shadow (TO tripplanner) filters only when app.tenant_id is set. Default: app.tenant_id, else the TripPlanner demo tenant (aa-tripplanner); rows before tp-025 backfilled to it.';
COMMENT ON COLUMN tripplanner.trip_drafts.tenant_id IS
    'tp-025 (AA-1038 R5): owning tenant, soft key to shared.tenants.tenant_id (no FK, another owner). Shadow phase: RLS enabled, not forced; policy trip_drafts_tenant_shadow (TO tripplanner) filters only when app.tenant_id is set. Default: app.tenant_id, else the TripPlanner demo tenant (aa-tripplanner); rows before tp-025 backfilled to it.';
COMMENT ON COLUMN tripplanner.trip_events.tenant_id IS
    'tp-025 (AA-1038 R5): owning tenant, soft key to shared.tenants.tenant_id (no FK, another owner). Shadow phase: RLS enabled, not forced; policy trip_events_tenant_shadow (TO tripplanner) filters only when app.tenant_id is set. Default: app.tenant_id, else the TripPlanner demo tenant (aa-tripplanner); rows before tp-025 backfilled to it.';
COMMENT ON COLUMN tripplanner.outbox.tenant_id IS
    'tp-025 (AA-1038 R5): owning tenant, soft key to shared.tenants.tenant_id (no FK, another owner). Shadow phase: RLS enabled, not forced; policy outbox_tenant_shadow (TO tripplanner) filters only when app.tenant_id is set. Default: app.tenant_id, else the TripPlanner demo tenant (aa-tripplanner); rows before tp-025 backfilled to it. Not in v_inquiry_outbox (its column list is fixed).';

-- 9. guards

DO $$
DECLARE
    bad text;
BEGIN
    -- no row without a tenant (NOT NULL makes this impossible; checked as the owner, which reads every row)
    SELECT string_agg(t, ', ' ORDER BY t) INTO bad
      FROM (SELECT 'sessions' AS t WHERE EXISTS (SELECT 1 FROM tripplanner.sessions WHERE tenant_id IS NULL)
            UNION ALL
            SELECT 'trip_drafts' WHERE EXISTS (SELECT 1 FROM tripplanner.trip_drafts WHERE tenant_id IS NULL)
            UNION ALL
            SELECT 'trip_events' WHERE EXISTS (SELECT 1 FROM tripplanner.trip_events WHERE tenant_id IS NULL)
            UNION ALL
            SELECT 'outbox' WHERE EXISTS (SELECT 1 FROM tripplanner.outbox WHERE tenant_id IS NULL)) x;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'tp-025: rows without tenant_id in tripplanner.%', bad;
    END IF;

    -- tenant_id is a NOT NULL uuid on all four
    SELECT string_agg(r, ', ' ORDER BY r) INTO bad
      FROM unnest(ARRAY['sessions', 'trip_drafts', 'trip_events', 'outbox']) AS r
     WHERE NOT EXISTS (SELECT 1 FROM pg_attribute a
                        WHERE a.attrelid = ('tripplanner.' || r)::regclass AND a.attname = 'tenant_id'
                          AND NOT a.attisdropped AND a.attnotnull AND a.atttypid = 'uuid'::regtype);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'tp-025: tenant_id is not a NOT NULL uuid on tripplanner.%', bad;
    END IF;

    -- row-level security enabled and NOT forced (forced would filter the owner and its views: the FORCE slice)
    SELECT string_agg(c.relname::text || ' (enabled=' || c.relrowsecurity || ', forced=' || c.relforcerowsecurity
                      || ')', ', ' ORDER BY c.relname) INTO bad
      FROM pg_class c
     WHERE c.relnamespace = 'tripplanner'::regnamespace
       AND c.relname IN ('sessions', 'trip_drafts', 'trip_events', 'outbox')
       AND (NOT c.relrowsecurity OR c.relforcerowsecurity);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'tp-025: expected row-level security enabled and not forced on tripplanner.%', bad;
    END IF;

    -- the shadow policy on all four, with its shape: permissive, every command, TO tripplanner, reads app.tenant_id
    SELECT string_agg(r, ', ' ORDER BY r) INTO bad
      FROM unnest(ARRAY['sessions', 'trip_drafts', 'trip_events', 'outbox']) AS r
     WHERE NOT EXISTS (SELECT 1 FROM pg_policies p
                        WHERE p.schemaname = 'tripplanner' AND p.tablename = r
                          AND p.policyname = r || '_tenant_shadow'
                          AND p.permissive = 'PERMISSIVE' AND p.cmd = 'ALL'
                          AND p.roles = ARRAY['tripplanner']::name[]
                          AND p.qual LIKE '%NULLIF(current_setting(''app.tenant_id''%'
                          AND p.with_check LIKE '%NULLIF(current_setting(''app.tenant_id''%');
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'tp-025: policy <table>_tenant_shadow missing or of another shape on tripplanner.%', bad;
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('tp-025', now(), 'AA-1038 R5: tenant_id + shadow RLS on sessions, trip_drafts, trip_events, outbox')
ON CONFLICT (version) DO NOTHING;

COMMIT;
