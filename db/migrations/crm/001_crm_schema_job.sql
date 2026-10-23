-- Migration crm-001: AA-932 (partner CRM, design v3 card CRM-04) — the crm schema's privileges and its job table.
--
-- Owner: AA-Partner (api/migrations/001_crm_schema_job.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- DB Migrate applies (Migration Copy Guard). Key crm-001 (ADR 0008a decision 1, data standards DM-1, MIG-2).
--
-- Why. Infra rl-003 creates crm_owner (NOLOGIN), crm_app (LOGIN, limit 6) and the EMPTY schema crm owned by
-- crm_owner; rl-004 adds the NOLOGIN roles crm_app reaches by SET LOCAL ROLE. DB Migrate runs this file as crm_owner
-- (live owner of the anchor schema crm, XD8), which may register crm- keys from CIS 269. This first file sets the
-- schema's privilege model before any table exists, and creates crm.job (ADR 0003a: one job table per owner, the
-- shared DDL template of AA-CIS-App shared/jobs/job_table_template.sql) so the AA-Partner worker (AA-933) has its
-- queue and the DB Migrate idle check sees it from day one.
--
-- What:
--   1. Privilege model (ADR 0008a decision 1, design v3 §3.1 and §4.3):
--      * REVOKE ALL ON SCHEMA crm FROM PUBLIC; USAGE to crm_app and to the four NOLOGIN roles only. No other app role
--        (cis_app, aa_app_user, booking, tripplanner) gets anything on crm: the isolation probe asserts 42501.
--      * Default privileges FOR ROLE crm_owner: functions are NOT executable by PUBLIC (crm.erase_subject() is for
--        crm_eraser only, design §4.10; every function is granted by name); in schema crm, DML on new tables and
--        USAGE, SELECT on new sequences to crm_app. The NOLOGIN roles get nothing by default: their grants come with
--        the cards that need them, table by table (never on the F1 vault tables).
--   2. crm.job from the ADR 0003a template: kind pattern '^crm_[a-z0-9_]+$' (owners.yaml job_kind_prefix crm_),
--      statuses queued/running/succeeded/failed/cancelled, max_attempts default 5 (as Booking), every template index,
--      the updated_at trigger and the high-churn autovacuum settings. Job payloads carry ids only (DM-6.3); the
--      AA-Partner CI rejects personal-data keys in a payload (CRM-05). Retention: data standards §7 row
--      `crm.job` (succeeded 30 d, failed / cancelled 90 d, queued / running never; the crm_ TTL kinds, AA-933).
--      Kind crm_heartbeat is idle-exempt in DB Migrate (owners.yaml idle_exempt_kinds).
--   No tenant table here: crm.tenant and the base template with RLS and trash columns come with AA-933 (crm-002).
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block (X1 switch shape), no role DDL (roles/ only).
-- Rollback: a forward crm- file (MIG-14); before AA-933 deploys nothing reads crm.job.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '15min';

-- ── Guard 0: the role bootstrap is in place and this file runs as the owner ─────────────────────────
DO $$
DECLARE
    r text;
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-001: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF (SELECT pg_catalog.pg_get_userbyid(nspowner) FROM pg_catalog.pg_namespace WHERE nspname = 'crm')
           IS DISTINCT FROM 'crm_owner' THEN
        RAISE EXCEPTION 'crm-001: schema crm must exist, owned by crm_owner (Infra rl-003)';
    END IF;
    FOREACH r IN ARRAY ARRAY['crm_app', 'crm_ai_reader', 'crm_insights', 'crm_support_reader', 'crm_eraser'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r) THEN
            RAISE EXCEPTION 'crm-001: role % does not exist (Infra rl-003 / rl-004)', r;
        END IF;
    END LOOP;
END $$;

-- ── 1. Privilege model ───────────────────────────────────────────────────────────────────────────
REVOKE ALL ON SCHEMA crm FROM PUBLIC;
GRANT USAGE ON SCHEMA crm TO crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser;

ALTER DEFAULT PRIVILEGES FOR ROLE crm_owner REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE crm_owner IN SCHEMA crm
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO crm_app;
ALTER DEFAULT PRIVILEGES FOR ROLE crm_owner IN SCHEMA crm
    GRANT USAGE, SELECT ON SEQUENCES TO crm_app;

-- ── 2. crm.job (ADR 0003a template, rendered: schema crm, kind '^crm_[a-z0-9_]+$', no extra status, 5 attempts) ──
CREATE TABLE IF NOT EXISTS crm.job (
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
    parent_job_id    UUID REFERENCES crm.job(id),
    created_by       TEXT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    started_at       TIMESTAMPTZ,
    finished_at      TIMESTAMPTZ,
    CONSTRAINT job_kind_chk     CHECK (kind ~ '^crm_[a-z0-9_]+$'),
    CONSTRAINT job_status_chk   CHECK (status IN ('queued', 'running', 'succeeded', 'failed', 'cancelled')),
    CONSTRAINT job_attempts_chk CHECK (attempt >= 0 AND max_attempts >= 1),
    CONSTRAINT job_lease_chk    CHECK (status <> 'running' OR (locked_by IS NOT NULL AND locked_until IS NOT NULL))
);

-- One job per idempotency key, ever.
CREATE UNIQUE INDEX IF NOT EXISTS job_idempotency_key_uq ON crm.job (idempotency_key) WHERE idempotency_key IS NOT NULL;
-- Claim path: next due queued job.
CREATE INDEX IF NOT EXISTS job_queued_due_idx ON crm.job (run_after, created_at) WHERE status = 'queued';
-- Reaper + per-kind running count.
CREATE INDEX IF NOT EXISTS job_running_idx ON crm.job (kind, locked_until) WHERE status = 'running';
-- Admin jobs view (CIS reads it only through the crm.ops.v1 HTTP contract, never from the database).
CREATE INDEX IF NOT EXISTS job_kind_created_idx ON crm.job (kind, created_at DESC);
CREATE INDEX IF NOT EXISTS job_parent_idx ON crm.job (parent_job_id) WHERE parent_job_id IS NOT NULL;
-- Retention keyset walk (NAM-15, C5.2e).
CREATE INDEX IF NOT EXISTS job_finished_idx ON crm.job (finished_at, id) WHERE finished_at IS NOT NULL;

CREATE OR REPLACE FUNCTION crm.job_set_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION crm.job_set_updated_at() FROM PUBLIC;

CREATE OR REPLACE TRIGGER job_set_updated_at
    BEFORE UPDATE ON crm.job
    FOR EACH ROW EXECUTE FUNCTION crm.job_set_updated_at();

-- High-churn queue (heartbeat UPDATEs), C5.1b as amended by AA-751.
ALTER TABLE crm.job SET (autovacuum_vacuum_scale_factor = 0.02, autovacuum_vacuum_threshold = 50);

COMMENT ON TABLE crm.job IS 'AA-932 (crm-001): the partner CRM job queue (ADR 0003a template, kinds crm_*), written and claimed only by AA-Partner (crm_app). Retention: data standards §7 row crm.job.';
COMMENT ON COLUMN crm.job.payload IS 'ids only, never personal data (DM-6.3; AA-Partner CI rejects personal-data keys, CRM-05)';
COMMENT ON COLUMN crm.job.result IS 'ids and counts only, never personal data (DM-6.3)';
COMMENT ON COLUMN crm.job.error IS 'error class and ids only, never personal data or a message echoing input (DM-6.3)';

-- ── Guard 1: the privilege model, by shape ───────────────────────────────────────────────────────
DO $$
DECLARE
    r text;
    p text;
BEGIN
    FOREACH p IN ARRAY ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'] LOOP
        IF NOT pg_catalog.has_table_privilege('crm_app', 'crm.job', p) THEN
            RAISE EXCEPTION 'crm-001: crm_app lacks % on crm.job (default privileges FOR ROLE crm_owner)', p;
        END IF;
    END LOOP;
    IF pg_catalog.has_table_privilege('crm_app', 'crm.job', 'TRUNCATE')
       OR pg_catalog.has_table_privilege('crm_app', 'crm.job', 'SELECT WITH GRANT OPTION') THEN
        RAISE EXCEPTION 'crm-001: crm_app holds more than DML on crm.job';
    END IF;
    -- The NOLOGIN roles get nothing on crm.job (granted table by table by later cards).
    FOREACH r IN ARRAY ARRAY['crm_ai_reader', 'crm_insights', 'crm_support_reader', 'crm_eraser'] LOOP
        IF pg_catalog.has_table_privilege(r, 'crm.job', 'SELECT') THEN
            RAISE EXCEPTION 'crm-001: % may read crm.job', r;
        END IF;
    END LOOP;
    IF pg_catalog.has_function_privilege('public', 'crm.job_set_updated_at()', 'EXECUTE') THEN
        RAISE EXCEPTION 'crm-001: crm.job_set_updated_at() is executable by PUBLIC (SEC-4)';
    END IF;
    -- No AA app role reaches the schema (ADR 0008a decision 1). A role missing on this database is skipped.
    FOREACH r IN ARRAY ARRAY['cis_app', 'aa_app_user', 'booking', 'tripplanner', 'cis_owner', 'bk_owner', 'tp_owner']
    LOOP
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r)
           AND pg_catalog.has_schema_privilege(r, 'crm', 'USAGE') THEN
            RAISE EXCEPTION 'crm-001: role % has USAGE on schema crm', r;
        END IF;
    END LOOP;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-001', now(), 'AA-932: crm schema privileges (crm_app DML defaults, no PUBLIC EXECUTE) + crm.job (ADR 0003a template, kinds crm_*)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
