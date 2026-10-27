-- Migration bk-031: AA-996 — the CIS tour countries that Booking's reference list was missing (Pakistan, Taiwan,
-- Kyrgyzstan, Uzbekistan), so Booking can keep state for them (Catalog → Countries) and use them for suppliers,
-- hotels, services and trip case countries.
--
-- Owner: AA-Booking (key bk-NNN). A byte-identical copy goes to AA-CIS-Infra
-- db/migrations/booking/031_countries_cis_markets.sql and is applied to Dev by the DB Migrate workflow (check, then
-- apply), as bk_owner (the live owner of schema booking since bk-014). Never run it from a laptop.
--
-- Depends on bk-005 (booking.countries) only.
--
-- Why: booking.countries (bk-005: 16 markets, bk-008: Mongolia) is the ISO list Booking can reference
-- (country_profiles, suppliers, hotels, services, trip_case_countries all point at it). Since Booking #118 the
-- Countries page starts from CIS (catalog.v_country, CIS 279) and lists a CIS country outside this table read-only
-- (booking_reference false, PATCH 409 country_not_in_booking). On Dev that was Pakistan, Taiwan and Kyrgyzstan.
-- The list below is the AA tour countries of CIS (migration 279 checks that each resolves: Bhutan, Cambodia, China,
-- India, Indonesia, Japan, Kyrgyzstan, Laos, Malaysia, Mongolia, Myanmar, Nepal, Pakistan, Philippines, South
-- Korea, Sri Lanka, Taiwan, Thailand, Uzbekistan, Vietnam) minus the 17 rows already here; Uzbekistan has no CIS
-- place on Dev yet but is an AA tour country, so it is added with the others.
-- Names are CIS's shared.countries.name (= catalog.v_country.name) because Booking matches CIS country names to this
-- table by name (app/catalog/destinations.py, app/catalog/trip_plans.py). active = true: AA sells these countries, as
-- for Mongolia in bk-008. No code change is needed: booking_reference becomes true for these countries by itself.
--
-- Not here: no other ISO country (a cross-border CIS place in a country AA does not sell stays read-only on the
-- Countries page, as designed), no schema change, no grant change (role booking keeps SELECT only, bk-005).
--
-- Locks: ROW EXCLUSIVE on booking.countries for four inserts. lock_timeout 5s.
-- Re-runnable (the Integration Tests replay every file): ON CONFLICT DO NOTHING (an existing row keeps its name and
-- active flag).
-- Undo (a later bk- file): DELETE the four rows, only while nothing references them.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF current_user <> 'bk_owner' THEN
        RAISE EXCEPTION 'bk-031: expected to run as bk_owner (live owner of schema booking), running as %', current_user;
    END IF;
    IF to_regclass('booking.countries') IS NULL THEN
        RAISE EXCEPTION 'bk-031: needs bk-005 (booking.countries) first';
    END IF;
END $$;

INSERT INTO booking.countries (iso2, name, active) VALUES
    ('KG', 'Kyrgyzstan', true),
    ('PK', 'Pakistan', true),
    ('TW', 'Taiwan', true),
    ('UZ', 'Uzbekistan', true)
ON CONFLICT (iso2) DO NOTHING;

-- Post-checks: the four rows are there, and role booking still only reads the reference list.
DO $$
DECLARE
    v_missing text;
BEGIN
    SELECT string_agg(code, ', ' ORDER BY code) INTO v_missing
      FROM unnest(ARRAY['KG', 'PK', 'TW', 'UZ']) AS code
     WHERE NOT EXISTS (SELECT 1 FROM booking.countries c WHERE c.iso2 = code);
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'bk-031: booking.countries is missing %', v_missing;
    END IF;
    IF has_table_privilege('booking', 'booking.countries', 'INSERT')
       OR has_table_privilege('booking', 'booking.countries', 'UPDATE')
       OR has_table_privilege('booking', 'booking.countries', 'DELETE') THEN
        RAISE EXCEPTION 'bk-031: role booking can write booking.countries';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-031', now(), 'AA-996: booking.countries gains the CIS tour countries KG Kyrgyzstan, PK Pakistan, TW Taiwan, UZ Uzbekistan (active), so Booking can keep state for them')
ON CONFLICT (version) DO NOTHING;

COMMIT;
