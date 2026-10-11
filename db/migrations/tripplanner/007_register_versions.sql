-- Migration tp-007: AA-684 — TripPlanner migrations register in shared.schema_versions.
--
-- TripPlanner migrations 001-006 never registered, so nobody could tell from the DB which ones ran.
-- From now on every TripPlanner migration registers its own key with the `tp-` prefix
-- (AA-Ecosys docs/database/schema-ownership.md, rule 4 — CIS keeps plain numbers, so an unprefixed
-- `007` would collide with CIS 007 and silently not register).
--
-- Backfill: register tp-001 … tp-006 ONLY for the ones whose objects exist in this database, so a
-- missing step shows up as a missing row instead of a false record. Applied through AA-CIS-Infra
-- DB Migrate (owner `tripplanner`).

BEGIN;

DO $$
BEGIN
    IF to_regclass('tripplanner.trip_drafts') IS NOT NULL
       AND to_regclass('tripplanner.itinerary_components') IS NOT NULL THEN
        INSERT INTO shared.schema_versions (version, applied_at, description)
        VALUES ('tp-001', now(), 'backfill: tripplanner schema (components, customers, sessions, events, drafts)')
        ON CONFLICT (version) DO NOTHING;
    END IF;

    IF to_regclass('shared.destinations') IS NOT NULL THEN
        INSERT INTO shared.schema_versions (version, applied_at, description)
        VALUES ('tp-002', now(), 'backfill: shared.destinations (owner CIS since ADR 0002)')
        ON CONFLICT (version) DO NOTHING;
    END IF;

    IF to_regclass('tripplanner.tour_day') IS NOT NULL THEN
        INSERT INTO shared.schema_versions (version, applied_at, description)
        VALUES ('tp-003', now(), 'backfill: tripplanner.tour_day')
        ON CONFLICT (version) DO NOTHING;
    END IF;

    IF to_regclass('tripplanner.tour_graph_build') IS NOT NULL
       AND to_regclass('tripplanner.tour_junction') IS NOT NULL THEN
        INSERT INTO shared.schema_versions (version, applied_at, description)
        VALUES ('tp-004', now(), 'backfill: Tour Graph tables')
        ON CONFLICT (version) DO NOTHING;
    END IF;

    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'shared' AND table_name = 'destinations'
                  AND column_name = 'located_by') THEN
        INSERT INTO shared.schema_versions (version, applied_at, description)
        VALUES ('tp-005', now(), 'backfill: destinations.located_by / located_at')
        ON CONFLICT (version) DO NOTHING;
    END IF;

    IF EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'trip_events_type_chk'
                  AND pg_get_constraintdef(oid) LIKE '%add_day%') THEN
        INSERT INTO shared.schema_versions (version, applied_at, description)
        VALUES ('tp-006', now(), 'backfill: trip_events add_day / remove_day')
        ON CONFLICT (version) DO NOTHING;
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('tp-007', now(), 'AA-684: TripPlanner migrations register with the tp- prefix (+ backfill 001-006)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
