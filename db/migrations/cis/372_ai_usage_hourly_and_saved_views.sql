-- Migration 372: AA-1045 (S268, AI gateway usage analytics explorer) — the hourly usage rollup of every paid-call
-- ledger CIS can read, and the explorer's saved views.
--
-- Why. The business owner wants to see how AI and data providers are used (requests, tokens, cost, latency, errors,
-- fallbacks) by any one or two dimensions over any window, sorted, filtered and exported. The ledgers already hold
-- every call (shared.llm_call_log, shared.decision_log, shared.dfs_call_log, geo.geocode_call), but an aggregate over
-- them per page view gets slower as they grow (llm_call_log ~390k rows, decision_log ~430k rows, 04/11/2026), and
-- shared.llm_call_daily is per day and LLM only. An hourly rollup keeps the page fast and keeps the history past the
-- raw retention window (DM-7.4: readers of history read the rollup).
--
-- What.
--   1. shared.ai_usage_hourly: one row per UTC hour x source x app x provider x account x model x stage x role x
--      tenant x status x error class x traffic (unique key, NULLS NOT DISTINCT), with the summed metrics: requests,
--      ledger rows, fallback answers, input / output / cache read / cache write / reasoning tokens, cost (USD,
--      numeric(18,6): exact sums of the ledgers' numeric costs), latency sum and count, and a latency histogram
--      (integer[20], the bucket bounds in api/services/usage_dims.py LATENCY_BOUNDS_MS) for the p95. Written only by
--      job kind ai_usage_rollup (services/jobs/ai_usage_rollup_job.py): per hour range, DELETE then INSERT ... SELECT
--      from the ledgers in one transaction (idempotent per hour); the schedule re-rolls the last hours, so a late row
--      is counted. source: llm | jev | dfs | geocoder (the CRM's ledger is not readable here; the explorer merges the
--      CRM's daily totals at read time through crm.ops.v1). traffic: live | shadow | experiment.
--   2. shared.ai_usage_saved_view: a named explorer view (the address query, at most 4 kB) per staff member
--      (staff_id = shared.admin_users id, from the verified sign-in; no foreign key, a deactivated member's rows stay
--      until they are deleted), unique per staff member and lower-cased name.
--   3. GRANT cis_app SELECT, INSERT, UPDATE, DELETE on both (the job runs on the worker as cis_app; the api reads the
--      rollup and writes the saved views).
--   4. Register 372.
--
-- Behaviour. None on apply: both tables are empty; nothing reads them until the AA-1045 code PR ships, and that code
-- answers 503 "needs migration 372" (explorer) or skips the job while a table is missing.
--
-- Class: contract (no '-- migrate:' directive). Two new tables, their constraints and indexes, grants on them and
-- comments; no existing object changes. It is not expand because shared.ai_usage_hourly has a tenant_id column
-- with RLS off on purpose (a CIS-only rollup; tenant_id is attribution; X2 allowlist rule a), and the expand
-- classify refuses a new tenant_id table without ENABLE and FORCE ROW LEVEL SECURITY. Applied by hand with DB
-- Migrate (S268). Retention rows (DM-7.1): root data standards Part B section 7, in the root PR of this change
-- (merged before the Infra copy).
--
-- Number. 371 is the highest on main (04/11, after the S268 route control and route policy files). Migration-only PR
-- (no readiness raise: the code tolerates the missing tables).
--
-- Rollback (a new forward migration, after the code is reverted): DROP TABLE shared.ai_usage_saved_view,
-- shared.ai_usage_hourly; (a destructive file, DRY RUN). The rollup can be rebuilt from the ledgers within their raw
-- window (job kind ai_usage_rollup, mode backfill).
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of schema shared.

BEGIN;

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS shared.ai_usage_hourly (
    hour                timestamptz   NOT NULL,
    source              text          NOT NULL,
    app                 text          NOT NULL,
    provider            text          NOT NULL,
    account             text,
    model               text,
    stage               text,
    role                text,
    tenant_id           uuid,
    status              text          NOT NULL,
    error_class         text,
    traffic             text          NOT NULL,
    requests            bigint        NOT NULL DEFAULT 0,
    ledger_rows         bigint        NOT NULL DEFAULT 0,
    fallback_requests   bigint        NOT NULL DEFAULT 0,
    tokens_in           bigint        NOT NULL DEFAULT 0,
    tokens_out          bigint        NOT NULL DEFAULT 0,
    cache_read_tokens   bigint        NOT NULL DEFAULT 0,
    cache_write_tokens  bigint        NOT NULL DEFAULT 0,
    reasoning_tokens    bigint        NOT NULL DEFAULT 0,
    cost_usd            numeric(18,6) NOT NULL DEFAULT 0,
    latency_ms_sum      bigint        NOT NULL DEFAULT 0,
    latency_ms_count    bigint        NOT NULL DEFAULT 0,
    latency_hist        integer[]     NOT NULL,
    refreshed_at        timestamptz   NOT NULL DEFAULT now(),
    CONSTRAINT ai_usage_hourly_hour_check CHECK (hour = date_trunc('hour', hour, 'UTC')),
    CONSTRAINT ai_usage_hourly_source_check CHECK (source IN ('llm', 'jev', 'dfs', 'geocoder')),
    CONSTRAINT ai_usage_hourly_traffic_check CHECK (traffic IN ('live', 'shadow', 'experiment')),
    CONSTRAINT ai_usage_hourly_counts_check CHECK (
        requests >= 0 AND ledger_rows >= 0 AND fallback_requests >= 0 AND tokens_in >= 0 AND tokens_out >= 0
        AND cache_read_tokens >= 0 AND cache_write_tokens >= 0 AND reasoning_tokens >= 0
        AND latency_ms_sum >= 0 AND latency_ms_count >= 0),
    CONSTRAINT ai_usage_hourly_hist_check CHECK (cardinality(latency_hist) = 20)
);

CREATE UNIQUE INDEX IF NOT EXISTS ai_usage_hourly_key
    ON shared.ai_usage_hourly (hour, source, app, provider, account, model, stage, role, tenant_id, status,
                               error_class, traffic) NULLS NOT DISTINCT;
CREATE INDEX IF NOT EXISTS ai_usage_hourly_tenant_hour_idx
    ON shared.ai_usage_hourly (tenant_id, hour) WHERE tenant_id IS NOT NULL;

COMMENT ON TABLE shared.ai_usage_hourly IS
    'AA-1045 (CIS 372): hourly rollup of the paid-call ledgers CIS can read (llm_call_log without Jev''s typesafe '
    'rows, decision_log, dfs_call_log, geo.geocode_call), one row per UTC hour and dimension set. Written only by job '
    'kind ai_usage_rollup (DELETE + INSERT per hour range, idempotent; the schedule re-rolls the last hours for late '
    'rows). Read by /admin/usage-explorer/*. Its totals equal the ledgers'' for the same whole hours '
    '(GET /admin/usage-explorer/rollup/check).';
COMMENT ON COLUMN shared.ai_usage_hourly.hour IS 'AA-1045 (372): the UTC hour the ledger rows were created in.';
COMMENT ON COLUMN shared.ai_usage_hourly.requests IS
    'AA-1045 (372): calls: one per ledger row, except geo.geocode_call where a row is a batch of `requests`.';
COMMENT ON COLUMN shared.ai_usage_hourly.fallback_requests IS
    'AA-1045 (372): answered (status ok) LLM rows served by a fallback: fallback_used, attempt_no > 1 or a gateway '
    'route position > 0 (the route rung rule of the AI gateway trace).';
COMMENT ON COLUMN shared.ai_usage_hourly.latency_hist IS
    'AA-1045 (372): count of rows with a latency per bucket; bucket k holds [bound k-1, bound k) ms with the bounds of '
    'api/services/usage_dims.py LATENCY_BOUNDS_MS (bucket 1 starts at 0, bucket 20 has no upper bound).';

CREATE TABLE IF NOT EXISTS shared.ai_usage_saved_view (
    id          uuid        NOT NULL DEFAULT gen_random_uuid(),
    staff_id    uuid        NOT NULL,
    name        text        NOT NULL,
    query       jsonb       NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ai_usage_saved_view_pkey PRIMARY KEY (id),
    CONSTRAINT ai_usage_saved_view_name_check CHECK (length(btrim(name)) BETWEEN 1 AND 80),
    CONSTRAINT ai_usage_saved_view_query_check CHECK (jsonb_typeof(query) = 'object' AND length(query::text) <= 4096)
);

CREATE UNIQUE INDEX IF NOT EXISTS ai_usage_saved_view_staff_name_uq
    ON shared.ai_usage_saved_view (staff_id, lower(btrim(name)));

COMMENT ON TABLE shared.ai_usage_saved_view IS
    'AA-1045 (CIS 372): the usage explorer''s saved views: a name and the explorer''s address query per staff member '
    '(staff_id = shared.admin_users id of the verified sign-in). Written by POST / DELETE /admin/usage-explorer/views '
    '(the member''s own rows only).';

GRANT SELECT, INSERT, UPDATE, DELETE ON shared.ai_usage_hourly TO cis_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON shared.ai_usage_saved_view TO cis_app;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('372', now(), 'AA-1045: shared.ai_usage_hourly (hourly usage rollup of the paid-call ledgers) and '
                      'shared.ai_usage_saved_view (usage explorer saved views)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
