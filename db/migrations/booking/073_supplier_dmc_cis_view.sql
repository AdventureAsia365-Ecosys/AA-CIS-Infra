-- Migration bk-073: AA-1148 (S290; S285 advisory r2-content-staff T5, slice L4 of root
-- docs/audits/2026-11-19-S285-session/advisory-r2-plan.md) — the supplier category `dmc` and the read-only supplier
-- list for CIS (contract supply.supplier.v1).
--
-- Owner: AA-Booking (key bk-NNN). AA-CIS-Infra Migration Sync copies it byte for byte to
-- db/migrations/booking/073_supplier_dmc_cis_view.sql and Migration Apply applies it on Dev as bk_owner once every job
-- table is idle (root ADR 0017a). Never run it from a laptop.
--
-- Depends on bk-008 (booking.suppliers) and bk-017 (USAGE on schema booking to cis_app, repeated here).
--
-- Why. CIS content staff create tours by hand in the CIS content workspace (AA-1148) and must tie each tour to the AA
-- supplier it comes from. The supplier list is Booking's (booking.suppliers); CIS only had the free text of the Excel
-- cell (raw_tours.provider), which it cannot link. Following the supply views CIS already reads (bk-023 v_supply_*,
-- bk-040 v_from_prices), Booking opens one read-only view with the supplier's identity and nothing else, and CIS stores
-- the chosen id as a soft key (CIS 478, raw_tours.supplier_id). The tours AA buys come from destination management
-- companies (DMCs) that run the whole program (transport, guides, entrances, hotels, meals), and the category list had
-- no word for them: `dmc` is added (S285 T5: named dmc, not tour, because AA still buys a tour component by component).
--
-- What:
--   1. suppliers_categories_chk (bk-008, replaced): the categories are hotel, transport, guide, entrance, activity, meal
--      and dmc, 1 to 7 of them (was 6 values, at most 6). A looser CHECK: every existing row passes.
--   2. booking.v_supply_suppliers (security_barrier): id, code, company_name, categories, country_code (text),
--      status (pending | active | inactive), updated_at of every supplier. Never a contact, the internal notes, the
--      legal entity, the tax code, the payment terms, a bank account or a price. Columns are append-only (contract
--      supply.supplier.v1, root docs/contracts/supply.supplier.v1.md).
--   3. SELECT on the view to booking and to cis_app (USAGE on schema booking to cis_app repeated, held since bk-017).
--      The cis_app grant is a contract grant mirrored in AA-CIS-Infra db/owners.yaml booking.consumer_grants
--      (expected_from bk-073, isolation probe cell consumer.contract_grants.bk-073). cis_app still reads nothing behind
--      the view (checked below).
--
-- Class: contract (root ADR 0017 d3: a replaced CHECK on an existing table and a cross-owner grant). Migration-only PR
-- first (MIG-4); the Booking code PR that accepts `dmc` in the supplier forms raises readiness to bk-073. The CIS reader
-- is fail soft (42P01 / 42501 = "the supplier list is not available"), so the CIS code may ship before or after.
-- DM-6.1: the view carries no personal data (company identity only). DM-7.1: no new table.
-- Re-runnable (the Integration Tests replay every file): DROP CONSTRAINT IF EXISTS + ADD, CREATE OR REPLACE VIEW,
-- repeatable grants.
-- Number: owner main max (bk-072) + 1. If it moves, renumber: file name, this header, the guard, the registration, the
-- tests that name it and CONTEXT.md (git grep '073_' and 'bk-073').
-- Undo (a later bk- file, after the CIS reader is gone): REVOKE SELECT ON booking.v_supply_suppliers FROM cis_app,
-- DROP VIEW; the dmc category stays while a supplier carries it.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

DO $$
BEGIN
    IF current_user <> 'bk_owner' THEN
        RAISE EXCEPTION 'bk-073: expected to run as bk_owner (live owner of schema booking), running as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cis_app') THEN
        RAISE EXCEPTION 'bk-073: role cis_app is missing (AA-CIS-Infra roles/001, rl-001)';
    END IF;
    IF to_regclass('booking.suppliers') IS NULL THEN
        RAISE EXCEPTION 'bk-073: booking.suppliers is missing (apply bk-008 first)';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'bk-073' AND description NOT LIKE 'AA-1148%') THEN
        RAISE EXCEPTION 'bk-073: the key bk-073 is already held by another migration (not AA-1148): renumber one';
    END IF;
END
$$;

-- 1. the dmc category
ALTER TABLE booking.suppliers DROP CONSTRAINT IF EXISTS suppliers_categories_chk;
ALTER TABLE booking.suppliers ADD CONSTRAINT suppliers_categories_chk CHECK (
    cardinality(categories) >= 1 AND cardinality(categories) <= 7
    AND categories <@ ARRAY['hotel', 'transport', 'guide', 'entrance', 'activity', 'meal', 'dmc']::text[]
);

-- 2. the supplier list for CIS (supply.supplier.v1)
CREATE OR REPLACE VIEW booking.v_supply_suppliers WITH (security_barrier = true) AS
SELECT s.id,
       s.code,
       s.company_name,
       s.categories,
       s.country_code::text AS country_code,
       s.status,
       s.updated_at
  FROM booking.suppliers s;

COMMENT ON VIEW booking.v_supply_suppliers IS
    'bk-073 (AA-1148), contract supply.supplier.v1: the identity of every AA supplier (id, code, company name, '
    'categories, country, status, updated_at) for the CIS content workspace, which stores the id as a soft key '
    '(raw_tours.supplier_id). Never a contact, note, legal / tax / payment detail, bank account or price. SELECT to '
    'cis_app. Columns append-only.';

-- 3. grants
REVOKE INSERT, UPDATE, DELETE ON booking.v_supply_suppliers FROM booking;
GRANT SELECT ON booking.v_supply_suppliers TO booking;
GRANT USAGE ON SCHEMA booking TO cis_app;
GRANT SELECT ON booking.v_supply_suppliers TO cis_app;

DO $$
BEGIN
    IF NOT has_table_privilege('cis_app', 'booking.v_supply_suppliers', 'SELECT') THEN
        RAISE EXCEPTION 'bk-073: cis_app cannot read booking.v_supply_suppliers';
    END IF;
    IF has_table_privilege('cis_app', 'booking.v_supply_suppliers', 'INSERT')
       OR has_table_privilege('cis_app', 'booking.v_supply_suppliers', 'UPDATE')
       OR has_table_privilege('cis_app', 'booking.v_supply_suppliers', 'DELETE') THEN
        RAISE EXCEPTION 'bk-073: cis_app can write booking.v_supply_suppliers';
    END IF;
    IF has_table_privilege('cis_app', 'booking.suppliers', 'SELECT') THEN
        RAISE EXCEPTION 'bk-073: cis_app can read booking.suppliers behind the view';
    END IF;
    IF (SELECT count(*) FROM information_schema.columns
         WHERE table_schema = 'booking' AND table_name = 'v_supply_suppliers') <> 7 THEN
        RAISE EXCEPTION 'bk-073: booking.v_supply_suppliers does not have exactly the seven contract columns';
    END IF;
END
$$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-073', now(), 'AA-1148: supplier category dmc (1 to 7 categories) and the read-only supplier list booking.v_supply_suppliers for cis_app (supply.supplier.v1)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
