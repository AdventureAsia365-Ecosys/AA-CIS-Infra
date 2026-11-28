-- Migration 498: AA-1191 (S297) — catalog.v_billing_currencies_v1: the enabled currencies of CIS 497, as Booking reads
-- them (contract tenant.entitlements.v1 1.12; a new view, nothing existing changes).
--
-- Why. Booking drafts the monthly SaaS invoice of every agency from catalog.v_tenant_billing_v1 (377 / 438), in the
-- agency's billing_currency (USD | VND). With VND not enabled (CIS 497, default USD only) the drafts must bill in USD
-- and Booking must refuse a VND write, so Booking needs the value in force of cis.billing.enabled_currencies. Booking
-- reads the CIS control plane only through catalog views (role booking has USAGE on schema catalog, never on shared;
-- no HTTP, no secret), so the value is served by a view, like the billing terms of 438. The partner CRM holds no grant
-- on any CIS schema (root ADR 0010 decision 4) and reads the same value over HTTP (catalog.http.v1 1.5,
-- GET /catalog/v1/currencies), never through this view.
--
-- What:
--   1. catalog.v_billing_currencies_v1 (security_barrier, owner catalog_owner), always exactly one row:
--        enabled_currencies text[]  'USD' first (the base currency, always enabled), then every other currency of the
--                                   value in force in its list order, without duplicates;
--        base_currency text         'USD'.
--      The value in force comes from shared.v_setting_billing_effective (CIS 435: the newest approved platform row in
--      force, else the definition default; SELECT to catalog_owner since 435), so a change approved on Platform ›
--      Settings shows here at once. Before 497 is applied the key is missing and the view serves {USD}.
--      SELECT to booking only. Contract v1: columns are only appended.
--   2. Register 498.
--
-- Behaviour on apply. None for running code: nothing reads the view until the AA-1191 Booking PR is deployed, and that
-- reader feature-detects it (SQLSTATE 42P01 / 42501: it keeps USD only).
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): a view in the hot schema catalog under the
-- catalog.* recipe (role switch, GRANT / REVOKE CREATE). MIG-4: the AA-1191 migration-only PR (batch cis 497-498),
-- applied on Dev by Infra Migration Apply when every job table is idle (ADR 0017a). DM-7.1: a view, no new table.
-- DM-6.1: no personal data.
--
-- Recipe. The X1 S22 catalog recipe (as 377 / 415 / 438): GRANT CREATE ON SCHEMA catalog TO catalog_owner; SET LOCAL
-- ROLE catalog_owner; the view DDL; SET LOCAL ROLE cis_owner; REVOKE CREATE. Migration Apply / DB Migrate runs the file
-- as cis_owner (login db_migrator). Never RESET ROLE, no SECURITY DEFINER, no role DDL, no dynamic SQL. The conftest
-- replay skips this file (catalog recipe, 245's owners); tests/integration/test_aa1191_migration_498.py applies it
-- the DB Migrate way and undoes it.
--
-- Number. 497 + 1 (see 497 for the renumber rule).
--
-- Locks. One CREATE OR REPLACE VIEW. lock_timeout 5s, statement_timeout 1min. Idempotent (CREATE OR REPLACE with the
-- same column list, re-runnable grant), one transaction, self-registering.
--
-- Rollback (a new forward migration under the same recipe, after the Booking reader is reverted): DROP VIEW
-- catalog.v_billing_currencies_v1.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Preconditions (as the file's role: cis_owner on Dev) ─────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '435') THEN
        RAISE EXCEPTION 'migration 498: apply 435 first (shared.v_setting_billing_effective)';
    END IF;
    IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'catalog') <> 'cis_owner' THEN
        RAISE EXCEPTION 'migration 498: schema catalog is not owned by cis_owner (apply 245 first)';
    END IF;
    IF NOT pg_catalog.has_table_privilege('catalog_owner', 'shared.v_setting_billing_effective', 'SELECT') THEN
        RAISE EXCEPTION 'migration 498: catalog_owner cannot read shared.v_setting_billing_effective (435)';
    END IF;
END $$;

GRANT CREATE ON SCHEMA catalog TO catalog_owner;
SET LOCAL ROLE catalog_owner;

-- ── 1. The enabled currencies ───────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW catalog.v_billing_currencies_v1 WITH (security_barrier = true) AS
SELECT ARRAY['USD']::text[] || ARRAY(
           SELECT t.code
             FROM jsonb_array_elements_text(
                      CASE WHEN jsonb_typeof(cur.value) = 'array' THEN cur.value ELSE '[]'::jsonb END)
                  WITH ORDINALITY AS t(code, n)
            WHERE t.code <> 'USD'
            GROUP BY t.code
            ORDER BY min(t.n)) AS enabled_currencies,
       'USD'::text AS base_currency
  FROM (SELECT (SELECT e.value FROM shared.v_setting_billing_effective e
                 WHERE e.key = 'cis.billing.enabled_currencies') AS value) AS cur;

COMMENT ON VIEW catalog.v_billing_currencies_v1 IS
    'AA-1191 (CIS 498), contract tenant.entitlements.v1 1.12: one row, the currencies the platform shows and accepts '
    '(cis.billing.enabled_currencies in force, Platform › Settings). enabled_currencies: USD first (always enabled), '
    'then the other enabled currencies in list order; base_currency: USD. A tenant whose billing_currency is not '
    'enabled is invoiced in USD; a write in a currency that is not enabled is refused. Booking only. Contract v1: '
    'columns are only appended.';

GRANT SELECT ON catalog.v_billing_currencies_v1 TO booking;

-- ── Closing check as catalog_owner: the view answers one row ─────────────────────────────────────────────────────
DO $$
DECLARE
    n bigint;
BEGIN
    SELECT count(*) INTO n FROM catalog.v_billing_currencies_v1;
    IF n <> 1 THEN
        RAISE EXCEPTION 'migration 498: catalog.v_billing_currencies_v1 answers % rows (exactly 1 expected)', n;
    END IF;
    RAISE NOTICE 'migration 498: as catalog_owner, enabled currencies %',
        (SELECT enabled_currencies FROM catalog.v_billing_currencies_v1);
END $$;

SET LOCAL ROLE cis_owner;
REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;

-- ── Closing check as cis_owner ───────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    r text;
    cols text;
BEGIN
    IF (SELECT pg_get_userbyid(relowner) FROM pg_class
         WHERE oid = 'catalog.v_billing_currencies_v1'::regclass) <> 'catalog_owner' THEN
        RAISE EXCEPTION 'migration 498: catalog.v_billing_currencies_v1 is not catalog_owner''s';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = 'catalog.v_billing_currencies_v1'::regclass
                      AND 'security_barrier=true' = ANY(reloptions)) THEN
        RAISE EXCEPTION 'migration 498: catalog.v_billing_currencies_v1 is not security_barrier';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'booking')
       AND NOT pg_catalog.has_table_privilege('booking', 'catalog.v_billing_currencies_v1', 'SELECT') THEN
        RAISE EXCEPTION 'migration 498: booking cannot read catalog.v_billing_currencies_v1';
    END IF;
    FOREACH r IN ARRAY ARRAY['tripplanner', 'aa_app_user', 'cis_app', 'crm_app'] LOOP
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r)
           AND pg_catalog.has_table_privilege(r, 'catalog.v_billing_currencies_v1', 'SELECT') THEN
            RAISE EXCEPTION 'migration 498: % can read catalog.v_billing_currencies_v1 (booking only)', r;
        END IF;
    END LOOP;
    SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum) INTO cols
      FROM pg_attribute a WHERE a.attrelid = 'catalog.v_billing_currencies_v1'::regclass AND a.attnum > 0
       AND NOT a.attisdropped;
    IF cols IS DISTINCT FROM 'enabled_currencies text[], base_currency text' THEN
        RAISE EXCEPTION 'migration 498: catalog.v_billing_currencies_v1 columns are %', cols;
    END IF;
    IF pg_catalog.has_schema_privilege('catalog_owner', 'catalog', 'CREATE') THEN
        RAISE EXCEPTION 'migration 498: catalog_owner still has CREATE on schema catalog';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('498', now(), 'AA-1191: catalog.v_billing_currencies_v1 (the enabled currencies, Booking)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
