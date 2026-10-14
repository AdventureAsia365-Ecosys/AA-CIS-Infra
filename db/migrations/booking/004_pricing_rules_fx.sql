-- Migration bk-004: AA-810 — pricing rules, FX rates and per-item net costs (ADR 0005 first cut).
--
-- Owner: AA-Booking (key bk-NNN). A byte-identical copy lives in AA-CIS-Infra
-- db/migrations/booking/004_pricing_rules_fx.sql and is applied to Dev by the DB Migrate workflow
-- (check, then apply), as aa_cis_admin, like bk-001/bk-002. Never run it from a laptop.
--
-- DEPENDS ON bk-003 (AA-681 slice 3), applied first; this file fails on a database without it:
--   * booking.version_item_costs.version_item_id references booking.trip_case_version_itinerary (id
--     UUID, ERD v2 docs/AAA/erd-v2/booking.dbml) and follows its approval lock;
--   * created_by / entered_by reference booking.staff_users (cis_user_id TEXT, ADR 0004 O1: the
--     CIS staff id = staff JWT sub).
--
-- Decisions it implements (root ADR 0005 "Pricing and supplier rates", accepted 14/10/2026):
--   * Decision 4: selling price = net cost / (1 - margin), margin = gross margin on the selling
--     price; card/payment fee (~3%) built into the price; peak season +3 to +5 points; a floor per
--     channel below which a sales override needs a reason. The numbers are policy DATA in
--     booking.pricing_rules ("margin numbers are policy and editable, not code constants").
--   * Decision 5: base currency USD; supplier costs entered in the supplier's currency and
--     converted with DATED FX rates; non-USD selling prices = USD x FX x (1 + buffer).
--   * Decision 2 ("new rates are new rows with new validity — never overwrite"): pricing_rules and
--     fx_rates are append-only for role booking (UPDATE/DELETE revoked). A change is a new row
--     with a later valid_from / as_of; the row in force is the newest one dated on or before the day.
--
-- Not here: supplier contracts and net rate sheets, cost sheets per pax band x season, tax_rules,
-- trip_plan_prices / v_from_prices, FX lock on a sent quote (all later bk-00x per ADR 0005).
--
-- Status-like columns are TEXT + CHECK (same reason as bk-001/bk-002). Ratios are fractions
-- (0.3000 = 30%), NUMERIC(5,4). created_by is NULL for rows written by this migration (seed).
--
-- Re-running the whole file is a no-op (IF NOT EXISTS / OR REPLACE / ON CONFLICT DO NOTHING /
-- idempotent GRANT/REVOKE).

BEGIN;

-- ── Pricing rules (ADR 0005 decision 4) ──────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.pricing_rules (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    channel          TEXT NOT NULL,
    target_margin    NUMERIC(5,4) NOT NULL,
    floor_margin     NUMERIC(5,4) NOT NULL,
    peak_uplift_pts  NUMERIC(5,4) NOT NULL DEFAULT 0,
    card_fee_pct     NUMERIC(5,4) NOT NULL DEFAULT 0,
    valid_from       DATE NOT NULL,
    note             TEXT,
    created_by       TEXT REFERENCES booking.staff_users (cis_user_id),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT pricing_rules_channel_valid_from_uq UNIQUE (channel, valid_from),
    CONSTRAINT pricing_rules_channel_chk CHECK (channel IN ('b2c_tailor_made', 'fixed_departure', 'b2b')),
    CONSTRAINT pricing_rules_ratios_chk CHECK (
        target_margin >= 0 AND target_margin < 1
        AND floor_margin >= 0 AND floor_margin <= target_margin
        AND peak_uplift_pts >= 0 AND peak_uplift_pts < 1
        AND card_fee_pct >= 0 AND card_fee_pct < 1),
    CONSTRAINT pricing_rules_divisor_chk CHECK (target_margin + peak_uplift_pts + card_fee_pct < 1)
);

COMMENT ON TABLE booking.pricing_rules IS
    'bk-004 (ADR 0005 d4): margin policy per channel, append-only; the row in force is the newest valid_from <= the pricing day.';
COMMENT ON COLUMN booking.pricing_rules.target_margin IS
    'Gross margin on the selling price (not markup): sell = net / (1 - margin - card_fee). 0.3000 = 30%.';
COMMENT ON COLUMN booking.pricing_rules.floor_margin IS
    'Effective margin below this flags the quote below_floor; a sales override there needs a reason (audited).';
COMMENT ON COLUMN booking.pricing_rules.peak_uplift_pts IS
    'Added to target_margin for peak-season quotes (ADR 0005: +3 to +5 points). 0.0300 = 3 points.';
COMMENT ON COLUMN booking.pricing_rules.card_fee_pct IS
    'Card/payment fee built into the price (ADR 0005: about 3%), a share of the selling price.';

-- ── FX rates (ADR 0005 decision 5) ───────────────────────────────────────────
-- rate_per_usd = units of `currency` per 1 USD (EUR 0.92, VND 25400). USD itself has no row.
-- buffer_pct is applied when `currency` is the SELLING currency (USD x rate x (1 + buffer)); cost
-- conversion to USD uses the plain rate.

CREATE TABLE IF NOT EXISTS booking.fx_rates (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    currency      CHAR(3) NOT NULL,
    rate_per_usd  NUMERIC(18,8) NOT NULL,
    buffer_pct    NUMERIC(5,4) NOT NULL DEFAULT 0,
    as_of         DATE NOT NULL,
    source        TEXT NOT NULL,
    created_by    TEXT REFERENCES booking.staff_users (cis_user_id),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fx_rates_currency_as_of_uq UNIQUE (currency, as_of),
    CONSTRAINT fx_rates_currency_chk CHECK (currency ~ '^[A-Z]{3}$' AND currency <> 'USD'),
    CONSTRAINT fx_rates_rate_chk CHECK (rate_per_usd > 0),
    CONSTRAINT fx_rates_buffer_chk CHECK (buffer_pct >= 0 AND buffer_pct < 1),
    CONSTRAINT fx_rates_source_chk CHECK (length(btrim(source)) > 0)
);

COMMENT ON TABLE booking.fx_rates IS
    'bk-004 (ADR 0005 d5): dated FX rates against USD, append-only; the rate in force is the newest as_of <= the pricing day.';

-- ── Net cost per version item (ADR 0005 decision 4/5 inputs) ─────────────────
-- Staff enter the supplier's net cost of a proposal item in the supplier's currency. One item may
-- carry several cost rows (room + transfer, two suppliers). bk-003 owns the version item table.

CREATE TABLE IF NOT EXISTS booking.version_item_costs (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    version_item_id  UUID NOT NULL REFERENCES booking.trip_case_version_itinerary (id) ON DELETE CASCADE,
    net_amount       NUMERIC(16,2) NOT NULL,
    net_currency     CHAR(3) NOT NULL,
    supplier_note    TEXT,
    entered_by       TEXT REFERENCES booking.staff_users (cis_user_id),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT version_item_costs_amount_chk CHECK (net_amount >= 0),
    CONSTRAINT version_item_costs_currency_chk CHECK (net_currency ~ '^[A-Z]{3}$')
);

COMMENT ON TABLE booking.version_item_costs IS
    'bk-004: supplier net cost lines of a trip case version item (bk-003 trip_case_version_itinerary), in the supplier currency.';

CREATE INDEX IF NOT EXISTS version_item_costs_item_idx
    ON booking.version_item_costs (version_item_id);

CREATE OR REPLACE TRIGGER version_item_costs_set_updated_at
    BEFORE UPDATE ON booking.version_item_costs
    FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();

-- Same lock as bk-003 puts on version items: once a version is approved its price is fixed (ADR 0005
-- context), so its cost rows can no longer be added, changed or removed.
CREATE OR REPLACE FUNCTION booking.version_item_cost_lock() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_item UUID;
BEGIN
    v_item := CASE WHEN TG_OP = 'INSERT' THEN NEW.version_item_id ELSE OLD.version_item_id END;
    IF EXISTS (
           SELECT 1
           FROM booking.trip_case_version_itinerary i
           JOIN booking.trip_case_versions v ON v.id = i.trip_case_version_id
           WHERE i.id = v_item AND v.is_approved)
       OR (TG_OP = 'UPDATE' AND EXISTS (
           SELECT 1
           FROM booking.trip_case_version_itinerary i
           JOIN booking.trip_case_versions v ON v.id = i.trip_case_version_id
           WHERE i.id = NEW.version_item_id AND v.is_approved))
    THEN
        RAISE EXCEPTION 'version item % belongs to an approved, locked version', v_item
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END $$;

CREATE OR REPLACE TRIGGER version_item_costs_lock
    BEFORE INSERT OR UPDATE OR DELETE ON booking.version_item_costs
    FOR EACH ROW EXECUTE FUNCTION booking.version_item_cost_lock();

-- ── Seed: ADR 0005 decision 4 targets ────────────────────────────────────────
-- TO CONFIRM WITH MS. THU before the first price load (ADR 0005 status line: margin numbers are
-- policy data, checked with Ms. Thư). Values are the ADR's table: target / floor 30/20 (B2C
-- tailor-made), 25/18 (fixed departure), 15/10 (B2B). peak_uplift_pts = 0.03 is the low end of the
-- ADR's "+3 to +5 points"; card_fee_pct = 0.03 is the ADR's "~3%" (also on B2B until confirmed).
-- A correction is a NEW row with a later valid_from, never an UPDATE.

INSERT INTO booking.pricing_rules (channel, target_margin, floor_margin, peak_uplift_pts, card_fee_pct, valid_from, note)
VALUES
    ('b2c_tailor_made', 0.3000, 0.2000, 0.0300, 0.0300, DATE '2026-10-14', 'ADR 0005 seed — to confirm with Ms. Thư'),
    ('fixed_departure', 0.2500, 0.1800, 0.0300, 0.0300, DATE '2026-10-14', 'ADR 0005 seed — to confirm with Ms. Thư'),
    ('b2b',             0.1500, 0.1000, 0.0300, 0.0300, DATE '2026-10-14', 'ADR 0005 seed — to confirm with Ms. Thư')
ON CONFLICT (channel, valid_from) DO NOTHING;

-- No FX rows are seeded: rates are market data entered (with their source) by staff.

-- ── Grants ───────────────────────────────────────────────────────────────────
-- Default privileges (bk-001, FOR ROLE aa_cis_admin) already give role booking DML on the new
-- tables; repeated per table so the file stands on its own. No blanket ALL TABLES grant here: it
-- would re-open UPDATE on the append-only tables below if a later file forgot the REVOKE.

GRANT SELECT, INSERT, UPDATE, DELETE ON booking.version_item_costs TO booking;
GRANT SELECT, INSERT ON booking.pricing_rules TO booking;
GRANT SELECT, INSERT ON booking.fx_rates TO booking;
GRANT EXECUTE ON FUNCTION booking.version_item_cost_lock() TO booking;

-- Append-only policy data (ADR 0005 decision 2): role booking may add rows, never rewrite history.
REVOKE UPDATE, DELETE, TRUNCATE ON booking.pricing_rules FROM booking;
REVOKE UPDATE, DELETE, TRUNCATE ON booking.fx_rates FROM booking;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-004', now(), 'AA-810: pricing_rules (ADR 0005 seed 30/20, 25/18, 15/10, append-only), fx_rates (dated, append-only), version_item_costs (FK bk-003 trip_case_version_itinerary, approval lock)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
