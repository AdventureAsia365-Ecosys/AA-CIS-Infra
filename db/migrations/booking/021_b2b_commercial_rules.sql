-- Migration bk-021: AA-974 (CRM-B2b) — B2B commercial rules: cancellation-fee policies (maker-checker), B2B
-- cancellations, hold extension once, re-hold limit (root ADR 0005a decisions 3 and 4; contract booking.b2b.v1;
-- design v3 §3.4 Fix A3 / A8 / C2).
--
-- Owner: AA-Booking (key bk-NNN). A byte-identical copy goes to AA-CIS-Infra
-- db/migrations/booking/021_b2b_commercial_rules.sql and is applied to Dev by the DB Migrate workflow (check, then
-- apply), as bk_owner (the live owner of schema booking since bk-014). Never run it from a laptop.
--
-- Depends on bk-003 (staff_users), bk-005 (settings), bk-007 (policy_approvals), bk-009 (trip_plans), bk-002
-- (trip_cases), bk-019 (b2b_partners) and bk-020 (b2b_holds). Every grant names its table (no "ON ALL TABLES").
--
-- What it adds (docs/implementation-notes/AA-974.md):
--   * booking.cancellation_policies: the fee AA charges an agency when it cancels a confirmed B2B booking, as a
--     schedule by days before departure (tiers: min_days -> fee_pct of the booking's b2b price). One row per
--     (channel, trip plan or NULL = the channel default, valid_from); append-only like pricing_rules (a change is a
--     new row) and in force only once a second person approved it (policy_approvals, maker-checker, bk-007 pattern).
--     Not the supplier-side terms (supplier_contracts.cancellation_policy stays free text, ADR 0005a decision 4).
--   * booking.policy_approvals.cancellation_policy_id: approvals of those rows (entity_type cancellation_policy),
--     with its own maker-checker trigger (bk-007's function is left as it is).
--   * Seed: the default B2B policy (60+ days 0 %, 30-59 25 %, 15-29 50 %, 7-14 75 %, 0-6 100 %), approved as
--     seed:bk-021. PROPOSED DEFAULT, to confirm with Ms. Thu; change it with a new row + approval, not a migration.
--   * booking.b2b_cancellations: one row per cancelled B2B booking (POST /booking/b2b/v1/bookings/{id}/cancel): the
--     policy, days before departure, fee % and amounts in the quote currency, reason code, Idempotency-Key.
--     Append-only for role booking (SELECT, INSERT). No personal data.
--   * booking.b2b_holds: extended_at, extend_reason, extend_idempotency_key (extend once, POST /holds/{id}/extend;
--     extended_count is bk-020's), cancellation_policy_id (the policy locked when the hold was confirmed), and an
--     index for the re-hold count per (partner, proposal_ref) and day.
--   * Backfill: B2B holds confirmed before bk-021 get the seeded default policy locked (the only policy then).
--   * booking.settings rows b2b_hold_extend_hours = 72 and b2b_rehold_limit_per_day = 3 (policy data).
--
-- Locks: policy_approvals and b2b_holds take ACCESS EXCLUSIVE for the column adds and CHECK adds (small tables, a
-- short scan each). lock_timeout 5s: the apply fails rather than queueing behind the job worker.
-- Re-runnable (the Integration Tests replay every file): IF NOT EXISTS everywhere, DROP CONSTRAINT IF EXISTS before
-- each added CHECK, CREATE OR REPLACE for the function and trigger, seed rows ON CONFLICT DO NOTHING.

BEGIN;

SET LOCAL lock_timeout = '5s';

-- ── Cancellation-fee policies ────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.cancellation_policies (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    channel       TEXT NOT NULL DEFAULT 'b2b',
    trip_plan_id  UUID REFERENCES booking.trip_plans (id),
    valid_from    DATE NOT NULL,
    title         TEXT NOT NULL,
    tiers         JSONB NOT NULL,
    note          TEXT,
    created_by    TEXT REFERENCES booking.staff_users (cis_user_id),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT cancellation_policies_channel_chk CHECK (channel IN ('b2b')),
    CONSTRAINT cancellation_policies_title_chk CHECK (length(btrim(title)) BETWEEN 1 AND 120),
    CONSTRAINT cancellation_policies_note_chk CHECK (note IS NULL OR length(note) <= 500),
    CONSTRAINT cancellation_policies_tiers_chk CHECK (
        jsonb_typeof(tiers) = 'array'
        AND jsonb_array_length(tiers) BETWEEN 1 AND 20
        AND jsonb_path_exists(tiers, '$[*] ? (@.min_days == 0)')
        AND NOT jsonb_path_exists(
            tiers,
            '$[*] ? (!(exists(@.min_days) && @.min_days.type() == "number" && @.min_days >= 0'
            ' && @.min_days <= 730 && exists(@.fee_pct) && @.fee_pct.type() == "number" && @.fee_pct >= 0'
            ' && @.fee_pct <= 100))'))
);

CREATE UNIQUE INDEX IF NOT EXISTS cancellation_policies_scope_uq
    ON booking.cancellation_policies (channel, trip_plan_id, valid_from) NULLS NOT DISTINCT;

COMMENT ON TABLE booking.cancellation_policies IS
    'bk-021 (AA-974, ADR 0005a d4): fee schedule AA charges an agency for cancelling a confirmed B2B booking, by days before departure. trip_plan_id NULL = the channel default. Append-only; in force = the newest APPROVED row (policy_approvals) of the plan, else of the default, dated on or before the day.';
COMMENT ON COLUMN booking.cancellation_policies.title IS
    'conf:commercial; bk-021: staff label of the policy (no customer data).';
COMMENT ON COLUMN booking.cancellation_policies.note IS
    'conf:commercial; bk-021: staff note on the policy (no customer data).';
COMMENT ON COLUMN booking.cancellation_policies.tiers IS
    'bk-021: [{"min_days": n, "fee_pct": p}] — cancelling d days before departure costs the fee_pct of the tier with the largest min_days <= max(d, 0); a tier with min_days 0 is required; fee_pct never rises with more days (app check).';

-- ── Approvals of cancellation policies (maker-checker, bk-007 pattern) ───────

ALTER TABLE booking.policy_approvals
    ADD COLUMN IF NOT EXISTS cancellation_policy_id UUID
        REFERENCES booking.cancellation_policies (id) ON DELETE CASCADE;

CREATE UNIQUE INDEX IF NOT EXISTS policy_approvals_cancellation_policy_uq
    ON booking.policy_approvals (cancellation_policy_id);

ALTER TABLE booking.policy_approvals DROP CONSTRAINT IF EXISTS policy_approvals_entity_chk;
ALTER TABLE booking.policy_approvals ADD CONSTRAINT policy_approvals_entity_chk CHECK (
    (entity_type = 'pricing_rule' AND pricing_rule_id IS NOT NULL AND fx_rate_id IS NULL
        AND cancellation_policy_id IS NULL)
    OR (entity_type = 'fx_rate' AND fx_rate_id IS NOT NULL AND pricing_rule_id IS NULL
        AND cancellation_policy_id IS NULL)
    OR (entity_type = 'cancellation_policy' AND cancellation_policy_id IS NOT NULL AND pricing_rule_id IS NULL
        AND fx_rate_id IS NULL));

COMMENT ON COLUMN booking.policy_approvals.cancellation_policy_id IS
    'bk-021 (AA-974): the approved cancellation_policies row (entity_type cancellation_policy).';

CREATE OR REPLACE FUNCTION booking.cancellation_policy_maker_checker() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_maker TEXT;
BEGIN
    IF NEW.entity_type = 'cancellation_policy' THEN
        SELECT p.created_by INTO v_maker FROM booking.cancellation_policies p WHERE p.id = NEW.cancellation_policy_id;
        IF v_maker IS NOT NULL AND v_maker = NEW.approved_by THEN
            RAISE EXCEPTION 'the creator of a cancellation_policy row cannot approve it (maker-checker)'
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.cancellation_policy_maker_checker() IS
    'bk-021: refuses a policy_approvals row whose approver created the approved cancellation policy.';

CREATE OR REPLACE TRIGGER policy_approvals_cancellation_maker_checker
    BEFORE INSERT ON booking.policy_approvals
    FOR EACH ROW EXECUTE FUNCTION booking.cancellation_policy_maker_checker();

-- ── Seed: the default B2B policy (PROPOSED DEFAULT, to confirm with Ms. Thu) ──

INSERT INTO booking.cancellation_policies (id, channel, trip_plan_id, valid_from, title, tiers, note)
VALUES (
    '00000000-0000-4000-8000-0000000bc021', 'b2b', NULL, DATE '2026-10-01', 'B2B standard (proposed)',
    '[{"min_days": 60, "fee_pct": 0}, {"min_days": 30, "fee_pct": 25}, {"min_days": 15, "fee_pct": 50},
      {"min_days": 7, "fee_pct": 75}, {"min_days": 0, "fee_pct": 100}]'::jsonb,
    'bk-021 seed: proposed default, to confirm with Ms. Thu (AA-974)')
ON CONFLICT (id) DO NOTHING;

INSERT INTO booking.policy_approvals (entity_type, cancellation_policy_id, approved_by, note)
VALUES ('cancellation_policy', '00000000-0000-4000-8000-0000000bc021', 'seed:bk-021',
        'proposed default, to confirm with Ms. Thu')
ON CONFLICT (cancellation_policy_id) DO NOTHING;

-- ── B2B cancellations ────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.b2b_cancellations (
    id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    hold_id                UUID NOT NULL REFERENCES booking.b2b_holds (id),
    trip_case_id           UUID NOT NULL REFERENCES booking.trip_cases (id),
    partner_id             UUID NOT NULL REFERENCES booking.b2b_partners (id),
    m2m_client_id          TEXT NOT NULL,
    policy_id              UUID NOT NULL REFERENCES booking.cancellation_policies (id),
    reason_code            TEXT NOT NULL,
    idempotency_key        TEXT NOT NULL,
    departure_date         DATE NOT NULL,
    days_before_departure  INTEGER NOT NULL,
    fee_pct                NUMERIC(5, 2) NOT NULL,
    currency               CHAR(3) NOT NULL,
    total_b2b_price        NUMERIC(14, 2) NOT NULL,
    fee_amount             NUMERIC(14, 2) NOT NULL,
    refundable_amount      NUMERIC(14, 2) NOT NULL,
    cancelled_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT b2b_cancellations_hold_uq UNIQUE (hold_id),
    CONSTRAINT b2b_cancellations_trip_case_uq UNIQUE (trip_case_id),
    CONSTRAINT b2b_cancellations_client_chk CHECK (m2m_client_id ~ '^[A-Za-z0-9]{1,128}$'),
    CONSTRAINT b2b_cancellations_reason_chk CHECK (
        reason_code IN ('client_cancelled', 'agency_cancelled', 'departure_cancelled', 'other')),
    CONSTRAINT b2b_cancellations_key_chk CHECK (length(idempotency_key) BETWEEN 8 AND 200),
    CONSTRAINT b2b_cancellations_fee_pct_chk CHECK (fee_pct BETWEEN 0 AND 100),
    CONSTRAINT b2b_cancellations_currency_chk CHECK (currency ~ '^[A-Z]{3}$'),
    CONSTRAINT b2b_cancellations_amounts_chk CHECK (
        total_b2b_price >= 0 AND fee_amount >= 0 AND refundable_amount >= 0
        AND fee_amount + refundable_amount = total_b2b_price)
);

CREATE INDEX IF NOT EXISTS b2b_cancellations_partner_idx ON booking.b2b_cancellations (partner_id, cancelled_at DESC);

COMMENT ON TABLE booking.b2b_cancellations IS
    'bk-021 (AA-974): a cancelled B2B booking (POST /booking/b2b/v1/bookings/{id}/cancel) with the fee charged under its cancellation policy. Append-only. No personal data.';
COMMENT ON COLUMN booking.b2b_cancellations.days_before_departure IS
    'bk-021: departure_date (the trip case start) minus the UTC day of the cancel; negative after the start (the 0-day tier applies).';
COMMENT ON COLUMN booking.b2b_cancellations.fee_amount IS
    'bk-021: total_b2b_price x fee_pct / 100 in the quote currency, half-up to the currency unit (cent; whole VND).';

-- ── Holds: extend once, the policy locked at confirm, the re-hold count ──────

ALTER TABLE booking.b2b_holds
    ADD COLUMN IF NOT EXISTS extended_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS extend_reason TEXT,
    ADD COLUMN IF NOT EXISTS extend_idempotency_key TEXT,
    ADD COLUMN IF NOT EXISTS cancellation_policy_id UUID REFERENCES booking.cancellation_policies (id);

ALTER TABLE booking.b2b_holds DROP CONSTRAINT IF EXISTS b2b_holds_extend_chk;
ALTER TABLE booking.b2b_holds ADD CONSTRAINT b2b_holds_extend_chk CHECK (
    ((extended_count = 0) = (extended_at IS NULL))
    AND ((extended_at IS NULL) = (extend_reason IS NULL))
    AND ((extended_at IS NULL) = (extend_idempotency_key IS NULL))
    AND (extend_reason IS NULL OR extend_reason IN ('payment_claimed', 'client_recheck'))
    AND (extend_idempotency_key IS NULL OR length(extend_idempotency_key) BETWEEN 8 AND 200));

CREATE INDEX IF NOT EXISTS b2b_holds_proposal_day_idx ON booking.b2b_holds (partner_id, proposal_ref, created_at);

COMMENT ON COLUMN booking.b2b_holds.extended_at IS
    'bk-021 (AA-974): when the hold was extended (at most once; extended_count 1).';
COMMENT ON COLUMN booking.b2b_holds.extend_reason IS
    'bk-021: payment_claimed (bank-transfer claim) or client_recheck (contract ExtendRequest.reason).';
COMMENT ON COLUMN booking.b2b_holds.extend_idempotency_key IS
    'bk-021: the Idempotency-Key of the extend; a retry with it returns the hold, any other extend is 409 extend_limit.';
COMMENT ON COLUMN booking.b2b_holds.cancellation_policy_id IS
    'bk-021: the cancellation policy in force when the hold was confirmed; a later cancel charges by it.';

-- Backfill: a B2B hold confirmed before this migration (AA-973 code) has no locked policy. The seeded default is
-- the only policy that exists when this runs, so it is the one those bookings were made under; locking it now keeps
-- a policy approved later (even with a backdated valid_from) from changing their fee. Re-runnable (IS NULL only).
UPDATE booking.b2b_holds SET cancellation_policy_id = '00000000-0000-4000-8000-0000000bc021'
WHERE status = 'confirmed' AND cancellation_policy_id IS NULL;

-- ── Settings ─────────────────────────────────────────────────────────────────

INSERT INTO booking.settings (key, value, description) VALUES
    ('b2b_hold_extend_hours', '72'::jsonb, 'Hours a B2B hold gains on its one extension (POST /holds/{id}/extend), capped by the departure start (AA-974; policy data, proposed +72 h).'),
    ('b2b_rehold_limit_per_day', '3'::jsonb, 'Re-holds a partner may place per UTC day before 429 rehold_limit, counted per proposal ref and per departure (AA-974, Fix A3; policy data).')
ON CONFLICT (key) DO NOTHING;

-- ── Grants (per table) ───────────────────────────────────────────────────────

GRANT SELECT, INSERT ON booking.cancellation_policies TO booking;
GRANT SELECT, INSERT ON booking.b2b_cancellations TO booking;
GRANT EXECUTE ON FUNCTION booking.cancellation_policy_maker_checker() TO booking;

-- The schema's default privileges may have granted more on creation: both tables are append-only for the app.
REVOKE UPDATE, DELETE, TRUNCATE ON booking.cancellation_policies FROM booking;
REVOKE UPDATE, DELETE, TRUNCATE ON booking.b2b_cancellations FROM booking;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-021', now(), 'AA-974 (CRM-B2b): cancellation_policies (+ approvals, seed default B2B policy), b2b_cancellations, b2b_holds extend columns + cancellation_policy_id + re-hold index, settings b2b_hold_extend_hours, b2b_rehold_limit_per_day')
ON CONFLICT (version) DO NOTHING;

COMMIT;
