-- Migration bk-026: AA-682 slice S1 — supplier bookings, the supply track and the post-sale status edges of a trip
-- case (operations MVP, S252 design §3.1 with the critic fixes B1, B2, B3, B9).
--
-- Owner: AA-Booking (key bk-NNN). A byte-identical copy goes to AA-CIS-Infra
-- db/migrations/booking/026_ops_supplier_bookings.sql and is applied to Dev by the DB Migrate workflow (check, then
-- apply), as bk_owner (the live owner of schema booking since bk-014). Never run it from a laptop.
--
-- Depends on bk-003 (trip_cases, status edges + trigger, staff_users, set_updated_at), bk-005 (settings, edges),
-- bk-008 (suppliers), bk-010 (hotels, hotel_room_types, services, version item supply columns) and bk-022
-- (b2b_hold_lines decline codes and answers). Every grant names its object (no "ON ALL TABLES").
--
-- What it adds (docs/implementation-notes/AA-682.md):
--   * booking.ops_transitions (entity, from_status, to_status) + booking.ops_check_transition(): one edges table and
--     one trigger function (TG_ARGV[0] = the entity) for the operations state machines. bk-026 seeds the supplier
--     booking edges; invoices (bk-028) and supplier bills (bk-029) add theirs. Read-only for role booking.
--   * Post-sale trip case edges (critic B1: the money edges invoice_sent / payment_pending / paid wait for bk-028):
--     confirmed -> supplier_confirming (first supplier booking requested), supplier_confirming -> confirmed (no live
--     supplier booking left), confirmed / supplier_confirming -> pre_departure, pre_departure -> on_trip,
--     on_trip -> completed, and cancel from supplier_confirming and pre_departure.
--   * booking.trip_cases_post_sale_guard (BEFORE UPDATE OF status): an edge alone is no control, because the staff
--     status route walks any edge in the table. The guard checks the FACT behind each post-sale target:
--       supplier_confirming  >= 1 live supplier booking;
--       confirmed (back from supplier_confirming)  no live supplier booking;
--       pre_departure        supply state booked or none (v_trip_case_supply_state) and, in bk-026, a B2B case only
--                            (a B2C case also needs its live invoice paid: bk-028 replaces this function);
--       on_trip              start_date <= current_date;  completed  end_date < current_date;
--       invoice_sent / payment_pending / paid  refused here (bk-028: B2C only, equal to what the invoice implies);
--       new_inquiry (reopen from cancelled)  no live supplier booking (critic B9; bk-028 adds invoices, payments).
--     The application also refuses every post-sale target but cancelled on the staff route (409
--     status_system_managed); only the operations service moves them.
--   * booking.ops_files: documents of the operations module, in the private ops-docs bucket
--     (aa-booking-<env>-ops-docs-<account>, SSE-KMS with a CMK, AA-CIS-Infra) under the key ops-docs/<kind>/<id>.<ext>
--     derived from the row (CHECK). PDF / JPEG / PNG / WebP, at most 10 MB, sha256, file name. Kinds for every slice
--     (payment_evidence, supplier_voucher, supplier_confirmation, supplier_bill, payout_evidence); bk-026 accepts only
--     the supplier-booking kinds (the guard refuses the others until bk-028 / bk-029 create their entities). No file
--     on a supplier booking of a B2B case (DM-6.8: no traveller data of an agency trip in booking.*; design D12).
--     status active | removed (removed is final). Role booking: SELECT, INSERT, UPDATE of the removal columns only.
--   * booking.supplier_bookings (code SB-000123): one booking of one supplier for one item of the approved version (or
--     an extra item without one): supplier, room type or service, description, service date, nights, pax, net amount
--     and currency, status pending -> requested -> confirmed | declined, cancel, confirmed -> requested (a change);
--     confirmation_ref on confirm, decline_code (the four B2B desk codes) on decline, cancel_reason on cancel,
--     voucher_file_id, and for an on-request line of a B2B case the hold line (b2b_hold_id, b2b_line_ref). At most
--     ONE LIVE booking (pending, requested, confirmed) per version item: a declined booking does not block its
--     replacement with another supplier (critic B3). Edges by ops_transitions; facts by supplier_bookings_guard.
--   * booking.v_trip_case_supply_state: per trip case, the supply items of the approved version (rooms / services),
--     how many are booked, the live / confirmed / waiting / declined counts and the state:
--       none        nothing to book (no supply item to book and no live booking), e.g. a B2B case of departure plan
--                   lines only, which have no supplier (critic: passes the pre_departure gate like booked);
--       booked      >= 1 live booking or booked item, every live booking confirmed and every supply item booked =
--                   "Confirmed & Booked" (design D1, a computed badge, not a status);
--       confirming  anything else (an item still to book, or a live booking not yet confirmed).
--     A supply item counts as booked when it has a confirmed live booking or, for a B2B case, its on-request hold
--     line is confirmed (answered on the desk before or without a supplier booking). Items of a B2B line that is
--     declined or cancelled no longer need supply.
--   * settings rows supplier_answer_days (2), pre_departure_days (14), ops_docs_max_bytes (10485760).
--
-- Not here: trip checks (bk-027), invoices / schedule / payments (bk-028), supplier bills / payouts (bk-029). No outbox
-- change: a supplier booking of an on-request B2B line answers the line through app/b2b/desk.answer_line, whose UPDATE
-- fires the bk-022 trigger (line.confirmed / line.declined), so booking.b2b.v1 stays 1.1.
--
-- Locks: trip_cases takes SHARE ROW EXCLUSIVE for the new trigger (an instant); the new tables are empty.
-- lock_timeout 5s: the apply fails rather than queueing behind the job worker.
-- Re-runnable (the Integration Tests replay every file): IF NOT EXISTS everywhere, DROP CONSTRAINT IF EXISTS is not
-- needed (new tables only), CREATE OR REPLACE for functions, triggers and the view (same column list), ON CONFLICT DO
-- NOTHING for seed rows, grants repeat.
-- Undo (a later bk- file): DROP the view, supplier_bookings, ops_files, ops_transitions, the guard trigger and
-- function, DELETE the bk-026 edges and settings rows (only while no case is in a post-sale status other than
-- confirmed / cancelled).

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF current_user <> 'bk_owner' THEN
        RAISE EXCEPTION 'bk-026: expected to run as bk_owner (live owner of schema booking), running as %', current_user;
    END IF;
    IF to_regclass('booking.b2b_hold_lines') IS NULL OR to_regclass('booking.services') IS NULL THEN
        RAISE EXCEPTION 'bk-026: needs bk-010 (hotels, services) and bk-020 / bk-022 (b2b_hold_lines) first';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'booking' AND table_name = 'b2b_hold_lines' AND column_name = 'decline_code') THEN
        RAISE EXCEPTION 'bk-026: needs bk-022 (b2b_hold_lines.decline_code) first';
    END IF;
END $$;

-- ── Generic operations state machines ────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.ops_transitions (
    entity       TEXT NOT NULL,
    from_status  TEXT NOT NULL,
    to_status    TEXT NOT NULL,

    CONSTRAINT ops_transitions_pk PRIMARY KEY (entity, from_status, to_status),
    CONSTRAINT ops_transitions_entity_chk CHECK (entity IN ('supplier_booking', 'invoice', 'supplier_bill')),
    CONSTRAINT ops_transitions_distinct_chk CHECK (from_status <> to_status)
);

COMMENT ON TABLE booking.ops_transitions IS
    'bk-026 (AA-682 D4): allowed status edges of the operations entities (supplier_booking; invoice from bk-028; supplier_bill from bk-029), checked by booking.ops_check_transition(<entity>). Read-only for role booking; changed by a reviewed migration.';

CREATE OR REPLACE FUNCTION booking.ops_check_transition() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM booking.ops_transitions t
        WHERE t.entity = TG_ARGV[0] AND t.from_status = OLD.status AND t.to_status = NEW.status
    ) THEN
        RAISE EXCEPTION 'illegal % status transition % -> %', TG_ARGV[0], OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.ops_check_transition() IS
    'bk-026 (AA-682 D4): BEFORE UPDATE OF status trigger function; TG_ARGV[0] names the entity of booking.ops_transitions. An edge that is not listed raises check_violation.';

INSERT INTO booking.ops_transitions (entity, from_status, to_status) VALUES
    ('supplier_booking', 'pending', 'requested'),
    ('supplier_booking', 'pending', 'cancelled'),
    ('supplier_booking', 'requested', 'confirmed'),
    ('supplier_booking', 'requested', 'declined'),
    ('supplier_booking', 'requested', 'cancelled'),
    ('supplier_booking', 'confirmed', 'requested'),
    ('supplier_booking', 'confirmed', 'cancelled')
ON CONFLICT DO NOTHING;

-- ── Post-sale trip case edges (money edges: bk-028) ──────────────────────────

INSERT INTO booking.trip_case_status_transitions (from_status, to_status) VALUES
    ('confirmed', 'supplier_confirming'),
    ('supplier_confirming', 'confirmed'),
    ('confirmed', 'pre_departure'),
    ('supplier_confirming', 'pre_departure'),
    ('pre_departure', 'on_trip'),
    ('on_trip', 'completed'),
    ('supplier_confirming', 'cancelled'),
    ('pre_departure', 'cancelled')
ON CONFLICT DO NOTHING;

COMMENT ON TABLE booking.trip_case_status_transitions IS
    'bk-003 + bk-005 + bk-026: allowed trip case status edges (read-only for role booking). Pre-sale edges, proposal_sent -> confirmed (version approval), confirmed -> cancelled, cancelled -> new_inquiry (reopen); bk-026 (AA-682): the supply and travel edges (confirmed <-> supplier_confirming, -> pre_departure -> on_trip -> completed, cancel from supplier_confirming / pre_departure), each fact-checked by trip_cases_post_sale_guard. Money edges ship with bk-028.';

-- ── Operations documents ─────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.ops_files (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    kind            TEXT NOT NULL,
    entity_type     TEXT NOT NULL,
    entity_id       UUID NOT NULL,
    trip_case_id    UUID REFERENCES booking.trip_cases (id),
    s3_bucket       TEXT NOT NULL,
    s3_key          TEXT NOT NULL,
    content_type    TEXT NOT NULL,
    bytes           INTEGER NOT NULL,
    sha256          TEXT NOT NULL,
    file_name       TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'active',
    removed_reason  TEXT,
    removed_at      TIMESTAMPTZ,
    uploaded_by     TEXT REFERENCES booking.staff_users (cis_user_id),
    removed_by      TEXT REFERENCES booking.staff_users (cis_user_id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT ops_files_kind_chk CHECK (kind IN ('payment_evidence', 'supplier_voucher', 'supplier_confirmation',
                                                  'supplier_bill', 'payout_evidence')),
    CONSTRAINT ops_files_entity_type_chk CHECK (entity_type IN ('payment', 'supplier_booking', 'supplier_bill',
                                                                'supplier_payout')),
    CONSTRAINT ops_files_kind_entity_chk CHECK (
        (kind = 'payment_evidence' AND entity_type = 'payment')
        OR (kind IN ('supplier_voucher', 'supplier_confirmation') AND entity_type = 'supplier_booking')
        OR (kind = 'supplier_bill' AND entity_type = 'supplier_bill')
        OR (kind = 'payout_evidence' AND entity_type = 'supplier_payout')),
    CONSTRAINT ops_files_bucket_chk CHECK (s3_bucket ~ '^aa-booking-[a-z0-9]+-ops-docs-[0-9]{12}$'),
    CONSTRAINT ops_files_content_type_chk CHECK (content_type IN ('application/pdf', 'image/jpeg', 'image/png',
                                                                  'image/webp')),
    -- The key is derived from the row: ops-docs/<kind>/<id>.<ext of the content type>.
    CONSTRAINT ops_files_key_chk CHECK (
        s3_key = 'ops-docs/' || kind || '/' || id::text || '.'
                 || CASE content_type WHEN 'application/pdf' THEN 'pdf' WHEN 'image/jpeg' THEN 'jpg'
                                      WHEN 'image/png' THEN 'png' ELSE 'webp' END),
    CONSTRAINT ops_files_bytes_chk CHECK (bytes BETWEEN 1 AND 10485760),
    CONSTRAINT ops_files_sha256_chk CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT ops_files_name_chk CHECK (length(file_name) BETWEEN 1 AND 200),
    CONSTRAINT ops_files_status_chk CHECK (status IN ('active', 'removed')),
    CONSTRAINT ops_files_removed_chk CHECK (
        (status = 'removed') = (removed_at IS NOT NULL AND removed_reason IS NOT NULL)
        AND (removed_reason IS NULL OR length(removed_reason) BETWEEN 1 AND 500))
);

COMMENT ON TABLE booking.ops_files IS
    'bk-026 (AA-682 D10): documents of the operations module (supplier vouchers / confirmations now; payment evidence, supplier bills, payout evidence from bk-028 / bk-029) in the private ops-docs bucket (SSE-KMS CMK) under ops-docs/<kind>/<id>.<ext>. Never deleted by role booking: status active / removed (final). No file on a B2B case (DM-6.8).';
COMMENT ON COLUMN booking.ops_files.entity_id IS
    'bk-026: id of the row the file belongs to, per entity_type (no FK: one column pair for several tables; booking.ops_files_guard refuses a missing entity).';
COMMENT ON COLUMN booking.ops_files.s3_bucket IS
    'bk-026: the Booking ops-docs bucket (Terraform aa-booking-<env>-ops-docs-<account>); settings OPS_DOCS_BUCKET.';
COMMENT ON COLUMN booking.ops_files.s3_key IS
    'pii:payment; also pii:name (the object may hold bank references and traveller names: vouchers, evidence). bk-026: derived from the row, ops-docs/<kind>/<id>.<ext>.';
COMMENT ON COLUMN booking.ops_files.file_name IS
    'pii:free_text; the file name as uploaded (may name a person). bk-026: shown to staff, used as the download file name.';
COMMENT ON COLUMN booking.ops_files.removed_reason IS
    'pii:free_text; why staff removed the file (bk-026).';
COMMENT ON COLUMN booking.ops_files.sha256 IS
    'bk-026: hex SHA-256 of the stored bytes, computed by the API; one active copy of the same bytes per entity.';

CREATE UNIQUE INDEX IF NOT EXISTS ops_files_entity_sha_uq
    ON booking.ops_files (entity_type, entity_id, sha256) WHERE status = 'active';
CREATE INDEX IF NOT EXISTS ops_files_entity_idx ON booking.ops_files (entity_type, entity_id, created_at);
CREATE INDEX IF NOT EXISTS ops_files_trip_case_idx ON booking.ops_files (trip_case_id) WHERE trip_case_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS ops_files_uploaded_by_idx ON booking.ops_files (uploaded_by) WHERE uploaded_by IS NOT NULL;
CREATE INDEX IF NOT EXISTS ops_files_removed_by_idx ON booking.ops_files (removed_by) WHERE removed_by IS NOT NULL;
CREATE INDEX IF NOT EXISTS ops_files_removed_idx ON booking.ops_files (removed_at) WHERE status = 'removed';

CREATE OR REPLACE TRIGGER ops_files_set_updated_at
    BEFORE UPDATE ON booking.ops_files
    FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();

-- ── Supplier bookings ────────────────────────────────────────────────────────

CREATE SEQUENCE IF NOT EXISTS booking.supplier_booking_code_seq;

CREATE TABLE IF NOT EXISTS booking.supplier_bookings (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code                TEXT NOT NULL DEFAULT ('SB-' || lpad(nextval('booking.supplier_booking_code_seq')::text, 6, '0')),
    trip_case_id        UUID NOT NULL REFERENCES booking.trip_cases (id),
    version_item_id     UUID REFERENCES booking.trip_case_version_itinerary (id),
    supplier_id         UUID NOT NULL REFERENCES booking.suppliers (id),
    hotel_room_type_id  UUID REFERENCES booking.hotel_room_types (id),
    service_id          UUID REFERENCES booking.services (id),
    item_description    TEXT NOT NULL,
    service_date        DATE,
    nights              SMALLINT,
    pax                 SMALLINT,
    net_amount          NUMERIC(16, 2),
    net_currency        CHARACTER(3),
    status              TEXT NOT NULL DEFAULT 'pending',
    requested_at        TIMESTAMPTZ,
    requested_by        TEXT REFERENCES booking.staff_users (cis_user_id),
    confirmed_at        TIMESTAMPTZ,
    confirmed_by        TEXT REFERENCES booking.staff_users (cis_user_id),
    confirmation_ref    TEXT,
    declined_at         TIMESTAMPTZ,
    decline_code        TEXT,
    cancelled_at        TIMESTAMPTZ,
    cancel_reason       TEXT,
    voucher_file_id     UUID REFERENCES booking.ops_files (id),
    b2b_hold_id         UUID,
    b2b_line_ref        TEXT,
    notes               TEXT,
    created_by          TEXT REFERENCES booking.staff_users (cis_user_id),
    updated_by          TEXT REFERENCES booking.staff_users (cis_user_id),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT supplier_bookings_code_chk CHECK (code ~ '^SB-[0-9]{6,}$'),
    CONSTRAINT supplier_bookings_b2b_line_fk FOREIGN KEY (b2b_hold_id, b2b_line_ref)
        REFERENCES booking.b2b_hold_lines (hold_id, line_ref),
    CONSTRAINT supplier_bookings_b2b_pair_chk CHECK ((b2b_hold_id IS NULL) = (b2b_line_ref IS NULL)),
    CONSTRAINT supplier_bookings_supply_chk CHECK (num_nonnulls(hotel_room_type_id, service_id) <= 1),
    CONSTRAINT supplier_bookings_description_chk CHECK (length(item_description) BETWEEN 1 AND 500),
    CONSTRAINT supplier_bookings_nights_chk CHECK (nights IS NULL OR nights BETWEEN 0 AND 60),
    CONSTRAINT supplier_bookings_pax_chk CHECK (pax IS NULL OR pax BETWEEN 1 AND 120),
    CONSTRAINT supplier_bookings_net_chk CHECK (
        (net_amount IS NULL) = (net_currency IS NULL)
        AND (net_amount IS NULL OR net_amount >= 0)
        AND (net_currency IS NULL OR net_currency ~ '^[A-Z]{3}$')),
    CONSTRAINT supplier_bookings_status_chk CHECK (status IN ('pending', 'requested', 'confirmed', 'declined',
                                                              'cancelled')),
    CONSTRAINT supplier_bookings_requested_chk CHECK (status = 'pending' OR status = 'cancelled'
                                                      OR requested_at IS NOT NULL),
    CONSTRAINT supplier_bookings_confirmed_chk CHECK (
        status <> 'confirmed' OR (confirmation_ref IS NOT NULL AND confirmed_at IS NOT NULL)),
    CONSTRAINT supplier_bookings_ref_chk CHECK (confirmation_ref IS NULL OR length(confirmation_ref) BETWEEN 1 AND 100),
    CONSTRAINT supplier_bookings_decline_chk CHECK (
        (status = 'declined') = (decline_code IS NOT NULL AND declined_at IS NOT NULL)
        AND (decline_code IS NULL OR decline_code IN ('sold_out', 'supplier_unavailable', 'minimum_not_met', 'other'))),
    CONSTRAINT supplier_bookings_cancel_chk CHECK (
        (status = 'cancelled') = (cancel_reason IS NOT NULL AND cancelled_at IS NOT NULL)
        AND (cancel_reason IS NULL OR length(cancel_reason) BETWEEN 1 AND 500)),
    CONSTRAINT supplier_bookings_notes_chk CHECK (notes IS NULL OR length(notes) BETWEEN 1 AND 2000)
);

COMMENT ON TABLE booking.supplier_bookings IS
    'bk-026 (AA-682 S1): one booking of one supplier for one item of the approved version of a trip case (B2C and B2B, memo seam 1), or an extra item. Live = pending / requested / confirmed: at most one live booking per version item (a declined one can be replaced, B2C). Edges in booking.ops_transitions (supplier_booking); an on-request B2B line is answered in the same transaction (desk.answer_line, line.confirmed / line.declined). Never deleted.';
COMMENT ON COLUMN booking.supplier_bookings.item_description IS
    'bk-026: what is booked (hotel and room type, service title, or the item title); copied from the version item, editable while pending / requested.';
COMMENT ON COLUMN booking.supplier_bookings.net_amount IS
    'conf:commercial; bk-026: expected supplier net, the sum of the item''s version_item_costs rows (refused when their currencies differ), editable while pending / requested.';
COMMENT ON COLUMN booking.supplier_bookings.notes IS
    'pii:free_text; also conf:commercial (staff notes on the booking; may name a traveller, so the field help says: no traveller names on a B2B case, DM-6.8).';
COMMENT ON COLUMN booking.supplier_bookings.cancel_reason IS
    'pii:free_text; why the booking was cancelled (bk-026).';
COMMENT ON COLUMN booking.supplier_bookings.confirmation_ref IS
    'bk-026: the supplier''s confirmation number, required to confirm.';
COMMENT ON COLUMN booking.supplier_bookings.b2b_hold_id IS
    'bk-026 (design D13): with b2b_line_ref, the on-request hold line of a B2B case this booking answers (confirm = accept, decline = decline, desk.answer_line in the same transaction).';

CREATE UNIQUE INDEX IF NOT EXISTS supplier_bookings_code_uq ON booking.supplier_bookings (code);
-- One live booking per version item; declined and cancelled rows never block a replacement (critic B3).
CREATE UNIQUE INDEX IF NOT EXISTS supplier_bookings_item_live_uq
    ON booking.supplier_bookings (version_item_id)
    WHERE status IN ('pending', 'requested', 'confirmed') AND version_item_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS supplier_bookings_case_idx ON booking.supplier_bookings (trip_case_id, created_at);
CREATE INDEX IF NOT EXISTS supplier_bookings_item_idx
    ON booking.supplier_bookings (version_item_id) WHERE version_item_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS supplier_bookings_supplier_idx
    ON booking.supplier_bookings (supplier_id, service_date DESC);
CREATE INDEX IF NOT EXISTS supplier_bookings_waiting_idx
    ON booking.supplier_bookings (requested_at) WHERE status = 'requested';
CREATE INDEX IF NOT EXISTS supplier_bookings_room_type_idx
    ON booking.supplier_bookings (hotel_room_type_id) WHERE hotel_room_type_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS supplier_bookings_service_idx
    ON booking.supplier_bookings (service_id) WHERE service_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS supplier_bookings_voucher_idx
    ON booking.supplier_bookings (voucher_file_id) WHERE voucher_file_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS supplier_bookings_b2b_line_idx
    ON booking.supplier_bookings (b2b_hold_id, b2b_line_ref) WHERE b2b_hold_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS supplier_bookings_requested_by_idx
    ON booking.supplier_bookings (requested_by) WHERE requested_by IS NOT NULL;
CREATE INDEX IF NOT EXISTS supplier_bookings_confirmed_by_idx
    ON booking.supplier_bookings (confirmed_by) WHERE confirmed_by IS NOT NULL;
CREATE INDEX IF NOT EXISTS supplier_bookings_created_by_idx
    ON booking.supplier_bookings (created_by) WHERE created_by IS NOT NULL;
CREATE INDEX IF NOT EXISTS supplier_bookings_updated_by_idx
    ON booking.supplier_bookings (updated_by) WHERE updated_by IS NOT NULL;

CREATE OR REPLACE TRIGGER supplier_bookings_set_updated_at
    BEFORE UPDATE ON booking.supplier_bookings
    FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();

CREATE OR REPLACE TRIGGER supplier_bookings_check_transition
    BEFORE UPDATE OF status ON booking.supplier_bookings
    FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status)
    EXECUTE FUNCTION booking.ops_check_transition('supplier_booking');

-- Facts of a supplier booking: where it belongs, what may change when, and no voucher on a B2B case.
CREATE OR REPLACE FUNCTION booking.supplier_bookings_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_channel  TEXT;
    v_item_ok  BOOLEAN;
BEGIN
    SELECT channel INTO v_channel FROM booking.trip_cases WHERE id = NEW.trip_case_id;
    IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'pending' THEN
            RAISE EXCEPTION 'a supplier booking starts pending, not %', NEW.status USING ERRCODE = 'check_violation';
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
        IF (NEW.trip_case_id, NEW.version_item_id, NEW.b2b_hold_id, NEW.b2b_line_ref, NEW.code, NEW.created_by,
            NEW.created_at)
           IS DISTINCT FROM
           (OLD.trip_case_id, OLD.version_item_id, OLD.b2b_hold_id, OLD.b2b_line_ref, OLD.code, OLD.created_by,
            OLD.created_at) THEN
            RAISE EXCEPTION 'supplier booking %: case, item, B2B line and code never change', OLD.code
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
    'bk-026 (AA-682): a supplier booking starts pending, belongs to an item of the approved version of its case, names the hold of its own B2B case only; case / item / line / code never change; supplier and service facts change only while pending / requested; the voucher is an active supplier_voucher file of this booking and never on a B2B case.';

CREATE OR REPLACE TRIGGER supplier_bookings_guard
    BEFORE INSERT OR UPDATE ON booking.supplier_bookings
    FOR EACH ROW EXECUTE FUNCTION booking.supplier_bookings_guard();

-- Files: removed is final; the entity exists; bk-026 takes only files of supplier bookings, never of a B2B case.
CREATE OR REPLACE FUNCTION booking.ops_files_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_case     UUID;
    v_channel  TEXT;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF OLD.status = 'removed' AND NEW.status IS DISTINCT FROM OLD.status THEN
            RAISE EXCEPTION 'file % is removed; upload it again instead', OLD.id
                USING ERRCODE = 'object_not_in_prerequisite_state';
        END IF;
        IF (NEW.kind, NEW.entity_type, NEW.entity_id, NEW.trip_case_id, NEW.s3_bucket, NEW.s3_key, NEW.content_type,
            NEW.bytes, NEW.sha256, NEW.file_name, NEW.uploaded_by, NEW.created_at)
           IS DISTINCT FROM
           (OLD.kind, OLD.entity_type, OLD.entity_id, OLD.trip_case_id, OLD.s3_bucket, OLD.s3_key, OLD.content_type,
            OLD.bytes, OLD.sha256, OLD.file_name, OLD.uploaded_by, OLD.created_at) THEN
            RAISE EXCEPTION 'file %: only its removal changes', OLD.id USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.status <> 'active' THEN
        RAISE EXCEPTION 'a file starts active' USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.entity_type <> 'supplier_booking' THEN
        -- Payments (bk-028), supplier bills and payouts (bk-029) do not exist yet; those files replace this function.
        RAISE EXCEPTION 'files of a % arrive with a later migration', NEW.entity_type USING ERRCODE = 'check_violation';
    END IF;
    SELECT sb.trip_case_id, tc.channel INTO v_case, v_channel
      FROM booking.supplier_bookings sb JOIN booking.trip_cases tc ON tc.id = sb.trip_case_id
     WHERE sb.id = NEW.entity_id;
    IF v_case IS NULL THEN
        RAISE EXCEPTION 'file %: supplier booking % does not exist', NEW.id, NEW.entity_id
            USING ERRCODE = 'foreign_key_violation';
    END IF;
    IF NEW.trip_case_id IS DISTINCT FROM v_case THEN
        RAISE EXCEPTION 'file %: trip_case_id must be the trip case of supplier booking %', NEW.id, NEW.entity_id
            USING ERRCODE = 'check_violation';
    END IF;
    IF v_channel = 'b2b' THEN
        RAISE EXCEPTION 'no supplier document on a B2B trip case (DM-6.8: confirmation ref only)'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.ops_files_guard() IS
    'bk-026 (AA-682 D10, D12): a file starts active, only its removal changes and removed is final; bk-026 accepts files of an existing supplier booking of a B2C case only (bk-028 / bk-029 replace this function for their entities).';

CREATE OR REPLACE TRIGGER ops_files_guard
    BEFORE INSERT OR UPDATE ON booking.ops_files
    FOR EACH ROW EXECUTE FUNCTION booking.ops_files_guard();

-- ── Supply state (computed badge, design D1) ─────────────────────────────────

CREATE OR REPLACE VIEW booking.v_trip_case_supply_state AS
SELECT tc.id AS trip_case_id,
       items.to_book::int AS items_to_book,
       items.booked::int AS items_booked,
       coalesce(sb.live, 0)::int AS live,
       coalesce(sb.confirmed, 0)::int AS confirmed,
       coalesce(sb.waiting, 0)::int AS waiting,
       coalesce(sb.declined, 0)::int AS declined,
       CASE
           WHEN coalesce(sb.live, 0) = 0 AND items.to_book = 0 THEN 'none'
           WHEN coalesce(sb.live, 0) = coalesce(sb.confirmed, 0) AND items.booked = items.to_book THEN 'booked'
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
LEFT JOIN LATERAL (
    SELECT count(*) FILTER (WHERE b.status IN ('pending', 'requested', 'confirmed')) AS live,
           count(*) FILTER (WHERE b.status = 'confirmed') AS confirmed,
           count(*) FILTER (WHERE b.status IN ('pending', 'requested')) AS waiting,
           count(*) FILTER (WHERE b.status = 'declined') AS declined
      FROM booking.supplier_bookings b
     WHERE b.trip_case_id = tc.id
) sb ON true;

COMMENT ON VIEW booking.v_trip_case_supply_state IS
    'bk-026 (AA-682 D1): per trip case, supply items of the approved version to book / booked, live / confirmed / waiting / declined supplier bookings, and state none | confirming | booked (booked = the "Confirmed & Booked" badge). Live = pending / requested / confirmed. A B2B item whose on-request line is confirmed counts as booked; one whose line is declined or cancelled needs no supply.';

-- ── Fact guard on post-sale case statuses (critic B1, B9) ────────────────────

CREATE OR REPLACE FUNCTION booking.trip_cases_post_sale_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_live   INTEGER;
    v_state  TEXT;
BEGIN
    SELECT count(*) INTO v_live FROM booking.supplier_bookings
     WHERE trip_case_id = NEW.id AND status IN ('pending', 'requested', 'confirmed');
    IF NEW.status = 'supplier_confirming' AND v_live = 0 THEN
        RAISE EXCEPTION 'trip case %: supplier_confirming needs a live supplier booking', NEW.code
            USING ERRCODE = 'check_violation';
    ELSIF NEW.status = 'confirmed' AND OLD.status = 'supplier_confirming' AND v_live > 0 THEN
        RAISE EXCEPTION 'trip case %: back to confirmed only when no live supplier booking is left', NEW.code
            USING ERRCODE = 'check_violation';
    ELSIF NEW.status = 'pre_departure' THEN
        SELECT state INTO v_state FROM booking.v_trip_case_supply_state WHERE trip_case_id = NEW.id;
        IF v_state IS DISTINCT FROM 'booked' AND v_state IS DISTINCT FROM 'none' THEN
            RAISE EXCEPTION 'trip case %: pre_departure needs every supplier booking confirmed (supply is %)',
                NEW.code, v_state USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.channel <> 'b2b' THEN
            -- A B2C case also needs its live invoice paid: bk-028 replaces this function.
            RAISE EXCEPTION 'trip case %: a B2C case reaches pre_departure only once paid (invoices: bk-028)', NEW.code
                USING ERRCODE = 'check_violation';
        END IF;
    ELSIF NEW.status = 'on_trip' AND (NEW.start_date IS NULL OR NEW.start_date > current_date) THEN
        RAISE EXCEPTION 'trip case %: on_trip only from its start date', NEW.code USING ERRCODE = 'check_violation';
    ELSIF NEW.status = 'completed' AND (NEW.end_date IS NULL OR NEW.end_date >= current_date) THEN
        RAISE EXCEPTION 'trip case %: completed only after its end date', NEW.code USING ERRCODE = 'check_violation';
    ELSIF NEW.status IN ('invoice_sent', 'payment_pending', 'paid') THEN
        RAISE EXCEPTION 'trip case %: % is set by the invoice of bk-028 only', NEW.code, NEW.status
            USING ERRCODE = 'check_violation';
    ELSIF NEW.status = 'new_inquiry' AND OLD.status = 'cancelled' AND v_live > 0 THEN
        RAISE EXCEPTION 'trip case %: cancel its % live supplier booking(s) before reopening it', NEW.code, v_live
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.trip_cases_post_sale_guard() IS
    'bk-026 (AA-682 critic B1, B9): the fact behind each post-sale case status (supplier bookings, supply state, dates); money statuses refused until bk-028 replaces this function; reopen refused while a live supplier booking exists.';

CREATE OR REPLACE TRIGGER trip_cases_post_sale_guard
    BEFORE UPDATE OF status ON booking.trip_cases
    FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status)
    EXECUTE FUNCTION booking.trip_cases_post_sale_guard();

-- ── Settings (policy data) ───────────────────────────────────────────────────

INSERT INTO booking.settings (key, value, description) VALUES
    ('supplier_answer_days', '2'::jsonb, 'Days a requested supplier booking may wait for the supplier''s answer before staff are reminded (AA-682; policy data, proposed for Ms. Thu).'),
    ('pre_departure_days', '14'::jsonb, 'Days before the start date a fully booked (and, B2C, paid) trip case moves to pre_departure (AA-682; policy data).'),
    ('ops_docs_max_bytes', '10485760'::jsonb, 'Upper bound of one operations document in bytes (AA-682 D10; the base64 path through the staff BFF caps it lower, see app/ops/files.py).')
ON CONFLICT (key) DO NOTHING;

-- ── Grants (per object) ──────────────────────────────────────────────────────

REVOKE ALL ON booking.ops_transitions FROM booking;
GRANT SELECT ON booking.ops_transitions TO booking;

-- ops_files: insert, then only the removal columns change; never deleted.
REVOKE ALL ON booking.ops_files FROM booking;
GRANT SELECT, INSERT ON booking.ops_files TO booking;
GRANT UPDATE (status, removed_reason, removed_at, removed_by, updated_at) ON booking.ops_files TO booking;

-- supplier_bookings: never deleted.
REVOKE ALL ON booking.supplier_bookings FROM booking;
GRANT SELECT, INSERT, UPDATE ON booking.supplier_bookings TO booking;
GRANT USAGE, SELECT ON SEQUENCE booking.supplier_booking_code_seq TO booking;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON booking.v_trip_case_supply_state FROM booking;
GRANT SELECT ON booking.v_trip_case_supply_state TO booking;

GRANT EXECUTE ON FUNCTION booking.ops_check_transition() TO booking;
GRANT EXECUTE ON FUNCTION booking.supplier_bookings_guard() TO booking;
GRANT EXECUTE ON FUNCTION booking.ops_files_guard() TO booking;
GRANT EXECUTE ON FUNCTION booking.trip_cases_post_sale_guard() TO booking;

DO $$
DECLARE
    v_rel TEXT;
BEGIN
    FOREACH v_rel IN ARRAY ARRAY['booking.ops_transitions', 'booking.ops_files', 'booking.supplier_bookings',
                                 'booking.v_trip_case_supply_state'] LOOP
        IF has_table_privilege('booking', v_rel, 'DELETE') OR has_table_privilege('booking', v_rel, 'TRUNCATE') THEN
            RAISE EXCEPTION 'bk-026: role booking can delete from %', v_rel;
        END IF;
    END LOOP;
    IF has_table_privilege('booking', 'booking.ops_transitions', 'INSERT')
       OR has_table_privilege('booking', 'booking.v_trip_case_supply_state', 'UPDATE') THEN
        RAISE EXCEPTION 'bk-026: role booking can write reference data or the supply view';
    END IF;
    IF has_table_privilege('cis_app', 'booking.supplier_bookings', 'SELECT')
       OR has_table_privilege('cis_app', 'booking.ops_files', 'SELECT') THEN
        RAISE EXCEPTION 'bk-026: cis_app can read an operations table';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-026', now(), 'AA-682 S1: ops_transitions + ops_check_transition, post-sale trip case edges (supply / travel) + trip_cases_post_sale_guard, ops_files (ops-docs bucket), supplier_bookings (SB- code, one live per version item), v_trip_case_supply_state, settings supplier_answer_days / pre_departure_days / ops_docs_max_bytes')
ON CONFLICT (version) DO NOTHING;

COMMIT;
