-- Migration bk-051: AA-1091 (S278) — the margins and the individual (FIT) cancellation scale the tech lead approved on
-- 2026-11-12, as new approved rows of the existing staff-data tables (root ADR 0005b decision 15, Q8 and the margin
-- question of the S278 pricing advisory section 7).
--
-- Owner: AA-Booking (key bk-NNN). AA-CIS-Infra Migration Sync copies it byte for byte to
-- db/migrations/booking/051_s278_margins_cancellation_scale.sql; on Dev it is applied as bk_owner (the live owner of
-- schema booking since bk-014) by Infra Migration Apply once every job table is idle (root ADR 0017a), or by a person
-- with DB Migrate apply. Never run it from a laptop.
--
-- What (rows only, no schema change):
--   1. booking.pricing_rules: a b2b rule (target margin 20 %, floor 12 %) and a fixed_departure rule (target 25 %,
--      floor 15 %), valid from 2026-11-12, margins on the selling price. Every other column (peak uplift, card fee,
--      RRP markup, child share, infant amount, early-booking days and points) is copied from the APPROVED rule of the
--      same channel in force on 2026-11-12 (the same pick as app/pricing/repository.py RULE_SQL), so only the margins
--      change; a pending staff draft or a future-dated row is never copied (maker-checker, ADR 0005 d8 / bk-007). Approved in booking.policy_approvals by 'tech lead S278'; created_by is NULL like
--      the bk-004 seed (it references booking.staff_users), which the bk-007 maker-checker trigger accepts. The rows the bk-004 seed and staff wrote stay: the
--      new row is in force from its date, the older ones become superseded (app/pricing/policy.py).
--   2. booking.cancellation_policies: the b2b default schedule for individual bookings, valid from 2026-11-12:
--      31 days or more before departure free, 30-22 days 10 %, 21-15 days 25 %, 14-8 days 50 %, 7-2 days 75 %, under
--      48 hours (0-1 day) 100 %. Approved by 'tech lead S278'. The bk-021 proposed default stays as history.
--   3. booking.settings b2b_quote_valid_hours: its description says it is retired. The quote validity is the pricing
--      policy parameter quote_validity_days (bk-050, Pricing > Policy); the code no longer reads this row. The row
--      stays (a delete is a destructive file and buys nothing).
-- Staff change any of these later on their pages (Pricing rules & FX, cancellation policies), with a second person.
--
-- Class: contract (root ADR 0017 d3): rows inserted into and updated in existing tables. A migration-only PR first
-- (MIG-4); no code waits for it (the code reads whatever rule is in force). On Dev: Infra Migration Apply once every job
-- table is idle (root ADR 0017a). Needs bk-007 (policy_approvals), bk-021 (cancellation policies), bk-048 (the early
-- booking columns of pricing_rules).
-- DM-6.1: no personal data; margins and fees are conf:commercial (existing column tags).
-- Locks: ROW EXCLUSIVE on pricing_rules, cancellation_policies, policy_approvals and settings for a moment.
-- Re-runnable (the integration tests replay every file): fixed ids with ON CONFLICT (id) DO NOTHING, the approval only
-- when its row exists, the description update is idempotent. A clash on (channel, valid_from) with a row someone else
-- wrote is NOT swallowed: the INSERT fails and the whole file rolls back (then pick a new date with the tech lead), and
-- the post-check fails the file when a row or its approval is missing.

BEGIN;

SET LOCAL lock_timeout = '5s';

-- ── 1. Margins ────────────────────────────────────────────────────────────────────────────────────────────────────

INSERT INTO booking.pricing_rules
    (id, channel, target_margin, floor_margin, peak_uplift_pts, card_fee_pct, valid_from, note, created_by,
     rrp_markup_pct, child_pct, infant_flat_usd, early_days, early_discount_pts)
SELECT s.id, s.channel, s.target, s.floor, r.peak_uplift_pts, r.card_fee_pct, DATE '2026-11-12', s.note,
       NULL, r.rrp_markup_pct, r.child_pct, r.infant_flat_usd, r.early_days,
       CASE WHEN r.early_discount_pts IS NULL THEN NULL ELSE least(r.early_discount_pts, s.target) END
FROM (VALUES
        ('00000000-0000-4000-8000-0000000b5101'::uuid, 'b2b', 0.2000, 0.1200,
         'S278: margin on the selling price, target 20 %, floor 12 % (approved by the tech lead 2026-11-12)'),
        ('00000000-0000-4000-8000-0000000b5102'::uuid, 'fixed_departure', 0.2500, 0.1500,
         'S278: margin on the selling price, target 25 %, floor 15 % (approved by the tech lead 2026-11-12)')
     ) AS s (id, channel, target, floor, note)
JOIN LATERAL (
    SELECT p.peak_uplift_pts, p.card_fee_pct, p.rrp_markup_pct, p.child_pct, p.infant_flat_usd, p.early_days,
           p.early_discount_pts
    FROM booking.pricing_rules p
    JOIN booking.policy_approvals a ON a.pricing_rule_id = p.id
    WHERE p.channel = s.channel AND p.valid_from <= DATE '2026-11-12'
    ORDER BY p.valid_from DESC, p.created_at DESC
    LIMIT 1
) r ON true
ON CONFLICT (id) DO NOTHING;

INSERT INTO booking.policy_approvals (entity_type, pricing_rule_id, approved_by, note)
SELECT 'pricing_rule', p.id, 'tech lead S278', 'S278 pricing policy, approved 2026-11-12'
FROM booking.pricing_rules p
WHERE p.id IN ('00000000-0000-4000-8000-0000000b5101', '00000000-0000-4000-8000-0000000b5102')
ON CONFLICT (pricing_rule_id) DO NOTHING;

-- ── 2. The individual (FIT) cancellation scale ────────────────────────────────────────────────────────────────────

INSERT INTO booking.cancellation_policies (id, channel, trip_plan_id, valid_from, title, tiers, note, created_by)
VALUES (
    '00000000-0000-4000-8000-0000000b5103', 'b2b', NULL, DATE '2026-11-12', 'B2B individual bookings (S278)',
    '[{"min_days": 31, "fee_pct": 0}, {"min_days": 22, "fee_pct": 10}, {"min_days": 15, "fee_pct": 25},
      {"min_days": 8, "fee_pct": 50}, {"min_days": 2, "fee_pct": 75}, {"min_days": 0, "fee_pct": 100}]'::jsonb,
    'S278: 30-22 days 10 %, 21-15 days 25 %, 14-8 days 50 %, 7 days to 48 hours 75 %, under 48 hours 100 %'
    ' (approved by the tech lead 2026-11-12)',
    NULL)
ON CONFLICT (id) DO NOTHING;

INSERT INTO booking.policy_approvals (entity_type, cancellation_policy_id, approved_by, note)
SELECT 'cancellation_policy', p.id, 'tech lead S278', 'S278 pricing policy, approved 2026-11-12'
FROM booking.cancellation_policies p
WHERE p.id = '00000000-0000-4000-8000-0000000b5103'
ON CONFLICT (cancellation_policy_id) DO NOTHING;

-- ── Post-check: the three rows exist and are approved, or the whole file fails ──────────────────────────────────
-- A channel without an approved rule in force on 2026-11-12 (nothing to copy the other columns from), or a staff row
-- already holding (channel, valid_from 2026-11-12) for a rule or the b2b default cancellation schedule, makes an
-- INSERT above add nothing or fail; this check turns the first case into a failure too, so bk-051 is never recorded
-- as applied while the old margins or the old scale stay in force.

DO $$
DECLARE
    n integer;
BEGIN
    SELECT (SELECT count(*) FROM booking.pricing_rules r
              JOIN booking.policy_approvals a ON a.pricing_rule_id = r.id
             WHERE r.id IN ('00000000-0000-4000-8000-0000000b5101', '00000000-0000-4000-8000-0000000b5102')
               AND r.valid_from = DATE '2026-11-12')
         + (SELECT count(*) FROM booking.cancellation_policies c
              JOIN booking.policy_approvals a ON a.cancellation_policy_id = c.id
             WHERE c.id = '00000000-0000-4000-8000-0000000b5103' AND c.valid_from = DATE '2026-11-12')
      INTO n;
    IF n <> 3 THEN
        RAISE EXCEPTION 'bk-051: % of the 3 approved S278 rows (2 pricing rules, 1 cancellation policy) exist', n
            USING HINT = 'A channel has no approved rule in force on 2026-11-12, or a row already holds that date.';
    END IF;
END
$$;

-- ── 3. The retired quote validity setting ─────────────────────────────────────────────────────────────────────────

UPDATE booking.settings
SET description = 'Retired (bk-051): the B2B quote validity is the pricing policy parameter quote_validity_days '
                  '(Pricing > Policy, bk-050); this row is no longer read.'
WHERE key IN ('b2b_quote_valid_hours') AND description NOT LIKE 'Retired (bk-051)%';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-051', now(), 'AA-1091: S278 margins (b2b 20/12, fixed_departure 25/15) and the FIT cancellation scale as approved rows, quote validity setting retired')
ON CONFLICT (version) DO NOTHING;

COMMIT;
