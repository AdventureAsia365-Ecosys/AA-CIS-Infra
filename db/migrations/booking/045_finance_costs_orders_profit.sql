-- Migration bk-045: AA-1074 (Booking finance; S275 study root docs/research/2026-11-10-odoo-tour-travel-plugin-comparison.md
-- items bk-05, bk-06, bk-07, bk-08, bk-10) — FX-normalised costs and the realised FX difference, departure shared costs
-- priced by the group size, supplier purchase orders, planned against actual supplier cost, profit per trip case,
-- departure and agency month.
--
-- Owner: AA-Booking (key bk-NNN). AA-CIS-Infra Migration Sync copies it byte for byte to
-- db/migrations/booking/045_finance_costs_orders_profit.sql; on Dev it is applied as bk_owner (the live owner of schema
-- booking since bk-014) by Infra Migration Apply once every job table is idle (root ADR 0017a), or by a person with DB
-- Migrate apply. Never run it from a laptop.
--
-- What:
--   1. booking.fx_plain_rate(currency, day): the approved plain rate in force on a day (rate_per_usd of the newest
--      APPROVED booking.fx_rates row dated on or before it, no buffer; 1 for USD; NULL when none). The SQL twin of
--      app/pricing/fx.py, used by the views below for rows without a snapshot.
--   2. FX snapshots (bk-10): supplier_bookings.fx_rate_per_usd / fx_as_of (set by the app when the booking is
--      confirmed) and supplier_bills.fx_rate_per_usd / fx_as_of (set when the bill is approved). Nullable: rows before
--      this file, and a currency without an approved rate, read the rate in force through 1.
--   3. booking.departure_costs (bk-05): a cost shared by the whole departure (a coach, a guide, a group entrance):
--      supplier + service, the rate band picked for the departure's sold seats (pricing 'rate', re-priced by the job
--      bk_departure_cost_recompute while not frozen) or a hand amount (pricing 'manual'), basis group / vehicle / day /
--      person, net in the rate currency. It is ordered through a supplier booking of the departure (supplier_booking_id,
--      set once); the row FREEZES (frozen_at) when that booking is requested (trigger below): money facts fixed from then.
--   4. supplier_bookings.departure_id + trip_case_id nullable, CHECK exactly one of the two: a departure-level supplier
--      booking orders a shared cost; it follows the same life (pending -> requested -> confirmed ...) and takes bill
--      lines like a case booking.
--   5. booking.supplier_orders (bk-06, PO-000123): one purchase order per supplier + currency + service month grouping
--      pending supplier bookings (supplier_bookings.supplier_order_id). draft -> sending (staff pressed Send: the
--      snapshot, total and address are fixed, the job bk_supplier_order_send is queued) -> sent (the e-mail left; the
--      lines are requested) ; draft / sending / sent -> cancelled (reason). confirmed / partly confirmed are derived
--      from the lines' answers (never stored). The snapshot is what the supplier saw: services, dates, nights, pax,
--      nets and AA references; never an agency name or a traveller name (DM-6.8).
--   6. supplier_bills.departure_id (bk-07): a bill of the shared costs of one departure (its lines name departure-level
--      bookings of that departure); a bill names a trip case or a departure, never both.
--   7. Guards replaced: supplier_bookings_guard (departure and order rules), supplier_bills_guard (departure_id is a
--      money fact), supplier_bill_items_guard (a departure-level booking has no trip case; a departure bill takes only
--      that departure's bookings).
--   8. Views (owner bk_owner, conf:commercial, staff only, never in booking.b2b.v1; app reads under pricing.read or
--      profit.read):
--        v_cost_variance        per supplier booking: planned net + USD, billed (approved / paid bill lines) + USD,
--                               variance (NULL until billed), variance_usd, fx_difference_usd (same native amount at
--                               the bill rate minus at the booking rate), best cost (billed, else planned while live).
--        v_departure_cost_share per departure cost x sold trip case: the case's share by seats.
--        v_case_profit          per B2B trip case with a confirmed hold: revenue (quote total, or the cancellation fee),
--                               quoted / planned / actual / best cost, profit and margin in USD and in the quote currency.
--        v_departure_profit     per departure: sold seats, revenue, case costs, shared costs, profit, profit per seat.
--        v_agency_profit_month  per agency x travel month (trip start).
--      USD rounding rule: every native amount is converted per line at its rate and rounded half up to the cent; totals
--      are sums of those cents (so a total equals the sum of its lines). Shares: net x seats / sold seats, rounded half
--      up to the cent per case (the rounding remainder stays with the departure).
--
-- Class: contract (root ADR 0017 d3): ALTERs, CHECKs, FKs and replaced trigger functions on existing tables, next to two
-- new tables and the views. So a migration-only PR first (MIG-4); the code PR raises readiness to bk-045. On Dev: Infra
-- Migration Apply once every job table is idle (root ADR 0017a). Needs bk-019 / bk-020 (b2b holds, departures), bk-026
-- (supplier_bookings), bk-030 (supplier bills), bk-007 (policy_approvals of FX rows).
-- DM-7.1 rows for the two new tables: root docs/architecture/data-standards/02-data-management.md (AA-1074 root PR,
-- merged before the Infra copy). DM-6.1 tags below (supplier_orders.sent_to pii:contact, notes / reasons
-- pii:free_text, money conf:commercial).
--
-- Locks: ACCESS EXCLUSIVE on supplier_bookings and supplier_bills for nullable ADD COLUMNs, DROP NOT NULL and the
-- CHECK / FK adds (a scan of a few hundred rows at most), on departures / suppliers / services / supplier_rates for the
-- FKs of the new tables (SHARE ROW EXCLUSIVE, a moment). lock_timeout 5s.
-- Key guard: refuses to run when shared.schema_versions already holds bk-045 with another description (a second file
-- under the same number would be silently skipped by ON CONFLICT DO NOTHING).
-- Re-runnable (the integration tests replay every file): IF NOT EXISTS, DROP CONSTRAINT / TRIGGER IF EXISTS before each
-- ADD / CREATE, CREATE OR REPLACE FUNCTION / VIEW (views dropped first: their column lists are new), grants repeat.
-- Undo (a later bk- file, after the code is reverted and while no departure-level supplier booking exists): DROP the five
-- views, booking.fx_plain_rate, the tables supplier_orders and departure_costs (and their functions and sequence), the
-- added columns; restore NOT NULL on supplier_bookings.trip_case_id and the bk-026 / bk-030 bodies of the three guards.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF current_user <> 'bk_owner' THEN
        RAISE EXCEPTION 'bk-045: expected to run as bk_owner (live owner of schema booking), running as %', current_user;
    END IF;
    IF to_regclass('booking.supplier_bookings') IS NULL OR to_regclass('booking.supplier_bills') IS NULL
       OR to_regclass('booking.departures') IS NULL OR to_regclass('booking.b2b_holds') IS NULL
       OR to_regclass('booking.policy_approvals') IS NULL OR to_regclass('booking.b2b_cancellations') IS NULL THEN
        RAISE EXCEPTION 'bk-045: needs bk-007, bk-019 .. bk-021, bk-026 and bk-030 first';
    END IF;
    -- The key bk-045 is this file's (AA-1074 finance). Another file registered under it would make the
    -- ON CONFLICT DO NOTHING below record nothing while readiness reports bk-045: stop instead of passing silently.
    IF EXISTS (SELECT 1 FROM shared.schema_versions
                WHERE version = 'bk-045' AND description NOT LIKE 'AA-1074:%') THEN
        RAISE EXCEPTION 'bk-045: the key bk-045 is already held by another migration (not AA-1074 finance): renumber one';
    END IF;
END $$;

-- ── 1. The approved plain FX rate in force ───────────────────────────────────

CREATE OR REPLACE FUNCTION booking.fx_plain_rate(p_currency TEXT, p_on DATE) RETURNS NUMERIC
    LANGUAGE sql STABLE
    SET search_path = pg_catalog
AS $$
    SELECT CASE
        WHEN p_currency IS NULL OR p_on IS NULL THEN NULL
        WHEN p_currency = 'USD' THEN 1::numeric
        ELSE (SELECT f.rate_per_usd
                FROM booking.fx_rates f
                JOIN booking.policy_approvals a ON a.fx_rate_id = f.id
               WHERE f.currency = p_currency AND f.as_of <= p_on
               ORDER BY f.as_of DESC
               LIMIT 1)
    END
$$;

COMMENT ON FUNCTION booking.fx_plain_rate(TEXT, DATE) IS
    'bk-045 (AA-1074, bk-10): rate_per_usd of the newest APPROVED fx_rates row of the currency dated on or before the day (no buffer); 1 for USD; NULL when none. Same choice as app.pricing.repository.fx_rates_in_force.';

-- ── 2. FX snapshots ──────────────────────────────────────────────────────────

ALTER TABLE booking.supplier_bookings
    ADD COLUMN IF NOT EXISTS fx_rate_per_usd NUMERIC(18, 8),
    ADD COLUMN IF NOT EXISTS fx_as_of DATE,
    ADD COLUMN IF NOT EXISTS departure_id UUID,
    ADD COLUMN IF NOT EXISTS supplier_order_id UUID;

ALTER TABLE booking.supplier_bills
    ADD COLUMN IF NOT EXISTS fx_rate_per_usd NUMERIC(18, 8),
    ADD COLUMN IF NOT EXISTS fx_as_of DATE,
    ADD COLUMN IF NOT EXISTS departure_id UUID;

ALTER TABLE booking.supplier_bookings DROP CONSTRAINT IF EXISTS supplier_bookings_fx_chk;
ALTER TABLE booking.supplier_bookings ADD CONSTRAINT supplier_bookings_fx_chk CHECK (
    (fx_rate_per_usd IS NULL) = (fx_as_of IS NULL) AND (fx_rate_per_usd IS NULL OR fx_rate_per_usd > 0));
ALTER TABLE booking.supplier_bills DROP CONSTRAINT IF EXISTS supplier_bills_fx_chk;
ALTER TABLE booking.supplier_bills ADD CONSTRAINT supplier_bills_fx_chk CHECK (
    (fx_rate_per_usd IS NULL) = (fx_as_of IS NULL) AND (fx_rate_per_usd IS NULL OR fx_rate_per_usd > 0));

COMMENT ON COLUMN booking.supplier_bookings.fx_rate_per_usd IS
    'conf:commercial; bk-045 (AA-1074): plain approved rate of net_currency per USD when the booking was confirmed (1 for USD); NULL before bk-045 or with no approved rate (views read the rate in force then).';
COMMENT ON COLUMN booking.supplier_bookings.fx_as_of IS 'bk-045 (AA-1074): as_of of the FX row behind fx_rate_per_usd (the confirm day for USD).';
COMMENT ON COLUMN booking.supplier_bills.fx_rate_per_usd IS
    'conf:commercial; bk-045 (AA-1074): plain approved rate of the bill currency per USD when the bill was approved (1 for USD).';
COMMENT ON COLUMN booking.supplier_bills.fx_as_of IS 'bk-045 (AA-1074): as_of of the FX row behind fx_rate_per_usd.';

-- ── 3. Departure shared costs ────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.departure_costs (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    departure_id         UUID NOT NULL REFERENCES booking.departures (id),
    supplier_id          UUID NOT NULL REFERENCES booking.suppliers (id),
    service_id           UUID REFERENCES booking.services (id),
    supplier_rate_id     UUID REFERENCES booking.supplier_rates (id),
    item_description     TEXT NOT NULL,
    service_date         DATE NOT NULL,
    basis                TEXT NOT NULL,
    quantity             SMALLINT NOT NULL DEFAULT 1,
    pricing              TEXT NOT NULL,
    unit_amount          NUMERIC(16, 2) NOT NULL,
    net_amount           NUMERIC(16, 2) NOT NULL,
    currency             CHAR(3) NOT NULL,
    priced_for_pax       SMALLINT NOT NULL,
    priced_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    frozen_at            TIMESTAMPTZ,
    supplier_booking_id  UUID REFERENCES booking.supplier_bookings (id),
    status               TEXT NOT NULL DEFAULT 'active',
    cancelled_at         TIMESTAMPTZ,
    cancelled_by         TEXT,
    cancel_reason        TEXT,
    notes                TEXT,
    created_by           TEXT NOT NULL,
    updated_by           TEXT,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT departure_costs_basis_chk CHECK (basis IN ('group', 'vehicle', 'day', 'person')),
    CONSTRAINT departure_costs_pricing_chk CHECK (
        pricing IN ('rate', 'manual') AND ((pricing = 'rate') = (supplier_rate_id IS NOT NULL))),
    CONSTRAINT departure_costs_quantity_chk CHECK (quantity BETWEEN 1 AND 999),
    CONSTRAINT departure_costs_amount_chk CHECK (unit_amount >= 0 AND net_amount >= 0),
    CONSTRAINT departure_costs_currency_chk CHECK (currency ~ '^[A-Z]{3}$'),
    CONSTRAINT departure_costs_pax_chk CHECK (priced_for_pax BETWEEN 0 AND 1000),
    CONSTRAINT departure_costs_frozen_chk CHECK (frozen_at IS NULL OR supplier_booking_id IS NOT NULL),
    CONSTRAINT departure_costs_status_chk CHECK (status IN ('active', 'cancelled')),
    CONSTRAINT departure_costs_cancel_chk CHECK (
        ((status = 'cancelled') = (cancelled_at IS NOT NULL AND cancelled_by IS NOT NULL AND cancel_reason IS NOT NULL))
        AND (cancel_reason IS NULL OR length(cancel_reason) BETWEEN 1 AND 500)),
    CONSTRAINT departure_costs_text_chk CHECK (
        length(item_description) BETWEEN 1 AND 500 AND (notes IS NULL OR length(notes) BETWEEN 1 AND 2000)
        AND length(created_by) BETWEEN 1 AND 128)
);

CREATE INDEX IF NOT EXISTS departure_costs_departure_idx ON booking.departure_costs (departure_id, service_date);
CREATE UNIQUE INDEX IF NOT EXISTS departure_costs_booking_uq
    ON booking.departure_costs (supplier_booking_id) WHERE supplier_booking_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS departure_costs_supplier_idx ON booking.departure_costs (supplier_id);
CREATE INDEX IF NOT EXISTS departure_costs_service_idx ON booking.departure_costs (service_id) WHERE service_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS departure_costs_rate_idx
    ON booking.departure_costs (supplier_rate_id) WHERE supplier_rate_id IS NOT NULL;

COMMENT ON TABLE booking.departure_costs IS
    'bk-045 (AA-1074, bk-05): a cost shared by a whole departure (coach, guide, group entrance), priced from the supplier rate band of the departure''s sold seats (pricing rate, re-priced by bk_departure_cost_recompute until frozen) or by hand (manual). net_amount = unit_amount x quantity (x priced_for_pax for basis person). Ordered through one departure-level supplier booking; frozen when that booking is requested. Split to trip cases by seats in v_departure_cost_share.';
COMMENT ON COLUMN booking.departure_costs.unit_amount IS 'conf:commercial; net per unit from the rate (or by hand).';
COMMENT ON COLUMN booking.departure_costs.net_amount IS 'conf:commercial; total net of the departure for this cost.';
COMMENT ON COLUMN booking.departure_costs.notes IS 'pii:free_text; also conf:commercial (staff notes on the cost).';
COMMENT ON COLUMN booking.departure_costs.cancel_reason IS 'pii:free_text; why staff removed the cost.';

CREATE OR REPLACE TRIGGER departure_costs_set_updated_at
    BEFORE UPDATE ON booking.departure_costs
    FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();

CREATE OR REPLACE FUNCTION booking.departure_costs_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'active' OR NEW.frozen_at IS NOT NULL OR NEW.supplier_booking_id IS NOT NULL THEN
            RAISE EXCEPTION 'a departure cost starts active, not ordered and not frozen' USING ERRCODE = 'check_violation';
        END IF;
        IF EXISTS (SELECT 1 FROM booking.departures d WHERE d.id = NEW.departure_id AND d.status = 'cancelled') THEN
            RAISE EXCEPTION 'departure % is cancelled: it takes no new cost', NEW.departure_id
                USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
    END IF;
    IF (NEW.departure_id, NEW.created_by, NEW.created_at) IS DISTINCT FROM (OLD.departure_id, OLD.created_by, OLD.created_at)
    THEN
        RAISE EXCEPTION 'departure cost %: departure and creator never change', OLD.id USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.status = 'cancelled' THEN
        RAISE EXCEPTION 'departure cost % is cancelled; it is final', OLD.id USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.supplier_booking_id IS NOT NULL AND NEW.supplier_booking_id IS DISTINCT FROM OLD.supplier_booking_id THEN
        RAISE EXCEPTION 'departure cost %: its supplier booking never changes', OLD.id USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.frozen_at IS NOT NULL THEN
        IF NEW.frozen_at IS DISTINCT FROM OLD.frozen_at THEN
            RAISE EXCEPTION 'departure cost %: frozen once, never thawed', OLD.id USING ERRCODE = 'check_violation';
        END IF;
        IF (NEW.supplier_id, NEW.service_id, NEW.supplier_rate_id, NEW.basis, NEW.quantity, NEW.pricing,
            NEW.unit_amount, NEW.net_amount, NEW.currency, NEW.priced_for_pax, NEW.service_date)
           IS DISTINCT FROM
           (OLD.supplier_id, OLD.service_id, OLD.supplier_rate_id, OLD.basis, OLD.quantity, OLD.pricing,
            OLD.unit_amount, OLD.net_amount, OLD.currency, OLD.priced_for_pax, OLD.service_date) THEN
            RAISE EXCEPTION 'departure cost % is frozen (ordered from the supplier): its money facts are fixed', OLD.id
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.departure_costs_guard() IS
    'bk-045 (AA-1074): a departure cost starts active, unordered, unfrozen, on a departure that is not cancelled; departure / creator never change; cancelled is final; the supplier booking is set once; frozen is final and fixes the money facts.';

DROP TRIGGER IF EXISTS departure_costs_guard ON booking.departure_costs;
CREATE TRIGGER departure_costs_guard
    BEFORE INSERT OR UPDATE ON booking.departure_costs
    FOR EACH ROW EXECUTE FUNCTION booking.departure_costs_guard();

-- ── 5. Supplier purchase orders ──────────────────────────────────────────────

CREATE SEQUENCE IF NOT EXISTS booking.supplier_order_code_seq;

CREATE TABLE IF NOT EXISTS booking.supplier_orders (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code           TEXT NOT NULL DEFAULT ('PO-' || lpad(nextval('booking.supplier_order_code_seq')::text, 6, '0')),
    supplier_id    UUID NOT NULL REFERENCES booking.suppliers (id),
    currency       CHAR(3) NOT NULL,
    service_month  DATE NOT NULL,
    status         TEXT NOT NULL DEFAULT 'draft',
    total_net      NUMERIC(16, 2),
    snapshot       JSONB,
    sent_to        TEXT,
    redirected     BOOLEAN NOT NULL DEFAULT false,
    send_requested_at TIMESTAMPTZ,
    sent_by        TEXT,
    sent_at        TIMESTAMPTZ,
    delivery_ref   TEXT,
    send_error     TEXT,
    note           TEXT,
    cancelled_at   TIMESTAMPTZ,
    cancelled_by   TEXT,
    cancel_reason  TEXT,
    created_by     TEXT NOT NULL,
    updated_by     TEXT,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT supplier_orders_code_chk CHECK (code ~ '^PO-[0-9]{6,}$'),
    CONSTRAINT supplier_orders_currency_chk CHECK (currency ~ '^[A-Z]{3}$'),
    CONSTRAINT supplier_orders_month_chk CHECK (
        service_month = date_trunc('month', service_month)::date AND service_month >= DATE '2020-01-01'),
    CONSTRAINT supplier_orders_status_chk CHECK (status IN ('draft', 'sending', 'sent', 'cancelled')),
    CONSTRAINT supplier_orders_send_chk CHECK (
        (send_requested_at IS NULL) = (sent_by IS NULL)
        AND (send_requested_at IS NULL OR (snapshot IS NOT NULL AND total_net IS NOT NULL AND sent_to IS NOT NULL))
        AND (status NOT IN ('sending', 'sent') OR send_requested_at IS NOT NULL)
        AND ((status = 'sent') = (sent_at IS NOT NULL AND delivery_ref IS NOT NULL)
             OR (status = 'cancelled' AND sent_at IS NOT NULL))),
    CONSTRAINT supplier_orders_total_chk CHECK (total_net IS NULL OR total_net >= 0),
    CONSTRAINT supplier_orders_cancel_chk CHECK (
        ((status = 'cancelled') = (cancelled_at IS NOT NULL AND cancelled_by IS NOT NULL AND cancel_reason IS NOT NULL))
        AND (cancel_reason IS NULL OR length(cancel_reason) BETWEEN 1 AND 500)),
    CONSTRAINT supplier_orders_text_chk CHECK (
        (sent_to IS NULL OR (length(sent_to) <= 254 AND sent_to LIKE '%_@_%'))
        AND (delivery_ref IS NULL OR length(delivery_ref) BETWEEN 1 AND 200)
        AND (send_error IS NULL OR length(send_error) BETWEEN 1 AND 500)
        AND (note IS NULL OR length(note) BETWEEN 1 AND 2000)
        AND length(created_by) BETWEEN 1 AND 128),
    CONSTRAINT supplier_orders_snapshot_chk CHECK (snapshot IS NULL OR jsonb_typeof(snapshot) = 'object')
);

CREATE UNIQUE INDEX IF NOT EXISTS supplier_orders_code_uq ON booking.supplier_orders (code);
CREATE INDEX IF NOT EXISTS supplier_orders_supplier_idx ON booking.supplier_orders (supplier_id, service_month DESC);
CREATE INDEX IF NOT EXISTS supplier_orders_status_idx ON booking.supplier_orders (status, created_at DESC);

COMMENT ON TABLE booking.supplier_orders IS
    'bk-045 (AA-1074, bk-06): a purchase order to one supplier (PO-000123) grouping pending supplier bookings of one currency and service month. draft -> sending (Send pressed: snapshot, total and address fixed, bk_supplier_order_send queued) -> sent (e-mail left, lines requested); -> cancelled with a reason. Confirmed / partly confirmed are derived from the lines. The snapshot names services, dates, pax, nets and AA references only: no agency or traveller name (DM-6.8).';
COMMENT ON COLUMN booking.supplier_orders.total_net IS 'conf:commercial; sum of the line nets when Send was pressed.';
COMMENT ON COLUMN booking.supplier_orders.snapshot IS 'conf:commercial; the order as the supplier received it (lines, nets, references).';
COMMENT ON COLUMN booking.supplier_orders.sent_to IS
    'pii:contact; the supplier''s booking e-mail the order was addressed to (outside prod the mail goes to the staff inbox, redirected = true).';
COMMENT ON COLUMN booking.supplier_orders.note IS 'pii:free_text; staff note printed on the order.';
COMMENT ON COLUMN booking.supplier_orders.cancel_reason IS 'pii:free_text; why the order was cancelled.';

CREATE OR REPLACE TRIGGER supplier_orders_set_updated_at
    BEFORE UPDATE ON booking.supplier_orders
    FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();

CREATE OR REPLACE FUNCTION booking.supplier_orders_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'draft' OR NEW.send_requested_at IS NOT NULL THEN
            RAISE EXCEPTION 'a supplier order starts draft' USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
    END IF;
    IF (NEW.code, NEW.supplier_id, NEW.currency, NEW.service_month, NEW.created_by, NEW.created_at)
       IS DISTINCT FROM (OLD.code, OLD.supplier_id, OLD.currency, OLD.service_month, OLD.created_by, OLD.created_at) THEN
        RAISE EXCEPTION 'supplier order %: code, supplier, currency, month and creator never change', OLD.code
            USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.status = 'cancelled' THEN
        RAISE EXCEPTION 'supplier order % is cancelled; it is final', OLD.code USING ERRCODE = 'check_violation';
    END IF;
    IF NOT ((OLD.status = NEW.status)
            OR (OLD.status = 'draft' AND NEW.status IN ('sending', 'cancelled'))
            OR (OLD.status = 'sending' AND NEW.status IN ('sent', 'draft', 'cancelled'))
            OR (OLD.status = 'sent' AND NEW.status = 'cancelled')) THEN
        RAISE EXCEPTION 'supplier order %: % -> % is not allowed', OLD.code, OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.status = 'sent' AND (NEW.snapshot, NEW.total_net, NEW.sent_to, NEW.sent_at, NEW.delivery_ref, NEW.sent_by)
       IS DISTINCT FROM (OLD.snapshot, OLD.total_net, OLD.sent_to, OLD.sent_at, OLD.delivery_ref, OLD.sent_by) THEN
        RAISE EXCEPTION 'supplier order % was sent: what the supplier received is fixed', OLD.code
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.supplier_orders_guard() IS
    'bk-045 (AA-1074): an order starts draft; code / supplier / currency / month / creator never change; draft -> sending | cancelled, sending -> sent | draft (mail refused) | cancelled, sent -> cancelled; cancelled is final; a sent order''s snapshot and delivery facts are fixed.';

DROP TRIGGER IF EXISTS supplier_orders_guard ON booking.supplier_orders;
CREATE TRIGGER supplier_orders_guard
    BEFORE INSERT OR UPDATE ON booking.supplier_orders
    FOR EACH ROW EXECUTE FUNCTION booking.supplier_orders_guard();

-- ── 4. Departure-level supplier bookings, order lines ────────────────────────

ALTER TABLE booking.supplier_bookings ALTER COLUMN trip_case_id DROP NOT NULL;
ALTER TABLE booking.supplier_bookings DROP CONSTRAINT IF EXISTS supplier_bookings_departure_fk;
ALTER TABLE booking.supplier_bookings ADD CONSTRAINT supplier_bookings_departure_fk
    FOREIGN KEY (departure_id) REFERENCES booking.departures (id);
ALTER TABLE booking.supplier_bookings DROP CONSTRAINT IF EXISTS supplier_bookings_order_fk;
ALTER TABLE booking.supplier_bookings ADD CONSTRAINT supplier_bookings_order_fk
    FOREIGN KEY (supplier_order_id) REFERENCES booking.supplier_orders (id);
ALTER TABLE booking.supplier_bookings DROP CONSTRAINT IF EXISTS supplier_bookings_owner_chk;
ALTER TABLE booking.supplier_bookings ADD CONSTRAINT supplier_bookings_owner_chk CHECK (
    num_nonnulls(trip_case_id, departure_id) = 1
    AND (departure_id IS NULL OR (version_item_id IS NULL AND b2b_hold_id IS NULL AND voucher_file_id IS NULL)));

CREATE INDEX IF NOT EXISTS supplier_bookings_departure_idx
    ON booking.supplier_bookings (departure_id, created_at) WHERE departure_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS supplier_bookings_order_idx
    ON booking.supplier_bookings (supplier_order_id) WHERE supplier_order_id IS NOT NULL;

COMMENT ON COLUMN booking.supplier_bookings.departure_id IS
    'bk-045 (AA-1074): a departure-level booking (a shared cost of booking.departure_costs); exactly one of trip_case_id and departure_id.';
COMMENT ON COLUMN booking.supplier_bookings.supplier_order_id IS
    'bk-045 (AA-1074): the purchase order this booking is a line of (same supplier and currency); fixed once the order left draft.';

CREATE OR REPLACE FUNCTION booking.supplier_bookings_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_channel  TEXT;
    v_item_ok  BOOLEAN;
    v_order    RECORD;
BEGIN
    SELECT channel INTO v_channel FROM booking.trip_cases WHERE id = NEW.trip_case_id;
    IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'pending' THEN
            RAISE EXCEPTION 'a supplier booking starts pending, not %', NEW.status USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.departure_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM booking.departures d WHERE d.id = NEW.departure_id AND d.status = 'cancelled'
        ) THEN
            RAISE EXCEPTION 'departure % is cancelled: nothing is booked for it', NEW.departure_id
                USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.version_item_id IS NOT NULL THEN
            SELECT true INTO v_item_ok
              FROM booking.trip_case_version_itinerary i
              JOIN booking.trip_case_versions v ON v.id = i.trip_case_version_id
             WHERE i.id = NEW.version_item_id AND v.trip_case_id = NEW.trip_case_id
               AND v.is_approved AND v.deleted_at IS NULL;
            IF v_item_ok IS NULL THEN
                RAISE EXCEPTION 'version item % is not an item of the approved version of trip case %',
                    NEW.version_item_id, NEW.trip_case_id USING ERRCODE = 'check_violation';
            END IF;
        END IF;
        IF NEW.b2b_hold_id IS NOT NULL THEN
            IF v_channel IS DISTINCT FROM 'b2b' OR NOT EXISTS (
                SELECT 1 FROM booking.b2b_holds h WHERE h.id = NEW.b2b_hold_id AND h.trip_case_id = NEW.trip_case_id
            ) THEN
                RAISE EXCEPTION 'hold % is not the hold of B2B trip case %', NEW.b2b_hold_id, NEW.trip_case_id
                    USING ERRCODE = 'check_violation';
            END IF;
        END IF;
    ELSE
        IF (NEW.trip_case_id, NEW.departure_id, NEW.version_item_id, NEW.b2b_hold_id, NEW.b2b_line_ref, NEW.code,
            NEW.created_by, NEW.created_at)
           IS DISTINCT FROM
           (OLD.trip_case_id, OLD.departure_id, OLD.version_item_id, OLD.b2b_hold_id, OLD.b2b_line_ref, OLD.code,
            OLD.created_by, OLD.created_at) THEN
            RAISE EXCEPTION 'supplier booking %: case, departure, item, B2B line and code never change', OLD.code
                USING ERRCODE = 'check_violation';
        END IF;
        IF OLD.status NOT IN ('pending', 'requested')
           AND (NEW.supplier_id, NEW.hotel_room_type_id, NEW.service_id, NEW.item_description, NEW.service_date,
                NEW.nights, NEW.pax, NEW.net_amount, NEW.net_currency)
               IS DISTINCT FROM
               (OLD.supplier_id, OLD.hotel_room_type_id, OLD.service_id, OLD.item_description, OLD.service_date,
                OLD.nights, OLD.pax, OLD.net_amount, OLD.net_currency) THEN
            RAISE EXCEPTION 'supplier booking % is %: its supplier and service facts are fixed', OLD.code, OLD.status
                USING ERRCODE = 'check_violation';
        END IF;
        IF OLD.fx_rate_per_usd IS NOT NULL
           AND (NEW.fx_rate_per_usd, NEW.fx_as_of) IS DISTINCT FROM (OLD.fx_rate_per_usd, OLD.fx_as_of)
           AND NOT (OLD.status = 'confirmed' AND NEW.status = 'requested') THEN
            RAISE EXCEPTION 'supplier booking %: its FX snapshot is fixed until it is re-requested', OLD.code
                USING ERRCODE = 'check_violation';
        END IF;
        IF OLD.supplier_order_id IS NOT NULL AND NEW.supplier_order_id IS DISTINCT FROM OLD.supplier_order_id THEN
            SELECT status, code INTO v_order FROM booking.supplier_orders WHERE id = OLD.supplier_order_id;
            IF v_order.status IS DISTINCT FROM 'draft' AND v_order.status IS DISTINCT FROM 'cancelled' THEN
                RAISE EXCEPTION 'supplier booking % is a line of order % (%): it stays on it', OLD.code, v_order.code,
                    v_order.status USING ERRCODE = 'check_violation';
            END IF;
        END IF;
    END IF;
    IF NEW.supplier_order_id IS NOT NULL
       AND NEW.supplier_order_id IS DISTINCT FROM (CASE WHEN TG_OP = 'UPDATE' THEN OLD.supplier_order_id END) THEN
        SELECT status, code, supplier_id, currency INTO v_order FROM booking.supplier_orders
         WHERE id = NEW.supplier_order_id;
        IF v_order.status IS DISTINCT FROM 'draft' THEN
            RAISE EXCEPTION 'order % is %: lines join a draft order only', coalesce(v_order.code, 'missing'),
                coalesce(v_order.status, 'missing') USING ERRCODE = 'check_violation';
        END IF;
        IF v_order.supplier_id <> NEW.supplier_id OR v_order.currency IS DISTINCT FROM NEW.net_currency THEN
            RAISE EXCEPTION 'supplier booking % is not of the supplier and currency of order %', NEW.code, v_order.code
                USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.status <> 'pending' THEN
            RAISE EXCEPTION 'supplier booking % is %: an order line starts pending', NEW.code, NEW.status
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    IF v_channel = 'b2c' AND NEW.b2b_hold_id IS NOT NULL THEN
        RAISE EXCEPTION 'a B2C trip case has no B2B hold line' USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.voucher_file_id IS NOT NULL AND NEW.voucher_file_id IS DISTINCT FROM
       (CASE WHEN TG_OP = 'UPDATE' THEN OLD.voucher_file_id END) THEN
        IF v_channel = 'b2b' THEN
            RAISE EXCEPTION 'no voucher file on a B2B trip case (DM-6.8)' USING ERRCODE = 'check_violation';
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM booking.ops_files f
             WHERE f.id = NEW.voucher_file_id AND f.status = 'active' AND f.kind = 'supplier_voucher'
               AND f.entity_type = 'supplier_booking' AND f.entity_id = NEW.id
        ) THEN
            RAISE EXCEPTION 'file % is not an active voucher of supplier booking %', NEW.voucher_file_id, NEW.code
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.supplier_bookings_guard() IS
    'bk-026 (AA-682) + bk-045 (AA-1074): a supplier booking starts pending, belongs to an item of the approved version of its case (or to a departure that is not cancelled), names the hold of its own B2B case only; case / departure / item / line / code never change; supplier and service facts change only while pending / requested; the FX snapshot changes only on a re-request; an order line joins a draft order of its supplier and currency while pending and leaves only a draft or cancelled order; the voucher is an active supplier_voucher file of this booking and never on a B2B case.';

-- The shared cost behind a departure-level booking freezes when the booking is requested (ordered from the supplier).
CREATE OR REPLACE FUNCTION booking.supplier_bookings_freeze_departure_cost() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    IF NEW.departure_id IS NOT NULL AND NEW.status = 'requested' THEN
        UPDATE booking.departure_costs SET frozen_at = now(), updated_by = NEW.updated_by
         WHERE supplier_booking_id = NEW.id AND frozen_at IS NULL;
    END IF;
    RETURN NULL;
END $$;

COMMENT ON FUNCTION booking.supplier_bookings_freeze_departure_cost() IS
    'bk-045 (AA-1074, bk-05): when a departure-level supplier booking is requested, its departure cost freezes (the price the supplier was asked for).';

DROP TRIGGER IF EXISTS supplier_bookings_freeze_departure_cost ON booking.supplier_bookings;
CREATE TRIGGER supplier_bookings_freeze_departure_cost
    AFTER UPDATE OF status ON booking.supplier_bookings
    FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status)
    EXECUTE FUNCTION booking.supplier_bookings_freeze_departure_cost();

-- ── 6. Supplier bills of a departure ─────────────────────────────────────────

ALTER TABLE booking.supplier_bills DROP CONSTRAINT IF EXISTS supplier_bills_departure_fk;
ALTER TABLE booking.supplier_bills ADD CONSTRAINT supplier_bills_departure_fk
    FOREIGN KEY (departure_id) REFERENCES booking.departures (id);
ALTER TABLE booking.supplier_bills DROP CONSTRAINT IF EXISTS supplier_bills_scope_chk;
ALTER TABLE booking.supplier_bills ADD CONSTRAINT supplier_bills_scope_chk CHECK (num_nonnulls(trip_case_id, departure_id) <= 1);
CREATE INDEX IF NOT EXISTS supplier_bills_departure_idx
    ON booking.supplier_bills (departure_id) WHERE departure_id IS NOT NULL;

COMMENT ON COLUMN booking.supplier_bills.departure_id IS
    'bk-045 (AA-1074, bk-07): a bill of the shared costs of one departure (its lines name that departure''s bookings); a bill names a trip case or a departure, never both.';

CREATE OR REPLACE FUNCTION booking.supplier_bills_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_lines   INTEGER;
    v_sum     NUMERIC;
    v_paid    NUMERIC;
    v_live    INTEGER;
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'received' OR NEW.approved_at IS NOT NULL OR NEW.paid_at IS NOT NULL
           OR NEW.cancelled_at IS NOT NULL OR NEW.fx_rate_per_usd IS NOT NULL THEN
            RAISE EXCEPTION 'a supplier bill starts received' USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.document_file_id IS NOT NULL THEN
            RAISE EXCEPTION 'a supplier bill gets its document after it exists (upload with the bill as entity)'
                USING ERRCODE = 'check_violation';
        END IF;
        NEW.facts_edited_by := NEW.created_by;  -- whoever enters the bill set its facts
        RETURN NEW;
    END IF;
    IF (NEW.code, NEW.created_by, NEW.created_at, NEW.idempotency_key, NEW.request_sha256)
       IS DISTINCT FROM (OLD.code, OLD.created_by, OLD.created_at, OLD.idempotency_key, OLD.request_sha256) THEN
        RAISE EXCEPTION 'supplier bill %: code, creator and key never change', OLD.code
            USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.status = 'cancelled' THEN
        RAISE EXCEPTION 'supplier bill % is cancelled; it is final', OLD.code USING ERRCODE = 'check_violation';
    END IF;
    -- The facts and the document change only while the bill is received (the working draft) and stays received.
    IF (OLD.status <> 'received' OR NEW.status <> 'received')
       AND (NEW.supplier_id, NEW.trip_case_id, NEW.departure_id, NEW.bill_number, NEW.currency, NEW.amount,
            NEW.issue_date, NEW.due_date, NEW.document_file_id)
           IS DISTINCT FROM
           (OLD.supplier_id, OLD.trip_case_id, OLD.departure_id, OLD.bill_number, OLD.currency, OLD.amount,
            OLD.issue_date, OLD.due_date, OLD.document_file_id) THEN
        RAISE EXCEPTION 'supplier bill %: its facts and document change only while it is received', OLD.code
            USING ERRCODE = 'check_violation';
    END IF;
    -- The FX snapshot is taken with the approval and fixed from then.
    IF (NEW.fx_rate_per_usd, NEW.fx_as_of) IS DISTINCT FROM (OLD.fx_rate_per_usd, OLD.fx_as_of)
       AND NOT (OLD.status = 'received' AND NEW.status = 'approved' AND OLD.fx_rate_per_usd IS NULL) THEN
        RAISE EXCEPTION 'supplier bill %: its FX snapshot is set once, with the approval', OLD.code
            USING ERRCODE = 'check_violation';
    END IF;
    -- Maker-checker input: who last set the money facts. A fact change records its author (updated_by); otherwise
    -- the app may only mark the editor of the lines (itself, while received) before it replaces them.
    IF (NEW.supplier_id, NEW.trip_case_id, NEW.departure_id, NEW.bill_number, NEW.currency, NEW.amount, NEW.issue_date,
        NEW.due_date)
       IS DISTINCT FROM
       (OLD.supplier_id, OLD.trip_case_id, OLD.departure_id, OLD.bill_number, OLD.currency, OLD.amount, OLD.issue_date,
        OLD.due_date) THEN
        IF NEW.updated_by IS NULL THEN
            RAISE EXCEPTION 'supplier bill %: say who changes its facts (updated_by)', OLD.code
                USING ERRCODE = 'check_violation';
        END IF;
        NEW.facts_edited_by := NEW.updated_by;
    ELSIF NEW.facts_edited_by IS DISTINCT FROM OLD.facts_edited_by
          AND (OLD.status <> 'received' OR NEW.status <> 'received'
               OR NEW.facts_edited_by IS DISTINCT FROM NEW.updated_by) THEN
        RAISE EXCEPTION 'supplier bill %: facts_edited_by names the person editing a received bill (updated_by)',
            OLD.code USING ERRCODE = 'check_violation';
    END IF;
    -- The lines were checked against the supplier, the case and the departure when they were added: those stay while
    -- lines exist.
    IF (NEW.supplier_id, NEW.trip_case_id, NEW.departure_id) IS DISTINCT FROM (OLD.supplier_id, OLD.trip_case_id, OLD.departure_id)
       AND EXISTS (SELECT 1 FROM booking.supplier_bill_items WHERE bill_id = OLD.id) THEN
        RAISE EXCEPTION 'supplier bill %: remove its lines before changing the supplier, the trip case or the departure',
            OLD.code USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.document_file_id IS NOT NULL AND NEW.document_file_id IS DISTINCT FROM OLD.document_file_id THEN
        PERFORM 1 FROM booking.ops_files f
         WHERE f.id = NEW.document_file_id AND f.status = 'active' AND f.kind = 'supplier_bill'
           AND f.entity_type = 'supplier_bill' AND f.entity_id = NEW.id
           FOR SHARE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'file % is not an active document of supplier bill %', NEW.document_file_id, NEW.code
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    -- Approve: another person (CHECK too), at least one line, the lines add up to the amount.
    IF OLD.status = 'received' AND NEW.status = 'approved' THEN
        IF NEW.approved_by IS NOT DISTINCT FROM NEW.created_by THEN
            RAISE EXCEPTION 'supplier bill %: maker-checker, the person who entered it cannot approve it', OLD.code
                USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.approved_by IS NOT DISTINCT FROM NEW.facts_edited_by THEN
            RAISE EXCEPTION 'supplier bill %: maker-checker, the person who last changed its amounts cannot approve it',
                OLD.code USING ERRCODE = 'check_violation';
        END IF;
        SELECT count(*), coalesce(sum(amount), 0) INTO v_lines, v_sum
          FROM booking.supplier_bill_items WHERE bill_id = OLD.id;
        IF v_lines = 0 THEN
            RAISE EXCEPTION 'supplier bill %: match it to at least one confirmed supplier booking before approving',
                OLD.code USING ERRCODE = 'check_violation';
        END IF;
        IF v_sum <> NEW.amount THEN
            RAISE EXCEPTION 'supplier bill %: the lines add up to % but the bill is %', OLD.code, v_sum, NEW.amount
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    IF OLD.status IN ('approved', 'paid') AND NEW.approved_by IS DISTINCT FROM OLD.approved_by THEN
        RAISE EXCEPTION 'supplier bill %: the approval is fixed', OLD.code USING ERRCODE = 'check_violation';
    END IF;
    -- Money states are derived from the live payouts (paid only by payouts; a void steps back).
    IF NEW.status IN ('approved', 'paid') OR (NEW.status = 'cancelled' AND OLD.status IN ('approved', 'paid')) THEN
        SELECT coalesce(sum(o.amount), 0), count(*) INTO v_paid, v_live
          FROM booking.supplier_payouts o WHERE o.bill_id = OLD.id AND o.voided_at IS NULL;
        IF NEW.status = 'cancelled' AND v_live > 0 THEN
            RAISE EXCEPTION 'supplier bill % has % live payout(s); void them before cancelling', OLD.code, v_live
                USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.status = 'paid' AND v_paid < NEW.amount THEN
            RAISE EXCEPTION 'supplier bill %: paid needs payouts of % (live payouts: %)', OLD.code, NEW.amount, v_paid
                USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.status = 'approved' AND v_paid >= NEW.amount THEN
            RAISE EXCEPTION 'supplier bill %: its payouts cover it, it is paid', OLD.code
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.supplier_bills_guard() IS
    'bk-030 (AA-682 S4) + bk-045 (AA-1074): a bill starts received with no document and no FX snapshot; code / creator / key never change; cancelled is final; facts (departure included) and document change only while received (supplier, case and departure stay while lines exist); the FX snapshot is set once with the approval; the document is an active supplier_bill file of this bill; facts_edited_by follows the author of a fact change; approve needs another person than created_by and facts_edited_by, >= 1 line and lines = amount; approved / paid equal the live payouts; cancel needs no live payout.';

CREATE OR REPLACE FUNCTION booking.supplier_bill_items_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_bill      booking.supplier_bills%ROWTYPE;
    v_booking   RECORD;
BEGIN
    -- Lock the bill first: a line change racing an approve waits for it and then sees the bill approved.
    SELECT * INTO v_bill FROM booking.supplier_bills
     WHERE id = CASE WHEN TG_OP = 'DELETE' THEN OLD.bill_id ELSE NEW.bill_id END FOR UPDATE;
    IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'a supplier bill line is never updated; delete it and add it again while the bill is received'
            USING ERRCODE = 'check_violation';
    END IF;
    IF v_bill.status IS DISTINCT FROM 'received' THEN
        RAISE EXCEPTION 'supplier bill % is %: its lines are fixed', v_bill.code, coalesce(v_bill.status, 'missing')
            USING ERRCODE = 'check_violation';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    -- Maker-checker: the person adding a line is the bill's last editor (the app marks the bill first), so whoever
    -- changes the lines can never approve them.
    IF NEW.created_by IS NULL OR NEW.created_by IS DISTINCT FROM v_bill.facts_edited_by THEN
        RAISE EXCEPTION 'supplier bill %: a line is added by the person editing the bill (set facts_edited_by first)',
            v_bill.code USING ERRCODE = 'check_violation';
    END IF;
    SELECT sb.code, sb.status, sb.supplier_id, sb.trip_case_id, sb.departure_id, tc.channel INTO v_booking
      FROM booking.supplier_bookings sb LEFT JOIN booking.trip_cases tc ON tc.id = sb.trip_case_id
     WHERE sb.id = NEW.supplier_booking_id;
    IF v_booking.status IS DISTINCT FROM 'confirmed' THEN
        RAISE EXCEPTION 'supplier booking % is %: a bill line names a confirmed booking',
            coalesce(v_booking.code, NEW.supplier_booking_id::text), coalesce(v_booking.status, 'missing')
            USING ERRCODE = 'check_violation';
    END IF;
    IF v_booking.supplier_id <> v_bill.supplier_id THEN
        RAISE EXCEPTION 'supplier booking % is with another supplier than bill %', v_booking.code, v_bill.code
            USING ERRCODE = 'check_violation';
    END IF;
    IF v_bill.trip_case_id IS NOT NULL AND v_booking.trip_case_id IS DISTINCT FROM v_bill.trip_case_id THEN
        RAISE EXCEPTION 'supplier booking % is of another trip case than bill %', v_booking.code, v_bill.code
            USING ERRCODE = 'check_violation';
    END IF;
    IF v_bill.departure_id IS NOT NULL AND v_booking.departure_id IS DISTINCT FROM v_bill.departure_id THEN
        RAISE EXCEPTION 'supplier booking % is not a shared cost of the departure of bill %', v_booking.code, v_bill.code
            USING ERRCODE = 'check_violation';
    END IF;
    -- DM-6.8: a bill with a document (it names guests) never covers a B2B booking.
    IF v_booking.channel = 'b2b' AND EXISTS (
        SELECT 1 FROM booking.ops_files f
         WHERE f.entity_type = 'supplier_bill' AND f.entity_id = v_bill.id AND f.status = 'active'
    ) THEN
        RAISE EXCEPTION 'supplier bill % has a document; it cannot cover the B2B booking % (DM-6.8)', v_bill.code,
            v_booking.code USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.supplier_bill_items_guard() IS
    'bk-030 (AA-682 S4) + bk-045 (AA-1074): lines change (insert / delete, never update) only while the bill is received, after locking the bill row; a line is added by the bill''s facts_edited_by (maker-checker); a line names a confirmed booking of the bill''s supplier (and of its case or departure); a bill with a document never covers a B2B booking (DM-6.8).';

-- ── 8. Views ─────────────────────────────────────────────────────────────────

DROP VIEW IF EXISTS booking.v_agency_profit_month;
DROP VIEW IF EXISTS booking.v_departure_profit;
DROP VIEW IF EXISTS booking.v_case_profit;
DROP VIEW IF EXISTS booking.v_departure_cost_share;
DROP VIEW IF EXISTS booking.v_departure_cost_lines;
DROP VIEW IF EXISTS booking.v_cost_variance;

-- Per supplier booking: planned (its net at its snapshot rate, else the rate in force on its confirm day, else today),
-- billed = lines of APPROVED / PAID bills (a received bill is not a fact yet), each converted at its bill's rate.
CREATE VIEW booking.v_cost_variance AS
SELECT x.supplier_booking_id, x.code, x.trip_case_id, x.departure_id, x.supplier_id, x.status, x.live,
       x.planned_net, x.planned_currency, x.planned_fx_rate_per_usd, x.planned_usd,
       x.billed, x.billed_lines, x.billed_net, x.billed_other_currency, x.billed_usd,
       CASE WHEN x.billed AND NOT x.billed_other_currency THEN x.billed_net - x.planned_net END AS variance,
       CASE WHEN x.billed THEN x.billed_usd - x.planned_usd END AS variance_usd,
       CASE WHEN x.billed THEN x.fx_difference_usd END AS fx_difference_usd,
       CASE WHEN x.billed THEN x.billed_usd WHEN x.live THEN x.planned_usd ELSE 0::numeric END AS cost_usd,
       (x.planned_currency IS NOT NULL AND x.planned_fx_rate_per_usd IS NULL) OR x.billed_rate_missing AS fx_missing
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
             coalesce(bl.rate_missing, false) AS billed_rate_missing
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
    'bk-045 (AA-1074, bk-07 / bk-10): conf:commercial. Per supplier booking: planned net and USD (snapshot rate, else the rate in force on the confirm day, else today), billed = lines of approved / paid bills (native sum in the planned currency, USD at each bill''s rate), variance and variance_usd only once billed, fx_difference_usd = the billed native amount at the bill rate minus at the booking rate, cost_usd = billed, else planned while live, else 0. USD per line rounded half up to the cent.';

-- Per departure cost: planned USD, its booking's billed / best cost when ordered.
CREATE VIEW booking.v_departure_cost_lines AS
SELECT dc.id AS departure_cost_id, dc.departure_id, dc.supplier_id, dc.service_id, dc.status, dc.currency::text AS currency,
       dc.net_amount, dc.supplier_booking_id, dc.frozen_at,
       coalesce(cv.planned_usd, round(dc.net_amount / booking.fx_plain_rate(dc.currency::text, current_date), 2))
           AS planned_usd,
       cv.billed, cv.billed_usd,
       CASE WHEN cv.supplier_booking_id IS NULL
            THEN round(dc.net_amount / booking.fx_plain_rate(dc.currency::text, current_date), 2)
            ELSE cv.cost_usd END AS cost_usd
  FROM booking.departure_costs dc
  LEFT JOIN booking.v_cost_variance cv ON cv.supplier_booking_id = dc.supplier_booking_id
 WHERE dc.status = 'active';

COMMENT ON VIEW booking.v_departure_cost_lines IS
    'bk-045 (AA-1074, bk-05): conf:commercial. Active departure costs with planned USD (their booking''s planned USD once ordered, else at today''s rate) and the best cost (billed, else planned).';

-- Seats per sold trip case of a departure (confirmed hold, line not declined / cancelled), the departures.py rule.
CREATE VIEW booking.v_departure_cost_share AS
WITH seats AS (
    SELECT l.departure_id, h.trip_case_id, sum(l.seats)::int AS seats
      FROM booking.b2b_hold_lines l
      JOIN booking.b2b_holds h ON h.id = l.hold_id
     WHERE h.status = 'confirmed' AND h.trip_case_id IS NOT NULL AND l.departure_id IS NOT NULL
       AND l.status NOT IN ('declined', 'cancelled')
     GROUP BY l.departure_id, h.trip_case_id
), sold AS (
    SELECT departure_id, sum(seats)::int AS sold FROM seats GROUP BY departure_id
)
SELECT c.departure_cost_id, c.departure_id, s.trip_case_id, s.seats, t.sold AS departure_seats, c.currency,
       c.net_amount,
       round(c.net_amount * s.seats / t.sold, 2) AS share_net,
       round(c.planned_usd * s.seats / t.sold, 2) AS share_planned_usd,
       CASE WHEN c.billed THEN round(c.billed_usd * s.seats / t.sold, 2) END AS share_billed_usd,
       round(c.cost_usd * s.seats / t.sold, 2) AS share_cost_usd
  FROM booking.v_departure_cost_lines c
  JOIN seats s ON s.departure_id = c.departure_id
  JOIN sold t ON t.departure_id = c.departure_id AND t.sold > 0;

COMMENT ON VIEW booking.v_departure_cost_share IS
    'bk-045 (AA-1074, bk-05): conf:commercial. Each active departure cost split to the sold trip cases of its departure by seats (net x seats / sold seats, half up to the cent per case; the remainder stays with the departure).';

-- Per B2B trip case with a confirmed hold. Revenue = the quote total, or the cancellation fee once cancelled, in the
-- quote currency and in USD at the quote's plain rate (the agency tier discount is already inside the quote price).
CREATE VIEW booking.v_case_profit AS
WITH own AS (
    SELECT cv.trip_case_id,
           count(*) FILTER (WHERE cv.live OR cv.billed)::int AS bookings,
           sum(cv.planned_usd) FILTER (WHERE cv.live) AS planned_usd,
           sum(cv.billed_usd) FILTER (WHERE cv.billed) AS billed_usd,
           sum(cv.billed_usd) FILTER (WHERE cv.billed AND cv.status = 'cancelled') AS cancel_fee_usd,
           sum(cv.cost_usd) AS cost_usd,
           count(*) FILTER (WHERE cv.status = 'confirmed' AND NOT cv.billed)::int AS unbilled,
           bool_or(cv.fx_missing AND (cv.live OR cv.billed)) AS fx_missing
      FROM booking.v_cost_variance cv
     WHERE cv.trip_case_id IS NOT NULL
     GROUP BY cv.trip_case_id
), shared AS (
    SELECT trip_case_id, sum(share_planned_usd) AS planned_usd, sum(share_billed_usd) AS billed_usd,
           sum(share_cost_usd) AS cost_usd
      FROM booking.v_departure_cost_share GROUP BY trip_case_id
), base AS (
    SELECT tc.id AS trip_case_id, tc.code, tc.status, tc.start_date, tc.end_date, tc.pax,
           h.partner_id, h.id AS hold_id,
           (SELECT l.departure_id FROM booking.b2b_hold_lines l
             WHERE l.hold_id = h.id AND l.departure_id IS NOT NULL ORDER BY l.line_no LIMIT 1) AS departure_id,
           q.currency::text AS currency,
           CASE WHEN q.currency = 'USD' THEN 1::numeric ELSE q.fx_rate_per_usd END AS fx_rate_per_usd,
           c.id IS NOT NULL AS cancelled,
           CASE WHEN c.id IS NOT NULL THEN c.fee_amount ELSE q.total_b2b_price END AS revenue,
           (SELECT round(sum(ql.net_cost_usd), 2) FROM booking.b2b_quote_lines ql WHERE ql.quote_id = q.id)
               AS quoted_cost_usd
      FROM booking.trip_cases tc
      JOIN booking.b2b_holds h ON h.trip_case_id = tc.id AND h.status = 'confirmed'
      JOIN booking.b2b_quotes q ON q.id = h.quote_id
      LEFT JOIN booking.b2b_cancellations c ON c.trip_case_id = tc.id
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
    'bk-045 (AA-1074, bk-08): conf:commercial, staff only (profit.read), never in booking.b2b.v1. Per B2B trip case with a confirmed hold: revenue (quote total, or the cancellation fee) in the quote currency and USD at the quote''s plain rate; costs in USD: quoted (quote lines), planned (live supplier bookings + departure share), actual (approved bills incl. supplier cancellation fees + share), best (cost_usd: billed, else planned, else the quote while no booking exists); profit_usd, profit (quote currency), margin (fraction of revenue).';

CREATE VIEW booking.v_departure_profit AS
WITH cases AS (
    SELECT departure_id, count(*)::int AS cases, sum(revenue_usd) AS revenue_usd,
           sum(cost_usd - shared_cost_usd) AS case_cost_usd, bool_or(fx_missing) AS fx_missing
      FROM booking.v_case_profit WHERE departure_id IS NOT NULL GROUP BY departure_id
), shared AS (
    SELECT departure_id, count(*)::int AS cost_lines, sum(planned_usd) AS planned_usd, sum(cost_usd) AS cost_usd,
           sum(billed_usd) FILTER (WHERE billed) AS billed_usd
      FROM booking.v_departure_cost_lines GROUP BY departure_id
), unlinked AS (
    -- Departure-level bookings that are not behind an active departure cost (a removed cost still billed).
    SELECT cv.departure_id, sum(cv.cost_usd) AS cost_usd
      FROM booking.v_cost_variance cv
     WHERE cv.departure_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM booking.departure_costs dc
                        WHERE dc.supplier_booking_id = cv.supplier_booking_id AND dc.status = 'active')
     GROUP BY cv.departure_id
), seats AS (
    SELECT l.departure_id, sum(l.seats)::int AS sold
      FROM booking.b2b_hold_lines l JOIN booking.b2b_holds h ON h.id = l.hold_id
     WHERE h.status = 'confirmed' AND l.departure_id IS NOT NULL AND l.status NOT IN ('declined', 'cancelled')
     GROUP BY l.departure_id
), totals AS (
    SELECT d.id AS departure_id, d.trip_plan_id, d.start_date, d.status, d.capacity,
           coalesce(st.sold, 0) AS sold_seats,
           coalesce(c.cases, 0) AS cases,
           coalesce(c.revenue_usd, 0) AS revenue_usd,
           coalesce(c.case_cost_usd, 0) AS case_cost_usd,
           coalesce(s.cost_lines, 0) AS shared_cost_lines,
           coalesce(s.planned_usd, 0) AS shared_planned_usd,
           coalesce(s.cost_usd, 0) + coalesce(u.cost_usd, 0) AS shared_cost_usd,
           coalesce(c.fx_missing, false) AS fx_missing
      FROM booking.departures d
      LEFT JOIN cases c ON c.departure_id = d.id
      LEFT JOIN shared s ON s.departure_id = d.id
      LEFT JOIN unlinked u ON u.departure_id = d.id
      LEFT JOIN seats st ON st.departure_id = d.id
     WHERE c.departure_id IS NOT NULL OR s.departure_id IS NOT NULL OR u.departure_id IS NOT NULL
)
SELECT departure_id, trip_plan_id, start_date, status, capacity, sold_seats, cases, revenue_usd, case_cost_usd,
       shared_cost_lines, shared_planned_usd, shared_cost_usd, fx_missing,
       case_cost_usd + shared_cost_usd AS cost_usd,
       revenue_usd - case_cost_usd - shared_cost_usd AS profit_usd,
       CASE WHEN sold_seats > 0 THEN round((revenue_usd - case_cost_usd - shared_cost_usd) / sold_seats, 2) END
           AS profit_per_seat_usd,
       CASE WHEN revenue_usd > 0 THEN round((revenue_usd - case_cost_usd - shared_cost_usd) / revenue_usd, 4) END
           AS margin
  FROM totals;

COMMENT ON VIEW booking.v_departure_profit IS
    'bk-045 (AA-1074, bk-08): conf:commercial, staff only (profit.read). Per departure with a sold case or a shared cost: sold seats, revenue and own case costs of its trip cases, the full shared cost (best estimate, rounding remainder included), profit, profit per sold seat and margin, in USD.';

CREATE VIEW booking.v_agency_profit_month AS
SELECT partner_id, date_trunc('month', start_date)::date AS travel_month,
       count(*)::int AS cases,
       count(*) FILTER (WHERE cancelled)::int AS cancelled_cases,
       sum(revenue_usd) AS revenue_usd,
       sum(cost_usd) AS cost_usd,
       sum(profit_usd) AS profit_usd,
       CASE WHEN sum(revenue_usd) > 0 THEN round(sum(profit_usd) / sum(revenue_usd), 4) END AS margin,
       bool_or(fx_missing) AS fx_missing
  FROM booking.v_case_profit
 WHERE start_date IS NOT NULL
 GROUP BY partner_id, date_trunc('month', start_date)::date;

COMMENT ON VIEW booking.v_agency_profit_month IS
    'bk-045 (AA-1074, bk-08): conf:commercial, staff only (profit.read). Per agency (b2b partner) and travel month (trip start): cases, revenue, best cost, profit and margin in USD.';

-- ── Grants (per object) ──────────────────────────────────────────────────────

REVOKE ALL ON booking.departure_costs FROM booking;
GRANT SELECT, INSERT, UPDATE ON booking.departure_costs TO booking;

REVOKE ALL ON booking.supplier_orders FROM booking;
GRANT SELECT, INSERT, UPDATE ON booking.supplier_orders TO booking;
GRANT USAGE, SELECT ON SEQUENCE booking.supplier_order_code_seq TO booking;

-- supplier_bills: the column grants of bk-030 plus the departure and the FX snapshot.
GRANT UPDATE (departure_id, fx_rate_per_usd, fx_as_of) ON booking.supplier_bills TO booking;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON booking.v_cost_variance FROM booking;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON booking.v_departure_cost_lines FROM booking;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON booking.v_departure_cost_share FROM booking;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON booking.v_case_profit FROM booking;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON booking.v_departure_profit FROM booking;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON booking.v_agency_profit_month FROM booking;
GRANT SELECT ON booking.v_cost_variance, booking.v_departure_cost_lines, booking.v_departure_cost_share,
    booking.v_case_profit, booking.v_departure_profit, booking.v_agency_profit_month TO booking;

GRANT EXECUTE ON FUNCTION booking.fx_plain_rate(TEXT, DATE) TO booking;
GRANT EXECUTE ON FUNCTION booking.departure_costs_guard() TO booking;
GRANT EXECUTE ON FUNCTION booking.supplier_orders_guard() TO booking;
GRANT EXECUTE ON FUNCTION booking.supplier_bookings_guard() TO booking;
GRANT EXECUTE ON FUNCTION booking.supplier_bookings_freeze_departure_cost() TO booking;
GRANT EXECUTE ON FUNCTION booking.supplier_bills_guard() TO booking;
GRANT EXECUTE ON FUNCTION booking.supplier_bill_items_guard() TO booking;

DO $$
BEGIN
    IF has_table_privilege('booking', 'booking.departure_costs', 'DELETE')
       OR has_table_privilege('booking', 'booking.supplier_orders', 'DELETE')
       OR has_table_privilege('booking', 'booking.v_case_profit', 'INSERT') THEN
        RAISE EXCEPTION 'bk-045: role booking can delete a cost or an order, or write a profit view';
    END IF;
    IF has_table_privilege('cis_app', 'booking.departure_costs', 'SELECT')
       OR has_table_privilege('cis_app', 'booking.supplier_orders', 'SELECT')
       OR has_table_privilege('cis_app', 'booking.v_case_profit', 'SELECT')
       OR has_table_privilege('cis_app', 'booking.v_cost_variance', 'SELECT') THEN
        RAISE EXCEPTION 'bk-045: cis_app can read Booking costs or profit';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-045', now(), 'AA-1074: FX snapshots on supplier bookings / bills + fx_plain_rate, departure_costs (shared costs by group size, frozen when ordered), departure-level supplier bookings, supplier_orders (PO-), supplier_bills.departure_id, guards replaced, views v_cost_variance / v_departure_cost_lines / v_departure_cost_share / v_case_profit / v_departure_profit / v_agency_profit_month')
ON CONFLICT (version) DO NOTHING;

COMMIT;
