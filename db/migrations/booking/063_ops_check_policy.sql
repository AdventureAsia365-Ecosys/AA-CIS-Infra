-- Migration bk-063: AA-1171 (S287, alerts catalogue P0; tech lead decision D3 of the S287 alerting decision page) — the
-- thresholds of the Booking in-app job checks as pricing policy parameters.
--
-- Owner: AA-Booking (key bk-NNN). AA-CIS-Infra Migration Sync copies it byte for byte to
-- db/migrations/booking/063_ops_check_policy.sql and Migration Apply applies it on Dev as bk_owner once every job
-- table is idle (root ADR 0017a). Never run it from a laptop.
--
-- Why: the in-app checks that replaced the booking.job CloudWatch alarms (S263, app/jobs/ops_checks.py and
-- app/jobs/metrics.py) used two code constants: a due job waiting more than 900 s while no healthy job runs is
-- "stuck" (STUCK_AFTER_S), and a running job past 2 x its kind's expected time is "overdue" (kinds.OVERDUE_FACTOR).
-- The tech lead's rule (S279) makes every threshold an admin-editable value, and Booking keeps every one in
-- booking.pricing_policy (Pricing > Policy, maker-checker, versioned, audited; keys, types and approver:
-- backend/app/pricing/policy_params_ops.py, section "ops", approved by the administrator group). The code PR that
-- follows reads them (app.jobs.ops_checks / app.jobs.metrics) and lists them in the check registry the CIS alerts
-- catalogue reads (GET /booking/ops/checks).
--
-- What: version 1 of 2 new parameters, made by the migration ('seed:bk-063'), submitted, and approved, in force from
-- 2026-01-01 like the bk-050 / bk-056 / bk-059 / bk-061 seeds. The seeds are TODAY'S EFFECTIVE VALUES, so nothing
-- changes until staff change them on the page:
--   ops_jobs_stuck_after_s     900   (seconds)
--   ops_jobs_overdue_factor    "2"   (x the kind's expected seconds; a decimal is stored as a JSON string)
--
-- Class: contract (root ADR 0017 d3): config rows into existing tables. Migration-only PR first (MIG-4), then the code
-- PR raises readiness to bk-063. On Dev: Infra Migration Apply once every job table is idle (root ADR 0017a). The
-- running code before the code PR does not read these keys (app.pricing.policy_values ignores a key the code does not
-- know), so nothing it reads changes here.
-- DM-6.1: no personal data (policy values). DM-7.1: no new table.
-- Locks: row inserts only; lock_timeout 5s.
-- Re-runnable (the Integration Tests replay every file): ON CONFLICT DO NOTHING.
-- Number: owner main max + 1 (bk-062 on main). If it moves, renumber: file name, this header, the post-check, the
-- registration, the ids (…b63000…) and the tests that name it (git grep '063_' and 'bk-063').
-- Undo (a later bk- file, after the code is reverted): DELETE the seed:bk-063 events, then the versions.

BEGIN;

SET LOCAL lock_timeout = '5s';

-- ── 1. The new parameters, version 1 = today's effective values ──────────────────────────────────────────────────

INSERT INTO booking.pricing_policy (id, param_key, version_no, value, unit, effective_from, reason, created_by)
VALUES
    ('00000000-0000-4000-8000-0000b6300000', 'ops_jobs_stuck_after_s', 1, '900'::jsonb, 'seconds', DATE '2026-01-01',
     'AA-1171: the job queue stuck check threshold that was the code constant STUCK_AFTER_S.', 'seed:bk-063'),
    ('00000000-0000-4000-8000-0000b6300010', 'ops_jobs_overdue_factor', 1, '"2"'::jsonb, 'x expected', DATE '2026-01-01',
     'AA-1171: the running job overdue factor that was the code constant OVERDUE_FACTOR.', 'seed:bk-063')
ON CONFLICT DO NOTHING;

INSERT INTO booking.pricing_policy_events (id, policy_id, maker, event, actor)
SELECT e.id, p.id, p.created_by, 'submitted', p.created_by
FROM (VALUES ('00000000-0000-4000-8000-0000b6300001'::uuid, '00000000-0000-4000-8000-0000b6300000'::uuid),
             ('00000000-0000-4000-8000-0000b6300011'::uuid, '00000000-0000-4000-8000-0000b6300010'::uuid)) AS e (id, pid)
JOIN booking.pricing_policy p ON p.id = e.pid AND p.created_by = 'seed:bk-063'
ON CONFLICT DO NOTHING;

INSERT INTO booking.pricing_policy_events (id, policy_id, maker, event, actor)
SELECT e.id, p.id, p.created_by, 'approved', 'tech lead S279 (thresholds rule: seeded defaults)'
FROM (VALUES ('00000000-0000-4000-8000-0000b6300002'::uuid, '00000000-0000-4000-8000-0000b6300000'::uuid),
             ('00000000-0000-4000-8000-0000b6300012'::uuid, '00000000-0000-4000-8000-0000b6300010'::uuid)) AS e (id, pid)
JOIN booking.pricing_policy p ON p.id = e.pid AND p.created_by = 'seed:bk-063'
ON CONFLICT DO NOTHING;

-- ── 2. Post-check: both parameters have an approved version 1 ────────────────────────────────────────────────────

DO $$
DECLARE
    n integer;
BEGIN
    SELECT count(*) INTO n
    FROM booking.pricing_policy p
    JOIN booking.pricing_policy_events a ON a.policy_id = p.id AND a.event = 'approved'
    WHERE p.created_by IN ('seed:bk-063') AND p.version_no = 1;
    IF n <> 2 THEN
        RAISE EXCEPTION 'bk-063: % of the 2 new pricing policy parameters have an approved version 1', n
            USING HINT = 'A key already had a version 1 made by someone else; the seed must not overwrite it.';
    END IF;
END
$$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-063', now(), 'AA-1171: the Booking job check thresholds (ops_jobs_stuck_after_s, ops_jobs_overdue_factor) as pricing policy parameters')
ON CONFLICT (version) DO NOTHING;

COMMIT;
