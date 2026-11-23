-- Migration bk-069: AA-1153 part 1 (S289; S285 advisories r2 hotels T8, T9, T10, T11, B7; Jira PR-30) — hotel
-- contracts through DMCs: one hotel with contracts from many suppliers, board basis on tours, contract seasons, hotel
-- child prices, the rate-sheet import log, the hotel's own confirmation number on a supplier booking.
--
-- Owner: AA-Booking (key bk-NNN). AA-CIS-Infra Migration Sync copies it byte for byte to
-- db/migrations/booking/069_hotel_contracts_dmc.sql and Migration Apply applies it on Dev as bk_owner once every job
-- table is idle (root ADR 0017a). Never run it from a laptop.
--
-- Depends on bk-008 (suppliers, supplier_contracts), bk-010 (hotels, hotel_room_types, supplier_rates and the guard
-- supplier_rate_guard), bk-019 (trip_plan_components), bk-026 (supplier_bookings), bk-050 (pricing_policy,
-- pricing_policy_events), bk-060 (supply_restrictions and the guard supply_restriction_guard).
--
-- Why: AA has no contract with a hotel. The chain is hotel -> DMC (AA's supplier) -> AA, so the same hotel is sold to
-- AA by several DMCs, each under its own AA supplier contract. Today a hotel belongs to exactly one supplier
-- (hotels.supplier_id, the unique key (supplier_id, name, place) and the two guards), so a second DMC means a second
-- hotel row, a second CIS description and a second set of photos for the same building.
--
-- What:
--   1. booking.hotel_supplier_links (new): which suppliers (DMCs) sell a hotel to AA, with the DMC's own code for it
--      (supplier_hotel_code, unique per supplier), one preferred DMC per hotel at most (the quote takes the preferred
--      DMC's price first, then the cheapest), status active | inactive (never deleted: rates of a past contract keep
--      their hotel). Backfilled with one active, not preferred row per hotel from hotels.supplier_id; an AFTER INSERT
--      trigger on hotels adds that row for every new hotel, so code that still creates hotels the old way keeps the
--      invariant "the hotel's first supplier is linked". hotels.supplier_id stays (NOT NULL, the supplier that first
--      listed the hotel); dropping it is a later contract step once nothing reads it.
--   2. booking.hotels gains the property-master facts of T10 / T11: external_codes (jsonb object, e.g. a DMC code or
--      a GIATA id later; no paid code is bought), facts_source (dmc_sheet | hotel_website | site_visit),
--      facts_source_supplier_id (the DMC that said it, with dmc_sheet), facts_confirmed_on / facts_confirmed_by (the
--      last confirmation; re-confirmation is due facts_confirmed_on + the pricing policy hotel_facts_reconfirm_days).
--      None of them is a supply.hotel.v1 fact, so the bk-023 trigger does not bump supply_version (CIS sees nothing).
--   3. booking.hotel_room_type_aliases (new): the names a DMC uses for an AA room type ("Deluxe City View" for
--      "Deluxe"), optionally per supplier; the rate-sheet importer matches them after the AA name.
--   4. booking.supplier_contract_seasons (new): the named seasons of a supplier contract (Low 2027-05-01..2027-09-30;
--      one season may have several ranges). A rate keeps its season label and its own dates (per-night pricing reads
--      the rate dates); the importer expands a season label into one rate per range and checks gaps and overlaps.
--      Written while the contract is a draft only (like rates).
--   5. booking.hotel_child_policies (new, T12 for hotels): the child price a DMC gives AA for a hotel under one
--      contract: age band, basis sharing | extra_bed, optional board, net per night in the contract currency (one
--      price per contract, hotel, board, basis and band start: a sheet may give a sharing and an extra-bed price for
--      the same band). Two DMCs may give different child prices for one hotel. Written while the contract is a draft only; the hotel must
--      be linked to the contract's supplier.
--   6. booking.rate_sheet_imports (new, append-only): one row per rate-sheet import that created a draft contract:
--      file hash and name, row count, the business checks (HB cheaper than BB, season gaps, price jumps) and the diff
--      against the supplier's previous contract as they were at import time. Publishing such a draft asks the second
--      person to acknowledge the checks (the code reads the checks live; this row is the record).
--   7. booking.trip_plan_components.meal_plan: the board basis of a tour's hotel night (RO, BB, HB, FB, AI; NULL = the
--      pricing policy's default board, hotel_default_board, seeded BB). Rooms only (CHECK).
--   8. booking.supplier_bookings.hotel_confirmation_ref: the hotel's own confirmation number the DMC passes on
--      (confirmation_ref stays the DMC's reference); 1..100 characters, editable while the booking lives.
--   9. booking.supplier_rate_guard() and booking.supply_restriction_guard() REPLACED: a room type is accepted under a
--      contract when its hotel has an ACTIVE link to the contract's supplier (was: hotels.supplier_id = the contract's
--      supplier). Every other line of both bodies is the one bk-010 / bk-060 wrote. Every hotel is linked to its
--      hotels.supplier_id by the backfill, so every write the running code makes today is still accepted.
--  10. Seven pricing policy parameters (Pricing > Policy, section hotels, approver group pricing), version 1 made,
--      submitted and approved by the migration ('seed:bk-069', in force from 2026-01-01; the advisory's defaults):
--        hotel_match_block_pct       85    (% name similarity that blocks a new hotel as a duplicate, with distance)
--        hotel_match_block_m         300   (metres)
--        hotel_match_warn_pct        60    (% name similarity that asks "a different hotel?")
--        hotel_match_warn_m          1000  (metres: same place and this close asks too)
--        hotel_facts_reconfirm_days  180   (days after the last confirmation of a hotel's facts)
--        rate_sheet_jump_warn_pct    60    (% rise against the previous contract that the import flags)
--        hotel_default_board         "BB"  (the board a hotel night is priced on when neither the quote line nor the
--                                           tour night names one; one of RO, BB, HB, FB, AI)
--
-- Class: contract (root ADR 0017 d3): columns, CHECKs and a trigger on existing tables, guard functions replaced,
-- config rows. Migration-only PR first (MIG-4); the code PR raises readiness to bk-069. The running code never names
-- a new column or table; the replaced guards accept every row they accepted before (the backfilled links), and the new
-- trigger on hotels only adds the link row the backfill would.
-- Foreign keys of the new tables are ON DELETE CASCADE (SET NULL for the two optional supplier / contract refs): role
-- booking deletes no hotel, supplier or contract, so a cascade only follows an owner clean-up (test fixtures, erasure).
-- DM-6.1: no personal data. Commercial columns are tagged conf:commercial (child net, the import's checks and diff).
-- No free text column (aliases, codes and season names are supply data, never traveller data).
-- DM-7.1: the five new tables have their row in the root data standards (root PR merged before the Infra copy).
-- Locks: ALTER TABLE on hotels, trip_plan_components, supplier_bookings (constant-free nullable adds; NOT NULL DEFAULT
-- on hotels is a constant default: no rewrite) and the CHECK adds (a short scan of small tables); lock_timeout 5s.
-- Re-runnable (the Integration Tests replay every file): IF NOT EXISTS, DROP CONSTRAINT IF EXISTS, CREATE OR REPLACE,
-- ON CONFLICT DO NOTHING.
-- Number: owner main max + 1 at merge (bk-067 and bk-068 of two other S289 lanes are on main). If it moves,
-- renumber: file name, this header, the registration, the ids (…b6900…) and the tests that name it (git grep '069_'
-- and 'bk-069').
-- Undo (a later bk- file, after the code is reverted): restore the bk-010 / bk-060 guard bodies, DROP the five tables,
-- the trigger hotels_supplier_link and its function, the new columns and their CHECKs, DELETE the seed:bk-069 policy
-- events and versions.

BEGIN;

SET LOCAL lock_timeout = '5s';

-- ── 1. hotel_supplier_links: the DMCs that sell a hotel to AA ────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.hotel_supplier_links (
    hotel_id             uuid NOT NULL REFERENCES booking.hotels (id) ON DELETE CASCADE,
    supplier_id          uuid NOT NULL REFERENCES booking.suppliers (id) ON DELETE CASCADE,
    supplier_hotel_code  text,
    is_preferred         boolean NOT NULL DEFAULT false,
    status               text NOT NULL DEFAULT 'active',
    created_by           text NOT NULL,
    updated_by           text,
    created_at           timestamptz NOT NULL DEFAULT now(),
    updated_at           timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT hotel_supplier_links_pkey PRIMARY KEY (hotel_id, supplier_id),
    CONSTRAINT hotel_supplier_links_status_chk CHECK (status IN ('active', 'inactive')),
    CONSTRAINT hotel_supplier_links_preferred_chk CHECK (NOT is_preferred OR status = 'active'),
    CONSTRAINT hotel_supplier_links_text_chk CHECK (
        (supplier_hotel_code IS NULL OR length(btrim(supplier_hotel_code)) BETWEEN 1 AND 64)
        AND length(btrim(created_by)) BETWEEN 1 AND 128
        AND (updated_by IS NULL OR length(btrim(updated_by)) BETWEEN 1 AND 128))
);

CREATE INDEX IF NOT EXISTS hotel_supplier_links_supplier_idx ON booking.hotel_supplier_links (supplier_id);
CREATE UNIQUE INDEX IF NOT EXISTS hotel_supplier_links_code_uq
    ON booking.hotel_supplier_links (supplier_id, upper(btrim(supplier_hotel_code)))
    WHERE supplier_hotel_code IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS hotel_supplier_links_preferred_uq
    ON booking.hotel_supplier_links (hotel_id) WHERE is_preferred;

COMMENT ON TABLE booking.hotel_supplier_links IS
    'bk-069 (AA-1153, T8): the suppliers (DMCs) that sell a hotel to AA under their own AA supplier contracts; the DMC''s code for the hotel; at most one preferred DMC per hotel. Never deleted (status inactive).';
COMMENT ON COLUMN booking.hotel_supplier_links.supplier_hotel_code IS
    'bk-069: the DMC''s own code for this hotel (rate sheets match it first); unique per supplier.';
COMMENT ON COLUMN booking.hotel_supplier_links.is_preferred IS
    'bk-069: the preferred DMC of the hotel; its price is taken first when several DMCs have one for the same board.';

INSERT INTO booking.hotel_supplier_links (hotel_id, supplier_id, created_by)
SELECT h.id, h.supplier_id, 'seed:bk-069' FROM booking.hotels h
ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION booking.hotels_supplier_link() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    INSERT INTO booking.hotel_supplier_links (hotel_id, supplier_id, created_by)
    VALUES (NEW.id, NEW.supplier_id, coalesce(NULLIF(btrim(NEW.created_by), ''), 'system'))
    ON CONFLICT DO NOTHING;
    RETURN NULL;
END $$;

COMMENT ON FUNCTION booking.hotels_supplier_link() IS
    'bk-069 (AA-1153): a new hotel is linked to the supplier that listed it (hotels.supplier_id), active, not preferred.';

CREATE OR REPLACE TRIGGER hotels_supplier_link
    AFTER INSERT ON booking.hotels
    FOR EACH ROW EXECUTE FUNCTION booking.hotels_supplier_link();

CREATE OR REPLACE TRIGGER hotel_supplier_links_set_updated_at
    BEFORE UPDATE ON booking.hotel_supplier_links
    FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();

-- ── 2. hotels: property-master facts (external codes, source and confirmation of the facts) ─────────────────────

ALTER TABLE booking.hotels
    ADD COLUMN IF NOT EXISTS external_codes jsonb NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS facts_source text,
    ADD COLUMN IF NOT EXISTS facts_source_supplier_id uuid REFERENCES booking.suppliers (id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS facts_confirmed_on date,
    ADD COLUMN IF NOT EXISTS facts_confirmed_by text;

ALTER TABLE booking.hotels DROP CONSTRAINT IF EXISTS hotels_external_codes_chk;
ALTER TABLE booking.hotels ADD CONSTRAINT hotels_external_codes_chk CHECK (
    jsonb_typeof(external_codes) = 'object' AND length(external_codes::text) <= 2000);

ALTER TABLE booking.hotels DROP CONSTRAINT IF EXISTS hotels_facts_chk;
ALTER TABLE booking.hotels ADD CONSTRAINT hotels_facts_chk CHECK (
    (facts_source IS NULL OR facts_source IN ('dmc_sheet', 'hotel_website', 'site_visit'))
    AND (facts_source_supplier_id IS NULL OR facts_source = 'dmc_sheet')
    AND ((facts_confirmed_on IS NULL) = (facts_confirmed_by IS NULL))
    AND (facts_confirmed_on IS NULL OR facts_source IS NOT NULL)
    AND (facts_confirmed_by IS NULL OR length(btrim(facts_confirmed_by)) BETWEEN 1 AND 128));

COMMENT ON COLUMN booking.hotels.external_codes IS
    'bk-069 (AA-1153, T10): codes of this hotel in other systems as {"<system>": "<code>"} (a DMC code, a GIATA id later); not a supply.hotel.v1 fact.';
COMMENT ON COLUMN booking.hotels.facts_source IS
    'bk-069 (T11): where the facts were last confirmed from: dmc_sheet | hotel_website | site_visit.';
COMMENT ON COLUMN booking.hotels.facts_source_supplier_id IS
    'bk-069 (T11): the DMC whose sheet confirmed the facts (dmc_sheet only).';
COMMENT ON COLUMN booking.hotels.facts_confirmed_on IS
    'bk-069 (T11): the day the facts were last confirmed; re-confirmation is due after the pricing policy hotel_facts_reconfirm_days.';
COMMENT ON COLUMN booking.hotels.facts_confirmed_by IS
    'bk-069 (T11): the staff key that confirmed the facts last.';

-- ── 3. hotel_room_type_aliases: the names DMCs use for an AA room type ───────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.hotel_room_type_aliases (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    room_type_id  uuid NOT NULL REFERENCES booking.hotel_room_types (id) ON DELETE CASCADE,
    supplier_id   uuid REFERENCES booking.suppliers (id) ON DELETE CASCADE,
    alias         text NOT NULL,
    created_by    text NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT hotel_room_type_aliases_text_chk CHECK (
        length(btrim(alias)) BETWEEN 1 AND 120 AND length(btrim(created_by)) BETWEEN 1 AND 128)
);

CREATE UNIQUE INDEX IF NOT EXISTS hotel_room_type_aliases_uq
    ON booking.hotel_room_type_aliases (room_type_id, coalesce(supplier_id::text, '-'), lower(btrim(alias)));
CREATE INDEX IF NOT EXISTS hotel_room_type_aliases_supplier_idx
    ON booking.hotel_room_type_aliases (supplier_id) WHERE supplier_id IS NOT NULL;

COMMENT ON TABLE booking.hotel_room_type_aliases IS
    'bk-069 (AA-1153, T8 / T10): another name of an AA room type as a DMC writes it (supplier_id NULL = any DMC); the rate-sheet importer matches it after the AA name.';

-- ── 4. supplier_contract_seasons: the named seasons of a supplier contract ──────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.supplier_contract_seasons (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    supplier_contract_id  uuid NOT NULL REFERENCES booking.supplier_contracts (id) ON DELETE CASCADE,
    name                  text NOT NULL,
    date_from             date NOT NULL,
    date_to               date NOT NULL,
    created_by            text NOT NULL,
    created_at            timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT supplier_contract_seasons_dates_chk CHECK (date_to >= date_from AND date_to - date_from <= 731),
    CONSTRAINT supplier_contract_seasons_text_chk CHECK (
        length(btrim(name)) BETWEEN 1 AND 80 AND length(btrim(created_by)) BETWEEN 1 AND 128)
);

CREATE UNIQUE INDEX IF NOT EXISTS supplier_contract_seasons_uq
    ON booking.supplier_contract_seasons (supplier_contract_id, lower(btrim(name)), date_from);

COMMENT ON TABLE booking.supplier_contract_seasons IS
    'bk-069 (AA-1153, T10): the named season ranges of a supplier contract (one season may have several ranges); written while the contract is a draft only, inside its validity.';

-- ── 5. hotel_child_policies: the child price a DMC gives AA for a hotel ─────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.hotel_child_policies (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    supplier_contract_id  uuid NOT NULL REFERENCES booking.supplier_contracts (id) ON DELETE CASCADE,
    hotel_id              uuid NOT NULL REFERENCES booking.hotels (id) ON DELETE CASCADE,
    age_min               smallint NOT NULL,
    age_max               smallint NOT NULL,
    basis                 text NOT NULL,
    meal_plan             text,
    net_amount            numeric(16,2) NOT NULL,
    created_by            text NOT NULL,
    created_at            timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT hotel_child_policies_age_chk CHECK (age_min BETWEEN 0 AND 17 AND age_max BETWEEN age_min AND 17),
    CONSTRAINT hotel_child_policies_basis_chk CHECK (basis IN ('sharing', 'extra_bed')),
    CONSTRAINT hotel_child_policies_meal_plan_chk CHECK (
        meal_plan IS NULL OR meal_plan IN ('RO', 'BB', 'HB', 'FB', 'AI')),
    CONSTRAINT hotel_child_policies_amount_chk CHECK (net_amount >= 0),
    CONSTRAINT hotel_child_policies_text_chk CHECK (length(btrim(created_by)) BETWEEN 1 AND 128)
);

CREATE UNIQUE INDEX IF NOT EXISTS hotel_child_policies_uq
    ON booking.hotel_child_policies (supplier_contract_id, hotel_id, coalesce(meal_plan, '*'), basis, age_min);
CREATE INDEX IF NOT EXISTS hotel_child_policies_hotel_idx ON booking.hotel_child_policies (hotel_id);

COMMENT ON TABLE booking.hotel_child_policies IS
    'bk-069 (AA-1153, T12 for hotels): the price per night of a child sharing a room or on an extra bed, by age band and optional board, that a DMC gives AA for one hotel under one AA supplier contract. Written while the contract is a draft only.';
COMMENT ON COLUMN booking.hotel_child_policies.net_amount IS
    'conf:commercial; bk-069: net per child per night in the contract currency (0 = free).';

-- Seasons and child prices of a contract follow its rates: written while it is a draft, inside its validity; a child
-- price names a hotel linked (active) to the contract's supplier.
CREATE OR REPLACE FUNCTION booking.supplier_contract_parts_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    k RECORD;
    v_contract uuid;
BEGIN
    v_contract := CASE WHEN TG_OP = 'DELETE' THEN OLD.supplier_contract_id ELSE NEW.supplier_contract_id END;
    IF TG_OP = 'UPDATE' AND NEW.supplier_contract_id IS DISTINCT FROM OLD.supplier_contract_id THEN
        RAISE EXCEPTION 'a row of contract % cannot move to another contract', OLD.supplier_contract_id
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    SELECT c.status, c.supplier_id, c.valid_from, c.valid_to INTO k
    FROM booking.supplier_contracts c WHERE c.id = v_contract FOR SHARE;
    -- A cascade from a removed contract or hotel (only an owner clean-up: role booking deletes neither).
    IF TG_OP = 'DELETE' AND NOT FOUND THEN
        RETURN OLD;
    END IF;
    IF TG_OP = 'DELETE' AND TG_TABLE_NAME = 'hotel_child_policies' THEN
        IF NOT EXISTS (SELECT 1 FROM booking.hotels h WHERE h.id = OLD.hotel_id) THEN
            RETURN OLD;
        END IF;
    END IF;
    IF k.status IS DISTINCT FROM 'draft' THEN
        RAISE EXCEPTION 'the % of a % contract are fixed (contract %)', TG_TABLE_NAME, k.status, v_contract
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    IF TG_TABLE_NAME = 'supplier_contract_seasons' THEN
        IF NEW.date_from < k.valid_from OR (k.valid_to IS NOT NULL AND NEW.date_to > k.valid_to) THEN
            RAISE EXCEPTION 'season dates are outside the contract validity' USING ERRCODE = 'check_violation';
        END IF;
    ELSIF NOT EXISTS (
        SELECT 1 FROM booking.hotel_supplier_links l
        WHERE l.hotel_id = NEW.hotel_id AND l.supplier_id = k.supplier_id AND l.status = 'active') THEN
        RAISE EXCEPTION 'a child price names a hotel linked to the contract''s supplier' USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.supplier_contract_parts_guard() IS
    'bk-069: contract seasons and hotel child prices are written while their contract is a draft only (fixed once published); a season stays inside the contract validity; a child price names a hotel linked to the contract''s supplier.';

CREATE OR REPLACE TRIGGER supplier_contract_seasons_guard
    BEFORE INSERT OR UPDATE OR DELETE ON booking.supplier_contract_seasons
    FOR EACH ROW EXECUTE FUNCTION booking.supplier_contract_parts_guard();

CREATE OR REPLACE TRIGGER hotel_child_policies_guard
    BEFORE INSERT OR UPDATE OR DELETE ON booking.hotel_child_policies
    FOR EACH ROW EXECUTE FUNCTION booking.supplier_contract_parts_guard();

-- ── 6. rate_sheet_imports: the record of every rate-sheet import (append-only) ───────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.rate_sheet_imports (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    supplier_id           uuid NOT NULL REFERENCES booking.suppliers (id) ON DELETE CASCADE,
    supplier_contract_id  uuid NOT NULL REFERENCES booking.supplier_contracts (id) ON DELETE CASCADE,
    previous_contract_id  uuid REFERENCES booking.supplier_contracts (id) ON DELETE SET NULL,
    file_sha256           text NOT NULL,
    file_name             text,
    rate_rows             integer NOT NULL,
    checks                jsonb NOT NULL DEFAULT '[]'::jsonb,
    diff                  jsonb NOT NULL DEFAULT '{}'::jsonb,
    imported_by           text NOT NULL,
    imported_at           timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT rate_sheet_imports_contract_uq UNIQUE (supplier_contract_id),
    CONSTRAINT rate_sheet_imports_sha_chk CHECK (file_sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT rate_sheet_imports_rows_chk CHECK (rate_rows BETWEEN 0 AND 100000),
    CONSTRAINT rate_sheet_imports_json_chk CHECK (
        jsonb_typeof(checks) = 'array' AND jsonb_array_length(checks) <= 500 AND jsonb_typeof(diff) = 'object'),
    CONSTRAINT rate_sheet_imports_text_chk CHECK (
        (file_name IS NULL OR length(btrim(file_name)) BETWEEN 1 AND 200)
        AND length(btrim(imported_by)) BETWEEN 1 AND 128)
);

CREATE INDEX IF NOT EXISTS rate_sheet_imports_supplier_idx ON booking.rate_sheet_imports (supplier_id, imported_at DESC);

COMMENT ON TABLE booking.rate_sheet_imports IS
    'bk-069 (AA-1153, T10): one row per rate-sheet import that made a draft supplier contract: file hash and name, rows, the business checks and the diff against the supplier''s previous contract at import time. Append-only.';
COMMENT ON COLUMN booking.rate_sheet_imports.checks IS
    'conf:commercial; bk-069: [{code, severity, message, ...}] the business checks of the sheet at import time (HB below BB, season gaps and overlaps, price jumps).';
COMMENT ON COLUMN booking.rate_sheet_imports.diff IS
    'conf:commercial; bk-069: {added, changed, removed} rates against the previous published contract of the supplier (nets old and new).';

-- ── 7. trip_plan_components.meal_plan: the board basis of a tour's hotel night ──────────────────────────────────

ALTER TABLE booking.trip_plan_components ADD COLUMN IF NOT EXISTS meal_plan text;

ALTER TABLE booking.trip_plan_components DROP CONSTRAINT IF EXISTS trip_plan_components_meal_plan_chk;
ALTER TABLE booking.trip_plan_components ADD CONSTRAINT trip_plan_components_meal_plan_chk CHECK (
    meal_plan IS NULL OR (hotel_room_type_id IS NOT NULL AND meal_plan IN ('RO', 'BB', 'HB', 'FB', 'AI')));

COMMENT ON COLUMN booking.trip_plan_components.meal_plan IS
    'bk-069 (AA-1153, T9): the board basis of this hotel night (RO, BB, HB, FB, AI); NULL = the pricing policy default board (hotel_default_board, seeded BB). A quote line may ask another.';

-- ── 8. supplier_bookings.hotel_confirmation_ref: the hotel's own confirmation number ────────────────────────────

ALTER TABLE booking.supplier_bookings ADD COLUMN IF NOT EXISTS hotel_confirmation_ref text;

ALTER TABLE booking.supplier_bookings DROP CONSTRAINT IF EXISTS supplier_bookings_hotel_ref_chk;
ALTER TABLE booking.supplier_bookings ADD CONSTRAINT supplier_bookings_hotel_ref_chk CHECK (
    hotel_confirmation_ref IS NULL OR length(btrim(hotel_confirmation_ref)) BETWEEN 1 AND 100);

COMMENT ON COLUMN booking.supplier_bookings.hotel_confirmation_ref IS
    'bk-069 (AA-1153, T11): the hotel''s own confirmation number the DMC passes on (travellers check in with it); confirmation_ref stays the DMC''s reference.';

-- ── 9. The two guards: a room type of a hotel linked to the contract's supplier ─────────────────────────────────

CREATE OR REPLACE FUNCTION booking.supplier_rate_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    k RECORD;
    v_supplier UUID;
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        SELECT c.status INTO k FROM booking.supplier_contracts c WHERE c.id = OLD.supplier_contract_id FOR SHARE;
        IF k.status IS DISTINCT FROM 'draft' THEN
            RAISE EXCEPTION 'rate % belongs to a % contract and is fixed', OLD.id, k.status
                USING ERRCODE = 'object_not_in_prerequisite_state';
        END IF;
        IF TG_OP = 'DELETE' THEN
            RETURN OLD;
        END IF;
    END IF;
    SELECT c.status, c.supplier_id, c.currency, c.valid_from, c.valid_to INTO k
    FROM booking.supplier_contracts c WHERE c.id = NEW.supplier_contract_id FOR SHARE;
    IF k.status IS DISTINCT FROM 'draft' THEN
        RAISE EXCEPTION 'rates are added to a draft contract only (contract % is %)', NEW.supplier_contract_id, k.status
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    IF NEW.hotel_room_type_id IS NOT NULL THEN
        -- bk-069 (T8): a room type of any hotel with an active link to the contract's supplier (DMC).
        SELECT l.supplier_id INTO v_supplier
        FROM booking.hotel_room_types r
        JOIN booking.hotel_supplier_links l ON l.hotel_id = r.hotel_id AND l.status = 'active'
        WHERE r.id = NEW.hotel_room_type_id AND l.supplier_id = k.supplier_id;
    ELSE
        SELECT s.supplier_id INTO v_supplier FROM booking.services s WHERE s.id = NEW.service_id;
    END IF;
    IF v_supplier IS DISTINCT FROM k.supplier_id THEN
        RAISE EXCEPTION 'rate % prices a room type or service of another supplier than its contract', NEW.id
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.currency <> k.currency THEN
        RAISE EXCEPTION 'rate currency % differs from the contract currency %', NEW.currency, k.currency
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.valid_from < k.valid_from
       OR (k.valid_to IS NOT NULL AND (NEW.valid_to IS NULL OR NEW.valid_to > k.valid_to)) THEN
        RAISE EXCEPTION 'rate validity is outside the contract validity'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION booking.supply_restriction_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    k RECORD;
    v_supplier uuid;
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.inventory_kind = 'stop_sale' THEN
            RAISE EXCEPTION 'stop-sale % is never deleted (withdraw, reject or end it)', OLD.id
                USING ERRCODE = 'object_not_in_prerequisite_state';
        END IF;
        SELECT c.status INTO k FROM booking.supplier_contracts c WHERE c.id = OLD.supplier_contract_id FOR SHARE;
        IF k.status IS DISTINCT FROM 'draft' THEN
            RAISE EXCEPTION 'restriction % belongs to a % contract and is fixed', OLD.id, k.status
                USING ERRCODE = 'object_not_in_prerequisite_state';
        END IF;
        RETURN OLD;
    END IF;
    -- Erasure (DM-6.7): note and the three reason columns may be set to the fixed marker '[redacted]' on any row
    -- (closed stop-sale or term of a published contract), with nothing else changed but updated_by / updated_at. It
    -- runs as bk_owner in a reviewed run-script (the DSAR erasure runbook); triggers fire for bk_owner too.
    IF TG_OP = 'UPDATE'
       AND (to_jsonb(NEW) - 'note' - 'reject_reason' - 'withdraw_reason' - 'end_reason' - 'updated_by' - 'updated_at')
           = (to_jsonb(OLD) - 'note' - 'reject_reason' - 'withdraw_reason' - 'end_reason' - 'updated_by' - 'updated_at')
       AND (NEW.note IS NOT DISTINCT FROM OLD.note OR (OLD.note IS NOT NULL AND NEW.note = '[redacted]'))
       AND (NEW.reject_reason IS NOT DISTINCT FROM OLD.reject_reason
            OR (OLD.reject_reason IS NOT NULL AND NEW.reject_reason = '[redacted]'))
       AND (NEW.withdraw_reason IS NOT DISTINCT FROM OLD.withdraw_reason
            OR (OLD.withdraw_reason IS NOT NULL AND NEW.withdraw_reason = '[redacted]'))
       AND (NEW.end_reason IS NOT DISTINCT FROM OLD.end_reason
            OR (OLD.end_reason IS NOT NULL AND NEW.end_reason = '[redacted]'))
       AND (NEW.note, NEW.reject_reason, NEW.withdraw_reason, NEW.end_reason)
           IS DISTINCT FROM (OLD.note, OLD.reject_reason, OLD.withdraw_reason, OLD.end_reason) THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'UPDATE' AND OLD.inventory_kind = 'stop_sale' THEN
        -- A stop-sale's facts are fixed; only its decision and its end move (CHECKs keep the people apart).
        IF (NEW.supplier_contract_id, NEW.hotel_room_type_id, NEW.service_id, NEW.inventory_kind, NEW.date_from,
            NEW.date_to, NEW.note, NEW.created_by, NEW.created_at)
           IS DISTINCT FROM
           (OLD.supplier_contract_id, OLD.hotel_room_type_id, OLD.service_id, OLD.inventory_kind, OLD.date_from,
            OLD.date_to, OLD.note, OLD.created_by, OLD.created_at) THEN
            RAISE EXCEPTION 'stop-sale % keeps its facts; enter a new one instead', OLD.id
                USING ERRCODE = 'object_not_in_prerequisite_state';
        END IF;
        IF OLD.status IN ('rejected', 'withdrawn') OR OLD.ended_by IS NOT NULL THEN
            RAISE EXCEPTION 'stop-sale % is closed (%)', OLD.id, OLD.status
                USING ERRCODE = 'object_not_in_prerequisite_state';
        END IF;
        IF OLD.status = 'approved' AND NEW.status IS DISTINCT FROM 'approved' THEN
            RAISE EXCEPTION 'an approved stop-sale % ends through an end request, never a new status', OLD.id
                USING ERRCODE = 'object_not_in_prerequisite_state';
        END IF;
        IF OLD.status = 'approved' AND (NEW.decided_by, NEW.decided_at) IS DISTINCT FROM (OLD.decided_by, OLD.decided_at) THEN
            RAISE EXCEPTION 'the approval of stop-sale % is fixed', OLD.id
                USING ERRCODE = 'object_not_in_prerequisite_state';
        END IF;
        RETURN NEW;
    END IF;
    IF TG_OP = 'UPDATE' AND NEW.inventory_kind IS DISTINCT FROM OLD.inventory_kind
       AND 'stop_sale' IN (NEW.inventory_kind, OLD.inventory_kind) THEN
        RAISE EXCEPTION 'a contract restriction never becomes a stop-sale (or back)'
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    IF TG_OP = 'UPDATE' AND NEW.supplier_contract_id IS DISTINCT FROM OLD.supplier_contract_id THEN
        RAISE EXCEPTION 'restriction % cannot move to another contract', OLD.id
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    SELECT c.status, c.supplier_id, c.valid_from, c.valid_to INTO k
    FROM booking.supplier_contracts c WHERE c.id = NEW.supplier_contract_id FOR SHARE;
    IF NEW.inventory_kind = 'stop_sale' THEN
        IF k.status IS DISTINCT FROM 'published' THEN
            RAISE EXCEPTION 'a stop-sale applies to a published contract (contract % is %)', NEW.supplier_contract_id,
                k.status USING ERRCODE = 'object_not_in_prerequisite_state';
        END IF;
        IF NEW.status <> 'pending' THEN
            RAISE EXCEPTION 'a new stop-sale starts pending (in effect at once, a second person reviews it)'
                USING ERRCODE = 'check_violation';
        END IF;
    ELSIF k.status IS DISTINCT FROM 'draft' THEN
        RAISE EXCEPTION 'allotment, free-sale and on-request terms are written under a draft contract only (contract % is %)',
            NEW.supplier_contract_id, k.status USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    IF NEW.hotel_room_type_id IS NOT NULL THEN
        -- bk-069 (T8): a room type of any hotel with an active link to the contract's supplier (DMC).
        SELECT l.supplier_id INTO v_supplier
        FROM booking.hotel_room_types r
        JOIN booking.hotel_supplier_links l ON l.hotel_id = r.hotel_id AND l.status = 'active'
        WHERE r.id = NEW.hotel_room_type_id AND l.supplier_id = k.supplier_id;
    ELSE
        SELECT s.supplier_id INTO v_supplier FROM booking.services s WHERE s.id = NEW.service_id;
    END IF;
    IF v_supplier IS DISTINCT FROM k.supplier_id THEN
        RAISE EXCEPTION 'a restriction names a room type or service of its contract''s own supplier'
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.date_from < k.valid_from OR (k.valid_to IS NOT NULL AND NEW.date_to > k.valid_to) THEN
        RAISE EXCEPTION 'restriction dates are outside the contract validity'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.supplier_rate_guard() IS
    'bk-010, bk-069: rates are written under a draft contract only (fixed once published), in its currency, inside its validity, for a service of its supplier or a room type of a hotel with an active link to its supplier.';
COMMENT ON FUNCTION booking.supply_restriction_guard() IS
    'bk-060, bk-069: contract restrictions (allotment, free_sale, on_request) are written under a draft contract only; a stop-sale is entered pending on a published contract, keeps its facts, is never deleted; both name a service of the contract''s supplier or a room type of a hotel linked to it, inside its validity. Erasure (DM-6.7): note, reject_reason, withdraw_reason and end_reason may be set to ''[redacted]'' on any row with nothing else changed (bk_owner, reviewed run-script).';

-- ── 10. Pricing policy: the hotel matching, re-confirmation and rate-sheet jump thresholds, the default board ─────

INSERT INTO booking.pricing_policy (id, param_key, version_no, value, unit, effective_from, reason, created_by)
VALUES
    ('00000000-0000-4000-8000-0000b6900000', 'hotel_match_block_pct', 1, '85'::jsonb, '%', DATE '2026-01-01',
     'AA-1153: a new hotel whose normalised name is this similar to one nearby is refused as a duplicate.', 'seed:bk-069'),
    ('00000000-0000-4000-8000-0000b6900010', 'hotel_match_block_m', 1, '300'::jsonb, 'metres', DATE '2026-01-01',
     'AA-1153: the distance under which a very similar name is the same hotel.', 'seed:bk-069'),
    ('00000000-0000-4000-8000-0000b6900020', 'hotel_match_warn_pct', 1, '60'::jsonb, '%', DATE '2026-01-01',
     'AA-1153: a new hotel whose name is this similar asks "a different hotel?" with a reason.', 'seed:bk-069'),
    ('00000000-0000-4000-8000-0000b6900030', 'hotel_match_warn_m', 1, '1000'::jsonb, 'metres', DATE '2026-01-01',
     'AA-1153: a hotel at the same place and this close asks "a different hotel?" too.', 'seed:bk-069'),
    ('00000000-0000-4000-8000-0000b6900040', 'hotel_facts_reconfirm_days', 1, '180'::jsonb, 'days', DATE '2026-01-01',
     'AA-1153: the facts of a hotel are confirmed again this many days after the last confirmation.', 'seed:bk-069'),
    ('00000000-0000-4000-8000-0000b6900050', 'rate_sheet_jump_warn_pct', 1, '60'::jsonb, '%', DATE '2026-01-01',
     'AA-1153: a rate-sheet price this much above the previous contract''s is flagged before approval.', 'seed:bk-069'),
    ('00000000-0000-4000-8000-0000b6900060', 'hotel_default_board', 1, '"BB"'::jsonb, NULL, DATE '2026-01-01',
     'AA-1153 (T9): a hotel night is priced on this board when neither the quote line nor the tour night names one.',
     'seed:bk-069')
ON CONFLICT DO NOTHING;

INSERT INTO booking.pricing_policy_events (id, policy_id, maker, event, actor)
SELECT (substr(p.id::text, 1, 35) || '1')::uuid, p.id, p.created_by, 'submitted', p.created_by
FROM booking.pricing_policy p
WHERE p.created_by = 'seed:bk-069' AND p.version_no = 1
ON CONFLICT DO NOTHING;

INSERT INTO booking.pricing_policy_events (id, policy_id, maker, event, actor)
SELECT (substr(p.id::text, 1, 35) || '2')::uuid, p.id, p.created_by, 'approved',
       'tech lead S279 (thresholds rule: seeded defaults, S285 hotel advisory)'
FROM booking.pricing_policy p
WHERE p.created_by = 'seed:bk-069' AND p.version_no = 1
ON CONFLICT DO NOTHING;

DO $$
DECLARE
    n integer;
BEGIN
    SELECT count(DISTINCT p.param_key) INTO n
    FROM booking.pricing_policy p
    JOIN booking.pricing_policy_events a ON a.policy_id = p.id AND a.event = 'approved'
    WHERE p.version_no = 1 AND p.param_key IN ('hotel_match_block_pct', 'hotel_match_block_m', 'hotel_match_warn_pct',
                                               'hotel_match_warn_m', 'hotel_facts_reconfirm_days',
                                               'rate_sheet_jump_warn_pct', 'hotel_default_board');
    IF n <> 7 THEN
        RAISE EXCEPTION 'bk-069: % of the 7 seeded hotel parameters have an approved version 1', n;
    END IF;
    IF EXISTS (SELECT 1 FROM booking.hotels h WHERE NOT EXISTS (
        SELECT 1 FROM booking.hotel_supplier_links l WHERE l.hotel_id = h.id AND l.supplier_id = h.supplier_id)) THEN
        RAISE EXCEPTION 'bk-069: a hotel is not linked to its own supplier after the backfill';
    END IF;
END
$$;

-- ── Grants (per object) ─────────────────────────────────────────────────────────────────────────────────────────

-- bk-014 default privileges give role booking every table right on a new table: take them back first.
REVOKE ALL ON booking.hotel_supplier_links, booking.hotel_room_type_aliases, booking.supplier_contract_seasons,
    booking.hotel_child_policies, booking.rate_sheet_imports FROM booking;
GRANT SELECT, INSERT, UPDATE ON booking.hotel_supplier_links TO booking;
GRANT SELECT, INSERT, DELETE ON booking.hotel_room_type_aliases TO booking;
GRANT SELECT, INSERT, DELETE ON booking.supplier_contract_seasons TO booking;
GRANT SELECT, INSERT, DELETE ON booking.hotel_child_policies TO booking;
GRANT SELECT, INSERT ON booking.rate_sheet_imports TO booking;
GRANT EXECUTE ON FUNCTION booking.hotels_supplier_link() TO booking;
GRANT EXECUTE ON FUNCTION booking.supplier_contract_parts_guard() TO booking;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-069', now(), 'AA-1153: hotel contracts through DMCs (supplier links, room type aliases, contract seasons, hotel child prices, rate-sheet import log, board on tour nights, hotel confirmation ref, link-based guards)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
