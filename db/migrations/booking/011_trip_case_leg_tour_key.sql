-- Migration bk-011: AA-830 — catalog tour key on trip case legs (data standards X3, DM-2.2; S237 decision E7).
--
-- Owner: AA-Booking (key bk-NNN). A byte-identical copy goes to AA-CIS-Infra
-- db/migrations/booking/011_trip_case_leg_tour_key.sql and is applied to Dev by the DB Migrate workflow (check, then
-- apply), as aa_cis_admin. Never run it from a laptop.
--
-- Depends on bk-002 (booking.trip_case_legs) only.
--
-- Why: a leg's source_tour_id (bk-002) holds whatever TripPlanner keyed the tour by, which is a catalog source_id for
-- some tours and a version tour_id for others; the tour_id changes on every CIS re-upload, so a leg can silently point
-- at a superseded tour and nothing can check it. Contract inquiry.submitted v1.2 adds the catalog key
-- (source_system, source_id) of contract catalog.tour.v1 per leg; this file adds the same two columns here.
--
--   * Nullable: legs opened before v1.2, and legs whose key could not be resolved against catalog.v_tour (the tour left
--     the catalog), have none. bk_inquiry_process fills them for every new leg (from the v1.2 payload, else by
--     resolving source_tour_id against catalog.v_tour); existing legs are back-filled by
--     `python -m app.inquiry.leg_keys` (DRY RUN by default, run in the Booking task, AA-830 implementation notes).
--   * Both set or both null (CHECK); source_system is 'cis' only (catalog.v_tour.source_system).
--   * No FK across schemas (role booking has SELECT on the catalog views, not REFERENCES; data standards DM-2.3): the
--     nightly schema dump reports legs whose key is not in catalog.v_tour (orphan rate, DM-4.2).
--   * source_tour_id stays NOT NULL and unchanged (compatibility with v1 / v1.1 payloads and existing readers).
--
-- The new columns are written by role booking through its existing UPDATE grant on the table (bk-002); no grant change.
-- Re-running the whole file is a no-op (IF NOT EXISTS, guarded constraint, ON CONFLICT DO NOTHING).

BEGIN;

ALTER TABLE booking.trip_case_legs
    ADD COLUMN IF NOT EXISTS source_system TEXT,
    ADD COLUMN IF NOT EXISTS source_id TEXT;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_constraint
        WHERE conname = 'trip_case_legs_tour_key_chk' AND conrelid = 'booking.trip_case_legs'::regclass
    ) THEN
        -- coalesce: a CHECK passes on NULL, so a half-null pair must evaluate to false, not unknown.
        ALTER TABLE booking.trip_case_legs ADD CONSTRAINT trip_case_legs_tour_key_chk CHECK (
            (source_system IS NULL AND source_id IS NULL)
            OR coalesce(source_system = 'cis' AND length(btrim(source_id)) BETWEEN 1 AND 128, false)
        );
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS trip_case_legs_tour_key_idx
    ON booking.trip_case_legs (source_system, source_id);

COMMENT ON COLUMN booking.trip_case_legs.source_tour_id IS
    'bk-002: the tour key as TripPlanner sent it (a catalog source_id or a version tour_id). Do not join on it; use source_system + source_id (bk-011).';
COMMENT ON COLUMN booking.trip_case_legs.source_system IS
    'bk-011 (AA-830): catalog key system of the leg''s tour, ''cis'' (catalog.v_tour.source_system); null with source_id when unresolved.';
COMMENT ON COLUMN booking.trip_case_legs.source_id IS
    'bk-011 (AA-830): stable catalog tour key (catalog.v_tour.source_id, contract catalog.tour.v1); soft key, no FK; orphans reported by the nightly dump (DM-4.2).';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-011', now(), 'AA-830: booking.trip_case_legs + source_system / source_id (catalog tour key of inquiry.submitted v1.2, nullable, both or neither, cis only), index, back-filled by app.inquiry.leg_keys')
ON CONFLICT (version) DO NOTHING;

COMMIT;
