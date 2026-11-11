-- Migration bk-047: AA-1075 (Booking ops; S275 study root docs/research/2026-11-10-odoo-tour-travel-plugin-comparison.md
-- items bk-11, bk-12, bk-13 step 1, bk-14, bk-15, bk-18) — staff-entered agency bookings, voucher fields on supplier
-- bookings, cancellation override / waive and partial cancellation, child / infant / single-supplement net prices, and
-- per-tour deposit and balance terms.
--
-- Owner: AA-Booking (key bk-NNN). AA-CIS-Infra Migration Sync copies it byte for byte to
-- db/migrations/booking/047_agency_desk_vouchers_cancel_child_terms.sql; on Dev it is applied as bk_owner (the live owner
-- of schema booking since bk-014) by Infra Migration Apply once every job table is idle (root ADR 0017a), or by a person
-- with DB Migrate apply. Never run it from a laptop.
--
-- What:
--   1. Staff-entered bookings (bk-11). booking.trip_cases gains entered_via ('api' = the agency's CRM through the
--      booking.b2b.v1 API, the default; 'staff' = AA staff keyed it in for the agency) and entered_by (the staff key,
--      only with 'staff'). New booking.b2b_desk_bookings: one row per booking staff enter on behalf of an agency (the
--      quote, hold and trip case it made, the rule price, the floor price and an optional price override with its
--      reason). A price below the floor waits for a second staff member (maker-checker: decided_by <> entered_by).
--      The outbox gets booking.created_by_aa: b2b_holds_outbox also emits it when a hold whose trip case was entered
--      by staff is confirmed (before the line.confirmed events of the same transaction), so the agency's CRM imports
--      the booking.
--   2. Vouchers (bk-12). booking.supplier_bookings gains service_time, pickup_point, dropoff_point, voucher_note (what
--      a generated agency voucher prints; never traveller names) and supplier_cancel_fee + currency (what the supplier
--      charges for a cancel, recorded when the supplier answers; feeds the profit views).
--   3. Cancellation override / waive (bk-14). booking.b2b_cancellations gains entered_via / entered_by (staff cancel
--      for an e-mailed request), fee_override_pct, waive_reason, override_by / _at, override_approved_by / _at
--      (maker-checker). The fee and refundable amounts change only when a second staff member approves a lower fee
--      (guard trigger); the change emits booking.fee_changed.
--   4. Partial cancellation (bk-14). New booking.b2b_line_reductions: fewer travellers on one line of a confirmed
--      booking, the fee by the booking's policy on the removed seats. Append-only; emits booking.line_reduced. The
--      reduction row is the amendment record: the approved version stays as sold (bk-003 locks an approved version and
--      allows one per case), and the case total reads as the version total less the refundable amounts.
--   5. Child, infant and single-supplement prices (bk-15). booking.trip_plan_prices gains child_amount,
--      infant_amount, single_supplement_amount and their nets (per person, in the row's currencies);
--      booking.trip_plans gains child_age_max and infant_age_max; booking.pricing_rules gains child_pct (a child pays
--      this fraction of the adult price) and infant_flat_usd (net per infant per trip).
--   6. Per-tour deposit and balance terms (bk-18). New booking.trip_plan_billing_terms: deposit % and balance days for
--      one trip plan, for every agency (party_tenant_id NULL) or one agency. The settlement draft and GET /terms take
--      the most specific of agency + tour > tour > agency > default (booking.billing_terms keeps the last two). A
--      separate table, not a trip_plan_id column on billing_terms: the agency status view (bk-042, read by CIS) and the
--      reminder job read billing_terms per agency and would see tour rows as agency rows.
--   7. Views (CREATE OR REPLACE, same columns): v_cost_variance counts a recorded supplier cancel fee as the cost of a
--      cancelled, unbilled supplier booking; v_case_profit takes partial cancellations into the revenue (removed
--      seats leave it, their fee stays) and the recorded cancel fees into supplier_cancel_fee_usd.
--   8. Settings b2b_ops_contact (empty), b2b_child_age_max (11) and b2b_infant_age_max (1).
--
-- Class: contract (root ADR 0017 d3): ALTER TABLE on trip_cases, supplier_bookings, b2b_cancellations,
-- trip_plan_prices, trip_plans, pricing_rules; outbox CHECKs and b2b_holds_outbox replaced; views replaced; next to
-- three new tables. So a migration-only PR first (MIG-4); the code PR raises readiness to bk-047. On Dev: Infra
-- Migration Apply once every job table is idle (root ADR 0017a). Needs bk-019..bk-022 (B2B, outbox), bk-026
-- (supplier bookings), bk-032 / bk-039 (price matrix), bk-041 (billing_terms) and bk-045 (views).
-- DM-7.1 rows for the three new tables: root docs/architecture/data-standards/02-data-management.md (AA-1075 root PR,
-- merged before the Infra copy). DM-6.1: override and agency amounts conf:commercial; waive_reason, override_reason and
-- voucher_note pii:free_text (staff text; never traveller data by rule, tagged in case); no traveller name anywhere.
-- Erasure (DM-6.7): the two guard triggers allow one move on any row, override_reason / waive_reason set to the
-- fixed marker '[redacted]' with every other column unchanged; it runs as bk_owner in a reviewed DB Migrate
-- run-script (root docs/legal/dsar-erasure-runbook.md), the app role gets no new grant for it.
--
-- Locks: ACCESS EXCLUSIVE for the nullable / constant-default ADD COLUMNs (no rewrite) and CHECK adds on trip_cases,
-- supplier_bookings, b2b_cancellations, trip_plan_prices, trip_plans, pricing_rules (tens to hundreds of rows) and the
-- outbox CHECK replace; SHARE ROW EXCLUSIVE on the FK targets for a moment. lock_timeout 5s.
-- Key guard: refuses to run when shared.schema_versions already holds bk-047 with another description.
-- Re-runnable (the integration tests replay every file): IF NOT EXISTS, DROP CONSTRAINT / TRIGGER IF EXISTS before each
-- ADD / CREATE, CREATE OR REPLACE FUNCTION / VIEW, grants repeat.
-- Undo (a later bk- file, after the code is reverted): DROP the three new tables and their functions, DROP the added
-- columns and CHECKs, restore the bk-046 outbox CHECKs and the bk-022 b2b_holds_outbox body (outbox rows of the three
-- new types deleted first), restore the bk-045 view bodies.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF current_user <> 'bk_owner' THEN
        RAISE EXCEPTION 'bk-047: expected to run as bk_owner (live owner of schema booking), running as %', current_user;
    END IF;
    IF to_regclass('booking.b2b_cancellations') IS NULL OR to_regclass('booking.outbox') IS NULL
       OR to_regclass('booking.supplier_bookings') IS NULL OR to_regclass('booking.billing_terms') IS NULL
       OR to_regclass('booking.v_case_profit') IS NULL OR to_regclass('booking.departure_allotments') IS NULL
    THEN
        RAISE EXCEPTION 'bk-047: needs bk-021, bk-022, bk-026, bk-041, bk-045 and bk-046 first';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.schema_versions
                WHERE version = 'bk-047' AND description NOT LIKE 'AA-1075:%') THEN
        RAISE EXCEPTION 'bk-047: the key bk-047 is already held by another migration (not AA-1075 booking ops): renumber one';
    END IF;
END $$;

-- ── 1. Staff-entered bookings ────────────────────────────────────────────────

ALTER TABLE booking.trip_cases
    ADD COLUMN IF NOT EXISTS entered_via TEXT NOT NULL DEFAULT 'api',
    ADD COLUMN IF NOT EXISTS entered_by TEXT;

ALTER TABLE booking.trip_cases DROP CONSTRAINT IF EXISTS trip_cases_entered_chk;
ALTER TABLE booking.trip_cases ADD CONSTRAINT trip_cases_entered_chk CHECK (
    entered_via IN ('api', 'staff')
    AND (entered_via = 'staff') = (entered_by IS NOT NULL)
    AND (entered_via = 'api' OR channel = 'b2b')
    AND (entered_by IS NULL OR length(entered_by) BETWEEN 1 AND 128));

COMMENT ON COLUMN booking.trip_cases.entered_via IS
    'bk-047 (AA-1075, bk-11): how a B2B booking was entered: api = the agency''s CRM through booking.b2b.v1 (default), staff = AA staff keyed it in for the agency (POST /booking/b2b-desk/bookings). source_system stays crm.';
COMMENT ON COLUMN booking.trip_cases.entered_by IS
    'bk-047 (AA-1075, bk-11): the staff key (staff_users.cis_user_id) who entered a staff booking; NULL for api.';

CREATE TABLE IF NOT EXISTS booking.b2b_desk_bookings (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    partner_id       UUID NOT NULL REFERENCES booking.b2b_partners (id),
    agency_ref       TEXT NOT NULL,
    quote_id         UUID NOT NULL REFERENCES booking.b2b_quotes (id),
    hold_id          UUID NOT NULL REFERENCES booking.b2b_holds (id),
    trip_case_id     UUID REFERENCES booking.trip_cases (id),
    status           TEXT NOT NULL,
    currency         CHAR(3) NOT NULL,
    quoted_total     NUMERIC(14,2) NOT NULL,
    floor_total      NUMERIC(14,2) NOT NULL,
    override_total   NUMERIC(14,2),
    override_reason  TEXT,
    idempotency_key  TEXT NOT NULL,
    entered_by       TEXT NOT NULL,
    entered_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    decided_by       TEXT,
    decided_at       TIMESTAMPTZ,
    CONSTRAINT b2b_desk_bookings_quote_uq UNIQUE (quote_id),
    CONSTRAINT b2b_desk_bookings_hold_uq UNIQUE (hold_id),
    CONSTRAINT b2b_desk_bookings_key_uq UNIQUE (idempotency_key),
    CONSTRAINT b2b_desk_bookings_status_chk CHECK (status IN ('awaiting_approval', 'booked', 'rejected', 'lapsed')),
    CONSTRAINT b2b_desk_bookings_ref_chk CHECK (length(agency_ref) BETWEEN 1 AND 64),
    CONSTRAINT b2b_desk_bookings_currency_chk CHECK (currency ~ '^[A-Z]{3}$'),
    CONSTRAINT b2b_desk_bookings_amounts_chk CHECK (
        quoted_total >= 0 AND floor_total >= 0 AND floor_total <= quoted_total
        AND (override_total IS NULL OR override_total >= 0)),
    CONSTRAINT b2b_desk_bookings_override_chk CHECK (
        (override_total IS NULL) = (override_reason IS NULL)
        AND (override_reason IS NULL OR length(btrim(override_reason)) BETWEEN 1 AND 500)),
    -- Only a price below the floor waits for a second person.
    CONSTRAINT b2b_desk_bookings_waiting_chk CHECK (
        status <> 'awaiting_approval' OR (override_total IS NOT NULL AND override_total < floor_total)),
    CONSTRAINT b2b_desk_bookings_booked_chk CHECK ((status = 'booked') = (trip_case_id IS NOT NULL)),
    CONSTRAINT b2b_desk_bookings_key_chk CHECK (length(idempotency_key) BETWEEN 8 AND 200),
    CONSTRAINT b2b_desk_bookings_actor_chk CHECK (
        length(entered_by) BETWEEN 1 AND 128
        AND (decided_by IS NULL) = (decided_at IS NULL)
        AND (decided_by IS NULL OR (decided_by <> entered_by AND length(decided_by) BETWEEN 1 AND 128))
        AND (status <> 'rejected' OR decided_by IS NOT NULL)
        AND (status <> 'booked' OR override_total IS NULL OR override_total >= floor_total
             OR decided_by IS NOT NULL))
);

CREATE INDEX IF NOT EXISTS b2b_desk_bookings_partner_idx
    ON booking.b2b_desk_bookings (partner_id, entered_at DESC);
CREATE INDEX IF NOT EXISTS b2b_desk_bookings_waiting_idx
    ON booking.b2b_desk_bookings (entered_at) WHERE status = 'awaiting_approval';
CREATE INDEX IF NOT EXISTS b2b_desk_bookings_case_idx
    ON booking.b2b_desk_bookings (trip_case_id) WHERE trip_case_id IS NOT NULL;

COMMENT ON TABLE booking.b2b_desk_bookings IS
    'bk-047 (AA-1075, bk-11): a booking AA staff entered on behalf of an agency (e-mail or chat): the quote, hold and trip case it made, the rule price (quoted_total), the floor-margin price (floor_total) and an optional override. awaiting_approval = an override below the floor waits for a second staff member (the hold keeps the seats); booked; rejected; lapsed (the hold expired first). No personal data.';
COMMENT ON COLUMN booking.b2b_desk_bookings.quoted_total IS
    'conf:commercial; bk-047: the booking total at the B2B rule (with the agency discount), in currency.';
COMMENT ON COLUMN booking.b2b_desk_bookings.floor_total IS
    'conf:commercial; bk-047: the total at the rule''s floor margin; an override below it needs a second approver.';
COMMENT ON COLUMN booking.b2b_desk_bookings.override_total IS
    'conf:commercial; bk-047: the total staff set instead of quoted_total (the quote lines carry it, scaled).';
COMMENT ON COLUMN booking.b2b_desk_bookings.override_reason IS
    'pii:free_text; also conf:commercial (bk-047: why the price was overridden; staff text, never traveller data). Erasure: set to ''[redacted]'' by a reviewed DB Migrate run-script as bk_owner (the guard allows that move only).';

CREATE OR REPLACE FUNCTION booking.b2b_desk_bookings_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    unredacted booking.b2b_desk_bookings;
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.status NOT IN ('awaiting_approval', 'booked') THEN
            RAISE EXCEPTION 'a staff booking starts awaiting_approval or booked, not %', NEW.status
                USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
    END IF;
    -- DM-6.7 erasure: the one move allowed on any row, final or not: override_reason set to the fixed marker
    -- '[redacted]', every other column unchanged (run as bk_owner by a reviewed DB Migrate run-script).
    unredacted := NEW;
    unredacted.override_reason := OLD.override_reason;
    IF NEW.override_reason = '[redacted]' AND OLD.override_reason IS NOT NULL
       AND OLD.override_reason IS DISTINCT FROM NEW.override_reason AND unredacted IS NOT DISTINCT FROM OLD THEN
        RETURN NEW;
    END IF;
    IF (NEW.partner_id, NEW.agency_ref, NEW.quote_id, NEW.hold_id, NEW.currency, NEW.quoted_total, NEW.floor_total,
        NEW.override_total, NEW.override_reason, NEW.idempotency_key, NEW.entered_by, NEW.entered_at)
       IS DISTINCT FROM
       (OLD.partner_id, OLD.agency_ref, OLD.quote_id, OLD.hold_id, OLD.currency, OLD.quoted_total, OLD.floor_total,
        OLD.override_total, OLD.override_reason, OLD.idempotency_key, OLD.entered_by, OLD.entered_at) THEN
        RAISE EXCEPTION 'staff booking %: its facts never change', OLD.id USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.status <> 'awaiting_approval' AND NEW IS DISTINCT FROM OLD THEN
        RAISE EXCEPTION 'staff booking % is %: final', OLD.id, OLD.status USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;
COMMENT ON FUNCTION booking.b2b_desk_bookings_guard() IS
    'bk-047 (AA-1075): a staff booking starts awaiting_approval or booked; its facts never change; only an awaiting row moves (booked, rejected or lapsed), once. Erasure (DM-6.7): override_reason may be set to ''[redacted]'' with nothing else changed.';

DROP TRIGGER IF EXISTS b2b_desk_bookings_guard ON booking.b2b_desk_bookings;
CREATE TRIGGER b2b_desk_bookings_guard
    BEFORE INSERT OR UPDATE ON booking.b2b_desk_bookings
    FOR EACH ROW EXECUTE FUNCTION booking.b2b_desk_bookings_guard();

-- ── 2. Outbox: booking.created_by_aa, booking.line_reduced, booking.fee_changed ─

ALTER TABLE booking.outbox DROP CONSTRAINT IF EXISTS outbox_event_type_chk;
ALTER TABLE booking.outbox ADD CONSTRAINT outbox_event_type_chk CHECK (event_type IN (
    'hold.expired', 'hold.extended', 'line.confirmed', 'line.declined', 'booking.cancelled',
    'booking.created_by_aa', 'booking.line_reduced', 'booking.fee_changed',
    'departure.guaranteed', 'departure.cancelled', 'departure.incident', 'departure.incident_cleared',
    'departure.at_risk', 'allotment.released',
    'supply.upsert', 'supply.deactivate'));

ALTER TABLE booking.outbox DROP CONSTRAINT IF EXISTS outbox_hold_chk;
ALTER TABLE booking.outbox ADD CONSTRAINT outbox_hold_chk CHECK (
    (event_type IN ('hold.expired', 'hold.extended', 'line.confirmed', 'line.declined', 'booking.cancelled',
                    'booking.created_by_aa', 'booking.line_reduced', 'booking.fee_changed'))
    = (hold_id IS NOT NULL));

ALTER TABLE booking.outbox DROP CONSTRAINT IF EXISTS outbox_booking_chk;
ALTER TABLE booking.outbox ADD CONSTRAINT outbox_booking_chk CHECK (
    event_type NOT IN ('booking.cancelled', 'booking.created_by_aa', 'booking.line_reduced', 'booking.fee_changed')
    OR booking_id IS NOT NULL);

ALTER TABLE booking.outbox DROP CONSTRAINT IF EXISTS outbox_line_chk;
ALTER TABLE booking.outbox ADD CONSTRAINT outbox_line_chk CHECK (
    (event_type IN ('line.confirmed', 'line.declined', 'booking.line_reduced')) = (line_ref IS NOT NULL)
    AND (line_ref IS NULL OR length(line_ref) BETWEEN 1 AND 64));

CREATE OR REPLACE FUNCTION booking.b2b_holds_outbox() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    IF NEW.status = 'expired' AND OLD.status IS DISTINCT FROM 'expired' THEN
        INSERT INTO booking.outbox (stream, event_type, partner_id, hold_id)
        VALUES ('b2b', 'hold.expired', NEW.partner_id, NEW.id);
    END IF;
    IF NEW.extended_count > OLD.extended_count THEN
        INSERT INTO booking.outbox (stream, event_type, partner_id, hold_id)
        VALUES ('b2b', 'hold.extended', NEW.partner_id, NEW.id);
    END IF;
    -- bk-047: a booking AA staff entered for the agency; the CRM imports it (it never placed this hold itself).
    IF NEW.status = 'confirmed' AND OLD.status IS DISTINCT FROM 'confirmed' AND NEW.trip_case_id IS NOT NULL
       AND EXISTS (SELECT 1 FROM booking.trip_cases c WHERE c.id = NEW.trip_case_id AND c.entered_via = 'staff') THEN
        INSERT INTO booking.outbox (stream, event_type, partner_id, hold_id, booking_id)
        VALUES ('b2b', 'booking.created_by_aa', NEW.partner_id, NEW.id, NEW.trip_case_id);
    END IF;
    RETURN NULL;
END $$;

-- ── 3. Vouchers and supplier cancel fees on supplier bookings ─────────────────

ALTER TABLE booking.supplier_bookings
    ADD COLUMN IF NOT EXISTS service_time TIME,
    ADD COLUMN IF NOT EXISTS pickup_point TEXT,
    ADD COLUMN IF NOT EXISTS dropoff_point TEXT,
    ADD COLUMN IF NOT EXISTS voucher_note TEXT,
    ADD COLUMN IF NOT EXISTS supplier_cancel_fee NUMERIC(16,2),
    ADD COLUMN IF NOT EXISTS supplier_cancel_fee_currency CHAR(3);

ALTER TABLE booking.supplier_bookings DROP CONSTRAINT IF EXISTS supplier_bookings_voucher_chk;
ALTER TABLE booking.supplier_bookings ADD CONSTRAINT supplier_bookings_voucher_chk CHECK (
    (pickup_point IS NULL OR length(btrim(pickup_point)) BETWEEN 1 AND 200)
    AND (dropoff_point IS NULL OR length(btrim(dropoff_point)) BETWEEN 1 AND 200)
    AND (voucher_note IS NULL OR length(btrim(voucher_note)) BETWEEN 1 AND 500));
ALTER TABLE booking.supplier_bookings DROP CONSTRAINT IF EXISTS supplier_bookings_cancel_fee_chk;
ALTER TABLE booking.supplier_bookings ADD CONSTRAINT supplier_bookings_cancel_fee_chk CHECK (
    (supplier_cancel_fee IS NULL) = (supplier_cancel_fee_currency IS NULL)
    AND (supplier_cancel_fee IS NULL OR (supplier_cancel_fee >= 0 AND status = 'cancelled'))
    AND (supplier_cancel_fee_currency IS NULL OR supplier_cancel_fee_currency ~ '^[A-Z]{3}$'));

COMMENT ON COLUMN booking.supplier_bookings.service_time IS
    'bk-047 (AA-1075, bk-12): local time of the service (pick-up or start), printed on the agency voucher.';
COMMENT ON COLUMN booking.supplier_bookings.pickup_point IS
    'bk-047 (AA-1075, bk-12): where the service picks the group up (a hotel lobby, an airport hall); never a traveller name.';
COMMENT ON COLUMN booking.supplier_bookings.dropoff_point IS
    'bk-047 (AA-1075, bk-12): where the service ends; never a traveller name.';
COMMENT ON COLUMN booking.supplier_bookings.voucher_note IS
    'pii:free_text; bk-047 (AA-1075, bk-12): an operational note printed on the agency voucher (what to bring, whom to call); staff text, never traveller data by rule.';
COMMENT ON COLUMN booking.supplier_bookings.supplier_cancel_fee IS
    'conf:commercial; bk-047 (AA-1075, bk-14): what the supplier charges for cancelling this booking, recorded when it answers (only on a cancelled booking); the cost of a cancelled booking until its bill is approved.';
COMMENT ON COLUMN booking.supplier_bookings.supplier_cancel_fee_currency IS
    'conf:commercial; bk-047 (AA-1075, bk-14): currency of supplier_cancel_fee.';

-- ── 4. Cancellation override / waive and the staff cancel ─────────────────────

ALTER TABLE booking.b2b_cancellations
    ADD COLUMN IF NOT EXISTS entered_via TEXT NOT NULL DEFAULT 'api',
    ADD COLUMN IF NOT EXISTS entered_by TEXT,
    ADD COLUMN IF NOT EXISTS fee_override_pct NUMERIC(5,2),
    ADD COLUMN IF NOT EXISTS waive_reason TEXT,
    ADD COLUMN IF NOT EXISTS override_by TEXT,
    ADD COLUMN IF NOT EXISTS override_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS override_approved_by TEXT,
    ADD COLUMN IF NOT EXISTS override_approved_at TIMESTAMPTZ;

ALTER TABLE booking.b2b_cancellations DROP CONSTRAINT IF EXISTS b2b_cancellations_entered_chk;
ALTER TABLE booking.b2b_cancellations ADD CONSTRAINT b2b_cancellations_entered_chk CHECK (
    entered_via IN ('api', 'staff')
    AND (entered_via = 'staff') = (entered_by IS NOT NULL)
    AND (entered_by IS NULL OR length(entered_by) BETWEEN 1 AND 128));
ALTER TABLE booking.b2b_cancellations DROP CONSTRAINT IF EXISTS b2b_cancellations_override_chk;
ALTER TABLE booking.b2b_cancellations ADD CONSTRAINT b2b_cancellations_override_chk CHECK (
    (fee_override_pct IS NULL) = (override_by IS NULL)
    AND (override_by IS NULL) = (override_at IS NULL)
    AND (override_by IS NULL) = (waive_reason IS NULL)
    AND (override_approved_by IS NULL) = (override_approved_at IS NULL)
    AND (override_approved_by IS NULL OR override_by IS NOT NULL)
    AND (override_approved_by IS NULL OR override_approved_by <> override_by)
    AND (fee_override_pct IS NULL OR (fee_override_pct >= 0 AND fee_override_pct < fee_pct))
    AND (waive_reason IS NULL OR length(btrim(waive_reason)) BETWEEN 1 AND 500)
    AND (override_by IS NULL OR length(override_by) BETWEEN 1 AND 128)
    AND (override_approved_by IS NULL OR length(override_approved_by) BETWEEN 1 AND 128));

COMMENT ON COLUMN booking.b2b_cancellations.entered_via IS
    'bk-047 (AA-1075, bk-14): api = the agency cancelled through booking.b2b.v1; staff = AA staff cancelled for it (an e-mailed request).';
COMMENT ON COLUMN booking.b2b_cancellations.fee_override_pct IS
    'conf:commercial; bk-047 (AA-1075, bk-14): a lower fee % staff asked for (0 = waive); fee_amount changes only once a second staff member approves it.';
COMMENT ON COLUMN booking.b2b_cancellations.waive_reason IS
    'pii:free_text; bk-047 (AA-1075, bk-14): why the fee is lowered or waived (staff text, never traveller data by rule). Erasure: set to ''[redacted]'' by a reviewed DB Migrate run-script as bk_owner (the guard allows that move only).';

CREATE OR REPLACE FUNCTION booking.b2b_cancellations_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    unredacted booking.b2b_cancellations;
BEGIN
    -- DM-6.7 erasure: the one move allowed on any row, approved or not: waive_reason set to the fixed marker
    -- '[redacted]', every other column unchanged (run as bk_owner by a reviewed DB Migrate run-script).
    unredacted := NEW;
    unredacted.waive_reason := OLD.waive_reason;
    IF NEW.waive_reason = '[redacted]' AND OLD.waive_reason IS NOT NULL
       AND OLD.waive_reason IS DISTINCT FROM NEW.waive_reason AND unredacted IS NOT DISTINCT FROM OLD THEN
        RETURN NEW;
    END IF;
    IF (NEW.hold_id, NEW.trip_case_id, NEW.partner_id, NEW.m2m_client_id, NEW.policy_id, NEW.reason_code,
        NEW.idempotency_key, NEW.departure_date, NEW.days_before_departure, NEW.fee_pct, NEW.currency,
        NEW.total_b2b_price, NEW.cancelled_at, NEW.entered_via, NEW.entered_by)
       IS DISTINCT FROM
       (OLD.hold_id, OLD.trip_case_id, OLD.partner_id, OLD.m2m_client_id, OLD.policy_id, OLD.reason_code,
        OLD.idempotency_key, OLD.departure_date, OLD.days_before_departure, OLD.fee_pct, OLD.currency,
        OLD.total_b2b_price, OLD.cancelled_at, OLD.entered_via, OLD.entered_by) THEN
        RAISE EXCEPTION 'cancellation %: its facts never change', OLD.id USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.override_approved_at IS NOT NULL AND NEW IS DISTINCT FROM OLD THEN
        RAISE EXCEPTION 'cancellation %: the fee override is approved and final', OLD.id
            USING ERRCODE = 'check_violation';
    END IF;
    IF (NEW.fee_amount, NEW.refundable_amount) IS DISTINCT FROM (OLD.fee_amount, OLD.refundable_amount)
       AND NOT (OLD.override_approved_at IS NULL AND NEW.override_approved_at IS NOT NULL
                AND NEW.fee_amount < OLD.fee_amount) THEN
        RAISE EXCEPTION 'cancellation %: the fee changes only to a lower amount, when the override is approved', OLD.id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;
COMMENT ON FUNCTION booking.b2b_cancellations_guard() IS
    'bk-047 (AA-1075): a cancellation''s facts never change; the fee and refundable amounts change once, to a lower fee, in the update that approves the override; an approved override is final. Erasure (DM-6.7): waive_reason may be set to ''[redacted]'' with nothing else changed.';

DROP TRIGGER IF EXISTS b2b_cancellations_guard ON booking.b2b_cancellations;
CREATE TRIGGER b2b_cancellations_guard
    BEFORE UPDATE ON booking.b2b_cancellations
    FOR EACH ROW EXECUTE FUNCTION booking.b2b_cancellations_guard();

CREATE OR REPLACE FUNCTION booking.b2b_cancellations_fee_outbox() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    IF NEW.fee_amount IS DISTINCT FROM OLD.fee_amount THEN
        INSERT INTO booking.outbox (stream, event_type, partner_id, hold_id, booking_id)
        VALUES ('b2b', 'booking.fee_changed', NEW.partner_id, NEW.hold_id, NEW.trip_case_id);
    END IF;
    RETURN NULL;
END $$;
COMMENT ON FUNCTION booking.b2b_cancellations_fee_outbox() IS
    'bk-047 (AA-1075): booking.fee_changed to the agency when an approved override lowers a cancellation fee.';

DROP TRIGGER IF EXISTS b2b_cancellations_fee_outbox ON booking.b2b_cancellations;
CREATE TRIGGER b2b_cancellations_fee_outbox
    AFTER UPDATE OF fee_amount ON booking.b2b_cancellations
    FOR EACH ROW EXECUTE FUNCTION booking.b2b_cancellations_fee_outbox();

-- ── 5. Partial cancellation: fewer seats on one line ─────────────────────────

CREATE TABLE IF NOT EXISTS booking.b2b_line_reductions (
    id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    hold_id                UUID NOT NULL REFERENCES booking.b2b_holds (id),
    trip_case_id           UUID NOT NULL REFERENCES booking.trip_cases (id),
    partner_id             UUID NOT NULL REFERENCES booking.b2b_partners (id),
    line_ref               TEXT NOT NULL,
    removed_adults         SMALLINT NOT NULL,
    removed_children       SMALLINT NOT NULL,
    removed_infants        SMALLINT NOT NULL,
    seats_before           SMALLINT NOT NULL,
    seats_after            SMALLINT NOT NULL,
    policy_id              UUID NOT NULL REFERENCES booking.cancellation_policies (id),
    days_before_departure  INTEGER NOT NULL,
    fee_pct                NUMERIC(5,2) NOT NULL,
    currency               CHAR(3) NOT NULL,
    removed_amount         NUMERIC(14,2) NOT NULL,
    fee_amount             NUMERIC(14,2) NOT NULL,
    refundable_amount      NUMERIC(14,2) NOT NULL,
    reason_code            TEXT NOT NULL,
    idempotency_key        TEXT NOT NULL,
    entered_via            TEXT NOT NULL,
    entered_by             TEXT,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT b2b_line_reductions_key_uq UNIQUE (hold_id, idempotency_key),
    CONSTRAINT b2b_line_reductions_ref_chk CHECK (length(line_ref) BETWEEN 1 AND 64),
    CONSTRAINT b2b_line_reductions_pax_chk CHECK (
        removed_adults BETWEEN 0 AND 60 AND removed_children BETWEEN 0 AND 60 AND removed_infants BETWEEN 0 AND 20
        AND removed_adults + removed_children + removed_infants >= 1),
    CONSTRAINT b2b_line_reductions_seats_chk CHECK (
        seats_after >= 1 AND seats_after = seats_before - removed_adults - removed_children),
    CONSTRAINT b2b_line_reductions_fee_chk CHECK (
        fee_pct BETWEEN 0 AND 100 AND removed_amount >= 0 AND fee_amount >= 0 AND refundable_amount >= 0
        AND fee_amount + refundable_amount = removed_amount),
    CONSTRAINT b2b_line_reductions_currency_chk CHECK (currency ~ '^[A-Z]{3}$'),
    CONSTRAINT b2b_line_reductions_reason_chk CHECK (reason_code IN ('client_cancelled', 'agency_cancelled', 'other')),
    CONSTRAINT b2b_line_reductions_key_chk CHECK (length(idempotency_key) BETWEEN 8 AND 200),
    CONSTRAINT b2b_line_reductions_entered_chk CHECK (
        entered_via IN ('api', 'staff')
        AND (entered_via = 'staff') = (entered_by IS NOT NULL)
        AND (entered_by IS NULL OR length(entered_by) BETWEEN 1 AND 128))
);

CREATE INDEX IF NOT EXISTS b2b_line_reductions_hold_idx ON booking.b2b_line_reductions (hold_id, created_at);
CREATE INDEX IF NOT EXISTS b2b_line_reductions_case_idx ON booking.b2b_line_reductions (trip_case_id);
CREATE INDEX IF NOT EXISTS b2b_line_reductions_partner_idx ON booking.b2b_line_reductions (partner_id);
CREATE INDEX IF NOT EXISTS b2b_line_reductions_policy_idx ON booking.b2b_line_reductions (policy_id);

COMMENT ON TABLE booking.b2b_line_reductions IS
    'bk-047 (AA-1075, bk-14): a partial cancellation of a confirmed B2B booking: fewer travellers on one line (counts by age band), the fee by the booking''s locked policy on the removed seats'' share of the line price and the refundable rest (the amendment record; the approved version stays as sold). Append-only; emits booking.line_reduced. No personal data.';
COMMENT ON COLUMN booking.b2b_line_reductions.removed_amount IS
    'conf:commercial; bk-047: the line price share of the removed travellers (in the quote currency).';

CREATE OR REPLACE FUNCTION booking.b2b_line_reductions_outbox() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    INSERT INTO booking.outbox (stream, event_type, partner_id, hold_id, booking_id, line_ref)
    VALUES ('b2b', 'booking.line_reduced', NEW.partner_id, NEW.hold_id, NEW.trip_case_id, NEW.line_ref);
    RETURN NULL;
END $$;
COMMENT ON FUNCTION booking.b2b_line_reductions_outbox() IS
    'bk-047 (AA-1075): booking.line_reduced to the agency for each partial cancellation.';

DROP TRIGGER IF EXISTS b2b_line_reductions_outbox ON booking.b2b_line_reductions;
CREATE TRIGGER b2b_line_reductions_outbox
    AFTER INSERT ON booking.b2b_line_reductions
    FOR EACH ROW EXECUTE FUNCTION booking.b2b_line_reductions_outbox();

-- ── 6. Child, infant and single-supplement prices ────────────────────────────

ALTER TABLE booking.trip_plan_prices
    ADD COLUMN IF NOT EXISTS child_amount NUMERIC(12,2),
    ADD COLUMN IF NOT EXISTS infant_amount NUMERIC(12,2),
    ADD COLUMN IF NOT EXISTS single_supplement_amount NUMERIC(12,2),
    ADD COLUMN IF NOT EXISTS child_net_amount NUMERIC(12,2),
    ADD COLUMN IF NOT EXISTS infant_net_amount NUMERIC(12,2),
    ADD COLUMN IF NOT EXISTS single_supplement_net_amount NUMERIC(12,2);

ALTER TABLE booking.trip_plan_prices DROP CONSTRAINT IF EXISTS trip_plan_prices_pax_type_chk;
ALTER TABLE booking.trip_plan_prices ADD CONSTRAINT trip_plan_prices_pax_type_chk CHECK (
    (child_amount IS NULL OR child_amount >= 0)
    AND (infant_amount IS NULL OR infant_amount >= 0)
    AND (single_supplement_amount IS NULL OR single_supplement_amount >= 0)
    AND (child_net_amount IS NULL OR (child_net_amount >= 0 AND net_amount IS NOT NULL))
    AND (infant_net_amount IS NULL OR (infant_net_amount >= 0 AND net_amount IS NOT NULL))
    AND (single_supplement_net_amount IS NULL OR (single_supplement_net_amount >= 0 AND net_amount IS NOT NULL)));

COMMENT ON COLUMN booking.trip_plan_prices.child_amount IS
    'conf:commercial; bk-047 (AA-1075, bk-15): price per child (up to the plan''s child_age_max) in currency; NULL = priced like an adult.';
COMMENT ON COLUMN booking.trip_plan_prices.infant_amount IS
    'conf:commercial; bk-047 (AA-1075, bk-15): price per infant (up to infant_age_max) in currency; NULL = free.';
COMMENT ON COLUMN booking.trip_plan_prices.single_supplement_amount IS
    'conf:commercial; bk-047 (AA-1075, bk-15): extra price for a traveller in a single room, in currency.';
COMMENT ON COLUMN booking.trip_plan_prices.child_net_amount IS
    'conf:commercial; bk-047: net cost per child, in net_currency (the cost sheet: adult net x the rule''s child_pct).';
COMMENT ON COLUMN booking.trip_plan_prices.infant_net_amount IS
    'conf:commercial; bk-047: net cost per infant, in net_currency (the cost sheet: the rule''s infant_flat_usd).';
COMMENT ON COLUMN booking.trip_plan_prices.single_supplement_net_amount IS
    'conf:commercial; bk-047: net single supplement, in net_currency (the cost sheet: per night, the single room rate less half the double rate).';

ALTER TABLE booking.trip_plans
    ADD COLUMN IF NOT EXISTS child_age_max SMALLINT,
    ADD COLUMN IF NOT EXISTS infant_age_max SMALLINT;

ALTER TABLE booking.trip_plans DROP CONSTRAINT IF EXISTS trip_plans_age_bands_chk;
ALTER TABLE booking.trip_plans ADD CONSTRAINT trip_plans_age_bands_chk CHECK (
    (child_age_max IS NULL OR child_age_max BETWEEN 2 AND 17)
    AND (infant_age_max IS NULL OR infant_age_max BETWEEN 0 AND 4)
    AND (child_age_max IS NULL OR infant_age_max IS NULL OR infant_age_max < child_age_max));

COMMENT ON COLUMN booking.trip_plans.child_age_max IS
    'bk-047 (AA-1075, bk-15): the oldest age that travels at the child price (NULL = the default 11).';
COMMENT ON COLUMN booking.trip_plans.infant_age_max IS
    'bk-047 (AA-1075, bk-15): the oldest age that travels at the infant price (NULL = the default 1).';

ALTER TABLE booking.pricing_rules
    ADD COLUMN IF NOT EXISTS child_pct NUMERIC(5,4),
    ADD COLUMN IF NOT EXISTS infant_flat_usd NUMERIC(10,2);

ALTER TABLE booking.pricing_rules DROP CONSTRAINT IF EXISTS pricing_rules_child_chk;
ALTER TABLE booking.pricing_rules ADD CONSTRAINT pricing_rules_child_chk CHECK (
    (child_pct IS NULL OR (child_pct >= 0 AND child_pct <= 1))
    AND (infant_flat_usd IS NULL OR (infant_flat_usd >= 0 AND infant_flat_usd < 10000)));

COMMENT ON COLUMN booking.pricing_rules.child_pct IS
    'conf:commercial; bk-047 (AA-1075, bk-15): a child pays this fraction of the adult price on a trip plan (NULL = like an adult).';
COMMENT ON COLUMN booking.pricing_rules.infant_flat_usd IS
    'conf:commercial; bk-047 (AA-1075, bk-15): net cost per infant per trip, in USD, priced by the rule (NULL = infants free).';

-- ── 7. Per-tour deposit and balance terms ────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.trip_plan_billing_terms (
    id                             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    trip_plan_id                   UUID NOT NULL REFERENCES booking.trip_plans (id),
    party_tenant_id                UUID,
    deposit_pct                    NUMERIC(5,4) NOT NULL,
    balance_days_before_departure  SMALLINT NOT NULL,
    created_at                     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by                     TEXT,
    CONSTRAINT trip_plan_billing_terms_deposit_chk CHECK (deposit_pct >= 0 AND deposit_pct <= 1),
    CONSTRAINT trip_plan_billing_terms_days_chk CHECK (balance_days_before_departure BETWEEN 0 AND 365),
    CONSTRAINT trip_plan_billing_terms_actor_chk CHECK (updated_by IS NULL OR length(updated_by) BETWEEN 1 AND 128)
);

CREATE UNIQUE INDEX IF NOT EXISTS trip_plan_billing_terms_scope_uq
    ON booking.trip_plan_billing_terms (trip_plan_id, party_tenant_id) NULLS NOT DISTINCT;
CREATE INDEX IF NOT EXISTS trip_plan_billing_terms_party_idx
    ON booking.trip_plan_billing_terms (party_tenant_id) WHERE party_tenant_id IS NOT NULL;

COMMENT ON TABLE booking.trip_plan_billing_terms IS
    'bk-047 (AA-1075, bk-18): deposit % and balance days for one trip plan, for every agency (party_tenant_id NULL) or one agency. Most specific wins: agency + plan > plan > agency (billing_terms) > default (billing_terms). Configuration edited by finance and audited; no personal data.';
COMMENT ON COLUMN booking.trip_plan_billing_terms.deposit_pct IS 'conf:commercial; bk-047: deposit as a fraction (0.3000 = 30 %).';

DROP TRIGGER IF EXISTS trip_plan_billing_terms_set_updated_at ON booking.trip_plan_billing_terms;
CREATE TRIGGER trip_plan_billing_terms_set_updated_at
    BEFORE UPDATE ON booking.trip_plan_billing_terms FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();

-- ── 8. Views (same columns, new bodies) ──────────────────────────────────────

-- A recorded supplier cancel fee is the cost of a cancelled booking until its bill is approved.
CREATE OR REPLACE VIEW booking.v_cost_variance AS
SELECT x.supplier_booking_id, x.code, x.trip_case_id, x.departure_id, x.supplier_id, x.status, x.live,
       x.planned_net, x.planned_currency, x.planned_fx_rate_per_usd, x.planned_usd,
       x.billed, x.billed_lines, x.billed_net, x.billed_other_currency, x.billed_usd,
       CASE WHEN x.billed AND NOT x.billed_other_currency THEN x.billed_net - x.planned_net END AS variance,
       CASE WHEN x.billed THEN x.billed_usd - x.planned_usd END AS variance_usd,
       CASE WHEN x.billed THEN x.fx_difference_usd END AS fx_difference_usd,
       CASE WHEN x.billed THEN x.billed_usd WHEN x.live THEN x.planned_usd
            ELSE coalesce(x.cancel_fee_usd, 0::numeric) END AS cost_usd,
       (x.planned_currency IS NOT NULL AND x.planned_fx_rate_per_usd IS NULL) OR x.billed_rate_missing
           OR (x.cancel_fee_currency IS NOT NULL AND x.cancel_fee_usd IS NULL AND NOT x.billed) AS fx_missing
  FROM (
      SELECT sb.id AS supplier_booking_id, sb.code, sb.trip_case_id, sb.departure_id, sb.supplier_id, sb.status,
             sb.status IN ('pending', 'requested', 'confirmed') AS live,
             sb.net_amount AS planned_net, sb.net_currency::text AS planned_currency,
             pr.rate AS planned_fx_rate_per_usd,
             round(sb.net_amount / pr.rate, 2) AS planned_usd,
             coalesce(bl.lines, 0) > 0 AS billed,
             coalesce(bl.lines, 0)::int AS billed_lines,
             bl.same_amount AS billed_net,
             coalesce(bl.other_currency, false) AS billed_other_currency,
             CASE WHEN bl.rate_missing THEN NULL ELSE bl.billed_usd END AS billed_usd,
             bl.fx_difference_usd,
             coalesce(bl.rate_missing, false) AS billed_rate_missing,
             sb.supplier_cancel_fee_currency::text AS cancel_fee_currency,
             round(sb.supplier_cancel_fee
                   / booking.fx_plain_rate(sb.supplier_cancel_fee_currency::text,
                                           coalesce(sb.cancelled_at::date, current_date)), 2) AS cancel_fee_usd
        FROM booking.supplier_bookings sb
        CROSS JOIN LATERAL (
            SELECT coalesce(sb.fx_rate_per_usd,
                            booking.fx_plain_rate(sb.net_currency::text, coalesce(sb.confirmed_at::date, current_date)))
                   AS rate
        ) pr
        LEFT JOIN LATERAL (
            SELECT count(*) AS lines,
                   sum(it.amount) FILTER (WHERE b.currency = sb.net_currency) AS same_amount,
                   bool_or(b.currency IS DISTINCT FROM sb.net_currency) AS other_currency,
                   sum(round(it.amount / br.rate, 2)) AS billed_usd,
                   bool_or(br.rate IS NULL) AS rate_missing,
                   sum(round(it.amount / br.rate, 2) - round(it.amount / pr.rate, 2))
                       FILTER (WHERE b.currency = sb.net_currency) AS fx_difference_usd
              FROM booking.supplier_bill_items it
              JOIN booking.supplier_bills b ON b.id = it.bill_id
              CROSS JOIN LATERAL (
                  SELECT coalesce(b.fx_rate_per_usd,
                                  booking.fx_plain_rate(b.currency::text, coalesce(b.approved_at::date, b.issue_date)))
                         AS rate
              ) br
             WHERE it.supplier_booking_id = sb.id AND b.status IN ('approved', 'paid')
        ) bl ON true
  ) x;

COMMENT ON VIEW booking.v_cost_variance IS
    'bk-045 (AA-1074, bk-07 / bk-10), bk-047 (AA-1075, bk-14): conf:commercial. Per supplier booking: planned net and USD (snapshot rate, else the rate in force on the confirm day, else today), billed = lines of approved / paid bills (native sum in the planned currency, USD at each bill''s rate), variance and variance_usd only once billed, fx_difference_usd = the billed native amount at the bill rate minus at the booking rate, cost_usd = billed, else planned while live, else the recorded supplier cancel fee (USD at the rate of the cancel day), else 0. USD per line rounded half up to the cent.';

CREATE OR REPLACE VIEW booking.v_case_profit AS
WITH own AS (
    SELECT cv.trip_case_id,
           count(*) FILTER (WHERE cv.live OR cv.billed)::int AS bookings,
           sum(cv.planned_usd) FILTER (WHERE cv.live) AS planned_usd,
           sum(cv.billed_usd) FILTER (WHERE cv.billed) AS billed_usd,
           sum(cv.cost_usd) FILTER (WHERE cv.status = 'cancelled') AS cancel_fee_usd,
           sum(cv.cost_usd) AS cost_usd,
           count(*) FILTER (WHERE cv.status = 'confirmed' AND NOT cv.billed)::int AS unbilled,
           bool_or(cv.fx_missing AND (cv.live OR cv.billed OR cv.status = 'cancelled')) AS fx_missing
      FROM booking.v_cost_variance cv
     WHERE cv.trip_case_id IS NOT NULL
     GROUP BY cv.trip_case_id
), shared AS (
    SELECT trip_case_id, sum(share_planned_usd) AS planned_usd, sum(share_billed_usd) AS billed_usd,
           sum(share_cost_usd) AS cost_usd
      FROM booking.v_departure_cost_share GROUP BY trip_case_id
), reduced AS (
    SELECT hold_id, sum(removed_amount) AS removed, sum(fee_amount) AS fees
      FROM booking.b2b_line_reductions GROUP BY hold_id
), base AS (
    SELECT tc.id AS trip_case_id, tc.code, tc.status, tc.start_date, tc.end_date, tc.pax,
           h.partner_id, h.id AS hold_id,
           (SELECT l.departure_id FROM booking.b2b_hold_lines l
             WHERE l.hold_id = h.id AND l.departure_id IS NOT NULL ORDER BY l.line_no LIMIT 1) AS departure_id,
           q.currency::text AS currency,
           CASE WHEN q.currency = 'USD' THEN 1::numeric ELSE q.fx_rate_per_usd END AS fx_rate_per_usd,
           c.id IS NOT NULL AS cancelled,
           (CASE WHEN c.id IS NOT NULL THEN c.fee_amount + coalesce(r.fees, 0)
                 ELSE q.total_b2b_price - coalesce(r.removed, 0) + coalesce(r.fees, 0) END)::numeric(14,2) AS revenue,
           (SELECT round(sum(ql.net_cost_usd), 2) FROM booking.b2b_quote_lines ql WHERE ql.quote_id = q.id)
               AS quoted_cost_usd
      FROM booking.trip_cases tc
      JOIN booking.b2b_holds h ON h.trip_case_id = tc.id AND h.status = 'confirmed'
      JOIN booking.b2b_quotes q ON q.id = h.quote_id
      LEFT JOIN booking.b2b_cancellations c ON c.trip_case_id = tc.id
      LEFT JOIN reduced r ON r.hold_id = h.id
     WHERE tc.channel = 'b2b' AND tc.deleted_at IS NULL
), costed AS (
    SELECT b.*, d.trip_plan_id,
           round(b.revenue / b.fx_rate_per_usd, 2) AS revenue_usd,
           coalesce(o.bookings, 0) AS bookings,
           coalesce(o.planned_usd, 0) + coalesce(s.planned_usd, 0) AS planned_cost_usd,
           coalesce(o.billed_usd, 0) + coalesce(s.billed_usd, 0) AS actual_cost_usd,
           coalesce(o.cancel_fee_usd, 0) AS supplier_cancel_fee_usd,
           coalesce(s.cost_usd, 0) AS shared_cost_usd,
           coalesce(o.unbilled, 0) AS unbilled_bookings,
           coalesce(o.fx_missing, false) AS fx_missing,
           CASE WHEN coalesce(o.bookings, 0) = 0 AND NOT b.cancelled AND b.quoted_cost_usd IS NOT NULL THEN 'quote'
                ELSE 'bookings' END AS cost_basis,
           CASE WHEN coalesce(o.bookings, 0) = 0 AND NOT b.cancelled
                THEN coalesce(b.quoted_cost_usd, 0)
                ELSE coalesce(o.cost_usd, 0) END + coalesce(s.cost_usd, 0) AS cost_usd
      FROM base b
      LEFT JOIN booking.departures d ON d.id = b.departure_id
      LEFT JOIN own o ON o.trip_case_id = b.trip_case_id
      LEFT JOIN shared s ON s.trip_case_id = b.trip_case_id
)
SELECT trip_case_id, code, status, start_date, end_date, pax, partner_id, hold_id, departure_id, trip_plan_id,
       currency, fx_rate_per_usd, cancelled, revenue, revenue_usd, quoted_cost_usd, bookings, planned_cost_usd,
       actual_cost_usd, supplier_cancel_fee_usd, shared_cost_usd, unbilled_bookings, fx_missing, cost_basis, cost_usd,
       revenue_usd - cost_usd AS profit_usd,
       revenue_usd - planned_cost_usd AS planned_profit_usd,
       round((revenue_usd - cost_usd) * fx_rate_per_usd, 2) AS profit,
       CASE WHEN revenue_usd > 0 THEN round((revenue_usd - cost_usd) / revenue_usd, 4) END AS margin
  FROM costed;

COMMENT ON VIEW booking.v_case_profit IS
    'bk-045 (AA-1074, bk-08), bk-047 (AA-1075, bk-14): conf:commercial, staff only (profit.read), never in booking.b2b.v1. Per B2B trip case with a confirmed hold: revenue (quote total less the removed seats of partial cancellations plus their fees, or the cancellation fee plus those fees once cancelled) in the quote currency and USD at the quote''s plain rate; costs in USD: quoted (quote lines), planned (live supplier bookings + departure share), actual (approved bills incl. supplier cancellation fees + share), supplier_cancel_fee_usd (billed or recorded cancel fees), best (cost_usd: billed, else planned, else recorded cancel fees, else the quote while no booking exists); profit_usd, profit (quote currency), margin (fraction of revenue).';

-- ── 9. Settings ──────────────────────────────────────────────────────────────

-- The AA operations desk an agency voucher prints (bk-12). Seeded empty: the voucher then prints no line; the business
-- owner's company line is set later with a DB Migrate run-script (never a personal mobile).
INSERT INTO booking.settings (key, value, description) VALUES
    ('b2b_ops_contact', '{}'::jsonb, 'AA 24-hour operations desk printed on agency vouchers (AA-1075 bk-12): {"label": "..."}, the company line AA publishes, never a person; empty = no line printed.'),
    ('b2b_child_age_max', '11'::jsonb, 'Default oldest age at the child price when a trip plan sets none (AA-1075 bk-15; policy data, proposed for the business owner).'),
    ('b2b_infant_age_max', '1'::jsonb, 'Default oldest age at the infant price when a trip plan sets none (AA-1075 bk-15; policy data, proposed for the business owner).')
ON CONFLICT (key) DO NOTHING;

-- ── Grants (per object) ──────────────────────────────────────────────────────

REVOKE ALL ON booking.b2b_desk_bookings FROM booking;
GRANT SELECT, INSERT ON booking.b2b_desk_bookings TO booking;
GRANT UPDATE (status, trip_case_id, decided_by, decided_at) ON booking.b2b_desk_bookings TO booking;

REVOKE ALL ON booking.b2b_line_reductions FROM booking;
GRANT SELECT, INSERT ON booking.b2b_line_reductions TO booking;

REVOKE ALL ON booking.trip_plan_billing_terms FROM booking;
GRANT SELECT, INSERT, UPDATE, DELETE ON booking.trip_plan_billing_terms TO booking;

-- b2b_cancellations stays INSERT + SELECT; only the override columns and the two amounts are updatable (the guard
-- trigger keeps the amounts to the approval update).
GRANT UPDATE (fee_override_pct, waive_reason, override_by, override_at, override_approved_by, override_approved_at,
              fee_amount, refundable_amount) ON booking.b2b_cancellations TO booking;

-- trip_cases, supplier_bookings, trip_plan_prices, trip_plans, pricing_rules: the table grants of their bk- files
-- cover the new columns. Views: SELECT to booking stays (CREATE OR REPLACE keeps the grants); read-only repeated.
REVOKE INSERT, UPDATE, DELETE ON booking.v_cost_variance FROM booking;
REVOKE INSERT, UPDATE, DELETE ON booking.v_case_profit FROM booking;
GRANT SELECT ON booking.v_cost_variance, booking.v_case_profit TO booking;

GRANT EXECUTE ON FUNCTION booking.b2b_desk_bookings_guard() TO booking;
GRANT EXECUTE ON FUNCTION booking.b2b_holds_outbox() TO booking;
GRANT EXECUTE ON FUNCTION booking.b2b_cancellations_guard() TO booking;
GRANT EXECUTE ON FUNCTION booking.b2b_cancellations_fee_outbox() TO booking;
GRANT EXECUTE ON FUNCTION booking.b2b_line_reductions_outbox() TO booking;

DO $$
BEGIN
    IF has_table_privilege('booking', 'booking.b2b_line_reductions', 'UPDATE')
       OR has_table_privilege('booking', 'booking.b2b_line_reductions', 'DELETE')
       OR has_table_privilege('booking', 'booking.b2b_desk_bookings', 'DELETE')
       OR has_column_privilege('booking', 'booking.b2b_desk_bookings', 'override_total', 'UPDATE')
       OR has_table_privilege('booking', 'booking.b2b_cancellations', 'DELETE')
       OR has_column_privilege('booking', 'booking.b2b_cancellations', 'fee_pct', 'UPDATE') THEN
        RAISE EXCEPTION 'bk-047: role booking can rewrite a reduction, a staff booking or a cancellation';
    END IF;
    IF has_table_privilege('cis_app', 'booking.b2b_desk_bookings', 'SELECT')
       OR has_table_privilege('cis_app', 'booking.b2b_line_reductions', 'SELECT')
       OR has_table_privilege('cis_app', 'booking.trip_plan_billing_terms', 'SELECT') THEN
        RAISE EXCEPTION 'bk-047: cis_app can read agency bookings or terms';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-047', now(), 'AA-1075: trip_cases entered_via / entered_by, b2b_desk_bookings (staff-entered agency bookings, override maker-checker), outbox booking.created_by_aa / booking.line_reduced / booking.fee_changed (b2b_holds_outbox replaced), supplier_bookings voucher fields + supplier_cancel_fee, b2b_cancellations staff cancel + fee override (guard, fee outbox), b2b_line_reductions, trip_plan_prices child / infant / single supplement (+ nets), trip_plans age bands, pricing_rules child_pct / infant_flat_usd, trip_plan_billing_terms, v_cost_variance / v_case_profit bodies, settings b2b_ops_contact / b2b_child_age_max / b2b_infant_age_max')
ON CONFLICT (version) DO NOTHING;

COMMIT;
