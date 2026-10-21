-- Migration 256: AA-847 — the catalog views expose line places (owner decision S246, D1: rivers, roads and trekking
-- stretches are DRAWN on the TripPlanner map as lines — never a pin, a circle or hidden). "Migration B" of the
-- revised plan (root docs/audits/2026-10-21-S246-aa847/design-linear-places.md, skeptic pass §3). Needs 253 (catalog
-- L4 read model) and 255 (geo.place_shape, geo.tour_segment).
--
-- What (columns APPENDED only — CREATE OR REPLACE VIEW cannot drop, rename, reorder or retype one; same rows):
--   1. catalog.v_destination += shape_kind, shape_status, shape_source, length_km, min_lat, min_lng, max_lat, max_lng,
--      shape_lo. The four bbox columns are NEVER NULL: the shape's bbox for a line (a pending shape row carries its
--      point), the point itself for every other destination — so a consumer's tile filter is a plain float8
--      comparison (leakproof, pushed below the security barrier and the photo LATERAL). shape_lo (≤ 60 vertices) for
--      search results / static maps; shape_mid is NOT here (12 KB per row; read by id from v_destination_shape).
--   2. catalog.v_destination_shape (new, security_barrier, granted to tripplanner only): destination_id,
--      shape_status, shape_mid, shape_lo — line destinations only (usable: not suspect, not a merged duplicate).
--      The geometry endpoint of TripPlanner reads it by id (`= ANY($1)`), CDN-cached; tiles never carry geometry.
--   3. catalog.v_tour_place += segment, segment_basis, segment_from_destination_id, segment_to_destination_id,
--      segment_km (geo.tour_segment of the CURRENT build, like _live_stop). `precision` is already there (228).
--   4. catalog.v_tour_component += precision and the same five segment columns, after the optional embedding column
--      (the 228 / 253 DO / EXECUTE build: both shapes append at the end).
--   5. catalog._live_stop: a line destination is never a stop (defence in depth: graph.py already skips lines).
-- Not here: the probe's "255+" view follow-ups (security_barrier off on graph views, catalog.graph.v1.1 columns on
-- v_tour_component). Whichever migration runs later restates the other's body and keeps this column order.
--
-- Contracts: catalog.tour v1.2 (v_destination, v_tour_place, v_destination_shape) and catalog.graph v1.2
-- (v_tour_component), additive (root docs/contracts/).
--
-- Recipe: the X1 S22 catalog recipe, as 253 (GRANT CREATE ON SCHEMA catalog TO catalog_owner; SET LOCAL ROLE
-- catalog_owner; the view DDL; SET LOCAL ROLE cis_owner; REVOKE CREATE). DB Migrate runs the file as cis_owner
-- (login db_migrator). The conftest replay skips it (it needs 253); tests/integration/test_aa847_migration_256.py
-- applies 253 + 256 the DB Migrate way inside one transaction and rolls back.
--
-- Locks: ACCESS EXCLUSIVE on the four views until COMMIT (seconds); lock_timeout 10s. Apply while the job tables
-- are idle (DB Migrate waits for it). Idempotent (CREATE OR REPLACE, re-runnable grants), self-registering.
--
-- Rollback: appended columns cannot be removed by CREATE OR REPLACE — forward-only. Readers ignore NULL columns;
-- to hide the shapes, revoke SELECT on catalog.v_destination_shape and re-run 253's _live_stop statement.

BEGIN;
SET LOCAL lock_timeout = '10s';

-- ── Preconditions + the row counts the closing check compares with ──────────────────────────────────────────────
DO $$
BEGIN
    IF to_regclass('catalog._live_tour') IS NULL OR to_regclass('catalog._live_stop') IS NULL THEN
        RAISE EXCEPTION 'migration 256: catalog._live_tour / _live_stop missing (apply 253 first)';
    END IF;
    IF to_regclass('geo.place_shape') IS NULL OR to_regclass('geo.tour_segment') IS NULL THEN
        RAISE EXCEPTION 'migration 256: geo.place_shape / geo.tour_segment missing (apply 255 first)';
    END IF;
    IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'catalog') <> 'cis_owner' THEN
        RAISE EXCEPTION 'migration 256: schema catalog is not owned by cis_owner (apply 245 first)';
    END IF;
END $$;

GRANT CREATE ON SCHEMA catalog TO catalog_owner;
SET LOCAL ROLE catalog_owner;

DO $$
DECLARE
    n bigint;
BEGIN
    PERFORM set_config('app.tenant_id', '00000000-0000-0000-0000-000000000000', true);
    SELECT count(*) INTO n FROM catalog.v_tour_place;
    PERFORM set_config('aa847.expected_v_tour_place', n::text, true);
    SELECT count(*) INTO n FROM catalog.v_tour_component;
    PERFORM set_config('aa847.expected_v_tour_component', n::text, true);
    SELECT count(*) INTO n FROM catalog.v_destination;
    PERFORM set_config('aa847.expected_v_destination', n::text, true);
    PERFORM set_config('app.tenant_id', '', true);
END $$;

-- ── 1. Destinations + the line's kind, status, length and non-null bbox ─────────────────────────────────────────
CREATE OR REPLACE VIEW catalog.v_destination WITH (security_barrier = true) AS
SELECT 'cis'::text      AS source_system,
       d.id::text       AS source_id,
       d.id             AS destination_id,
       d.name,
       d.country,
       d.lat,
       d.lng,
       photos.cover_path AS cover_photo_path,
       d.cover_image_url,
       COALESCE(photos.n, 0) AS photo_count,
       d.created_at,
       GREATEST(d.created_at, d.located_at, photos.last_update) AS updated_at,
       d.geo_status,
       d.located_by,
       d.geo_precision  AS precision,
       -- 256 (appended)
       s.kind           AS shape_kind,
       s.status         AS shape_status,
       s.source         AS shape_source,
       s.length_km::double precision AS length_km,
       COALESCE(s.min_lat, d.lat) AS min_lat,
       COALESCE(s.min_lng, d.lng) AS min_lng,
       COALESCE(s.max_lat, d.lat) AS max_lat,
       COALESCE(s.max_lng, d.lng) AS max_lng,
       s.geom_lo        AS shape_lo
  FROM shared.destinations d
  LEFT JOIN geo.place_shape s ON s.destination_id = d.id AND d.geo_precision = 'line'
  LEFT JOIN LATERAL (
      SELECT count(*) AS n, max(p.updated_at) AS last_update,
             (array_agg(p.path) FILTER (WHERE p.position = 1))[1] AS cover_path
        FROM shared.v_destination_photos p
       WHERE p.destination_id = d.id
  ) photos ON true;

-- ── 2. Line geometry by id (new) ─────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW catalog.v_destination_shape WITH (security_barrier = true) AS
SELECT s.destination_id,
       s.status   AS shape_status,
       s.geom_mid AS shape_mid,
       s.geom_lo  AS shape_lo
  FROM geo.place_shape s
  JOIN shared.destinations d ON d.id = s.destination_id
                            AND d.geo_precision = 'line'
                            AND d.geo_status <> 'suspect' AND d.duplicate_of IS NULL;

COMMENT ON VIEW catalog.v_destination_shape IS
    'AA-847 (256) — the geometry of a LINE destination (river, road, trail): GeoJSON clipped to its country, shape_mid '
    '≤ 300 vertices / 12 KB (map from zoom 7, trip panel), shape_lo ≤ 60 (below zoom 7, static maps). shape_status: '
    'ok (OpenStreetMap feature) | approximate (anchored route of a tour-day, draw dashed "approximate route") | '
    'manual | pending / not_found / failed (no geometry: draw the provisional dashed line between the day''s stops). '
    'OpenStreetMap data (ODbL): show "© OpenStreetMap contributors". Read by id. TripPlanner only.';

-- ── 3. Places per tour day + the day's stretch of a line ─────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW catalog.v_tour_place WITH (security_barrier = true) AS
WITH atom AS (
    SELECT 'cis'::text AS source_system, t.source_id, t.tour_id, t.country AS tour_country,
           a.itinerary_day, btrim(a.place) AS place, lower(btrim(a.place)) AS place_key,
           a.atom_id, a.activity_type, a.created_at,
           dm.days ->> a.itinerary_day::text AS day_text,
           pc.card_id
      FROM catalog._live_tour t
      CROSS JOIN LATERAL (
          SELECT jsonb_object_agg(d.day_number::text, d.title || E'\n' || d.body) AS days
            FROM catalog._tour_day_text d
           WHERE d.tour_id = t.tour_id
      ) dm
      -- the v_active_tour_atoms rule (203) on the base table: t is already a live master tour
      JOIN acp_contract.tour_atoms a ON a.tour_id = t.tour_id AND NOT a.deleted AND NOT a.is_empty_marker
      LEFT JOIN acp_shared.atom_place_card apc ON apc.atom_id = a.atom_id
      LEFT JOIN acp_shared.place_card pc ON pc.card_id = apc.card_id AND pc.status <> 'rejected'
     WHERE a.place IS NOT NULL AND btrim(a.place) <> ''
),
spelled AS (
    SELECT atom.*,
           count(*) OVER (PARTITION BY tour_id, itinerary_day, place) AS spelling_n,
           strpos(COALESCE(day_text, ''), place) > 0                  AS spelled_in_text
      FROM atom
),
grouped AS (
    SELECT source_system, source_id, tour_id, tour_country,
           itinerary_day                                                      AS day_number,
           place_key,
           (array_agg(place ORDER BY spelled_in_text DESC, spelling_n DESC,
                                     place COLLATE "C"))[1]                   AS place_name,
           (array_agg(card_id ORDER BY created_at, card_id)
                FILTER (WHERE card_id IS NOT NULL))[1]                        AS place_card_id,
           array_agg(DISTINCT activity_type) FILTER (WHERE activity_type IS NOT NULL) AS activity_types,
           count(*)                                                           AS atom_count,
           min(created_at)                                                    AS first_seen_at,
           NULLIF(strpos(lower(COALESCE(max(day_text), '')), place_key), 0)   AS text_pos
      FROM spelled
     GROUP BY source_system, source_id, tour_id, tour_country, itinerary_day, place_key
)
SELECT g.source_system, g.source_id, g.tour_id, g.day_number,
       row_number() OVER (PARTITION BY g.tour_id, g.day_number
                          ORDER BY g.text_pos NULLS LAST, g.first_seen_at,
                                   g.place_key COLLATE "C") AS position,
       g.place_name,
       g.place_card_id,
       pc.display_name AS place_display_name,
       pc.locality,
       pc.region,
       COALESCE(pc.country, g.tour_country) AS country,
       d.id   AS destination_id,
       d.name AS destination_name,
       d.lat,
       d.lng,
       COALESCE(g.activity_types, ARRAY[]::text[]) AS activity_types,
       g.atom_count,
       d.located_by,
       d.geo_precision AS precision,
       -- 256 (appended): the stretch of a line destination this tour-day follows (geo.tour_segment, current build)
       seg.segment,
       seg.basis               AS segment_basis,
       seg.from_destination_id AS segment_from_destination_id,
       seg.to_destination_id   AS segment_to_destination_id,
       seg.segment_km::double precision AS segment_km
  FROM grouped g
  LEFT JOIN acp_shared.place_card pc ON pc.card_id = g.place_card_id
  -- 1. the place pipeline's link: the component of this source, day and place (component identity
  --    is name_norm of the itinerary spelling, 226 / services/places/components.py)
  LEFT JOIN LATERAL (
      SELECT gp.destination_id
        FROM geo.tour_place gp
       WHERE gp.source_id = g.source_id
         AND gp.day_index = g.day_number
         AND gp.destination_id IS NOT NULL
         AND geo.name_norm(gp.name) = geo.name_norm(g.place_name)
       ORDER BY gp.component_id
       LIMIT 1
  ) pipeline ON true
  -- 3. 225's exact name + country match (a 226 duplicate row resolves to its keeper); the first USABLE
  --    match, so a suspect card-name match does not hide a usable itinerary-name match
  LEFT JOIN LATERAL (
      SELECT k.id
        FROM shared.destinations dd
        JOIN shared.destinations k ON k.id = COALESCE(dd.duplicate_of, dd.id)
       WHERE lower(dd.name) IN (lower(pc.display_name), lower(g.place_name))
         AND lower(dd.country) = lower(COALESCE(pc.country, g.tour_country))
         AND k.geo_status <> 'suspect' AND k.duplicate_of IS NULL
       ORDER BY (lower(dd.name) = lower(pc.display_name)) DESC NULLS LAST, dd.id
       LIMIT 1
  ) legacy ON true
  -- first usable candidate: pipeline link, 2. the card's destination, legacy match
  LEFT JOIN LATERAL (
      SELECT dd.id, dd.name, dd.lat, dd.lng, dd.located_by, dd.geo_precision
        FROM (VALUES (1, pipeline.destination_id), (2, pc.destination_id), (3, legacy.id)) AS c(rank, id)
        JOIN shared.destinations dd ON dd.id = c.id
       WHERE dd.geo_status <> 'suspect' AND dd.duplicate_of IS NULL
       ORDER BY c.rank
       LIMIT 1
  ) d ON true
  -- 256: the current build's stretch of this day on this (line) destination; at most one row (the PK)
  LEFT JOIN LATERAL (
      SELECT ts.segment, ts.basis, ts.from_destination_id, ts.to_destination_id, ts.segment_km
        FROM geo.graph_build b
        JOIN geo.tour_segment ts ON ts.build_id = b.build_id
       WHERE b.is_current
         AND ts.source_id = g.source_id
         AND ts.day_index = g.day_number
         AND ts.destination_id = d.id
       LIMIT 1
  ) seg ON true;

-- ── 4. Components + precision + the day's stretch (same dynamic build as 228 / 253 for the optional embedding) ────
DO $do$
DECLARE
    emb text := '';
BEGIN
    IF EXISTS (SELECT 1 FROM pg_attribute
                WHERE attrelid = 'geo.tour_place'::regclass AND attname = 'embedding' AND NOT attisdropped) THEN
        emb := E',\n               gp.embedding';
    ELSE
        RAISE NOTICE 'migration 256: geo.tour_place.embedding missing (no pgvector), '
                     'catalog.v_tour_component kept without the embedding column';
    END IF;
    EXECUTE format($v$
        CREATE OR REPLACE VIEW catalog.v_tour_component WITH (security_barrier = true) AS
        SELECT 'cis'::text               AS source_system,
               t.source_id,
               t.tour_id,
               gp.tour_id                AS built_from_tour_id,
               (gp.tour_id <> t.tour_id) AS is_stale,
               gp.component_id,
               gp.day_index,
               gp.destination_id,
               gp.name,
               gp.country,
               gp.activity,
               gp.intensity_level,
               gp.season_months,
               gp.duration_hint,
               gp.text_extract,
               gp.place_card_id%s,
               d.geo_precision           AS precision,
               seg.segment,
               seg.basis                 AS segment_basis,
               seg.from_destination_id   AS segment_from_destination_id,
               seg.to_destination_id     AS segment_to_destination_id,
               seg.segment_km::double precision AS segment_km
          FROM geo.tour_place gp
          JOIN catalog._live_tour t ON t.source_id = gp.source_id
          JOIN shared.destinations d ON d.id = gp.destination_id
                                    AND d.geo_status <> 'suspect' AND d.duplicate_of IS NULL
          LEFT JOIN LATERAL (
              SELECT ts.segment, ts.basis, ts.from_destination_id, ts.to_destination_id, ts.segment_km
                FROM geo.graph_build b
                JOIN geo.tour_segment ts ON ts.build_id = b.build_id
               WHERE b.is_current
                 AND ts.source_id = gp.source_id
                 AND ts.day_index = gp.day_index
                 AND ts.destination_id = gp.destination_id
               LIMIT 1
          ) seg ON true
    $v$, emb);
END $do$;

-- ── 5. Live stops (internal): never a line (defence in depth) ────────────────────────────────────────────────────
CREATE OR REPLACE VIEW catalog._live_stop AS
SELECT t.source_id,
       t.tour_id,
       s.day_index,
       s.destination_id,
       s.country,
       s.source,
       s.build_id
  FROM geo.graph_build b
  JOIN geo.tour_stop s ON s.build_id = b.build_id
  JOIN catalog._live_tour t ON t.source_id = s.source_id
  JOIN shared.destinations d ON d.id = s.destination_id
                            AND d.geo_status <> 'suspect' AND d.duplicate_of IS NULL
                            AND d.geo_precision IS DISTINCT FROM 'line'
 WHERE b.is_current;

COMMENT ON VIEW catalog._live_stop IS
    'AA-847 — INTERNAL: stops of the current tour graph build on live tours and usable destinations (the rows of '
    'v_tour_stop), read by v_tour_stop, v_graph_node and v_tour_junction. Never a line destination (256). Not '
    'security_barrier, not granted.';

COMMENT ON COLUMN catalog.v_destination.min_lat IS
    'AA-847 (256): bbox of the line''s shape, else the point (never NULL): filter tiles on min/max lat/lng';
COMMENT ON COLUMN catalog.v_tour_place.segment IS
    'AA-847 (256): GeoJSON LineString ≤ 300 vertices — the stretch of this line destination the day follows (current '
    'build); NULL with basis feature (draw the clipped feature, or the provisional line between segment_from / _to)';

-- ── Grants (CREATE OR REPLACE keeps the existing ones; restated, unguarded) ──────────────────────────────────────
GRANT SELECT ON catalog.v_destination, catalog.v_tour_place, catalog.v_tour_component
    TO aa_app_user, tripplanner, booking;
GRANT SELECT ON catalog.v_destination_shape TO tripplanner;
REVOKE ALL ON catalog.v_destination_shape FROM PUBLIC;

-- ── Closing check as catalog_owner: same rows, never-null bbox, no line stop ─────────────────────────────────────
DO $$
DECLARE
    n bigint;
BEGIN
    PERFORM set_config('app.tenant_id', '00000000-0000-0000-0000-000000000000', true);
    PERFORM 1 FROM catalog.v_destination_shape LIMIT 1;
    SELECT count(*) INTO n FROM catalog.v_tour_place;
    IF n <> current_setting('aa847.expected_v_tour_place')::bigint THEN
        RAISE EXCEPTION 'migration 256: catalog.v_tour_place has % rows, % before', n,
                        current_setting('aa847.expected_v_tour_place');
    END IF;
    SELECT count(*) INTO n FROM catalog.v_tour_component;
    IF n <> current_setting('aa847.expected_v_tour_component')::bigint THEN
        RAISE EXCEPTION 'migration 256: catalog.v_tour_component has % rows, % before', n,
                        current_setting('aa847.expected_v_tour_component');
    END IF;
    SELECT count(*) INTO n FROM catalog.v_destination;
    IF n <> current_setting('aa847.expected_v_destination')::bigint THEN
        RAISE EXCEPTION 'migration 256: catalog.v_destination has % rows, % before', n,
                        current_setting('aa847.expected_v_destination');
    END IF;
    IF EXISTS (SELECT 1 FROM catalog.v_destination
                WHERE min_lat IS NULL OR min_lng IS NULL OR max_lat IS NULL OR max_lng IS NULL) THEN
        RAISE EXCEPTION 'migration 256: catalog.v_destination has a NULL bbox column';
    END IF;
    IF EXISTS (SELECT 1 FROM catalog._live_stop s JOIN shared.destinations d ON d.id = s.destination_id
                WHERE d.geo_precision = 'line') THEN
        RAISE EXCEPTION 'migration 256: catalog._live_stop still shows a line destination';
    END IF;
    RAISE NOTICE 'migration 256: as catalog_owner v_tour_place = %, v_tour_component = %, v_destination = % (unchanged)',
                 current_setting('aa847.expected_v_tour_place'), current_setting('aa847.expected_v_tour_component'),
                 current_setting('aa847.expected_v_destination');
    PERFORM set_config('app.tenant_id', '', true);
END $$;

SET LOCAL ROLE cis_owner;
REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('256', now(), 'AA-847: catalog views expose line places — v_destination shape kind / status / length / never-null bbox / shape_lo, v_destination_shape (tripplanner), v_tour_place and v_tour_component day stretch (geo.tour_segment), _live_stop without lines')
ON CONFLICT (version) DO NOTHING;

COMMIT;
