-- Migration bk-075: AA-1128 follow-up (S290 capacity review C4.3 W48, root
-- docs/audits/2026-11-24-S290-session/c43-w48/README.md finding 6) — the season calendar step of the catalog sync
-- remembers what it found per trip plan, and the recheck interval is a pricing policy parameter.
--
-- Owner: AA-Booking (key bk-NNN). AA-CIS-Infra Migration Sync copies it byte for byte to
-- db/migrations/booking/075_season_sync_checks.sql and Migration Apply applies it on Dev as bk_owner once every job
-- table is idle (root ADR 0017a). Never run it from a laptop.
--
-- Why: bk_trip_plan_sync gives a trip plan without a season calendar the calendar of its first day's destination,
-- reading the CIS catalog one plan at a time (AA-1128 B1, bk-059). A plan whose tour is not in the catalog or whose
-- first day names no destination was picked again on every run (the salt only rotates the order): since 18/11 the
-- step read catalog.v_tour 29,200 times and only 650 reads found a destination. The code PR that follows records
-- such an outcome per plan and picks the plan again only after the recheck interval, or earlier when CIS sent a
-- lifecycle event for its tour (booking.inbox_events, contract catalog.tour) after the check.
--
-- What:
--   1. booking.season_sync_checks: one row per trip plan the step could not give a calendar: outcome no_tour (the
--      plan's tour is not in catalog.v_tour) or no_destination (its first day names no destination), the CIS tour id
--      when found, and when it was checked. Written and deleted by the job only (role booking); a plan that gets a
--      calendar loses its row. Derived state: no personal data, rebuilt by the next runs if emptied.
--   2. Pricing policy parameter season_sync_recheck_days version 1 = 7 (days; section operations, approver group
--      admin, like season_sync_batch_size), made by the migration ('seed:bk-075'), submitted, and approved, in force
--      from 2026-01-01 like the bk-059 seeds. The tech lead's rule (S279) makes every interval an admin-editable value.
--
-- Class: contract (root ADR 0017 d3: config rows into an existing table, plus a new table). Migration-only PR first
-- (MIG-4), then the code PR raises readiness to bk-075. The running code before the code PR never reads the table
-- and ignores the new key (app.pricing.policy_values ignores a key the code does not know), so nothing changes here.
-- DM-6.1: no personal data (ids, an outcome code, a time; policy values conf:commercial). DM-7.1: the new table has
-- its row in the root data standards (root PR merged before the Infra copy).
-- Locks: a new table; row inserts only; lock_timeout 5s.
-- Re-runnable (the Integration Tests replay every file): CREATE TABLE / INDEX IF NOT EXISTS, ON CONFLICT DO NOTHING.
-- Number: owner main max + 1 (bk-074 on main). If it moves, renumber: file name, this header, the post-check, the
-- registration, the ids (…b75000…) and the tests that name it (git grep '075_' and 'bk-075').
-- Undo (a later bk- file, after the code is reverted): DROP TABLE booking.season_sync_checks (derived state only);
-- DELETE the seed:bk-075 events, then the version.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF to_regclass('booking.trip_plans') IS NULL OR to_regclass('booking.pricing_policy') IS NULL THEN
        RAISE EXCEPTION 'bk-075: needs booking.trip_plans and booking.pricing_policy first';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.schema_versions
                WHERE version = 'bk-075' AND description NOT LIKE 'AA-1128 %') THEN
        RAISE EXCEPTION 'bk-075: the key bk-075 is already held by another migration (not AA-1128): renumber one';
    END IF;
END $$;

-- ── 1. What the season calendar step found per trip plan ─────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.season_sync_checks (
    trip_plan_id  uuid PRIMARY KEY REFERENCES booking.trip_plans (id) ON DELETE CASCADE,
    outcome       text NOT NULL,
    tour_id       uuid,
    checked_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT season_sync_checks_outcome_chk CHECK (outcome IN ('no_tour', 'no_destination')),
    CONSTRAINT season_sync_checks_tour_chk CHECK ((outcome = 'no_tour') = (tour_id IS NULL))
);

CREATE INDEX IF NOT EXISTS season_sync_checks_checked_idx ON booking.season_sync_checks (checked_at);

COMMENT ON TABLE booking.season_sync_checks IS
    'bk-075 (AA-1128 follow-up, S290 C4.3 finding 6): one row per trip plan the season calendar step of '
    'bk_trip_plan_sync could not give a calendar (its tour is not in catalog.v_tour, or its first day names no '
    'destination) and when it checked. The step picks the plan again after the pricing policy value '
    'season_sync_recheck_days, or earlier when a CIS lifecycle event for its tour arrived after checked_at; a plan that '
    'gets a calendar loses its row. Derived state, written by the job only; no personal data.';
COMMENT ON COLUMN booking.season_sync_checks.outcome IS
    'bk-075: no_tour (the plan''s tour is not in catalog.v_tour: paused or retired in CIS) or no_destination (its '
    'first day names no destination).';
COMMENT ON COLUMN booking.season_sync_checks.tour_id IS
    'bk-075: the CIS tour id (catalog.v_tour.tour_id) read at the check, for no_destination; NULL for no_tour.';

GRANT SELECT, INSERT, UPDATE, DELETE ON booking.season_sync_checks TO booking;

-- ── 2. The recheck interval, version 1 ───────────────────────────────────────────────────────────────────────────

INSERT INTO booking.pricing_policy (id, param_key, version_no, value, unit, effective_from, reason, created_by)
VALUES
    ('00000000-0000-4000-8000-0000b7500000', 'season_sync_recheck_days', 1, '7'::jsonb, 'days', DATE '2026-01-01',
     'AA-1128: a trip plan the season calendar step could not give a calendar is read from the catalog again after '
     '7 days (or earlier on a CIS lifecycle event of its tour).',
     'seed:bk-075')
ON CONFLICT DO NOTHING;

INSERT INTO booking.pricing_policy_events (id, policy_id, maker, event, actor)
SELECT (substr(p.id::text, 1, 35) || '1')::uuid, p.id, p.created_by, 'submitted', p.created_by
FROM booking.pricing_policy p
WHERE p.created_by = 'seed:bk-075' AND p.version_no = 1
ON CONFLICT DO NOTHING;

INSERT INTO booking.pricing_policy_events (id, policy_id, maker, event, actor)
SELECT (substr(p.id::text, 1, 35) || '2')::uuid, p.id, p.created_by, 'approved',
       'tech lead S279 (thresholds rule: seeded defaults)'
FROM booking.pricing_policy p
WHERE p.created_by = 'seed:bk-075' AND p.version_no = 1
ON CONFLICT DO NOTHING;

-- ── 3. Post-check: the parameter has an approved version 1 ───────────────────────────────────────────────────────

DO $$
DECLARE
    n integer;
BEGIN
    SELECT count(DISTINCT p.param_key) INTO n
    FROM booking.pricing_policy p
    JOIN booking.pricing_policy_events a ON a.policy_id = p.id AND a.event = 'approved'
    WHERE p.version_no = 1 AND p.param_key IN ('season_sync_recheck_days');
    IF n <> 1 THEN
        RAISE EXCEPTION 'bk-075: % of the 1 seeded parameter has an approved version 1', n
            USING HINT = 'The key already had a version 1 made by someone else; the seed must not overwrite it.';
    END IF;
END
$$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-075', now(), 'AA-1128 season calendar step: per-plan check outcomes and the recheck interval as a pricing policy parameter')
ON CONFLICT (version) DO NOTHING;

COMMIT;
