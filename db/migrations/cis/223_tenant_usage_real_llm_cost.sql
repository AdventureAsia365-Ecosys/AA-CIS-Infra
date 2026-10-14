-- Migration 223: AA-798 (S235) — shared.v_tenant_monthly_usage.llm_cost_usd becomes the tenant's
-- real month-to-date LLM spend from shared.llm_call_log, and the objects the live view depends on
-- are captured in the repo for the first time.
--
-- Problem. The live llm_cost_usd was invented: pipeline_runs.cost_usd (never written by the T axis)
-- + 0.018 x count(ai_generated tenant_tour_versions). S234: Atlas showed $0.054 against $6.78 real
-- in llm_call_log, Terra $0.072 against $6.83.
--
-- Schema drift (S235 synthesis R4). The live view (billing_month, quota_*_pct, llm_cost_usd ...),
-- shared.membership_plans and shared.tenants.plan_id were created by hand on Dev and exist in no
-- migration; the only repo definition of the view is 007_tenant_usage.sql, with different columns
-- (month, total_calls ...). Everything below was written from a read-only dump of the live DB taken
-- 14/10/2026 (.tmp-session/s235/view_dump.json: pg_get_viewdef, owner, grants, dependents, the
-- membership_plans DDL + rows, tenants.plan_id + its FK).
--
-- 1. shared.membership_plans — CREATE TABLE IF NOT EXISTS with the live columns, defaults, PK and
--    UNIQUE (plan_name); the five live plans are seeded with their live ids, ON CONFLICT (plan_name)
--    DO NOTHING. No-op on Dev (table and rows exist); it makes a fresh DB match Dev.
-- 2. shared.tenants.plan_id — ADD COLUMN IF NOT EXISTS with the live FK (tenants_plan_id_fkey, no ON
--    DELETE action). No-op on Dev. No backfill: Dev was backfilled in S234; a fresh DB has no tenants.
-- 3. shared.v_tenant_monthly_usage — DROP VIEW IF EXISTS + CREATE VIEW (CREATE OR REPLACE cannot
--    turn the 007 shape into the live shape). Same 16 columns, same names, types and order as live;
--    every column except llm_cost_usd keeps the live expression unchanged. llm_cost_usd is now
--      SUM(llm_call_log.cost_usd) for rows with tenant_id = the tenant, created_at in the current
--      calendar month (same date_trunc('month', now()) boundary as every other column), and
--      quality_signal NOT marked {"shadow": true}.
--    - Jev (TypeSafe) calls are included: shared/llm_client/decide.py logs them to llm_call_log.
--    - Shadow rows are excluded: they are AA's own model experiments (ADR 0006, shared/llm_client/
--      shadow.py writes quality_signal {"shadow": true, ...}), not the cost of serving the tenant.
--    - Rows with tenant_id NULL (A-series / platform calls) are not attributed to any tenant,
--      including aa_internal. Platform spend is reported by /admin/overview (_MTD_LLM_SQL).
--    - shared.pipeline_runs is no longer read by the view.
--    The plain DROP (no CASCADE) fails loudly if a dependent object appears before this runs; the
--    live dump found none.
--
-- Grants. The live ACL is owner-only: the view (and membership_plans) belong to aa_cis_admin, and
-- information_schema lists only that role's implicit owner privileges. DB Migrate runs as the CIS
-- api DATABASE_URL login, which is aa_cis_admin (AA-CIS-Infra terraform.tfvars), so DROP + CREATE
-- reproduces the same owner and the same ACL. No GRANT is added: aa_app_user never had access to
-- this view, and billing data stays admin-path only.
--
-- Readers (unchanged by this file): admin_pipeline.get_admin_billing, v1_tours /v1/billing,
-- admin_overview._QUOTA_SQL, admin_settings, admin.py tenant list. admin.py GET /admin/tenants/
-- {id}/usage still selects the 007 columns (month, total_calls ...) and 500s on Dev today; its fix
-- is in the AA-798 app change, not here.
--
-- Applied on Dev via the AA-CIS-Infra "DB Migrate" workflow (identical copy in db/migrations/cis/).
-- Apply only after the app change that removes llm_cost_usd from /v1/billing is deployed on Dev.
-- The view keeps its live column names and types, so no reader breaks either way. But tenant
-- GET /v1/billing (v1_tours.py, tenant JWT) still selects v.llm_cost_usd, so applying this first
-- would show every tenant AA's real month-to-date LLM spend (Gate-1, 14/10: never tenant-visible).

BEGIN;

-- 1 ── membership plans (baseline capture of the live table) ─────────────────────────────────
CREATE TABLE IF NOT EXISTS shared.membership_plans (
    id                             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    plan_name                      TEXT NOT NULL UNIQUE,
    tours_quota_monthly            INTEGER NOT NULL DEFAULT 0,
    api_calls_quota_monthly        INTEGER NOT NULL DEFAULT 0,
    price_usd_monthly              NUMERIC(10, 2) NOT NULL DEFAULT 0,
    overage_rate_usd_per_tour      NUMERIC(10, 4) NOT NULL DEFAULT 0,
    overage_rate_usd_per_1k_calls  NUMERIC(10, 4) NOT NULL DEFAULT 0,
    is_active                      BOOLEAN NOT NULL DEFAULT true,
    created_at                     TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO shared.membership_plans
    (id, plan_name, tours_quota_monthly, api_calls_quota_monthly, price_usd_monthly,
     overage_rate_usd_per_tour, overage_rate_usd_per_1k_calls, is_active)
VALUES
    ('5e1c9c9d-6517-4c48-9421-beb5c780f044', 'starter',        50,   5000,  299.00, 4.0000, 0.8000, true),
    ('dc2c3b21-93b1-42e7-9f4c-f9d54d83f399', 'growth',        200,  20000,  799.00, 3.0000, 0.6000, true),
    ('efe57a9c-d35d-442d-8a09-0f20b8a68a65', 'business',      500, 100000, 1499.00, 2.0000, 0.4000, true),
    ('b8f49e3f-4bb6-4add-a7c0-c3d1e12496a1', 'enterprise', 999999, 999999,    0.00, 0.0000, 0.0000, true),
    ('e887ccf0-54c3-419f-b190-d80e31c4b366', 'internal',   999999, 999999,    0.00, 0.0000, 0.0000, true)
ON CONFLICT (plan_name) DO NOTHING;

-- 2 ── tenants.plan_id (baseline capture; the FK is created only together with a new column) ──
ALTER TABLE shared.tenants
    ADD COLUMN IF NOT EXISTS plan_id UUID REFERENCES shared.membership_plans(id);

-- 3 ── the view ─────────────────────────────────────────────────────────────────────────────
DROP VIEW IF EXISTS shared.v_tenant_monthly_usage;

CREATE VIEW shared.v_tenant_monthly_usage AS
SELECT t.tenant_id,
       t.name AS tenant_name,
       t.plan_tier,
       t.slug,
       mp.tours_quota_monthly,
       mp.api_calls_quota_monthly,
       mp.price_usd_monthly,
       mp.overage_rate_usd_per_tour,
       date_trunc('month'::text, now()) AS billing_month,
       count(DISTINCT ttv.id) AS tours_rewritten,
       (SELECT count(*)::numeric AS count
          FROM shared.tenant_api_usage tau
         WHERE tau.tenant_id = t.tenant_id
           AND date_trunc('month'::text, tau.called_at) = date_trunc('month'::text, now())) AS api_calls_used,
       CASE
           WHEN mp.tours_quota_monthly > 0
           THEN round(count(DISTINCT ttv.id)::numeric / mp.tours_quota_monthly::numeric * 100::numeric, 1)
           ELSE 0::numeric
       END AS quota_tours_pct,
       CASE
           WHEN mp.api_calls_quota_monthly > 0
           THEN round(((SELECT count(*)::numeric AS count
                          FROM shared.tenant_api_usage tau2
                         WHERE tau2.tenant_id = t.tenant_id
                           AND date_trunc('month'::text, tau2.called_at) = date_trunc('month'::text, now())))
                      / mp.api_calls_quota_monthly::numeric * 100::numeric, 1)
           ELSE 0::numeric
       END AS quota_calls_pct,
       GREATEST(0::bigint, count(DISTINCT ttv.id) - mp.tours_quota_monthly) AS tours_overage,
       round(GREATEST(0::bigint, count(DISTINCT ttv.id) - mp.tours_quota_monthly)::numeric
             * mp.overage_rate_usd_per_tour, 2) AS overage_usd,
       -- AA-798: real month-to-date LLM spend (Jev included, shadow runs excluded).
       COALESCE((SELECT round(sum(l.cost_usd), 4)
                   FROM shared.llm_call_log l
                  WHERE l.tenant_id = t.tenant_id
                    AND l.created_at >= date_trunc('month'::text, now())
                    AND l.created_at < date_trunc('month'::text, now()) + interval '1 month'
                    AND NOT (l.quality_signal @> '{"shadow": true}'::jsonb)), 0::numeric) AS llm_cost_usd
  FROM shared.tenants t
  LEFT JOIN shared.membership_plans mp ON mp.id = t.plan_id
  LEFT JOIN gold_aa_internal.tenant_tour_versions ttv
         ON ttv.tenant_id = t.tenant_id
        AND date_trunc('month'::text, ttv.created_at) = date_trunc('month'::text, now())
 GROUP BY t.tenant_id, t.name, t.plan_tier, t.slug, mp.tours_quota_monthly,
          mp.api_calls_quota_monthly, mp.price_usd_monthly, mp.overage_rate_usd_per_tour;

COMMENT ON VIEW shared.v_tenant_monthly_usage IS
    'Per-tenant usage for the current billing month (one row per tenant): plan quotas from '
    'membership_plans, tours rewritten, API calls, quota %, overage, and real LLM cost. '
    'Baseline-captured from the live definition in migration 223 (AA-798).';
COMMENT ON COLUMN shared.v_tenant_monthly_usage.llm_cost_usd IS
    'AA-798 — SUM(shared.llm_call_log.cost_usd) for this tenant_id this calendar month, Jev '
    'included, shadow rows (quality_signal.shadow = true) excluded. Admin-only: never in a '
    'tenant API response.';

-- Fail the migration if the view lost a column or changed the column order.
DO $$
DECLARE
    got TEXT;
BEGIN
    SELECT string_agg(column_name, ',' ORDER BY ordinal_position) INTO got
      FROM information_schema.columns
     WHERE table_schema = 'shared' AND table_name = 'v_tenant_monthly_usage';
    IF got IS DISTINCT FROM
       'tenant_id,tenant_name,plan_tier,slug,tours_quota_monthly,api_calls_quota_monthly,'
       'price_usd_monthly,overage_rate_usd_per_tour,billing_month,tours_rewritten,api_calls_used,'
       'quota_tours_pct,quota_calls_pct,tours_overage,overage_usd,llm_cost_usd' THEN
        RAISE EXCEPTION 'AA-798: v_tenant_monthly_usage columns differ from the live shape: %', got;
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('223', now(), 'AA-798: v_tenant_monthly_usage.llm_cost_usd = real llm_call_log month-to-date '
        'cost (shadow excluded); baseline capture of membership_plans + tenants.plan_id + the live view')
ON CONFLICT (version) DO NOTHING;

COMMIT;
