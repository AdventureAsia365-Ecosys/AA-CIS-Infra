-- Migration 242: AA-751 (X6) — shared.job conforms to the job table DDL template
-- (shared/jobs/job_table_template.sql, ADR 0003a decision 2).
--
-- Why. shared.job (CIS 174 + the 233 job_finished_idx) lacked the kind CHECK, the running-lease CHECK,
-- attempt >= 0 and the updated_at trigger the template fixes, and had no queue autovacuum settings (data
-- standard C5.1b as amended by AA-751: scale 0.02 + threshold 50 is never later than the default 0.2 + 50 at
-- any row count; retention keeps the table at a few thousand rows). All CIS writers already keep the
-- invariants (shared/jobs/queue.py claim / _finish / fail / release / reap; admin retry and the two
-- _COALESCE_SQL in services/places/enqueue.py and services/jobs/recompute_job.py only touch queued rows).
-- The trigger also covers those two _COALESCE_SQL UPDATEs, which never set updated_at. CIS kinds stay
-- unprefixed (ADR 0003a d3); the kind CHECK rejects other owners' prefixes bk_ / tp_ and anything that is
-- not lower-case snake_case.
--
-- What.
--   * FUNCTION shared.job_set_updated_at() (SET search_path = pg_catalog) + TRIGGER job_set_updated_at
--     BEFORE UPDATE FOR EACH ROW, both CREATE OR REPLACE;
--   * CHECKs job_kind_chk  (kind ~ '^(?!bk_|tp_)[a-z][a-z0-9_]*$'),
--            job_lease_chk (status <> 'running' OR (locked_by IS NOT NULL AND locked_until IS NOT NULL)),
--            job_attempts_chk (attempt >= 0 AND max_attempts >= 1), each added only when no constraint of that
--     name exists (one that exists must already have exactly the template's definition, else guard 1 stops);
--   * the 174 inline CHECK (max_attempts >= 1), superseded by job_attempts_chk, is dropped by DEFINITION
--     (its auto-generated name is job_max_attempts_check in CI; the drop does not depend on the name);
--   * reloptions autovacuum_vacuum_scale_factor = 0.02, autovacuum_vacuum_threshold = 50.
--   Unchanged: columns, indexes (already the template's six + the PK), the status CHECK (174's
--   job_status_check holds the template set + 'stopped_budget'; constraint names are not part of the shape).
--
-- Guards (in the style of 237/239):
--   1. before, under ACCESS EXCLUSIVE (so no row can change between the count and the ALTERs): the table
--      exists and the runner owns it (or is a member of its owner); no retained row breaks a new CHECK
--      (counts + up to five ids per rule in the error, so the rows can be fixed and the file re-run); a
--      constraint that already carries one of the three names has the template's definition.
--      A plain ADD CONSTRAINT ... CHECK would also refuse a bad row, but with a bare "violated by some row";
--      NOT VALID + VALIDATE buys nothing here because the ACCESS EXCLUSIVE lock of ADD is held until COMMIT
--      anyway. The C1 pre-check (AA-Ecosys/docs/audits/2026-10-16-S240-aa751/c1_precheck.py) runs the same
--      counts read-only on Dev before the apply window.
--   2. after, by shape: the three CHECKs exist and are validated, the 174 max_attempts CHECK is gone, exactly
--      one enabled BEFORE UPDATE FOR EACH ROW trigger calls shared.job_set_updated_at(), the reloptions hold;
--   3. after, by behaviour (each probe in a sub-block whose changes are rolled back): kind 'bk_…' and 'tp_…'
--      are rejected, 'running' without a lease is rejected, attempt -1 is rejected, and an UPDATE sets
--      updated_at to now() although the row was inserted with an old value.
--   The CI integration test tests/integration/test_aa751_job_table_template.py compares the result with the
--   rendered template through pg_catalog (shared/jobs/job_table_shape.py) and re-runs this file.
--
-- Locks. LOCK TABLE ... ACCESS EXCLUSIVE until COMMIT, on a small table, inside lock_timeout 5s (gives up
-- instead of queueing the worker's claims and the admin Jobs page). Hot-table DDL (C5.2g): apply only when
-- every job table is idle (DB Migrate refuses otherwise, AA-751 I1). Any failed guard or a bad row aborts the
-- whole file and nothing changes. Re-running is a no-op. Not destructive (no row is changed or removed), so
-- no `migrate:` header directive.
--
-- After apply: regenerate docs/architecture/db-schema-reference.md (the DB Schema Dump workflow); expect
-- job_kind_chk, job_lease_chk, job_attempts_chk, trigger job_set_updated_at and the two reloptions.
--
-- Rollback (migration 243; the code works either way):
--   DROP TRIGGER IF EXISTS job_set_updated_at ON shared.job;
--   DROP FUNCTION IF EXISTS shared.job_set_updated_at();
--   ALTER TABLE shared.job DROP CONSTRAINT IF EXISTS job_kind_chk,
--                          DROP CONSTRAINT IF EXISTS job_lease_chk,
--                          DROP CONSTRAINT IF EXISTS job_attempts_chk,
--                          ADD CONSTRAINT job_max_attempts_check CHECK (max_attempts >= 1);
--   ALTER TABLE shared.job RESET (autovacuum_vacuum_scale_factor, autovacuum_vacuum_threshold);

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '120s';

-- ── Guard 1a: the table exists and the runner may alter it ───────────────────────────────────────
DO $$
DECLARE
    owner_name text;
BEGIN
    IF to_regclass('shared.job') IS NULL THEN
        RAISE EXCEPTION 'migration 242: shared.job does not exist';
    END IF;
    SELECT pg_get_userbyid(relowner) INTO owner_name FROM pg_class WHERE oid = 'shared.job'::regclass;
    IF NOT pg_has_role(current_user, owner_name, 'MEMBER') THEN
        RAISE EXCEPTION 'migration 242: shared.job is owned by %, not by the runner % (ALTER TABLE needs the owner)',
            owner_name, current_user;
    END IF;
END $$;

LOCK TABLE shared.job IN ACCESS EXCLUSIVE MODE;

-- ── Guard 1b: no retained row breaks a new CHECK; existing names carry the template definition ───
DO $$
DECLARE
    n_kind    bigint;
    n_lease   bigint;
    n_attempt bigint;
    ids_kind    text;
    ids_lease   text;
    ids_attempt text;
    want   jsonb := jsonb_build_object(
        'job_kind_chk',     'CHECK ((kind ~ ''^(?!bk_|tp_)[a-z][a-z0-9_]*$''::text))',
        'job_lease_chk',    'CHECK (((status <> ''running''::text) OR ((locked_by IS NOT NULL) AND (locked_until IS NOT NULL))))',
        'job_attempts_chk', 'CHECK (((attempt >= 0) AND (max_attempts >= 1)))');
    r record;
BEGIN
    SELECT count(*) FILTER (WHERE kind !~ '^(?!bk_|tp_)[a-z][a-z0-9_]*$'),
           count(*) FILTER (WHERE status = 'running' AND (locked_by IS NULL OR locked_until IS NULL)),
           count(*) FILTER (WHERE attempt < 0 OR max_attempts < 1)
      INTO n_kind, n_lease, n_attempt
      FROM shared.job;
    IF n_kind + n_lease + n_attempt > 0 THEN
        SELECT string_agg(id::text || ' (' || kind || ')', ', ') INTO ids_kind
          FROM (SELECT id, kind FROM shared.job WHERE kind !~ '^(?!bk_|tp_)[a-z][a-z0-9_]*$' LIMIT 5) s;
        SELECT string_agg(id::text, ', ') INTO ids_lease
          FROM (SELECT id FROM shared.job
                 WHERE status = 'running' AND (locked_by IS NULL OR locked_until IS NULL) LIMIT 5) s;
        SELECT string_agg(id::text, ', ') INTO ids_attempt
          FROM (SELECT id FROM shared.job WHERE attempt < 0 OR max_attempts < 1 LIMIT 5) s;
        RAISE EXCEPTION 'migration 242: % kind / % lease / % attempt rows of shared.job break the new CHECKs; fix them first, nothing was changed. kind: [%] lease: [%] attempt: [%]',
            n_kind, n_lease, n_attempt, coalesce(ids_kind, ''), coalesce(ids_lease, ''), coalesce(ids_attempt, '');
    END IF;

    FOR r IN SELECT conname, pg_get_constraintdef(oid) AS def FROM pg_constraint
              WHERE conrelid = 'shared.job'::regclass AND want ? conname LOOP
        IF r.def <> want ->> r.conname THEN
            RAISE EXCEPTION 'migration 242: shared.job constraint % exists as "%", expected "%" (drift; a human must look)',
                r.conname, r.def, want ->> r.conname;
        END IF;
    END LOOP;
END $$;

-- ── The updated_at trigger ───────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION shared.job_set_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;
COMMENT ON FUNCTION shared.job_set_updated_at() IS 'AA-751 (242): BEFORE UPDATE trigger on shared.job, keeps updated_at current (job table template).';

CREATE OR REPLACE TRIGGER job_set_updated_at
    BEFORE UPDATE ON shared.job
    FOR EACH ROW EXECUTE FUNCTION shared.job_set_updated_at();

-- ── The template CHECKs ──────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'shared.job'::regclass AND conname = 'job_kind_chk') THEN
        ALTER TABLE shared.job ADD CONSTRAINT job_kind_chk
            CHECK (kind ~ '^(?!bk_|tp_)[a-z][a-z0-9_]*$');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'shared.job'::regclass AND conname = 'job_lease_chk') THEN
        ALTER TABLE shared.job ADD CONSTRAINT job_lease_chk
            CHECK (status <> 'running' OR (locked_by IS NOT NULL AND locked_until IS NOT NULL));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'shared.job'::regclass AND conname = 'job_attempts_chk') THEN
        ALTER TABLE shared.job ADD CONSTRAINT job_attempts_chk
            CHECK (attempt >= 0 AND max_attempts >= 1);
    END IF;
END $$;

-- Superseded by job_attempts_chk: the CIS 174 inline CHECK (max_attempts >= 1), whatever its name.
DO $$
DECLARE
    r record;
BEGIN
    FOR r IN SELECT conname FROM pg_constraint
              WHERE conrelid = 'shared.job'::regclass AND contype = 'c'
                AND pg_get_constraintdef(oid) = 'CHECK ((max_attempts >= 1))' LOOP
        EXECUTE format('ALTER TABLE shared.job DROP CONSTRAINT %I', r.conname);
        RAISE NOTICE 'migration 242: dropped superseded CHECK % (max_attempts >= 1)', r.conname;
    END LOOP;
END $$;

-- ── Queue autovacuum (C5.1b as amended by AA-751) ────────────────────────────────────────────────
ALTER TABLE shared.job SET (autovacuum_vacuum_scale_factor = 0.02, autovacuum_vacuum_threshold = 50);

-- ── Guard 2: shape after ─────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    n int;
    opts text[];
BEGIN
    SELECT count(*) INTO n FROM pg_constraint
     WHERE conrelid = 'shared.job'::regclass AND contype = 'c' AND convalidated
       AND conname IN ('job_kind_chk', 'job_lease_chk', 'job_attempts_chk');
    IF n <> 3 THEN
        RAISE EXCEPTION 'migration 242: expected 3 validated template CHECKs on shared.job, found %', n;
    END IF;
    SELECT count(*) INTO n FROM pg_constraint
     WHERE conrelid = 'shared.job'::regclass AND contype = 'c'
       AND pg_get_constraintdef(oid) = 'CHECK ((max_attempts >= 1))';
    IF n <> 0 THEN
        RAISE EXCEPTION 'migration 242: the superseded max_attempts CHECK is still on shared.job';
    END IF;
    -- tgtype 19 = ROW (1) | BEFORE (2) | UPDATE (16); enabled, no WHEN clause, no column list.
    SELECT count(*) INTO n FROM pg_trigger
     WHERE tgrelid = 'shared.job'::regclass AND NOT tgisinternal
       AND tgfoid = 'shared.job_set_updated_at()'::regprocedure
       AND tgtype = 19 AND tgenabled = 'O' AND tgqual IS NULL AND coalesce(array_length(tgattr, 1), 0) = 0;
    IF n <> 1 THEN
        RAISE EXCEPTION 'migration 242: expected one enabled BEFORE UPDATE FOR EACH ROW trigger calling shared.job_set_updated_at(), found %', n;
    END IF;
    SELECT reloptions INTO opts FROM pg_class WHERE oid = 'shared.job'::regclass;
    IF NOT coalesce(opts, '{}') @> ARRAY['autovacuum_vacuum_scale_factor=0.02', 'autovacuum_vacuum_threshold=50'] THEN
        RAISE EXCEPTION 'migration 242: shared.job reloptions are %', opts;
    END IF;
END $$;

-- ── Guard 3: behaviour (every probe row is rolled back with its sub-block) ───────────────────────
DO $$
DECLARE
    probe_id uuid;
    bumped   boolean := false;
    bad_kind text;
BEGIN
    FOREACH bad_kind IN ARRAY ARRAY['bk_migration_242_probe', 'tp_migration_242_probe', 'Migration-242-Probe'] LOOP
        BEGIN
            INSERT INTO shared.job (kind, created_by) VALUES (bad_kind, 'migration-242-probe');
            RAISE EXCEPTION 'migration 242: job_kind_chk accepted kind %', bad_kind;
        EXCEPTION WHEN check_violation THEN
            NULL;
        END;
    END LOOP;

    BEGIN
        INSERT INTO shared.job (kind, status, created_by) VALUES ('migration_242_probe', 'running', 'migration-242-probe');
        RAISE EXCEPTION 'migration 242: job_lease_chk accepted a running row without a lease';
    EXCEPTION WHEN check_violation THEN
        NULL;
    END;

    BEGIN
        INSERT INTO shared.job (kind, attempt, created_by) VALUES ('migration_242_probe', -1, 'migration-242-probe');
        RAISE EXCEPTION 'migration 242: job_attempts_chk accepted attempt -1';
    EXCEPTION WHEN check_violation THEN
        NULL;
    END;

    BEGIN
        INSERT INTO shared.job (kind, created_by, updated_at)
        VALUES ('migration_242_probe', 'migration-242-probe', now() - interval '1 day')
        RETURNING id INTO probe_id;
        UPDATE shared.job SET error = 'migration 242 probe' WHERE id = probe_id
        RETURNING updated_at = now() INTO bumped;
        RAISE EXCEPTION USING ERRCODE = 'AA242', MESSAGE = 'migration 242: roll back the trigger probe';
    EXCEPTION WHEN SQLSTATE 'AA242' THEN
        NULL;
    END;
    IF NOT bumped THEN
        RAISE EXCEPTION 'migration 242: an UPDATE of shared.job did not set updated_at (trigger job_set_updated_at)';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('242', now(), 'AA-751 (X6): shared.job conforms to the job table template — kind/lease/attempts CHECKs, updated_at trigger, queue autovacuum')
ON CONFLICT (version) DO NOTHING;

COMMIT;
