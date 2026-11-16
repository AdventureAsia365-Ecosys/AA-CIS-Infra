-- Migration 435: AA-1116 (S282) — storage for the option B price list (tech lead 16/11/2026: every price, threshold,
-- limit and policy value is data an administrator edits in the CIS admin, never a code literal). Root ADR 0019
-- amendment "option B" (b2-b4, b18) and the S282 pricing decisions.
--
-- Why. The S282 pricing gap audit found the option B values with nowhere to live: no VND price list, no minimum seats,
-- no Enterprise floor, overage rates only in the legacy shared.membership_plans (no admin writer), no AI increment for
-- the TripPlanner plans, no billing interval / agreed price / price lock on a subscription, no per-agency billing
-- currency or founding-offer dates, and a pilot that must end on a date (the tech lead wants "free
-- until go-live").
--
-- What (storage only; the readers come with migrations 437-439 and the AA-1116 code PRs):
--   1. shared.plan: + price_vnd_monthly numeric(14,0), price_extra_seat_vnd numeric(14,0), seats_min integer (>= 1,
--      NULL = no minimum; billed quantity = max(seats, seats_min)), price_floor_usd_monthly numeric(10,2) (Enterprise
--      contract floor), overage_usd_per_tour numeric(10,4), overage_usd_per_1k_calls numeric(10,4), price_set_at date
--      (the day the list price was last set; the review badge counts from it). Backfill: the content plans get today's
--      overage rates of shared.membership_plans by tier (so they become editable on the Plans page; nothing else
--      changes). The product and price-unit CHECKs stay as 353: there is no retail add-on product (S282 decision 14:
--      no custom-domain add-on, no AI pack; the custom domain is a TripPlanner Pro feature and an AI top-up is a
--      per-tenant override).
--   2. shared.entitlement_feature: + ai.budget_addon_usd_monthly (platform, limit, usd_month): what a crm /
--      tripplanner plan ADDS to the tenant's monthly AI budget (TripPlanner Hosted +10, Pro +25 USD in option B).
--   3. shared.tenant_subscription: + billing_interval month | year (NOT NULL DEFAULT 'month'), agreed_price_monthly
--      numeric(14,2) + agreed_currency USD | VND (both or neither), agreed_until date (needs an agreed price; NULL with
--      a price = a contract price without end). The agreed price is per billed unit, like the list price it replaces:
--      per seat on a per-seat plan (line = agreed x max(seats, seats_min)), the plan fee on any other plan (extra seats
--      above seats_included still at the extra-seat list price). The price lock of option B is an agreed price with
--      agreed_until.
--   4. shared.tenants: + billing_currency USD | VND (NOT NULL DEFAULT 'USD'), founding_offer_from / founding_offer_until
--      (both or neither, until >= from). tenants_pilot_check relaxed: a pilot may have no end date ("until go-live",
--      decision 8); a non-pilot still has none and a pilot is still an agency.
--   5. shared.v_setting_billing_effective (key, value): the platform value in force of every cis.billing.* registry key
--      (the newest approved platform row with effective_from <= now(), else the definition default), for SQL readers
--      (resolver 437, catalog views 438). A view owned by cis_owner (it reads the FORCE RLS settings tables as their
--      owner); SELECT to cis_app and catalog_owner.
--   6. Guards and register 435.
--
-- Behaviour on apply. None for running code: new columns are NULL / defaulted (USD, month), the pilot CHECK only
-- widens (a pilot without an end date) and nothing reads the settings view yet. The overage backfill
-- copies values (4 / 3 / 2 USD a tour, 0.80 / 0.60 / 0.40 USD per 1k calls on Dev) that only 439 starts to read.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): ALTERs existing tables, replaces a CHECK,
-- backfills rows. MIG-4: the AA-1116 migration-only PR (435-439, one batch), applied on Dev by Infra Migration Apply
-- when every job table is idle (ADR 0017a), then the code PRs. DM-6.1: billing_currency and the founding dates are
-- commercial terms, not personal data; DM-7.1: no new table.
--
-- Number. 433 is the newest CIS migration on main (16/11/2026); 434 is taken by another S282 lane (AA-1120). If the
-- owner main max + 1 differs at merge, renumber 435-439 (git grep '435_' and '435' in api/migrations, tests,
-- shared/settings/compiled_defaults.json and docs/implementation-notes/AA-1116.md).
--
-- Locks. ALTER TABLE ADD COLUMN with constant defaults (no rewrite on PG 15), CHECK swaps on three small tables
-- (plan ~10 rows, tenants ~11, tenant_subscription ~31). lock_timeout 5s, statement_timeout 2min.
-- Idempotent (IF NOT EXISTS, DROP CONSTRAINT IF EXISTS + ADD, CREATE OR REPLACE, ON CONFLICT, backfill only where
-- NULL), one transaction, self-registering.
--
-- Rollback (a NEW forward migration, after the AA-1116 code is reverted): restate the 354 pilot CHECK (after giving
-- every pilot an end date); DROP the added columns and the settings view; DELETE the ai.budget_addon_usd_monthly feature.
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of shared.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '2min';
SELECT set_config('aa.actor', 'migration:435', true);

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '407') THEN
        RAISE EXCEPTION 'migration 435: apply 407 (settings registry) first';
    END IF;
    IF to_regclass('shared.tenant_subscription') IS NULL THEN
        RAISE EXCEPTION 'migration 435: apply 353 first';
    END IF;
END $$;

-- ── 1. shared.plan ──────────────────────────────────────────────────────────────────────────────────────────────────
ALTER TABLE shared.plan
    ADD COLUMN IF NOT EXISTS price_vnd_monthly        numeric(14,0),
    ADD COLUMN IF NOT EXISTS price_extra_seat_vnd     numeric(14,0),
    ADD COLUMN IF NOT EXISTS seats_min                integer,
    ADD COLUMN IF NOT EXISTS price_floor_usd_monthly  numeric(10,2),
    ADD COLUMN IF NOT EXISTS overage_usd_per_tour     numeric(10,4),
    ADD COLUMN IF NOT EXISTS overage_usd_per_1k_calls numeric(10,4),
    ADD COLUMN IF NOT EXISTS price_set_at             date;

ALTER TABLE shared.plan DROP CONSTRAINT IF EXISTS plan_option_b_check;
ALTER TABLE shared.plan ADD CONSTRAINT plan_option_b_check
    CHECK ((price_vnd_monthly IS NULL OR price_vnd_monthly >= 0)
           AND (price_extra_seat_vnd IS NULL OR price_extra_seat_vnd >= 0)
           AND (seats_min IS NULL OR seats_min BETWEEN 1 AND 500)
           AND (price_floor_usd_monthly IS NULL OR price_floor_usd_monthly >= 0)
           AND (overage_usd_per_tour IS NULL OR overage_usd_per_tour >= 0)
           AND (overage_usd_per_1k_calls IS NULL OR overage_usd_per_1k_calls >= 0));

COMMENT ON COLUMN shared.plan.price_vnd_monthly IS
    'AA-1116 (435): the VND list price a month (per seat for a per-seat plan); NULL = not '
    'priced in VND. Reviewed every cis.billing.vnd_price_review_months against cis.billing.fx_vnd_per_usd.';
COMMENT ON COLUMN shared.plan.seats_min IS
    'AA-1116 (435): the fewest seats billed (quantity = max(seats, seats_min)); provision raises a smaller request to '
    'it (decision 2). NULL = no minimum.';
COMMENT ON COLUMN shared.plan.price_floor_usd_monthly IS
    'AA-1116 (435): the lowest agreed monthly price of a contract plan (Enterprise floor 699 USD in option B).';
COMMENT ON COLUMN shared.plan.overage_usd_per_tour IS
    'AA-1116 (435): USD billed per tour rewrite above content.rewrite (was shared.membership_plans).';
COMMENT ON COLUMN shared.plan.overage_usd_per_1k_calls IS
    'AA-1116 (435): USD billed per 1,000 API calls above api.calls_monthly (was shared.membership_plans).';
COMMENT ON COLUMN shared.plan.price_set_at IS
    'AA-1116 (435): the day the list price was last set (the Plans API sets it on a price change); the review badge '
    'counts cis.billing.price_review_months from it.';

-- Backfill: today's overage rates of the legacy content tiers, only where still empty (re-runnable, never overwrites
-- an administrator's edit). The CI test DB has no shared.membership_plans (its 223 does not replay): nothing to copy.
DO $$
BEGIN
    IF to_regclass('shared.membership_plans') IS NOT NULL THEN
        UPDATE shared.plan p
           SET overage_usd_per_tour = mp.overage_rate_usd_per_tour,
               overage_usd_per_1k_calls = mp.overage_rate_usd_per_1k_calls
          FROM shared.membership_plans mp
         WHERE p.product = 'content' AND p.tier IS NOT NULL AND mp.plan_name = p.tier::text
           AND p.overage_usd_per_tour IS NULL AND p.overage_usd_per_1k_calls IS NULL;
    END IF;
END $$;

-- ── 2. Feature catalogue ─────────────────────────────────────────────────────────────────────────────────────────────
INSERT INTO shared.entitlement_feature (feature_key, product, value_kind, unit, description)
VALUES ('ai.budget_addon_usd_monthly', 'platform', 'limit', 'usd_month',
        'USD a month this plan adds to the tenant''s AI budget (crm / tripplanner plans); never on a content plan. '
        'The resolver adds it to the content plan''s ai.budget_usd_monthly (AA-1116, CIS 437).')
ON CONFLICT (feature_key) DO NOTHING;

-- ── 3. shared.tenant_subscription ───────────────────────────────────────────────────────────────────────────────────
ALTER TABLE shared.tenant_subscription
    ADD COLUMN IF NOT EXISTS billing_interval     text NOT NULL DEFAULT 'month',
    ADD COLUMN IF NOT EXISTS agreed_price_monthly numeric(14,2),
    ADD COLUMN IF NOT EXISTS agreed_currency      character(3),
    ADD COLUMN IF NOT EXISTS agreed_until         date;
ALTER TABLE shared.tenant_subscription DROP CONSTRAINT IF EXISTS tenant_subscription_terms_check;
ALTER TABLE shared.tenant_subscription ADD CONSTRAINT tenant_subscription_terms_check
    CHECK (billing_interval IN ('month', 'year')
           AND (agreed_price_monthly IS NULL OR agreed_price_monthly >= 0)
           AND (agreed_currency IS NULL OR agreed_currency IN ('USD', 'VND'))
           AND ((agreed_price_monthly IS NULL) = (agreed_currency IS NULL))
           AND (agreed_until IS NULL OR agreed_price_monthly IS NOT NULL));
COMMENT ON COLUMN shared.tenant_subscription.billing_interval IS
    'AA-1116 (435): month or year (annual = cis.billing.annual_paid_months of 12 paid up front; Booking flags it for a '
    'manual invoice, decision 7).';
COMMENT ON COLUMN shared.tenant_subscription.agreed_price_monthly IS
    'AA-1116 (435): the monthly price agreed with this agency in agreed_currency (Enterprise contract, price lock), '
    'per billed unit like the list price it replaces: per seat on a per-seat plan (line = agreed x max(seats, '
    'seats_min)), the plan fee on any other plan (extra seats above seats_included at the extra-seat list price). '
    'Wins over the list price until agreed_until (NULL = no end). NULL = the list price.';

-- ── 4. shared.tenants ───────────────────────────────────────────────────────────────────────────────────────────────
ALTER TABLE shared.tenants
    ADD COLUMN IF NOT EXISTS billing_currency     character(3) NOT NULL DEFAULT 'USD',
    ADD COLUMN IF NOT EXISTS founding_offer_from  date,
    ADD COLUMN IF NOT EXISTS founding_offer_until date;
ALTER TABLE shared.tenants DROP CONSTRAINT IF EXISTS tenants_billing_terms_check;
ALTER TABLE shared.tenants ADD CONSTRAINT tenants_billing_terms_check
    CHECK (billing_currency IN ('USD', 'VND')
           AND ((founding_offer_from IS NULL) = (founding_offer_until IS NULL))
           AND (founding_offer_until IS NULL OR founding_offer_until >= founding_offer_from));
-- 354's pilot rule relaxed: a pilot may run "until go-live" (no end date, ended by End pilot); a non-pilot has no end
-- date and a pilot is an agency, as before.
ALTER TABLE shared.tenants DROP CONSTRAINT IF EXISTS tenants_pilot_check;
ALTER TABLE shared.tenants ADD CONSTRAINT tenants_pilot_check
    CHECK ((is_pilot OR pilot_ends_at IS NULL) AND (NOT is_pilot OR kind = 'agency'));
COMMENT ON COLUMN shared.tenants.billing_currency IS
    'AA-1116 (435): the currency the agency is invoiced in (USD or VND; VND uses the plan''s VND list price). Edited '
    'in Tenant 360 > Billing details.';
COMMENT ON COLUMN shared.tenants.founding_offer_from IS
    'AA-1116 (435): start of the founding-agency offer (cis.billing.founding_discount_pct for cis.billing.'
    'founding_months, at most cis.billing.founding_max_agencies agencies); NULL = none.';

-- ── 5. shared.v_setting_billing_effective ─────────────────────────────────────────────────────────────────────────
-- A view, not a function: a view reads its tables as its owner (cis_owner, which the FORCE RLS settings tables let read
-- every key), while a function would run as its caller (booking, tripplanner through a catalog view) and a SECURITY
-- DEFINER routine in shared is refused by MIG-6 (CIS 245).
CREATE OR REPLACE VIEW shared.v_setting_billing_effective AS
SELECT d.key,
       coalesce((SELECT sv.value
                   FROM shared.setting_value sv
                  WHERE sv.key = d.key AND sv.tenant_id IS NULL AND sv.status = 'approved'
                    AND sv.effective_from <= now()
                  ORDER BY sv.effective_from DESC, sv.version DESC
                  LIMIT 1),
                d.default_value) AS value
  FROM shared.setting_definition d
 WHERE d.key LIKE 'cis.billing.%';
COMMENT ON VIEW shared.v_setting_billing_effective IS
    'AA-1116 (CIS 435): the platform value in force of every cis.billing.* settings-registry key (newest approved '
    'platform row in force, else the definition default), for SQL readers (resolver 437, catalog views 438). Python '
    'code reads through shared.settings instead.';
REVOKE ALL ON shared.v_setting_billing_effective FROM PUBLIC;
GRANT SELECT ON shared.v_setting_billing_effective TO cis_app, catalog_owner;

-- ── 6. Guards ───────────────────────────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    n bigint;
BEGIN
    SELECT count(*) INTO n FROM information_schema.columns
     WHERE table_schema = 'shared'
       AND (table_name, column_name) IN (('plan', 'price_vnd_monthly'), ('plan', 'seats_min'),
                                         ('plan', 'price_floor_usd_monthly'), ('plan', 'overage_usd_per_tour'),
                                         ('plan', 'overage_usd_per_1k_calls'), ('plan', 'price_set_at'),
                                         ('plan', 'price_extra_seat_vnd'),
                                         ('tenant_subscription', 'billing_interval'),
                                         ('tenant_subscription', 'agreed_price_monthly'),
                                         ('tenant_subscription', 'agreed_currency'),
                                         ('tenant_subscription', 'agreed_until'),
                                         ('tenants', 'billing_currency'), ('tenants', 'founding_offer_from'),
                                         ('tenants', 'founding_offer_until'));
    IF n <> 14 THEN
        RAISE EXCEPTION 'migration 435: % of 14 new columns present', n;
    END IF;
    -- every live content plan of a legacy tier has its overage rates
    IF to_regclass('shared.membership_plans') IS NOT NULL THEN
        SELECT count(*) INTO n FROM shared.plan p
          JOIN shared.membership_plans mp ON mp.plan_name = p.tier::text
         WHERE p.product = 'content' AND p.retired_at IS NULL
           AND (p.overage_usd_per_tour IS NULL OR p.overage_usd_per_1k_calls IS NULL);
        IF n > 0 THEN
            RAISE EXCEPTION 'migration 435: % content plan(s) without overage rates after the backfill', n;
        END IF;
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('435', now(), 'AA-1116: option B pricing storage (plan VND / seats_min / floor / overage, AI increment '
                      'feature, subscription interval / agreed price, tenant billing currency / founding dates, pilot '
                      'without end, shared.v_setting_billing_effective)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
