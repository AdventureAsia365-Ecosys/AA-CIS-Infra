-- Migration 290: AA-995 (S253) — one photo, one URL: the photo read views point every copy of the same file at one
-- canonical photo id.
--
-- Why. The Drive photo sync stores one shared.place_photo row per Drive file, and the AA folders hold the same picture
-- in many tour folders (S253: 2,629 matched rows, 1,120 distinct sha256). Each copy got its own
-- /content/photos/<id> path, so readers could not tell that two covers are the same picture: the TripPlanner home's
-- duplicate-cover rule (compares photo URLs) let one Bhutan photo through four times in the featured row and the photo
-- ribbon, and browsers / the CDN cached the same bytes under many URLs.
--
-- What (same columns, names, types and order; only the `path` value changes):
--   1. shared.v_tour_photos and shared.v_destination_photos: `path` = /content/photos/<canonical id>, the canonical id
--      being the earliest matched, served row (s3_key_large set) with the same sha256 (created_at, then id). A row
--      without sha256 keeps its own id. `photo_id` stays the row's own id, so identity, position and place_label are
--      unchanged. The catalog views (catalog.v_tour, v_tour_photo, v_destination, v_destination_photo) read `path` from
--      these views and pick it up without a change.
--   2. Index place_photo_sha256_matched_idx for the canonical lookup.
-- /content/photos/<id> serves any matched row, and the canonical row has the same bytes (same sha256).

-- Runs as the file's runner: DB Migrate logs in as the owner of schema shared (cis_owner since 245), like 279 part A.
BEGIN;
SET LOCAL lock_timeout = '10s';

CREATE INDEX IF NOT EXISTS place_photo_sha256_matched_idx
    ON shared.place_photo (sha256, created_at, id)
 WHERE status = 'matched' AND s3_key_large IS NOT NULL AND sha256 IS NOT NULL;

CREATE OR REPLACE VIEW shared.v_tour_photos AS
SELECT p.tour_id, p.id AS photo_id, '/content/photos/' || COALESCE(c.id, p.id)::text AS path, p.place_label,
       p.destination_id, p.width, p.height, p.match_source, p.updated_at,
       row_number() OVER (PARTITION BY p.tour_id
                          ORDER BY (p.match_source = 'manual') DESC, p.file_name) AS position
  FROM shared.place_photo p
  LEFT JOIN LATERAL (
        SELECT q.id FROM shared.place_photo q
         WHERE q.sha256 = p.sha256 AND q.status = 'matched' AND q.s3_key_large IS NOT NULL
         ORDER BY q.created_at, q.id LIMIT 1) c ON p.sha256 IS NOT NULL
 WHERE p.status = 'matched' AND p.tour_id IS NOT NULL AND p.s3_key_large IS NOT NULL;

CREATE OR REPLACE VIEW shared.v_destination_photos AS
SELECT p.destination_id, p.id AS photo_id, '/content/photos/' || COALESCE(c.id, p.id)::text AS path, p.place_label,
       p.tour_id, p.width, p.height, p.match_source, p.updated_at,
       row_number() OVER (PARTITION BY p.destination_id
                          ORDER BY (p.match_source = 'manual') DESC, p.file_name) AS position
  FROM shared.place_photo p
  LEFT JOIN LATERAL (
        SELECT q.id FROM shared.place_photo q
         WHERE q.sha256 = p.sha256 AND q.status = 'matched' AND q.s3_key_large IS NOT NULL
         ORDER BY q.created_at, q.id LIMIT 1) c ON p.sha256 IS NOT NULL
 WHERE p.status = 'matched' AND p.destination_id IS NOT NULL AND p.s3_key_large IS NOT NULL;

COMMENT ON VIEW shared.v_tour_photos IS 'AA-708 — matched AA photos per tour (read contract for TripPlanner / portal / AA-Booking). AA-995 (290): path names the canonical row of the same file (sha256).';
COMMENT ON VIEW shared.v_destination_photos IS 'AA-708 — matched AA photos per destination (read contract; cover = position 1). AA-995 (290): path names the canonical row of the same file (sha256).';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('290', now(), 'AA-995 S253: photo read views point every copy of the same file (sha256) at one canonical '
                      '/content/photos/<id> path; same columns')
ON CONFLICT (version) DO NOTHING;

COMMIT;
