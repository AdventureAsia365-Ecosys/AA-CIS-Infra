-- Migration tp-021: AA-861 — tripplanner.job (ADR 0003a job table template) and the outbox redaction marker.
--
-- Owner: AA-TripPlanner-Web (key tp-NNN). A byte-identical copy goes to AA-CIS-Infra
-- db/migrations/tripplanner/021_job_table_outbox_redaction.sql and is applied to Dev by the DB Migrate workflow
-- (check, then apply), as tp_owner (the live owner of schema tripplanner since tp-013, XD8). Never run it from a
-- laptop.
--
-- Why. tripplanner.outbox.payload keeps the traveller's contact data (inquiry.submitted: name, email, phone, the
-- signed-in identity, custom day notes) forever. Data standards DM-6.6 / DM-7.2 (window approved in E3): the payload
-- PII is redacted after 90 days by an owner-run TTL job kind in the owner's own job table; the row, its
-- idempotency_key and schema_version stay, so AA-Booking's dedupe (booking.inbox_events, keyed by idempotency_key)
-- keeps working. TripPlanner had no job table: ADR 0003a decision 4 says it creates tripplanner.job from the shared
-- DDL template before its first deferred kind, and runs its worker as a scheduled Lambda (no ECS worker). The first
-- kind is tp_retention_outbox_redact (AA-861, code in a later PR).
--
-- What (additive only; nothing reads the new objects until the AA-861 code deploy):
--   1. tripplanner.job, rendered from AA-CIS-App shared/jobs/job_table_template.sql (byte copy in
--      migrations/tests/job_template/, compared by test_tp021_pg.py): kind pattern '^tp_[a-z0-9_]+$' (owners.yaml
--      job_kind_prefix tp_), statuses queued/running/succeeded/failed/cancelled, max_attempts default 5 (as Booking
--      and the CRM), every template index, the updated_at trigger (its function not executable by PUBLIC) and the
--      high-churn autovacuum settings. The runtime role tripplanner gets SELECT, INSERT, UPDATE, DELETE through the
--      tp_owner default privileges (tp-013), restated here. Job payloads and results carry ids and counts only
--      (DM-6.3). Retention: data standards §7 row "booking.job, crm.job (and every <schema>.job)".
--   2. tripplanner.outbox.redacted_at (nullable, no default: metadata-only) marks a row whose payload the redaction
--      kind rebuilt; the partial index outbox_redact_due_idx (created_at, id) WHERE redacted_at IS NULL is the
--      kind's keyset walk (oldest first). The table comment is restated: the owner's redaction is the one UPDATE.
--   3. Register tp-021.
--
-- Locks: CREATE TABLE / INDEX on the new, empty job table; ADD COLUMN takes ACCESS EXCLUSIVE on tripplanner.outbox for
-- a metadata-only change (nullable, no default) and the plain CREATE INDEX holds SHARE for the build (a few rows on
-- Dev). The assembly Lambda's send-to-advisor INSERT waits well under a second; DB Migrate's lock_timeout bounds it.
-- v_inquiry_outbox lists its columns, so the new column does not reach AA-Booking.
--
-- Re-runnable (test_replay_twice_pg.py replays every file twice): IF NOT EXISTS everywhere, CREATE OR REPLACE for
-- the trigger function and trigger, repeated grants / revokes / comments, ON CONFLICT DO NOTHING.
-- Undo: a later tp- file (DROP TABLE tripplanner.job; ALTER TABLE tripplanner.outbox DROP COLUMN redacted_at), with
-- `-- migrate: destructive`, after the AA-861 code is gone.

BEGIN;

DO $$
BEGIN
    IF current_user <> 'tp_owner' THEN
        RAISE EXCEPTION 'tp-021: expected to run as tp_owner (live owner of schema tripplanner), running as %', current_user;
    END IF;
END $$;

-- ── 1. tripplanner.job (ADR 0003a template, rendered: schema tripplanner, kind '^tp_[a-z0-9_]+$', 5 attempts) ──
CREATE TABLE IF NOT EXISTS tripplanner.job (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    kind             TEXT NOT NULL,
    payload          JSONB NOT NULL DEFAULT '{}'::jsonb,
    status           TEXT NOT NULL DEFAULT 'queued',
    attempt          INTEGER NOT NULL DEFAULT 0,
    max_attempts     INTEGER NOT NULL DEFAULT 5,
    run_after        TIMESTAMPTZ NOT NULL DEFAULT now(),
    locked_by        TEXT,
    locked_until     TIMESTAMPTZ,
    cancel_requested BOOLEAN NOT NULL DEFAULT false,
    idempotency_key  TEXT,
    progress         JSONB NOT NULL DEFAULT '{}'::jsonb,
    result           JSONB,
    cost_usd         NUMERIC(12, 6) NOT NULL DEFAULT 0,
    error            TEXT,
    parent_job_id    UUID REFERENCES tripplanner.job(id),
    created_by       TEXT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    started_at       TIMESTAMPTZ,
    finished_at      TIMESTAMPTZ,
    CONSTRAINT job_kind_chk     CHECK (kind ~ '^tp_[a-z0-9_]+$'),
    CONSTRAINT job_status_chk   CHECK (status IN ('queued', 'running', 'succeeded', 'failed', 'cancelled')),
    CONSTRAINT job_attempts_chk CHECK (attempt >= 0 AND max_attempts >= 1),
    CONSTRAINT job_lease_chk    CHECK (status <> 'running' OR (locked_by IS NOT NULL AND locked_until IS NOT NULL))
);

-- One job per idempotency key, ever.
CREATE UNIQUE INDEX IF NOT EXISTS job_idempotency_key_uq ON tripplanner.job (idempotency_key) WHERE idempotency_key IS NOT NULL;
-- Claim path: next due queued job.
CREATE INDEX IF NOT EXISTS job_queued_due_idx ON tripplanner.job (run_after, created_at) WHERE status = 'queued';
-- Reaper + per-kind running count.
CREATE INDEX IF NOT EXISTS job_running_idx ON tripplanner.job (kind, locked_until) WHERE status = 'running';
-- Jobs view (latest runs per kind).
CREATE INDEX IF NOT EXISTS job_kind_created_idx ON tripplanner.job (kind, created_at DESC);
CREATE INDEX IF NOT EXISTS job_parent_idx ON tripplanner.job (parent_job_id) WHERE parent_job_id IS NOT NULL;
-- Retention keyset walk (NAM-15, C5.2e).
CREATE INDEX IF NOT EXISTS job_finished_idx ON tripplanner.job (finished_at, id) WHERE finished_at IS NOT NULL;

CREATE OR REPLACE FUNCTION tripplanner.job_set_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION tripplanner.job_set_updated_at() FROM PUBLIC;

CREATE OR REPLACE TRIGGER job_set_updated_at
    BEFORE UPDATE ON tripplanner.job
    FOR EACH ROW EXECUTE FUNCTION tripplanner.job_set_updated_at();

-- High-churn queue, C5.1b as amended by AA-751.
ALTER TABLE tripplanner.job SET (autovacuum_vacuum_scale_factor = 0.02, autovacuum_vacuum_threshold = 50);

-- The tp_owner default privileges (tp-013) already give these; restated so the file states the runtime's rights.
GRANT SELECT, INSERT, UPDATE, DELETE ON tripplanner.job TO tripplanner;

COMMENT ON TABLE tripplanner.job IS
    'tp-021 (AA-861): the TripPlanner job queue (ADR 0003a template, kinds tp_*), written and claimed only by the TripPlanner jobs Lambda (role tripplanner). Retention: data standards §7 row "booking.job, crm.job (and every <schema>.job)".';
COMMENT ON COLUMN tripplanner.job.payload IS
    'ids, flags and counts only, never personal data (DM-6.3)';
COMMENT ON COLUMN tripplanner.job.result IS
    'ids and counts only, never personal data (DM-6.3)';
COMMENT ON COLUMN tripplanner.job.error IS
    'error class and a fixed message only, never personal data or a message echoing a payload (DM-6.3)';

-- ── 2. The outbox redaction marker ──────────────────────────────────────────────────────────────────
ALTER TABLE tripplanner.outbox ADD COLUMN IF NOT EXISTS redacted_at timestamptz;

CREATE INDEX IF NOT EXISTS outbox_redact_due_idx ON tripplanner.outbox (created_at, id) WHERE redacted_at IS NULL;

COMMENT ON TABLE tripplanner.outbox IS
    'AA-676: append-only transactional outbox. Consumers read v_inquiry_outbox and keep their own cursor/inbox; never UPDATE/DELETE here. tp-021 (AA-861): the one exception is the owner''s redaction kind tp_retention_outbox_redact, which rebuilds payload from an allowlist after 90 days (DM-6.6) and sets redacted_at; the row, idempotency_key and schema_version stay.';
COMMENT ON COLUMN tripplanner.outbox.redacted_at IS
    'tp-021 (AA-861): when tp_retention_outbox_redact rebuilt payload without personal data (DM-6.6); NULL = not redacted yet.';

-- ── Guard: ownership and the runtime's rights, by shape ─────────────────────────────────────────────
DO $$
DECLARE
    p text;
BEGIN
    IF (SELECT tableowner FROM pg_catalog.pg_tables WHERE schemaname = 'tripplanner' AND tablename = 'job')
           IS DISTINCT FROM 'tp_owner' THEN
        RAISE EXCEPTION 'tp-021: tripplanner.job must be owned by tp_owner';
    END IF;
    FOREACH p IN ARRAY ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'] LOOP
        IF NOT pg_catalog.has_table_privilege('tripplanner', 'tripplanner.job', p) THEN
            RAISE EXCEPTION 'tp-021: role tripplanner lacks % on tripplanner.job', p;
        END IF;
    END LOOP;
    IF NOT pg_catalog.has_column_privilege('tripplanner', 'tripplanner.outbox', 'redacted_at', 'UPDATE') THEN
        RAISE EXCEPTION 'tp-021: role tripplanner cannot UPDATE tripplanner.outbox.redacted_at';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('tp-021', now(), 'AA-861: tripplanner.job (ADR 0003a template) + outbox.redacted_at and its redaction index')
ON CONFLICT (version) DO NOTHING;

COMMIT;
