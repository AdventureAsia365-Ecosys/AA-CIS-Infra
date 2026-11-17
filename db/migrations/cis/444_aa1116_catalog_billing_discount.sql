-- Migration 444: AA-1116 (S283) — contract tenant.entitlements.v1 1.10: catalog.v_tenant_billing_v1 appends the quote
-- discount of each subscription line (discount_pct, discount_kind), so AA-Booking drafts a real discount line instead
-- of the zero "check the Tenant 360 quote" line.
--
-- Why. 443 stores the share CIS code computes from the one quote rule (services/tenant_account/quote.py); Booking
-- reads only this contract view (it has no grant on shared.*).
--
-- What:
--   1. catalog_owner column SELECT on shared.tenant_subscription (quote_discount_pct, quote_discount_kind).
--   2. catalog.v_tenant_billing_v1 (Booking only): 438's 28 columns in their order, then discount_pct numeric(5,2)
--      (the percentage of this line's amount to take off; 0 = none; NULL on the row of a tenant without a
--      subscription) and discount_kind text (founding | combo | NULL). Same rows as 377 / 438.
--   3. Register 444.
--
-- Behaviour on apply. Same rows; discount_pct is 0 and discount_kind NULL everywhere until the AA-1116 code PR's first
-- tick fills 443's columns. A Booking reader that names the 438 columns keeps working unchanged; the Booking drafts
-- change reads the two columns after this file is applied.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): a column GRANT on an existing table and a
-- replaced view in the hot schema catalog (the catalog.* recipe). MIG-4: the AA-1116 contract 1.10 migration-only PR
-- (443-444, one batch), applied on Dev by Infra Migration Apply when every job table is idle (ADR 0017a). The code
-- does not read this view (Booking does), so readiness stays at 443.
--
-- Recipe. The X1 S22 catalog recipe (as 377 / 438): the grant as cis_owner, then GRANT CREATE ON SCHEMA catalog TO
-- catalog_owner; SET LOCAL ROLE catalog_owner; the view DDL; SET LOCAL ROLE cis_owner; REVOKE CREATE. DB Migrate runs
-- the file as cis_owner (login db_migrator). Never RESET ROLE, no SECURITY DEFINER, no role DDL, no dynamic SQL. The
-- conftest replay skips this file (needs 377 / 438, skipped too); tests/integration/test_aa1116_migrations_443_444.py
-- applies them the DB Migrate way and undoes them.
--
-- Number. 443 + 1 (see 443 for the renumber rule).
--
-- Locks. One column GRANT and one CREATE OR REPLACE VIEW. lock_timeout 5s, statement_timeout 1min. Idempotent, one
-- transaction, self-registering.
--
-- Rollback (a NEW forward migration under the same recipe, after the Booking reader is reverted): restate the 438 view
-- (a view loses appended columns only by DROP + CREATE), REVOKE the column grant.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Preconditions (as the file's role: cis_owner on Dev) ─────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '443')
       OR NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '438') THEN
        RAISE EXCEPTION 'migration 444: apply 438 and 443 first';
    END IF;
    IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'catalog') <> 'cis_owner' THEN
        RAISE EXCEPTION 'migration 444: schema catalog is not owned by cis_owner (apply 245 first)';
    END IF;
END $$;

-- ── 1. What catalog_owner may read ───────────────────────────────────────────────────────────────────────────────
GRANT SELECT (quote_discount_pct, quote_discount_kind) ON shared.tenant_subscription TO catalog_owner;

GRANT CREATE ON SCHEMA catalog TO catalog_owner;
SET LOCAL ROLE catalog_owner;

-- ── 2. The Booking billing view: 438's columns, then the quote discount ─────────────────────────────────────────
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
       s.status AS subscription_status,
       t.billing_currency::text AS billing_currency,
       p.price_vnd_monthly,
       p.price_extra_seat_vnd,
       p.seats_min,
       s.agreed_price_monthly,
       s.agreed_currency::text AS agreed_currency,
       s.agreed_until,
       s.billing_interval,
       s.trial_ends_at,
       t.is_pilot,
       t.is_pilot AND coalesce(((SELECT v.value FROM shared.v_setting_billing_effective v
                  WHERE v.key = 'cis.billing.pilot_free') #>> '{}')::boolean, true)
           AS bill_free,
       -- 444: the quote discount of this line (443; contract 1.10)
       s.quote_discount_pct AS discount_pct,
       s.quote_discount_kind AS discount_kind
  FROM shared.tenants t
  LEFT JOIN shared.tenant_subscription s ON s.tenant_id = t.tenant_id
  LEFT JOIN shared.plan p ON p.plan_key = s.plan_key;

COMMENT ON VIEW catalog.v_tenant_billing_v1 IS
    'AA-1037 R4, AA-1116 (377, 438, 444; contract tenant.entitlements.v1 1.10, root ADR 0019 d1 / d9): what AA-Booking '
    'invoices an agency for: one row per tenant and subscription (NULL subscription columns for a tenant without one) '
    'with the plan''s USD and VND list prices, unit, included seats, seat minimum and extra-seat prices, the agreed '
    'price per billed unit / currency / end (438), the billing interval, '
    'the trial end, the agency''s billing currency, the pilot flag and bill_free (pilot while cis.billing.pilot_free '
    'is on), the bill-to fields CIS holds and (444) the quote discount of the line: discount_pct of its amount, '
    'discount_kind founding | combo. Booking only. Contract v1: columns are only appended.';

GRANT SELECT ON catalog.v_tenant_billing_v1 TO booking;

-- ── Closing check as catalog_owner: the view answers ─────────────────────────────────────────────────────────────
DO $$
BEGIN
    RAISE NOTICE 'migration 444: as catalog_owner, billing % row(s)', (SELECT count(*) FROM catalog.v_tenant_billing_v1);
END $$;

SET LOCAL ROLE cis_owner;
REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;

-- ── Closing check as cis_owner ───────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    r text;
    cols text;
BEGIN
    IF (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'catalog.v_tenant_billing_v1'::regclass)
       <> 'catalog_owner' THEN
        RAISE EXCEPTION 'migration 444: catalog.v_tenant_billing_v1 is not catalog_owner''s';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = 'catalog.v_tenant_billing_v1'::regclass
                    AND 'security_barrier=true' = ANY(reloptions)) THEN
        RAISE EXCEPTION 'migration 444: catalog.v_tenant_billing_v1 is not security_barrier';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'booking')
       AND NOT pg_catalog.has_table_privilege('booking', 'catalog.v_tenant_billing_v1', 'SELECT') THEN
        RAISE EXCEPTION 'migration 444: booking cannot read catalog.v_tenant_billing_v1';
    END IF;
    FOREACH r IN ARRAY ARRAY['tripplanner', 'aa_app_user', 'cis_app', 'crm_app'] LOOP
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r)
           AND pg_catalog.has_table_privilege(r, 'catalog.v_tenant_billing_v1', 'SELECT') THEN
            RAISE EXCEPTION 'migration 444: % can read catalog.v_tenant_billing_v1 (booking only)', r;
        END IF;
    END LOOP;
    SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum) INTO cols
      FROM pg_attribute a WHERE a.attrelid = 'catalog.v_tenant_billing_v1'::regclass AND a.attnum > 0
       AND NOT a.attisdropped;
    IF cols IS DISTINCT FROM 'tenant_id uuid, name text, kind text, legal_entity_name text, tax_id text, '
                             'billing_email text, billing_address text, billing_country text, product text, '
                             'plan_key text, plan_name text, price_usd_monthly numeric(10,2), price_unit text, '
                             'seats_included integer, price_extra_seat_usd numeric(10,2), seats integer, '
                             'subscription_status text, billing_currency text, price_vnd_monthly numeric(14,0), '
                             'price_extra_seat_vnd numeric(14,0), seats_min integer, '
                             'agreed_price_monthly numeric(14,2), agreed_currency text, agreed_until date, '
                             'billing_interval text, trial_ends_at timestamp with time zone, is_pilot boolean, '
                             'bill_free boolean, discount_pct numeric(5,2), discount_kind text' THEN
        RAISE EXCEPTION 'migration 444: catalog.v_tenant_billing_v1 columns are %', cols;
    END IF;
    IF pg_catalog.has_column_privilege('catalog_owner', 'shared.tenant_subscription', 'billing_ref', 'SELECT') THEN
        RAISE EXCEPTION 'migration 444: catalog_owner reads tenant_subscription.billing_ref';
    END IF;
    IF pg_catalog.has_schema_privilege('catalog_owner', 'catalog', 'CREATE') THEN
        RAISE EXCEPTION 'migration 444: catalog_owner still has CREATE on schema catalog';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('444', now(), 'AA-1116: contract 1.10, the quote discount (discount_pct, discount_kind) appended to '
                      'catalog.v_tenant_billing_v1')
ON CONFLICT (version) DO NOTHING;

COMMIT;
