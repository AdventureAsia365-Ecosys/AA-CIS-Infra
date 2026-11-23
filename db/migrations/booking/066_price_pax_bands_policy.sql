-- Migration bk-066: AA-1175 (S288, tech lead request from the business owner's group prices) — the group-size bands of
-- the computed price matrix as a pricing policy parameter (Pricing > Policy).
--
-- Owner: AA-Booking (key bk-NNN). AA-CIS-Infra Migration Sync copies it byte for byte to
-- db/migrations/booking/066_price_pax_bands_policy.sql and Migration Apply applies it on Dev as bk_owner once every
-- job table is idle (root ADR 0017a). Never run it from a laptop.
--
-- Why: the cost sheet (backend/app/catalog/cost_sheet.py) priced every computed matrix on bands fixed in code
-- (PAX_BANDS = 1, 2, 3-4, 5-6, 7-10, 11+; root ADR 0005 decision 3). The tech lead's rule (S278/S279) makes every
-- business policy value an admin-editable parameter, and the business owner prices groups on other bands (per person,
-- double occupancy: 2 pax, 4 pax, 5-7 pax, 8 pax and up to 10). Keys, type, range and approver group:
-- backend/app/pricing/pax_bands.py (type pax_bands, section "prices", approved by the pricing group). The code PR that
-- follows reads the bands in force on the recompute day instead of the constant.
--
-- What: one new parameter, price_pax_bands, with two versions made by the migration ('seed:bk-066'), both submitted
-- and approved, so the history is honest:
--   v1, in force from 2026-01-01: the bands the code used until now (an exact copy of the constant);
--     [[1,1],[2,2],[3,4],[5,6],[7,10],[11,null]]
--   v2, in force from 2026-11-23, replacing v1: the business owner's bands, 3 added as its own band (bands must be
--     contiguous from 1; a 3-4 band would be priced at 3 travellers and overcharge a party of 4) and an open top
--     band 11+ (priced at 11, so it never undercuts the 8-10 band, as the price per person falls with the party):
--     [[1,1],[2,2],[3,3],[4,4],[5,7],[8,10],[11,null]]
-- A band is [smallest party, largest party] and null = open (only the last band may be open).
-- Computed rows move only on the next recompute (the scheduled one, or Recompute prices on the tour): until then the
-- matrix keeps the rows computed on the old bands.
--
-- Class: contract (root ADR 0017 d3): config rows into existing tables. Migration-only PR first (MIG-4), then the code
-- PR raises readiness to bk-066. On Dev: Infra Migration Apply once every job table is idle (root ADR 0017a). The
-- running code before the code PR does not read this key (app.pricing.policy_values ignores a key the code does not
-- know), so nothing it prices changes here.
-- DM-6.1: no personal data (policy values). DM-7.1: no new table.
-- Locks: row inserts only; lock_timeout 5s.
-- Re-runnable (the Integration Tests replay every file): ON CONFLICT DO NOTHING.
-- Number: owner main max + 1 (bk-065 on main). If it moves, renumber: file name, this header, the post-check, the
-- registration, the ids (…b66000…) and the tests that name it (git grep '066_' and 'bk-066').
-- Undo (a later bk- file, after the code is reverted): DELETE the seed:bk-066 events, then the versions (v2 first).

BEGIN;

SET LOCAL lock_timeout = '5s';

-- ── 1. The new parameter: v1 = the code's old bands, v2 = the business owner's bands ─────────────────────────────

INSERT INTO booking.pricing_policy
    (id, param_key, version_no, value, unit, effective_from, reason, replaces_id, diff, created_by)
VALUES
    ('00000000-0000-4000-8000-0000b6600000', 'price_pax_bands', 1,
     '[[1, 1], [2, 2], [3, 4], [5, 6], [7, 10], [11, null]]'::jsonb, 'travellers', DATE '2026-01-01',
     'The group-size bands of the computed price matrix that were the code constant PAX_BANDS.',
     NULL, NULL, 'seed:bk-066'),
    ('00000000-0000-4000-8000-0000b6600010', 'price_pax_bands', 2,
     '[[1, 1], [2, 2], [3, 3], [4, 4], [5, 7], [8, 10], [11, null]]'::jsonb, 'travellers', DATE '2026-11-23',
     'The business owner''s group-size bands (2, 4, 5-7, 8-10 per person, double occupancy), with 3 on its'
     ' own and an open 11+ top band.',
     '00000000-0000-4000-8000-0000b6600000',
     '{"from": [[1, 1], [2, 2], [3, 4], [5, 6], [7, 10], [11, null]],'
     ' "to": [[1, 1], [2, 2], [3, 3], [4, 4], [5, 7], [8, 10], [11, null]]}'::jsonb,
     'seed:bk-066')
ON CONFLICT DO NOTHING;

INSERT INTO booking.pricing_policy_events (id, policy_id, maker, event, actor)
SELECT e.id, p.id, p.created_by, 'submitted', p.created_by
FROM (VALUES ('00000000-0000-4000-8000-0000b6600001'::uuid, '00000000-0000-4000-8000-0000b6600000'::uuid),
             ('00000000-0000-4000-8000-0000b6600011'::uuid, '00000000-0000-4000-8000-0000b6600010'::uuid)) AS e (id, pid)
JOIN booking.pricing_policy p ON p.id = e.pid AND p.created_by = 'seed:bk-066'
ON CONFLICT DO NOTHING;

INSERT INTO booking.pricing_policy_events (id, policy_id, maker, event, actor)
SELECT e.id, p.id, p.created_by, 'approved', e.actor
FROM (VALUES ('00000000-0000-4000-8000-0000b6600002'::uuid, '00000000-0000-4000-8000-0000b6600000'::uuid,
              'tech lead S288 (the bands the code used until bk-066)'),
             ('00000000-0000-4000-8000-0000b6600012'::uuid, '00000000-0000-4000-8000-0000b6600010'::uuid,
              'tech lead S288 (business owner group-size bands)')) AS e (id, pid, actor)
JOIN booking.pricing_policy p ON p.id = e.pid AND p.created_by = 'seed:bk-066'
ON CONFLICT DO NOTHING;

-- ── 2. Post-check: both versions are approved, v2 replaces v1 ────────────────────────────────────────────────────

DO $$
DECLARE
    n integer;
BEGIN
    SELECT count(*) INTO n
    FROM booking.pricing_policy p
    JOIN booking.pricing_policy_events a ON a.policy_id = p.id AND a.event = 'approved'
    WHERE p.param_key = 'price_pax_bands' AND p.created_by = 'seed:bk-066'
      AND ((p.version_no = 1 AND p.replaces_id IS NULL)
           OR (p.version_no = 2 AND p.replaces_id = '00000000-0000-4000-8000-0000b6600000'::uuid));
    IF n <> 2 THEN
        RAISE EXCEPTION 'bk-066: % of the 2 seeded price_pax_bands versions are approved', n
            USING HINT = 'The key already had a version 1 or 2 made by someone else; the seed must not overwrite it.';
    END IF;
END
$$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-066', now(), 'AA-1175: the group-size bands of the computed price matrix as the pricing policy parameter price_pax_bands')
ON CONFLICT (version) DO NOTHING;

COMMIT;
