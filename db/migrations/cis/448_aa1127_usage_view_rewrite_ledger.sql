-- Migration 448: AA-1127 (S284, UI audit batch S1) — one ledger for tour rewrites: shared.v_tenant_monthly_usage counts
-- the month's rewrites from shared.tenant_rewrite_usage, the counter the rewrite quota already reads and enforces.
--
-- Why. The S283 UI audit (root docs/audits/2026-11-17-S283-fe-audit, agency rows 18-19, 24) found two rewrite counters
-- that disagree on the agency's own pages: the Content studio dashboard said "Rewrites used 2 / 200" (GET /v1/billing,
-- this view's tours_rewritten) while the Billing and Marketplace meters said 0 used (GET /v1/quota, the counter). The
-- view counted every gold_aa_internal.tenant_tour_versions row created this month, whatever made it: a tenant's own
-- inline edit (edit_source 'tenant_edit', PATCH /v1/tours/versions/{id}) raised tours_rewritten, and with it the billed
-- overage (tours_overage, overage_usd), but never the quota. An edit is not a rewrite: the plan quota is
-- "content.rewrite" (AA-640), and the quota counter is incremented in the same transaction that accepts a rewrite
-- request (api/routers/v1_tours.py trigger_rewrite -> _check_and_consume_rewrite_quota: validate first, charge last,
-- AA-741; a hard-mode refusal rolls it back), which is the only writer of AI tour versions.
--
-- What.
--   1. DROP + CREATE shared.v_tenant_monthly_usage with 439's columns, order and types. Only tours_rewritten changes:
--      the counter's rewrite_count for (tenant_id, the current UTC month 'YYYY-MM'), 0 when the month has no row,
--      as bigint (count() before). quota_tours_pct, tours_overage and overage_usd follow it. Everything else is 439's
--      body unchanged. Skipped (NOTICE) when a relation the view reads, or gold_aa_internal.tenant_tour_versions,
--      is absent (the CI test DB keeps its old view, as with 233 / 439).
--   2. GRANT SELECT to cis_app (the view is recreated).
--   3. Register 448.
--
-- Behaviour on apply. The studio dashboard, the Billing tab, the admin tenant list, Tenant 360 and the overage now show
-- the quota's number. A tenant whose month had tenant edits sees a lower "rewrites" count and, past the quota, a lower
-- overage. The month key is UTC, like _current_year_month_and_reset() in v1_tours.py (the RDS session time zone is
-- UTC; the expression does not depend on it).
--
-- Class: CONTRACT (DROP + CREATE of an existing view; no migrate directive line). MIG-4: an AA-1127 migration-only PR,
-- applied on Dev by Infra Migration Apply when every job table is idle (root ADR 0017a). No readiness raise: no code
-- reads a new column; the code PR of this batch only filters the dashboard's daily rewrite line the same way.
-- DM-7.1: no new table.
--
-- Number. 447 (AA-1126) is the newest CIS migration on main, so this batch is 448-449 and merges first in the S284 wave
-- (450-452 stage free text and connection cap views, then 453 delivery range settings, follow; the preflight refuses
-- a gap). If the owner main max + 1 differs at merge, renumber (git grep '448_' and '448' here, in
-- tests/integration/test_aa1127_migration_448.py, the code PR's comments and docs/implementation-notes/AA-1127.md).
--
-- Locks. DROP / CREATE VIEW (AccessExclusive on the view only). lock_timeout 5s. Idempotent, one transaction,
-- self-registering.
--
-- Rollback (a NEW forward migration): restate 439's view body.
--
-- X1. One BEGIN … COMMIT block, no role switch; the DO block's EXECUTE runs literal DDL only (as 439).

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '439') THEN
        RAISE EXCEPTION 'migration 448: apply 439 first';
    END IF;
END $$;

DO $mig$
DECLARE
    got text;
    missing text;
BEGIN
    -- gold_aa_internal.tenant_tour_versions is no longer read, but its absence still means "the CI test DB", where
    -- 233 / 439 left the 007-shaped view that several tests check for (same skip as 439, same view everywhere)
    SELECT string_agg(r, ', ') INTO missing
      FROM unnest(ARRAY['gold_aa_internal.tenant_tour_versions', 'shared.tenants', 'shared.tenant_subscription',
                        'shared.plan', 'shared.tenant_entitlement', 'shared.tenant_rewrite_usage',
                        'shared.tenant_api_usage', 'shared.llm_call_log']) AS r
     WHERE to_regclass(r) IS NULL;
    IF missing IS NOT NULL THEN
        RAISE NOTICE 'migration 448: % absent; v_tenant_monthly_usage left as is', missing;
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
            -- AA-1127: the rewrite ledger is the quota counter (trigger_rewrite), not every tour version of the month
            SELECT COALESCE((SELECT r.rewrite_count
                               FROM shared.tenant_rewrite_usage r
                              WHERE r.tenant_id = t.tenant_id
                                AND r.year_month = to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM')), 0)::bigint
                       AS tours_rewritten,
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
        'since 439 (AA-1116), tours rewritten = the rewrite quota counter shared.tenant_rewrite_usage for the current '
        'UTC month (448, AA-1127; every tour version of the month before), API calls, quota %, overage, real LLM cost, '
        'plan_key, billing_currency, price_vnd_monthly, overage_rate_usd_per_1k_calls.'
    $c$;
    EXECUTE $c$
    COMMENT ON COLUMN shared.v_tenant_monthly_usage.tours_rewritten IS
        'AA-1127 (448): the month''s accepted tour rewrite requests, read from shared.tenant_rewrite_usage (the counter '
        'GET /v1/quota reads and trigger_rewrite increments). A tenant''s own inline edit is not a rewrite.'
    $c$;
    EXECUTE $c$
    COMMENT ON COLUMN shared.v_tenant_monthly_usage.llm_cost_usd IS
        'AA-798 — SUM(shared.llm_call_log.cost_usd) for this tenant_id this calendar month, Jev '
        'included, shadow rows (quality_signal.shadow = true) excluded. Admin-only: never in a '
        'tenant API response.'
    $c$;
    EXECUTE $g$ GRANT SELECT ON shared.v_tenant_monthly_usage TO cis_app $g$;

    SELECT string_agg(column_name || ':' || data_type, ',' ORDER BY ordinal_position) INTO got
      FROM information_schema.columns
     WHERE table_schema = 'shared' AND table_name = 'v_tenant_monthly_usage'
       AND column_name IN ('tours_rewritten', 'tours_overage');
    IF got IS DISTINCT FROM 'tours_rewritten:bigint,tours_overage:bigint' THEN
        RAISE EXCEPTION 'migration 448: v_tenant_monthly_usage rewrite columns are %', got;
    END IF;
    SELECT string_agg(column_name, ',' ORDER BY ordinal_position) INTO got
      FROM information_schema.columns
     WHERE table_schema = 'shared' AND table_name = 'v_tenant_monthly_usage';
    IF got IS DISTINCT FROM
       'tenant_id,tenant_name,plan_tier,slug,tours_quota_monthly,api_calls_quota_monthly,'
       'price_usd_monthly,overage_rate_usd_per_tour,billing_month,tours_rewritten,api_calls_used,'
       'quota_tours_pct,quota_calls_pct,tours_overage,overage_usd,llm_cost_usd,plan_key,billing_currency,'
       'price_vnd_monthly,overage_rate_usd_per_1k_calls' THEN
        RAISE EXCEPTION 'migration 448: v_tenant_monthly_usage columns are %', got;
    END IF;
END $mig$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('448', now(), 'AA-1127: v_tenant_monthly_usage.tours_rewritten reads the rewrite quota counter '
                      '(shared.tenant_rewrite_usage), one ledger for quota, billing and overage')
ON CONFLICT (version) DO NOTHING;

COMMIT;
