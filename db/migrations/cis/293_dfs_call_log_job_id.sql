-- Migration 293: AA-665 C2 — attribute DataForSEO spend to the durable job that caused it.
--
-- Why. shared.llm_call_log has carried job_id since 177 (the worker binds the job id in a contextvar around each
-- handler, call_log.current_job_id()), but shared.dfs_call_log has only tenant_id / tour_id / meta, and the DFS
-- client never passes meta. "What triggered each DFS run" (the 25/09/2026 spend spike) can therefore only be guessed
-- from time windows. The Cost Operations page (AA-665) groups DFS spend by job (GET /admin/dfs-usage/runs).
--
-- What. shared.dfs_call_log.job_id uuid (NULL for calls made outside a job: request handlers, scripts, Lambdas, and
-- every row written before this file) + a partial index on it. No FK on purpose, same as 177: a log write must never
-- fail because of the job table (fire-and-forget log), and job retention may delete a job its log rows outlive.
-- Additive: no data change, no grant change (cis_app already has INSERT / SELECT on the table; a new column inherits
-- the table grant).
--
-- Order with the code. Apply BEFORE the code deploys: the code's INSERT names this column, and without it every DFS log
-- write fails (the write is fire-and-forget, so the SEO fetch still works, but the cost row is lost). The code PR
-- raises REQUIRED_CIS_SCHEMA to 293 so /health/ready reports a missing apply. Apply through AA-CIS-Infra DB Migrate
-- (byte copy in db/migrations/cis/), after 292.
--
-- Preflight (read-only; expected: 292 registered = 1, column present = 0):
--   SELECT (SELECT count(*) FROM shared.schema_versions WHERE version = '292') AS predecessor,
--          (SELECT count(*) FROM information_schema.columns
--            WHERE table_schema = 'shared' AND table_name = 'dfs_call_log' AND column_name = 'job_id') AS present;
--
-- Rollback (a NEW forward migration, after the code that writes the column is reverted):
--   DROP INDEX shared.idx_dfs_call_log_job;  ALTER TABLE shared.dfs_call_log DROP COLUMN job_id;
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of shared.dfs_call_log.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF to_regclass('shared.dfs_call_log') IS NULL THEN
        RAISE EXCEPTION 'migration 293: shared.dfs_call_log is missing (CIS 154)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '292') THEN
        RAISE NOTICE 'migration 293: 292 is not registered (Dev applies in version order)';
    END IF;
END $$;

ALTER TABLE shared.dfs_call_log
    ADD COLUMN IF NOT EXISTS job_id uuid;

COMMENT ON COLUMN shared.dfs_call_log.job_id IS
    'AA-665 C2 (CIS 293): the shared.job running when the DataForSEO call was made (call_log.current_job_id()); NULL '
    'outside a job and on rows written before 293. No FK (fire-and-forget log, job retention).';

CREATE INDEX IF NOT EXISTS idx_dfs_call_log_job
    ON shared.dfs_call_log (job_id) WHERE job_id IS NOT NULL;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('293', now(), 'AA-665 C2: dfs_call_log.job_id + partial index (DataForSEO spend by job)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
