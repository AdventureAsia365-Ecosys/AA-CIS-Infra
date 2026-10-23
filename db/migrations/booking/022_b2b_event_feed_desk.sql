-- Migration bk-022: AA-975 (CRM-B3) — the shared Booking outbox and the B2B event feed, the on-request desk and the
-- departure incident flag (contract booking.b2b.v1 minor 1.1 GET /events; design v3 §3.4 "b2b_event outbox", §2.5
-- "Booking staff admin"; Booking commercial-core memo seams 4, 8, 10).
--
-- Owner: AA-Booking (key bk-NNN). A byte-identical copy goes to AA-CIS-Infra db/migrations/booking/022_b2b_event_feed_desk.sql
-- and is applied to Dev by the DB Migrate workflow (check, then apply), as bk_owner (the live owner of schema booking
-- since bk-014). Never run it from a laptop.
--
-- Depends on bk-003 (staff_users), bk-005 (settings), bk-019 (b2b_partners), bk-020 (departures, b2b_holds,
-- b2b_hold_lines) and bk-021 (b2b_cancellations). Every grant names its table (no "ON ALL TABLES").
--
-- What it adds (docs/implementation-notes/AA-975.md):
--   * booking.outbox: ONE transactional outbox for every event Booking publishes to another app. A row is written in
--     the same transaction as the change it reports (by the triggers below), so an event exists if and only if the
--     change committed. stream 'b2b' = the booking.b2b.v1 feed of one partner agency (partner_id); AA-835 adds stream
--     'supply' (ADR 0004a) with its own columns and v_supply_* views. Typed id columns only: no payload, no free text,
--     so no event can ever carry traveller data (Linear AA-975 E). No foreign keys: an event outlives what it names
--     (log semantics; retention / test clean-up of the named rows never fails on it).
--   * Feed order: feed_seq is NOT the insert order. Two transactions can commit in the opposite order of their ids,
--     so a reader that paged on id could skip a row committed late. The app stamps feed_seq on committed rows in id
--     order under one advisory lock (app/outbox.py; sequence booking.outbox_feed_seq): a feed_seq is only ever given
--     to a committed row, and later stampings only give larger numbers, so a cursor "feed_seq > n" never skips and
--     never repeats a row (at-least-once delivery; consumers dedupe on event_id).
--   * Triggers that write the b2b events: b2b_holds (hold.expired, hold.extended), b2b_hold_lines (line.confirmed,
--     line.declined), b2b_cancellations (booking.cancelled), departures (departure.guaranteed, departure.cancelled)
--     and departure_incidents (departure.incident, departure.incident_cleared). Departure events fan out: one row per
--     partner holding or having bought seats on that departure. A trigger, not a service call, so every path that
--     changes a state (requests, the expiry job, a lazy expiry, the desk, AA-682 later; memo seam 8) emits.
--   * booking.departure_incidents: "Flag incident on departure" in the Booking staff admin (design Fix B3). A fixed
--     incident_code (contract enum), who flagged / cleared it and when; at most one open incident per departure. No
--     free-text column on purpose.
--   * booking.b2b_hold_lines: answer_due_at (the on-request SLA, 1 business day in the ops time zone), answered_at,
--     answered_by, decline_code — the on-request desk (accept / decline). declined <=> a decline_code.
--   * booking.b2b_answer_due(): adds business days (Mon-Fri) in a time zone; a request on a weekend starts the clock
--     at 00:00 of the next Monday. Public holidays are not modelled (est.).
--   * booking.settings rows b2b_on_request_answer_business_days = 1, b2b_ops_timezone = Asia/Ho_Chi_Minh.
--   * Backfill: on_request lines of holds confirmed before bk-022 get their answer_due_at from confirmed_at.
--
-- Locks: b2b_hold_lines takes ACCESS EXCLUSIVE for the column adds and CHECK adds (a tiny table on Dev, a short scan);
-- the triggers take a SHARE ROW EXCLUSIVE lock on their tables for an instant. lock_timeout 5s: the apply fails rather
-- than queueing behind the job worker.
-- Re-runnable (the Integration Tests replay every file): IF NOT EXISTS everywhere, DROP CONSTRAINT IF EXISTS before
-- each added CHECK, CREATE OR REPLACE for functions and triggers, settings rows ON CONFLICT DO NOTHING, the backfill
-- only touches NULLs.

BEGIN;

SET LOCAL lock_timeout = '5s';

-- ── The shared outbox ────────────────────────────────────────────────────────

CREATE SEQUENCE IF NOT EXISTS booking.outbox_feed_seq AS BIGINT;

CREATE TABLE IF NOT EXISTS booking.outbox (
    id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_id       UUID NOT NULL DEFAULT gen_random_uuid(),
    stream         TEXT NOT NULL,
    event_type     TEXT NOT NULL,
    partner_id     UUID,
    hold_id        UUID,
    booking_id     UUID,
    line_ref       TEXT,
    departure_id   UUID,
    incident_code  TEXT,
    decline_code   TEXT,
    occurred_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    feed_seq       BIGINT,
    sequenced_at   TIMESTAMPTZ,
    CONSTRAINT outbox_event_id_uq UNIQUE (event_id),
    CONSTRAINT outbox_feed_seq_uq UNIQUE (feed_seq),
    CONSTRAINT outbox_stream_chk CHECK (stream IN ('b2b')),
    CONSTRAINT outbox_event_type_chk CHECK (event_type IN (
        'hold.expired', 'hold.extended', 'line.confirmed', 'line.declined', 'booking.cancelled',
        'departure.guaranteed', 'departure.cancelled', 'departure.incident', 'departure.incident_cleared')),
    CONSTRAINT outbox_b2b_partner_chk CHECK (stream <> 'b2b' OR partner_id IS NOT NULL),
    CONSTRAINT outbox_hold_chk CHECK (
        (event_type IN ('hold.expired', 'hold.extended', 'line.confirmed', 'line.declined', 'booking.cancelled'))
        = (hold_id IS NOT NULL)),
    CONSTRAINT outbox_booking_chk CHECK (event_type <> 'booking.cancelled' OR booking_id IS NOT NULL),
    CONSTRAINT outbox_line_chk CHECK (
        (event_type IN ('line.confirmed', 'line.declined')) = (line_ref IS NOT NULL)
        AND (line_ref IS NULL OR length(line_ref) BETWEEN 1 AND 64)),
    CONSTRAINT outbox_departure_chk CHECK (event_type NOT LIKE 'departure.%' OR departure_id IS NOT NULL),
    CONSTRAINT outbox_incident_chk CHECK (
        (event_type IN ('departure.incident', 'departure.incident_cleared')) = (incident_code IS NOT NULL)
        AND (incident_code IS NULL
             OR incident_code IN ('weather', 'road', 'health', 'political', 'supplier', 'other'))),
    CONSTRAINT outbox_decline_chk CHECK (
        (event_type = 'line.declined') = (decline_code IS NOT NULL)
        AND (decline_code IS NULL
             OR decline_code IN ('sold_out', 'supplier_unavailable', 'minimum_not_met', 'other'))),
    CONSTRAINT outbox_sequenced_chk CHECK ((feed_seq IS NULL) = (sequenced_at IS NULL))
);

CREATE INDEX IF NOT EXISTS outbox_partner_feed_idx
    ON booking.outbox (partner_id, feed_seq) WHERE feed_seq IS NOT NULL;
CREATE INDEX IF NOT EXISTS outbox_pending_idx ON booking.outbox (id) WHERE feed_seq IS NULL;

COMMENT ON TABLE booking.outbox IS
    'bk-022 (AA-975): the one transactional outbox of Booking. Rows are written by triggers in the transaction of the change; feed_seq is stamped later, in commit order (app/outbox.py), and is the cursor of booking.b2b.v1 GET /events. Ids and codes only, no personal data. No FKs (log).';
COMMENT ON COLUMN booking.outbox.id IS
    'bk-022: insert order (identity). Not a feed cursor: transactions commit out of id order.';
COMMENT ON COLUMN booking.outbox.event_id IS
    'bk-022: the contract Event.event_id; consumers dedupe on it (delivery is at least once).';
COMMENT ON COLUMN booking.outbox.stream IS
    'bk-022: b2b = the booking.b2b.v1 feed of partner_id. AA-835 adds supply (ADR 0004a).';
COMMENT ON COLUMN booking.outbox.partner_id IS
    'bk-022: the booking.b2b_partners row whose feed carries the event (soft key; departure events fan out one row per partner).';
COMMENT ON COLUMN booking.outbox.booking_id IS
    'bk-022: the B2B trip case (contract booking_id), when the event is about a confirmed booking.';
COMMENT ON COLUMN booking.outbox.feed_seq IS
    'bk-022: position in the feed, stamped on committed rows in id order under one advisory lock (app/outbox.py); NULL = not yet visible to readers.';

-- ── Departure incidents (Fix B3) ─────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.departure_incidents (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    departure_id   UUID NOT NULL REFERENCES booking.departures (id),
    incident_code  TEXT NOT NULL,
    flagged_by     TEXT NOT NULL REFERENCES booking.staff_users (cis_user_id),
    flagged_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    cleared_by     TEXT REFERENCES booking.staff_users (cis_user_id),
    cleared_at     TIMESTAMPTZ,
    CONSTRAINT departure_incidents_code_chk CHECK (
        incident_code IN ('weather', 'road', 'health', 'political', 'supplier', 'other')),
    CONSTRAINT departure_incidents_cleared_chk CHECK (
        (cleared_at IS NULL) = (cleared_by IS NULL) AND (cleared_at IS NULL OR cleared_at >= flagged_at))
);

CREATE UNIQUE INDEX IF NOT EXISTS departure_incidents_open_uq
    ON booking.departure_incidents (departure_id) WHERE cleared_at IS NULL;
CREATE INDEX IF NOT EXISTS departure_incidents_departure_idx
    ON booking.departure_incidents (departure_id, flagged_at DESC);

COMMENT ON TABLE booking.departure_incidents IS
    'bk-022 (AA-975, design Fix B3): an incident AA staff flag on a departure (Booking staff admin). A code from a fixed list, never free text or traveller data; at most one open per departure. Emits departure.incident / departure.incident_cleared to the partners on it.';
COMMENT ON COLUMN booking.departure_incidents.incident_code IS
    'bk-022: contract Event.incident_code (weather, road, health, political, supplier, other).';

-- ── On-request desk columns on hold lines ────────────────────────────────────

ALTER TABLE booking.b2b_hold_lines
    ADD COLUMN IF NOT EXISTS answer_due_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS answered_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS answered_by TEXT REFERENCES booking.staff_users (cis_user_id),
    ADD COLUMN IF NOT EXISTS decline_code TEXT;

ALTER TABLE booking.b2b_hold_lines DROP CONSTRAINT IF EXISTS b2b_hold_lines_decline_chk;
ALTER TABLE booking.b2b_hold_lines ADD CONSTRAINT b2b_hold_lines_decline_chk CHECK (
    (status = 'declined') = (decline_code IS NOT NULL)
    AND (decline_code IS NULL OR decline_code IN ('sold_out', 'supplier_unavailable', 'minimum_not_met', 'other')));

ALTER TABLE booking.b2b_hold_lines DROP CONSTRAINT IF EXISTS b2b_hold_lines_answer_chk;
ALTER TABLE booking.b2b_hold_lines ADD CONSTRAINT b2b_hold_lines_answer_chk CHECK (
    (answered_by IS NULL OR answered_at IS NOT NULL)
    AND (answered_at IS NULL OR status IN ('confirmed', 'declined', 'cancelled')));

CREATE INDEX IF NOT EXISTS b2b_hold_lines_on_request_idx
    ON booking.b2b_hold_lines (answer_due_at) WHERE status = 'on_request';

COMMENT ON COLUMN booking.b2b_hold_lines.answer_due_at IS
    'bk-022 (AA-975): when AA ops must accept or decline an on_request line of a confirmed booking (confirmed_at + b2b_on_request_answer_business_days business days in b2b_ops_timezone).';
COMMENT ON COLUMN booking.b2b_hold_lines.answered_at IS
    'bk-022: when the on-request desk accepted (confirmed) or declined the line.';
COMMENT ON COLUMN booking.b2b_hold_lines.answered_by IS
    'bk-022: the staff member who answered the line on the on-request desk.';
COMMENT ON COLUMN booking.b2b_hold_lines.decline_code IS
    'bk-022: why AA declined the line (sold_out, supplier_unavailable, minimum_not_met, other); set exactly when status is declined.';

-- ── Business-day SLA ─────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION booking.b2b_answer_due(start_at TIMESTAMPTZ, business_days INTEGER, tz TEXT)
    RETURNS TIMESTAMPTZ
    LANGUAGE plpgsql
    STABLE
    SET search_path = pg_catalog
AS $$
DECLARE
    v_local TIMESTAMP := start_at AT TIME ZONE tz;
    v_left  INTEGER := greatest(business_days, 0);
BEGIN
    -- A request on Saturday or Sunday starts the clock at 00:00 of the next Monday.
    WHILE extract(isodow FROM v_local) > 5 LOOP
        v_local := date_trunc('day', v_local) + interval '1 day';
    END LOOP;
    WHILE v_left > 0 LOOP
        v_local := v_local + interval '1 day';
        IF extract(isodow FROM v_local) <= 5 THEN
            v_left := v_left - 1;
        END IF;
    END LOOP;
    RETURN v_local AT TIME ZONE tz;
END $$;

COMMENT ON FUNCTION booking.b2b_answer_due(TIMESTAMPTZ, INTEGER, TEXT) IS
    'bk-022 (AA-975): start_at + n business days (Mon-Fri) in time zone tz; a weekend start counts from the next Monday 00:00. No public holidays.';

-- ── Event triggers ───────────────────────────────────────────────────────────

-- The partners with seats on a departure: a live hold, or a confirmed booking whose line is not declined / cancelled.
CREATE OR REPLACE FUNCTION booking.outbox_departure_event(p_departure UUID, p_type TEXT, p_incident TEXT)
    RETURNS void
    LANGUAGE sql
    SET search_path = pg_catalog
AS $$
    INSERT INTO booking.outbox (stream, event_type, partner_id, departure_id, incident_code)
    SELECT DISTINCT 'b2b', p_type, h.partner_id, p_departure, p_incident
    FROM booking.b2b_hold_lines l
    JOIN booking.b2b_holds h ON h.id = l.hold_id
    WHERE l.departure_id = p_departure
      AND ((h.status = 'active' AND h.expires_at > now())
           OR (h.status = 'confirmed' AND l.status NOT IN ('declined', 'cancelled')));
$$;

COMMENT ON FUNCTION booking.outbox_departure_event(UUID, TEXT, TEXT) IS
    'bk-022 (AA-975): one b2b outbox row per partner with seats on the departure (live hold or confirmed booking line).';

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
    RETURN NULL;
END $$;

CREATE OR REPLACE TRIGGER b2b_holds_outbox
    AFTER UPDATE OF status, extended_count ON booking.b2b_holds
    FOR EACH ROW EXECUTE FUNCTION booking.b2b_holds_outbox();

CREATE OR REPLACE FUNCTION booking.b2b_hold_lines_outbox() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_partner UUID;
    v_booking UUID;
BEGIN
    IF NEW.status IN ('confirmed', 'declined') AND OLD.status IS DISTINCT FROM NEW.status THEN
        SELECT h.partner_id, h.trip_case_id INTO v_partner, v_booking FROM booking.b2b_holds h WHERE h.id = NEW.hold_id;
        INSERT INTO booking.outbox
            (stream, event_type, partner_id, hold_id, booking_id, line_ref, departure_id, decline_code)
        VALUES ('b2b', 'line.' || NEW.status, v_partner, NEW.hold_id, v_booking, NEW.line_ref, NEW.departure_id,
                CASE WHEN NEW.status = 'declined' THEN NEW.decline_code END);
    END IF;
    RETURN NULL;
END $$;

CREATE OR REPLACE TRIGGER b2b_hold_lines_outbox
    AFTER UPDATE OF status ON booking.b2b_hold_lines
    FOR EACH ROW EXECUTE FUNCTION booking.b2b_hold_lines_outbox();

CREATE OR REPLACE FUNCTION booking.b2b_cancellations_outbox() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    INSERT INTO booking.outbox (stream, event_type, partner_id, hold_id, booking_id)
    VALUES ('b2b', 'booking.cancelled', NEW.partner_id, NEW.hold_id, NEW.trip_case_id);
    RETURN NULL;
END $$;

CREATE OR REPLACE TRIGGER b2b_cancellations_outbox
    AFTER INSERT ON booking.b2b_cancellations
    FOR EACH ROW EXECUTE FUNCTION booking.b2b_cancellations_outbox();

CREATE OR REPLACE FUNCTION booking.departures_outbox() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    IF NEW.status IN ('guaranteed', 'cancelled') AND OLD.status IS DISTINCT FROM NEW.status THEN
        PERFORM booking.outbox_departure_event(NEW.id, 'departure.' || NEW.status, NULL);
    END IF;
    RETURN NULL;
END $$;

CREATE OR REPLACE TRIGGER departures_outbox
    AFTER UPDATE OF status ON booking.departures
    FOR EACH ROW EXECUTE FUNCTION booking.departures_outbox();

CREATE OR REPLACE FUNCTION booking.departure_incidents_outbox() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        PERFORM booking.outbox_departure_event(NEW.departure_id, 'departure.incident', NEW.incident_code);
    ELSIF OLD.cleared_at IS NULL AND NEW.cleared_at IS NOT NULL THEN
        PERFORM booking.outbox_departure_event(NEW.departure_id, 'departure.incident_cleared', NEW.incident_code);
    END IF;
    RETURN NULL;
END $$;

CREATE OR REPLACE TRIGGER departure_incidents_outbox
    AFTER INSERT OR UPDATE OF cleared_at ON booking.departure_incidents
    FOR EACH ROW EXECUTE FUNCTION booking.departure_incidents_outbox();

-- ── Settings ─────────────────────────────────────────────────────────────────

INSERT INTO booking.settings (key, value, description) VALUES
    ('b2b_on_request_answer_business_days', '1'::jsonb, 'Business days (Mon-Fri, ops time zone) AA ops have to accept or decline an on-request B2B line after the booking is confirmed (AA-975, design Q1 6.2; policy data).'),
    ('b2b_ops_timezone', '"Asia/Ho_Chi_Minh"'::jsonb, 'Time zone of the AA ops desk: business days of the on-request SLA are counted in it (AA-975; policy data).')
ON CONFLICT (key) DO NOTHING;

-- ── Backfill: on-request lines confirmed before bk-022 ───────────────────────

UPDATE booking.b2b_hold_lines l
SET answer_due_at = booking.b2b_answer_due(h.confirmed_at, 1, 'Asia/Ho_Chi_Minh')
FROM booking.b2b_holds h
WHERE h.id = l.hold_id AND h.status = 'confirmed' AND l.status = 'on_request' AND l.answer_due_at IS NULL;

-- ── Grants (per table) ───────────────────────────────────────────────────────

-- outbox: the app reads it, writes rows only through the triggers' columns and stamps feed_seq; never deletes.
-- Table-level INSERT / UPDATE from the schema's default privileges are taken back first (a table-level REVOKE also
-- drops column grants), then the column grants are given again.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON booking.outbox FROM booking;
GRANT SELECT ON booking.outbox TO booking;
GRANT INSERT (stream, event_type, partner_id, hold_id, booking_id, line_ref, departure_id, incident_code, decline_code)
    ON booking.outbox TO booking;
GRANT UPDATE (feed_seq, sequenced_at) ON booking.outbox TO booking;
GRANT USAGE ON SEQUENCE booking.outbox_feed_seq TO booking;

REVOKE UPDATE, DELETE, TRUNCATE ON booking.departure_incidents FROM booking;
GRANT SELECT, INSERT ON booking.departure_incidents TO booking;
GRANT UPDATE (cleared_by, cleared_at) ON booking.departure_incidents TO booking;

GRANT EXECUTE ON FUNCTION booking.b2b_answer_due(TIMESTAMPTZ, INTEGER, TEXT) TO booking;
GRANT EXECUTE ON FUNCTION booking.outbox_departure_event(UUID, TEXT, TEXT) TO booking;
GRANT EXECUTE ON FUNCTION booking.b2b_holds_outbox() TO booking;
GRANT EXECUTE ON FUNCTION booking.b2b_hold_lines_outbox() TO booking;
GRANT EXECUTE ON FUNCTION booking.b2b_cancellations_outbox() TO booking;
GRANT EXECUTE ON FUNCTION booking.departures_outbox() TO booking;
GRANT EXECUTE ON FUNCTION booking.departure_incidents_outbox() TO booking;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-022', now(), 'AA-975 (CRM-B3): shared outbox (+ feed_seq sequence, event triggers on holds, hold lines, cancellations, departures, incidents), departure_incidents, hold-line on-request desk columns, b2b_answer_due(), settings b2b_on_request_answer_business_days, b2b_ops_timezone')
ON CONFLICT (version) DO NOTHING;

COMMIT;
