-- Migration bk-025: AA-992 — data coverage contract views for the CIS admin page /admin/data-coverage.
--
-- Owner: AA-Booking (key bk-NNN). A byte-identical copy goes to AA-CIS-Infra
-- db/migrations/booking/025_ops_data_coverage_views.sql and is applied to Dev by the DB Migrate workflow (check, then
-- apply), as bk_owner (the live owner of schema booking since bk-014). Never run it from a laptop.
--
-- Why (AA-992; S252 data coverage design §1.8, §3.2): the CIS admin "Data coverage" page counts, for the whole system,
-- what each stage holds and what is missing, from the raw upload to TripPlanner, Booking and the CRM. Booking, the
-- owner, publishes two views in its own schema and grants them to the CIS runtime role cis_app (contract rule 5 of
-- AA-Ecosys docs/contracts/README.md; same pattern as bk-017). Every other booking.* object stays 42501 for cis_app
-- (isolation probe cell cross.cis_app.booking.customers).
--
-- v_ops_data_totals (metric text, n bigint), long format, one row per metric, counts as of now:
--   trip_plans                booking.trip_plans rows
--   trip_plans_sellable       trip plans marked sellable
--   trip_plan_components      booking.trip_plan_components rows
--   departures_open           departures scheduled / guaranteed that start today or later
--   suppliers_active          suppliers with status active
--   contracts_published       supplier contracts published and valid today
--   rates_current             supplier rates valid today
--   media_active              supplier media rows with status active
--   media_active_with_rights  active media rows with usage rights
--   customers                 customers not soft-deleted
--   b2b_partners_active       B2B partners with status active
--   b2b_holds_active          B2B holds with status active
-- Aggregates only: no id, no name, no e-mail, no price, no free text.
--
-- v_ops_trip_plan_keys (source_system text, source_id text, sellable boolean): the catalog key of each trip plan and
-- whether it is sellable, so CIS can count plans whose tour left the live catalogue against its own tables. Unlike
-- the other v_ops_* views it is row-level, but it carries catalog keys only: no plan id, no name, and none of the
-- conf:commercial columns (default_channel, price_hint_*, commercial_notes) or any personal data.
--
-- Metric names and column lists are part of the contract (AA-Ecosys docs/contracts/ops.overview.v1.md, family
-- ops.data_coverage.v1): add new names, never rename.
--
-- Readers: cis_app gets SELECT on the two views (USAGE on schema booking is held since bk-017; repeated here,
-- idempotent). A view reads its base tables with its owner's (bk_owner's) rights, so cis_app needs nothing on the
-- tables.
--
-- Re-runnable (the Integration Tests replay every file): CREATE OR REPLACE VIEW keeps the column lists; the REVOKE and
-- grants repeat. The guard raises (it never skips) when cis_app is missing.
-- Cost: one count per metric over tables of < 1,000 rows each on Dev; read at most every minute by CIS.
-- Undo: DROP VIEW booking.v_ops_data_totals, booking.v_ops_trip_plan_keys (a later bk- file, after the CIS reader is
-- gone); keep USAGE on the schema (bk-017 still needs it).

BEGIN;

DO $$
BEGIN
    IF current_user <> 'bk_owner' THEN
        RAISE EXCEPTION 'bk-025: expected to run as bk_owner (live owner of schema booking), running as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cis_app') THEN
        RAISE EXCEPTION 'bk-025: role cis_app is missing (AA-CIS-Infra roles/001, rl-001)';
    END IF;
END $$;

CREATE OR REPLACE VIEW booking.v_ops_data_totals AS
SELECT 'trip_plans'::text AS metric, count(*)::bigint AS n FROM booking.trip_plans
UNION ALL
SELECT 'trip_plans_sellable'::text, count(*)::bigint FROM booking.trip_plans WHERE sellable
UNION ALL
SELECT 'trip_plan_components'::text, count(*)::bigint FROM booking.trip_plan_components
UNION ALL
SELECT 'departures_open'::text, count(*)::bigint
  FROM booking.departures
 WHERE status IN ('scheduled', 'guaranteed') AND start_date >= current_date
UNION ALL
SELECT 'suppliers_active'::text, count(*)::bigint FROM booking.suppliers WHERE status = 'active'
UNION ALL
SELECT 'contracts_published'::text, count(*)::bigint
  FROM booking.supplier_contracts
 WHERE status = 'published' AND valid_from <= current_date AND (valid_to IS NULL OR valid_to >= current_date)
UNION ALL
SELECT 'rates_current'::text, count(*)::bigint
  FROM booking.supplier_rates
 WHERE valid_from <= current_date AND (valid_to IS NULL OR valid_to >= current_date)
UNION ALL
SELECT 'media_active'::text, count(*)::bigint FROM booking.entity_media WHERE status = 'active'
UNION ALL
SELECT 'media_active_with_rights'::text, count(*)::bigint
  FROM booking.entity_media
 WHERE status = 'active' AND usage_rights
UNION ALL
SELECT 'customers'::text, count(*)::bigint FROM booking.customers WHERE deleted_at IS NULL
UNION ALL
SELECT 'b2b_partners_active'::text, count(*)::bigint FROM booking.b2b_partners WHERE status = 'active'
UNION ALL
SELECT 'b2b_holds_active'::text, count(*)::bigint FROM booking.b2b_holds WHERE status = 'active';

COMMENT ON VIEW booking.v_ops_data_totals IS
    'bk-025 (AA-992): Booking row counts, aggregates only (metric, n). Contract ops.data_coverage.v1, read by AA-CIS-App /admin/data-coverage (role cis_app).';

CREATE OR REPLACE VIEW booking.v_ops_trip_plan_keys AS
SELECT tp.source_system, tp.source_id, tp.sellable
  FROM booking.trip_plans tp;

COMMENT ON VIEW booking.v_ops_trip_plan_keys IS
    'bk-025 (AA-992): catalog key (source_system, source_id) and sellable flag of each trip plan; catalog keys only, no plan id, no conf:commercial column, no personal data. Contract ops.data_coverage.v1, read by AA-CIS-App /admin/data-coverage (role cis_app) to count plans whose tour left the live catalogue.';

-- Role booking: read-only on both views (default privileges FOR ROLE bk_owner gave it DML).
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON booking.v_ops_data_totals FROM booking;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON booking.v_ops_trip_plan_keys FROM booking;

-- The CIS reader (contract grant; AA-CIS-Infra db/owners.yaml booking.consumer_grants).
GRANT USAGE ON SCHEMA booking TO cis_app;
GRANT SELECT ON booking.v_ops_data_totals, booking.v_ops_trip_plan_keys TO cis_app;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-025', now(), 'AA-992: data coverage contract views booking.v_ops_data_totals + v_ops_trip_plan_keys, SELECT to cis_app')
ON CONFLICT (version) DO NOTHING;

COMMIT;
