-- Migration bk-059: AA-1128 B1 (S283 UI audit, root docs/audits/2026-11-17-S283-fe-audit/ section 6, Booking row 11)
-- — the season calendar step of the catalog sync gets its batch size and its catalog read timeout as pricing policy
-- parameters.
--
-- Owner: AA-Booking (key bk-NNN). AA-CIS-Infra Migration Sync copies it byte for byte to
-- db/migrations/booking/059_season_sync_policy.sql and Migration Apply applies it on Dev as bk_owner once every job
-- table is idle (root ADR 0017a). Never run it from a laptop.
--
-- Why: the catalog sync job (bk_trip_plan_sync) gives every trip plan without a season calendar the calendar of the
-- destination of its first day. On Dev that step never assigned one calendar: its batch query joined the CIS catalog
-- view for every plan before the LIMIT and ran past the 5 s statement timeout on every run, and the job still said
-- "succeeded". The code PR that follows picks the batch from booking.trip_plans alone and reads the catalog one plan
-- at a time, each read cut at a timeout. The tech lead's rule (S279) makes every batch size and timeout an
-- admin-editable value, so both numbers are parameters of booking.pricing_policy (Pricing > Policy, maker-checker,
-- versioned, audited; keys, types and ranges: backend/app/pricing/policy_params.py), section "operations",
-- approved by the administrator group.
--
-- What: version 1 of 2 new parameters, made by the migration ('seed:bk-059'), submitted, and approved, in force
-- from 2026-01-01 like the bk-050 and bk-056 seeds. Each seed is TODAY'S EFFECTIVE VALUE, so nothing changes until
-- staff change it on the page:
--   season_sync_batch_size            50 plans per run (the code constant CALENDAR_BATCH of app.catalog.trip_plan_sync)
--   season_sync_read_timeout_seconds  5 seconds per catalog read (the API pool command_timeout, app.db)
--
-- Class: contract (root ADR 0017 d3): config rows into existing tables. Migration-only PR first (MIG-4), then the
-- code PR raises readiness to bk-059. On Dev: Infra Migration Apply once every job table is idle (root ADR 0017a).
-- The running code before the code PR does not read these keys (app.pricing.policy_values ignores a key the code
-- does not know), so nothing it reads changes here.
-- DM-6.1: no personal data (policy values, conf:commercial). DM-7.1: no new table.
-- Locks: row inserts only; lock_timeout 5s.
-- Re-runnable (the Integration Tests replay every file): ON CONFLICT DO NOTHING.
-- Undo (a later bk- file, after the code is reverted): DELETE the seed:bk-059 events, then the versions.

BEGIN;

SET LOCAL lock_timeout = '5s';

-- ── 1. The new parameters, version 1 = today's effective value ───────────────────────────────────────────────────

INSERT INTO booking.pricing_policy (id, param_key, version_no, value, unit, effective_from, reason, created_by)
VALUES
    ('00000000-0000-4000-8000-0000000b5901', 'season_sync_batch_size', 1, '50'::jsonb, 'plans', DATE '2026-01-01',
     'AA-1128: the catalog sync gives at most 50 trip plans their season calendar per run (former code constant).',
     'seed:bk-059'),
    ('00000000-0000-4000-8000-0000000b5902', 'season_sync_read_timeout_seconds', 1, '5'::jsonb, 'seconds',
     DATE '2026-01-01',
     'AA-1128: one catalog read of the season calendar step is cut after 5 seconds (the API statement timeout).',
     'seed:bk-059')
ON CONFLICT DO NOTHING;

INSERT INTO booking.pricing_policy_events (id, policy_id, maker, event, actor)
SELECT ('00000000-0000-4000-8000-0000000b6' || right(p.id::text, 3))::uuid, p.id, p.created_by, 'submitted',
       p.created_by
FROM booking.pricing_policy p
WHERE p.created_by IN ('seed:bk-059')
ON CONFLICT DO NOTHING;

INSERT INTO booking.pricing_policy_events (id, policy_id, maker, event, actor)
SELECT ('00000000-0000-4000-8000-0000000b7' || right(p.id::text, 3))::uuid, p.id, p.created_by, 'approved',
       'tech lead S279 (thresholds rule: seeded defaults)'
FROM booking.pricing_policy p
WHERE p.created_by IN ('seed:bk-059')
ON CONFLICT DO NOTHING;

-- ── 2. Post-check: both parameters have an approved version 1 ────────────────────────────────────────────────────

DO $$
DECLARE
    n integer;
BEGIN
    SELECT count(*) INTO n
    FROM booking.pricing_policy p
    JOIN booking.pricing_policy_events a ON a.policy_id = p.id AND a.event = 'approved'
    WHERE p.created_by IN ('seed:bk-059') AND p.version_no = 1;
    IF n <> 2 THEN
        RAISE EXCEPTION 'bk-059: % of the 2 new pricing policy parameters have an approved version 1', n
            USING HINT = 'A key already had a version 1 made by someone else; the seed must not overwrite it.';
    END IF;
END
$$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-059', now(), 'AA-1128 B1: season calendar step of the catalog sync, batch size and catalog read timeout as pricing policy parameters')
ON CONFLICT (version) DO NOTHING;

COMMIT;
