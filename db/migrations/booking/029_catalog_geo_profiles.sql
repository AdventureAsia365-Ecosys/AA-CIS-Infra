-- Migration bk-029: AA-996 — Booking state of CIS countries and destinations (Catalog → Countries / Destinations,
-- UI spec §3 and §7: "CIS content + Booking state"; Figma COUNTRY / DESTINATION screens, module 06).
--
-- Owner: AA-Booking (key bk-NNN). A byte-identical copy goes to AA-CIS-Infra
-- db/migrations/booking/029_catalog_geo_profiles.sql and is applied to Dev by the DB Migrate workflow (check, then
-- apply), as bk_owner (the live owner of schema booking since bk-014). Never run it from a laptop.
--
-- Depends on bk-001 (set_updated_at), bk-003 (staff_users), bk-005 (countries). Every grant names its object.
--
-- Content stays in CIS (ADR 0002, O7): names, coordinates, photos and descriptions are read live from
-- catalog.v_destination / v_tour; nothing is copied here. These tables hold only what Booking decides:
--   * booking.country_profiles: one row per ISO country (booking.countries) once staff change something. status
--     active | inactive (Booking sells trips there or not; the Figma "Delete / Unpublish Country" dialogs become
--     "Deactivate"), area (sales grouping, free text until areas are modelled), internal_notes, status_reason (why it
--     was deactivated). No row = active. `id` is a surrogate uuid only so audit_logs.entity_id can point at the row.
--   * booking.destination_profiles: one row per CIS place (catalog.v_destination.destination_id; no FK across
--     schemas, the API checks the id against the view on every write). status, internal_notes, status_reason.
--     No row = active.
-- Never deleted by role booking (soft state only: no DELETE, no TRUNCATE); the status is informational for staff in
-- this slice (lists, filters, badges) and does not yet block a supplier place pick or a proposal item.
--
-- Not log / event / job / ledger / credential / versioned-history tables, so no DM-7.1 retention row is needed: they
-- are current-state reference rows (the change history is in booking.audit_logs).
--
-- Locks: two new empty tables. lock_timeout 5s.
-- Re-runnable (the Integration Tests replay every file): IF NOT EXISTS, CREATE OR REPLACE TRIGGER, grants repeat.
-- Undo (a later bk- file): DROP TABLE booking.destination_profiles, booking.country_profiles.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF current_user <> 'bk_owner' THEN
        RAISE EXCEPTION 'bk-029: expected to run as bk_owner (live owner of schema booking), running as %', current_user;
    END IF;
    IF to_regclass('booking.countries') IS NULL OR to_regclass('booking.staff_users') IS NULL THEN
        RAISE EXCEPTION 'bk-029: needs bk-003 (staff_users) and bk-005 (countries) first';
    END IF;
END $$;

-- ── Country profiles ─────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.country_profiles (
    country_code    CHAR(2) PRIMARY KEY REFERENCES booking.countries (iso2),
    id              UUID NOT NULL DEFAULT gen_random_uuid(),
    status          TEXT NOT NULL DEFAULT 'active',
    area            TEXT,
    internal_notes  TEXT,
    status_reason   TEXT,
    updated_by      TEXT REFERENCES booking.staff_users (cis_user_id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT country_profiles_id_uq UNIQUE (id),
    CONSTRAINT country_profiles_status_chk CHECK (status IN ('active', 'inactive')),
    CONSTRAINT country_profiles_area_chk CHECK (area IS NULL OR length(btrim(area)) BETWEEN 1 AND 60),
    CONSTRAINT country_profiles_notes_chk CHECK (internal_notes IS NULL OR length(internal_notes) <= 5000),
    CONSTRAINT country_profiles_reason_chk CHECK (status_reason IS NULL OR length(status_reason) <= 500)
);

COMMENT ON TABLE booking.country_profiles IS
    'bk-029 (AA-996): Booking state of one ISO country (status, area, notes). Country content (names of places, photos, descriptions) stays in CIS (O7). No row = active. Never deleted: status = inactive.';
COMMENT ON COLUMN booking.country_profiles.status IS
    'bk-029: active = Booking sells trips in this country; inactive = soft "delete / unpublish" of the Figma country screens.';
COMMENT ON COLUMN booking.country_profiles.area IS
    'bk-029: sales grouping (e.g. Indochina), free text until areas are modelled.';
COMMENT ON COLUMN booking.country_profiles.internal_notes IS
    'conf:commercial; bk-029: staff-only notes on selling this country.';
COMMENT ON COLUMN booking.country_profiles.status_reason IS
    'conf:commercial; bk-029: why the country was deactivated (staff only, from the deactivate dialog).';

CREATE OR REPLACE TRIGGER country_profiles_set_updated_at
    BEFORE UPDATE ON booking.country_profiles
    FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();

-- ── Destination profiles ─────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.destination_profiles (
    destination_id  UUID PRIMARY KEY,
    status          TEXT NOT NULL DEFAULT 'active',
    internal_notes  TEXT,
    status_reason   TEXT,
    updated_by      TEXT REFERENCES booking.staff_users (cis_user_id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT destination_profiles_status_chk CHECK (status IN ('active', 'inactive')),
    CONSTRAINT destination_profiles_notes_chk CHECK (internal_notes IS NULL OR length(internal_notes) <= 5000),
    CONSTRAINT destination_profiles_reason_chk CHECK (status_reason IS NULL OR length(status_reason) <= 500)
);

COMMENT ON TABLE booking.destination_profiles IS
    'bk-029 (AA-996): Booking state of one CIS place (catalog.v_destination.destination_id, checked by the API; no FK across schemas). Place content stays in CIS (O7). No row = active. Never deleted: status = inactive.';
COMMENT ON COLUMN booking.destination_profiles.destination_id IS
    'bk-029: CIS catalog place id (contract catalog.tour.v1, catalog.v_destination). Never a Booking-created place.';
COMMENT ON COLUMN booking.destination_profiles.status IS
    'bk-029: active = Booking sells trips to this place; inactive = soft "delete" of the Figma destination screens.';
COMMENT ON COLUMN booking.destination_profiles.internal_notes IS
    'conf:commercial; bk-029: staff-only notes on selling this place.';
COMMENT ON COLUMN booking.destination_profiles.status_reason IS
    'conf:commercial; bk-029: why the place was deactivated (staff only, from the deactivate dialog).';

CREATE OR REPLACE TRIGGER destination_profiles_set_updated_at
    BEFORE UPDATE ON booking.destination_profiles
    FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();

-- ── Grants ───────────────────────────────────────────────────────────────────

REVOKE ALL ON booking.country_profiles FROM booking;
GRANT SELECT, INSERT ON booking.country_profiles TO booking;
GRANT UPDATE (status, area, internal_notes, status_reason, updated_by, updated_at) ON booking.country_profiles TO booking;

REVOKE ALL ON booking.destination_profiles FROM booking;
GRANT SELECT, INSERT ON booking.destination_profiles TO booking;
GRANT UPDATE (status, internal_notes, status_reason, updated_by, updated_at) ON booking.destination_profiles TO booking;

DO $$
BEGIN
    IF has_table_privilege('booking', 'booking.country_profiles', 'DELETE')
       OR has_table_privilege('booking', 'booking.country_profiles', 'TRUNCATE')
       OR has_table_privilege('booking', 'booking.destination_profiles', 'DELETE')
       OR has_table_privilege('booking', 'booking.destination_profiles', 'TRUNCATE') THEN
        RAISE EXCEPTION 'bk-029: role booking can delete country or destination profiles';
    END IF;
    IF has_column_privilege('booking', 'booking.country_profiles', 'country_code', 'UPDATE')
       OR has_column_privilege('booking', 'booking.country_profiles', 'id', 'UPDATE')
       OR has_column_privilege('booking', 'booking.destination_profiles', 'destination_id', 'UPDATE') THEN
        RAISE EXCEPTION 'bk-029: role booking can re-key a profile';
    END IF;
    IF has_table_privilege('cis_app', 'booking.country_profiles', 'SELECT')
       OR has_table_privilege('cis_app', 'booking.destination_profiles', 'SELECT') THEN
        RAISE EXCEPTION 'bk-029: cis_app can read Booking geo profiles';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-029', now(), 'AA-996: country_profiles and destination_profiles (Booking status, area, internal notes of CIS countries and places, soft state, no delete)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
