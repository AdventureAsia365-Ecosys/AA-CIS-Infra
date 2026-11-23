-- Migration bk-065: AA-1149 part 1 (S288; S285 advisory r2 items T15, B13, B12 label) — a sold tour becomes one
-- supplier booking per component, frozen at sale, and a "can operate" check with an admin sale exception.
--
-- Owner: AA-Booking (key bk-NNN). AA-CIS-Infra Migration Sync copies it byte for byte to
-- db/migrations/booking/065_tour_split_operable.sql and Migration Apply applies it on Dev as bk_owner once every job
-- table is idle (root ADR 0017a). Never run it from a laptop.
--
-- Why: a trip plan (tp:) line of a B2B booking is priced from its components (app.b2b.components), but only the line
-- total is stored, so Generate on the Suppliers tab makes no supplier booking for a sold tour (ops add every hotel
-- night, transfer and guide by hand), and a later edit of the tour's components cannot be told apart from what was
-- sold. A tour can also be sold to agencies while a night has no hotel or a supplier is not active.
--
-- What:
--   1. booking.b2b_quote_line_parts (append-only; role booking INSERT, SELECT): one row per component of each tp:
--      quote line, written by the quote calculation itself in the transaction that stores the quote (no second
--      pricing run). The hold confirms one fixed quote, so the parts of the confirmed quote ARE the sold snapshot:
--      a later tour edit changes nothing that was sold. A row: day and date, room type XOR service, the supplier, the
--      quantity (rooms of a room night; the rate unit's quantity of a service), nights (1), pax, the room mix of a
--      room part (occupancy names and counts, e.g. [{"occupancy":"double","count":2}]), the net in the supplier's
--      currency (NULL pair when the part's rates are in more than one currency: staff enter it, never a guessed net)
--      and the supplier rate ids. ON DELETE CASCADE from the quote line: quote lines are never deleted by the app
--      (no DELETE grant); the cascade only follows a fixture delete.
--   2. booking.supplier_bookings: quote_part_id (FK to the part) and quantity (1..999). CHECK at most one of
--      version_item_id, quote_part_id. New partial unique index supplier_bookings_part_live_uq: one live booking per
--      part. supplier_bookings_item_live_uq STAYS as it is (the running code's INSERT ... ON CONFLICT (version_item_id)
--      WHERE ... infers it during the MIG-4 window; changing its predicate would break it).
--   3. booking.supplier_bookings_guard(): the bk-045 body plus: an INSERT naming a part needs the part to belong to
--      the confirmed hold quote of the booking's own trip case, on a line without a departure, and no hold line link;
--      the part's hold line must be confirmed (not on request, declined or cancelled) and no waiver may close the part
--      (the same set the supply view counts; defence in depth behind the app's checks); quote_part_id never changes;
--      quantity is a fact (fixed once requested / confirmed, like nights and pax).
--   4. booking.v_trip_case_supply_state REPLACED (same columns): items_to_book also counts the parts of the case's
--      confirmed hold whose hold line is confirmed (an on-request line counts once the desk accepted it), whose quote
--      line has no departure (a departure's costs are booked once per departure) and which no waiver closed; a part
--      counts as booked when a confirmed booking names it. Cases confirmed before bk-065 have no parts: their counts
--      do not change. Behaviour change for a new tp: case: pre_departure (bk-026 / bk-028 guard) now needs every part
--      confirmed or waived.
--   5. booking.trip_case_part_waivers (append-only; INSERT, SELECT): a part ops need not or cannot book (a service
--      dropped after the sale, no replacement supplier), with a reason of 20..500 characters (pii:free_text, staff
--      text). One per part. The view counts a waived part as not to book.
--   6. booking.trip_plans.no_hotel_nights smallint[] (default '{}'): the nights of a tour that need no hotel (night
--      train, a cruise not modelled as a room type). Tour data for rule N1 of the can-operate check, not an exception.
--      booking.trip_plans.no_hotel_nights_reason text: why the nights were last set (staff text, 20..500 characters,
--      pii:free_text; NULL until first set; '[redacted]' on erasure). Contracting staff (trip_plan.write) may lift N1
--      this way for good, so every change carries a reason (and an audit row, written by the app).
--   7. booking.trip_plan_operable_overrides: the admin sale exception of a tour. It covers exact findings of rules N1
--      (a night without a hotel) and N3 (a supplier not active) only: a missing rate (N2) or an inactive room type,
--      hotel or service is refused by the quote whatever an exception says. Reason 20..500 characters
--      (pii:free_text), expiry in the future and at most 90 days after creation (outer backstop; the real maximum is
--      the pricing policy operable_exception_max_days). At most one unrevoked row per tour (partial unique index).
--      Guard: an INSERT starts unrevoked, dated now, with findings that match its rules; the only later changes are the
--      revoke (once, dated now, with who and why) and, on erasure (DM-6.7, bk_owner in a reviewed run-script), the
--      reasons set to the fixed marker '[redacted]' alone. Role booking: SELECT, INSERT, UPDATE of the revoke columns.
--   8. booking.b2b_quote_lines.operable_override_id: the exception that covered a finding of that line when it was
--      quoted (NULL otherwise). Written once with the line (append-only table).
--   9. booking.b2b_holds_sale_exception_checks(): AFTER UPDATE OF status on b2b_holds. When a hold becomes confirmed,
--      one open "custom" trip check per covering exception of its quote's lines (no departure) is added to the new
--      trip case: what Booking could not book, to book by hand. Fires once per hold (a hold is confirmed once).
--  10. Two pricing policy parameters (Pricing > Policy, section operations, approver group admin), version 1 made,
--      submitted and approved by the migration ('seed:bk-065', in force from 2026-01-01):
--        operable_exception_default_days  14   (days)
--        operable_exception_max_days      30   (days)
--
-- Class: contract (root ADR 0017 d3: new tables, a new FK and unique index on supplier_bookings, a guard function and
-- a view replaced, a new trigger, config rows). Migration-only PR first (MIG-4); the code PR raises readiness to
-- bk-065. The running code never names a part, an override or no_hotel_nights, so nothing it writes or reads changes:
-- no part exists until the code PR quotes, and every new column is nullable or defaulted.
-- DM-6.1: parts and overrides hold no personal data (ids, dates, quantities, conf:commercial nets and rate ids);
-- override reason / revoke_reason, waiver reason and trip_plans.no_hotel_nights_reason are staff free text
-- (pii:free_text by rule).
-- DM-7.1: b2b_quote_line_parts, trip_case_part_waivers and trip_plan_operable_overrides have their rows in the root
-- data standards (root PR merged before the Infra copy).
-- Locks: ACCESS EXCLUSIVE, briefly, on supplier_bookings (tens of rows), b2b_quote_lines (~160 rows), trip_plans (~900
-- rows; the CHECK validates them) for ADD COLUMN / constraints / indexes; CREATE OR REPLACE VIEW / FUNCTION; a new
-- trigger on b2b_holds (~50 rows); lock_timeout 5s.
-- Re-runnable (the Integration Tests replay every file): CREATE TABLE / INDEX IF NOT EXISTS, ADD COLUMN IF NOT EXISTS,
-- DROP CONSTRAINT IF EXISTS + ADD, CREATE OR REPLACE FUNCTION / TRIGGER / VIEW, ON CONFLICT DO NOTHING.
-- Number: owner main max + 1 (bk-064 before it). If it moves, renumber: file name, this header, the pre-check, the
-- registration, the seed ids (…b65000…) and the tests that name it (git grep '065_' and 'bk-065').
-- Undo (a later bk- file, after the code is reverted): DROP the b2b_holds_sale_exception_checks trigger and function;
-- put back the bk-045 guard body and the bk-026 view; DROP the new columns (supplier_bookings.quote_part_id /
-- quantity, b2b_quote_lines.operable_override_id, trip_plans.no_hotel_nights / no_hotel_nights_reason) with their
-- CHECKs and indexes; DROP the
-- three new tables (destructive: DRY RUN); DELETE the seed:bk-065 policy events, then the versions.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF to_regclass('booking.billing_entity_change') IS NULL OR to_regclass('booking.b2b_quote_lines') IS NULL
       OR to_regclass('booking.supplier_orders') IS NULL OR to_regclass('booking.trip_case_checks') IS NULL THEN
        RAISE EXCEPTION 'bk-065: needs bk-019, bk-027, bk-045 and bk-064 first';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.schema_versions
                WHERE version = 'bk-065' AND description NOT LIKE 'AA-1149 %') THEN
        RAISE EXCEPTION 'bk-065: the key bk-065 is already held by another migration (not AA-1149): renumber one';
    END IF;
END $$;

-- ── 1. The sold snapshot: one part per component of a tp: quote line ────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.b2b_quote_line_parts (
    id                  uuid         NOT NULL DEFAULT gen_random_uuid(),
    quote_id            uuid         NOT NULL,
    line_no             smallint     NOT NULL,
    part_no             smallint     NOT NULL,
    day_no              smallint     NOT NULL,
    service_date        date         NOT NULL,
    hotel_room_type_id  uuid,
    service_id          uuid,
    supplier_id         uuid         NOT NULL,
    quantity            smallint     NOT NULL,
    nights              smallint     NOT NULL DEFAULT 1,
    pax                 smallint     NOT NULL,
    rooms               jsonb,
    net_amount          numeric(16,2),
    net_currency        character(3),
    supplier_rate_ids   uuid[]       NOT NULL,
    created_at          timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT b2b_quote_line_parts_pkey PRIMARY KEY (id),
    CONSTRAINT b2b_quote_line_parts_line_fkey FOREIGN KEY (quote_id, line_no)
        REFERENCES booking.b2b_quote_lines (quote_id, line_no) ON DELETE CASCADE,
    CONSTRAINT b2b_quote_line_parts_room_type_fkey FOREIGN KEY (hotel_room_type_id)
        REFERENCES booking.hotel_room_types (id),
    CONSTRAINT b2b_quote_line_parts_service_fkey FOREIGN KEY (service_id) REFERENCES booking.services (id),
    CONSTRAINT b2b_quote_line_parts_supplier_fkey FOREIGN KEY (supplier_id) REFERENCES booking.suppliers (id),
    CONSTRAINT b2b_quote_line_parts_no_uq UNIQUE (quote_id, line_no, part_no),
    CONSTRAINT b2b_quote_line_parts_no_chk CHECK (part_no BETWEEN 1 AND 200),
    CONSTRAINT b2b_quote_line_parts_day_chk CHECK (day_no BETWEEN 1 AND 366),
    CONSTRAINT b2b_quote_line_parts_target_chk CHECK (num_nonnulls(hotel_room_type_id, service_id) = 1),
    CONSTRAINT b2b_quote_line_parts_quantity_chk CHECK (quantity BETWEEN 1 AND 999),
    CONSTRAINT b2b_quote_line_parts_nights_chk CHECK (nights BETWEEN 1 AND 60),
    CONSTRAINT b2b_quote_line_parts_pax_chk CHECK (pax BETWEEN 1 AND 120),
    CONSTRAINT b2b_quote_line_parts_rooms_chk CHECK (
        (hotel_room_type_id IS NULL) = (rooms IS NULL)
        AND (rooms IS NULL OR (jsonb_typeof(rooms) = 'array' AND jsonb_array_length(rooms) BETWEEN 1 AND 30))),
    CONSTRAINT b2b_quote_line_parts_net_chk CHECK (
        (net_amount IS NULL) = (net_currency IS NULL)
        AND (net_amount IS NULL OR net_amount >= 0)
        AND (net_currency IS NULL OR net_currency ~ '^[A-Z]{3}$')),
    CONSTRAINT b2b_quote_line_parts_rates_chk CHECK (cardinality(supplier_rate_ids) BETWEEN 1 AND 60)
);

CREATE INDEX IF NOT EXISTS b2b_quote_line_parts_supplier_idx ON booking.b2b_quote_line_parts (supplier_id);
CREATE INDEX IF NOT EXISTS b2b_quote_line_parts_room_type_idx
    ON booking.b2b_quote_line_parts (hotel_room_type_id) WHERE hotel_room_type_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS b2b_quote_line_parts_service_idx
    ON booking.b2b_quote_line_parts (service_id) WHERE service_id IS NOT NULL;

COMMENT ON TABLE booking.b2b_quote_line_parts IS
    'bk-065 (AA-1149 T15): one row per component of a tp: quote line, written by the quote calculation with the quote '
    '(append-only). The parts of a confirmed hold''s quote are the sold snapshot: Generate makes one supplier booking '
    'per part; a later edit of the tour''s components changes nothing sold. Kept with its quote.';
COMMENT ON COLUMN booking.b2b_quote_line_parts.quantity IS
    'bk-065: rooms of a room night (the sum of the room mix), or the quantity of the service''s rate unit (person = '
    'the party, group / vehicle = 1, day = 1).';
COMMENT ON COLUMN booking.b2b_quote_line_parts.rooms IS
    'bk-065: the room mix of a room part as priced, [{"occupancy": name, "count": n}] (NULL for a service part).';
COMMENT ON COLUMN booking.b2b_quote_line_parts.net_amount IS
    'conf:commercial; bk-065: the part''s supplier net in its rates'' currency (NULL with net_currency when its rates '
    'are in more than one currency: staff enter the net on the booking).';
COMMENT ON COLUMN booking.b2b_quote_line_parts.net_currency IS
    'conf:commercial; bk-065: the currency of net_amount.';
COMMENT ON COLUMN booking.b2b_quote_line_parts.supplier_rate_ids IS
    'conf:commercial; bk-065: the supplier rates the part was priced on (several for a room mix).';

REVOKE ALL ON booking.b2b_quote_line_parts FROM booking;
GRANT SELECT, INSERT ON booking.b2b_quote_line_parts TO booking;

-- ── 2. Supplier bookings name their part ───────────────────────────────────────────────────────────────────────

ALTER TABLE booking.supplier_bookings
    ADD COLUMN IF NOT EXISTS quote_part_id uuid,
    ADD COLUMN IF NOT EXISTS quantity smallint;

ALTER TABLE booking.supplier_bookings DROP CONSTRAINT IF EXISTS supplier_bookings_quote_part_fkey;
ALTER TABLE booking.supplier_bookings ADD CONSTRAINT supplier_bookings_quote_part_fkey
    FOREIGN KEY (quote_part_id) REFERENCES booking.b2b_quote_line_parts (id);
ALTER TABLE booking.supplier_bookings DROP CONSTRAINT IF EXISTS supplier_bookings_quantity_chk;
ALTER TABLE booking.supplier_bookings ADD CONSTRAINT supplier_bookings_quantity_chk
    CHECK (quantity IS NULL OR quantity BETWEEN 1 AND 999);
ALTER TABLE booking.supplier_bookings DROP CONSTRAINT IF EXISTS supplier_bookings_source_chk;
ALTER TABLE booking.supplier_bookings ADD CONSTRAINT supplier_bookings_source_chk
    CHECK (num_nonnulls(version_item_id, quote_part_id) <= 1);

-- One live booking per tour component (declined and cancelled rows never block a replacement).
CREATE UNIQUE INDEX IF NOT EXISTS supplier_bookings_part_live_uq
    ON booking.supplier_bookings (quote_part_id)
    WHERE status IN ('pending', 'requested', 'confirmed') AND quote_part_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS supplier_bookings_part_idx
    ON booking.supplier_bookings (quote_part_id) WHERE quote_part_id IS NOT NULL;

COMMENT ON COLUMN booking.supplier_bookings.quote_part_id IS
    'bk-065 (AA-1149 T15): the sold tour component (booking.b2b_quote_line_parts) this booking books; at most one live '
    'booking per part; never with version_item_id; never changes.';
COMMENT ON COLUMN booking.supplier_bookings.quantity IS
    'bk-065: rooms, vehicles, people or days booked (from the part); a fact like nights and pax.';

-- ── 3. The fact guard: the bk-045 body plus the part rules ─────────────────────────────────────────────────────

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
        -- bk-065: a tour component booking books a part of its own case's confirmed hold quote (no departure line).
        IF NEW.quote_part_id IS NOT NULL THEN
            IF NEW.b2b_hold_id IS NOT NULL OR NOT EXISTS (
                SELECT 1
                  FROM booking.b2b_quote_line_parts qp
                  JOIN booking.b2b_quote_lines ql ON ql.quote_id = qp.quote_id AND ql.line_no = qp.line_no
                  JOIN booking.b2b_holds h ON h.quote_id = qp.quote_id
                 WHERE qp.id = NEW.quote_part_id AND h.trip_case_id = NEW.trip_case_id AND h.status = 'confirmed'
                   AND ql.departure_id IS NULL
            ) THEN
                RAISE EXCEPTION 'tour component % is not a part of the confirmed booking of trip case % (or it is linked'
                    ' to a hold line)', NEW.quote_part_id, NEW.trip_case_id USING ERRCODE = 'check_violation';
            END IF;
            -- The supply view's set: the part's hold line is confirmed (an on-request line once the desk accepted it;
            -- never a declined or cancelled one) and no waiver closed the part.
            IF NOT EXISTS (
                SELECT 1
                  FROM booking.b2b_quote_line_parts qp
                  JOIN booking.b2b_holds h ON h.quote_id = qp.quote_id
                  JOIN booking.b2b_hold_lines l ON l.hold_id = h.id AND l.line_no = qp.line_no
                 WHERE qp.id = NEW.quote_part_id AND h.trip_case_id = NEW.trip_case_id AND h.status = 'confirmed'
                   AND l.status = 'confirmed'
            ) THEN
                RAISE EXCEPTION 'tour component %: its agency line is not confirmed (on request, declined or cancelled):'
                    ' nothing is booked for it', NEW.quote_part_id USING ERRCODE = 'check_violation';
            END IF;
            IF EXISTS (SELECT 1 FROM booking.trip_case_part_waivers w WHERE w.quote_part_id = NEW.quote_part_id) THEN
                RAISE EXCEPTION 'tour component % is closed as needing no booking (waiver): nothing is booked for it',
                    NEW.quote_part_id USING ERRCODE = 'check_violation';
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
        IF (NEW.trip_case_id, NEW.departure_id, NEW.version_item_id, NEW.quote_part_id, NEW.b2b_hold_id,
            NEW.b2b_line_ref, NEW.code, NEW.created_by, NEW.created_at)
           IS DISTINCT FROM
           (OLD.trip_case_id, OLD.departure_id, OLD.version_item_id, OLD.quote_part_id, OLD.b2b_hold_id,
            OLD.b2b_line_ref, OLD.code, OLD.created_by, OLD.created_at) THEN
            RAISE EXCEPTION 'supplier booking %: case, departure, item, tour component, B2B line and code never change',
                OLD.code USING ERRCODE = 'check_violation';
        END IF;
        IF OLD.status NOT IN ('pending', 'requested')
           AND (NEW.supplier_id, NEW.hotel_room_type_id, NEW.service_id, NEW.item_description, NEW.service_date,
                NEW.nights, NEW.pax, NEW.quantity, NEW.net_amount, NEW.net_currency)
               IS DISTINCT FROM
               (OLD.supplier_id, OLD.hotel_room_type_id, OLD.service_id, OLD.item_description, OLD.service_date,
                OLD.nights, OLD.pax, OLD.quantity, OLD.net_amount, OLD.net_currency) THEN
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
    'bk-026 (AA-682) + bk-045 (AA-1074) + bk-065 (AA-1149): a supplier booking starts pending, belongs to an item of the approved version of its case, to a part of its case''s confirmed hold quote (no departure line, no hold line link, the part''s hold line confirmed, no waiver) or to a departure that is not cancelled, names the hold of its own B2B case only; case / departure / item / part / line / code never change; supplier and service facts (quantity included) change only while pending / requested; the FX snapshot changes only on a re-request; an order line joins a draft order of its supplier and currency while pending and leaves only a draft or cancelled order; the voucher is an active supplier_voucher file of this booking and never on a B2B case.';

GRANT EXECUTE ON FUNCTION booking.supplier_bookings_guard() TO booking;

-- ── 5. Waivers: a part that needs no booking ──────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.trip_case_part_waivers (
    id             uuid         NOT NULL DEFAULT gen_random_uuid(),
    trip_case_id   uuid         NOT NULL,
    quote_part_id  uuid         NOT NULL,
    reason         text         NOT NULL,
    created_by     text         NOT NULL,
    created_at     timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT trip_case_part_waivers_pkey PRIMARY KEY (id),
    CONSTRAINT trip_case_part_waivers_case_fkey FOREIGN KEY (trip_case_id) REFERENCES booking.trip_cases (id),
    CONSTRAINT trip_case_part_waivers_part_fkey FOREIGN KEY (quote_part_id)
        REFERENCES booking.b2b_quote_line_parts (id) ON DELETE CASCADE,
    CONSTRAINT trip_case_part_waivers_by_fkey FOREIGN KEY (created_by) REFERENCES booking.staff_users (cis_user_id),
    CONSTRAINT trip_case_part_waivers_part_uq UNIQUE (quote_part_id),
    CONSTRAINT trip_case_part_waivers_reason_chk CHECK (
        reason = '[redacted]' OR char_length(btrim(reason)) BETWEEN 20 AND 500)
);

CREATE INDEX IF NOT EXISTS trip_case_part_waivers_case_idx ON booking.trip_case_part_waivers (trip_case_id);
CREATE INDEX IF NOT EXISTS trip_case_part_waivers_by_idx ON booking.trip_case_part_waivers (created_by);

COMMENT ON TABLE booking.trip_case_part_waivers IS
    'bk-065 (AA-1149): a sold tour component (part) that ops need not or cannot book, closed with a reason; the supply '
    'state counts it as not to book. Append-only, one per part; kept with its trip case.';
COMMENT ON COLUMN booking.trip_case_part_waivers.reason IS
    'pii:free_text — why the component needs no supplier booking (staff text, 20..500 characters).';

REVOKE ALL ON booking.trip_case_part_waivers FROM booking;
GRANT SELECT, INSERT ON booking.trip_case_part_waivers TO booking;

CREATE OR REPLACE FUNCTION booking.trip_case_part_waivers_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.created_at IS DISTINCT FROM now() OR NOT EXISTS (
            SELECT 1
              FROM booking.b2b_quote_line_parts qp
              JOIN booking.b2b_holds h ON h.quote_id = qp.quote_id
             WHERE qp.id = NEW.quote_part_id AND h.trip_case_id = NEW.trip_case_id AND h.status = 'confirmed'
        ) THEN
            RAISE EXCEPTION 'a waiver closes a part of its own trip case''s confirmed booking, dated now'
                USING ERRCODE = 'check_violation';
        END IF;
        IF EXISTS (SELECT 1 FROM booking.supplier_bookings b
                    WHERE b.quote_part_id = NEW.quote_part_id AND b.status IN ('pending', 'requested', 'confirmed')) THEN
            RAISE EXCEPTION 'tour component % has a live supplier booking: cancel it first', NEW.quote_part_id
                USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
    END IF;
    -- Erasure (DM-6.7): the reason may be set to the fixed marker, nothing else.
    IF (to_jsonb(NEW) - 'reason') = (to_jsonb(OLD) - 'reason') AND NEW.reason = '[redacted]' THEN
        RETURN NEW;
    END IF;
    RAISE EXCEPTION 'waiver %: a waiver is final', OLD.id USING ERRCODE = 'check_violation';
END $$;

COMMENT ON FUNCTION booking.trip_case_part_waivers_guard() IS
    'bk-065 (AA-1149): a waiver closes a part of its own case''s confirmed hold quote, dated now, never while a live '
    'booking names the part; final, except the reason set to [redacted] alone on erasure (DM-6.7).';

GRANT EXECUTE ON FUNCTION booking.trip_case_part_waivers_guard() TO booking;

CREATE OR REPLACE TRIGGER trip_case_part_waivers_guard
    BEFORE INSERT OR UPDATE ON booking.trip_case_part_waivers
    FOR EACH ROW EXECUTE FUNCTION booking.trip_case_part_waivers_guard();

-- ── 4. Supply state: the parts of a sold tour count ────────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW booking.v_trip_case_supply_state AS
SELECT tc.id AS trip_case_id,
       (items.to_book + parts.to_book)::int AS items_to_book,
       (items.booked + parts.booked)::int AS items_booked,
       coalesce(sb.live, 0)::int AS live,
       coalesce(sb.confirmed, 0)::int AS confirmed,
       coalesce(sb.waiting, 0)::int AS waiting,
       coalesce(sb.declined, 0)::int AS declined,
       CASE
           WHEN coalesce(sb.live, 0) = 0 AND items.to_book + parts.to_book = 0 THEN 'none'
           WHEN coalesce(sb.live, 0) = coalesce(sb.confirmed, 0)
                AND items.booked + parts.booked = items.to_book + parts.to_book THEN 'booked'
           ELSE 'confirming'
       END AS state
FROM booking.trip_cases tc
CROSS JOIN LATERAL (
    SELECT count(*) AS to_book,
           count(*) FILTER (
               WHERE EXISTS (SELECT 1 FROM booking.supplier_bookings b
                              WHERE b.version_item_id = i.id AND b.status = 'confirmed')
                  OR l.status = 'confirmed') AS booked
      FROM booking.trip_case_versions v
      JOIN booking.trip_case_version_itinerary i ON i.trip_case_version_id = v.id
      LEFT JOIN booking.b2b_holds h ON tc.channel = 'b2b' AND h.trip_case_id = tc.id
      LEFT JOIN booking.b2b_hold_lines l ON l.hold_id = h.id AND l.line_no = i.position
     WHERE v.trip_case_id = tc.id AND v.is_approved AND v.deleted_at IS NULL
       AND (i.hotel_room_type_id IS NOT NULL OR i.service_id IS NOT NULL)
       AND (l.status IS NULL OR l.status NOT IN ('declined', 'cancelled'))
) items
CROSS JOIN LATERAL (
    SELECT count(*) AS to_book,
           count(*) FILTER (
               WHERE EXISTS (SELECT 1 FROM booking.supplier_bookings b
                              WHERE b.quote_part_id = qp.id AND b.status = 'confirmed')) AS booked
      FROM booking.b2b_holds h
      JOIN booking.b2b_hold_lines l ON l.hold_id = h.id AND l.status = 'confirmed'
      JOIN booking.b2b_quote_lines ql ON ql.quote_id = h.quote_id AND ql.line_no = l.line_no
                                     AND ql.departure_id IS NULL
      JOIN booking.b2b_quote_line_parts qp ON qp.quote_id = ql.quote_id AND qp.line_no = ql.line_no
     WHERE tc.channel = 'b2b' AND h.trip_case_id = tc.id AND h.status = 'confirmed'
       AND NOT EXISTS (SELECT 1 FROM booking.trip_case_part_waivers w WHERE w.quote_part_id = qp.id)
) parts
LEFT JOIN LATERAL (
    SELECT count(*) FILTER (WHERE b.status IN ('pending', 'requested', 'confirmed')) AS live,
           count(*) FILTER (WHERE b.status = 'confirmed') AS confirmed,
           count(*) FILTER (WHERE b.status IN ('pending', 'requested')) AS waiting,
           count(*) FILTER (WHERE b.status = 'declined') AS declined
      FROM booking.supplier_bookings b
     WHERE b.trip_case_id = tc.id
) sb ON true;

COMMENT ON VIEW booking.v_trip_case_supply_state IS
    'bk-026 (AA-682 D1) + bk-065 (AA-1149): per trip case, supply items of the approved version and sold tour components (parts of the confirmed hold quote whose hold line is confirmed, no departure, not waived) to book / booked, live / confirmed / waiting / declined supplier bookings, and state none | confirming | booked (booked = the "Confirmed & Booked" badge). Live = pending / requested / confirmed. A B2B room or service item whose on-request line is confirmed counts as booked; one whose line is declined or cancelled needs no supply; a part counts as booked when a confirmed supplier booking names it.';

REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON booking.v_trip_case_supply_state FROM booking;
GRANT SELECT ON booking.v_trip_case_supply_state TO booking;

-- ── 6. Nights that need no hotel ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE booking.trip_plans ADD COLUMN IF NOT EXISTS no_hotel_nights smallint[] NOT NULL DEFAULT '{}';
ALTER TABLE booking.trip_plans DROP CONSTRAINT IF EXISTS trip_plans_no_hotel_nights_chk;
ALTER TABLE booking.trip_plans ADD CONSTRAINT trip_plans_no_hotel_nights_chk CHECK (
    cardinality(no_hotel_nights) <= 365 AND 1 <= ALL (no_hotel_nights) AND 365 >= ALL (no_hotel_nights));

COMMENT ON COLUMN booking.trip_plans.no_hotel_nights IS
    'bk-065 (AA-1149 B13): the nights of the tour that need no hotel (night n = between day n and day n + 1: a night '
    'train, a cruise not modelled as a room type); rule N1 of the can-operate check skips them.';

ALTER TABLE booking.trip_plans ADD COLUMN IF NOT EXISTS no_hotel_nights_reason text;
ALTER TABLE booking.trip_plans DROP CONSTRAINT IF EXISTS trip_plans_no_hotel_nights_reason_chk;
ALTER TABLE booking.trip_plans ADD CONSTRAINT trip_plans_no_hotel_nights_reason_chk CHECK (
    no_hotel_nights_reason IS NULL OR no_hotel_nights_reason = '[redacted]'
    OR char_length(btrim(no_hotel_nights_reason)) BETWEEN 20 AND 500);

COMMENT ON COLUMN booking.trip_plans.no_hotel_nights_reason IS
    'pii:free_text — bk-065 (AA-1149 B13): why no_hotel_nights was last set (staff text, 20..500 characters; NULL '
    'until first set). Contracting staff lift rule N1 this way, so every change has a reason and an audit row.';

-- ── 7. The admin sale exception ──────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.trip_plan_operable_overrides (
    id             uuid         NOT NULL DEFAULT gen_random_uuid(),
    trip_plan_id   uuid         NOT NULL,
    rules          text[]       NOT NULL,
    findings       text[]       NOT NULL,
    reason         text         NOT NULL,
    expires_at     timestamptz  NOT NULL,
    created_by     text         NOT NULL,
    created_at     timestamptz  NOT NULL DEFAULT now(),
    revoked_by     text,
    revoked_at     timestamptz,
    revoke_reason  text,
    CONSTRAINT trip_plan_operable_overrides_pkey PRIMARY KEY (id),
    CONSTRAINT trip_plan_operable_overrides_plan_fkey FOREIGN KEY (trip_plan_id) REFERENCES booking.trip_plans (id),
    CONSTRAINT trip_plan_operable_overrides_by_fkey FOREIGN KEY (created_by)
        REFERENCES booking.staff_users (cis_user_id),
    CONSTRAINT trip_plan_operable_overrides_revoked_by_fkey FOREIGN KEY (revoked_by)
        REFERENCES booking.staff_users (cis_user_id),
    CONSTRAINT trip_plan_operable_overrides_rules_chk CHECK (
        cardinality(rules) BETWEEN 1 AND 2 AND rules <@ ARRAY['N1', 'N3']::text[]),
    CONSTRAINT trip_plan_operable_overrides_findings_chk CHECK (cardinality(findings) BETWEEN 1 AND 200),
    CONSTRAINT trip_plan_operable_overrides_reason_chk CHECK (
        reason = '[redacted]' OR char_length(btrim(reason)) BETWEEN 20 AND 500),
    -- technical-constant: 90 days is an outer backstop only; the maximum staff can choose is the pricing policy value
    -- operable_exception_max_days (app.catalog.sell_exceptions).
    CONSTRAINT trip_plan_operable_overrides_expiry_chk CHECK (
        expires_at > created_at AND expires_at <= created_at + interval '90 days'),
    CONSTRAINT trip_plan_operable_overrides_revoke_chk CHECK (
        (revoked_at IS NULL) = (revoked_by IS NULL) AND (revoked_at IS NULL) = (revoke_reason IS NULL)
        AND (revoke_reason IS NULL OR revoke_reason = '[redacted]'
             OR char_length(btrim(revoke_reason)) BETWEEN 1 AND 300))
);

-- At most one unrevoked exception per tour (an expired one is revoked by the next create, in its transaction).
CREATE UNIQUE INDEX IF NOT EXISTS trip_plan_operable_overrides_live_uq
    ON booking.trip_plan_operable_overrides (trip_plan_id) WHERE revoked_at IS NULL;
CREATE INDEX IF NOT EXISTS trip_plan_operable_overrides_plan_idx
    ON booking.trip_plan_operable_overrides (trip_plan_id, created_at DESC);
CREATE INDEX IF NOT EXISTS trip_plan_operable_overrides_by_idx ON booking.trip_plan_operable_overrides (created_by);
CREATE INDEX IF NOT EXISTS trip_plan_operable_overrides_revoked_by_idx
    ON booking.trip_plan_operable_overrides (revoked_by) WHERE revoked_by IS NOT NULL;

COMMENT ON TABLE booking.trip_plan_operable_overrides IS
    'bk-065 (AA-1149 B13): the admin sale exception of a tour: it lets agencies buy the tour while the exact listed '
    'findings of rules N1 (night without a hotel) or N3 (supplier not active) stand, until expires_at or a revoke. A '
    'new finding is never covered. Never deleted; at most one unrevoked row per tour.';
COMMENT ON COLUMN booking.trip_plan_operable_overrides.findings IS
    'bk-065: the covered finding keys, e.g. N1:night:2 or N3:supplier:SUP-000045.';
COMMENT ON COLUMN booking.trip_plan_operable_overrides.reason IS
    'pii:free_text — why the tour may be sold anyway (staff text, 20..500 characters).';
COMMENT ON COLUMN booking.trip_plan_operable_overrides.revoke_reason IS
    'pii:free_text — why the exception was revoked early (staff text).';

REVOKE ALL ON booking.trip_plan_operable_overrides FROM booking;
GRANT SELECT, INSERT ON booking.trip_plan_operable_overrides TO booking;
GRANT UPDATE (revoked_by, revoked_at, revoke_reason) ON booking.trip_plan_operable_overrides TO booking;

CREATE OR REPLACE FUNCTION booking.trip_plan_operable_overrides_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_bad  text;
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.revoked_at IS NOT NULL OR NEW.created_at IS DISTINCT FROM now() OR NEW.expires_at <= now() THEN
            RAISE EXCEPTION 'a sale exception starts unrevoked, dated now, with an expiry in the future'
                USING ERRCODE = 'check_violation';
        END IF;
        SELECT f INTO v_bad FROM unnest(NEW.findings) f
         WHERE NOT ((f ~ '^N1:night:[0-9]{1,3}$' AND 'N1' = ANY (NEW.rules))
                    OR (f ~ '^N3:supplier:[A-Za-z0-9-]{1,40}$' AND 'N3' = ANY (NEW.rules)))
         LIMIT 1;
        IF v_bad IS NOT NULL THEN
            RAISE EXCEPTION 'sale exception: finding % is not one of its rules (only a night without a hotel or a'
                ' supplier not active can be covered)', v_bad USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
    END IF;
    -- Erasure (DM-6.7): the staff reasons may be set to the fixed marker, nothing else in the same update.
    IF (to_jsonb(NEW) - 'reason' - 'revoke_reason') = (to_jsonb(OLD) - 'reason' - 'revoke_reason')
       AND (NEW.reason, NEW.revoke_reason) IS DISTINCT FROM (OLD.reason, OLD.revoke_reason)
       AND (NEW.reason IS NOT DISTINCT FROM OLD.reason OR NEW.reason = '[redacted]')
       AND (NEW.revoke_reason IS NOT DISTINCT FROM OLD.revoke_reason OR NEW.revoke_reason = '[redacted]') THEN
        RETURN NEW;
    END IF;
    IF OLD.revoked_at IS NOT NULL THEN
        RAISE EXCEPTION 'sale exception % is revoked; it is final', OLD.id USING ERRCODE = 'check_violation';
    END IF;
    IF (to_jsonb(NEW) - 'revoked_by' - 'revoked_at' - 'revoke_reason')
       IS DISTINCT FROM (to_jsonb(OLD) - 'revoked_by' - 'revoked_at' - 'revoke_reason')
       OR NEW.revoked_at IS DISTINCT FROM now() THEN
        RAISE EXCEPTION 'sale exception %: only a revoke dated now changes it', OLD.id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.trip_plan_operable_overrides_guard() IS
    'bk-065 (AA-1149): a sale exception starts unrevoked, dated now, expiring later, with findings of its rules only '
    '(N1:night:<n>, N3:supplier:<code>); the only change is one revoke dated now (final), or on erasure (DM-6.7) the '
    'reasons set to [redacted] alone.';

GRANT EXECUTE ON FUNCTION booking.trip_plan_operable_overrides_guard() TO booking;

CREATE OR REPLACE TRIGGER trip_plan_operable_overrides_guard
    BEFORE INSERT OR UPDATE ON booking.trip_plan_operable_overrides
    FOR EACH ROW EXECUTE FUNCTION booking.trip_plan_operable_overrides_guard();

-- ── 8. Which exception covered a quote line ──────────────────────────────────────────────────────────────────

ALTER TABLE booking.b2b_quote_lines ADD COLUMN IF NOT EXISTS operable_override_id uuid;
ALTER TABLE booking.b2b_quote_lines DROP CONSTRAINT IF EXISTS b2b_quote_lines_operable_override_fkey;
ALTER TABLE booking.b2b_quote_lines ADD CONSTRAINT b2b_quote_lines_operable_override_fkey
    FOREIGN KEY (operable_override_id) REFERENCES booking.trip_plan_operable_overrides (id);
CREATE INDEX IF NOT EXISTS b2b_quote_lines_operable_override_idx
    ON booking.b2b_quote_lines (operable_override_id) WHERE operable_override_id IS NOT NULL;

COMMENT ON COLUMN booking.b2b_quote_lines.operable_override_id IS
    'bk-065 (AA-1149 B13): the sale exception that covered a finding of this tp: line when it was quoted (NULL: none '
    'needed). The confirm of its hold adds a trip check to book the missing parts by hand.';

-- ── 9. Trips sold under an exception get an ops task at confirm ──────────────────────────────────────────────

CREATE OR REPLACE FUNCTION booking.b2b_holds_sale_exception_checks() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    r        record;
    v_start  date;
    v_text   text;
BEGIN
    IF NEW.status <> 'confirmed' OR OLD.status = 'confirmed' OR NEW.trip_case_id IS NULL THEN
        RETURN NULL;
    END IF;
    SELECT start_date INTO v_start FROM booking.trip_cases WHERE id = NEW.trip_case_id;
    FOR r IN
        SELECT o.id, o.findings, string_agg(ql.line_ref, ', ' ORDER BY ql.line_no) AS refs
          FROM booking.b2b_quote_lines ql
          JOIN booking.trip_plan_operable_overrides o ON o.id = ql.operable_override_id
         WHERE ql.quote_id = NEW.quote_id AND ql.departure_id IS NULL
         GROUP BY o.id, o.findings
         ORDER BY min(ql.line_no)
    LOOP
        SELECT string_agg(CASE WHEN f LIKE 'N1:night:%' THEN 'night ' || substr(f, 10) || ' has no hotel'
                               WHEN f LIKE 'N3:supplier:%' THEN 'supplier ' || substr(f, 13) || ' is not active'
                               ELSE f END, '; ' ORDER BY f)
          INTO v_text FROM unnest(r.findings) f;
        INSERT INTO booking.trip_case_checks (trip_case_id, code, title, status, due_date, note)
        VALUES (NEW.trip_case_id, 'custom',
                left('Sold under a sale exception: book by hand what is missing (' || v_text || ')', 200),
                'open', v_start,
                left('Agency line ' || r.refs || ' was sold under a sale exception (' || v_text || '). Booking has'
                     || ' no supplier booking for what is missing: book it by hand with a supplier and add it to this'
                     || ' trip.', 2000));
    END LOOP;
    RETURN NULL;
END $$;

COMMENT ON FUNCTION booking.b2b_holds_sale_exception_checks() IS
    'bk-065 (AA-1149 B13): when a hold becomes confirmed, one open custom trip check per sale exception that covered a '
    'finding of its quote''s lines (no departure): what Booking could not book, to book by hand. Once per hold.';

GRANT EXECUTE ON FUNCTION booking.b2b_holds_sale_exception_checks() TO booking;

CREATE OR REPLACE TRIGGER b2b_holds_sale_exception_checks
    AFTER UPDATE OF status ON booking.b2b_holds
    FOR EACH ROW EXECUTE FUNCTION booking.b2b_holds_sale_exception_checks();

-- ── 10. Policy: the exception's default and maximum length (section operations, approver group admin) ────────

INSERT INTO booking.pricing_policy (id, param_key, version_no, value, unit, effective_from, reason, created_by)
VALUES
    ('00000000-0000-4000-8000-0000b6500000', 'operable_exception_default_days', 1, '14'::jsonb, 'days',
     DATE '2026-01-01', 'AA-1149: the default length of a can-operate sale exception (issue B13: 14 days).',
     'seed:bk-065'),
    ('00000000-0000-4000-8000-0000b6500010', 'operable_exception_max_days', 1, '30'::jsonb, 'days', DATE '2026-01-01',
     'AA-1149: the longest can-operate sale exception staff may set (issue B13: 30 days).', 'seed:bk-065')
ON CONFLICT DO NOTHING;

INSERT INTO booking.pricing_policy_events (id, policy_id, maker, event, actor)
SELECT e.id, p.id, p.created_by, 'submitted', p.created_by
FROM (VALUES ('00000000-0000-4000-8000-0000b6500001'::uuid, '00000000-0000-4000-8000-0000b6500000'::uuid),
             ('00000000-0000-4000-8000-0000b6500011'::uuid, '00000000-0000-4000-8000-0000b6500010'::uuid)) AS e (id, pid)
JOIN booking.pricing_policy p ON p.id = e.pid AND p.created_by = 'seed:bk-065'
ON CONFLICT DO NOTHING;

INSERT INTO booking.pricing_policy_events (id, policy_id, maker, event, actor)
SELECT e.id, p.id, p.created_by, 'approved', 'tech lead S285 (AA-1149 B13: exception 14 days, at most 30)'
FROM (VALUES ('00000000-0000-4000-8000-0000b6500002'::uuid, '00000000-0000-4000-8000-0000b6500000'::uuid),
             ('00000000-0000-4000-8000-0000b6500012'::uuid, '00000000-0000-4000-8000-0000b6500010'::uuid)) AS e (id, pid)
JOIN booking.pricing_policy p ON p.id = e.pid AND p.created_by = 'seed:bk-065'
ON CONFLICT DO NOTHING;

DO $$
DECLARE
    n integer;
BEGIN
    SELECT count(*) INTO n
    FROM booking.pricing_policy p
    JOIN booking.pricing_policy_events a ON a.policy_id = p.id AND a.event = 'approved'
    WHERE p.created_by IN ('seed:bk-065') AND p.version_no = 1;
    IF n <> 2 THEN
        RAISE EXCEPTION 'bk-065: % of the 2 new pricing policy parameters have an approved version 1', n
            USING HINT = 'A key already had a version 1 made by someone else; the seed must not overwrite it.';
    END IF;
END
$$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-065', now(), 'AA-1149 tour split and can operate: b2b_quote_line_parts (sold snapshot), supplier_bookings.quote_part_id + quantity (one live per part), guard and supply view replaced, trip_case_part_waivers, trip_plans.no_hotel_nights + reason, trip_plan_operable_overrides (sale exception), b2b_quote_lines.operable_override_id, exception trip check at confirm, policy operable_exception_default_days / max_days')
ON CONFLICT (version) DO NOTHING;

COMMIT;
