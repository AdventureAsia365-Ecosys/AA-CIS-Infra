-- Migration 377: AA-1037 R4 slice 1 (root ADR 0019 d1, d9) — Booking's read of what it invoices an agency for: the
-- contract view catalog.v_tenant_billing_v1 (tenant.entitlements.v1 1.3, the billing part for Booking).
--
-- Why. ADR 0019 d9 ("every invoice is issued from Booking"): the Booking job bk_saas_invoice_draft drafts the software
-- fee of each agency from its CIS subscriptions, and an issued invoice keeps a snapshot of the bill-to legal fields
-- that CIS holds as the account master (d1: legal entity name, tax ID, billing e-mail and address, country; CIS 354).
-- catalog.v_tenant_account_v1 (357) carries neither the plans nor their prices nor the bill-to fields, and
-- tenant.entitlements.v1 carries limits, not prices. Booking reads the CIS control plane through catalog contract views
-- only (role booking has USAGE on schema catalog, never on shared), so the billing facts are served by one more view:
-- no HTTP, no new Cognito client, no secret.
--
-- What:
--   1. Column-level SELECT for catalog_owner on shared.tenants (the bill-to fields; tenant_id, name and kind are
--      granted again, idempotent, held since 357), on shared.tenant_subscription (tenant_id, product, plan_key,
--      status, seats; never billing_ref) and on shared.plan (plan_key, name, the price columns).
--   2. catalog.v_tenant_billing_v1 (security_barrier, owner catalog_owner): one row per tenant and subscription (a
--      tenant without a subscription has one row with NULL subscription columns): tenant_id, name, kind, the bill-to
--      fields, product, plan_key, plan_name, price_usd_monthly, price_unit, seats_included, price_extra_seat_usd,
--      seats, subscription_status. SELECT to booking only. Contract v1: columns are only appended.
--   3. Register 377.
--
-- Personal data (DM-6.1): the bill-to columns are tagged on shared.tenants (pii:name, pii:government_id,
-- pii:contact, pii:address, CIS 354); Booking keeps them only as the issued invoice's snapshot
-- (booking.agency_invoice.bill_to, tagged, an accounting record).
--
-- Behaviour. None on apply: nothing reads the view until the AA-Booking agency billing code is deployed, and that code
-- detects the view (42P01 / 42501 before this file: the SaaS draft answers skipped, an issue snapshots the agency name
-- only).
--
-- Class: CONTRACT (root ADR 0017 decision 3; no expand header): column GRANTs on existing tables, a view in the hot
-- schema catalog, DO guards and the catalog.* recipe (role switch, GRANT / REVOKE CREATE). MIG-4: migration-only PR;
-- applied on Dev by Infra Migration Apply when the job tables are idle (ADR 0017a). DM-7.1: a view, no new table.
--
-- Guards (RAISE rolls the whole file back): before — 357 registered (the catalog_owner column grants on
-- shared.tenants), schema catalog owned by cis_owner. After, as cis_owner — the view's exact columns and types, owner
-- catalog_owner, security_barrier, booking can read it, tripplanner / aa_app_user / cis_app / crm_app cannot, booking
-- has no privilege on the three base tables, catalog_owner has no table-level SELECT and no write on them, never
-- billing_ref, and no CREATE on schema catalog any more.
--
-- Recipe. The X1 S22 catalog recipe (as 323 / 329 / 341 / 347 / 357): GRANT CREATE ON SCHEMA catalog TO
-- catalog_owner; SET LOCAL ROLE catalog_owner; the view DDL; SET LOCAL ROLE cis_owner; REVOKE CREATE. DB Migrate runs
-- the file as cis_owner (login db_migrator). Never RESET ROLE, no SECURITY DEFINER, no role DDL, no dynamic SQL. The
-- conftest replay skips this file (catalog recipe, 245's owners); tests/integration/test_aa1037_migration_377.py
-- applies it the DB Migrate way and undoes it.
--
-- Number. 376 is the highest on main (05/11, after 375 and 376 merged); written as 381, renumbered to 377. If the owner
-- main max + 1 differs at merge, renumber (git grep '377_' and '377' in this file, the test, conftest and the
-- AA-Booking test stub).
--
-- Locks. Column GRANTs and one CREATE VIEW. lock_timeout 5s, statement_timeout 1min. Idempotent (CREATE OR REPLACE
-- with the same column list, re-runnable grants, ON CONFLICT DO NOTHING), one transaction, self-registering.
--
-- Rollback (a NEW forward migration under the same recipe, after the Booking code is reverted): DROP VIEW
-- catalog.v_tenant_billing_v1; REVOKE SELECT (the bill-to columns) ON shared.tenants FROM catalog_owner; REVOKE SELECT
-- (...) ON shared.tenant_subscription, shared.plan FROM catalog_owner.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Preconditions (as the file's role: cis_owner on Dev) ─────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '357') THEN
        RAISE EXCEPTION 'migration 377: apply 357 (catalog.v_tenant_account_v1) first';
    END IF;
    IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'catalog') <> 'cis_owner' THEN
        RAISE EXCEPTION 'migration 377: schema catalog is not owned by cis_owner (apply 245 first)';
    END IF;
END $$;

-- ── 1. What catalog_owner may read ───────────────────────────────────────────────────────────────────────────────
GRANT SELECT (tenant_id, name, kind, legal_entity_name, tax_id, billing_email, billing_address, billing_country)
    ON shared.tenants TO catalog_owner;
GRANT SELECT (tenant_id, product, plan_key, status, seats) ON shared.tenant_subscription TO catalog_owner;
GRANT SELECT (plan_key, name, price_usd_monthly, price_unit, seats_included, price_extra_seat_usd)
    ON shared.plan TO catalog_owner;

GRANT CREATE ON SCHEMA catalog TO catalog_owner;
SET LOCAL ROLE catalog_owner;

-- ── 2. The view: one row per tenant and subscription ─────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW catalog.v_tenant_billing_v1 WITH (security_barrier = true) AS
SELECT t.tenant_id,
       t.name::text AS name,
       t.kind,
       t.legal_entity_name,
       t.tax_id,
       t.billing_email,
       t.billing_address,
       t.billing_country,
       s.product,
       s.plan_key,
       p.name AS plan_name,
       p.price_usd_monthly,
       p.price_unit,
       p.seats_included,
       p.price_extra_seat_usd,
       s.seats,
       s.status AS subscription_status
  FROM shared.tenants t
  LEFT JOIN shared.tenant_subscription s ON s.tenant_id = t.tenant_id
  LEFT JOIN shared.plan p ON p.plan_key = s.plan_key;

COMMENT ON VIEW catalog.v_tenant_billing_v1 IS
    'AA-1037 R4 (377, contract tenant.entitlements.v1 1.3, root ADR 0019 d1 / d9): what AA-Booking invoices an agency '
    'for: one row per tenant and subscription (NULL subscription columns for a tenant without one) with the plan''s '
    'monthly USD price, unit, included seats and extra-seat price, the seats and the subscription status, and the '
    'bill-to fields CIS holds (snapshotted on an issued invoice). Booking only. Contract v1: columns are only appended.';

GRANT SELECT ON catalog.v_tenant_billing_v1 TO booking;

-- ── Closing check as catalog_owner: the view answers ─────────────────────────────────────────────────────────────
DO $$
BEGIN
    RAISE NOTICE 'migration 377: as catalog_owner, % row(s), % live subscription(s)',
        (SELECT count(*) FROM catalog.v_tenant_billing_v1),
        (SELECT count(*) FROM catalog.v_tenant_billing_v1 WHERE subscription_status IN ('active', 'past_due'));
END $$;

SET LOCAL ROLE cis_owner;
REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;

-- ── Closing check as cis_owner ───────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v constant text := 'catalog.v_tenant_billing_v1';
    r text;
    t text;
    cols text;
BEGIN
    IF (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = v::regclass) <> 'catalog_owner' THEN
        RAISE EXCEPTION 'migration 377: % is not catalog_owner''s', v;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = v::regclass AND 'security_barrier=true' = ANY(reloptions)) THEN
        RAISE EXCEPTION 'migration 377: % is not security_barrier', v;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'booking')
       AND NOT pg_catalog.has_table_privilege('booking', v, 'SELECT') THEN
        RAISE EXCEPTION 'migration 377: booking cannot read %', v;
    END IF;
    FOREACH r IN ARRAY ARRAY['tripplanner', 'aa_app_user', 'cis_app', 'crm_app'] LOOP
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r)
           AND pg_catalog.has_table_privilege(r, v, 'SELECT') THEN
            RAISE EXCEPTION 'migration 377: % can read % (booking only)', r, v;
        END IF;
    END LOOP;
    SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum) INTO cols
      FROM pg_attribute a WHERE a.attrelid = v::regclass AND a.attnum > 0 AND NOT a.attisdropped;
    IF cols IS DISTINCT FROM 'tenant_id uuid, name text, kind text, legal_entity_name text, tax_id text, '
                             'billing_email text, billing_address text, billing_country text, product text, '
                             'plan_key text, plan_name text, price_usd_monthly numeric(10,2), price_unit text, '
                             'seats_included integer, price_extra_seat_usd numeric(10,2), seats integer, '
                             'subscription_status text' THEN
        RAISE EXCEPTION 'migration 377: % columns are %', v, cols;
    END IF;
    FOREACH t IN ARRAY ARRAY['shared.tenants', 'shared.tenant_subscription', 'shared.plan'] LOOP
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'booking')
           AND (pg_catalog.has_any_column_privilege('booking', t, 'SELECT')
                OR pg_catalog.has_any_column_privilege('booking', t, 'UPDATE')) THEN
            RAISE EXCEPTION 'migration 377: booking can read or change % directly', t;
        END IF;
        IF pg_catalog.has_table_privilege('catalog_owner', t, 'SELECT')
           OR pg_catalog.has_any_column_privilege('catalog_owner', t, 'INSERT')
           OR pg_catalog.has_any_column_privilege('catalog_owner', t, 'UPDATE')
           OR pg_catalog.has_table_privilege('catalog_owner', t, 'DELETE') THEN
            RAISE EXCEPTION 'migration 377: catalog_owner has more than column SELECT on %', t;
        END IF;
    END LOOP;
    IF pg_catalog.has_column_privilege('catalog_owner', 'shared.tenant_subscription', 'billing_ref', 'SELECT') THEN
        RAISE EXCEPTION 'migration 377: catalog_owner reads tenant_subscription.billing_ref';
    END IF;
    IF pg_catalog.has_schema_privilege('catalog_owner', 'catalog', 'CREATE') THEN
        RAISE EXCEPTION 'migration 377: catalog_owner still has CREATE on schema catalog';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('377', now(), 'AA-1037 R4: catalog.v_tenant_billing_v1 (subscriptions, plan prices, bill-to) for the Booking '
                      'agency invoices; column SELECT for catalog_owner on tenants, tenant_subscription, plan')
ON CONFLICT (version) DO NOTHING;

COMMIT;
