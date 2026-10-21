-- Migration tp-017: AA-847 (AA-712 slice 6c) — component id-map for the PLACES_SOURCE=cis flip.
--
-- Owner: AA-TripPlanner-Web (key tp-NNN). A byte-identical copy goes to AA-CIS-Infra
-- db/migrations/tripplanner/017_component_id_map.sql and is applied to Dev by the DB Migrate workflow (check, then
-- apply), as tp_owner (the live owner of schema tripplanner since tp-013, XD8). Never run it from a laptop.
--
-- Why (root ADR 0007 decision 10, design 03 §6.4): with PLACES_SOURCE=cis the readers serve the CIS catalog's
-- component ids (catalog.v_tour_component.component_id, stable uuid5 per source tour / day / name), not the frozen
-- tripplanner.itinerary_components ids. Trips drafted before the flip hold the old ids in trip_events (add, remove,
-- reorder), and a browser can still post an old id for one cache TTL after the flip (browse answers carry
-- cache-control public, max-age=1800). This table maps an old id to its catalog id; every assembly reader resolves
-- the ids it is given through it (backend/shared/component_ids.py) before reading the catalog views.
--
-- Filled once, right before the flip, by AA-CIS-Infra db/scripts/aa847_component_id_map_fill.py (DB Migrate
-- run-script: the master maps old tour keys to catalog source ids through raw_tours, then inserts under the
-- tripplanner role, ON CONFLICT DO NOTHING). Rows: (source, day, name) first, then (source, day, destination);
-- an old id with no match is not inserted (the pin drops from that draft; design §6.4, accepted on Dev).
--
-- Grants: the runtime role tripplanner reads it (assembly) and inserts (the fill, as tripplanner); no UPDATE /
-- DELETE (default privileges FOR ROLE tp_owner gave it DML: revoked here). No personal data (DM-6.1: ids only).
--
-- Re-runnable (test_replay_twice_pg.py replays every file twice): IF NOT EXISTS, repeated grants and revokes.
-- Undo: DROP TABLE tripplanner.component_id_map (a later tp- file, after the cis readers are gone).

BEGIN;

DO $$
BEGIN
    IF current_user <> 'tp_owner' THEN
        RAISE EXCEPTION 'tp-017: expected to run as tp_owner (live owner of schema tripplanner), running as %', current_user;
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS tripplanner.component_id_map (
    old_id     uuid PRIMARY KEY,
    new_id     uuid NOT NULL,
    matched_by text NOT NULL CHECK (matched_by IN ('name', 'destination')),
    created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE tripplanner.component_id_map IS
    'tp-017 (AA-847): frozen itinerary_components.id -> catalog.v_tour_component.component_id, for drafts and cached browse answers from before PLACES_SOURCE=cis. Filled by AA-CIS-Infra aa847_component_id_map_fill.py.';

REVOKE UPDATE, DELETE, TRUNCATE ON tripplanner.component_id_map FROM tripplanner;
GRANT SELECT, INSERT ON tripplanner.component_id_map TO tripplanner;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('tp-017', now(), 'AA-847: tripplanner.component_id_map (frozen component id -> catalog component id)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
