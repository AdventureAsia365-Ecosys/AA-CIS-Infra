-- Migration 301: AA-995 — shared.place_photo.s3_key_medium: a 960 w WebP rendition of each catalog photo.
--
-- Why. The photo sync stores two renditions (600 w and 1600 w WebP, services/photos/sync.py SIZES). A phone hero is
-- drawn ~850 CSS px wide, so the TripPlanner destination hero takes the 1600 w file (~140 KB) and its mobile LCP stays
-- at 2.7–3.0 s on a simulated slow 4G; a 960 w file (~100 KB) brings it to ~2.1 s (S256 measurement). The photos CDN
-- serves stored files only (no resizing), so the rendition has to exist in the bucket.
--
-- What. One nullable text column, no default, no index (read by photo id only), no CHECK. It holds the S3 key of the
-- 960 w WebP (photos/<country slug>/<drive file id>-960.webp). The sync writes it for every file it downloads once the
-- AA-995 code ships; the `photo_medium_backfill` job fills it for the files stored before (rendered from the stored
-- original, no Drive download). NULL until then: GET /content/photos/{id}?size=medium falls back to the next larger
-- size. Additive: no data change, no grant change (cis_app holds table-level grants on shared.place_photo, which cover
-- a new column).
--
-- Order with the code. Apply BEFORE the code deploys: the sync's upsert and the photo route name this column, and
-- without it every photo request (and the sync) fails. Apply through AA-CIS-Infra DB Migrate (byte copy in
-- db/migrations/cis/). It only needs the table (CIS 198). The code PR sets readiness.REQUIRED_CIS_SCHEMA to 301.
--
-- Number. 297–300 are used; 301 is the next free number.
--
-- Preflight (read-only; expected: table present = 1, column present = 0):
--   SELECT (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
--            WHERE n.nspname = 'shared' AND c.relname = 'place_photo') AS table_present,
--          (SELECT count(*) FROM information_schema.columns
--            WHERE table_schema = 'shared' AND table_name = 'place_photo'
--              AND column_name = 's3_key_medium') AS present;
--
-- Rollback (a NEW forward migration, after the code that reads and writes the column is reverted; the S3 objects can
-- stay, nothing else points at them):
--   ALTER TABLE shared.place_photo DROP COLUMN s3_key_medium;
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of the table.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF to_regclass('shared.place_photo') IS NULL THEN
        RAISE EXCEPTION 'migration 301: shared.place_photo is missing (CIS 198)';
    END IF;
END $$;

ALTER TABLE shared.place_photo
    ADD COLUMN IF NOT EXISTS s3_key_medium TEXT;

COMMENT ON COLUMN shared.place_photo.s3_key_medium IS
    'AA-995 (CIS 301): S3 key of the 960 w WebP rendition (photos/<country>/<file id>-960.webp). Written by the photo '
    'sync and by the photo_medium_backfill job; NULL until then (the public photo route falls back to the large file).';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('301', now(), 'AA-995: shared.place_photo.s3_key_medium (960 w WebP rendition for mobile heroes)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
