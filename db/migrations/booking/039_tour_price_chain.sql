-- Migration bk-039: AA-1029 R4 — the tour price chain: CIS master tour -> Booking trip plan -> cost sheet from the
-- supplier rates in force -> the public "from" price (contract price.from.v1) for TripPlanner, with dated price
-- history (root ADR 0005 decisions 3, 6, 7; amended by root ADR 0019 b15: the "from" price is the suggested retail
-- price, RRP = the agency net price + 25 %, kept as policy data on the b2b pricing rule).
--
-- Owner: AA-Booking (key bk-NNN). AA-CIS-Infra Migration Sync copies it byte for byte to
-- db/migrations/booking/039_tour_price_chain.sql; on Dev it is applied as bk_owner (the live owner of schema booking
-- since bk-014) by Infra Migration Apply once every job table is idle (root ADR 0017a), or by a person with DB Migrate
-- apply. Never run it from a laptop.
--
-- What:
--   1. booking.pricing_rules.rrp_markup_pct (b2b rows only): the RRP markup on the agency net price, policy data
--      (0.2500 = net + 25 %, b15). Rules stay append-only; a new markup is a new dated rule row, approved by a second
--      person like every rule (bk-007).
--   2. booking.trip_plans: synced_at (the bk_trip_plan_sync bridge created or last matched the row from
--      catalog.v_tour; NULL = a plan staff created first) and the reviewed reference price kept from the CIS source
--      text (reference_price_raw as read, the parsed reference_amount / reference_currency, reviewed by / at). The
--      reference is never a selling price and never reaches price.from.v1 (ADR 0005 d7).
--   3. booking.trip_plan_prices: computed (the cost sheet job bk_price_recompute wrote the row from the plan's
--      components and the rates in force; hand rows are NOT computed, or computed and overridden, and a recompute
--      keeps them) and rrp_amount (b2b rows: the suggested retail price per person = round up(amount x (1 +
--      rrp_markup_pct)), the price.from.v1 amount).
--   4. booking.trip_plan_price_history: the dated price list. Every change of a plan's matrix (staff PUT or a
--      recompute) closes the open rows (effective_to = now()) and inserts the new set (effective_from = now()), so
--      "the price on day X" is a plain range read. Append-only for role booking except effective_to (column grant).
--      DM-7.1 row: root docs/architecture/data-standards/02-data-management.md (AA-1029 root PR, merged first).
--      The history goes with its plan (ON DELETE CASCADE): role booking cannot delete a plan, only the owner can.
--   5. booking.v_from_prices (contract price.from.v1, root docs/contracts/price.from.v1.md): one row per catalog tour
--      key with a b2b price for 2 travellers still valid: the cheapest RRP (USD first). Keys, the public suggested
--      price and its validity only: never the agency net price, a supplier net or a margin. SELECT to booking and to
--      tripplanner (the TripPlanner tour page, ADR 0005 Consequences "TripPlanner shows from prices only via the
--      Booking view"); USAGE on schema booking to tripplanner (nothing else of booking is granted to it).
--
-- Class: contract, not expand (root ADR 0017 d3): ALTERs and CHECKs on existing tables and a cross-owner grant. So a
-- migration-only PR (MIG-4); the code PR raises readiness to bk-039. On Dev: Infra Migration Apply once every job table
-- is idle (root ADR 0017a). Needs bk-004 (pricing_rules), bk-009 (trip_plans), bk-032 (trip_plan_prices) and the role
-- tripplanner (Infra roles; TripPlanner tp-001).
--
-- Locks: ACCESS EXCLUSIVE on pricing_rules, trip_plans and trip_plan_prices for nullable or constant-default ADD
-- COLUMNs (no rewrite on PostgreSQL 11+) and their CHECKs (a scan of a few rows). lock_timeout 5s. No trigger.
-- Re-runnable (the integration tests replay every file): IF NOT EXISTS, DROP CONSTRAINT IF EXISTS before each ADD,
-- CREATE OR REPLACE VIEW with the same columns, grants repeat, ON CONFLICT DO NOTHING.
-- Undo (a later bk- file, after the code is reverted): DROP VIEW booking.v_from_prices; DROP TABLE
-- booking.trip_plan_price_history; ALTER TABLE ... DROP COLUMN for the columns above; REVOKE USAGE ON SCHEMA booking
-- FROM tripplanner.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF current_user <> 'bk_owner' THEN
        RAISE EXCEPTION 'bk-039: expected to run as bk_owner (live owner of schema booking), running as %', current_user;
    END IF;
    IF to_regclass('booking.pricing_rules') IS NULL OR to_regclass('booking.trip_plans') IS NULL
       OR to_regclass('booking.trip_plan_prices') IS NULL THEN
        RAISE EXCEPTION 'bk-039: needs bk-004 (pricing_rules), bk-009 (trip_plans) and bk-032 (trip_plan_prices)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'tripplanner') THEN
        RAISE EXCEPTION 'bk-039: role tripplanner is missing (AA-CIS-Infra roles, TripPlanner tp-001)';
    END IF;
END $$;

-- ── 1. RRP markup on the b2b rule ────────────────────────────────────────────

ALTER TABLE booking.pricing_rules ADD COLUMN IF NOT EXISTS rrp_markup_pct NUMERIC(6, 4);
ALTER TABLE booking.pricing_rules DROP CONSTRAINT IF EXISTS pricing_rules_rrp_markup_chk;
ALTER TABLE booking.pricing_rules ADD CONSTRAINT pricing_rules_rrp_markup_chk CHECK (
    rrp_markup_pct IS NULL OR (channel = 'b2b' AND rrp_markup_pct >= 0 AND rrp_markup_pct < 10));
COMMENT ON COLUMN booking.pricing_rules.rrp_markup_pct IS
    'conf:commercial; bk-039 (AA-1029, root ADR 0019 b15): b2b rule only, the suggested retail price markup on the agency net price (0.2500 = RRP is net + 25 %). Null = no RRP published under this rule.';

-- ── 2. Trip plan: bridge marker and the reviewed reference price ──────────────

ALTER TABLE booking.trip_plans
    ADD COLUMN IF NOT EXISTS synced_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS reference_price_raw TEXT,
    ADD COLUMN IF NOT EXISTS reference_amount NUMERIC(12, 2),
    ADD COLUMN IF NOT EXISTS reference_currency CHAR(3),
    ADD COLUMN IF NOT EXISTS reference_reviewed_by TEXT,
    ADD COLUMN IF NOT EXISTS reference_reviewed_at TIMESTAMPTZ;
ALTER TABLE booking.trip_plans DROP CONSTRAINT IF EXISTS trip_plans_reference_chk;
ALTER TABLE booking.trip_plans ADD CONSTRAINT trip_plans_reference_chk CHECK (
    (reference_price_raw IS NULL OR length(reference_price_raw) BETWEEN 1 AND 500)
    AND ((reference_amount IS NULL AND reference_currency IS NULL)
         OR (reference_amount IS NOT NULL AND reference_currency IS NOT NULL
             AND reference_amount > 0 AND reference_currency ~ '^[A-Z]{3}$'))
    AND ((reference_reviewed_by IS NULL) = (reference_reviewed_at IS NULL)));
COMMENT ON COLUMN booking.trip_plans.synced_at IS
    'bk-039 (AA-1029): when bk_trip_plan_sync last created or matched the row from catalog.v_tour (every published CIS master tour has a plan); NULL = never synced (a plan staff created).';
COMMENT ON COLUMN booking.trip_plans.reference_price_raw IS
    'conf:commercial; bk-039 (AA-1029, ADR 0005 d7): the free-text source price of the CIS tour as read (raw_tours.price_raw through a CIS contract view). Reference only, never a selling price.';
COMMENT ON COLUMN booking.trip_plans.reference_amount IS
    'conf:commercial; bk-039: the amount parsed from reference_price_raw (per person as written); reference only.';
COMMENT ON COLUMN booking.trip_plans.reference_currency IS 'conf:commercial; bk-039: currency of reference_amount.';
COMMENT ON COLUMN booking.trip_plans.reference_reviewed_by IS
    'bk-039: staff (cis_user_id) who reviewed the reference price; cleared when the CIS source text changes.';
COMMENT ON COLUMN booking.trip_plans.reference_reviewed_at IS 'bk-039: when the reference price was reviewed.';

-- ── 3. Price matrix: computed rows and the RRP ────────────────────────────────

ALTER TABLE booking.trip_plan_prices
    ADD COLUMN IF NOT EXISTS computed BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS rrp_amount NUMERIC(12, 2);
ALTER TABLE booking.trip_plan_prices DROP CONSTRAINT IF EXISTS trip_plan_prices_computed_chk;
ALTER TABLE booking.trip_plan_prices ADD CONSTRAINT trip_plan_prices_computed_chk CHECK (
    NOT computed OR net_amount IS NOT NULL);
ALTER TABLE booking.trip_plan_prices DROP CONSTRAINT IF EXISTS trip_plan_prices_rrp_chk;
ALTER TABLE booking.trip_plan_prices ADD CONSTRAINT trip_plan_prices_rrp_chk CHECK (
    rrp_amount IS NULL OR (channel = 'b2b' AND rrp_amount > 0));
COMMENT ON COLUMN booking.trip_plan_prices.computed IS
    'bk-039 (AA-1029): the cost sheet (bk_price_recompute) wrote the row from the plan components and the supplier rates in force; a recompute replaces it unless overridden. False = a row staff entered.';
COMMENT ON COLUMN booking.trip_plan_prices.rrp_amount IS
    'conf:commercial; bk-039 (AA-1029, root ADR 0019 b15): b2b rows, the suggested retail price per person = amount x (1 + rrp_markup_pct of the b2b rule), rounded up like a selling price. Public through booking.v_from_prices.';

-- ── 4. Dated price history ───────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.trip_plan_price_history (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    trip_plan_id      UUID NOT NULL REFERENCES booking.trip_plans (id) ON DELETE CASCADE,
    channel           TEXT NOT NULL,
    season            TEXT,
    peak              BOOLEAN NOT NULL,
    valid_from        DATE NOT NULL,
    valid_to          DATE NOT NULL,
    pax_min           SMALLINT NOT NULL,
    pax_max           SMALLINT,
    currency          CHAR(3) NOT NULL,
    amount            NUMERIC(12, 2) NOT NULL,
    rrp_amount        NUMERIC(12, 2),
    net_amount        NUMERIC(12, 2),
    net_currency      CHAR(3),
    effective_margin  NUMERIC(12, 4),
    computed          BOOLEAN NOT NULL,
    overridden        BOOLEAN NOT NULL,
    change_source     TEXT NOT NULL,
    changed_by        TEXT NOT NULL,
    effective_from    TIMESTAMPTZ NOT NULL DEFAULT now(),
    effective_to      TIMESTAMPTZ,

    CONSTRAINT trip_plan_price_history_channel_chk CHECK (channel IN ('b2c_tailor_made', 'fixed_departure', 'b2b')),
    CONSTRAINT trip_plan_price_history_source_chk CHECK (change_source IN ('staff', 'cost_sheet')),
    CONSTRAINT trip_plan_price_history_by_chk CHECK (length(btrim(changed_by)) BETWEEN 1 AND 128),
    CONSTRAINT trip_plan_price_history_validity_chk CHECK (valid_to >= valid_from),
    CONSTRAINT trip_plan_price_history_amount_chk CHECK (amount > 0 AND (rrp_amount IS NULL OR rrp_amount > 0)),
    CONSTRAINT trip_plan_price_history_period_chk CHECK (effective_to IS NULL OR effective_to >= effective_from)
);
COMMENT ON TABLE booking.trip_plan_price_history IS
    'bk-039 (AA-1029): dated history of every trip plan price matrix: each change closes the open rows (effective_to) and inserts the new set (effective_from). The price in force at time T = rows with effective_from <= T < coalesce(effective_to, infinity). Append-only except effective_to. DM-7.1 row in the data standards.';
COMMENT ON COLUMN booking.trip_plan_price_history.amount IS 'conf:commercial; bk-039: selling price per person.';
COMMENT ON COLUMN booking.trip_plan_price_history.rrp_amount IS 'conf:commercial; bk-039: suggested retail price per person (b2b).';
COMMENT ON COLUMN booking.trip_plan_price_history.net_amount IS 'conf:commercial; bk-039: net cost per person the row was priced from.';
COMMENT ON COLUMN booking.trip_plan_price_history.net_currency IS 'conf:commercial; bk-039: currency of net_amount.';
COMMENT ON COLUMN booking.trip_plan_price_history.effective_margin IS 'conf:commercial; bk-039: margin of amount over the net cost.';
COMMENT ON COLUMN booking.trip_plan_price_history.change_source IS
    'bk-039: staff (PUT …/prices) or cost_sheet (bk_price_recompute).';
COMMENT ON COLUMN booking.trip_plan_price_history.changed_by IS
    'bk-039: staff cis_user_id, or system:bk_price_recompute.';

CREATE INDEX IF NOT EXISTS trip_plan_price_history_plan_idx
    ON booking.trip_plan_price_history (trip_plan_id, effective_from);
CREATE INDEX IF NOT EXISTS trip_plan_price_history_open_idx
    ON booking.trip_plan_price_history (trip_plan_id) WHERE effective_to IS NULL;

REVOKE ALL ON booking.trip_plan_price_history FROM booking;
GRANT SELECT, INSERT ON booking.trip_plan_price_history TO booking;
GRANT UPDATE (effective_to) ON booking.trip_plan_price_history TO booking;

-- ── 5. Contract view price.from.v1 ───────────────────────────────────────────

CREATE OR REPLACE VIEW booking.v_from_prices AS
SELECT DISTINCT ON (p.source_system, p.source_id)
       p.source_system,
       p.source_id,
       pr.rrp_amount AS amount,
       pr.currency::text AS currency,
       'per_person'::text AS basis,
       2 AS pax,
       pr.season,
       pr.valid_from,
       pr.valid_to,
       'rrp'::text AS price_kind,
       pr.created_at AS priced_at
  FROM booking.trip_plans p
  JOIN booking.trip_plan_prices pr ON pr.trip_plan_id = p.id
 WHERE pr.channel = 'b2b' AND pr.rrp_amount IS NOT NULL
   AND pr.pax_min <= 2 AND (pr.pax_max IS NULL OR pr.pax_max >= 2)
   AND pr.valid_to >= (now() AT TIME ZONE 'UTC')::date
 ORDER BY p.source_system, p.source_id, (pr.currency = 'USD') DESC, pr.rrp_amount, pr.valid_from;
COMMENT ON VIEW booking.v_from_prices IS
    'bk-039 (AA-1029, contract price.from.v1, root ADR 0005 d6 as amended by ADR 0019 b15): per catalog tour key, the public "from" price = the cheapest suggested retail price per person for 2 travellers among the b2b rows still valid (USD first). Never a net, an agency price or a margin. Read by Booking and TripPlanner. Contract v1: columns are only appended.';

REVOKE INSERT, UPDATE, DELETE ON booking.v_from_prices FROM booking;
GRANT SELECT ON booking.v_from_prices TO booking;
GRANT USAGE ON SCHEMA booking TO tripplanner;
GRANT SELECT ON booking.v_from_prices TO tripplanner;

-- ── Closing checks ───────────────────────────────────────────────────────────

DO $$
DECLARE
    cols text;
BEGIN
    IF has_table_privilege('booking', 'booking.trip_plan_price_history', 'DELETE')
       OR has_table_privilege('booking', 'booking.trip_plan_price_history', 'TRUNCATE')
       OR has_column_privilege('booking', 'booking.trip_plan_price_history', 'amount', 'UPDATE') THEN
        RAISE EXCEPTION 'bk-039: role booking can rewrite booking.trip_plan_price_history';
    END IF;
    IF NOT has_column_privilege('booking', 'booking.trip_plan_price_history', 'effective_to', 'UPDATE') THEN
        RAISE EXCEPTION 'bk-039: role booking cannot close a history row (effective_to)';
    END IF;
    IF NOT has_column_privilege('booking', 'booking.trip_plans', 'synced_at', 'INSERT')
       OR NOT has_column_privilege('booking', 'booking.trip_plans', 'reference_reviewed_at', 'UPDATE')
       OR NOT has_column_privilege('booking', 'booking.trip_plan_prices', 'rrp_amount', 'INSERT')
       OR NOT has_column_privilege('booking', 'booking.pricing_rules', 'rrp_markup_pct', 'INSERT') THEN
        RAISE EXCEPTION 'bk-039: role booking cannot write the new columns';
    END IF;
    IF has_table_privilege('booking', 'booking.trip_plan_prices', 'UPDATE')
       OR has_table_privilege('booking', 'booking.pricing_rules', 'UPDATE') THEN
        RAISE EXCEPTION 'bk-039: role booking can edit prices or pricing rules in place';
    END IF;
    IF NOT has_table_privilege('tripplanner', 'booking.v_from_prices', 'SELECT') THEN
        RAISE EXCEPTION 'bk-039: tripplanner cannot read booking.v_from_prices';
    END IF;
    IF has_table_privilege('tripplanner', 'booking.trip_plan_prices', 'SELECT')
       OR has_table_privilege('tripplanner', 'booking.trip_plans', 'SELECT') THEN
        RAISE EXCEPTION 'bk-039: tripplanner can read the price tables behind the view';
    END IF;
    SELECT string_agg(a.attname, ',' ORDER BY a.attnum) INTO cols
      FROM pg_attribute a WHERE a.attrelid = 'booking.v_from_prices'::regclass AND a.attnum > 0 AND NOT a.attisdropped;
    IF cols IS DISTINCT FROM
       'source_system,source_id,amount,currency,basis,pax,season,valid_from,valid_to,price_kind,priced_at' THEN
        RAISE EXCEPTION 'bk-039: booking.v_from_prices columns are %', cols;
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-039', now(), 'AA-1029: tour price chain (b2b RRP markup, trip plan sync marker + reference price, computed / RRP price rows, dated price history, contract view v_from_prices to tripplanner)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
