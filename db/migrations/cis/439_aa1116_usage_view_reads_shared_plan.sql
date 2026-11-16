-- Migration 439: AA-1116 (S282) — one price source: shared.v_tenant_monthly_usage reads the tenant's live content plan
-- in shared.plan (price, overage rates) and its resolved entitlements (content.rewrite, api.calls_monthly) instead of
-- the legacy shared.membership_plans, which no admin page edits.
--
-- Why. The S282 pricing gap audit (V1, "missed" 3): an administrator can type the option B prices (149 / 349 / 699 USD)
-- on Tenants › Plans & add-ons, but the agency studio Billing tab, the admin tenant list, Tenant 360's margin and the
-- rewrite overage kept reading 299 / 799 / 1,499 USD and the overage rates from shared.membership_plans through this
-- view. 435 copied the overage rates onto shared.plan (overage_usd_per_tour, overage_usd_per_1k_calls).
--
-- What.
--   1. DROP + CREATE shared.v_tenant_monthly_usage with the 233 columns in the same order and types, then four
--      appended: plan_key (the live content plan), billing_currency, price_vnd_monthly, overage_rate_usd_per_1k_calls.
--      Sources: the live content subscription (trialing, active, past_due) -> shared.plan (price_usd_monthly,
--      overage_usd_per_tour, overage_usd_per_1k_calls, price_vnd_monthly); quotas = the materialised entitlements
--      shared.tenant_entitlement content.rewrite / api.calls_monthly (NULL = no quota: Enterprise / internal by
--      contract, decision 11; a per-tenant override counts). Counting, month filters and llm_cost_usd unchanged (233).
--      Skipped (NOTICE) where gold_aa_internal.tenant_tour_versions does not exist (the CI test DB, as 233).
--   2. GRANT SELECT to cis_app (the view is recreated; Dev's default ACL of cis_owner grants the rest as before).
--   3. COMMENT ON TABLE shared.membership_plans: deprecated, no price reader (the table stays: tenants.plan_id).
--   4. Register 439.
--
-- Behaviour on apply. Same rows. On Dev the content plans still hold 299 / 799 / 1,499 (seed 355) until the option B
-- prices are typed on the Plans page, so the numbers do not move at apply; the overage rates are the values 435
-- copied. A tenant with no live content subscription shows NULL plan fields (as with no plan_id before). Enterprise /
-- internal quotas move from 999,999 to NULL (no quota): over-quota is then never reported for them.
--
-- Class: CONTRACT (DROP + CREATE of an existing view). MIG-4: AA-1116 migration-only PR (435-439, one batch), applied
-- on Dev by Infra Migration Apply when every job table is idle (ADR 0017a). The code PR that stops the other readers
-- of membership_plans follows.
--
-- Number. 435 + 4 (see 435 for the renumber rule).
--
-- Locks. DROP / CREATE VIEW (AccessExclusive on the view only). lock_timeout 5s. Idempotent, one transaction,
-- self-registering.
--
-- Rollback (a NEW forward migration): restate 233's view body.
--
-- X1. One BEGIN … COMMIT block, no role switch; the DO block's EXECUTE runs literal DDL only (as 233).

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '435') THEN
        RAISE EXCEPTION 'migration 439: apply 435 first';
    END IF;
END $$;

DO $mig$
DECLARE
    got text;
BEGIN
    IF to_regclass('gold_aa_internal.tenant_tour_versions') IS NULL THEN
        RAISE NOTICE 'migration 439: gold_aa_internal.tenant_tour_versions is absent; v_tenant_monthly_usage left as is';
        RETURN;
    END IF;

    DROP VIEW IF EXISTS shared.v_tenant_monthly_usage;

    EXECUTE $view$
    CREATE VIEW shared.v_tenant_monthly_usage AS
    SELECT t.tenant_id,
           t.name AS tenant_name,
           t.plan_tier,
           t.slug,
           q.tours_quota_monthly,
           q.api_calls_quota_monthly,
           p.price_usd_monthly,
           p.overage_usd_per_tour AS overage_rate_usd_per_tour,
           date_trunc('month'::text, now()) AS billing_month,
           u.tours_rewritten,
           u.api_calls_used,
           CASE WHEN q.tours_quota_monthly > 0
                THEN round(u.tours_rewritten::numeric / q.tours_quota_monthly::numeric * 100::numeric, 1)
                ELSE 0::numeric END AS quota_tours_pct,
           CASE WHEN q.api_calls_quota_monthly > 0
                THEN round(u.api_calls_used / q.api_calls_quota_monthly::numeric * 100::numeric, 1)
                ELSE 0::numeric END AS quota_calls_pct,
           GREATEST(0::bigint, u.tours_rewritten - q.tours_quota_monthly) AS tours_overage,
           round(GREATEST(0::bigint, u.tours_rewritten - q.tours_quota_monthly)::numeric
                 * p.overage_usd_per_tour, 2) AS overage_usd,
           -- AA-798: real month-to-date LLM spend (Jev included, shadow runs excluded).
           COALESCE((SELECT round(sum(l.cost_usd), 4)
                       FROM shared.llm_call_log l
                      WHERE l.tenant_id = t.tenant_id
                        AND l.created_at >= date_trunc('month'::text, now())
                        AND l.created_at < date_trunc('month'::text, now()) + interval '1 month'
                        AND NOT (l.quality_signal @> '{"shadow": true}'::jsonb)), 0::numeric) AS llm_cost_usd,
           s.plan_key,
           t.billing_currency::text AS billing_currency,
           p.price_vnd_monthly,
           p.overage_usd_per_1k_calls AS overage_rate_usd_per_1k_calls
      FROM shared.tenants t
      LEFT JOIN shared.tenant_subscription s
             ON s.tenant_id = t.tenant_id AND s.product = 'content'
            AND s.status IN ('trialing', 'active', 'past_due')
      LEFT JOIN shared.plan p ON p.plan_key = s.plan_key
     CROSS JOIN LATERAL (
            SELECT (SELECT e.limit_value FROM shared.tenant_entitlement e
                     WHERE e.tenant_id = t.tenant_id AND e.feature_key = 'content.rewrite')::integer
                       AS tours_quota_monthly,
                   (SELECT e.limit_value FROM shared.tenant_entitlement e
                     WHERE e.tenant_id = t.tenant_id AND e.feature_key = 'api.calls_monthly')::integer
                       AS api_calls_quota_monthly
           ) q
     CROSS JOIN LATERAL (
            SELECT (SELECT count(DISTINCT ttv.id)
                      FROM gold_aa_internal.tenant_tour_versions ttv
                     WHERE ttv.tenant_id = t.tenant_id
                       AND ttv.created_at >= date_trunc('month'::text, now())
                       AND ttv.created_at < date_trunc('month'::text, now()) + interval '1 month') AS tours_rewritten,
                   (SELECT count(*)::numeric
                      FROM shared.tenant_api_usage tau
                     WHERE tau.tenant_id = t.tenant_id
                       AND tau.called_at >= date_trunc('month'::text, now())
                       AND tau.called_at < date_trunc('month'::text, now()) + interval '1 month') AS api_calls_used
           ) u
    $view$;

    EXECUTE $c$
    COMMENT ON VIEW shared.v_tenant_monthly_usage IS
        'Per-tenant usage for the current billing month (one row per tenant): the live content plan''s price and '
        'overage rates from shared.plan and the resolved quotas (content.rewrite, api.calls_monthly; NULL = no quota) '
        'since 439 (AA-1116; shared.membership_plans before), tours rewritten, API calls, quota %, overage, real LLM '
        'cost, and (439) plan_key, billing_currency, price_vnd_monthly, overage_rate_usd_per_1k_calls. Month filters '
        'sargable (233, AA-825).'
    $c$;
    EXECUTE $c$
    COMMENT ON COLUMN shared.v_tenant_monthly_usage.llm_cost_usd IS
        'AA-798 — SUM(shared.llm_call_log.cost_usd) for this tenant_id this calendar month, Jev '
        'included, shadow rows (quality_signal.shadow = true) excluded. Admin-only: never in a '
        'tenant API response.'
    $c$;
    EXECUTE $g$ GRANT SELECT ON shared.v_tenant_monthly_usage TO cis_app $g$;

    SELECT string_agg(column_name, ',' ORDER BY ordinal_position) INTO got
      FROM information_schema.columns
     WHERE table_schema = 'shared' AND table_name = 'v_tenant_monthly_usage';
    IF got IS DISTINCT FROM
       'tenant_id,tenant_name,plan_tier,slug,tours_quota_monthly,api_calls_quota_monthly,'
       'price_usd_monthly,overage_rate_usd_per_tour,billing_month,tours_rewritten,api_calls_used,'
       'quota_tours_pct,quota_calls_pct,tours_overage,overage_usd,llm_cost_usd,plan_key,billing_currency,'
       'price_vnd_monthly,overage_rate_usd_per_1k_calls' THEN
        RAISE EXCEPTION 'migration 439: v_tenant_monthly_usage columns are %', got;
    END IF;
END $mig$;

DO $$
BEGIN
    -- the CI test DB has no shared.membership_plans (its 223 does not replay)
    IF to_regclass('shared.membership_plans') IS NOT NULL THEN
        COMMENT ON TABLE shared.membership_plans IS
            'DEPRECATED (AA-1116, CIS 439): legacy content tiers (AA-640). No price or quota reader since 439: prices, '
            'overage rates and quotas live on shared.plan / shared.plan_feature (Tenants > Plans & add-ons). Kept as '
            'history and for the soft link shared.tenants.plan_id. Do not edit.';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('439', now(), 'AA-1116: v_tenant_monthly_usage reads shared.plan and the resolved quotas (membership_plans '
                      'deprecated); + plan_key, billing_currency, price_vnd_monthly, overage per 1k calls')
ON CONFLICT (version) DO NOTHING;

COMMIT;
