-- Migration bk-020: AA-973 (CRM-B2) — fixed departures with capacity, B2B holds with expiry, and the B2B trip case
-- (root ADR 0005a, ADR 0008a decision 3; contract booking.b2b.v1; Booking commercial-core memo seams 1, 2, 4, 9).
--
-- Owner: AA-Booking (key bk-NNN). A byte-identical copy goes to AA-CIS-Infra db/migrations/booking/020_departures_holds.sql
-- and is applied to Dev by the DB Migrate workflow (check, then apply), as bk_owner (the live owner of schema booking
-- since bk-014). Never run it from a laptop.
--
-- Depends on bk-002 (trip_cases), bk-003 (staff_users), bk-005 (settings), bk-009 (trip_plans) and bk-019
-- (b2b_partners, b2b_quotes, b2b_quote_lines). Every grant names its table (no "ON ALL TABLES").
--
-- What it adds (docs/implementation-notes/AA-973.md):
--   * booking.departures: a fixed departure of a sellable trip plan (start date, seat capacity, status
--     scheduled / guaranteed / cancelled, auto_confirm). Held and sold seats are NOT stored: they are counted from the
--     hold lines under a row lock of the departure (app/b2b/departures.py), so they can never drift. Never deleted
--     (cancel instead): SELECT, INSERT, UPDATE.
--   * booking.b2b_holds + booking.b2b_hold_lines: one hold set per (partner, proposal_ref, proposal_version) while it
--     is active or confirmed (unique partial index), idempotent on (partner, Idempotency-Key). A hold has an expiry;
--     the booking.job kind bk_b2b_hold_expire moves due holds to 'expired' (reads already treat an active hold past
--     expires_at as expired). Line status: available / on_request at hold time, then confirmed / declined /
--     cancelled (memo seam 4); held_as keeps the hold-time value. No personal data: seats are counts.
--     extended_count is AA-974's (extend once).
--   * booking.b2b_quote_lines.departure_id: the departure a quote line asked for (bk-019 had no departures yet).
--   * booking.trip_cases: channel ('b2c' default, 'b2b'), party_tenant_id (the agency, soft key); customer_id may be
--     NULL only for channel 'b2b' and must be NULL there (no traveller or customer ever enters Booking for B2B,
--     ADR 0008a decision 3); source_system gains 'crm' (a case opened by POST /booking/b2b/v1/holds/{id}/confirm).
--   * booking.settings row b2b_hold_hours = 48 (hold length; data, not code).
--
-- Locks: trip_cases takes ACCESS EXCLUSIVE for the column adds and the two CHECK swaps (a tiny table on Dev); every
-- step is metadata-only or a short scan. lock_timeout 5s: the apply fails rather than queueing behind the job worker.
-- Re-runnable (the Integration Tests replay every file): IF NOT EXISTS everywhere, DROP CONSTRAINT IF EXISTS before
-- each re-added CHECK, settings row ON CONFLICT DO NOTHING.

BEGIN;

SET LOCAL lock_timeout = '5s';

-- ── Departures ───────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.departures (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    trip_plan_id  UUID NOT NULL REFERENCES booking.trip_plans (id),
    start_date    DATE NOT NULL,
    capacity      INTEGER NOT NULL,
    status        TEXT NOT NULL DEFAULT 'scheduled',
    auto_confirm  BOOLEAN NOT NULL DEFAULT true,
    created_by    TEXT REFERENCES booking.staff_users (cis_user_id),
    updated_by    TEXT REFERENCES booking.staff_users (cis_user_id),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT departures_capacity_chk CHECK (capacity BETWEEN 0 AND 1000),
    CONSTRAINT departures_status_chk CHECK (status IN ('scheduled', 'guaranteed', 'cancelled'))
);

CREATE UNIQUE INDEX IF NOT EXISTS departures_plan_date_uq ON booking.departures (trip_plan_id, start_date);
CREATE INDEX IF NOT EXISTS departures_date_idx ON booking.departures (start_date);

DROP TRIGGER IF EXISTS departures_set_updated_at ON booking.departures;
CREATE TRIGGER departures_set_updated_at
    BEFORE UPDATE ON booking.departures
    FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();

COMMENT ON TABLE booking.departures IS
    'bk-020 (AA-973): a fixed departure of a trip plan with its seat capacity. Held / sold seats are counted from b2b_hold_lines under a row lock of the departure, never stored. Never deleted (status cancelled).';
COMMENT ON COLUMN booking.departures.auto_confirm IS
    'bk-020: true = a held seat on this departure confirms at once on POST /holds/{id}/confirm; false = the line goes on request (ops answer).';

-- ── Holds ────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.b2b_holds (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    partner_id        UUID NOT NULL REFERENCES booking.b2b_partners (id),
    m2m_client_id     TEXT NOT NULL,
    quote_id          UUID NOT NULL REFERENCES booking.b2b_quotes (id),
    proposal_ref      TEXT NOT NULL,
    proposal_version  INTEGER NOT NULL,
    idempotency_key   TEXT NOT NULL,
    status            TEXT NOT NULL DEFAULT 'active',
    expires_at        TIMESTAMPTZ NOT NULL,
    extended_count    SMALLINT NOT NULL DEFAULT 0,
    trip_case_id      UUID REFERENCES booking.trip_cases (id),
    deposit_ref       TEXT,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    confirmed_at      TIMESTAMPTZ,
    released_at       TIMESTAMPTZ,
    expired_at        TIMESTAMPTZ,
    CONSTRAINT b2b_holds_client_chk CHECK (m2m_client_id ~ '^[A-Za-z0-9]{1,128}$'),
    CONSTRAINT b2b_holds_proposal_chk CHECK (length(proposal_ref) BETWEEN 1 AND 64 AND proposal_version >= 1),
    CONSTRAINT b2b_holds_key_chk CHECK (length(idempotency_key) BETWEEN 8 AND 200),
    CONSTRAINT b2b_holds_status_chk CHECK (status IN ('active', 'confirmed', 'expired', 'released')),
    CONSTRAINT b2b_holds_extended_chk CHECK (extended_count BETWEEN 0 AND 1),
    CONSTRAINT b2b_holds_expiry_chk CHECK (expires_at > created_at),
    CONSTRAINT b2b_holds_deposit_chk CHECK (deposit_ref IS NULL OR length(deposit_ref) BETWEEN 1 AND 64),
    CONSTRAINT b2b_holds_confirmed_chk CHECK (
        (status = 'confirmed') = (confirmed_at IS NOT NULL AND trip_case_id IS NOT NULL)),
    CONSTRAINT b2b_holds_released_chk CHECK ((status = 'released') = (released_at IS NOT NULL)),
    CONSTRAINT b2b_holds_expired_chk CHECK ((status = 'expired') = (expired_at IS NOT NULL))
);

-- One hold set per proposal version while it holds or has sold anything (Fix A3); released / expired sets free it.
CREATE UNIQUE INDEX IF NOT EXISTS b2b_holds_proposal_uq
    ON booking.b2b_holds (partner_id, proposal_ref, proposal_version) WHERE status IN ('active', 'confirmed');
CREATE UNIQUE INDEX IF NOT EXISTS b2b_holds_idempotency_uq ON booking.b2b_holds (partner_id, idempotency_key);
CREATE UNIQUE INDEX IF NOT EXISTS b2b_holds_trip_case_uq ON booking.b2b_holds (trip_case_id) WHERE trip_case_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS b2b_holds_due_idx ON booking.b2b_holds (expires_at) WHERE status = 'active';
CREATE INDEX IF NOT EXISTS b2b_holds_quote_idx ON booking.b2b_holds (quote_id);

DROP TRIGGER IF EXISTS b2b_holds_set_updated_at ON booking.b2b_holds;
CREATE TRIGGER b2b_holds_set_updated_at
    BEFORE UPDATE ON booking.b2b_holds
    FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();

COMMENT ON TABLE booking.b2b_holds IS
    'bk-020 (AA-973): a B2B hold set on the lines of one quote (POST /booking/b2b/v1/holds). One active or confirmed set per (partner, proposal_ref, proposal_version). No personal data.';
COMMENT ON COLUMN booking.b2b_holds.idempotency_key IS
    'bk-020: the Idempotency-Key header of the POST /holds that created the hold (unique per partner).';
COMMENT ON COLUMN booking.b2b_holds.expires_at IS
    'bk-020: after this the hold is expired (reads treat it so at once; booking.job bk_b2b_hold_expire writes the status).';
COMMENT ON COLUMN booking.b2b_holds.extended_count IS
    'bk-020: times the hold was extended (at most once, POST /holds/{id}/extend, AA-974).';
COMMENT ON COLUMN booking.b2b_holds.trip_case_id IS
    'bk-020: the B2B trip case opened when the hold was confirmed (the contract booking_id).';
COMMENT ON COLUMN booking.b2b_holds.deposit_ref IS
    'bk-020: the CRM''s payment id given on confirm (opaque; no card or bank data).';

CREATE TABLE IF NOT EXISTS booking.b2b_hold_lines (
    hold_id       UUID NOT NULL REFERENCES booking.b2b_holds (id),
    line_no       SMALLINT NOT NULL,
    line_ref      TEXT NOT NULL,
    departure_id  UUID REFERENCES booking.departures (id),
    seats         SMALLINT NOT NULL,
    held_as       TEXT NOT NULL,
    status        TEXT NOT NULL,
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (hold_id, line_no),
    CONSTRAINT b2b_hold_lines_no_chk CHECK (line_no BETWEEN 1 AND 200),
    CONSTRAINT b2b_hold_lines_ref_chk CHECK (length(line_ref) BETWEEN 1 AND 64),
    CONSTRAINT b2b_hold_lines_seats_chk CHECK (seats BETWEEN 0 AND 120),
    CONSTRAINT b2b_hold_lines_held_as_chk CHECK (held_as IN ('available', 'on_request')),
    CONSTRAINT b2b_hold_lines_status_chk CHECK (
        status IN ('available', 'on_request', 'confirmed', 'declined', 'cancelled'))
);

CREATE UNIQUE INDEX IF NOT EXISTS b2b_hold_lines_ref_uq ON booking.b2b_hold_lines (hold_id, line_ref);
CREATE INDEX IF NOT EXISTS b2b_hold_lines_departure_idx
    ON booking.b2b_hold_lines (departure_id) WHERE departure_id IS NOT NULL;

DROP TRIGGER IF EXISTS b2b_hold_lines_set_updated_at ON booking.b2b_hold_lines;
CREATE TRIGGER b2b_hold_lines_set_updated_at
    BEFORE UPDATE ON booking.b2b_hold_lines
    FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();

COMMENT ON TABLE booking.b2b_hold_lines IS
    'bk-020 (AA-973): the lines of a B2B hold (one per quote line). Seats are counts (adults + children), never people.';
COMMENT ON COLUMN booking.b2b_hold_lines.seats IS
    'bk-020: seats this line takes on its departure (adults + children; infants take no seat); 0 without a departure.';
COMMENT ON COLUMN booking.b2b_hold_lines.held_as IS
    'bk-020: the availability the line was held at (contract HoldLine.line_status); never changes.';
COMMENT ON COLUMN booking.b2b_hold_lines.status IS
    'bk-020: available / on_request while held; confirmed / on_request after confirm; declined / cancelled later (AA-974, AA-975).';

-- ── Quote lines: the departure asked for ─────────────────────────────────────

ALTER TABLE booking.b2b_quote_lines
    ADD COLUMN IF NOT EXISTS departure_id UUID REFERENCES booking.departures (id);

COMMENT ON COLUMN booking.b2b_quote_lines.departure_id IS
    'bk-020 (AA-973): the fixed departure the line asked for (a tp: line), NULL otherwise.';

-- ── B2B trip case (memo seam 2) ──────────────────────────────────────────────

ALTER TABLE booking.trip_cases
    ADD COLUMN IF NOT EXISTS channel TEXT NOT NULL DEFAULT 'b2c',
    ADD COLUMN IF NOT EXISTS party_tenant_id UUID;

ALTER TABLE booking.trip_cases ALTER COLUMN customer_id DROP NOT NULL;

ALTER TABLE booking.trip_cases DROP CONSTRAINT IF EXISTS trip_cases_channel_chk;
ALTER TABLE booking.trip_cases ADD CONSTRAINT trip_cases_channel_chk CHECK (
    (channel = 'b2c' AND customer_id IS NOT NULL AND party_tenant_id IS NULL)
    OR (channel = 'b2b' AND customer_id IS NULL AND party_tenant_id IS NOT NULL));

ALTER TABLE booking.trip_cases DROP CONSTRAINT IF EXISTS trip_cases_source_system_chk;
ALTER TABLE booking.trip_cases ADD CONSTRAINT trip_cases_source_system_chk CHECK (
    source_system IN ('cis', 'tripplanner', 'manual', 'crm'));

CREATE INDEX IF NOT EXISTS trip_cases_party_idx
    ON booking.trip_cases (party_tenant_id, created_at DESC) WHERE party_tenant_id IS NOT NULL;

COMMENT ON COLUMN booking.trip_cases.channel IS
    'bk-020 (AA-973): b2c (a customer''s case) or b2b (an agency booking from booking.b2b.v1: no customer, party_tenant_id set).';
COMMENT ON COLUMN booking.trip_cases.party_tenant_id IS
    'bk-020: for channel b2b, the agency''s CIS tenant id (soft key, booking.b2b_partners.tenant_id); NULL for b2c.';

-- ── Settings ─────────────────────────────────────────────────────────────────

INSERT INTO booking.settings (key, value, description) VALUES
    ('b2b_hold_hours', '48'::jsonb, 'Length of a B2B hold (booking.b2b.v1 POST /holds) in hours, capped by the departure start (AA-973; policy data).')
ON CONFLICT (key) DO NOTHING;

-- ── Grants (per table) ───────────────────────────────────────────────────────

GRANT SELECT, INSERT, UPDATE ON booking.departures TO booking;
GRANT SELECT, INSERT, UPDATE ON booking.b2b_holds TO booking;
GRANT SELECT, INSERT, UPDATE ON booking.b2b_hold_lines TO booking;

-- The schema's default privileges may have granted more on creation: take back what the app must not do.
REVOKE DELETE, TRUNCATE ON booking.departures FROM booking;
REVOKE DELETE, TRUNCATE ON booking.b2b_holds FROM booking;
REVOKE DELETE, TRUNCATE ON booking.b2b_hold_lines FROM booking;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-020', now(), 'AA-973 (CRM-B2): departures, b2b_holds + lines, quote line departure_id, B2B trip case (channel, party_tenant_id, customer_id NULL for b2b, source crm), setting b2b_hold_hours')
ON CONFLICT (version) DO NOTHING;

COMMIT;
