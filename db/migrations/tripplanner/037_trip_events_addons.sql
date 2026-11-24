-- Migration tp-037: AA-1152 (S285 advisory PR-29 T6, Jira PR-29) — the trip log records the AA add-ons a traveller
-- ticks on a day card: two more trip event types, add_addon and remove_addon.
--
-- Class: contract (root ADR 0017 / 0017a). No directive line on purpose: it replaces the CHECK of an existing table
-- (tripplanner.trip_events_type_chk). Merge order MIG-4: this file ships in the AA-1152 migration-only PR with tp-036
-- (one batch, tp-036 first); the TripPlanner code PR (the day cards, the lead's day_plan[].addons) follows once both
-- are applied on Dev. On Dev, AA-CIS-Infra Migration Apply runs it in contract mode once every job table is idle
-- (byte-identical copy db/migrations/tripplanner/037_trip_events_addons.sql), as tp_owner, the live owner of schema
-- tripplanner since tp-013 (XD8). Never run it from a laptop.
--
-- Why: a ticked add-on must survive a reload and reach the agency with the lead (lead.submitted.v1 1.2
-- day_plan[].addons: the sv: component id and AA's name). The trip is event-sourced (tripplanner.trip_events, folded by
-- backend/assembly/events.py), like a pinned component or an added day, so a pick is an event too:
--   add_addon     payload {"day": <1..90>, "component_id": "sv:<uuid>", "title": "<AA's name, at most 300>"}
--   remove_addon  payload {"day": <1..90>, "component_id": "sv:<uuid>"}
-- No price in the payload (prices come from the agency's quote). No new personal data: the add-on is AA catalogue data;
-- the event row keeps the trip_events tags and retention (tp-016) and is erased with the tenant's trip_events (tp-031).
--
-- What:
--   1. guard: runs as tp_owner; the CHECK exists with the tp-006 list.
--   2. trip_events_type_chk replaced: the tp-006 list plus add_addon, remove_addon (DROP + ADD in one transaction; the
--      ADD validates the existing rows, which all hold a tp-006 type).
--   3. registration.
--
-- Deployed code: the running assembly Lambda never writes the new types; the code PR does (events.VALID_EVENTS).
-- Locks: ACCESS EXCLUSIVE on trip_events for the DROP / ADD (a scan of the table to validate); lock_timeout 5s.
-- Re-runnable (test_replay_twice_pg.py): DROP CONSTRAINT IF EXISTS + ADD, ON CONFLICT DO NOTHING.
-- Undo: a later tp- file restating the tp-006 list (contract), after the code no longer writes the types and no row
-- holds them.

BEGIN;

SET LOCAL lock_timeout = '5s';

-- 1. guard before any change

DO $$
BEGIN
    IF current_user <> 'tp_owner' THEN
        RAISE EXCEPTION 'tp-037: expected to run as tp_owner (live owner of schema tripplanner), running as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'trip_events_type_chk'
                    AND conrelid = 'tripplanner.trip_events'::regclass) THEN
        RAISE EXCEPTION 'tp-037: tripplanner.trip_events has no trip_events_type_chk (tp-006 is not applied)';
    END IF;
END $$;

-- 2. the event types

ALTER TABLE tripplanner.trip_events DROP CONSTRAINT IF EXISTS trip_events_type_chk;
ALTER TABLE tripplanner.trip_events ADD CONSTRAINT trip_events_type_chk CHECK (event_type IN (
    'add_component', 'remove_component', 'reorder', 'sent', 'add_day', 'remove_day', 'add_addon', 'remove_addon'
));

-- 3. registration

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('tp-037', now(), 'AA-1152: trip_events types add_addon / remove_addon (the AA add-ons ticked on a day card)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
