-- Migration 253: AA-847 — catalog L4 read model: one liveness definition the graph views can flatten, a cheaper
-- destination photo read, and an index-servable top-k view for TripPlanner search (ADR 0007 Consequences).
--
-- Why. Every catalog place / graph view of 228 joined catalog.v_tour. v_tour is a security_barrier view, so the
-- planner never flattens it: each read of v_tour_component, v_tour_stop, v_tour_leg, v_graph_node, v_graph_edge,
-- v_tour_junction or v_tour_day_route computed v_tour for every live tour first (a LATERAL photo count, a cover
-- join, the duration regex and an md5 content_hash per tour), only to use source_id and tour_id. v_tour_junction ran
-- two EXISTS over v_tour_stop (v_tour again) and v_graph_node aggregated over v_tour_stop. S237 Dev parity for Laos
-- (root docs/audits/2026-10-14-S237-lane-backlog/aa712-6b/): routes ~1 s on cis vs ~40 ms legacy, 80 tiles 1,014 vs
-- 122 ms, destination detail 3.6 s vs 0.85 s. TripPlanner cannot flip PLACES_SOURCE to cis before this is close.
--
-- What (same columns, same rows — CREATE OR REPLACE VIEW cannot drop, rename, reorder or retype a column):
--   1. catalog._live_tour (INTERNAL, not granted, not security_barrier): the live-tour rule of 225's `live` CTE with
--      its whole projection (AA master tenant, master_status 'active', not deleted, source active and not deleted).
--      Not a barrier, so inside each view it is flattened and the columns that view does not read are pruned.
--   2. catalog.v_tour is rebuilt on _live_tour (its `live` CTE moved there verbatim): one liveness definition.
--   3. _tour_day_text, v_tour_place (235's LATERAL kept), v_tour_photo, v_tour_component (228's DO/EXECUTE build of
--      the conditional embedding column kept), v_tour_day_route, v_tour_leg and v_graph_edge join _live_tour instead
--      of v_tour.
--   4. catalog._live_stop (INTERNAL, not granted, not security_barrier): the stops of the current build on live
--      tours and usable destinations — what v_tour_stop showed. v_tour_stop, v_graph_node and v_tour_junction read
--      it; v_tour_junction reads the distinct live stop destinations once (a materialized CTE) instead of two
--      EXISTS over v_tour_stop per junction row.
--   5. v_destination: the cover photo comes from the same per-destination LATERAL as the photo count (position 1 of
--      the same window), instead of a hash join over the window of every matched photo on each call. Per id it is
--      the old LATERAL plus one aggregate (lesson S238: a `= ANY($1)` filter is not pushed through a join, so the
--      per-id shape stays). Same values: shared.v_destination_photos numbers each destination's photos 1..n.
--   6. catalog.v_component_embedding (component_id, source_id, destination_id, activity, intensity_level,
--      season_months, embedding): NOT security_barrier, only resolved components of live tours, created only where
--      geo.tour_place.embedding exists (pgvector; the 228 pattern). A reader's ORDER BY embedding <=> q LIMIT k can be
--      served by the HNSW index tour_place_embedding_hnsw (hnsw.iterative_scan on pgvector >= 0.8); the filter
--      columns are there so TripPlanner's vector_topk scan_where stays inside the index scan. Granted to tripplanner
--      ONLY (Booking and aa_app_user do not need vectors). Usable-destination and other checks stay on the reader,
--      after the scan (keep_where over catalog.v_tour_component).
--   7. ANALYZE of the geo tables and shared.destinations / place_photo (Dev reltuples were stale, schema reference
--      20/10: geo.tour_place ~967 rows for ~1 country).
-- Not here, measured first (AA-847 plan, slice A probe): security_barrier off on the graph views, the
-- catalog.graph.v1.1 columns on v_tour_component, an expression index on raw_tours (COALESCE(source_group_id,
-- tour_id)::text). A later migration (255+) adds any of them if the probe's EXPLAIN shows the need.
--
-- Recipe. After 245 schema catalog belongs to cis_owner and the views to catalog_owner, so this file uses the X1
-- S22 catalog recipe (AA-CIS-App CONTEXT.md): GRANT CREATE ON SCHEMA catalog TO catalog_owner; SET LOCAL ROLE
-- catalog_owner; the view DDL; SET LOCAL ROLE cis_owner; REVOKE CREATE. DB Migrate runs the file as cis_owner
-- (login db_migrator, a member of catalog_owner). Never RESET ROLE, no SECURITY DEFINER, no role DDL. The new views
-- are created by catalog_owner, so they are catalog_owner's (no ALTER ... OWNER TO needed). The conftest replay skips
-- this file (it needs 245 / 246); tests/integration/test_aa847_migration_253.py applies it the DB Migrate way.
--
-- Locks. CREATE OR REPLACE VIEW takes ACCESS EXCLUSIVE on each catalog view until COMMIT: TripPlanner browse and
-- Booking catalog reads wait for the file (a few seconds). lock_timeout 10s: fail fast and re-run when idle instead
-- of queueing behind a long reader. Apply while the job tables are idle (DB Migrate waits for it).
--
-- Idempotent (CREATE OR REPLACE, re-runnable grants), one transaction, self-registering. Applied on Dev by the
-- AA-CIS-Infra DB Migrate workflow from the byte-identical copy in db/migrations/cis/. No code depends on it: the
-- TripPlanner reader of v_component_embedding merges only after this is applied (CONTEXT rule).
--
-- Rollback: re-run the 225 (v_tour, _tour_day_text, v_tour_photo), 235 (v_tour_place) and 228 (the other views)
-- statements under the same recipe, then DROP VIEW catalog.v_component_embedding, catalog._live_stop,
-- catalog._live_tour, and DELETE FROM shared.schema_versions WHERE version = '253'.

BEGIN;
SET LOCAL lock_timeout = '10s';

-- ── Preconditions + what the closing check compares with (read as the file's role: cis_owner on Dev) ─────────────
DO $$
DECLARE
    n_live  bigint;
    n_comp  bigint;
BEGIN
    IF to_regclass('catalog.v_tour_component') IS NULL OR to_regclass('catalog.v_tour_place') IS NULL THEN
        RAISE EXCEPTION 'migration 253: catalog views of 225 / 228 / 235 missing';
    END IF;
    IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'catalog') <> 'cis_owner' THEN
        RAISE EXCEPTION 'migration 253: schema catalog is not owned by cis_owner (apply 245 first)';
    END IF;
    SELECT count(*) INTO n_live
      FROM gold_aa_internal.published_tours pt
      JOIN silver_aa_internal.raw_tours rt ON rt.tour_id = pt.tour_id
     WHERE pt.tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
       AND pt.master_status = 'active' AND pt.deleted_at IS NULL
       AND rt.source_status = 'active' AND rt.deleted_at IS NULL;
    SELECT count(*) INTO n_comp
      FROM geo.tour_place gp
      JOIN shared.destinations d ON d.id = gp.destination_id
                                AND d.geo_status <> 'suspect' AND d.duplicate_of IS NULL
     WHERE EXISTS (SELECT 1
                     FROM gold_aa_internal.published_tours pt
                     JOIN silver_aa_internal.raw_tours rt ON rt.tour_id = pt.tour_id
                    WHERE COALESCE(rt.source_group_id, rt.tour_id)::text = gp.source_id
                      AND pt.tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
                      AND pt.master_status = 'active' AND pt.deleted_at IS NULL
                      AND rt.source_status = 'active' AND rt.deleted_at IS NULL);
    PERFORM set_config('aa847.expected_live_tours', n_live::text, true);
    PERFORM set_config('aa847.expected_components', n_comp::text, true);
END $$;

GRANT CREATE ON SCHEMA catalog TO catalog_owner;
SET LOCAL ROLE catalog_owner;

-- ── 1. Live tours (internal) ─────────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW catalog._live_tour AS
SELECT rt.tour_id,
       COALESCE(rt.source_group_id, rt.tour_id)::text AS source_id,
       rt.source_version, rt.sku, rt.country, rt.duration, rt.inclusions, rt.exclusions,
       rt.activities, rt.best_time_to_go, rt.group_size, rt.lifecycle_stage,
       pt.aa_name, pt.aa_subtitle, pt.aa_summary, pt.aa_description, pt.aa_highlights,
       pt.aa_itineraries, pt.published_at
  FROM gold_aa_internal.published_tours pt
  JOIN silver_aa_internal.raw_tours rt ON rt.tour_id = pt.tour_id
 WHERE pt.tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
   AND pt.master_status = 'active'
   AND pt.deleted_at IS NULL
   AND rt.source_status = 'active'
   AND rt.deleted_at IS NULL;

COMMENT ON VIEW catalog._live_tour IS
    'AA-847 — INTERNAL: the live-tour rule of the catalog (AA master tenant, Master Content active and not deleted, '
    'source active and not deleted), with the source columns v_tour shows. Not security_barrier so the views that '
    'join it can flatten it; not granted to consumers; may change without notice.';

-- ── 2. Tours: 225's body on _live_tour (the `live` CTE is _live_tour) ──────────────────────────────────────────────
CREATE OR REPLACE VIEW catalog.v_tour WITH (security_barrier = true) AS
WITH enriched AS (
    SELECT l.*,
           cover.path AS cover_photo_path,
           COALESCE(photos.n, 0) AS photo_count,
           photos.last_update AS photos_updated_at,
           COALESCE(
               substring(lower(l.duration) FROM '(\d+)\s*-?\s*days?')::int,
               (SELECT max(m[1]::int)
                  FROM regexp_matches(l.aa_itineraries, '(?:^|\n)Day\s+(\d+)\s+—', 'g') AS m)
           ) AS duration_days
      FROM catalog._live_tour l
      LEFT JOIN shared.v_tour_photos cover ON cover.tour_id = l.tour_id AND cover.position = 1
      LEFT JOIN LATERAL (
          SELECT count(*) AS n, max(p.updated_at) AS last_update
            FROM shared.v_tour_photos p
           WHERE p.tour_id = l.tour_id
      ) photos ON true
)
SELECT 'cis'::text                AS source_system,
       e.source_id,
       e.tour_id,
       e.source_version,
       e.sku,
       trim(BOTH '-' FROM left(regexp_replace(lower(e.aa_name || ' ' || COALESCE(e.country, '')),
                                              '[^a-z0-9]+', '-', 'g'), 80))
           || '-' || left(replace(e.source_id, '-', ''), 8) AS slug,
       e.aa_name                  AS title,
       e.aa_subtitle              AS subtitle,
       e.aa_summary               AS summary,
       e.aa_description           AS description,
       e.aa_highlights            AS highlights,
       e.country,
       e.duration                 AS duration_raw,
       e.duration_days,
       e.activities,
       e.inclusions,
       e.exclusions,
       e.best_time_to_go,
       e.group_size,
       e.lifecycle_stage::text    AS lifecycle_stage,
       e.aa_itineraries           AS itinerary_text,
       e.cover_photo_path,
       e.photo_count,
       e.published_at,
       -- not a change cursor: published_tours has no updated_at, so an in-place Master Content edit
       -- moves content_hash but not this. Consumers diff content_hash (contract catalog.tour.v1).
       GREATEST(e.published_at, e.photos_updated_at) AS updated_at,
       md5(jsonb_build_array(
           e.aa_name, e.aa_subtitle, e.aa_summary, e.aa_description, e.aa_highlights, e.aa_itineraries,
           e.country, e.duration, e.activities, e.inclusions, e.exclusions, e.best_time_to_go,
           e.group_size, e.lifecycle_stage::text, e.sku, e.cover_photo_path
       )::text)                   AS content_hash
  FROM enriched e;

-- ── 3a. Day text (internal): 225's body on _live_tour ─────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW catalog._tour_day_text WITH (security_barrier = true) AS
WITH chunk AS (
    SELECT 'cis'::text AS source_system, t.source_id, t.tour_id, t.country AS tour_country, c.ord,
           regexp_match(btrim(c.txt, E' \t\r\n'), '^Day\s+(\d+)\s+—[ \t]*([^\n]*)(.*)$') AS m
      FROM catalog._live_tour t
     CROSS JOIN LATERAL regexp_split_to_table(t.aa_itineraries, '\n(?=Day\s+\d+\s+—)')
           WITH ORDINALITY AS c(txt, ord)
     WHERE t.aa_itineraries IS NOT NULL
)
-- a repeated day number keeps the LAST block (parse_canonical_itinerary_days dict semantics)
SELECT DISTINCT ON (tour_id, (m[1])::int)
       source_system, source_id, tour_id, tour_country,
       (m[1])::int             AS day_number,
       btrim(m[2])             AS title,
       btrim(m[3], E' \t\r\n') AS body
  FROM chunk
 WHERE m IS NOT NULL
 ORDER BY tour_id, (m[1])::int, ord DESC;

-- ── 3b. Places per tour day: 235's body on _live_tour ─────────────────────────────────────────────────────────────
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
       d.geo_precision AS precision
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
  ) d ON true;

-- ── 3c. Tour photos: 225's body on _live_tour ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW catalog.v_tour_photo WITH (security_barrier = true) AS
SELECT 'cis'::text AS source_system, t.source_id, p.tour_id, p.photo_id, p.path, p.place_label, p.destination_id,
       p.width, p.height, p.position, p.updated_at
  FROM catalog._live_tour t
  JOIN shared.v_tour_photos p ON p.tour_id = t.tour_id;

-- ── 3d. Components: 228's body on _live_tour, same dynamic build for the optional embedding column ────────────────
DO $do$
DECLARE
    emb text := '';
BEGIN
    IF EXISTS (SELECT 1 FROM pg_attribute
                WHERE attrelid = 'geo.tour_place'::regclass AND attname = 'embedding' AND NOT attisdropped) THEN
        emb := E',\n               gp.embedding';
    ELSE
        RAISE NOTICE 'migration 253: geo.tour_place.embedding missing (no pgvector), '
                     'catalog.v_tour_component kept without its last column embedding';
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
               gp.place_card_id%s
          FROM geo.tour_place gp
          JOIN catalog._live_tour t ON t.source_id = gp.source_id
          JOIN shared.destinations d ON d.id = gp.destination_id
                                    AND d.geo_status <> 'suspect' AND d.duplicate_of IS NULL
    $v$, emb);
END $do$;

-- ── 3e. Day route: 228's body on _live_tour ───────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW catalog.v_tour_day_route WITH (security_barrier = true) AS
SELECT 'cis'::text               AS source_system,
       t.source_id,
       t.tour_id,
       td.tour_id                AS built_from_tour_id,
       (td.tour_id <> t.tour_id) AS is_stale,
       td.day_index,
       td.title,
       td.start_place,
       td.end_place,
       td.overnight_place,
       d.id                      AS overnight_destination_id,
       td.places,
       td.extracted_by,
       td.is_transit_day
  FROM geo.tour_day td
  JOIN catalog._live_tour t ON t.source_id = td.source_id
  LEFT JOIN shared.destinations d ON d.id = td.overnight_destination_id
                                 AND d.geo_status <> 'suspect' AND d.duplicate_of IS NULL;

-- ── 4a. Live stops (internal): what v_tour_stop showed ────────────────────────────────────────────────────────────
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
 WHERE b.is_current;

COMMENT ON VIEW catalog._live_stop IS
    'AA-847 — INTERNAL: stops of the current tour graph build on live tours and usable destinations (the rows of '
    'v_tour_stop), read by v_tour_stop, v_graph_node and v_tour_junction. Not security_barrier, not granted.';

-- ── 4b. Graph views on _live_stop / _live_tour ────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW catalog.v_tour_stop WITH (security_barrier = true) AS
SELECT 'cis'::text AS source_system,
       s.source_id,
       s.tour_id,
       s.day_index,
       s.destination_id,
       s.country,
       s.source,
       s.build_id
  FROM catalog._live_stop s;

CREATE OR REPLACE VIEW catalog.v_tour_leg WITH (security_barrier = true) AS
SELECT 'cis'::text AS source_system,
       t.source_id,
       t.tour_id,
       l.day_from,
       l.day_to,
       l.days,
       l.start_destination_id,
       l.end_destination_id,
       l.destination_ids,
       l.countries,
       l.activities,
       l.build_id
  FROM geo.graph_build b
  JOIN geo.tour_leg l ON l.build_id = b.build_id
  JOIN catalog._live_tour t ON t.source_id = l.source_id
 WHERE b.is_current
   AND NOT EXISTS (SELECT 1 FROM shared.destinations d
                    WHERE d.id = ANY (l.destination_ids || l.start_destination_id || l.end_destination_id)
                      AND (d.geo_status = 'suspect' OR d.duplicate_of IS NOT NULL));

CREATE OR REPLACE VIEW catalog.v_graph_node WITH (security_barrier = true) AS
SELECT n.destination_id,
       d.name,
       d.country,
       d.lat,
       d.lng,
       d.located_by,
       d.geo_precision AS precision,
       live.source_ids,
       live.tour_ids,
       live.stop_count,
       n.activities,
       n.intensity_min,
       n.intensity_max,
       n.season_months,
       n.build_id,
       b.built_at
  FROM geo.graph_build b
  JOIN geo.graph_node n ON n.build_id = b.build_id
  JOIN shared.destinations d ON d.id = n.destination_id
                            AND d.geo_status <> 'suspect' AND d.duplicate_of IS NULL
  JOIN (SELECT x.destination_id,
               array_agg(x.source_id ORDER BY x.source_id) AS source_ids,
               array_agg(x.tour_id ORDER BY x.source_id)   AS tour_ids,
               sum(x.n)::integer                           AS stop_count
          FROM (SELECT s.destination_id, s.source_id, s.tour_id, count(*) AS n
                  FROM catalog._live_stop s
                 GROUP BY s.destination_id, s.source_id, s.tour_id) x
         GROUP BY x.destination_id) live ON live.destination_id = n.destination_id
 WHERE b.is_current;

CREATE OR REPLACE VIEW catalog.v_graph_edge WITH (security_barrier = true) AS
SELECT e.from_destination_id,
       e.to_destination_id,
       count(*)::integer                         AS tour_count,
       array_agg(t.source_id ORDER BY t.source_id) AS source_ids,
       array_agg(t.tour_id ORDER BY t.source_id)   AS tour_ids,
       e.km::double precision                    AS km,
       e.build_id
  FROM geo.graph_build b
  JOIN geo.graph_edge e ON e.build_id = b.build_id
 CROSS JOIN LATERAL unnest(e.source_ids) AS src(source_id)
  JOIN catalog._live_tour t ON t.source_id = src.source_id
 WHERE b.is_current
   AND NOT EXISTS (SELECT 1 FROM shared.destinations d
                    WHERE d.id IN (e.from_destination_id, e.to_destination_id)
                      AND (d.geo_status = 'suspect' OR d.duplicate_of IS NOT NULL))
 GROUP BY e.build_id, e.from_destination_id, e.to_destination_id, e.km;

CREATE OR REPLACE VIEW catalog.v_tour_junction WITH (security_barrier = true) AS
WITH live_dest AS MATERIALIZED (
    SELECT DISTINCT s.destination_id FROM catalog._live_stop s
)
SELECT j.destination_a,
       j.destination_b,
       j.km::double precision AS km,
       j.cross_border,
       j.build_id
  FROM geo.graph_build b
  JOIN geo.tour_junction j ON j.build_id = b.build_id
 WHERE b.is_current
   AND j.destination_a IN (SELECT ld.destination_id FROM live_dest ld)
   AND j.destination_b IN (SELECT ld.destination_id FROM live_dest ld);

-- ── 5. Destinations: cover + count from one per-destination LATERAL ───────────────────────────────────────────────
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
       d.geo_precision  AS precision
  FROM shared.destinations d
  LEFT JOIN LATERAL (
      SELECT count(*) AS n, max(p.updated_at) AS last_update,
             (array_agg(p.path) FILTER (WHERE p.position = 1))[1] AS cover_path
        FROM shared.v_destination_photos p
       WHERE p.destination_id = d.id
  ) photos ON true;

-- ── 6. Top-k component embeddings (pgvector only) ─────────────────────────────────────────────────────────────────
DO $do$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_attribute
                WHERE attrelid = 'geo.tour_place'::regclass AND attname = 'embedding' AND NOT attisdropped) THEN
        EXECUTE $v$
            CREATE OR REPLACE VIEW catalog.v_component_embedding AS
            SELECT gp.component_id,
                   gp.source_id,
                   gp.destination_id,
                   gp.activity,
                   gp.intensity_level,
                   gp.season_months,
                   gp.embedding
              FROM geo.tour_place gp
             WHERE gp.destination_id IS NOT NULL
               AND gp.embedding IS NOT NULL
               AND EXISTS (SELECT 1 FROM catalog._live_tour t WHERE t.source_id = gp.source_id)
        $v$;
        EXECUTE $v$
            COMMENT ON VIEW catalog.v_component_embedding IS
                'AA-847 — embeddings of resolved components of live tours, for an index-ordered top-k '
                '(ORDER BY embedding <=> q LIMIT k on the HNSW index of geo.tour_place; hnsw.iterative_scan on '
                'pgvector >= 0.8). Not security_barrier so the order can come from the index. Reader applies the '
                'usable-destination rule after the scan (catalog.v_tour_component). TripPlanner only.'
        $v$;
        EXECUTE 'GRANT SELECT ON catalog.v_component_embedding TO tripplanner';
    ELSE
        RAISE NOTICE 'migration 253: geo.tour_place.embedding missing (no pgvector), '
                     'catalog.v_component_embedding not created';
    END IF;
END $do$;

-- ── Grants: unchanged contract views keep 225 / 228 grants (CREATE OR REPLACE keeps them); restated, unguarded ────
GRANT SELECT ON catalog.v_tour, catalog.v_tour_day, catalog.v_tour_place, catalog.v_tour_photo,
                catalog.v_destination, catalog.v_destination_photo, catalog.v_tour_component,
                catalog.v_tour_day_route, catalog.v_tour_stop, catalog.v_tour_leg, catalog.v_graph_node,
                catalog.v_graph_edge, catalog.v_tour_junction
    TO aa_app_user, tripplanner, booking;

-- ── Closing check as catalog_owner (only its RLS policy can admit rows: app.tenant_id = nil uuid) ─────────────────
DO $$
DECLARE
    v          text;
    n_tours    bigint;
    n_comp     bigint;
BEGIN
    PERFORM set_config('app.tenant_id', '00000000-0000-0000-0000-000000000000', true);
    -- privileges are checked when the plan starts: LIMIT 1 raises on a missing grant without a full scan
    FOREACH v IN ARRAY ARRAY['_live_tour', '_live_stop', 'v_tour', 'v_tour_day', 'v_tour_place', 'v_tour_photo',
                             'v_destination', 'v_destination_photo', 'v_tour_day_route', 'v_tour_stop', 'v_tour_leg',
                             'v_graph_node', 'v_graph_edge', 'v_tour_junction'] LOOP
        EXECUTE format('SELECT 1 FROM catalog.%I LIMIT 1', v);
    END LOOP;
    IF to_regclass('catalog.v_component_embedding') IS NOT NULL THEN
        PERFORM 1 FROM catalog.v_component_embedding LIMIT 1;
    END IF;
    SELECT count(*) INTO n_tours FROM catalog._live_tour;
    SELECT count(*) INTO n_comp FROM catalog.v_tour_component;
    RAISE NOTICE 'migration 253: as catalog_owner live tours = % (expected %), components = % (expected %)',
                 n_tours, current_setting('aa847.expected_live_tours'),
                 n_comp, current_setting('aa847.expected_components');
    IF n_tours <> current_setting('aa847.expected_live_tours')::bigint THEN
        RAISE EXCEPTION 'migration 253: catalog._live_tour has % rows for catalog_owner, % live AA tours exist '
                        '(RLS policy catalog_owner_aa_master_read or a grant is missing)',
                        n_tours, current_setting('aa847.expected_live_tours');
    END IF;
    IF n_comp <> current_setting('aa847.expected_components')::bigint THEN
        RAISE EXCEPTION 'migration 253: catalog.v_tour_component has % rows for catalog_owner, % resolved places '
                        'of live tours exist', n_comp, current_setting('aa847.expected_components');
    END IF;
    PERFORM set_config('app.tenant_id', '', true);
END $$;

SET LOCAL ROLE cis_owner;
REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;

-- ── 7. Fresh statistics (Dev reltuples were stale; owner cis_owner) ───────────────────────────────────────────────
ANALYZE geo.tour_place;
ANALYZE geo.tour_day;
ANALYZE geo.graph_build;
ANALYZE geo.tour_stop;
ANALYZE geo.tour_leg;
ANALYZE geo.graph_node;
ANALYZE geo.graph_edge;
ANALYZE geo.tour_junction;
ANALYZE shared.destinations;
ANALYZE shared.place_photo;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('253', now(), 'AA-847 L4: catalog._live_tour / _live_stop (internal, flattenable) under every place and graph '
                      'view, v_tour rebuilt on _live_tour, v_destination cover from its per-id LATERAL, '
                      'v_component_embedding (top-k, tripplanner only, pgvector only); same columns and rows')
ON CONFLICT (version) DO NOTHING;

COMMIT;
