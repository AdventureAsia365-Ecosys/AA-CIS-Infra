-- Migration 437: AA-1116 (S282) — the resolver serves the option B AI budget: AI budget = content plan (x the trial
-- share while trialing) + the AI increments of live crm / tripplanner plans (x the trial share while that
-- subscription trials); a per-tenant AI budget row with no amount follows the plan.
--
-- Why. Option B sells TripPlanner Hosted / Pro with +10 / +25 USD of AI a month and gives a trialing agency 50 % of
-- its AI budget (cis.billing.trial_ai_budget_pct, CIS 436). 361 serves only the content plan's ai.budget_usd_monthly,
-- and the only way to change it per tenant was an absolute override that never ends with the trial. There is no
-- retail add-on (no AI pack, no custom-domain add-on: S282 decision 14); an AI top-up stays a per-tenant override.
-- Decision 5 (S282): an AA-1016 shared.tenant_ai_budget row with monthly_usd empty means "follow the plan", not
-- "unlimited" (unlimited only for kind internal).
--
-- What.
--   1. CREATE OR REPLACE VIEW shared.v_tenant_entitlement_resolved, same columns as 361:
--      (a) live_sub as 361;
--      (b) factor = shared.v_setting_billing_effective('cis.billing.trial_ai_budget_pct') / 100 (one evaluation);
--      (c) addon_ai per tenant = sum over live crm / tripplanner subscriptions of their plan's
--          ai.budget_addon_usd_monthly (x factor while that subscription trials);
--      (d) the content plan's ai.budget_usd_monthly candidate (rank 3) = round(limit x factor-if-trialing +
--          addon_ai, 2); NULL (internal: no limit) stays NULL;
--      (e) rank 2 (shared.tenant_ai_budget) only when monthly_usd is set or the tenant is kind internal;
--      (f) ORDER BY rank, plan_key (as 361).
--      Overrides (rank 1) and AA-1016 amounts (rank 2) stay absolute (decision 4: the trial share never applies to
--      them).
--   2. shared.tenant_entitlement_sync_due() also re-syncs tenants with a trialing subscription (a changed trial share
--      reaches the materialisation within the hourly tenant_account_tick). The sync is diff-based: no change, no event.
--   3. Re-sync every tenant (actor migration:437). Dev today: no plan has ai.budget_addon_usd_monthly yet, so only a
--      trialing content subscription changes (its budget halves) and an AA-1016 row with an empty amount of a
--      non-internal tenant now follows the plan.
--   4. Guards as 361 (materialisation = resolver; no platform key without a live content subscription; no platform
--      key from a non-content plan) + ai.budget_addon_usd_monthly never served as its own entitlement.
--   5. Register 437.
--
-- Behaviour. The AI budget read by shared/cost_guard.py (shared.tenant_entitlement), catalog.v_tenant_ai_budget_v1
-- (TripPlanner) and Tenant 360 follows the sum above at once. cost_guard's _PLAN_FALLBACK (no key resolved) reads the
-- content plan only and is aligned in the AA-1116 code PR; it is a fallback for a missing row and stays the content
-- value until then (never unlimited).
--
-- Class: CONTRACT (CREATE OR REPLACE of an existing view and function, re-syncs rows). MIG-4: AA-1116 migration-only
-- PR (435-439, one batch), applied on Dev by Infra Migration Apply when every job table is idle (ADR 0017a).
--
-- Number. 435 + 2 (see 435 for the renumber rule).
--
-- Rollback (a NEW forward migration): restate 361's view and 353's tenant_entitlement_sync_due(); SELECT
-- shared.tenant_entitlement_sync(tenant_id) FROM shared.tenants.
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of shared.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '2min';
SELECT set_config('aa.actor', 'migration:437', true);

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '436')
       OR NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '361') THEN
        RAISE EXCEPTION 'migration 437: apply 361 and 436 first';
    END IF;
END $$;

-- ── 1. The resolver ─────────────────────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW shared.v_tenant_entitlement_resolved AS
WITH live_sub AS (
    SELECT s.tenant_id, s.product, s.plan_key, s.status, s.trial_ends_at, s.seats
      FROM shared.tenant_subscription s
     WHERE s.status IN ('trialing', 'active', 'past_due')
),
factor AS (
    -- 437: the AI share a trialing subscription gets (cis.billing.trial_ai_budget_pct, CIS 436)
    SELECT coalesce(((SELECT v.value FROM shared.v_setting_billing_effective v
                      WHERE v.key = 'cis.billing.trial_ai_budget_pct') #>> '{}')::numeric, 100) / 100
           AS trial
),
addon_ai AS (
    SELECT ls.tenant_id,
           sum(pf.limit_value * CASE WHEN ls.status = 'trialing' THEN f.trial ELSE 1 END) AS amount
      FROM live_sub ls
      JOIN shared.plan_feature pf ON pf.plan_key = ls.plan_key
                                 AND pf.feature_key = 'ai.budget_addon_usd_monthly'
     CROSS JOIN factor f
     WHERE ls.product <> 'content' AND pf.limit_value IS NOT NULL
     GROUP BY ls.tenant_id
),
candidate AS (
    -- 356: the limiter's per-tenant RPM (shared.tenants.rate_limit_rpm) when it differs from the live content plan.
    SELECT t.tenant_id, 'content.rate_limit_rpm'::text AS feature_key, t.rate_limit_rpm::numeric(14,2) AS limit_value,
           true AS enabled, 'override'::text AS source, NULL::text AS plan_key,
           NULL::timestamp with time zone AS expires_at, 0 AS rank, NULL::text AS sub_product
      FROM shared.tenants t
      JOIN live_sub ls ON ls.tenant_id = t.tenant_id AND ls.product = 'content'
      LEFT JOIN shared.plan_feature pf ON pf.plan_key = ls.plan_key AND pf.feature_key = 'content.rate_limit_rpm'
     WHERE pf.limit_value IS DISTINCT FROM t.rate_limit_rpm::numeric(14,2)
    UNION ALL
    SELECT o.tenant_id, o.feature_key, o.limit_value, o.enabled, 'override'::text, NULL::text, o.expires_at, 1,
           NULL::text
      FROM shared.tenant_entitlement_override o
     WHERE o.expires_at IS NULL OR o.expires_at > now()
    UNION ALL
    -- AA-1016's per-tenant AI budget acts as the override of ai.budget_usd_monthly until it is retired; 437: an empty
    -- amount follows the plan (decision 5), except for an internal tenant (no limit).
    SELECT b.tenant_id, 'ai.budget_usd_monthly'::text, b.monthly_usd::numeric(14,2), true, 'override'::text,
           NULL::text, NULL::timestamp with time zone, 2, NULL::text
      FROM shared.tenant_ai_budget b
      JOIN shared.tenants t ON t.tenant_id = b.tenant_id
     WHERE b.monthly_usd IS NOT NULL OR t.kind = 'internal'
    UNION ALL
    SELECT ls.tenant_id, pf.feature_key,
           CASE WHEN f.value_kind = 'seats' THEN coalesce(ls.seats::numeric(14,2), pf.limit_value)
                -- 437: the content plan's AI budget x the trial share + the crm / tripplanner increments
                WHEN pf.feature_key = 'ai.budget_usd_monthly' AND ls.product = 'content'
                THEN round(pf.limit_value * CASE WHEN ls.status = 'trialing' THEN fx.trial ELSE 1 END
                           + coalesce(ai.amount, 0), 2)::numeric(14,2)
                ELSE pf.limit_value END,
           true,
           CASE WHEN ls.status = 'trialing' THEN 'trial' ELSE 'plan' END,
           ls.plan_key,
           CASE WHEN ls.status = 'trialing' THEN ls.trial_ends_at END,
           3,
           ls.product
      FROM live_sub ls
      JOIN shared.plan_feature pf ON pf.plan_key = ls.plan_key
      JOIN shared.entitlement_feature f ON f.feature_key = pf.feature_key
     CROSS JOIN factor fx
      LEFT JOIN addon_ai ai ON ai.tenant_id = ls.tenant_id
),
ranked AS (
    SELECT c.tenant_id, c.feature_key, c.limit_value, c.enabled, c.source, c.plan_key, c.expires_at,
           f.product, f.value_kind, f.unit,
           row_number() OVER (PARTITION BY c.tenant_id, c.feature_key ORDER BY c.rank, c.plan_key) AS rn
      FROM candidate c
      JOIN shared.entitlement_feature f ON f.feature_key = c.feature_key
     WHERE f.retired_at IS NULL
       -- a candidate that is not a product plan's own needs a live subscription of the key's product; a platform
       -- key's product is content (356)
       AND (c.rank = 3
            OR EXISTS (SELECT 1 FROM live_sub ls
                        WHERE ls.tenant_id = c.tenant_id
                          AND ls.product = CASE WHEN f.product = 'platform' THEN 'content' ELSE f.product END))
       -- 361: a plan's platform key counts only from the content plan
       AND (c.rank <> 3 OR f.product <> 'platform' OR c.sub_product = 'content')
)
SELECT r.tenant_id, r.feature_key, r.product, r.value_kind, r.unit,
       CASE WHEN r.value_kind = 'flag' THEN NULL ELSE r.limit_value END AS limit_value,
       r.source, r.plan_key, r.expires_at
  FROM ranked r
 WHERE r.rn = 1 AND r.enabled;
COMMENT ON VIEW shared.v_tenant_entitlement_resolved IS
    'AA-1028 R1, AA-1116 (CIS 353, 356, 361, 437): the resolver, computed live: shared.tenants.rate_limit_rpm when it '
    'differs from the content plan > override (unexpired) > shared.tenant_ai_budget with an amount (or any row of an '
    'internal tenant) as the ai.budget_usd_monthly override > the plan of a live subscription (437: the '
    'content plan''s ai.budget_usd_monthly x cis.billing.trial_ai_budget_pct while trialing + the '
    'ai.budget_addon_usd_monthly of live crm / tripplanner plans, each x the trial share while that subscription '
    'trials). A non-plan candidate needs a live subscription of '
    'its product (content for platform keys). Internal: the contract view is shared.v_tenant_entitlement_v1 (355).';

-- ── 2. Hourly re-sync ───────────────────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION shared.tenant_entitlement_sync_due() RETURNS integer
    LANGUAGE plpgsql
    SET search_path = pg_catalog, shared
AS $$
DECLARE
    t uuid;
    n integer := 0;
BEGIN
    FOR t IN SELECT e.tenant_id FROM shared.tenant_entitlement e
              WHERE e.expires_at IS NOT NULL AND e.expires_at <= now()
             UNION
             -- 437: a trialing subscription follows a changed trial share
             SELECT s.tenant_id FROM shared.tenant_subscription s WHERE s.status = 'trialing'
             ORDER BY 1
    LOOP
        n := n + shared.tenant_entitlement_sync(t);
    END LOOP;
    RETURN n;
END
$$;
REVOKE ALL ON FUNCTION shared.tenant_entitlement_sync_due() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION shared.tenant_entitlement_sync_due() TO cis_app;

-- ── 3. Re-sync every tenant ─────────────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    changed bigint := 0;
    t       record;
BEGIN
    FOR t IN SELECT tenant_id FROM shared.tenants ORDER BY created_at, tenant_id LOOP
        changed := changed + shared.tenant_entitlement_sync(t.tenant_id);
    END LOOP;
    RAISE NOTICE 'migration 437: re-sync changed % entitlement row(s)', changed;
END $$;

-- ── 4. Guards ───────────────────────────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    n bigint;
BEGIN
    SELECT count(*) INTO n
      FROM shared.v_tenant_entitlement_resolved r
      FULL JOIN shared.tenant_entitlement e ON e.tenant_id = r.tenant_id AND e.feature_key = r.feature_key
     WHERE r.feature_key IS NULL OR e.feature_key IS NULL OR r.limit_value IS DISTINCT FROM e.limit_value
        OR r.source IS DISTINCT FROM e.source;
    IF n > 0 THEN
        RAISE EXCEPTION 'migration 437: % materialised row(s) differ from the resolver', n;
    END IF;
    SELECT count(*) INTO n
      FROM shared.tenant_entitlement e
      JOIN shared.entitlement_feature f ON f.feature_key = e.feature_key AND f.product = 'platform'
     WHERE NOT EXISTS (SELECT 1 FROM shared.tenant_subscription s
                        WHERE s.tenant_id = e.tenant_id AND s.product = 'content'
                          AND s.status IN ('trialing', 'active', 'past_due'));
    IF n > 0 THEN
        RAISE EXCEPTION 'migration 437: % platform entitlement(s) without a live content subscription', n;
    END IF;
    SELECT count(*) INTO n
      FROM shared.v_tenant_entitlement_resolved r
      JOIN shared.plan p ON p.plan_key = r.plan_key
     WHERE r.product = 'platform' AND r.source IN ('plan', 'trial') AND p.product <> 'content';
    IF n > 0 THEN
        RAISE EXCEPTION 'migration 437: % platform entitlement(s) served from a non-content plan', n;
    END IF;
    IF EXISTS (SELECT 1 FROM shared.v_tenant_entitlement_resolved WHERE feature_key = 'ai.budget_addon_usd_monthly') THEN
        RAISE EXCEPTION 'migration 437: ai.budget_addon_usd_monthly is served as its own entitlement';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('437', now(), 'AA-1116: resolver sums the AI budget (content x trial share + crm / tripplanner increments), '
                      'AA-1016 empty amount follows the plan; hourly re-sync of trials')
ON CONFLICT (version) DO NOTHING;

COMMIT;
