-- Migration 340: AA-1025 slice A7 (AI gateway v2, root plan S263 §1.A, gaps CIS-1 / OPS-07) — central LLM budgets in
-- shared.spend_budget: one provider value 'llm' (every LLM provider together, the spend of shared.llm_call_log) with
-- the scopes the gateway checks before any attempt, and a month axis.
--
-- Why. Budgets existed per LLM connection (monthly, 317), per tenant (321) and per job kind and provider for the jobs
-- that load a RunBudget themselves (168, cost_guard.load_run_budget). Nothing capped the CIS app as a whole, one stage,
-- every job kind, the eval runs or the ad-hoc scripts at the gateway, whatever the provider that answers. The code PR
-- of the same lane adds the pre-call check (shared/llm_client/central_budget.py, called in LLMClient._generate_with
-- after the stage switch and the tenant budget): a call whose scope is over a hard cap is refused before any provider
-- attempt with BudgetExceeded and one 0 USD ledger row (status refused, error_class budget).
--
-- What.
--   1. spend_budget_provider_check  + 'llm' (one value for every LLM provider: bedrock, anthropic, openai, ...).
--   2. spend_budget_scope_check     a non-'llm' row keeps 'global' | 'job:<kind>' (unchanged); an 'llm' row takes
--                                   'app:<app>'   the app's LLM spend (llm_call_log.app; 'cis' = this app's rows)
--                                   'stage:<s>'   the spend of one stage (llm_call_log.stage)
--                                   'job:<kind>'  the spend of one job kind (rows whose job is of that kind);
--                                                 per_run_usd = the spend of the running job
--                                   'eval'        the eval runs (stages writing_memory_eval / writing_memory_shadow)
--                                   'adhoc'       the ad-hoc scripts (stages adhoc_*)
--                                   ('global' is not an 'llm' scope: 'app:cis' is the whole app).
--   3. per_month_usd numeric(10,2)  NULL = no month cap; the UTC calendar month (T-8: eval and ad-hoc caps per month).
--                                   Read by the central check only; the job RunBudget (per run / per day) ignores it.
--   4. Seed (tech lead decision T-8, S263: cap = p95 of the daily spend of the last 30 days x 1.5; Dev caps are
--      alert-only, never a hard stop, so normal traffic is never blocked): ONE row ('llm', 'app:cis') with per_day_usd
--      computed from this database's own ledger, hard_stop false, alert_pct 80. Skipped when the ledger has no CIS
--      spend in the last 30 days (CI, a local replay) and never overwrites a row an admin set (ON CONFLICT DO NOTHING).
--      No stage, job kind, eval or ad-hoc row is seeded (T-8: caps stay loose; an admin adds them on AI providers ›
--      Budgets, alert-only on Dev).
--
-- Guards (RAISE rolls the whole file back):
--   before: shared.spend_budget exists (168) with the 304 provider set; no existing row would break the new CHECKs
--           (checked by the ALTERs themselves).
--   after:  the two CHECKs and the column exist; every row that existed before is unchanged (same md5 of the rows);
--           the seed, when written, is alert-only with a positive daily cap and no other axis.
--
-- Class: contract (root ADR 0017 d3: a CHECK change and a column on an existing table plus a config row), no expand
-- header. On Dev it is applied by Infra Migration Apply once every job table is idle (root ADR 0017a), after the byte
-- copy in AA-CIS-Infra db/migrations/cis/ merges. MIG-4: this migration-only PR merges before the code PR (the
-- central check, the admin editor and the Budgets tab coverage). The code reads the rows tolerantly (no 'llm' row and
-- no per_month_usd column before this file = nothing to check), so the order of deploy and apply does not change
-- behaviour; REQUIRED_CIS_SCHEMA is not raised. DM-7.1: no new table.
--
-- Rollback (a NEW forward migration): DELETE FROM shared.spend_budget WHERE provider = 'llm'; put back the 304 provider
-- CHECK and the 168 scope CHECK; ALTER TABLE shared.spend_budget DROP COLUMN per_month_usd.
--
-- X1. One BEGIN … COMMIT block, no role switch (DB Migrate runs cis/ files as cis_owner, the owner of
-- shared.spend_budget). Grants: none (cis_app keeps SELECT / INSERT / UPDATE / DELETE on the table, the new column
-- included). Locks: ALTER TABLE on a table of a few rows (ACCESS EXCLUSIVE for milliseconds); the seed reads
-- shared.llm_call_log over 30 days through llm_call_log_created_id_idx.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '2min';

DO $$
BEGIN
    IF to_regclass('shared.spend_budget') IS NULL THEN
        RAISE EXCEPTION 'migration 340: shared.spend_budget is missing (apply 168 first)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '304') THEN
        RAISE EXCEPTION 'migration 340: apply 304 first (the anthropic / azure_openai providers)';
    END IF;
    -- The rows as they are now, for the "nothing else changed" guard at the end (a transaction-local setting).
    PERFORM set_config('aa.m340_rows_before',
                       (SELECT md5(coalesce(string_agg(to_jsonb(b)::text, '|' ORDER BY b.provider, b.scope), ''))
                          FROM (SELECT provider, scope, per_run_usd, per_day_usd, hard_stop, alert_pct, updated_at,
                                       updated_by
                                  FROM shared.spend_budget) b),
                       true);
END $$;

-- ── 1. Provider 'llm' ────────────────────────────────────────────────────────────────────────────────────────────
ALTER TABLE shared.spend_budget DROP CONSTRAINT IF EXISTS spend_budget_provider_check;
ALTER TABLE shared.spend_budget
    ADD CONSTRAINT spend_budget_provider_check
    CHECK (provider IN ('dfs', 'bedrock', 'openai', 'jev', 'geocoder', 'anthropic', 'azure_openai', 'llm'));
COMMENT ON CONSTRAINT spend_budget_provider_check ON shared.spend_budget IS
    'AA-1025 A7 (CIS 340): + llm, the central LLM budgets checked by the gateway before any attempt (every LLM '
    'provider together). Was dfs | bedrock | openai | jev | geocoder | anthropic | azure_openai since 304.';

-- ── 2. Scopes ────────────────────────────────────────────────────────────────────────────────────────────────────
ALTER TABLE shared.spend_budget DROP CONSTRAINT IF EXISTS spend_budget_scope_check;
ALTER TABLE shared.spend_budget
    ADD CONSTRAINT spend_budget_scope_check
    CHECK ((provider <> 'llm' AND (scope = 'global' OR scope LIKE 'job:%'))
           OR (provider = 'llm' AND (scope ~ '^(app|stage|job):[a-z0-9][a-z0-9_.-]{0,99}$'
                                     OR scope IN ('eval', 'adhoc'))));
COMMENT ON CONSTRAINT spend_budget_scope_check ON shared.spend_budget IS
    'AA-1025 A7 (CIS 340): a provider row keeps global | job:<kind> (168); an llm row is app:<app> | stage:<stage> | '
    'job:<kind> | eval | adhoc (shared/llm_client/central_budget.py).';

-- ── 3. Month axis ────────────────────────────────────────────────────────────────────────────────────────────────
ALTER TABLE shared.spend_budget ADD COLUMN IF NOT EXISTS per_month_usd numeric(10, 2);
ALTER TABLE shared.spend_budget DROP CONSTRAINT IF EXISTS spend_budget_per_month_usd_check;
ALTER TABLE shared.spend_budget
    ADD CONSTRAINT spend_budget_per_month_usd_check CHECK (per_month_usd IS NULL OR per_month_usd >= 0);
COMMENT ON COLUMN shared.spend_budget.per_month_usd IS
    'AA-1025 A7 (CIS 340): the cap of the UTC calendar month (NULL = none). Read by the central LLM check only.';

-- ── 4. The T-8 seed: app:cis daily cap, alert-only, from this database's own ledger ─────────────────────────────
INSERT INTO shared.spend_budget (provider, scope, per_run_usd, per_day_usd, per_month_usd, hard_stop, alert_pct,
                                 updated_by)
SELECT 'llm', 'app:cis', NULL, round((p.p95 * 1.5)::numeric, 2), NULL, false, 80, 'migration-340-aa1025'
  FROM (SELECT percentile_cont(0.95) WITHIN GROUP (ORDER BY coalesce(s.usd, 0)) AS p95,
               max(coalesce(s.usd, 0)) AS top
          FROM generate_series(date_trunc('day', now() AT TIME ZONE 'utc') - interval '30 days',
                               date_trunc('day', now() AT TIME ZONE 'utc') - interval '1 day',
                               interval '1 day') AS d (day)
          LEFT JOIN (SELECT date_trunc('day', l.created_at AT TIME ZONE 'utc') AS day, sum(l.cost_usd) AS usd
                       FROM shared.llm_call_log l
                      WHERE l.created_at >= (date_trunc('day', now() AT TIME ZONE 'utc') - interval '30 days')
                                            AT TIME ZONE 'utc'
                        AND l.created_at < date_trunc('day', now() AT TIME ZONE 'utc') AT TIME ZONE 'utc'
                        AND coalesce(l.app, 'cis') = 'cis'
                      GROUP BY 1) s ON s.day = d.day) p
 WHERE p.top > 0 AND round((p.p95 * 1.5)::numeric, 2) > 0
ON CONFLICT (provider, scope) DO NOTHING;

-- ── 5. Guard: the result ─────────────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    sig_after text;
    bad       text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'shared.spend_budget'::regclass
                      AND attname = 'per_month_usd' AND NOT attisdropped) THEN
        RAISE EXCEPTION 'migration 340: shared.spend_budget.per_month_usd is missing';
    END IF;
    IF (SELECT count(*) FROM pg_constraint WHERE conrelid = 'shared.spend_budget'::regclass
           AND conname IN ('spend_budget_provider_check', 'spend_budget_scope_check',
                           'spend_budget_per_month_usd_check')) <> 3 THEN
        RAISE EXCEPTION 'migration 340: a CHECK of shared.spend_budget is missing';
    END IF;

    SELECT md5(coalesce(string_agg(to_jsonb(b)::text, '|' ORDER BY b.provider, b.scope), '')) INTO sig_after
      FROM (SELECT provider, scope, per_run_usd, per_day_usd, hard_stop, alert_pct, updated_at, updated_by
              FROM shared.spend_budget WHERE updated_by IS DISTINCT FROM 'migration-340-aa1025') b;
    IF sig_after IS DISTINCT FROM current_setting('aa.m340_rows_before', true) THEN
        RAISE EXCEPTION 'migration 340: an existing spend_budget row changed';
    END IF;

    SELECT string_agg(provider || '/' || scope, ', ') INTO bad
      FROM shared.spend_budget
     WHERE updated_by = 'migration-340-aa1025'
       AND NOT (provider = 'llm' AND scope = 'app:cis' AND NOT hard_stop AND per_day_usd > 0
                AND per_run_usd IS NULL AND per_month_usd IS NULL);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 340: the seed is not one alert-only app:cis daily cap: %', bad;
    END IF;

    RAISE NOTICE 'migration 340: central LLM scopes on; app:cis seed: %',
        coalesce((SELECT per_day_usd::text || ' USD per day, alert only' FROM shared.spend_budget
                   WHERE provider = 'llm' AND scope = 'app:cis'), '(none: no CIS spend in the last 30 days)');
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('340', now(), 'AA-1025 A7: spend_budget provider llm with scopes app / stage / job / eval / adhoc, '
                      'per_month_usd, alert-only app:cis daily cap seeded from the ledger (T-8)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
