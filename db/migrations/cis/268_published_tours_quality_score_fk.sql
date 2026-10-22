-- Migration 268: AA-894 (S247) — restore the foreign key gold_aa_internal.published_tours.quality_score_id
-- -> silver_aa_internal.quality_scores(id) (ON DELETE SET NULL), plus the index on the referencing column.
--
-- Why. Schema v2 (migration 002) declared `quality_score_id UUID REFERENCES quality_scores(id)`; schema v3 (003,
-- the per-tenant schema function that created the live tables) wrote the column as a plain UUID, so the key was
-- lost. The column is the published tour's accepted score row (the export handler sets it from the version's
-- quality_scores row, services/export/handler.py), and nothing in the database holds it. It CAN dangle today:
-- a revalidation (api/routers/admin_pipeline.py revalidate, services/jobs/revalidate_job.py) DELETEs a version's
-- quality_scores rows and INSERTs new ones with new ids, and a published tour of that version keeps the old id.
-- Both tables are CIS-owned (docs/database/schema-ownership.md), so data standards DM-4.1 / KEY-1 say the FK
-- SHOULD exist. It also gives the live ERD (AA-894) its missing silver -> gold edge for the score.
--
-- What it does, in one transaction (DB Migrate runs it as cis_owner; both tables are FORCE RLS and cis_owner has
-- its `<t>_cis_owner_all` USING (true) policy on both, CIS 244/245):
--   0. Preconditions (RAISE, never a no-op): both tables and columns exist with uuid types, quality_scores.id is its
--      primary key, and any constraint already named published_tours_quality_score_id_fkey is exactly this one.
--   1. Repair dangling pointers: a published tour whose quality_score_id names no quality_scores row is re-pointed
--      to the CURRENT score row of its own version (same generated_content_id, latest evaluated_at, the row the admin
--      tour view reads, api/routers/v1_tours.py), or set to NULL when that version has no score row. Its stored
--      `quality_score` number is left as published. The read-only DRY RUN for this step is AA-Ecosys
--      .tmp-session/aa894_fk_orphans.py (it counts what this step would change); on Dev it is expected to be a no-op.
--   2. CREATE INDEX IF NOT EXISTS on published_tours(quality_score_id): PostgreSQL does not index the referencing
--      side, and ON DELETE SET NULL looks rows up by it on every quality_scores delete (QRY-2). Plain build: the
--      table has ~900 rows (MIG-10 allows a plain index on a table <= 100k rows with the lock_timeout and jobs idle).
--   3. ADD CONSTRAINT ... NOT VALID, then VALIDATE CONSTRAINT in a second statement (MIG-11).
--      ON DELETE SET NULL, not the default NO ACTION: the revalidation DELETE of a published version's score row
--      must keep working; the pointer then becomes NULL (honest) instead of dangling.
--   4. Post-check: exactly one FK on the column, to quality_scores(id), ON DELETE SET NULL, validated; 0 orphans.
--   5. Register 268.
--
-- Locks (lock-sensitive tables: gold_aa_internal.published_tours, silver_aa_internal.quality_scores). The ADD takes
-- SHARE ROW EXCLUSIVE on both tables; DB Migrate sends the file as one transaction, so that lock is held until COMMIT,
-- through the VALIDATE scan (~900 x ~1.4k rows, milliseconds). Readers are never blocked; writers of the two tables
-- wait for those milliseconds. lock_timeout 5 s makes the file fail instead of queueing behind a job transaction
-- (MIG-9); apply with every job table idle (DM-11.4, DB Migrate checks it). No table rewrite.
--
-- Code: none needed. No writer sets a pointer to a missing row (export reads the id from quality_scores in the same
-- query). One behaviour change: a revalidation that deletes the version's score row between the export's SELECT and
-- its INSERT (services/export/handler.py, two autocommit statements) now fails that export with a foreign key
-- violation instead of storing a dangling id; the export can be run again. Readiness: no REQUIRED_CIS_SCHEMA bump
-- (api/core/readiness.py), no code depends on 268.
--
-- NUMBER: 268 (after 267, AA-779). The SQL does not depend on 265 / 266 / 267, but ORDER: apply only AFTER them. The
-- readiness check compares max(version::int) of shared.schema_versions with REQUIRED_CIS_SCHEMA, so with 268 applied
-- first, code that later needs 265, 266 or 267 would report ready while they are missing (same rule as 267).
--
-- Idempotent: step 1 changes nothing once there is no dangling pointer, the index is IF NOT EXISTS, the ADD is
-- guarded by name (step 0 refuses a different constraint under that name), VALIDATE of a validated constraint is a
-- no-op, the registration is ON CONFLICT DO NOTHING.
-- Rollback (schema only; a repaired pointer is not un-repaired, it pointed at nothing):
--   ALTER TABLE gold_aa_internal.published_tours DROP CONSTRAINT IF EXISTS published_tours_quality_score_id_fkey;
--   DROP INDEX IF EXISTS gold_aa_internal.idx_published_tours_quality_score_id;
--   DELETE FROM shared.schema_versions WHERE version = '268';

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '15min';

-- 0. Preconditions.
DO $$
DECLARE
    v_type text;
    v_def  text;
BEGIN
    IF to_regclass('gold_aa_internal.published_tours') IS NULL THEN
        RAISE EXCEPTION 'migration 268: gold_aa_internal.published_tours does not exist';
    END IF;
    IF to_regclass('silver_aa_internal.quality_scores') IS NULL THEN
        RAISE EXCEPTION 'migration 268: silver_aa_internal.quality_scores does not exist';
    END IF;

    SELECT format_type(a.atttypid, a.atttypmod) INTO v_type
    FROM pg_attribute a
    WHERE a.attrelid = 'gold_aa_internal.published_tours'::regclass AND a.attname = 'quality_score_id'
      AND a.attnum > 0 AND NOT a.attisdropped;
    IF v_type IS DISTINCT FROM 'uuid' THEN
        RAISE EXCEPTION 'migration 268: published_tours.quality_score_id is %, expected uuid', coalesce(v_type, 'missing');
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
        WHERE c.conrelid = 'silver_aa_internal.quality_scores'::regclass AND c.contype = 'p'
          AND array_length(c.conkey, 1) = 1 AND a.attname = 'id' AND a.atttypid = 'uuid'::regtype
    ) THEN
        RAISE EXCEPTION 'migration 268: silver_aa_internal.quality_scores.id is not its uuid primary key';
    END IF;

    SELECT pg_get_constraintdef(c.oid) INTO v_def
    FROM pg_constraint c
    WHERE c.conrelid = 'gold_aa_internal.published_tours'::regclass
      AND c.conname = 'published_tours_quality_score_id_fkey';
    IF v_def IS NOT NULL AND v_def NOT IN (
        'FOREIGN KEY (quality_score_id) REFERENCES silver_aa_internal.quality_scores(id) ON DELETE SET NULL',
        'FOREIGN KEY (quality_score_id) REFERENCES silver_aa_internal.quality_scores(id) ON DELETE SET NULL NOT VALID'
    ) THEN
        RAISE EXCEPTION 'migration 268: a different constraint published_tours_quality_score_id_fkey exists: %', v_def;
    END IF;
END $$;

-- 1. Repair dangling pointers (re-point to the version's current score row, else NULL).
DO $$
DECLARE
    v_repointed int;
    v_nulled    int;
BEGIN
    WITH dangling AS (
        SELECT pt.id,
               (SELECT qs.id
                FROM silver_aa_internal.quality_scores qs
                WHERE qs.generated_content_id = pt.generated_content_id
                ORDER BY qs.evaluated_at DESC, qs.id DESC
                LIMIT 1) AS current_score_id
        FROM gold_aa_internal.published_tours pt
        WHERE pt.quality_score_id IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM silver_aa_internal.quality_scores q WHERE q.id = pt.quality_score_id)
    ), fixed AS (
        UPDATE gold_aa_internal.published_tours pt
        SET quality_score_id = d.current_score_id
        FROM dangling d
        WHERE pt.id = d.id
        RETURNING d.current_score_id
    )
    SELECT count(*) FILTER (WHERE current_score_id IS NOT NULL),
           count(*) FILTER (WHERE current_score_id IS NULL)
    INTO v_repointed, v_nulled
    FROM fixed;
    RAISE NOTICE 'migration 268: dangling quality_score_id re-pointed %, set NULL %', v_repointed, v_nulled;
END $$;

-- 2. Index on the referencing column.
CREATE INDEX IF NOT EXISTS idx_published_tours_quality_score_id
    ON gold_aa_internal.published_tours (quality_score_id);

-- 3. The FK: NOT VALID, then VALIDATE in a second statement.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'gold_aa_internal.published_tours'::regclass
          AND conname = 'published_tours_quality_score_id_fkey'
    ) THEN
        ALTER TABLE gold_aa_internal.published_tours
            ADD CONSTRAINT published_tours_quality_score_id_fkey
            FOREIGN KEY (quality_score_id) REFERENCES silver_aa_internal.quality_scores (id)
            ON DELETE SET NULL
            NOT VALID;
    END IF;
END $$;

ALTER TABLE gold_aa_internal.published_tours VALIDATE CONSTRAINT published_tours_quality_score_id_fkey;

-- 4. Post-check.
DO $$
DECLARE
    v_fks     int;
    v_orphans int;
BEGIN
    SELECT count(*) INTO v_fks
    FROM pg_constraint c
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
    WHERE c.conrelid = 'gold_aa_internal.published_tours'::regclass AND c.contype = 'f'
      AND array_length(c.conkey, 1) = 1 AND a.attname = 'quality_score_id';
    IF v_fks <> 1 THEN
        RAISE EXCEPTION 'migration 268: % foreign keys on published_tours.quality_score_id, expected 1', v_fks;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'gold_aa_internal.published_tours'::regclass
          AND conname = 'published_tours_quality_score_id_fkey'
          AND confrelid = 'silver_aa_internal.quality_scores'::regclass
          AND confdeltype = 'n' AND convalidated
    ) THEN
        RAISE EXCEPTION 'migration 268: published_tours_quality_score_id_fkey is not a validated ON DELETE SET NULL FK';
    END IF;
    SELECT count(*) INTO v_orphans
    FROM gold_aa_internal.published_tours pt
    WHERE pt.quality_score_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM silver_aa_internal.quality_scores q WHERE q.id = pt.quality_score_id);
    IF v_orphans <> 0 THEN
        RAISE EXCEPTION 'migration 268: % published tours still point at a missing score row', v_orphans;
    END IF;
END $$;

-- 5. Register.
INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('268', now(), 'AA-894: FK published_tours.quality_score_id -> quality_scores(id) ON DELETE SET NULL (+ index, dangling pointers repaired)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
