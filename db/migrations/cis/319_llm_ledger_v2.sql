-- Migration 319: AA-804 (AI gateway v2, ledger v2; root ADR 0009 §8) — one ledger row per attempt, with its outcome.
--
-- Why. shared.llm_call_log had a row only for a call that was billed: a call the provider refused (Bedrock "Error 002",
-- a missing key, a spend cap), one the gateway refused itself (open circuit, connection budget, data scope) or one that
-- failed (outage, timeout) left nothing, so the ledger could not say how often a route failed or why. app, shadow and
-- eval runs lived only in quality_signal; latency, the connection, the deployment, the attempt position, the request
-- id, the tour, reasoning tokens and effort were not stored at all. The other paid-provider ledgers (Jev in
-- shared.decision_log, DataForSEO in shared.dfs_call_log, Geoapify in geo.geocode_call) had no outcome, latency, app
-- or tenant either. The code PR that follows writes these columns: the gateway writes its own row (cost 0, status,
-- error_class, latency) for every refused or failed attempt, callers keep writing the success row (one per success),
-- Jev / DataForSEO / Geoapify failures and budget refusals get rows, and an S1 Bedrock Batch ingest writes one row per
-- record (AA-642 S7, ledger part).
--
-- What.
--   1. shared.llm_call_log: 17 nullable columns, no default (a catalog-only ADD COLUMN, no table rewrite):
--      app, status, error_class, latency_ms, connection_key, deployment_wire_id, attempt_no, request_id, tour_id,
--      reasoning_tokens, effort, is_shadow, is_experiment, prompt_hash, prompt_version, units, unit_kind.
--      NULL = not said (every row before 319, and TripPlanner's rows: its INSERT names its columns). No backfill:
--      readers use coalesce(app, quality_signal->>'app', 'cis') and coalesce(is_shadow, quality_signal shadow flag).
--      CHECKs, added NOT VALID then validated (every existing row is NULL in these columns):
--        status IN ('ok', 'refused', 'error', 'billed_unusable', 'truncated');
--        error_class IN the provider-health classes (access_denied, quota_exhausted, throttled, credential, other,
--          shared.llm_provider_health, migration 309) plus deadline, budget and truncated;
--        latency_ms >= 0; attempt_no >= 1.
--      The role CHECK is widened to writer | judge | validate | embed | decide | data | guard (ADR 0009 provider
--      kinds; today's rows keep their roles). No provider CHECK: TripPlanner writes free provider values.
--      Indexes: tour_id (partial, NOT NULL) for the tour trace; (status, created_at DESC) WHERE status <> 'ok' for the
--      "refused / failed attempts" views (NULL and 'ok' rows are not in it).
--   2. shared.decision_log: index (job_id) WHERE job_id IS NOT NULL, for the job trace (there was none).
--   3. shared.dfs_call_log: status, latency_ms, error, stage, app (nullable; a failed call and a budget refusal now
--      write a row with cost 0).
--   4. geo.geocode_call: tenant_id (the job's tenant, NULL = platform), failed_requests (the HTTP requests of the run
--      that did not answer; each still spent a credit).
--   5. shared.llm_call_daily (rollup, AA-825): refused_calls, error_calls, latency_ms_sum, latency_ms_count, bigint NOT
--      NULL DEFAULT 0 (a constant default: no rewrite). calls stays the count of every row of the group (attempts
--      included); latency_ms_sum / latency_ms_count is the mean over the rows that have a latency.
--   6. Register 319.
--   Grants unchanged: cis_app has table-level SELECT / INSERT / UPDATE / DELETE on all five tables; tripplanner INSERT
--   on llm_call_log (it names its columns and writes NULL here).
--
-- Class: contract (root ADR 0017 d3), so no "-- migrate: expand" header: new CHECK constraints and a replaced one on
-- existing tables, ADD COLUMN on the ledger hot tables, and plain CREATE INDEX on llm_call_log (~384k rows) and
-- decision_log (~428k rows), above the expand runner's 100k-row threshold (MIG-10). CREATE INDEX CONCURRENTLY cannot
-- run inside the DB Migrate transaction; the plain build holds a SHARE lock (writes wait) for seconds on these sizes,
-- so apply with every job table idle (DB Migrate's idle wait does that). lock_timeout bounds the wait for each lock.
-- Order (ADR 0017 d1, MIG-4): (1) this migration-only PR merges to AA-CIS-App main; (2) the byte copy in
-- AA-CIS-Infra db/migrations/cis/ merges (Copy Guard green); (3) a manual DB Migrate apply (check, then apply);
-- (4) the bot/db-schema-reference PR merges; (5) only then the AA-804 ledger v2 code PR merges (it raises the
-- readiness requirement to 319).
-- Number: 318 is the AA-642 S0 seed file (separate PR); renumber at merge if a parallel PR takes 319 (file name, this
-- header, the registration below, the integration test).
--
-- Rollback (a NEW forward migration, after the code is reverted; the old code ignores every column added here):
--   DROP INDEX shared.llm_call_log_tour_idx, shared.llm_call_log_status_created_idx, shared.decision_log_job_idx;
--   restore llm_call_log_role_check to (writer, judge, validate, embed) once no row uses a new role;
--   ALTER TABLE ... DROP COLUMN for the columns above                              (a destructive file)
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/ (DB Migrate workflow); keep the two
-- byte-identical. After apply: regenerate docs/architecture/db-schema-reference.md (DB Schema Dump workflow).
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of every table here.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF to_regclass('shared.llm_call_log') IS NULL OR to_regclass('shared.llm_call_daily') IS NULL
       OR to_regclass('shared.decision_log') IS NULL OR to_regclass('shared.dfs_call_log') IS NULL
       OR to_regclass('geo.geocode_call') IS NULL THEN
        RAISE EXCEPTION 'migration 319: a ledger table is missing (llm_call_log, llm_call_daily, decision_log, '
                        'dfs_call_log, geo.geocode_call)';
    END IF;
END $$;

-- ── 1. shared.llm_call_log ───────────────────────────────────────────────────────────────────────────────────────

ALTER TABLE shared.llm_call_log
    ADD COLUMN IF NOT EXISTS app                text,
    ADD COLUMN IF NOT EXISTS status             text,
    ADD COLUMN IF NOT EXISTS error_class        text,
    ADD COLUMN IF NOT EXISTS latency_ms         integer,
    ADD COLUMN IF NOT EXISTS connection_key     text,
    ADD COLUMN IF NOT EXISTS deployment_wire_id text,
    ADD COLUMN IF NOT EXISTS attempt_no         integer,
    ADD COLUMN IF NOT EXISTS request_id         text,
    ADD COLUMN IF NOT EXISTS tour_id            uuid,
    ADD COLUMN IF NOT EXISTS reasoning_tokens   integer,
    ADD COLUMN IF NOT EXISTS effort             text,
    ADD COLUMN IF NOT EXISTS is_shadow          boolean,
    ADD COLUMN IF NOT EXISTS is_experiment      boolean,
    ADD COLUMN IF NOT EXISTS prompt_hash        text,
    ADD COLUMN IF NOT EXISTS prompt_version     text,
    ADD COLUMN IF NOT EXISTS units              integer,
    ADD COLUMN IF NOT EXISTS unit_kind          text;

COMMENT ON COLUMN shared.llm_call_log.app IS
    'AA-804: the app that made the call (cis, tripplanner, ...). NULL = not said: read coalesce(app, quality_signal->>''app'', ''cis'').';
COMMENT ON COLUMN shared.llm_call_log.status IS
    'AA-804: ok | refused (provider or gateway said no, nothing billed) | error (failed, nothing billed) | billed_unusable | truncated. NULL = before 319 or not said (a billed call).';
COMMENT ON COLUMN shared.llm_call_log.error_class IS
    'AA-804: why a refused / failed attempt failed: access_denied | quota_exhausted | throttled | credential | other | deadline | budget | truncated.';
COMMENT ON COLUMN shared.llm_call_log.latency_ms IS
    'AA-804: wall time of the attempt in the gateway (ms), the provider call and its SDK retries included.';
COMMENT ON COLUMN shared.llm_call_log.connection_key IS
    'AA-804: shared.llm_provider_connection key of the attempt (account keeps the AWS account or the vendor connection, as before).';
COMMENT ON COLUMN shared.llm_call_log.deployment_wire_id IS
    'AA-804: the model id sent on the wire (shared.llm_model_deployment.wire_id or the legacy profile id).';
COMMENT ON COLUMN shared.llm_call_log.attempt_no IS
    'AA-804: 1-based position of the attempt among the provider attempts of one gateway request (route fallbacks and deployments).';
COMMENT ON COLUMN shared.llm_call_log.request_id IS
    'AA-804: the provider''s request id (Bedrock RequestId, Anthropic request-id, OpenAI x-request-id), when it gave one.';
COMMENT ON COLUMN shared.llm_call_log.tour_id IS
    'AA-804: the tour the call worked on, when the caller knows it (silver_aa_internal.raw_tours.tour_id; no FK).';
COMMENT ON COLUMN shared.llm_call_log.reasoning_tokens IS
    'AA-804: reasoning tokens the provider reported (part of tokens_out).';
COMMENT ON COLUMN shared.llm_call_log.effort IS
    'AA-804: the effort level sent (Anthropic effort), when one was.';
COMMENT ON COLUMN shared.llm_call_log.is_shadow IS
    'AA-804: an A/B shadow call. NULL = before 319: read coalesce(is_shadow, quality_signal @> ''{"shadow": true}'').';
COMMENT ON COLUMN shared.llm_call_log.is_experiment IS
    'AA-804: an eval / experiment run (writing-memory eval label, AA-729 harness), not production traffic.';
COMMENT ON COLUMN shared.llm_call_log.prompt_hash IS
    'AA-804: sha256 hex of the system and user prompt of the request (not the prompt itself).';
COMMENT ON COLUMN shared.llm_call_log.prompt_version IS
    'AA-804: the prompt version the caller states (AA-900 prompt registry), when it does.';
COMMENT ON COLUMN shared.llm_call_log.units IS
    'AA-804: billed units that are not tokens (Jev questions, batch records), with unit_kind.';
COMMENT ON COLUMN shared.llm_call_log.unit_kind IS
    'AA-804: what units counts (question, record, ...).';

DO $$
DECLARE
    role_def text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'llm_call_log_status_check'
                      AND conrelid = 'shared.llm_call_log'::regclass) THEN
        ALTER TABLE shared.llm_call_log ADD CONSTRAINT llm_call_log_status_check CHECK (
            status IS NULL OR status IN ('ok', 'refused', 'error', 'billed_unusable', 'truncated')) NOT VALID;
        ALTER TABLE shared.llm_call_log VALIDATE CONSTRAINT llm_call_log_status_check;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'llm_call_log_error_class_check'
                      AND conrelid = 'shared.llm_call_log'::regclass) THEN
        ALTER TABLE shared.llm_call_log ADD CONSTRAINT llm_call_log_error_class_check CHECK (
            error_class IS NULL OR error_class IN ('access_denied', 'quota_exhausted', 'throttled', 'credential',
                                                   'other', 'deadline', 'budget', 'truncated')) NOT VALID;
        ALTER TABLE shared.llm_call_log VALIDATE CONSTRAINT llm_call_log_error_class_check;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'llm_call_log_latency_ms_check'
                      AND conrelid = 'shared.llm_call_log'::regclass) THEN
        ALTER TABLE shared.llm_call_log ADD CONSTRAINT llm_call_log_latency_ms_check CHECK (
            latency_ms IS NULL OR latency_ms >= 0) NOT VALID;
        ALTER TABLE shared.llm_call_log VALIDATE CONSTRAINT llm_call_log_latency_ms_check;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'llm_call_log_attempt_no_check'
                      AND conrelid = 'shared.llm_call_log'::regclass) THEN
        ALTER TABLE shared.llm_call_log ADD CONSTRAINT llm_call_log_attempt_no_check CHECK (
            attempt_no IS NULL OR attempt_no >= 1) NOT VALID;
        ALTER TABLE shared.llm_call_log VALIDATE CONSTRAINT llm_call_log_attempt_no_check;
    END IF;

    -- The role CHECK of migration 172 (writer, judge, validate, embed), widened to the ADR 0009 kinds. Replaced only
    -- when it does not list 'decide' yet, so a re-run changes nothing.
    SELECT pg_get_constraintdef(oid) INTO role_def FROM pg_constraint
     WHERE conname = 'llm_call_log_role_check' AND conrelid = 'shared.llm_call_log'::regclass;
    IF role_def IS NULL OR position('decide' IN role_def) = 0 THEN
        ALTER TABLE shared.llm_call_log DROP CONSTRAINT IF EXISTS llm_call_log_role_check;
        ALTER TABLE shared.llm_call_log ADD CONSTRAINT llm_call_log_role_check CHECK (
            role IN ('writer', 'judge', 'validate', 'embed', 'decide', 'data', 'guard')) NOT VALID;
        ALTER TABLE shared.llm_call_log VALIDATE CONSTRAINT llm_call_log_role_check;
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS llm_call_log_tour_idx
    ON shared.llm_call_log (tour_id) WHERE tour_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS llm_call_log_status_created_idx
    ON shared.llm_call_log (status, created_at DESC) WHERE status <> 'ok';

-- ── 2. shared.decision_log ───────────────────────────────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS decision_log_job_idx
    ON shared.decision_log (job_id) WHERE job_id IS NOT NULL;

-- ── 3. shared.dfs_call_log ───────────────────────────────────────────────────────────────────────────────────────

ALTER TABLE shared.dfs_call_log
    ADD COLUMN IF NOT EXISTS status     text,
    ADD COLUMN IF NOT EXISTS latency_ms integer,
    ADD COLUMN IF NOT EXISTS error      text,
    ADD COLUMN IF NOT EXISTS stage      text,
    ADD COLUMN IF NOT EXISTS app        text;

COMMENT ON COLUMN shared.dfs_call_log.status IS
    'AA-804: ok | refused (budget stop, auth or payment refusal: nothing billed) | error (the call failed). NULL = before 319 (a cache hit or a live call).';
COMMENT ON COLUMN shared.dfs_call_log.latency_ms IS
    'AA-804: wall time of the live HTTP call (ms). NULL for a cache hit or a refusal before the call.';
COMMENT ON COLUMN shared.dfs_call_log.error IS
    'AA-804: why a refused / failed call did not answer (no credential, no URL).';
COMMENT ON COLUMN shared.dfs_call_log.stage IS
    'AA-804: the pipeline stage that asked, when the caller says.';
COMMENT ON COLUMN shared.dfs_call_log.app IS
    'AA-804: the app that made the call. NULL = cis (before 319).';

-- ── 4. geo.geocode_call ──────────────────────────────────────────────────────────────────────────────────────────

ALTER TABLE geo.geocode_call
    ADD COLUMN IF NOT EXISTS tenant_id       uuid,
    ADD COLUMN IF NOT EXISTS failed_requests integer;

COMMENT ON COLUMN geo.geocode_call.tenant_id IS
    'AA-804: the tenant of the job that made the requests. NULL = platform content.';
COMMENT ON COLUMN geo.geocode_call.failed_requests IS
    'AA-804: requests of the run that did not answer (HTTP error, transport error; part of requests, each still a credit). NULL = before 319.';

-- ── 5. shared.llm_call_daily ─────────────────────────────────────────────────────────────────────────────────────

ALTER TABLE shared.llm_call_daily
    ADD COLUMN IF NOT EXISTS refused_calls    bigint NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS error_calls      bigint NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS latency_ms_sum   bigint NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS latency_ms_count bigint NOT NULL DEFAULT 0;

COMMENT ON COLUMN shared.llm_call_daily.refused_calls IS
    'AA-804: rows of the group with status refused (part of calls, cost 0).';
COMMENT ON COLUMN shared.llm_call_daily.error_calls IS
    'AA-804: rows of the group with status error (part of calls, cost 0).';
COMMENT ON COLUMN shared.llm_call_daily.latency_ms_sum IS
    'AA-804: sum of latency_ms over the rows that have one (mean = latency_ms_sum / latency_ms_count).';
COMMENT ON COLUMN shared.llm_call_daily.latency_ms_count IS
    'AA-804: rows of the group that have a latency_ms.';

-- ── 6. register ──────────────────────────────────────────────────────────────────────────────────────────────────

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('319', now(), 'AA-804: ledger v2 (llm_call_log attempt columns + CHECKs + indexes, decision_log job index, '
                      'dfs_call_log outcome, geocode_call tenant + failed requests, llm_call_daily outcome sums)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
