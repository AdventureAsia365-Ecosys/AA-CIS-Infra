-- Migration bk-013: AA-751 (X6) — booking.job catches up with the job table template
-- (AA-CIS-App shared/jobs/job_table_template.sql; ADR 0003a decisions 2 and 6).
--
-- Owner: AA-Booking (key bk-NNN). A byte-identical copy goes to AA-CIS-Infra db/migrations/booking/013_job_template_catch_up.sql
-- and is applied to Dev by the DB Migrate workflow (check, then apply), as aa_cis_admin. Never run it from a laptop.
--
-- Depends on bk-002 (booking.job) and bk-012 (job_finished_idx, already the template's retention index).
-- Adds the four columns bk-002 left out (cancel_requested, progress, cost_usd, parent_job_id; constant defaults,
-- so no table rewrite on PG 15), the parent index, the template's running index (kind, locked_until) and the
-- template's due-index name, and the queue autovacuum settings (C5.1b as amended by AA-751). progress /
-- cancel_requested are what release-on-shutdown needs (C6.2c). Role booking already has table-level
-- SELECT/INSERT/UPDATE/DELETE on booking.job: no grant change.
-- parent_job_id is a single-column FK onto id, so bk_retention_job's FK guard (app/retention/runner.py fk_refs) picks
-- it up by itself: a job that is some other job's parent is never deleted. ON DELETE is NO ACTION, as on CIS shared.job.
-- Converges: bk-002 re-creates job_due_idx / job_lease_idx with IF NOT EXISTS when every migration is re-run
-- (backend/tests/integration/test_bk001.py); the CREATE IF NOT EXISTS + DROP IF EXISTS pairs below end in the
-- same state after one or two passes. No RENAME, on purpose.
-- Hot-table DDL (C5.2g): DB Migrate refuses apply while any job table is busy.

BEGIN;

SET LOCAL lock_timeout = '5s';

ALTER TABLE booking.job
    ADD COLUMN IF NOT EXISTS cancel_requested BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS progress JSONB NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS cost_usd NUMERIC(12, 6) NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS parent_job_id UUID REFERENCES booking.job(id);

COMMENT ON COLUMN booking.job.cancel_requested IS 'bk-013 (X6): a staff cancel request; never claimed, reaped or released back to queued (cancelled instead).';
COMMENT ON COLUMN booking.job.progress IS 'bk-013 (X6): handler checkpoint / counters; attempt_started_at per claim, releases on shutdown in progress->>''releases''.';
COMMENT ON COLUMN booking.job.cost_usd IS 'bk-013 (X6): external cost of the job, USD (0 when none).';
COMMENT ON COLUMN booking.job.parent_job_id IS 'bk-013 (X6): the job that spawned this one (same table).';

CREATE INDEX IF NOT EXISTS job_parent_idx
    ON booking.job (parent_job_id) WHERE parent_job_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS job_running_idx
    ON booking.job (kind, locked_until) WHERE status = 'running';
CREATE INDEX IF NOT EXISTS job_queued_due_idx
    ON booking.job (run_after, created_at) WHERE status = 'queued';
DROP INDEX IF EXISTS booking.job_lease_idx;
DROP INDEX IF EXISTS booking.job_due_idx;

ALTER TABLE booking.job SET (autovacuum_vacuum_scale_factor = 0.02, autovacuum_vacuum_threshold = 50);

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-013', now(), 'AA-751 (X6): booking.job template catch-up — cancel_requested, progress, cost_usd, parent_job_id (+FK, job_parent_idx), job_running_idx, job_queued_due_idx, queue autovacuum')
ON CONFLICT (version) DO NOTHING;

COMMIT;
