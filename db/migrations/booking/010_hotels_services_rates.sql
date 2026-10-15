-- Migration bk-010: AA-823 — Booking wave 2b: hotels, hotel room types, services and supplier net rates
-- (ADR 0004a decision 1, ADR 0005 decisions 2 and 8; S236 UI spec §3, §6.3, §7; Q17).
--
-- Owner: AA-Booking (key bk-NNN). A byte-identical copy goes to AA-CIS-Infra
-- db/migrations/booking/010_hotels_services_rates.sql and is applied to Dev by the DB Migrate workflow (check, then
-- apply), as aa_cis_admin. Never run it from a laptop.
--
-- Depends on bk-001 (schema, role, set_updated_at), bk-003 (staff_users, trip_case_version_itinerary), bk-004
-- (version_item_costs), bk-005 (countries) and bk-008 (suppliers, supplier_contracts). It does NOT reference any
-- bk-009 object (trip_plans, AA-679): bk-010 applies with or without it.
-- Every grant below names its table: no blanket "ON ALL TABLES" grant, which would re-open UPDATE/DELETE on the
-- append-only pricing tables of bk-004 and the no-delete supplier tables of bk-008.
--
-- What it adds (docs/implementation-notes/AA-823.md):
--   * booking.hotels: the supply FACTS of a hotel (ADR 0004a decision 1): code HTL-000123, supplier, name, style,
--     star rating, address, geo point, check-in/out times, amenities, staff links, internal notes, status. The
--     place is a CIS soft key: destination_id is a catalog.v_destination id checked by the API (no FK across
--     schemas: role booking has SELECT on the catalog views, not REFERENCES), and country_code follows it.
--   * booking.hotel_room_types: name, max occupancy, bed types, internal notes, status, per hotel.
--   * booking.services: one table for activity / transfer / guide / entrance / meal (UI spec §6.3), code
--     SVC-000123: supplier, internal title, the pricing unit of its rates, place (destination_id soft key), an
--     optional CIS source reference (source_system 'cis' + source_id, e.g. a catalog component; no FK either),
--     max group size, duration, inclusions, internal notes, status.
--   * NO customer-facing column anywhere here: no description, highlights or photo (ADR 0004a decision 2, O7,
--     Q17 "none in v1"). CIS writes that content later from these facts (supply.hotel.v1 / supply.service.v1 and
--     booking.outbox are a later key, not this one). A schema test asserts the absence.
--   * booking.supplier_rates: net rate rows of a room type or a service UNDER a supplier contract: season label,
--     validity (inside the contract's), unit, meal plan (rooms), pax band, net amount and the contract currency.
--     Maker-checker comes from the contract (ADR 0005 d8): rates are written while their contract is a draft and
--     fixed once a second person publishes it ("never overwrite", ADR 0005 d2; trigger below). Only rates of a
--     published contract are "in force" for quoting.
--   * Version items (bk-003) may reference a hotel room type or a service; a cost line (bk-004) may name the rate
--     it was defaulted from (provenance only: the amount on the line is what prices the version).
--   * Commercial columns carry conf:commercial comment tags (data standards DM-6.1). No personal data here.
--
-- Status columns stay TEXT + CHECK. Hotels, room types and services are never deleted (status active / inactive,
-- role booking has no DELETE). Re-running the whole file is a no-op.
--
-- Known gap (ADR 0004a decision 4): CIS connects as aa_cis_admin, the owner of every booking.* object, so the
-- database does not stop CIS from reading these rates and notes; only the contract, the views and review do,
-- until CIS runs as a non-owner role (AA-817 follow-ups).
--
-- Lock-sensitive existing tables (data standards MIG-9): ALTER TABLE booking.trip_case_version_itinerary and
-- booking.version_item_costs (3 nullable FK columns, 1 CHECK, 3 partial indexes, all small tables), and new triggers on
-- booking.supplier_contracts. Until the DB Migrate runner sets defaults (N5), the file sets its own timeouts.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '15min';

-- ── Hotels ───────────────────────────────────────────────────────────────────

CREATE SEQUENCE IF NOT EXISTS booking.hotel_code_seq;

CREATE TABLE IF NOT EXISTS booking.hotels (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code            TEXT NOT NULL DEFAULT ('HTL-' || lpad(nextval('booking.hotel_code_seq')::text, 6, '0')),
    supplier_id     UUID NOT NULL REFERENCES booking.suppliers (id),
    name            TEXT NOT NULL,
    hotel_style     TEXT,
    star_rating     SMALLINT,
    address         TEXT,
    destination_id  UUID,
    country_code    CHAR(2) REFERENCES booking.countries (iso2),
    latitude        NUMERIC(9,6),
    longitude       NUMERIC(9,6),
    check_in_time   TIME,
    check_out_time  TIME,
    amenities       TEXT[] NOT NULL DEFAULT '{}',
    links           JSONB NOT NULL DEFAULT '[]'::jsonb,
    internal_notes  TEXT,
    status          TEXT NOT NULL DEFAULT 'active',
    created_by      TEXT REFERENCES booking.staff_users (cis_user_id),
    updated_by      TEXT REFERENCES booking.staff_users (cis_user_id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT hotels_code_uq UNIQUE (code),
    CONSTRAINT hotels_name_chk CHECK (length(btrim(name)) BETWEEN 1 AND 200),
    CONSTRAINT hotels_style_chk CHECK (hotel_style IS NULL OR length(hotel_style) BETWEEN 1 AND 60),
    CONSTRAINT hotels_star_chk CHECK (star_rating IS NULL OR star_rating BETWEEN 1 AND 5),
    CONSTRAINT hotels_geo_chk CHECK (
        (latitude IS NULL) = (longitude IS NULL)
        AND (latitude IS NULL OR latitude BETWEEN -90 AND 90)
        AND (longitude IS NULL OR longitude BETWEEN -180 AND 180)),
    CONSTRAINT hotels_amenities_chk CHECK (cardinality(amenities) <= 50),
    CONSTRAINT hotels_links_chk CHECK (jsonb_typeof(links) = 'array' AND jsonb_array_length(links) <= 10),
    CONSTRAINT hotels_status_chk CHECK (status IN ('active', 'inactive'))
);

COMMENT ON TABLE booking.hotels IS
    'bk-010 (AA-823, ADR 0004a d1): hotel supply facts owned by Booking. No customer-facing description or photo (O7, Q17): CIS writes that content. Never deleted: status active / inactive. destination_id is a CIS catalog.v_destination id checked by the API (no cross-schema FK).';
COMMENT ON COLUMN booking.hotels.destination_id IS
    'bk-010: CIS place id (catalog.v_destination.destination_id, golden record shared.destinations). Validated by the API; no FK across schemas.';
COMMENT ON COLUMN booking.hotels.links IS
    'bk-010: staff links [{label, url}] (supplier site, booking extranet, map); not shown to customers.';
COMMENT ON COLUMN booking.hotels.internal_notes IS
    'conf:commercial; bk-010: staff-only notes about the hotel; never shown to customers.';

-- One live record per supplier, hotel name and place (a double submit or a duplicate entry is refused).
CREATE UNIQUE INDEX IF NOT EXISTS hotels_supplier_name_place_uq
    ON booking.hotels (supplier_id, lower(btrim(name)), coalesce(destination_id::text, '-'));
CREATE INDEX IF NOT EXISTS hotels_status_idx ON booking.hotels (status);
CREATE INDEX IF NOT EXISTS hotels_supplier_idx ON booking.hotels (supplier_id);
CREATE INDEX IF NOT EXISTS hotels_country_idx ON booking.hotels (country_code);
CREATE INDEX IF NOT EXISTS hotels_destination_idx ON booking.hotels (destination_id) WHERE destination_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS hotels_updated_idx ON booking.hotels (updated_at DESC);

CREATE OR REPLACE TRIGGER hotels_set_updated_at
    BEFORE UPDATE ON booking.hotels
    FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();

-- ── Hotel room types ─────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.hotel_room_types (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    hotel_id        UUID NOT NULL REFERENCES booking.hotels (id),
    name            TEXT NOT NULL,
    max_occupancy   SMALLINT,
    bed_types       TEXT[] NOT NULL DEFAULT '{}',
    internal_notes  TEXT,
    status          TEXT NOT NULL DEFAULT 'active',
    created_by      TEXT REFERENCES booking.staff_users (cis_user_id),
    updated_by      TEXT REFERENCES booking.staff_users (cis_user_id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT hotel_room_types_name_chk CHECK (length(btrim(name)) BETWEEN 1 AND 120),
    CONSTRAINT hotel_room_types_occupancy_chk CHECK (max_occupancy IS NULL OR max_occupancy BETWEEN 1 AND 20),
    CONSTRAINT hotel_room_types_beds_chk CHECK (cardinality(bed_types) <= 10),
    CONSTRAINT hotel_room_types_status_chk CHECK (status IN ('active', 'inactive'))
);

COMMENT ON TABLE booking.hotel_room_types IS
    'bk-010 (AA-823, ADR 0004a d1): room types of a hotel (name, occupancy, bed types). Rates hang off a room type. Never deleted: status active / inactive.';
COMMENT ON COLUMN booking.hotel_room_types.internal_notes IS
    'conf:commercial; bk-010: staff-only notes on the room type.';

CREATE UNIQUE INDEX IF NOT EXISTS hotel_room_types_name_uq ON booking.hotel_room_types (hotel_id, lower(btrim(name)));

CREATE OR REPLACE TRIGGER hotel_room_types_set_updated_at
    BEFORE UPDATE ON booking.hotel_room_types
    FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();

-- ── Services ─────────────────────────────────────────────────────────────────

CREATE SEQUENCE IF NOT EXISTS booking.service_code_seq;

CREATE TABLE IF NOT EXISTS booking.services (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code              TEXT NOT NULL DEFAULT ('SVC-' || lpad(nextval('booking.service_code_seq')::text, 6, '0')),
    supplier_id       UUID NOT NULL REFERENCES booking.suppliers (id),
    service_type      TEXT NOT NULL,
    title             TEXT NOT NULL,
    unit              TEXT NOT NULL DEFAULT 'person',
    destination_id    UUID,
    country_code      CHAR(2) REFERENCES booking.countries (iso2),
    source_system     TEXT,
    source_id         TEXT,
    max_group_size    SMALLINT,
    duration_minutes  INTEGER,
    inclusions        TEXT[] NOT NULL DEFAULT '{}',
    internal_notes    TEXT,
    status            TEXT NOT NULL DEFAULT 'active',
    created_by        TEXT REFERENCES booking.staff_users (cis_user_id),
    updated_by        TEXT REFERENCES booking.staff_users (cis_user_id),
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT services_code_uq UNIQUE (code),
    CONSTRAINT services_type_chk CHECK (service_type IN ('activity', 'transfer', 'guide', 'entrance', 'meal')),
    CONSTRAINT services_title_chk CHECK (length(btrim(title)) BETWEEN 1 AND 200),
    CONSTRAINT services_unit_chk CHECK (unit IN ('person', 'group', 'vehicle', 'day')),
    CONSTRAINT services_source_chk CHECK (
        (source_system IS NULL AND source_id IS NULL)
        OR (source_system = 'cis' AND source_id IS NOT NULL AND length(source_id) BETWEEN 1 AND 120)),
    CONSTRAINT services_group_chk CHECK (max_group_size IS NULL OR max_group_size BETWEEN 1 AND 999),
    CONSTRAINT services_duration_chk CHECK (duration_minutes IS NULL OR duration_minutes BETWEEN 1 AND 43200),
    CONSTRAINT services_inclusions_chk CHECK (cardinality(inclusions) <= 50),
    CONSTRAINT services_status_chk CHECK (status IN ('active', 'inactive'))
);

COMMENT ON TABLE booking.services IS
    'bk-010 (AA-823, ADR 0004a d1, UI spec §6.3): commercial services (activity, transfer, guide, entrance, meal) at a CIS place. title is INTERNAL; customer-facing text is CIS content (O7). Never deleted: status active / inactive.';
COMMENT ON COLUMN booking.services.title IS
    'bk-010: internal working title for staff (not customer copy, ADR 0002).';
COMMENT ON COLUMN booking.services.unit IS
    'bk-010: pricing unit of the service rates: person, group, vehicle (per transfer) or day (ADR 0005 d8 template).';
COMMENT ON COLUMN booking.services.destination_id IS
    'bk-010: CIS place id (catalog.v_destination.destination_id). Validated by the API; no FK across schemas.';
COMMENT ON COLUMN booking.services.source_id IS
    'bk-010: optional CIS catalog reference (source_system = cis), e.g. a component the service delivers; soft key, no FK.';
COMMENT ON COLUMN booking.services.internal_notes IS
    'conf:commercial; bk-010: staff-only notes about the service; never shown to customers.';

CREATE UNIQUE INDEX IF NOT EXISTS services_supplier_title_place_uq
    ON booking.services (supplier_id, service_type, lower(btrim(title)), coalesce(destination_id::text, '-'));
CREATE INDEX IF NOT EXISTS services_status_idx ON booking.services (status);
CREATE INDEX IF NOT EXISTS services_type_idx ON booking.services (service_type);
CREATE INDEX IF NOT EXISTS services_supplier_idx ON booking.services (supplier_id);
CREATE INDEX IF NOT EXISTS services_country_idx ON booking.services (country_code);
CREATE INDEX IF NOT EXISTS services_destination_idx ON booking.services (destination_id) WHERE destination_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS services_updated_idx ON booking.services (updated_at DESC);

CREATE OR REPLACE TRIGGER services_set_updated_at
    BEFORE UPDATE ON booking.services
    FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();

-- ── Supplier net rates ───────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.supplier_rates (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    supplier_contract_id  UUID NOT NULL REFERENCES booking.supplier_contracts (id),
    hotel_room_type_id    UUID REFERENCES booking.hotel_room_types (id),
    service_id            UUID REFERENCES booking.services (id),
    season                TEXT,
    valid_from            DATE NOT NULL,
    valid_to              DATE,
    unit                  TEXT NOT NULL,
    meal_plan             TEXT,
    pax_min               SMALLINT,
    pax_max               SMALLINT,
    net_amount            NUMERIC(16,2) NOT NULL,
    currency              CHAR(3) NOT NULL,
    notes                 TEXT,
    created_by            TEXT NOT NULL REFERENCES booking.staff_users (cis_user_id),
    updated_by            TEXT REFERENCES booking.staff_users (cis_user_id),
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT supplier_rates_target_chk CHECK (num_nonnulls(hotel_room_type_id, service_id) = 1),
    -- A room rate is per room night; a service rate never is (its unit is the service unit).
    CONSTRAINT supplier_rates_unit_chk CHECK (
        unit IN ('room_night', 'person', 'group', 'vehicle', 'day')
        AND (hotel_room_type_id IS NOT NULL) = (unit = 'room_night')),
    CONSTRAINT supplier_rates_meal_plan_chk CHECK (
        meal_plan IS NULL OR (hotel_room_type_id IS NOT NULL AND meal_plan IN ('RO', 'BB', 'HB', 'FB', 'AI'))),
    CONSTRAINT supplier_rates_season_chk CHECK (season IS NULL OR length(season) BETWEEN 1 AND 80),
    CONSTRAINT supplier_rates_validity_chk CHECK (valid_to IS NULL OR valid_to >= valid_from),
    CONSTRAINT supplier_rates_pax_chk CHECK (
        (pax_min IS NULL OR pax_min BETWEEN 1 AND 999)
        AND (pax_max IS NULL OR pax_max BETWEEN 1 AND 999)
        AND (pax_min IS NULL OR pax_max IS NULL OR pax_max >= pax_min)),
    CONSTRAINT supplier_rates_amount_chk CHECK (net_amount >= 0),
    CONSTRAINT supplier_rates_currency_chk CHECK (currency ~ '^[A-Z]{3}$')
);

COMMENT ON TABLE booking.supplier_rates IS
    'bk-010 (AA-823, ADR 0005 d2/d8): net rate rows of a hotel room type or a service under a supplier contract (season, validity inside the contract, unit, meal plan, pax band, net amount in the contract currency). Written while the contract is a draft; fixed once it is published (maker-checker via the contract). Only rates of a published contract are in force.';
COMMENT ON COLUMN booking.supplier_rates.net_amount IS
    'conf:commercial; bk-010: supplier net price per unit, in the contract currency.';
COMMENT ON COLUMN booking.supplier_rates.notes IS
    'conf:commercial; bk-010: supplements, child policy and other staff-only rate notes.';

CREATE INDEX IF NOT EXISTS supplier_rates_contract_idx ON booking.supplier_rates (supplier_contract_id);
CREATE INDEX IF NOT EXISTS supplier_rates_room_type_idx
    ON booking.supplier_rates (hotel_room_type_id, valid_from DESC) WHERE hotel_room_type_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS supplier_rates_service_idx
    ON booking.supplier_rates (service_id, valid_from DESC) WHERE service_id IS NOT NULL;

CREATE OR REPLACE TRIGGER supplier_rates_set_updated_at
    BEFORE UPDATE ON booking.supplier_rates
    FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();

-- Rates belong to a DRAFT contract while they are written (the contract row is share-locked, so a publish running
-- at the same time waits for this write or makes it fail); they use the contract currency, stay inside the
-- contract validity and price a room type or service of the contract's own supplier. Once the contract is
-- published (by a second person, bk-008) or expired, its rates can no longer be added, changed or removed.
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
        SELECT h.supplier_id INTO v_supplier
        FROM booking.hotel_room_types r JOIN booking.hotels h ON h.id = r.hotel_id
        WHERE r.id = NEW.hotel_room_type_id;
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

COMMENT ON FUNCTION booking.supplier_rate_guard() IS
    'bk-010: rates are written under a draft contract only (fixed once published), in its currency, inside its validity, for its supplier.';

CREATE OR REPLACE TRIGGER supplier_rates_guard
    BEFORE INSERT OR UPDATE OR DELETE ON booking.supplier_rates
    FOR EACH ROW EXECUTE FUNCTION booking.supplier_rate_guard();

-- The other side: a draft contract that already has rates keeps its currency, and its validity may not shrink
-- below a rate's.
CREATE OR REPLACE FUNCTION booking.supplier_contract_rates_fit() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    IF NEW.currency IS DISTINCT FROM OLD.currency
       AND EXISTS (SELECT 1 FROM booking.supplier_rates r WHERE r.supplier_contract_id = OLD.id) THEN
        RAISE EXCEPTION 'contract % has rates in %; its currency cannot change', OLD.id, OLD.currency
            USING ERRCODE = 'check_violation';
    END IF;
    IF (NEW.valid_from, NEW.valid_to) IS DISTINCT FROM (OLD.valid_from, OLD.valid_to)
       AND EXISTS (
           SELECT 1 FROM booking.supplier_rates r
           WHERE r.supplier_contract_id = OLD.id
             AND (r.valid_from < NEW.valid_from
                  OR (NEW.valid_to IS NOT NULL AND (r.valid_to IS NULL OR r.valid_to > NEW.valid_to)))) THEN
        RAISE EXCEPTION 'contract % has rates outside the new validity', OLD.id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.supplier_contract_rates_fit() IS
    'bk-010: a contract with rates keeps its currency and a validity that covers every rate.';

CREATE OR REPLACE TRIGGER supplier_contracts_rates_fit
    BEFORE UPDATE OF currency, valid_from, valid_to ON booking.supplier_contracts
    FOR EACH ROW EXECUTE FUNCTION booking.supplier_contract_rates_fit();

-- ── Version items and cost lines reference supply ────────────────────────────

ALTER TABLE booking.trip_case_version_itinerary
    ADD COLUMN IF NOT EXISTS hotel_room_type_id UUID REFERENCES booking.hotel_room_types (id),
    ADD COLUMN IF NOT EXISTS service_id UUID REFERENCES booking.services (id);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_constraint WHERE conname = 'trip_case_version_itinerary_supply_chk'
    ) THEN
        ALTER TABLE booking.trip_case_version_itinerary ADD CONSTRAINT trip_case_version_itinerary_supply_chk
            CHECK (num_nonnulls(hotel_room_type_id, service_id) <= 1);
    END IF;
END $$;

COMMENT ON COLUMN booking.trip_case_version_itinerary.hotel_room_type_id IS
    'bk-010: the hotel room type this item books (optional; its rate in force defaults the item net cost).';
COMMENT ON COLUMN booking.trip_case_version_itinerary.service_id IS
    'bk-010: the service this item books (optional; its rate in force defaults the item net cost).';

CREATE INDEX IF NOT EXISTS trip_case_version_itinerary_room_type_idx
    ON booking.trip_case_version_itinerary (hotel_room_type_id) WHERE hotel_room_type_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS trip_case_version_itinerary_service_idx
    ON booking.trip_case_version_itinerary (service_id) WHERE service_id IS NOT NULL;

ALTER TABLE booking.version_item_costs
    ADD COLUMN IF NOT EXISTS supplier_rate_id UUID REFERENCES booking.supplier_rates (id);

COMMENT ON COLUMN booking.version_item_costs.supplier_rate_id IS
    'bk-010: the published supplier rate this line was defaulted from (provenance; net_amount is what is priced).';

CREATE INDEX IF NOT EXISTS version_item_costs_rate_idx
    ON booking.version_item_costs (supplier_rate_id) WHERE supplier_rate_id IS NOT NULL;

-- ── Grants (per object; no blanket ALL TABLES grant, see header) ─────────────

GRANT SELECT, INSERT, UPDATE ON booking.hotels TO booking;
GRANT SELECT, INSERT, UPDATE ON booking.hotel_room_types TO booking;
GRANT SELECT, INSERT, UPDATE ON booking.services TO booking;
GRANT SELECT, INSERT, UPDATE, DELETE ON booking.supplier_rates TO booking;
GRANT USAGE, SELECT ON SEQUENCE booking.hotel_code_seq TO booking;
GRANT USAGE, SELECT ON SEQUENCE booking.service_code_seq TO booking;
GRANT EXECUTE ON FUNCTION booking.supplier_rate_guard() TO booking;
GRANT EXECUTE ON FUNCTION booking.supplier_contract_rates_fit() TO booking;

-- Hotels, room types and services are never deleted (deactivate instead); default privileges grant DELETE.
-- A draft rate may be removed (the guard refuses it once the contract is published).
REVOKE DELETE, TRUNCATE ON booking.hotels FROM booking;
REVOKE DELETE, TRUNCATE ON booking.hotel_room_types FROM booking;
REVOKE DELETE, TRUNCATE ON booking.services FROM booking;
REVOKE TRUNCATE ON booking.supplier_rates FROM booking;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-010', now(), 'AA-823 wave 2b: hotels (HTL- code, supplier, style, stars, place, geo, check-in/out, amenities, links, active/inactive), hotel_room_types, services (SVC- code, activity/transfer/guide/entrance/meal, unit, place, CIS source ref), supplier_rates under draft-only contracts (fixed once published), version items reference a room type or service, cost lines name their rate, no customer-facing columns (Q17)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
