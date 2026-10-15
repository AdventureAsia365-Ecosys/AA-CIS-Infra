-- Migration bk-009: AA-679 (Booking half, S237 decision D4) — sellable trip plans over the CIS catalog.
--
-- Owner: AA-Booking (key bk-NNN). A byte-identical copy goes to AA-CIS-Infra
-- db/migrations/booking/009_trip_plans.sql and is applied to Dev by the DB Migrate workflow (check, then apply),
-- as aa_cis_admin. Never run it from a laptop.
--
-- Depends on bk-001 (schema, role, set_updated_at) and bk-003 (staff_users) only. It does NOT reference any
-- bk-008 object (suppliers, AA-822, written in parallel on another branch): the trip plan's supplier link is left
-- for a later key, so this file applies with or without bk-008.
--
-- D4 (Linear AA-679, S237): Booking LIVE-READS the CIS catalog views (catalog.v_tour, v_tour_day, v_tour_photo;
-- CIS migration 225, SELECT granted to role booking) and keeps only a COMMERCIAL row per tour. No CIS outbox, no
-- template copy job. So:
--   * booking.trip_plans holds no catalog content: no title, slug, summary, itinerary, days, places or photos
--     (ADR 0002, ADR 0004 O7, UI spec §7 / §8 "ERD content columns are NOT created"). The API joins the row to
--     catalog.v_tour at read time; a tour that leaves the catalog (inactive, trashed, superseded) simply drops out
--     of every list, and its row stays as history.
--   * The key is the CIS catalog key (source_system, source_id) from contract catalog.tour.v1: source_id is the
--     stable CIS tour id (raw_tours.source_group_id), NOT tour_id, which changes on every re-upload. There is no FK
--     across schemas (role booking has SELECT on the catalog views, not REFERENCES): the API checks the source_id
--     against catalog.v_tour before it writes a row.
--   * One row per tour (UNIQUE): marking a tour sellable twice updates the same row. Rows are never deleted (role
--     booking has no DELETE): "not for sale" is sellable = false.
--   * Commercial columns: the sellable flag, a free-text trip style (UI spec Q16 still open), a default sales
--     channel, a price HINT for sales (indicative "from" amount; never a quote: proposals are priced by the
--     pricing engine on cost lines, ADR 0005; the season x pax band matrix trip_plan_prices and booking.v_from_prices
--     come in a later key) and staff-only commercial notes, plus who / when columns.
--   * Commercial columns carry conf:commercial comment tags (data standards DM-6.1). No personal data here.
--
-- Re-running the whole file is a no-op (IF NOT EXISTS / OR REPLACE / idempotent GRANT and REVOKE).

BEGIN;

CREATE TABLE IF NOT EXISTS booking.trip_plans (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_system        TEXT NOT NULL DEFAULT 'cis',
    source_id            TEXT NOT NULL,
    sellable             BOOLEAN NOT NULL DEFAULT false,
    trip_style           TEXT,
    default_channel      TEXT,
    price_hint_amount    NUMERIC(12, 2),
    price_hint_currency  CHAR(3),
    price_hint_basis     TEXT,
    commercial_notes     TEXT,
    created_by           TEXT REFERENCES booking.staff_users (cis_user_id),
    updated_by           TEXT REFERENCES booking.staff_users (cis_user_id),
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT trip_plans_source_uq UNIQUE (source_system, source_id),
    CONSTRAINT trip_plans_source_system_chk CHECK (source_system = 'cis'),
    CONSTRAINT trip_plans_source_id_chk CHECK (length(btrim(source_id)) BETWEEN 1 AND 128),
    CONSTRAINT trip_plans_trip_style_chk CHECK (trip_style IS NULL OR length(btrim(trip_style)) BETWEEN 1 AND 60),
    CONSTRAINT trip_plans_channel_chk CHECK (
        default_channel IS NULL OR default_channel IN ('b2c_tailor_made', 'fixed_departure', 'b2b')),
    CONSTRAINT trip_plans_price_hint_chk CHECK (
        (price_hint_amount IS NULL AND price_hint_currency IS NULL AND price_hint_basis IS NULL)
        OR (price_hint_amount IS NOT NULL AND price_hint_currency IS NOT NULL AND price_hint_basis IS NOT NULL
            AND price_hint_amount > 0 AND price_hint_currency ~ '^[A-Z]{3}$'
            AND price_hint_basis IN ('per_person', 'per_group'))),
    CONSTRAINT trip_plans_notes_chk CHECK (commercial_notes IS NULL OR length(commercial_notes) <= 5000)
);

COMMENT ON TABLE booking.trip_plans IS
    'bk-009 (AA-679, S237 D4): the Booking commercial row of one CIS catalog tour (catalog.v_tour, key source_system + source_id). No catalog content is copied; the API joins catalog.v_tour live. Never deleted: sellable = false.';
COMMENT ON COLUMN booking.trip_plans.source_id IS
    'bk-009: CIS catalog key (contract catalog.tour.v1 source_id = raw_tours.source_group_id), stable across re-uploads. Never the CIS tour_id. Checked against catalog.v_tour by the API (no cross-schema FK).';
COMMENT ON COLUMN booking.trip_plans.sellable IS
    'bk-009: Booking sells this tour (UI spec badge Sellable / Not for sale). Only sellable plans can start a trip case.';
COMMENT ON COLUMN booking.trip_plans.trip_style IS
    'bk-009: free text until the trip style source is decided (UI spec Q16); copied to a trip case created from the plan.';
COMMENT ON COLUMN booking.trip_plans.default_channel IS
    'conf:commercial; bk-009: sales channel suggested for proposals from this plan (pricing_rules.channel values).';
COMMENT ON COLUMN booking.trip_plans.price_hint_amount IS
    'conf:commercial; bk-009: indicative from-price for sales, never a quote (ADR 0005: proposals are priced from cost lines). Replaced by the trip_plan_prices matrix in a later key.';
COMMENT ON COLUMN booking.trip_plans.price_hint_currency IS 'conf:commercial; bk-009: currency of price_hint_amount.';
COMMENT ON COLUMN booking.trip_plans.price_hint_basis IS 'conf:commercial; bk-009: per_person or per_group.';
COMMENT ON COLUMN booking.trip_plans.commercial_notes IS
    'conf:commercial; bk-009: staff-only notes (supplier hints, margins, selling points); never shown to customers.';

CREATE OR REPLACE TRIGGER trip_plans_set_updated_at
    BEFORE UPDATE ON booking.trip_plans
    FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();

CREATE INDEX IF NOT EXISTS trip_plans_sellable_idx
    ON booking.trip_plans (source_id) WHERE sellable;

-- ── Grants ───────────────────────────────────────────────────────────────────
-- Default privileges (bk-001) give role booking full DML on a new table; rows are never deleted, so DELETE and
-- TRUNCATE are revoked. Per-table grants only (no ON ALL TABLES), so the append-only pricing tables of bk-004 /
-- bk-007 stay append-only.

GRANT SELECT, INSERT, UPDATE ON booking.trip_plans TO booking;
REVOKE DELETE, TRUNCATE ON booking.trip_plans FROM booking;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-009', now(), 'AA-679: trip_plans (commercial-only row per CIS catalog tour, keyed on source_system + source_id: sellable, trip style, channel, price hint, notes)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
