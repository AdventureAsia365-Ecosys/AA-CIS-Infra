-- Migration tp-020: AA-992 — data coverage contract views for the CIS admin page /admin/data-coverage.
--
-- Why (AA-992; S252 data coverage design §3.1): the CIS admin "Data coverage" page counts, for the whole system, what
-- each stage holds and what is missing, from the raw upload to TripPlanner, Booking and the CRM. The TripPlanner part
-- needs numbers CIS cannot read itself: how many rows TripPlanner keeps (sessions, trips, id map, ...), which catalog
-- components travellers pinned and the id map that resolves them (so CIS can count pins whose component is gone). TripPlanner, the owner,
-- publishes three views in its own schema and grants them to the CIS runtime role cis_app (contract rule 5 of AA-Ecosys
-- docs/contracts/README.md; same pattern as tp-015). Every other tripplanner.* object stays 42501 for cis_app
-- (isolation probe cell cross.cis_app.tripplanner.sessions).
--
-- v_ops_data_totals (metric text, n bigint), long format, one row per metric, totals over all time:
--   sessions               tripplanner.sessions rows (guest + signed-in planner sessions)
--   trip_drafts            tripplanner.trip_drafts rows
--   trip_drafts_sent       trip_drafts with status 'sent' (sent to an advisor)
--   trips_with_events      distinct trips with at least one trip event
--   pin_events             trip events of type 'add_component' (pins ever added; remove_component not netted)
--   pin_events_invalid_id  add_component events whose payload component_id is not a UUID (POST /trip/{id}/components
--                          stores the body's component_id unchecked; such pins are left out of v_ops_pin_components)
--   component_id_map_rows  tripplanner.component_id_map rows (tp-017, AA-847)
--   customers              tripplanner.customers rows
--   traveller_accounts     tripplanner.traveller_accounts rows (tp-019)
--   outbox_rows            tripplanner.outbox rows (inquiry.submitted)
--   narration_cache_rows   tripplanner.narration_cache rows
-- Aggregates only: no id, no token, no customer, no payload text.
--
-- v_ops_pin_components (component_id text, trips bigint): one row per pinned component id as the traveller pinned it
-- (pins ever added, the same rule as AA-CIS-Infra db/scripts/aa990_reader_checks.py PINS_SQL), with the number of
-- trips that pinned it. It reads trip_events.payload (tagged pii:free_text, pii:travel) but exposes ONLY
-- payload->>'component_id', a CIS catalog key (geo.tour_place.component_id), never a trip id, a session id or any
-- traveller text. The assembly Lambda writes the request body's component_id into payload with no type or shape
-- check (a guest token can call it), so the view enforces the key's shape itself: only a UUID-shaped component_id is a
-- pin here (catalog component ids are UUIDs: component_id_map.old_id / new_id uuid, events.py ::uuid[]). Any other
-- string is counted, never shown, in v_ops_data_totals.pin_events_invalid_id. The id is lower-cased, the text form of a
-- Postgres uuid, so CIS compares it with geo.tour_place.component_id::text as is.
-- v_ops_component_id_map (old_id text, new_id text): the edges of tripplanner.component_id_map (tp-017 AA-847 fill +
-- the AA-990 backfill), catalog ids only. CIS needs every edge, not one hop per pin: TripPlanner resolves a pin by
-- walking the map and the CIS redirect (geo.component_redirect, CIS 285) hop by hop, map first, at most 5 hops
-- (backend/shared/component_ids.id_map), and the AA-990 backfill rows sit in the middle of such chains. CIS walks the
-- same chain on its side, so TripPlanner does not need the CIS catalog here.
--
-- Metric names and column lists are part of the contract (AA-Ecosys docs/contracts/ops.overview.v1.md, family
-- ops.data_coverage.v1): add new names, never rename.
--
-- Readers: cis_app gets SELECT on the three views (USAGE on schema tripplanner is held since tp-015; repeated here,
-- idempotent). The views read their base tables with their owner's (tp_owner's) rights, so cis_app needs nothing on
-- the tables.
--
-- Applied through AA-CIS-Infra DB Migrate from the byte-identical copy
-- db/migrations/tripplanner/020_ops_data_coverage_views.sql, as tp_owner (the live owner of schema tripplanner since
-- tp-013, XD8). Never run it from a laptop. Re-runnable: CREATE OR REPLACE VIEW keeps the column lists; the REVOKE and
-- grants repeat. The guard raises (it never skips) when cis_app is missing.
-- Cost: a handful of counts over tables of < 1,000 rows each; one DISTINCT over add_component trip events.
-- Undo: DROP VIEW tripplanner.v_ops_data_totals, tripplanner.v_ops_pin_components, tripplanner.v_ops_component_id_map
-- (a later tp- file, after the CIS reader is gone); keep USAGE on the schema (tp-015 still needs it).

BEGIN;

DO $$
BEGIN
    IF current_user <> 'tp_owner' THEN
        RAISE EXCEPTION 'tp-020: expected to run as tp_owner (live owner of schema tripplanner), running as %', current_user;
    END IF;
    IF to_regrole('cis_app') IS NULL THEN
        RAISE EXCEPTION 'tp-020: role cis_app is missing (AA-CIS-Infra roles/001, rl-001)';
    END IF;
END $$;

CREATE OR REPLACE VIEW tripplanner.v_ops_data_totals AS
SELECT 'sessions'::text AS metric, count(*)::bigint AS n FROM tripplanner.sessions
UNION ALL
SELECT 'trip_drafts'::text, count(*)::bigint FROM tripplanner.trip_drafts
UNION ALL
SELECT 'trip_drafts_sent'::text, count(*)::bigint FROM tripplanner.trip_drafts WHERE status = 'sent'
UNION ALL
SELECT 'trips_with_events'::text, count(DISTINCT trip_id)::bigint FROM tripplanner.trip_events
UNION ALL
SELECT 'pin_events'::text, count(*)::bigint FROM tripplanner.trip_events WHERE event_type = 'add_component'
UNION ALL
SELECT 'pin_events_invalid_id'::text, count(*)::bigint FROM tripplanner.trip_events
 WHERE event_type = 'add_component'
   AND payload ? 'component_id'
   AND (payload->>'component_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
UNION ALL
SELECT 'component_id_map_rows'::text, count(*)::bigint FROM tripplanner.component_id_map
UNION ALL
SELECT 'customers'::text, count(*)::bigint FROM tripplanner.customers
UNION ALL
SELECT 'traveller_accounts'::text, count(*)::bigint FROM tripplanner.traveller_accounts
UNION ALL
SELECT 'outbox_rows'::text, count(*)::bigint FROM tripplanner.outbox
UNION ALL
SELECT 'narration_cache_rows'::text, count(*)::bigint FROM tripplanner.narration_cache;

COMMENT ON VIEW tripplanner.v_ops_data_totals IS
    'tp-020 (AA-992): TripPlanner row totals, aggregates only (metric, n). Contract ops.data_coverage.v1, read by AA-CIS-App /admin/data-coverage (role cis_app).';

CREATE OR REPLACE VIEW tripplanner.v_ops_pin_components AS
WITH pins AS (
    SELECT DISTINCT e.trip_id, lower(e.payload->>'component_id') AS cid
      FROM tripplanner.trip_events e
     WHERE e.event_type = 'add_component'
       AND e.payload ? 'component_id'
       AND (e.payload->>'component_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
)
SELECT p.cid AS component_id, count(*)::bigint AS trips
  FROM pins p
 GROUP BY p.cid;

COMMENT ON VIEW tripplanner.v_ops_pin_components IS
    'tp-020 (AA-992): one row per pinned catalog component id (pins ever added, UUID-shaped ids only) and the number of trips that pinned it. Exposes only a UUID-shaped payload->>''component_id'' (a CIS catalog key, geo.tour_place.component_id) of trip_events: no trip id, session id or traveller text. Contract ops.data_coverage.v1, read by AA-CIS-App /admin/data-coverage (role cis_app).';

CREATE OR REPLACE VIEW tripplanner.v_ops_component_id_map AS
SELECT m.old_id::text AS old_id, m.new_id::text AS new_id
  FROM tripplanner.component_id_map m;

COMMENT ON VIEW tripplanner.v_ops_component_id_map IS
    'tp-020 (AA-992): the component id map edges (old_id -> new_id), catalog ids only, so CIS can walk a pin to its component the way TripPlanner does (map first, then the CIS redirect, <= 5 hops). Contract ops.data_coverage.v1, read by AA-CIS-App /admin/data-coverage (role cis_app).';

-- Runtime role tripplanner: read-only on the views (default privileges FOR ROLE tp_owner gave it DML).
REVOKE INSERT, UPDATE, DELETE, TRUNCATE
    ON tripplanner.v_ops_data_totals, tripplanner.v_ops_pin_components, tripplanner.v_ops_component_id_map
  FROM tripplanner;

-- The CIS reader (contract grant; AA-CIS-Infra db/owners.yaml tripplanner.consumer_grants).
GRANT USAGE ON SCHEMA tripplanner TO cis_app;
GRANT SELECT ON tripplanner.v_ops_data_totals, tripplanner.v_ops_pin_components, tripplanner.v_ops_component_id_map
   TO cis_app;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('tp-020', now(), 'AA-992: data coverage contract views tripplanner.v_ops_data_totals, v_ops_pin_components, v_ops_component_id_map, SELECT to cis_app')
ON CONFLICT (version) DO NOTHING;

COMMIT;
