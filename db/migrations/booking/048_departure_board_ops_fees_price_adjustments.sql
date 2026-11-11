-- Migration bk-048: AA-1073 rest (Booking departures; S275 study root docs/research/2026-11-10-odoo-tour-travel-plugin-comparison.md
-- items bk-04, bk-16, bk-09, bk-17) — the departure board (occupancy view), the departure ops sheet, departure fees
-- charged to agencies, and per-departure price adjustments with the early-booking rule.
--
-- Owner: AA-Booking (key bk-NNN). AA-CIS-Infra Migration Sync copies it byte for byte to
-- db/migrations/booking/048_departure_board_ops_fees_price_adjustments.sql; on Dev it is applied as bk_owner (the live
-- owner of schema booking since bk-014) by Infra Migration Apply once every job table is idle (root ADR 0017a), or by
-- a person with DB Migrate apply. Never run it from a laptop.
--
-- What:
--   1. Ops sheet (bk-16). booking.departures gains meeting_point (where the group meets: a public place, never a
--      traveller's address), meeting_time (local time on the start date) and ops_note (staff only, never sent). New
--      booking.departure_staff: who works the departure, by role (guide | tour_leader | driver): an AA staff member
--      (staff_user_id) or a supplier that provides the person (supplier_id), exactly one. No guide name, phone or
--      e-mail is stored. departures_outbox also emits departure.updated (to every agency on the departure) when the
--      meeting point or time changes on a departure that is not cancelled; the event names the departure only, the
--      agency reads the new values from GET /departures (contract 1.8). The trigger now fires on UPDATE OF status,
--      at_risk_at, meeting_point, meeting_time.
--   2. Departure fees (bk-09). New booking.departure_fees: a fee AA charges one agency on one departure (reason
--      min_shortfall | allotment_unreleased | other), seats x price per seat in one currency. Maker-checker: pending
--      until a second staff member approves or rejects it (CHECK decided_by <> created_by); the facts never change and
--      a decision is final (guard trigger). Approval emits departure.fee_charged to that agency, with the fee id,
--      amount and currency (new outbox columns fee_id, amount, currency). booking.agency_invoice_line gains the
--      settlement role departure_fee and source_fee_id (the fee it bills, like source_hold_id for a hold; one live line
--      per fee), picked up by the bk_settlement_draft job. A draft partner terms clause departure_fees describes the
--      fee; the business owner approves it in the staff admin before GET /terms shows it.
--   3. Price adjustments (bk-17). New booking.departure_price_adjustments: a per-departure change of the tour line
--      price, adjust_pct (a fraction, -0.5000..1.0000) or a signed amount per traveller in one currency, with a
--      reason. Maker-checker (approved_by <> created_by); at most one in force and one pending per departure; a change
--      is a new row replacing the old (ended on approval); ended once (replaced | withdrawn | rejected). The quote
--      engine applies the one in force to the tp: lines on that departure after the agency discount.
--      booking.pricing_rules gains early_days and early_discount_pts (b2b and fixed_departure rules only): a quote
--      made on or before start_date - early_days takes early_discount_pts off the rule's margin.
--      booking.b2b_quote_lines gains price_note (jsonb): what the engine applied to the line (adjustment, early
--      booking, a price under the floor), NULL when nothing.
--   4. The departure board (bk-04). View booking.v_departure_occupancy: one row per departure with its trip plan,
--      seats (held, sold, allotted, unused allotment, free, occupancy %), minimum, status, the at-risk rule, the open
--      incident and how many agencies are on it. Held / sold / allotments by the same rules as app/b2b/departures.py
--      (USAGE_SQL, ALLOTMENTS_SQL): counted, never stored.
--   5. The outbox event types departure.updated and departure.fee_charged (CHECK replaced).
--
-- Class: contract (root ADR 0017 d3): ALTER TABLE on departures, outbox, agency_invoice_line, pricing_rules and
-- b2b_quote_lines (columns, CHECKs), the departures_outbox function and trigger replaced, a config row inserted, next to
-- three new tables and a view. So a migration-only PR first (MIG-4); the code PR raises readiness to bk-048. On Dev:
-- Infra Migration Apply once every job table is idle (root ADR 0017a). Needs bk-022 (outbox), bk-041 (agency invoice
-- lines), bk-044 (terms clauses), bk-046 (allotments) and bk-047 (outbox CHECKs of 1.7, pricing_rules.child_pct).
-- DM-7.1 rows for the three new tables: root docs/architecture/data-standards/02-data-management.md (AA-1073 root PR,
-- merged before the Infra copy). DM-6.1: fee and adjustment amounts conf:commercial; ops_note, departure_fees.note and
-- departure_price_adjustments.reason pii:free_text (staff text; never traveller data by rule, tagged in case);
-- meeting_point is a public place sent to agencies; no traveller or guide name anywhere.
-- Erasure (DM-6.7): the two guard triggers allow one move on any row, note / reason set to the fixed marker
-- '[redacted]' with every other column unchanged; ops_note is a plain column. It runs as bk_owner in a reviewed DB
-- Migrate run-script (root docs/legal/dsar-erasure-runbook.md); the app role gets no new grant for it.
--
-- Locks: ACCESS EXCLUSIVE for the nullable ADD COLUMNs (no rewrite) and the CHECK adds on departures, outbox,
-- agency_invoice_line, pricing_rules and b2b_quote_lines (tens to hundreds of rows); SHARE ROW EXCLUSIVE on the FK
-- targets for a moment. lock_timeout 5s.
-- Key guard: refuses to run when shared.schema_versions already holds bk-048 with another description.
-- Re-runnable (the integration tests replay every file): IF NOT EXISTS, DROP CONSTRAINT / TRIGGER IF EXISTS before each
-- ADD / CREATE, CREATE OR REPLACE FUNCTION / VIEW, ON CONFLICT DO NOTHING, grants repeat.
-- Undo (a later bk- file, after the code is reverted): DROP the view, the three new tables and their functions, DROP
-- the added columns and CHECKs, restore the bk-047 outbox CHECK and the bk-046 departures_outbox body and trigger
-- (outbox rows of the two new types deleted first), the bk-041 agency_invoice_line role / source CHECKs (departure_fee
-- lines deleted first) and DELETE the departure_fees clause row.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF current_user <> 'bk_owner' THEN
        RAISE EXCEPTION 'bk-048: expected to run as bk_owner (live owner of schema booking), running as %', current_user;
    END IF;
    IF to_regclass('booking.departure_allotments') IS NULL OR to_regclass('booking.agency_invoice_line') IS NULL
       OR to_regclass('booking.partner_terms_clause') IS NULL OR to_regclass('booking.b2b_desk_bookings') IS NULL
       OR to_regprocedure('booking.outbox_departure_event(uuid,text,text)') IS NULL
    THEN
        RAISE EXCEPTION 'bk-048: needs bk-022, bk-041, bk-044, bk-046 and bk-047 first';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.schema_versions
                WHERE version = 'bk-048' AND description NOT LIKE 'AA-1073 rest:%') THEN
        RAISE EXCEPTION 'bk-048: the key bk-048 is already held by another migration (not AA-1073 rest): renumber one';
    END IF;
END $$;

-- ── 1. Ops sheet ─────────────────────────────────────────────────────────────

ALTER TABLE booking.departures
    ADD COLUMN IF NOT EXISTS meeting_point TEXT,
    ADD COLUMN IF NOT EXISTS meeting_time TIME,
    ADD COLUMN IF NOT EXISTS ops_note TEXT;

ALTER TABLE booking.departures DROP CONSTRAINT IF EXISTS departures_ops_chk;
ALTER TABLE booking.departures ADD CONSTRAINT departures_ops_chk CHECK (
    (meeting_point IS NULL OR length(btrim(meeting_point)) BETWEEN 1 AND 300)
    AND (ops_note IS NULL OR length(btrim(ops_note)) BETWEEN 1 AND 2000));

COMMENT ON COLUMN booking.departures.meeting_point IS
    'bk-048 (AA-1073, bk-16): where the group meets on the start date (a public place: hotel lobby, station; never a traveller''s address). Sent to the agencies on the departure (event departure.updated, GET /departures).';
COMMENT ON COLUMN booking.departures.meeting_time IS
    'bk-048 (AA-1073, bk-16): the meeting time, local time of the meeting point, on the start date. Sent to the agencies like meeting_point.';
COMMENT ON COLUMN booking.departures.ops_note IS
    'pii:free_text; bk-048 (AA-1073, bk-16): staff operations note on the departure (never sent to an agency, never traveller data by rule).';

CREATE TABLE IF NOT EXISTS booking.departure_staff (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    departure_id   UUID NOT NULL REFERENCES booking.departures (id),
    role           TEXT NOT NULL,
    staff_user_id  TEXT REFERENCES booking.staff_users (cis_user_id),
    supplier_id    UUID REFERENCES booking.suppliers (id),
    assigned_by    TEXT NOT NULL,
    assigned_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT departure_staff_role_chk CHECK (role IN ('guide', 'tour_leader', 'driver')),
    CONSTRAINT departure_staff_who_chk CHECK ((staff_user_id IS NULL) <> (supplier_id IS NULL)),
    CONSTRAINT departure_staff_by_chk CHECK (length(assigned_by) BETWEEN 1 AND 128)
);

CREATE INDEX IF NOT EXISTS departure_staff_departure_idx ON booking.departure_staff (departure_id);
CREATE UNIQUE INDEX IF NOT EXISTS departure_staff_staff_uq
    ON booking.departure_staff (departure_id, role, staff_user_id) WHERE staff_user_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS departure_staff_supplier_uq
    ON booking.departure_staff (departure_id, role, supplier_id) WHERE supplier_id IS NOT NULL;

COMMENT ON TABLE booking.departure_staff IS
    'bk-048 (AA-1073, bk-16): who works a departure, by role (guide, tour_leader, driver): an AA staff member or the supplier that provides the person. No name, phone or e-mail of a guide is stored; never sent to an agency. An unassign deletes the row (audit_logs keeps the change).';

-- ── 2. Departure fees ────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.departure_fees (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    departure_id    UUID NOT NULL REFERENCES booking.departures (id),
    partner_id      UUID NOT NULL REFERENCES booking.b2b_partners (id),
    reason          TEXT NOT NULL,
    seats           SMALLINT NOT NULL,
    price_per_seat  NUMERIC(14,2) NOT NULL,
    currency        TEXT NOT NULL,
    amount          NUMERIC(14,2) NOT NULL,
    note            TEXT,
    status          TEXT NOT NULL DEFAULT 'pending',
    created_by      TEXT NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    decided_by      TEXT,
    decided_at      TIMESTAMPTZ,
    CONSTRAINT departure_fees_reason_chk CHECK (reason IN ('min_shortfall', 'allotment_unreleased', 'other')),
    CONSTRAINT departure_fees_money_chk CHECK (
        seats BETWEEN 1 AND 1000 AND price_per_seat > 0 AND currency ~ '^[A-Z]{3}$'
        AND amount = round(seats * price_per_seat, 2)),
    CONSTRAINT departure_fees_note_chk CHECK (
        (note IS NULL OR length(btrim(note)) BETWEEN 1 AND 300) AND (reason <> 'other' OR note IS NOT NULL)),
    CONSTRAINT departure_fees_status_chk CHECK (
        status IN ('pending', 'approved', 'rejected')
        AND (status = 'pending') = (decided_by IS NULL)
        AND (decided_by IS NULL) = (decided_at IS NULL)
        AND (decided_by IS NULL OR (decided_by <> created_by AND length(decided_by) BETWEEN 1 AND 128))
        AND (decided_at IS NULL OR decided_at >= created_at)),
    CONSTRAINT departure_fees_creator_chk CHECK (length(created_by) BETWEEN 1 AND 128)
);

CREATE INDEX IF NOT EXISTS departure_fees_departure_idx ON booking.departure_fees (departure_id);
CREATE INDEX IF NOT EXISTS departure_fees_partner_idx ON booking.departure_fees (partner_id, status);

COMMENT ON TABLE booking.departure_fees IS
    'bk-048 (AA-1073, bk-09): a fee AA charges one agency on one departure (minimum shortfall, unreleased allotment, other): seats x price per seat. Maker-checker (a second staff member approves or rejects; final); approval emits departure.fee_charged to the agency and the settlement draft bills it once (agency_invoice_line.source_fee_id, role departure_fee).';
COMMENT ON COLUMN booking.departure_fees.price_per_seat IS 'conf:commercial; the fee per seat in currency.';
COMMENT ON COLUMN booking.departure_fees.amount IS 'conf:commercial; seats x price_per_seat, what the agency is billed.';
COMMENT ON COLUMN booking.departure_fees.note IS
    'pii:free_text; why the fee is charged (staff text, required for reason other; never traveller data by rule).';

CREATE OR REPLACE FUNCTION booking.departure_fees_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'pending' THEN
            RAISE EXCEPTION 'a departure fee starts pending' USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
    END IF;
    -- Erasure (DM-6.7): the staff note may be set to the fixed marker, nothing else in the same update.
    IF NEW.note = '[redacted]' AND OLD.note IS DISTINCT FROM NEW.note
       AND (to_jsonb(NEW) - 'note') = (to_jsonb(OLD) - 'note') THEN
        RETURN NEW;
    END IF;
    IF (NEW.departure_id, NEW.partner_id, NEW.reason, NEW.seats, NEW.price_per_seat, NEW.currency, NEW.amount,
        NEW.note, NEW.created_by, NEW.created_at)
       IS DISTINCT FROM
       (OLD.departure_id, OLD.partner_id, OLD.reason, OLD.seats, OLD.price_per_seat, OLD.currency, OLD.amount,
        OLD.note, OLD.created_by, OLD.created_at) THEN
        RAISE EXCEPTION 'departure fee %: its facts never change (a change is a new fee)', OLD.id
            USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.status <> 'pending' AND (NEW.status, NEW.decided_by, NEW.decided_at)
                                   IS DISTINCT FROM (OLD.status, OLD.decided_by, OLD.decided_at) THEN
        RAISE EXCEPTION 'departure fee % is %: the decision is final', OLD.id, OLD.status
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.departure_fees_guard() IS
    'bk-048 (AA-1073): a departure fee starts pending, its facts never change and its approve / reject is final; on erasure (DM-6.7) note may be set to [redacted], alone.';

DROP TRIGGER IF EXISTS departure_fees_guard ON booking.departure_fees;
CREATE TRIGGER departure_fees_guard
    BEFORE INSERT OR UPDATE ON booking.departure_fees
    FOR EACH ROW EXECUTE FUNCTION booking.departure_fees_guard();

-- The outbox carries the fee of departure.fee_charged (ids and money, no personal data).
ALTER TABLE booking.outbox
    ADD COLUMN IF NOT EXISTS fee_id UUID,
    ADD COLUMN IF NOT EXISTS amount NUMERIC(14,2),
    ADD COLUMN IF NOT EXISTS currency CHAR(3);

ALTER TABLE booking.outbox DROP CONSTRAINT IF EXISTS outbox_fee_chk;
ALTER TABLE booking.outbox ADD CONSTRAINT outbox_fee_chk CHECK (
    (event_type = 'departure.fee_charged') = (fee_id IS NOT NULL)
    AND (fee_id IS NULL) = (amount IS NULL) AND (fee_id IS NULL) = (currency IS NULL)
    AND (currency IS NULL OR currency ~ '^[A-Z]{3}$'));

COMMENT ON COLUMN booking.outbox.fee_id IS 'bk-048 (AA-1073): departure.fee_charged, the booking.departure_fees row.';
COMMENT ON COLUMN booking.outbox.amount IS 'conf:commercial; bk-048 (AA-1073): departure.fee_charged, the fee amount.';
COMMENT ON COLUMN booking.outbox.currency IS 'bk-048 (AA-1073): departure.fee_charged, the fee currency.';

CREATE OR REPLACE FUNCTION booking.departure_fees_outbox() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    IF NEW.status = 'approved' AND OLD.status = 'pending' THEN
        INSERT INTO booking.outbox (stream, event_type, partner_id, departure_id, fee_id, amount, currency)
        VALUES ('b2b', 'departure.fee_charged', NEW.partner_id, NEW.departure_id, NEW.id, NEW.amount, NEW.currency);
    END IF;
    RETURN NULL;
END $$;

COMMENT ON FUNCTION booking.departure_fees_outbox() IS
    'bk-048 (AA-1073): departure.fee_charged to the fee''s agency when a second staff member approves the fee.';

DROP TRIGGER IF EXISTS departure_fees_outbox ON booking.departure_fees;
CREATE TRIGGER departure_fees_outbox
    AFTER UPDATE OF status ON booking.departure_fees
    FOR EACH ROW EXECUTE FUNCTION booking.departure_fees_outbox();

-- Settlement lines: the role departure_fee bills one approved fee (source_fee_id), once while not voided.
ALTER TABLE booking.agency_invoice_line
    ADD COLUMN IF NOT EXISTS source_fee_id UUID REFERENCES booking.departure_fees (id);

ALTER TABLE booking.agency_invoice_line DROP CONSTRAINT IF EXISTS agency_invoice_line_role_chk;
ALTER TABLE booking.agency_invoice_line ADD CONSTRAINT agency_invoice_line_role_chk CHECK (
    (invoice_kind = 'saas' AND line_role IN ('subscription', 'extra_seats', 'adjustment'))
    OR (invoice_kind = 'settlement'
        AND line_role IN ('deposit', 'balance', 'full', 'cancellation_fee', 'departure_fee', 'adjustment')));

ALTER TABLE booking.agency_invoice_line DROP CONSTRAINT IF EXISTS agency_invoice_line_source_chk;
ALTER TABLE booking.agency_invoice_line ADD CONSTRAINT agency_invoice_line_source_chk CHECK (
    (line_role IN ('deposit', 'balance', 'full', 'cancellation_fee')) = (source_hold_id IS NOT NULL)
    AND (line_role = 'departure_fee') = (source_fee_id IS NOT NULL)
    AND ((line_role IN ('subscription', 'extra_seats')) = (product IS NOT NULL AND plan_key IS NOT NULL)));

CREATE UNIQUE INDEX IF NOT EXISTS agency_invoice_line_fee_uq ON booking.agency_invoice_line (source_fee_id)
    WHERE source_fee_id IS NOT NULL AND NOT voided;

COMMENT ON COLUMN booking.agency_invoice_line.source_fee_id IS
    'bk-048 (AA-1073, bk-09): the approved departure fee a departure_fee line bills (one live line per fee).';

-- The terms clause that describes departure fees: a draft until the business owner approves it (bk-044 flow).
INSERT INTO booking.partner_terms_clause (code, position, heading, body, free_cancel_days, status, updated_by)
VALUES ('departure_fees', 20, 'Departure fees',
        'A fixed departure runs once it has sold its minimum number of seats. When an agency''s booking or seat '
        'allotment leaves a departure short, or allotted seats are kept past their release date without being used, AA '
        'may charge the agency a departure fee per seat concerned, at the rate AA states in writing for that '
        'departure. AA tells the agency the seats, the rate and the amount before the fee is invoiced, and the fee '
        'appears as its own line on the agency''s settlement invoice. No departure fee is charged when AA cancels a '
        'departure for its own reasons.',
        NULL, 'draft', 'system:bk-048')
ON CONFLICT (code) DO NOTHING;

-- ── 3. Price adjustments and the early-booking rule ──────────────────────────

CREATE TABLE IF NOT EXISTS booking.departure_price_adjustments (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    departure_id  UUID NOT NULL REFERENCES booking.departures (id),
    adjust_pct    NUMERIC(5,4),
    amount        NUMERIC(14,2),
    currency      TEXT,
    reason        TEXT NOT NULL,
    replaces_id   UUID REFERENCES booking.departure_price_adjustments (id),
    created_by    TEXT NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    approved_by   TEXT,
    approved_at   TIMESTAMPTZ,
    ended_at      TIMESTAMPTZ,
    ended_by      TEXT,
    end_reason    TEXT,
    CONSTRAINT departure_price_adjustments_value_chk CHECK (
        (adjust_pct IS NULL) <> (amount IS NULL)
        AND (amount IS NULL) = (currency IS NULL)
        AND (adjust_pct IS NULL OR (adjust_pct <> 0 AND adjust_pct BETWEEN -0.5 AND 1))
        AND (amount IS NULL OR (amount <> 0 AND amount BETWEEN -100000000 AND 100000000))
        AND (currency IS NULL OR currency ~ '^[A-Z]{3}$')),
    CONSTRAINT departure_price_adjustments_reason_chk CHECK (length(btrim(reason)) BETWEEN 1 AND 300),
    CONSTRAINT departure_price_adjustments_approved_chk CHECK (
        (approved_by IS NULL) = (approved_at IS NULL)
        AND (approved_by IS NULL OR (approved_by <> created_by AND length(approved_by) BETWEEN 1 AND 128))
        AND (approved_at IS NULL OR approved_at >= created_at)),
    CONSTRAINT departure_price_adjustments_ended_chk CHECK (
        (ended_at IS NULL) = (ended_by IS NULL) AND (ended_at IS NULL) = (end_reason IS NULL)
        AND (end_reason IS NULL OR end_reason IN ('replaced', 'withdrawn', 'rejected'))
        AND (end_reason IS DISTINCT FROM 'rejected' OR approved_at IS NULL)
        AND (end_reason NOT IN ('replaced', 'withdrawn') OR end_reason IS NULL OR approved_at IS NOT NULL)
        AND (ended_by IS NULL OR length(ended_by) BETWEEN 1 AND 128)),
    CONSTRAINT departure_price_adjustments_replaces_chk CHECK (replaces_id IS NULL OR replaces_id <> id),
    CONSTRAINT departure_price_adjustments_creator_chk CHECK (length(created_by) BETWEEN 1 AND 128)
);

CREATE INDEX IF NOT EXISTS departure_price_adjustments_departure_idx
    ON booking.departure_price_adjustments (departure_id);
CREATE INDEX IF NOT EXISTS departure_price_adjustments_replaces_idx
    ON booking.departure_price_adjustments (replaces_id) WHERE replaces_id IS NOT NULL;
-- At most one in force and one pending per departure.
CREATE UNIQUE INDEX IF NOT EXISTS departure_price_adjustments_in_force_uq
    ON booking.departure_price_adjustments (departure_id) WHERE approved_at IS NOT NULL AND ended_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS departure_price_adjustments_pending_uq
    ON booking.departure_price_adjustments (departure_id) WHERE approved_at IS NULL AND ended_at IS NULL;

COMMENT ON TABLE booking.departure_price_adjustments IS
    'bk-048 (AA-1073, bk-17): a change of the tour line price on one departure, a fraction (adjust_pct) or a signed amount per traveller in one currency, applied by the quote engine after the agency discount (a price under the floor margin is still sold and noted). Append-only facts; maker-checker; at most one in force per departure; a change is a new row replacing the old (ended on approval).';
COMMENT ON COLUMN booking.departure_price_adjustments.adjust_pct IS
    'conf:commercial; the fraction added to the line price (-0.1000 = 10 % off, 0.0500 = 5 % more).';
COMMENT ON COLUMN booking.departure_price_adjustments.amount IS
    'conf:commercial; the signed amount added per traveller (adults + children), in currency.';
COMMENT ON COLUMN booking.departure_price_adjustments.reason IS
    'pii:free_text; why the price of this departure changes (staff text; never traveller data by rule).';

CREATE OR REPLACE FUNCTION booking.departure_price_adjustments_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.approved_at IS NOT NULL OR NEW.ended_at IS NOT NULL THEN
            RAISE EXCEPTION 'a price adjustment starts pending: not approved or ended' USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.replaces_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM booking.departure_price_adjustments a
             WHERE a.id = NEW.replaces_id AND a.departure_id = NEW.departure_id) THEN
            RAISE EXCEPTION 'a price adjustment replaces one of the same departure' USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
    END IF;
    -- Erasure (DM-6.7): the staff reason may be set to the fixed marker, nothing else in the same update.
    IF NEW.reason = '[redacted]' AND OLD.reason IS DISTINCT FROM NEW.reason
       AND (to_jsonb(NEW) - 'reason') = (to_jsonb(OLD) - 'reason') THEN
        RETURN NEW;
    END IF;
    IF (NEW.departure_id, NEW.adjust_pct, NEW.amount, NEW.currency, NEW.reason, NEW.replaces_id, NEW.created_by,
        NEW.created_at)
       IS DISTINCT FROM
       (OLD.departure_id, OLD.adjust_pct, OLD.amount, OLD.currency, OLD.reason, OLD.replaces_id, OLD.created_by,
        OLD.created_at) THEN
        RAISE EXCEPTION 'price adjustment %: its facts never change (a change is a new adjustment)', OLD.id
            USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.ended_at IS NOT NULL AND (NEW.ended_at, NEW.ended_by, NEW.end_reason, NEW.approved_at, NEW.approved_by)
                                    IS DISTINCT FROM (OLD.ended_at, OLD.ended_by, OLD.end_reason, OLD.approved_at,
                                                      OLD.approved_by) THEN
        RAISE EXCEPTION 'price adjustment % is ended; it is final', OLD.id USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.approved_at IS NOT NULL AND (NEW.approved_at, NEW.approved_by) IS DISTINCT FROM (OLD.approved_at, OLD.approved_by)
    THEN
        RAISE EXCEPTION 'price adjustment %: approved once', OLD.id USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.departure_price_adjustments_guard() IS
    'bk-048 (AA-1073): a price adjustment starts pending, replaces only one of the same departure; its facts never change; approved once, ended once (final); on erasure (DM-6.7) reason may be set to [redacted], alone.';

DROP TRIGGER IF EXISTS departure_price_adjustments_guard ON booking.departure_price_adjustments;
CREATE TRIGGER departure_price_adjustments_guard
    BEFORE INSERT OR UPDATE ON booking.departure_price_adjustments
    FOR EACH ROW EXECUTE FUNCTION booking.departure_price_adjustments_guard();

ALTER TABLE booking.pricing_rules
    ADD COLUMN IF NOT EXISTS early_days SMALLINT,
    ADD COLUMN IF NOT EXISTS early_discount_pts NUMERIC(5,4);

ALTER TABLE booking.pricing_rules DROP CONSTRAINT IF EXISTS pricing_rules_early_chk;
ALTER TABLE booking.pricing_rules ADD CONSTRAINT pricing_rules_early_chk CHECK (
    (early_days IS NULL) = (early_discount_pts IS NULL)
    AND (early_days IS NULL
         OR (channel IN ('b2b', 'fixed_departure') AND early_days BETWEEN 1 AND 365
             AND early_discount_pts > 0 AND early_discount_pts <= target_margin)));

COMMENT ON COLUMN booking.pricing_rules.early_days IS
    'bk-048 (AA-1073, bk-17): b2b and fixed_departure rules; a quote made on or before start_date - early_days of the departure takes early_discount_pts off the margin (NULL = no early-booking discount).';
COMMENT ON COLUMN booking.pricing_rules.early_discount_pts IS
    'conf:commercial; bk-048 (AA-1073, bk-17): margin points taken off for an early booking (0.0300 = 3 points), at most the target margin.';

ALTER TABLE booking.b2b_quote_lines ADD COLUMN IF NOT EXISTS price_note JSONB;

ALTER TABLE booking.b2b_quote_lines DROP CONSTRAINT IF EXISTS b2b_quote_lines_price_note_chk;
ALTER TABLE booking.b2b_quote_lines ADD CONSTRAINT b2b_quote_lines_price_note_chk CHECK (
    price_note IS NULL OR (jsonb_typeof(price_note) = 'object' AND octet_length(price_note::text) <= 2000));

COMMENT ON COLUMN booking.b2b_quote_lines.price_note IS
    'conf:commercial; bk-048 (AA-1073, bk-17): what the quote engine applied to the line besides the rule and the agency discount: the departure price adjustment (id, pct or amount), the early-booking discount (days, points) and below_floor when the line sells under the floor margin. NULL when nothing.';

-- ── 4. Outbox: departure.updated and departure.fee_charged ───────────────────

ALTER TABLE booking.outbox DROP CONSTRAINT IF EXISTS outbox_event_type_chk;
ALTER TABLE booking.outbox ADD CONSTRAINT outbox_event_type_chk CHECK (event_type IN (
    'hold.expired', 'hold.extended', 'line.confirmed', 'line.declined', 'booking.cancelled',
    'booking.created_by_aa', 'booking.line_reduced', 'booking.fee_changed',
    'departure.guaranteed', 'departure.cancelled', 'departure.incident', 'departure.incident_cleared',
    'departure.at_risk', 'allotment.released', 'departure.updated', 'departure.fee_charged',
    'supply.upsert', 'supply.deactivate'));

CREATE OR REPLACE FUNCTION booking.departures_outbox() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    IF NEW.status IN ('guaranteed', 'cancelled') AND OLD.status IS DISTINCT FROM NEW.status THEN
        PERFORM booking.outbox_departure_event(NEW.id, 'departure.' || NEW.status, NULL);
    END IF;
    IF NEW.at_risk_at IS NOT NULL AND OLD.at_risk_at IS NULL AND NEW.status = 'scheduled' THEN
        PERFORM booking.outbox_departure_event(NEW.id, 'departure.at_risk', NULL);
    END IF;
    IF NEW.status <> 'cancelled'
       AND (NEW.meeting_point, NEW.meeting_time) IS DISTINCT FROM (OLD.meeting_point, OLD.meeting_time) THEN
        PERFORM booking.outbox_departure_event(NEW.id, 'departure.updated', NULL);
    END IF;
    RETURN NULL;
END $$;

COMMENT ON FUNCTION booking.departures_outbox() IS
    'bk-022 (AA-975), bk-046, bk-048 (AA-1073): departure.guaranteed / departure.cancelled on a status move, departure.at_risk when at_risk_at is first stamped on a scheduled departure, departure.updated when the meeting point or time changes on a departure that is not cancelled; fan-out to every agency with seats on it.';

DROP TRIGGER IF EXISTS departures_outbox ON booking.departures;
CREATE TRIGGER departures_outbox
    AFTER UPDATE OF status, at_risk_at, meeting_point, meeting_time ON booking.departures
    FOR EACH ROW EXECUTE FUNCTION booking.departures_outbox();

-- ── 5. The departure board view ──────────────────────────────────────────────

CREATE OR REPLACE VIEW booking.v_departure_occupancy AS
SELECT d.id AS departure_id,
       d.trip_plan_id,
       p.source_system,
       p.source_id,
       d.start_date,
       d.status,
       d.capacity,
       u.held,
       u.sold,
       a.allotted,
       a.allotment_unused,
       CASE WHEN d.status = 'cancelled' THEN 0
            ELSE greatest(d.capacity - u.held - u.sold - a.allotment_unused, 0) END AS free,
       CASE WHEN d.capacity > 0 THEN round(100.0 * (u.held + u.sold) / d.capacity, 1) END AS occupancy_pct,
       d.min_to_operate,
       (d.status = 'scheduled' AND d.at_risk_at IS NOT NULL AND d.min_to_operate > 0 AND u.sold < d.min_to_operate)
           AS at_risk,
       i.id AS open_incident_id,
       i.incident_code AS open_incident_code,
       u.agencies_count,
       d.auto_confirm,
       d.sales_cutoff_days,
       d.decision_days_before,
       d.meeting_point,
       d.meeting_time
FROM booking.departures d
JOIN booking.trip_plans p ON p.id = d.trip_plan_id
CROSS JOIN LATERAL (
    SELECT coalesce(sum(l.seats) FILTER (WHERE h.status = 'active' AND h.expires_at > now()), 0)::int AS held,
           coalesce(sum(l.seats) FILTER (
               WHERE h.status = 'confirmed' AND l.status NOT IN ('declined', 'cancelled')), 0)::int AS sold,
           count(DISTINCT h.partner_id) FILTER (
               WHERE (h.status = 'active' AND h.expires_at > now())
                  OR (h.status = 'confirmed' AND l.status NOT IN ('declined', 'cancelled')))::int AS agencies_count
    FROM booking.b2b_hold_lines l
    JOIN booking.b2b_holds h ON h.id = l.hold_id
    WHERE l.departure_id = d.id
) u
CROSS JOIN LATERAL (
    SELECT coalesce(sum(al.seats), 0)::int AS allotted,
           coalesce(sum(greatest(al.seats - coalesce((
               SELECT sum(hl.seats) FROM booking.b2b_hold_lines hl JOIN booking.b2b_holds hh ON hh.id = hl.hold_id
                WHERE hl.departure_id = al.departure_id AND hh.partner_id = al.partner_id
                  AND ((hh.status = 'active' AND hh.expires_at > now())
                       OR (hh.status = 'confirmed' AND hl.status NOT IN ('declined', 'cancelled')))), 0), 0)), 0)::int
               AS allotment_unused
    FROM booking.departure_allotments al
    WHERE al.departure_id = d.id AND al.approved_at IS NOT NULL AND al.ended_at IS NULL AND al.released_at IS NULL
) a
LEFT JOIN booking.departure_incidents i ON i.departure_id = d.id AND i.cleared_at IS NULL;

COMMENT ON VIEW booking.v_departure_occupancy IS
    'bk-048 (AA-1073, bk-04): the departure board, one row per departure: seats held (live holds), sold (confirmed lines not declined / cancelled), allotted and unused allotment (in force, not released), free (capacity - held - sold - unused allotment; 0 when cancelled), occupancy % ((held + sold) / capacity), the minimum and the at-risk rule, the open incident and how many agencies are on it. Same rules as app/b2b/departures.py; counted at read time, never stored.';

-- ── Grants (per object) ──────────────────────────────────────────────────────

REVOKE ALL ON booking.departure_staff FROM booking;
GRANT SELECT, INSERT, DELETE ON booking.departure_staff TO booking;

REVOKE ALL ON booking.departure_fees FROM booking;
GRANT SELECT, INSERT ON booking.departure_fees TO booking;
GRANT UPDATE (status, decided_by, decided_at) ON booking.departure_fees TO booking;

REVOKE ALL ON booking.departure_price_adjustments FROM booking;
GRANT SELECT, INSERT ON booking.departure_price_adjustments TO booking;
GRANT UPDATE (approved_by, approved_at, ended_at, ended_by, end_reason) ON booking.departure_price_adjustments TO booking;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON booking.v_departure_occupancy FROM booking;
GRANT SELECT ON booking.v_departure_occupancy TO booking;

-- outbox: column-level INSERT (bk-022) for the fee columns written by the departure_fees trigger.
GRANT INSERT (fee_id, amount, currency) ON booking.outbox TO booking;
-- departures, agency_invoice_line, pricing_rules, b2b_quote_lines: the table grants of bk-020 / bk-041 / bk-004 /
-- bk-019 cover the new columns.
GRANT EXECUTE ON FUNCTION booking.departures_outbox() TO booking;
GRANT EXECUTE ON FUNCTION booking.departure_fees_guard() TO booking;
GRANT EXECUTE ON FUNCTION booking.departure_fees_outbox() TO booking;
GRANT EXECUTE ON FUNCTION booking.departure_price_adjustments_guard() TO booking;

DO $$
BEGIN
    IF has_table_privilege('booking', 'booking.departure_fees', 'DELETE')
       OR has_column_privilege('booking', 'booking.departure_fees', 'amount', 'UPDATE')
       OR has_table_privilege('booking', 'booking.departure_price_adjustments', 'DELETE')
       OR has_column_privilege('booking', 'booking.departure_price_adjustments', 'adjust_pct', 'UPDATE') THEN
        RAISE EXCEPTION 'bk-048: role booking can delete or change a departure fee or a price adjustment';
    END IF;
    IF has_table_privilege('cis_app', 'booking.departure_fees', 'SELECT')
       OR has_table_privilege('cis_app', 'booking.departure_price_adjustments', 'SELECT')
       OR has_table_privilege('cis_app', 'booking.departure_staff', 'SELECT') THEN
        RAISE EXCEPTION 'bk-048: cis_app can read departure fees, price adjustments or departure staff';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-048', now(), 'AA-1073 rest: departures meeting_point / meeting_time / ops_note + departure_staff (ops sheet, departure.updated), departure_fees (maker-checker, departure.fee_charged, settlement role departure_fee via agency_invoice_line.source_fee_id, draft terms clause), departure_price_adjustments + pricing_rules early_days / early_discount_pts + b2b_quote_lines.price_note, view v_departure_occupancy, outbox fee columns and event types')
ON CONFLICT (version) DO NOTHING;

COMMIT;
