-- Migration bk-072: AA-1153 part 2 (Jira PR-30; S285 advisory r2 hotels B8, T10) — two pricing policy parameters for
-- hotel allotments and the two-way rate sheet (Pricing > Policy, section hotels).
--
-- Owner: AA-Booking (key bk-NNN). AA-CIS-Infra Migration Sync copies it byte for byte to
-- db/migrations/booking/072_allotment_rate_sheet_policy.sql and Migration Apply applies it on Dev as bk_owner once
-- every job table is idle (root ADR 0017a). Never run it from a laptop.
--
-- Why: the tech lead's rule (S279) makes every threshold, cap and default an admin-edited parameter, never a code
-- literal. Part 2 adds two such values:
--   allotment_release_days_default  7     (days) the release days an allotment term gets when the contract or the
--                                          rate sheet gives none: rooms (or seats) of the allotment not sold this
--                                          many days before the date go back to the supplier;
--   rate_sheet_max_rows             2000  (rows) the most rows one rate-sheet workbook holds, on import (rate rows,
--                                          Seasons, Hotel children and Inventory rows together, and again after a
--                                          season is expanded into its ranges) and on export (a contract with more
--                                          rows is refused, so an exported sheet always imports back). It was the
--                                          code constant MAX_ROWS of app.supply.rate_sheet (2000), copied here.
-- Keys, type, range and approver group: backend/app/pricing/policy_params_hotels.py (section hotels, approved by the
-- pricing group). The code PR that follows reads both (readiness bk-072).
--
-- What: one version 1 of each, made by the migration ('seed:bk-072'), submitted and approved by another actor.
-- Class: contract (root ADR 0017 d3): config rows into existing tables. Migration-only PR first (MIG-4), then the code
-- PR raises readiness to bk-072. On Dev: Infra Migration Apply once every job table is idle (root ADR 0017a). The
-- running code before the code PR does not read these keys (app.pricing.policy_values ignores a key the code does
-- not know), so nothing changes here.
-- DM-6.1: no personal data (policy values). DM-7.1: no new table.
-- Locks: row inserts only; lock_timeout 5s.
-- Re-runnable (the Integration Tests replay every file): ON CONFLICT DO NOTHING.
-- Number: owner main max + 1 (bk-071 on main). If it moves, renumber: file name, this header, the post-check, the
-- registration, the ids (…b72000…) and the tests that name it (git grep '072_' and 'bk-072').
-- Undo (a later bk- file, after the code is reverted): DELETE the seed:bk-072 events, then the versions.

BEGIN;

SET LOCAL lock_timeout = '5s';

-- ── 1. The two parameters, version 1 ─────────────────────────────────────────────────────────────────────────────

INSERT INTO booking.pricing_policy (id, param_key, version_no, value, unit, effective_from, reason, created_by)
VALUES
    ('00000000-0000-4000-8000-0000b7200000', 'allotment_release_days_default', 1, '7'::jsonb, 'days',
     DATE '2026-01-01',
     'AA-1153 (B8): the release days of an allotment term that names none (unsold units go back to the supplier).',
     'seed:bk-072'),
    ('00000000-0000-4000-8000-0000b7200010', 'rate_sheet_max_rows', 1, '2000'::jsonb, 'rows', DATE '2026-01-01',
     'AA-1153 (T10): the most rows one rate-sheet workbook holds on import and export (was the code constant).',
     'seed:bk-072')
ON CONFLICT DO NOTHING;

INSERT INTO booking.pricing_policy_events (id, policy_id, maker, event, actor)
SELECT (substr(p.id::text, 1, 35) || '1')::uuid, p.id, p.created_by, 'submitted', p.created_by
FROM booking.pricing_policy p
WHERE p.created_by = 'seed:bk-072' AND p.version_no = 1
ON CONFLICT DO NOTHING;

INSERT INTO booking.pricing_policy_events (id, policy_id, maker, event, actor)
SELECT (substr(p.id::text, 1, 35) || '2')::uuid, p.id, p.created_by, 'approved',
       'tech lead S279 (thresholds rule: seeded defaults, S285 hotel advisory)'
FROM booking.pricing_policy p
WHERE p.created_by = 'seed:bk-072' AND p.version_no = 1
ON CONFLICT DO NOTHING;

-- ── 2. Post-check: both parameters have an approved version 1 ────────────────────────────────────────────────────

DO $$
DECLARE
    n integer;
BEGIN
    SELECT count(DISTINCT p.param_key) INTO n
    FROM booking.pricing_policy p
    JOIN booking.pricing_policy_events a ON a.policy_id = p.id AND a.event = 'approved'
    WHERE p.version_no = 1 AND p.param_key IN ('allotment_release_days_default', 'rate_sheet_max_rows');
    IF n <> 2 THEN
        RAISE EXCEPTION 'bk-072: % of the 2 seeded parameters have an approved version 1', n
            USING HINT = 'The key already had a version 1 made by someone else; the seed must not overwrite it.';
    END IF;
END
$$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-072', now(), 'AA-1153 part 2: allotment release days default and rate-sheet row cap as pricing policy parameters')
ON CONFLICT (version) DO NOTHING;

COMMIT;
