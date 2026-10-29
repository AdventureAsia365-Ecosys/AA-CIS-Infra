-- Migration 303: AA-671 — shared.place_photo.destination_match_source: who set a photo's destination.
--
-- Why. A photo's destination (place_photo.destination_id) is now filled automatically (AA-671 S257: the photo sync and
-- the photo_destination_match job give a tour-matched photo the place of its own tour that its label names). Staff can
-- also set it by hand (POST /admin/photos/{id}/assign). The table only says who set the TOUR (match_source), so an
-- automatic destination on a row whose tour was set by hand looks the same as a destination a person chose: the sync
-- would keep it forever, a later re-match would never reach it, and a folder-wide tour correction could not tell which
-- destinations belong to the old (wrong) tour. This column records who set the destination.
--
-- What. One nullable text column, CHECK in ('auto', 'manual'), no default, no index (read with the row only).
--   'manual' = set through the assign route; the sync and the job never change it.
--   'auto'   = set by the sync or the job; re-matched when the tour changes or on request.
--   NULL     = no destination.
-- Backfill: rows that already hold a destination get 'manual' when the row's tour was set by hand, else 'auto' (the
-- conservative reading: a person's row is protected). On Dev no row holds a destination today (S257: 0 of 3,232), so
-- the backfill updates nothing there. Additive: no grant change (cis_app holds table-level grants on
-- shared.place_photo, which cover a new column); the photo views do not select it.
--
-- Order with the code. Apply BEFORE the AA-671 destination-matching code deploys: its sync upsert, assign route and job
-- write this column (readiness.REQUIRED_CIS_SCHEMA = 303 in that PR). Apply through AA-CIS-Infra DB Migrate (byte copy
-- in db/migrations/cis/, opened by the migration-sync bot). It needs the table (CIS 198) and 302 before it (strict
-- prefix, ADR 0017).
--
-- Number. 302 is used; 303 is the next free number.
--
-- Preflight (read-only; expected: table present = 1, column present = 0, rows with a destination = 0 on Dev):
--   SELECT (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
--            WHERE n.nspname = 'shared' AND c.relname = 'place_photo') AS table_present,
--          (SELECT count(*) FROM information_schema.columns
--            WHERE table_schema = 'shared' AND table_name = 'place_photo'
--              AND column_name = 'destination_match_source') AS present,
--          (SELECT count(*) FROM shared.place_photo WHERE destination_id IS NOT NULL) AS with_destination;
--
-- Rollback (a NEW forward migration, after the code that reads and writes the column is reverted):
--   ALTER TABLE shared.place_photo DROP COLUMN destination_match_source;
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of the table.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF to_regclass('shared.place_photo') IS NULL THEN
        RAISE EXCEPTION 'migration 303: shared.place_photo is missing (CIS 198)';
    END IF;
END $$;

ALTER TABLE shared.place_photo
    ADD COLUMN IF NOT EXISTS destination_match_source TEXT;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'place_photo_destination_match_source_check'
                      AND conrelid = 'shared.place_photo'::regclass) THEN
        ALTER TABLE shared.place_photo
            ADD CONSTRAINT place_photo_destination_match_source_check
            CHECK (destination_match_source IN ('auto', 'manual'));
    END IF;
END $$;

UPDATE shared.place_photo
   SET destination_match_source = CASE WHEN match_source = 'manual' THEN 'manual' ELSE 'auto' END
 WHERE destination_id IS NOT NULL AND destination_match_source IS NULL;

COMMENT ON COLUMN shared.place_photo.destination_match_source IS
    'AA-671 (CIS 303): who set destination_id. manual = the assign route (never changed by the sync or the '
    'photo_destination_match job); auto = the sync or that job (re-matched when the tour changes or on request); '
    'NULL = no destination.';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('303', now(), 'AA-671: shared.place_photo.destination_match_source (who set the destination)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
