-- migrate: expand
--
-- Migration bk-034: AA-993 — index booking.trip_case_version_itinerary (source_tour_id), the one lookup of the
-- catalog lifecycle "affected trip cases" read that has no index.
--
-- Owner: AA-Booking (key bk-NNN). The first expand file of this repo (root ADR 0017): AA-CIS-Infra Migration Sync
-- copies it to db/migrations/booking/034_itinerary_source_tour_idx.sql and Migration Apply applies it on Dev as
-- bk_owner (the runner's role switch, live owner of schema booking since bk-014), with no hand step. Never run it from
-- a laptop.
--
-- Depends on bk-003 (booking.trip_case_version_itinerary and its source_tour_id column).
--
-- Why: app/catalog/lifecycle.py AFFECTED_CASES_SQL runs when a CIS tour is retired, paused or trashed
-- (bk_tour_lifecycle_pull) and lists the open trip cases that use the tour key in three ways: a TripPlanner leg
-- (trip_case_legs_tour_key_idx), the case's own key (trip_cases_source_idx), or an item of one of its versions,
-- `trip_case_version_itinerary.source_tour_id = $1`, which has no index: every lifecycle event scans the whole
-- itinerary table, which grows by one row per item per saved version (the fastest-growing trip case table). A partial
-- btree on the non-null keys turns the via_item EXISTS into an index probe; rows without a source tour (hotel and
-- service items) are left out.
--
-- Class: expand (ADR 0017 d3: a new non-unique index on an existing table, no other change). The table is small
-- (dump of 2026-10-29: ~4 rows), far below the 100k-row lock-risk limit, so a plain CREATE INDEX (SHARE lock for a
-- moment) in the normal transaction, not CONCURRENTLY. No DO block (opaque to the expand lint): the runner checks
-- the role. Readiness: backend/app/db.py requires bk-034, so Deploy Dev's schema-gate waits for this key (the
-- end-to-end proof of the expand auto-apply).
-- Re-runnable (the Integration Tests replay every file): IF NOT EXISTS + ON CONFLICT DO NOTHING.
-- Undo (a later bk- file): DROP INDEX IF EXISTS booking.trip_case_version_itinerary_source_tour_idx.

BEGIN;

SET LOCAL lock_timeout = '5s';

CREATE INDEX IF NOT EXISTS trip_case_version_itinerary_source_tour_idx
    ON booking.trip_case_version_itinerary (source_tour_id)
    WHERE source_tour_id IS NOT NULL;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-034', now(), 'AA-993: index trip_case_version_itinerary.source_tour_id (lifecycle affected cases)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
