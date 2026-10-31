-- Migration 318: AA-642 S0 (AI gateway v2, step 1) — seed the Jev daily cap and the per-run DataForSEO cap of the
-- S1 rewrite in shared.spend_budget.
--
-- Why. Two paid paths ran with no cap before the call (root design docs/audits/2026-10-31-S261-ai-gateway-design-v2,
-- step 1):
--   1. Jev (TypeSafe): decide() had no budget at all, and shared/cost_guard.py had no Jev day-spend query. The same
--      PR adds both: cost_guard.day_spend('jev') (llm_call_log provider 'typesafe') and a check in decide() against
--      the (jev, global) per_day_usd row before every ask. No row was ever seeded, so without this file the check
--      finds no cap and Jev keeps running unlimited.
--   2. DataForSEO on the S1 rewrite (services/seo_intelligence/handler.py process_seo, reached from the s1_rewrite job
--      and the S1 batch prep) built its client with no budget. The same PR loads load_run_budget(pool, 'dfs',
--      's1_rewrite') there; without a job row only the global row applies, whose daily cap is alert-only (KAN-90).
--
-- Values (measured live 31/10/2026, S262 step 0, last 60 days):
--   - Jev spend per UTC day: p95 2.20 USD, max 3.84 USD. Rule max(1.00, ceil(2 x p95)) = 5.00 USD per day, hard stop,
--     alert at 80 %. Over the cap decide() makes no TypeSafe call and the stage keeps its own rule (fail-open), so a
--     stop never fails a job.
--   - DataForSEO spend per tour: p50 0.002 USD, p99 0.099 USD. Rule max(0.50, 2 x p99) = 0.50 USD per run (one
--     s1_rewrite job = one tour), hard stop. Over the cap the remaining DataForSEO sub-calls of that tour are skipped
--     and S1 goes on without fresh SEO data (today's behaviour when DataForSEO fails).
--
-- What. Two rows, both ON CONFLICT (provider, scope) DO NOTHING: a row an admin already set (PUT
-- /admin/budgets/{provider}/{scope}) is never overwritten. The existing rows (dfs global 10.00 per day alert-only,
-- dfs job:s1_seo_prefetch 3.00, dfs job:segment_research 5.00, and every bedrock / geocoder row) are not touched.
-- 'jev' is already allowed by spend_budget_provider_check (migration 168), so no constraint change.
-- No route change: shared.llm_role_config, llm_model_deployment, llm_provider_connection and the catalog are untouched.
--
-- Class: contract (root ADR 0017 d3: config-row inserts are not expand). Applied by hand through DB Migrate before the
-- app PR merges. The code reads shared.spend_budget with a fallback (no row = no cap), so the readiness requirement is
-- not raised here.
--
-- Rollback (a new forward migration): DELETE FROM shared.spend_budget WHERE updated_by = 'migration-318';
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/ (DB Migrate workflow); keep the two
-- byte-identical. After apply: regenerate docs/architecture/db-schema-reference.md (DB Schema Dump workflow).
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of shared.spend_budget.

BEGIN;
SET LOCAL lock_timeout = '5s';

INSERT INTO shared.spend_budget (provider, scope, per_run_usd, per_day_usd, hard_stop, alert_pct, updated_by)
VALUES ('jev', 'global', NULL, 5.00, true, 80, 'migration-318')
ON CONFLICT (provider, scope) DO NOTHING;

INSERT INTO shared.spend_budget (provider, scope, per_run_usd, per_day_usd, hard_stop, alert_pct, updated_by)
VALUES ('dfs', 'job:s1_rewrite', 0.50, NULL, true, 80, 'migration-318')
ON CONFLICT (provider, scope) DO NOTHING;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('318', now(), 'AA-642 S0: spend_budget seed rows (jev global 5.00 per day, dfs job:s1_rewrite 0.50 per run)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
