-- Migration bk-040: AA-1029 R4 — the Content studio Marketplace reads the public "from" price: SELECT on
-- booking.v_from_prices (contract price.from.v1, bk-039) to the CIS runtime role cis_app.
--
-- Owner: AA-Booking (key bk-NNN). AA-CIS-Infra Migration Sync copies it byte for byte to
-- db/migrations/booking/040_from_prices_cis_reader.sql; on Dev it is applied by Infra Migration Apply as bk_owner (the
-- live owner of schema booking since bk-014) once every job table is idle. Never run it from a laptop.
--
-- Why (AA-1029 Done-when: "the from price on TripPlanner and in the portal"): the agency Content studio Marketplace
-- (AA-Partner web, /portal/marketplace) lists the AA catalogue from CIS GET /v1/tours/pool, which CIS serves from its
-- own tables. The price is Booking's (root ADR 0005 d1); readers never compute it and read it only through the
-- published contract view (root docs/contracts/price.from.v1.md). So CIS joins each pool row to this view by the
-- catalog key, in one extra read after its tenant block, and the studio shows "From US$X per person". cis_app already
-- reads other booking contract views (bk-017, bk-023, bk-025, bk-035); this adds one more, nothing else.
--
-- What: GRANT SELECT ON booking.v_from_prices TO cis_app (USAGE on schema booking is held since bk-017; repeated here,
-- idempotent). The view reads its base tables with its owner's (bk_owner's) rights, so cis_app needs nothing on them:
-- trip_plans / trip_plan_prices / trip_plan_price_history / pricing_rules stay 42501 for it (checked below). The view
-- carries the suggested retail price only, never a net, an agency (b2b) price or a margin (bk-039 guard, contract).
-- The tenant pool role aa_app_user gets nothing: CIS reads the view on its main pool (cis_app).
--
-- Class: contract, not expand (root ADR 0017 d3, "What stays manual"): a cross-owner grant (AA-CIS-Infra
-- db/owners.yaml booking.consumer_grants + the isolation probe cell consumer.contract_grants.bk-040). So a
-- migration-only PR (MIG-4); no Booking code reads it, so no readiness key (REQUIRED_SCHEMA_VERSIONS unchanged). The CIS
-- reader is fail soft (42P01 / 42501 = no price shown), so the CIS code may ship before or after this file.
--
-- Re-runnable (the integration tests replay every file): the grants repeat; the guard raises (never skips) when
-- cis_app or the view is missing.
-- Cost: none on apply (one ACL change on a view). Read by CIS once per Marketplace page (at most 100 keys).
-- Undo: REVOKE SELECT ON booking.v_from_prices FROM cis_app (a later bk- file, after the CIS reader is gone); keep USAGE
-- on the schema (bk-017 still needs it).

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF current_user <> 'bk_owner' THEN
        RAISE EXCEPTION 'bk-040: expected to run as bk_owner (live owner of schema booking), running as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cis_app') THEN
        RAISE EXCEPTION 'bk-040: role cis_app is missing (AA-CIS-Infra roles/001, rl-001)';
    END IF;
    IF to_regclass('booking.v_from_prices') IS NULL THEN
        RAISE EXCEPTION 'bk-040: booking.v_from_prices is missing (apply bk-039 first)';
    END IF;
END $$;

-- The CIS reader (contract grant; AA-CIS-Infra db/owners.yaml booking.consumer_grants).
GRANT USAGE ON SCHEMA booking TO cis_app;
GRANT SELECT ON booking.v_from_prices TO cis_app;

DO $$
BEGIN
    IF NOT has_table_privilege('cis_app', 'booking.v_from_prices', 'SELECT') THEN
        RAISE EXCEPTION 'bk-040: cis_app cannot read booking.v_from_prices';
    END IF;
    IF has_table_privilege('cis_app', 'booking.v_from_prices', 'INSERT')
       OR has_table_privilege('cis_app', 'booking.v_from_prices', 'UPDATE')
       OR has_table_privilege('cis_app', 'booking.v_from_prices', 'DELETE') THEN
        RAISE EXCEPTION 'bk-040: cis_app can write booking.v_from_prices';
    END IF;
    IF has_table_privilege('cis_app', 'booking.trip_plans', 'SELECT')
       OR has_table_privilege('cis_app', 'booking.trip_plan_prices', 'SELECT')
       OR has_table_privilege('cis_app', 'booking.trip_plan_price_history', 'SELECT')
       OR has_table_privilege('cis_app', 'booking.pricing_rules', 'SELECT') THEN
        RAISE EXCEPTION 'bk-040: cis_app can read the price tables behind the view';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-040', now(), 'AA-1029: SELECT on the price.from.v1 view booking.v_from_prices to cis_app (Content studio Marketplace)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
