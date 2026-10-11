-- Migration 216: AA-731 — TripPlanner reads atoms through the active-atom contract.
--
-- TripPlanner's component extraction (AA-TripPlanner-Web backend/extraction/components.py) read
-- acp_contract.tour_atoms directly (column grant, migration 180), so atoms of tours set
-- inactive/trashed in Master Content kept producing pinnable itinerary_components.
-- acp_contract.v_active_tour_atoms (migration 203) is the one active-atom source; give the
-- `tripplanner` role the same columns on the view. Least privilege as in 180 (no editorial fields).
-- The 180 grant on the table stays until TripPlanner no longer reads the table anywhere.
--
-- Additive. Apply before the TripPlanner change that reads the view is deployed.

BEGIN;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'tripplanner') THEN
        GRANT SELECT (atom_id, tour_id, owner_scope, itinerary_day, place, activity_type, action, text,
                      season_note, deleted, is_empty_marker)
            ON acp_contract.v_active_tour_atoms TO tripplanner;
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('216', now(), 'AA-731: tripplanner may read v_active_tour_atoms place/activity columns')
ON CONFLICT (version) DO NOTHING;

COMMIT;
