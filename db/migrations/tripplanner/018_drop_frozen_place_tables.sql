-- Migration tp-018: AA-712 X4 — drop the frozen place tables of the first TripPlanner extraction pilot.
-- migrate: destructive
--
-- NEEDS APPROVAL AFTER THE DRY RUN (skill aa-cis-schema references/destructive-ops.md): apply only after Nghiệp has
-- seen the DRY RUN (AA-CIS-Infra db/scripts/aa712_frozen_tables_dry_run.py: rows, dependents, last writes) and said go.
--
-- Owner: AA-TripPlanner-Web (key tp-NNN). A byte-identical copy goes to AA-CIS-Infra
-- db/migrations/tripplanner/018_drop_frozen_place_tables.sql and is applied to Dev by the DB Migrate workflow
-- (check, then apply), as tp_owner (the live owner of schema tripplanner since tp-013, XD8). The `destructive`
-- header makes DB Migrate take a manual RDS snapshot first and refuse to apply without it (MIG-12).
--
-- Why. The place pipeline is CIS's (root ADR 0002 / 0007, AA-712): CIS builds places, stops and the tour graph in
-- schema geo and serves them through the catalog views. These eight tables were filled by this repo's former
-- offline extraction, frozen since AA-712 slice 6a (TP #75, 14/10/2026: writers removed), and unread since the
-- PLACES_SOURCE=cis flip (AA-847, 22/10/2026) plus the X4 removal of the legacy readers (TP "TripPlanner reads CIS
-- only through the catalog views"): no TripPlanner code reads them (guard backend/tests/test_extraction_ops.py),
-- no CIS code reads them (photo sync moved to geo.* in AA-860 X1 S15). Their data is CIS's to rebuild.
--
-- What.
--   1. Guards (RAISE, nothing changes):
--      * running as tp_owner;
--      * no object outside the eight depends on them (a view, a foreign key from another table, a rule): listed;
--      * no row was written after the freeze. The three tables with a write time must be older than
--        2026-10-16 00:00 UTC (slice 6a removed the writers on 14/10; one day of margin): a later row means a writer
--        is still alive somewhere, so stop and find it.
--   2. DROP TABLE IF EXISTS the eight tables in one statement (RESTRICT, the default: their indexes, the HNSW index
--      itinerary_components_embedding_idx and their foreign keys to shared.destinations go with them).
--   3. Register tp-018.
--   Kept: tripplanner.component_id_map (tp-017). It maps the old itinerary_components ids that trip_events of drafts
--   from before the flip still carry to catalog component ids; it has no foreign key to the dropped table.
--
-- Undo: none in SQL (the data is gone). Restore the tables from the RDS snapshot DB Migrate takes before the apply
-- (restore to a new instance, then pg_dump/pg_restore the eight tables as tp_owner), and revert the TripPlanner
-- readers (the PR before this one). Only needed if a decision to read the frozen pilot data again is ever made.
--
-- Locks: ACCESS EXCLUSIVE on the eight tables only (nobody reads them); lock_timeout 5s (DB Migrate default).
-- Re-runnable (test_replay_twice_pg.py): IF EXISTS everywhere; the write-time guard reads a table only when it exists.

BEGIN;

DO $$
DECLARE
    frozen   text[] := ARRAY['itinerary_components', 'tour_day', 'tour_stop', 'tour_graph_build', 'tour_graph_edge',
                             'tour_graph_node', 'tour_leg', 'tour_junction'];
    deps     text;
    last_at  timestamptz;
    cutoff   constant timestamptz := '2026-10-16 00:00:00+00';
BEGIN
    IF current_user <> 'tp_owner' THEN
        RAISE EXCEPTION 'tp-018: expected to run as tp_owner (live owner of schema tripplanner), running as %', current_user;
    END IF;

    -- objects outside the eight that depend on one of them (views, rules, foreign keys from other tables)
    SELECT string_agg(DISTINCT dep, ', ' ORDER BY dep) INTO deps
      FROM (
        SELECT v.oid::regclass::text AS dep
          FROM pg_depend d
          JOIN pg_rewrite r ON r.oid = d.objid AND d.classid = 'pg_rewrite'::regclass
          JOIN pg_class v ON v.oid = r.ev_class
         WHERE d.refobjid IN (SELECT to_regclass('tripplanner.' || t) FROM unnest(frozen) t)
           AND v.oid NOT IN (SELECT to_regclass('tripplanner.' || t) FROM unnest(frozen) t)
        UNION
        SELECT c.conrelid::regclass::text || ' (FK ' || c.conname || ')'
          FROM pg_constraint c
         WHERE c.contype = 'f'
           AND c.confrelid IN (SELECT to_regclass('tripplanner.' || t) FROM unnest(frozen) t)
           AND c.conrelid NOT IN (SELECT to_regclass('tripplanner.' || t) FROM unnest(frozen) t)
      ) x;
    IF deps IS NOT NULL THEN
        RAISE EXCEPTION 'tp-018: objects outside the frozen place tables depend on them: %', deps;
    END IF;

    -- no write after the freeze (only these three carry a write time)
    IF to_regclass('tripplanner.itinerary_components') IS NOT NULL THEN
        EXECUTE 'SELECT max(created_at) FROM tripplanner.itinerary_components' INTO last_at;
        IF last_at >= cutoff THEN
            RAISE EXCEPTION 'tp-018: tripplanner.itinerary_components has a row written at % (after the freeze)', last_at;
        END IF;
    END IF;
    IF to_regclass('tripplanner.tour_day') IS NOT NULL THEN
        EXECUTE 'SELECT max(extracted_at) FROM tripplanner.tour_day' INTO last_at;
        IF last_at >= cutoff THEN
            RAISE EXCEPTION 'tp-018: tripplanner.tour_day has a row extracted at % (after the freeze)', last_at;
        END IF;
    END IF;
    IF to_regclass('tripplanner.tour_graph_build') IS NOT NULL THEN
        EXECUTE 'SELECT max(built_at) FROM tripplanner.tour_graph_build' INTO last_at;
        IF last_at >= cutoff THEN
            RAISE EXCEPTION 'tp-018: tripplanner.tour_graph_build has a build at % (after the freeze)', last_at;
        END IF;
    END IF;
END $$;

DROP TABLE IF EXISTS tripplanner.itinerary_components, tripplanner.tour_day, tripplanner.tour_stop,
    tripplanner.tour_graph_build, tripplanner.tour_graph_edge, tripplanner.tour_graph_node, tripplanner.tour_leg,
    tripplanner.tour_junction;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('tp-018', now(), 'AA-712 X4: drop the frozen place tables (itinerary_components, tour_day, tour_stop, tour_graph_*, tour_leg, tour_junction)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
