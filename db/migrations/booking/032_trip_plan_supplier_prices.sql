-- Migration bk-032: AA-996 (Figma audit slice 2, "Trip-plan commercial and list") — the supplier of a trip plan and
-- its price matrix (root ADR 0005 decisions 3 and 6; UI spec §3 /commercial "sellable, supplier, price matrix, trip
-- style", §6.3 GET/PUT /booking/catalog/trip-plans/{source_id}/prices; Figma CREATE / EDIT TEMPLATE Supplier and
-- Pricing cards).
--
-- Owner: AA-Booking (key bk-NNN). A byte-identical copy goes to AA-CIS-Infra
-- db/migrations/booking/032_trip_plan_supplier_prices.sql and is applied to Dev by the DB Migrate workflow (check,
-- then apply), as bk_owner (the live owner of schema booking since bk-014). Never run it from a laptop.
--
-- Depends on bk-003 (staff_users), bk-008 (suppliers) and bk-009 (trip_plans). Every grant names its object.
--
-- What it adds:
--   * booking.trip_plans.supplier_id: the main supplier (ground operator) of the plan, picked from the active
--     suppliers in the commercial drawer. Nullable (no supplier picked yet). bk-009 left the link "for a later key".
--     The table-level UPDATE that bk-009 grants role booking covers the new column.
--   * booking.trip_plan_prices: the published per-person selling price list of a plan, one row per channel ×
--     season / validity × pax band × currency (ADR 0005 decision 6). A row may carry the net cost per person it was
--     priced from (net_amount + net_currency); the API then prices it with app.pricing.service (the same rule, FX
--     and rounding as quote-preview) and keeps the effective margin and the pricing day; an amount sent with it is a
--     sales override (overridden = true, below the floor only with a reason). A row without a net cost
--     is a price entered by hand. The API refuses overlapping rows (same channel and currency, overlapping dates and
--     pax bands), so one day and party size has one price per channel and currency.
--     The set is replaced as a whole by PUT …/prices (delete + insert in one transaction, like
--     trip_plan_components, bk-019); every change writes one audit row with the rows before and after, so the
--     history lives in booking.audit_logs. This is a current-state price list, not a log, event, job, ledger,
--     credential or versioned-history table: no DM-7.1 retention row is needed.
--   Not here: booking.v_from_prices (contract price.from.v1, ADR 0005 decision 6) — it needs its consumers' grants
--   and a contract file, so it is its own key; the B2B parity read keeps the bk-009 price hint until then.
--
-- No triggers (no deferred constraint triggers, X1 lint). Commercial columns carry conf:commercial tags (DM-6.1).
-- Locks: ACCESS EXCLUSIVE on booking.trip_plans for a nullable ADD COLUMN (no rewrite) and SHARE ROW EXCLUSIVE on
-- booking.suppliers for the FK; both tables are small. lock_timeout 5s.
-- Re-runnable (the Integration Tests replay every file): ADD COLUMN IF NOT EXISTS, IF NOT EXISTS, grants repeat.
-- Undo (a later bk- file): DROP TABLE booking.trip_plan_prices; ALTER TABLE booking.trip_plans DROP COLUMN
-- supplier_id.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF current_user <> 'bk_owner' THEN
        RAISE EXCEPTION 'bk-032: expected to run as bk_owner (live owner of schema booking), running as %', current_user;
    END IF;
    IF to_regclass('booking.trip_plans') IS NULL OR to_regclass('booking.suppliers') IS NULL
       OR to_regclass('booking.staff_users') IS NULL THEN
        RAISE EXCEPTION 'bk-032: needs bk-003 (staff_users), bk-008 (suppliers) and bk-009 (trip_plans) first';
    END IF;
END $$;

-- ── Supplier of a plan ───────────────────────────────────────────────────────

ALTER TABLE booking.trip_plans
    ADD COLUMN IF NOT EXISTS supplier_id UUID REFERENCES booking.suppliers (id);

COMMENT ON COLUMN booking.trip_plans.supplier_id IS
    'conf:commercial; bk-032 (AA-996): main supplier (ground operator) of the plan, an active booking.suppliers row when picked. Null = none picked.';

CREATE INDEX IF NOT EXISTS trip_plans_supplier_idx
    ON booking.trip_plans (supplier_id) WHERE supplier_id IS NOT NULL;

-- ── Price matrix ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.trip_plan_prices (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    trip_plan_id      UUID NOT NULL REFERENCES booking.trip_plans (id),
    position          SMALLINT NOT NULL,
    channel           TEXT NOT NULL,
    season            TEXT,
    peak              BOOLEAN NOT NULL DEFAULT false,
    valid_from        DATE NOT NULL,
    valid_to          DATE NOT NULL,
    pax_min           SMALLINT NOT NULL,
    pax_max           SMALLINT,
    currency          CHAR(3) NOT NULL,
    amount            NUMERIC(12, 2) NOT NULL,
    net_amount        NUMERIC(12, 2),
    net_currency      CHAR(3),
    effective_margin  NUMERIC(6, 4),
    priced_on         DATE,
    overridden        BOOLEAN NOT NULL DEFAULT false,
    created_by        TEXT REFERENCES booking.staff_users (cis_user_id),
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT trip_plan_prices_position_uq UNIQUE (trip_plan_id, position),
    CONSTRAINT trip_plan_prices_position_chk CHECK (position BETWEEN 1 AND 200),
    CONSTRAINT trip_plan_prices_channel_chk CHECK (channel IN ('b2c_tailor_made', 'fixed_departure', 'b2b')),
    CONSTRAINT trip_plan_prices_season_chk CHECK (season IS NULL OR length(btrim(season)) BETWEEN 1 AND 80),
    CONSTRAINT trip_plan_prices_validity_chk CHECK (valid_to >= valid_from),
    CONSTRAINT trip_plan_prices_pax_chk CHECK (
        pax_min BETWEEN 1 AND 999 AND (pax_max IS NULL OR (pax_max BETWEEN 1 AND 999 AND pax_max >= pax_min))),
    CONSTRAINT trip_plan_prices_currency_chk CHECK (currency ~ '^[A-Z]{3}$'),
    CONSTRAINT trip_plan_prices_amount_chk CHECK (amount > 0),
    CONSTRAINT trip_plan_prices_net_chk CHECK (
        (net_amount IS NULL AND net_currency IS NULL AND effective_margin IS NULL AND priced_on IS NULL)
        OR (net_amount IS NOT NULL AND net_currency IS NOT NULL AND priced_on IS NOT NULL
            AND net_amount >= 0 AND net_currency ~ '^[A-Z]{3}$')),
    CONSTRAINT trip_plan_prices_override_chk CHECK (NOT overridden OR net_amount IS NOT NULL)
);

COMMENT ON TABLE booking.trip_plan_prices IS
    'bk-032 (AA-996, ADR 0005 d3/d6): the per-person selling price list of a trip plan (channel x season / validity x pax band x currency). Replaced as a set by PUT /booking/catalog/trip-plans/{source_id}/prices (delete + insert, audited); no overlapping rows per channel and currency (checked by the API).';
COMMENT ON COLUMN booking.trip_plan_prices.position IS 'bk-032: row order in the staff price matrix (1-based).';
COMMENT ON COLUMN booking.trip_plan_prices.channel IS
    'bk-032: sales channel of the price (pricing_rules.channel values: b2c_tailor_made, fixed_departure, b2b).';
COMMENT ON COLUMN booking.trip_plan_prices.season IS 'bk-032: season label shown to staff (Low, High, Peak, ...).';
COMMENT ON COLUMN booking.trip_plan_prices.peak IS
    'bk-032: priced with the channel''s peak uplift (pricing_rules.peak_uplift_pts, ADR 0005 d4).';
COMMENT ON COLUMN booking.trip_plan_prices.pax_max IS 'bk-032: top of the pax band; null = and more (11+).';
COMMENT ON COLUMN booking.trip_plan_prices.amount IS
    'conf:commercial; bk-032: selling price per person in currency (tax-inclusive B2C list price, ADR 0005 d10).';
COMMENT ON COLUMN booking.trip_plan_prices.net_amount IS
    'conf:commercial; bk-032: net cost per person the row was priced from, in net_currency. Never leaves Booking (ADR 0005a d2).';
COMMENT ON COLUMN booking.trip_plan_prices.net_currency IS 'conf:commercial; bk-032: currency of net_amount.';
COMMENT ON COLUMN booking.trip_plan_prices.effective_margin IS
    'conf:commercial; bk-032: gross margin of amount over net_amount after the card fee, on priced_on (app.pricing.engine).';
COMMENT ON COLUMN booking.trip_plan_prices.overridden IS
    'bk-032: amount is a sales override of the price computed from net_amount (ADR 0005 d4), not the computed price.';
COMMENT ON COLUMN booking.trip_plan_prices.priced_on IS
    'bk-032: day whose pricing rule and FX rates priced the row (null for a price entered by hand).';

CREATE INDEX IF NOT EXISTS trip_plan_prices_plan_idx
    ON booking.trip_plan_prices (trip_plan_id, channel, currency, valid_from);

-- ── Grants ───────────────────────────────────────────────────────────────────
-- The set is replaced as a whole (SELECT, INSERT, DELETE, as trip_plan_components); a row is never edited in place.

REVOKE ALL ON booking.trip_plan_prices FROM booking;
GRANT SELECT, INSERT, DELETE ON booking.trip_plan_prices TO booking;

DO $$
BEGIN
    IF has_table_privilege('booking', 'booking.trip_plan_prices', 'UPDATE')
       OR has_table_privilege('booking', 'booking.trip_plan_prices', 'TRUNCATE') THEN
        RAISE EXCEPTION 'bk-032: role booking can edit or truncate trip_plan_prices in place';
    END IF;
    IF NOT has_column_privilege('booking', 'booking.trip_plans', 'supplier_id', 'UPDATE')
       OR NOT has_column_privilege('booking', 'booking.trip_plans', 'supplier_id', 'INSERT') THEN
        RAISE EXCEPTION 'bk-032: role booking cannot write booking.trip_plans.supplier_id';
    END IF;
    IF has_table_privilege('booking', 'booking.trip_plans', 'DELETE') THEN
        RAISE EXCEPTION 'bk-032: role booking can delete trip plans';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-032', now(), 'AA-996: trip_plans.supplier_id and trip_plan_prices (per-person price list per channel, season / validity, pax band and currency, replaced as a set and audited)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
