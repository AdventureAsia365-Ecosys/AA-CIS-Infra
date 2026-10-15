-- Migration 228: AA-712 — catalog place / graph views over schema geo (ADR 0007 decision 2, design
-- AA-Ecosys/docs/audits/2026-10-14-S236-design-review/aa712/03-design.md §2.3 + §2.5, slice 4).
--
-- TripPlanner (and later AA-Booking) read the places and the tour graph that the CIS place pipeline
-- (migration 226, jobs place_extract / place_geocode / tour_graph_build) writes into the CIS-internal
-- schema geo ONLY through these views. Contract: AA-Ecosys/docs/contracts/catalog.graph.v1.json (new
-- views) and catalog.tour.v1.1.json (the columns appended to v_tour_place / v_destination).
--
-- Views only (S237 decision D7): no top-k search function. TripPlanner keeps its exact
-- MIN(embedding <=> q) path on the cis read path until the catalog-wide run (design §6.5); through a
-- security_barrier view joined to catalog.v_tour the HNSW index on geo.tour_place cannot serve an
-- ORDER BY embedding <=> q LIMIT k, so the top-k needs its own object later.
--
-- New views (all security_barrier, owner catalog_owner, SELECT to aa_app_user / tripplanner / booking):
--   v_tour_component   TripPlanner itinerary_components shape (+ embedding where pgvector exists)
--   v_tour_day_route   start / end / overnight place per tour day
--   v_tour_stop, v_tour_leg, v_graph_node, v_graph_edge, v_tour_junction   current graph build only
-- Changed 225 views — columns APPENDED only (CREATE OR REPLACE VIEW cannot drop, rename, reorder or
-- retype a column; v_tour_day depends on v_tour_place and keeps working):
--   v_destination  + geo_status, located_by, precision
--   v_tour_place   + located_by, precision; destination_id is now resolved, in this order, by the
--                  place pipeline's link (geo.tour_place, same source_id + day + geo.name_norm of the
--                  place), the place card's destination (acp_shared.place_card.destination_id, 226),
--                  else the 225 exact name + country match — so tours the pipeline has not built yet
--                  keep their 225 pins (the TripPlanner "places fallback" reads them).
--
-- Rules every view here follows (design §2.3):
--   * Liveness is not stored: geo rows join catalog.v_tour on source_id (active master, not trashed,
--     source active), so trash / supersede needs no delete and a trashed tour stops routing at once.
--     The graph views keep a node / edge / junction only while a live tour still uses it.
--   * built_from_tour_id / is_stale: after set-active the previous build keeps serving (places of two
--     versions of one tour are near-identical) until the rebuild lands, instead of the tour vanishing.
--   * A usable destination is geo_status <> 'suspect' AND duplicate_of IS NULL (the rule of
--     services/places/store.py graph_inputs). Suspect or duplicate places never reach a consumer
--     through these views: a component on one is hidden, a night on one shows no destination, a stop /
--     leg / node / edge / junction on one is dropped.
--   * Graph views read the build with geo.graph_build.is_current only (one row, partial unique index).
--   * Coordinates carry located_by + precision: geoapify = confirmed point (attribution "Powered by
--     Geoapify" + "© OpenStreetMap contributors" wherever shown), llm = the model's point, precision
--     'area' (draw an area, not a pin), manual = admin fix, mapbox = legacy TripPlanner row not yet
--     re-confirmed; precision NULL = legacy row the CIS pipeline has not processed yet.
--
-- RLS: same catalog_owner dance as migration 225 (read its header). geo.* has no RLS; catalog_owner
-- gets USAGE on schema geo + SELECT on exactly the geo tables the views read (no other app gets USAGE on
-- geo or any geo table; the consumers only get EXECUTE on the pure geo.name_norm, which a view calls with
-- the reader's rights). The runner is a member of catalog_owner for this transaction only.
--
-- pgvector: geo.tour_place.embedding exists only where the vector type exists (226). Without it (CI
-- Postgres) v_tour_component is created without its last column, embedding, with a NOTICE; the other
-- columns are identical, so the embedding column is always last.
--
-- Cross-owner grants are NOT guarded by IF EXISTS(role) (schema-ownership rule 5): roles tripplanner
-- and booking must exist. Idempotent (CREATE OR REPLACE, re-runnable grants), one transaction,
-- self-registering. Applied on Dev by the AA-CIS-Infra DB Migrate workflow from the byte-identical
-- copy in db/migrations/cis/ — this file merges to main first, with no code that depends on it
-- (S237 migration flow D8).

BEGIN;
-- CREATE OR REPLACE VIEW takes an ACCESS EXCLUSIVE lock on v_tour_place / v_destination: fail fast
-- (and re-run when idle) instead of queueing behind a long reader and blocking every catalog read.
SET LOCAL lock_timeout = '10s';

-- ── Preconditions ──────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF to_regclass('catalog.v_tour') IS NULL THEN
        RAISE EXCEPTION 'migration 228: catalog.v_tour missing (apply 225 first)';
    END IF;
    IF to_regclass('geo.tour_place') IS NULL OR to_regclass('geo.graph_build') IS NULL THEN
        RAISE EXCEPTION 'migration 228: schema geo missing (apply 226 first)';
    END IF;
END $$;

-- Transaction-scoped membership (revoked at the end, see 225 header): CREATE OR REPLACE on a view
-- owned by catalog_owner and ALTER ... OWNER TO catalog_owner both need it.
GRANT catalog_owner TO CURRENT_USER;

DO $$
BEGIN
    IF NOT pg_has_role(current_user, 'catalog_owner', 'MEMBER') THEN
        RAISE EXCEPTION 'migration 228: % must be able to SET ROLE catalog_owner (GRANT catalog_owner '
                        'TO % failed?)', current_user, current_user;
    END IF;
    SET LOCAL ROLE catalog_owner;
    RESET ROLE;
END $$;

-- ── catalog_owner reads geo (exactly the tables the views read; no write, no other app) ────────
GRANT USAGE ON SCHEMA geo TO catalog_owner;
GRANT SELECT ON geo.tour_place, geo.tour_day, geo.graph_build, geo.tour_stop, geo.graph_node,
                geo.graph_edge, geo.tour_leg, geo.tour_junction
    TO catalog_owner;
-- v_tour_place calls geo.name_norm. A function in a view runs with the READER's EXECUTE right (unlike the
-- tables, which are checked as the view owner), so the consumers need it too. Granted explicitly instead
-- of relying on the default EXECUTE TO PUBLIC, so hardening geo (REVOKE ... FROM PUBLIC) cannot break
-- every catalog place read; without USAGE on schema geo they still cannot call it by name.
GRANT EXECUTE ON FUNCTION geo.name_norm(text) TO catalog_owner, aa_app_user, tripplanner, booking;

-- ── Destinations: + geo_status, located_by, precision (appended) ────────────────────────────────
CREATE OR REPLACE VIEW catalog.v_destination WITH (security_barrier = true) AS
SELECT 'cis'::text      AS source_system,
       d.id::text       AS source_id,
       d.id             AS destination_id,
       d.name,
       d.country,
       d.lat,
       d.lng,
       cover.path       AS cover_photo_path,
       d.cover_image_url,
       COALESCE(photos.n, 0) AS photo_count,
       d.created_at,
       GREATEST(d.created_at, d.located_at, photos.last_update) AS updated_at,
       d.geo_status,
       d.located_by,
       d.geo_precision  AS precision
  FROM shared.destinations d
  LEFT JOIN shared.v_destination_photos cover ON cover.destination_id = d.id AND cover.position = 1
  LEFT JOIN LATERAL (
      SELECT count(*) AS n, max(p.updated_at) AS last_update
        FROM shared.v_destination_photos p
       WHERE p.destination_id = d.id
  ) photos ON true;

COMMENT ON VIEW catalog.v_destination IS
    'AA-679 / AA-712 — golden record of places (shared.destinations, CIS-owned since ADR 0002) + AA cover '
    'photo + geo quality (228): geo_status ok | suspect (do not draw) | manual, located_by, precision.';
COMMENT ON COLUMN catalog.v_destination.located_by IS
    'geoapify (confirmed: show "Powered by Geoapify" + "© OpenStreetMap contributors") | llm (model point) | '
    'manual (admin fix) | mapbox (legacy TripPlanner row, not yet re-confirmed) | NULL (never located).';
COMMENT ON COLUMN catalog.v_destination.precision IS
    'point | area (draw as an area, not a pin) | NULL = legacy row the CIS place pipeline has not processed.';

-- ── Places per tour day: destination by id first, + located_by, precision (appended) ───────────
-- The CTEs are 225's, unchanged; only the destination lookup and the two last columns are new.
CREATE OR REPLACE VIEW catalog.v_tour_place WITH (security_barrier = true) AS
WITH atom AS (
    SELECT t.source_system, t.source_id, t.tour_id, t.country AS tour_country,
           a.itinerary_day, btrim(a.place) AS place, lower(btrim(a.place)) AS place_key,
           a.atom_id, a.activity_type, a.created_at,
           dt.title || E'\n' || dt.body AS day_text,
           pc.card_id
      FROM catalog.v_tour t
      -- the v_active_tour_atoms rule (203) on the base table: t is already a live master tour
      JOIN acp_contract.tour_atoms a ON a.tour_id = t.tour_id AND NOT a.deleted AND NOT a.is_empty_marker
      LEFT JOIN catalog._tour_day_text dt ON dt.tour_id = t.tour_id AND dt.day_number = a.itinerary_day
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

COMMENT ON VIEW catalog.v_tour_place IS
    'AA-679 / AA-712 — places of a live tour per itinerary day, from active atoms (+ AA-772 place card). '
    'destination_id (228): the place pipeline''s link (geo.tour_place), else the card''s destination, else an '
    'exact name + country match; suspect / duplicate destinations are never returned. day_number NULL = '
    'atom without a day. position = order of first mention in the day text; places the text does not name '
    'come after, in a stable but not itinerary-meaningful order. located_by / precision: see v_destination.';
COMMENT ON COLUMN catalog.v_tour_place.precision IS
    'point | area (draw as an area, not a pin) | NULL = legacy row the CIS place pipeline has not processed.';

-- ── Components (TripPlanner itinerary_components shape) ─────────────────────────────────────────
-- Built dynamically for the optional embedding column (pgvector, see header). Hidden while the
-- place is not resolved (destination_id NULL in geo) or its destination is not usable.
DO $do$
DECLARE
    emb text := '';
BEGIN
    IF EXISTS (SELECT 1 FROM pg_attribute
                WHERE attrelid = 'geo.tour_place'::regclass AND attname = 'embedding' AND NOT attisdropped) THEN
        emb := E',\n           gp.embedding';
    ELSE
        RAISE NOTICE 'migration 228: geo.tour_place.embedding missing (no pgvector), '
                     'catalog.v_tour_component created without its last column embedding';
    END IF;
    EXECUTE format($v$
        CREATE OR REPLACE VIEW catalog.v_tour_component WITH (security_barrier = true) AS
        SELECT t.source_system,
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
          JOIN catalog.v_tour t ON t.source_id = gp.source_id
          JOIN shared.destinations d ON d.id = gp.destination_id
                                    AND d.geo_status <> 'suspect' AND d.duplicate_of IS NULL
    $v$, emb);
END $do$;

COMMENT ON VIEW catalog.v_tour_component IS
    'AA-712 — places of a live tour as TripPlanner itinerary components (one per source, day, place, '
    'activity; component_id = stable uuid5, survives re-atomize / re-upload). Only resolved places on usable '
    'destinations. embedding = cohere-embed-v4 1536-d search_document (TripPlanner queries with the same '
    'model); a full scan per query through this view (no top-k function yet, design §6.5). Contract '
    'catalog.graph.v1.';
COMMENT ON COLUMN catalog.v_tour_component.is_stale IS
    'true = built from an older version of the tour (set-active / re-publish); kept until the rebuild lands.';

-- ── Day route (start / end / overnight) ─────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW catalog.v_tour_day_route WITH (security_barrier = true) AS
SELECT t.source_system,
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
  JOIN catalog.v_tour t ON t.source_id = td.source_id
  LEFT JOIN shared.destinations d ON d.id = td.overnight_destination_id
                                 AND d.geo_status <> 'suspect' AND d.duplicate_of IS NULL;

COMMENT ON VIEW catalog.v_tour_day_route IS
    'AA-712 — day skeleton of a live tour: start / end / overnight place text and the night''s destination '
    '(NULL while unresolved or not usable). Contract catalog.graph.v1.';

-- ── Graph: stops (current build, live tours, usable destinations) ───────────────────────────────
CREATE OR REPLACE VIEW catalog.v_tour_stop WITH (security_barrier = true) AS
SELECT t.source_system,
       t.source_id,
       t.tour_id,
       s.day_index,
       s.destination_id,
       s.country,
       s.source,
       s.build_id
  FROM geo.graph_build b
  JOIN geo.tour_stop s ON s.build_id = b.build_id
  JOIN catalog.v_tour t ON t.source_id = s.source_id
  JOIN shared.destinations d ON d.id = s.destination_id
                            AND d.geo_status <> 'suspect' AND d.duplicate_of IS NULL
 WHERE b.is_current;

COMMENT ON VIEW catalog.v_tour_stop IS
    'AA-712 — one map stop per live tour day in the current tour graph build (source = overnight | component). '
    'Contract catalog.graph.v1.';

-- ── Graph: legs ─────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW catalog.v_tour_leg WITH (security_barrier = true) AS
SELECT t.source_system,
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
  JOIN catalog.v_tour t ON t.source_id = l.source_id
 WHERE b.is_current
   AND NOT EXISTS (SELECT 1 FROM shared.destinations d
                    WHERE d.id = ANY (l.destination_ids || l.start_destination_id || l.end_destination_id)
                      AND (d.geo_status = 'suspect' OR d.duplicate_of IS NOT NULL));

COMMENT ON VIEW catalog.v_tour_leg IS
    'AA-712 — every day span [day_from, day_to] of a live tour in the current graph build, with the '
    'destinations it passes. A leg through a suspect / duplicate destination is dropped. Contract catalog.graph.v1.';

-- ── Graph: nodes (a destination some live tour stops at) ────────────────────────────────────────
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
                  FROM catalog.v_tour_stop s
                 GROUP BY s.destination_id, s.source_id, s.tour_id) x
         GROUP BY x.destination_id) live ON live.destination_id = n.destination_id
 WHERE b.is_current;

COMMENT ON VIEW catalog.v_graph_node IS
    'AA-712 — tour graph nodes of the current build that a live tour still stops at. name / country / lat / '
    'lng / located_by / precision are the destination''s current values; source_ids / tour_ids (aligned, '
    'ordered by source_id) and stop_count count live tours only; activities / intensity / season are the '
    'build''s. Contract catalog.graph.v1.';

-- ── Graph: edges (consecutive stops of live tours) ──────────────────────────────────────────────
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
  JOIN catalog.v_tour t ON t.source_id = src.source_id
 WHERE b.is_current
   AND NOT EXISTS (SELECT 1 FROM shared.destinations d
                    WHERE d.id IN (e.from_destination_id, e.to_destination_id)
                      AND (d.geo_status = 'suspect' OR d.duplicate_of IS NOT NULL))
 GROUP BY e.build_id, e.from_destination_id, e.to_destination_id, e.km;

COMMENT ON VIEW catalog.v_graph_edge IS
    'AA-712 — directed edges between consecutive stops in the current build, kept while a live tour uses them; '
    'tour_count / source_ids / tour_ids count live tours only. km = great-circle distance. Contract '
    'catalog.graph.v1.';

-- ── Graph: junctions (two live nodes within the build's junction distance) ─────────────────────
CREATE OR REPLACE VIEW catalog.v_tour_junction WITH (security_barrier = true) AS
SELECT j.destination_a,
       j.destination_b,
       j.km::double precision AS km,
       j.cross_border,
       j.build_id
  FROM geo.graph_build b
  JOIN geo.tour_junction j ON j.build_id = b.build_id
 WHERE b.is_current
   AND EXISTS (SELECT 1 FROM catalog.v_tour_stop s WHERE s.destination_id = j.destination_a)
   AND EXISTS (SELECT 1 FROM catalog.v_tour_stop s WHERE s.destination_id = j.destination_b);

COMMENT ON VIEW catalog.v_tour_junction IS
    'AA-712 — pairs of graph nodes within the build''s junction distance (both directions), kept while a '
    'live tour stops at both ends. Contract catalog.graph.v1.';

-- ── Ownership: every catalog view belongs to catalog_owner (225 dance) ─────────────────────────
GRANT CREATE ON SCHEMA catalog TO catalog_owner;
ALTER VIEW catalog.v_destination     OWNER TO catalog_owner;
ALTER VIEW catalog.v_tour_place      OWNER TO catalog_owner;
ALTER VIEW catalog.v_tour_component  OWNER TO catalog_owner;
ALTER VIEW catalog.v_tour_day_route  OWNER TO catalog_owner;
ALTER VIEW catalog.v_tour_stop       OWNER TO catalog_owner;
ALTER VIEW catalog.v_tour_leg        OWNER TO catalog_owner;
ALTER VIEW catalog.v_graph_node      OWNER TO catalog_owner;
ALTER VIEW catalog.v_graph_edge      OWNER TO catalog_owner;
ALTER VIEW catalog.v_tour_junction   OWNER TO catalog_owner;
REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;

-- ── Grants (unguarded, see header) ──────────────────────────────────────────────────────────────
GRANT USAGE ON SCHEMA catalog TO aa_app_user, tripplanner, booking;
GRANT SELECT ON catalog.v_tour_component, catalog.v_tour_day_route, catalog.v_tour_stop, catalog.v_tour_leg,
                catalog.v_graph_node, catalog.v_graph_edge, catalog.v_tour_junction,
                catalog.v_tour_place, catalog.v_destination
    TO aa_app_user, tripplanner, booking;

-- ── Sanity check: every new view reads as catalog_owner; components are not empty when geo has
--    resolved places of live tours (a missing grant / policy would make them silently empty) ─────
DO $$
DECLARE
    v          text;
    n_view     bigint;
    n_expected bigint;
BEGIN
    PERFORM set_config('app.tenant_id', '00000000-0000-0000-0000-000000000000', true);
    SET LOCAL ROLE catalog_owner;
    -- privileges are checked when the plan starts, so LIMIT 1 is enough to raise on a missing one and keeps
    -- the ACCESS EXCLUSIVE locks on v_tour_place / v_destination short (no full scan of every live tour)
    FOREACH v IN ARRAY ARRAY['v_tour_day_route', 'v_tour_stop', 'v_tour_leg', 'v_graph_node',
                             'v_graph_edge', 'v_tour_junction', 'v_tour_place', 'v_destination'] LOOP
        EXECUTE format('SELECT 1 FROM catalog.%I LIMIT 1', v);
    END LOOP;
    SELECT count(*) INTO n_view FROM catalog.v_tour_component;
    RESET ROLE;

    PERFORM set_config('app.tenant_id', '00000000-0000-0000-0000-000000000001', true);
    SELECT count(*) INTO n_expected
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
    PERFORM set_config('app.tenant_id', '00000000-0000-0000-0000-000000000000', true);

    RAISE NOTICE 'migration 228: catalog.v_tour_component as catalog_owner = % rows, resolved live places = %',
                 n_view, n_expected;
    IF n_expected > 0 AND n_view = 0 THEN
        RAISE EXCEPTION 'migration 228: catalog.v_tour_component is empty for catalog_owner but % resolved '
                        'places of live tours exist (a grant on geo or the RLS policy is missing)', n_expected;
    END IF;
END $$;

-- the runner keeps no membership (see 225 header)
REVOKE catalog_owner FROM CURRENT_USER;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('228', now(), 'AA-712: catalog place/graph views over geo — v_tour_component, v_tour_day_route, '
                      'v_tour_stop, v_tour_leg, v_graph_node, v_graph_edge, v_tour_junction; v_tour_place '
                      '(destination by pipeline link) and v_destination + located_by/precision (appended); '
                      'owner catalog_owner, SELECT to aa_app_user, tripplanner, booking')
ON CONFLICT (version) DO NOTHING;

COMMIT;
