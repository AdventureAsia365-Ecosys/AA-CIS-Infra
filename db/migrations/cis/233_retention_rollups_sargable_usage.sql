-- Migration 233: AA-825 (S237, decision E3) — sargable shared.v_tenant_monthly_usage, retention
-- indexes, and the two rollup tables the TTL job kinds write before raw rows expire.
--
-- Problem (S237 data review P5/N4). No log table is retained or rolled up: shared.decision_log
-- ~314k rows, shared.llm_call_log ~244k (5x in 10 days), shared.tenant_api_usage ~113k (+8.5k/day).
-- v_tenant_monthly_usage (migration 223) filters `date_trunc('month', called_at) = date_trunc(
-- 'month', now())` twice per tenant, so no index on called_at can be used and the admin billing /
-- tenant list pages get slower every day.
--
-- 1. Indexes (data standards C5.2e: every retention / range column is indexed):
--      shared.tenant_api_usage (tenant_id, called_at)  — the view's per-tenant month range
--      shared.llm_call_log     (created_at, id)        — TTL keyset; only (stage|tenant|model,
--                                                        created_at) composites exist today
--      shared.decision_log     (created_at, id)        — TTL keyset
--      shared.job              (finished_at, id) WHERE finished_at IS NOT NULL — job TTL
--    Plain CREATE INDEX, not CONCURRENTLY: AA-CIS-Infra db/run_migration.py sends the whole file as
--    one simple-protocol query, which Postgres runs as an implicit transaction block, and CREATE
--    INDEX CONCURRENTLY refuses to run inside one (205 was applied by hand for that reason). A
--    plain build takes a SHARE lock: reads go on, INSERTs into that table wait for the build
--    (about 1-3 s each at today's sizes on db.t3.micro). lock_timeout 5 s makes the file fail
--    cleanly (whole transaction rolls back, re-run later) instead of queueing behind a long
--    transaction and blocking every writer behind it.
-- 2. Autovacuum for append-only ledgers (C5.1c): insert scale factor 0.05, analyze 0.02, so the
--    visibility map and stats stay fresh as the TTL deletes start. SHARE UPDATE EXCLUSIVE lock only.
-- 3. shared.tenant_api_usage.called_at SET NOT NULL (C5.2e: a NULL timestamp never ages out).
--    Only when no NULL row exists: the writer (shared/services/billing_service.py) always sets it
--    and the column defaults to now(), so none is expected. If one exists the column stays
--    nullable, a NOTICE is raised, and the TTL job reports those rows instead of deleting them.
-- 4. shared.llm_call_daily — daily rollup of llm_call_log (DM-7: by day, app, stage, role, model,
--    tenant; + provider, account, shadow flag so every cost page can be answered from it).
--    `app` = quality_signal->>'app', 'cis' when absent, until AA-804 adds a real column.
-- 5. shared.tenant_api_usage_monthly — monthly rollup per tenant and actor_type (DM-7: 90 days raw
--    + monthly rollup, kept). Admin traffic rows have tenant_id NULL, hence NULLS NOT DISTINCT.
--    Both rollups are written ONLY by the retention job kinds (services/retention/rollups.py),
--    always before the raw rows they summarise are deleted (DM-7.4). Days / months are UTC.
--    No FK to shared.tenants: the rollup is history and must outlive an offboarded tenant.
-- 6. shared.v_tenant_monthly_usage — same 16 columns, same expressions, same numbers; the three
--    `date_trunc('month', col) = date_trunc('month', now())` filters become
--    `col >= date_trunc('month', now()) AND col < date_trunc('month', now()) + interval '1 month'`
--    (identical set of rows in the session time zone; NULL timestamps match neither form), which
--    the new (tenant_id, called_at) index serves. DROP + CREATE (no CASCADE) like 223; the plain
--    DROP fails loudly if a dependent object appeared. Owner-only ACL as before (no GRANT).
--    The rebuild runs inside a DO block that skips it (NOTICE) only when
--    gold_aa_internal.tenant_tour_versions does not exist, which is the CI test DB alone; there
--    the rest of the file (indexes, rollup tables) still applies, so the retention tests run.
--
-- Rollback (if ever needed): re-run the view section of 223; DROP the two rollup tables and the
-- four indexes; ALTER TABLE ... RESET (autovacuum_...); ALTER COLUMN called_at DROP NOT NULL.
--
-- Applied on Dev via the AA-CIS-Infra "DB Migrate" workflow (identical copy in db/migrations/cis/),
-- S237 D8: this migration-only PR merges first, then the Infra copy, check, apply, and only then
-- the AA-825 code PR (retention job kinds) that writes the rollup tables.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '300s';

-- 1 ── indexes ────────────────────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS tenant_api_usage_tenant_called_idx
    ON shared.tenant_api_usage (tenant_id, called_at);
CREATE INDEX IF NOT EXISTS llm_call_log_created_id_idx
    ON shared.llm_call_log (created_at, id);
CREATE INDEX IF NOT EXISTS decision_log_created_id_idx
    ON shared.decision_log (created_at, id);
CREATE INDEX IF NOT EXISTS job_finished_idx
    ON shared.job (finished_at, id) WHERE finished_at IS NOT NULL;

-- 2 ── autovacuum for append-only ledgers (C5.1c) ─────────────────────────────────────────────
ALTER TABLE shared.llm_call_log
    SET (autovacuum_vacuum_insert_scale_factor = 0.05, autovacuum_analyze_scale_factor = 0.02);
ALTER TABLE shared.decision_log
    SET (autovacuum_vacuum_insert_scale_factor = 0.05, autovacuum_analyze_scale_factor = 0.02);
ALTER TABLE shared.tenant_api_usage
    SET (autovacuum_vacuum_insert_scale_factor = 0.05, autovacuum_analyze_scale_factor = 0.02);

-- 3 ── tenant_api_usage.called_at NOT NULL (only when no NULL row exists) ─────────────────────
DO $$
DECLARE
    n_null BIGINT;
BEGIN
    SELECT count(*) INTO n_null FROM shared.tenant_api_usage WHERE called_at IS NULL;
    IF n_null = 0 THEN
        ALTER TABLE shared.tenant_api_usage ALTER COLUMN called_at SET NOT NULL;
    ELSE
        RAISE NOTICE 'AA-825: % shared.tenant_api_usage rows have called_at NULL; column left nullable', n_null;
    END IF;
END $$;

-- 4 ── shared.llm_call_daily ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shared.llm_call_daily (
    day             DATE        NOT NULL,
    app             TEXT        NOT NULL,
    tenant_id       UUID,
    stage           TEXT        NOT NULL,
    role            TEXT        NOT NULL,
    model           TEXT        NOT NULL,
    provider        TEXT,
    account         TEXT,
    is_shadow       BOOLEAN     NOT NULL,
    calls           BIGINT      NOT NULL,
    fallback_calls  BIGINT      NOT NULL DEFAULT 0,
    tokens_in       BIGINT      NOT NULL DEFAULT 0,
    tokens_out      BIGINT      NOT NULL DEFAULT 0,
    cost_usd        NUMERIC     NOT NULL DEFAULT 0,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT llm_call_daily_key
        UNIQUE NULLS NOT DISTINCT (day, app, tenant_id, stage, role, model, provider, account, is_shadow)
);
CREATE INDEX IF NOT EXISTS llm_call_daily_tenant_day_idx ON shared.llm_call_daily (tenant_id, day);

COMMENT ON TABLE shared.llm_call_daily IS
    'AA-825 — daily (UTC) rollup of shared.llm_call_log, kept after the 180-day raw window (DM-7). '
    'Written only by the retention_llm_call_log job kind, before raw rows are deleted. app = '
    'quality_signal->>''app'' (cis when absent); is_shadow = quality_signal @> {"shadow": true}.';

-- 5 ── shared.tenant_api_usage_monthly ────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shared.tenant_api_usage_monthly (
    month               DATE        NOT NULL,
    tenant_id           UUID,
    actor_type          TEXT        NOT NULL,
    calls               BIGINT      NOT NULL,
    ok_calls            BIGINT      NOT NULL,
    rate_limited_calls  BIGINT      NOT NULL,
    server_error_calls  BIGINT      NOT NULL,
    response_ms_sum     BIGINT      NOT NULL DEFAULT 0,
    response_ms_count   BIGINT      NOT NULL DEFAULT 0,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT tenant_api_usage_monthly_key UNIQUE NULLS NOT DISTINCT (month, tenant_id, actor_type),
    CONSTRAINT tenant_api_usage_monthly_first_day CHECK (extract(day FROM month) = 1)
);
CREATE INDEX IF NOT EXISTS tenant_api_usage_monthly_tenant_idx
    ON shared.tenant_api_usage_monthly (tenant_id, month);

COMMENT ON TABLE shared.tenant_api_usage_monthly IS
    'AA-825 — monthly (UTC) rollup of shared.tenant_api_usage per tenant and actor_type, kept after '
    'the 90-day raw window (DM-7). Closed months only, written once by the retention_tenant_api_usage '
    'job kind before raw rows are deleted. ok_calls = status < 400, rate_limited_calls = 429, '
    'server_error_calls = status >= 500; avg response = response_ms_sum / response_ms_count.';

-- 6 ── the view, sargable ─────────────────────────────────────────────────────────────────────
-- Skipped (NOTICE) only where gold_aa_internal.tenant_tour_versions does not exist: the CI test DB,
-- where no repo migration creates it (see test_aa798 / test_aa825). On Dev it exists, so the view
-- is always rebuilt there; verify after apply with pg_get_viewdef (rollout step in the PR).
DO $mig$
DECLARE
    got TEXT;
BEGIN
    IF to_regclass('gold_aa_internal.tenant_tour_versions') IS NULL THEN
        RAISE NOTICE 'AA-825: gold_aa_internal.tenant_tour_versions is absent; v_tenant_monthly_usage left as is';
        RETURN;
    END IF;

    DROP VIEW IF EXISTS shared.v_tenant_monthly_usage;

    EXECUTE $view$
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
               AND tau.called_at >= date_trunc('month'::text, now())
               AND tau.called_at < date_trunc('month'::text, now()) + interval '1 month') AS api_calls_used,
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
                               AND tau2.called_at >= date_trunc('month'::text, now())
                               AND tau2.called_at < date_trunc('month'::text, now()) + interval '1 month'))
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
            AND ttv.created_at >= date_trunc('month'::text, now())
            AND ttv.created_at < date_trunc('month'::text, now()) + interval '1 month'
     GROUP BY t.tenant_id, t.name, t.plan_tier, t.slug, mp.tours_quota_monthly,
              mp.api_calls_quota_monthly, mp.price_usd_monthly, mp.overage_rate_usd_per_tour
    $view$;

    EXECUTE $c$
    COMMENT ON VIEW shared.v_tenant_monthly_usage IS
        'Per-tenant usage for the current billing month (one row per tenant): plan quotas from '
        'membership_plans, tours rewritten, API calls, quota %, overage, and real LLM cost. '
        'Baseline-captured from the live definition in migration 223 (AA-798); month filters made '
        'sargable (range on the raw column) in migration 233 (AA-825).'
    $c$;
    EXECUTE $c$
    COMMENT ON COLUMN shared.v_tenant_monthly_usage.llm_cost_usd IS
        'AA-798 — SUM(shared.llm_call_log.cost_usd) for this tenant_id this calendar month, Jev '
        'included, shadow rows (quality_signal.shadow = true) excluded. Admin-only: never in a '
        'tenant API response.'
    $c$;

    -- Fail the migration if the view lost a column or changed the column order.
    SELECT string_agg(column_name, ',' ORDER BY ordinal_position) INTO got
      FROM information_schema.columns
     WHERE table_schema = 'shared' AND table_name = 'v_tenant_monthly_usage';
    IF got IS DISTINCT FROM
       'tenant_id,tenant_name,plan_tier,slug,tours_quota_monthly,api_calls_quota_monthly,'
       'price_usd_monthly,overage_rate_usd_per_tour,billing_month,tours_rewritten,api_calls_used,'
       'quota_tours_pct,quota_calls_pct,tours_overage,overage_usd,llm_cost_usd' THEN
        RAISE EXCEPTION 'AA-825: v_tenant_monthly_usage columns differ from the live shape: %', got;
    END IF;
END $mig$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('233', now(), 'AA-825: sargable v_tenant_monthly_usage + (tenant_id, called_at) index, '
        'retention indexes, ledger autovacuum, shared.llm_call_daily + shared.tenant_api_usage_monthly rollups')
ON CONFLICT (version) DO NOTHING;

COMMIT;
