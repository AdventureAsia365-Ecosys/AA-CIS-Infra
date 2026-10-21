-- Migration 255: AA-847 — storage for drawing linear places as lines (owner decision S246, Nghiệp: rivers, roads and
-- trekking stretches are DRAWN on the TripPlanner map — never a pin, never a circle, never hidden).
--
-- Why. A linear feature ("Nam Ou River", "Ho Chi Minh Trail", "Karakoram Highway") has no point a map can mark. The
-- validity branch first hid them (geo_status 'suspect'); S246 replaces that: a linear name is stored geo_status 'ok',
-- geo_precision 'line', and its geometry lives in geo.place_shape. Design + skeptic pass: root
-- docs/audits/2026-10-21-S246-aa847/design-linear-places.md (revised plan §3 "Migration A").
--
-- What (storage only; the catalog views read it from a later migration, "Migration B"):
--   1. shared.destinations_geo_precision_check += 'line'. MUST be applied BEFORE the code that writes 'line'
--      (place_geocode on the validity branch) deploys, or every linear name raises CheckViolation.
--   2. geo.place_shape — one row per line destination (PK destination_id): the job queue state (pending /
--      ok / approximate / not_found / failed / manual), the source (geoapify_details / overpass / anchors /
--      manual), the GeoJSON (Multi)LineString clipped to the destination's country polygon at three levels
--      (geom ≤ 2,000 vertices; geom_mid ≤ 300 vertices and ≤ 12 KB; geom_lo ≤ 60 vertices), a NON-NULL bbox
--      (the point itself while pending, so a reader's bbox filter is a plain float comparison), length_km and
--      the OSM identity (osm_type, osm_id: also a same-place signal for the automatic duplicate merge).
--      Written only by the job kind place_shape (+ the admin manual action); place_geocode only inserts the
--      pending row. `kind` 'area' is reserved for polygons (a later migration widens the geometry CHECK).
--   3. geo.tour_segment — the stretch of a line a tour-day follows, versioned with the graph build (like
--      geo.tour_stop): build_id → geo.graph_build ON DELETE CASCADE, so old builds are pruned with it and rolling
--      a build back rolls its segments back. Written only by tour_graph_build (store.swap_graph). NOT columns on
--      geo.tour_place: that table is DELETE + INSERT per source on every re-extract (the columns would be wiped
--      until the next build and get two writers) and its UPDATEs would churn the HNSW index on `embedding`.
--   4. geo.geocode_call += endpoint ('search' / 'place_details' / 'overpass', default 'search') and credits.
--      credits is nullable: the running place_geocode code inserts rows without it during the deploy window, so the
--      daily credit guard sums COALESCE(credits, requests) (a Place Details call with full geometry is 2 credits
--      for 1 request). Existing rows are backfilled credits = requests.
--   5. geo.line_vertex_count(jsonb) — IMMUTABLE helper for the vertex-count CHECKs (LineString / MultiLineString).
--   6. shared.spend_budget row geocoder / job:place_shape ($10/run; Free plan = $0, the daily credit guard is
--      what bounds Geoapify).
--   7. Privileges: cis_app SELECT / INSERT / UPDATE / DELETE on both tables (the job and the build write them);
--      catalog_owner SELECT (the views of Migration B read them); nothing for tripplanner, booking, aa_app_user or
--      PUBLIC (geo is CIS-internal; TripPlanner reads catalog.* only).
--   8. Register 255.
--
-- Guards (RAISE, nothing changes): 0. before: shared.destinations, geo.graph_build, geo.geocode_call exist.
--   1. after: the CHECK accepts 'line' and still refuses another value; both tables with their named CHECKs; the
--   geocode_call columns; grants as in 7.
--
-- Locks. The CHECK swap takes ACCESS EXCLUSIVE on shared.destinations for the re-validation of ~1.5k rows
-- (milliseconds); lock_timeout 5s fails fast instead of queueing behind a job transaction — re-run when idle. The
-- two new tables lock nothing else. ADD COLUMN with a constant default is metadata only. Re-running is a no-op.
--
-- X1. One BEGIN … COMMIT block, no role switch (role lint, AA-CIS-Infra db/owners.yaml); DB Migrate runs cis/ files
-- as cis_owner, which owns shared.destinations and geo.* since 245 and therefore owns the new objects.
--
-- The SQL applied on Dev is the byte-identical copy in AA-CIS-Infra db/migrations/cis/ (Copy Guard). After apply:
-- the DB Schema Dump workflow regenerates docs/architecture/db-schema-reference.md (merge its PR before code reads
-- the new columns).
--
-- Rollback (emergency only — it breaks the owner's decision D1): UPDATE shared.destinations SET geo_precision =
-- 'area' WHERE geo_precision = 'line'; then narrow the CHECK; DROP TABLE geo.tour_segment, geo.place_shape (derived,
-- rebuildable data). The two geocode_call columns can stay.
BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Guard 0 ──────────────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF to_regclass('shared.destinations') IS NULL THEN
        RAISE EXCEPTION 'migration 255: shared.destinations does not exist';
    END IF;
    IF to_regclass('geo.graph_build') IS NULL OR to_regclass('geo.geocode_call') IS NULL THEN
        RAISE EXCEPTION 'migration 255: schema geo (migration 226) is missing';
    END IF;
END $$;

-- ── 1. geo_precision += line ─────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint
                    WHERE conrelid = 'shared.destinations'::regclass
                      AND conname = 'destinations_geo_precision_check'
                      AND pg_catalog.pg_get_constraintdef(oid) LIKE '%''line''%') THEN
        ALTER TABLE shared.destinations
            DROP CONSTRAINT IF EXISTS destinations_geo_precision_check,
            ADD CONSTRAINT destinations_geo_precision_check
                CHECK (geo_precision IS NULL OR geo_precision IN ('point', 'area', 'line'));
    END IF;
END $$;
COMMENT ON COLUMN shared.destinations.geo_precision IS
    'point (a geocoder-confirmed or admin point) | area (the model''s own point, or an area feature: drawn as an area, never a pinpoint) | line (AA-847, a linear feature: river / road / trail; drawn from geo.place_shape, never a pin)';

-- ── 5. vertex-count helper (used by the CHECKs below) ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION geo.line_vertex_count(g jsonb) RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $fn$
    SELECT CASE g ->> 'type'
               WHEN 'LineString' THEN pg_catalog.jsonb_array_length(g -> 'coordinates')
               WHEN 'MultiLineString' THEN (SELECT coalesce(sum(pg_catalog.jsonb_array_length(p)), 0)::integer
                                              FROM pg_catalog.jsonb_array_elements(g -> 'coordinates') AS p)
           END
$fn$;
COMMENT ON FUNCTION geo.line_vertex_count(jsonb) IS
    'AA-847 (255): vertices of a GeoJSON LineString / MultiLineString (NULL for any other type); used by the geo.place_shape / geo.tour_segment size CHECKs';

-- ── 2. geo.place_shape ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS geo.place_shape (
    destination_id  uuid             NOT NULL REFERENCES shared.destinations(id) ON DELETE CASCADE,
    kind            text             NOT NULL DEFAULT 'line',
    status          text             NOT NULL DEFAULT 'pending',
    source          text,
    geom            jsonb,
    geom_mid        jsonb,
    geom_lo         jsonb,
    min_lat         double precision NOT NULL,
    min_lng         double precision NOT NULL,
    max_lat         double precision NOT NULL,
    max_lng         double precision NOT NULL,
    length_km       numeric(8, 1),
    osm_type        text,
    osm_id          bigint,
    tries           integer          NOT NULL DEFAULT 0,
    next_retry_at   timestamptz      NOT NULL DEFAULT now(),
    last_error      text,
    fetched_at      timestamptz,
    meta            jsonb            NOT NULL DEFAULT '{}'::jsonb,
    created_at      timestamptz      NOT NULL DEFAULT now(),
    updated_at      timestamptz      NOT NULL DEFAULT now(),
    CONSTRAINT place_shape_pkey PRIMARY KEY (destination_id),
    CONSTRAINT place_shape_kind_chk CHECK (kind IN ('line', 'area')),
    CONSTRAINT place_shape_status_chk
        CHECK (status IN ('pending', 'ok', 'approximate', 'not_found', 'failed', 'manual')),
    CONSTRAINT place_shape_source_chk
        CHECK (source IS NULL OR source IN ('geoapify_details', 'overpass', 'anchors', 'manual')),
    -- a drawn row carries its three levels, its source and its length; a queued / missing one carries none
    CONSTRAINT place_shape_drawn_chk CHECK (
        (status IN ('ok', 'approximate', 'manual'))
        = (geom IS NOT NULL AND geom_mid IS NOT NULL AND geom_lo IS NOT NULL AND source IS NOT NULL
           AND length_km IS NOT NULL)),
    CONSTRAINT place_shape_status_source_chk CHECK (
        (status = 'approximate') = (source IS NOT DISTINCT FROM 'anchors')
        AND (status = 'manual') = (source IS NOT DISTINCT FROM 'manual')),
    CONSTRAINT place_shape_geom_chk CHECK (
        geom IS NULL OR (geom ->> 'type' IN ('LineString', 'MultiLineString')
                         AND geo.line_vertex_count(geom) BETWEEN 2 AND 2000)),
    CONSTRAINT place_shape_geom_mid_chk CHECK (
        geom_mid IS NULL OR (geom_mid ->> 'type' IN ('LineString', 'MultiLineString')
                             AND geo.line_vertex_count(geom_mid) BETWEEN 2 AND 300
                             AND pg_catalog.octet_length(geom_mid::text) <= 12288)),
    CONSTRAINT place_shape_geom_lo_chk CHECK (
        geom_lo IS NULL OR (geom_lo ->> 'type' IN ('LineString', 'MultiLineString')
                            AND geo.line_vertex_count(geom_lo) BETWEEN 2 AND 60)),
    CONSTRAINT place_shape_bbox_chk CHECK (
        min_lat BETWEEN -90 AND 90 AND max_lat BETWEEN -90 AND 90 AND min_lat <= max_lat
        AND min_lng BETWEEN -180 AND 180 AND max_lng BETWEEN -180 AND 180 AND min_lng <= max_lng),
    CONSTRAINT place_shape_osm_chk CHECK (
        (osm_type IS NULL) = (osm_id IS NULL) AND (osm_type IS NULL OR osm_type IN ('node', 'way', 'relation'))),
    CONSTRAINT place_shape_length_chk CHECK (length_km IS NULL OR length_km >= 0),
    CONSTRAINT place_shape_tries_chk CHECK (tries >= 0)
);
CREATE INDEX IF NOT EXISTS place_shape_due_idx ON geo.place_shape (status, next_retry_at);
CREATE INDEX IF NOT EXISTS place_shape_osm_idx ON geo.place_shape (osm_type, osm_id) WHERE osm_id IS NOT NULL;

COMMENT ON TABLE geo.place_shape IS
    'AA-847 (255): geometry of a line destination (shared.destinations.geo_precision = line), GeoJSON clipped to the destination''s country at three simplification levels. Written only by the job kind place_shape (and the admin manual action on /admin/places); place_geocode inserts the pending row. OpenStreetMap data (ODbL): attribution "© OpenStreetMap contributors" wherever drawn.';
COMMENT ON COLUMN geo.place_shape.status IS
    'pending (queued) | ok (an OSM feature passed the acceptance rule) | approximate (no single OSM feature: the polyline of a tour-day''s anchors, drawn dashed and labelled "approximate route") | not_found / failed (retried; listed on /admin/places Lines) | manual (admin GeoJSON)';
COMMENT ON COLUMN geo.place_shape.geom IS 'GeoJSON (Multi)LineString, ≤ 2,000 vertices, 5 decimals; CIS-internal (stretch substrings)';
COMMENT ON COLUMN geo.place_shape.geom_mid IS 'GeoJSON, ≤ 300 vertices and ≤ 12 KB (map from zoom 7, trip panel)';
COMMENT ON COLUMN geo.place_shape.geom_lo IS 'GeoJSON, ≤ 60 vertices (map below zoom 7, static maps)';
COMMENT ON COLUMN geo.place_shape.min_lat IS 'bbox of the shape; the destination point while no shape is stored (never NULL)';
COMMENT ON COLUMN geo.place_shape.osm_id IS 'OpenStreetMap id of the feature (with osm_type): a same-place signal for the automatic duplicate merge';

-- ── 3. geo.tour_segment ──────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS geo.tour_segment (
    build_id             uuid         NOT NULL REFERENCES geo.graph_build(build_id) ON DELETE CASCADE,
    source_id            text         NOT NULL,
    day_index            integer      NOT NULL,
    destination_id       uuid         NOT NULL REFERENCES shared.destinations(id) ON DELETE CASCADE,
    segment              jsonb,
    basis                text         NOT NULL,
    from_destination_id  uuid         REFERENCES shared.destinations(id) ON DELETE SET NULL,
    to_destination_id    uuid         REFERENCES shared.destinations(id) ON DELETE SET NULL,
    segment_km           numeric(8, 1),
    CONSTRAINT tour_segment_pkey PRIMARY KEY (build_id, source_id, day_index, destination_id),
    CONSTRAINT tour_segment_basis_chk CHECK (basis IN ('day_anchors', 'anchor_window', 'feature')),
    -- 'feature': no stretch could be cut, the reader draws the (country-clipped) feature
    CONSTRAINT tour_segment_feature_chk CHECK ((basis = 'feature') = (segment IS NULL)
                                               AND (segment IS NULL) = (segment_km IS NULL)),
    CONSTRAINT tour_segment_segment_chk CHECK (
        segment IS NULL OR (segment ->> 'type' = 'LineString'
                            AND geo.line_vertex_count(segment) BETWEEN 2 AND 300)),
    CONSTRAINT tour_segment_km_chk CHECK (segment_km IS NULL OR segment_km >= 0)
);
CREATE INDEX IF NOT EXISTS tour_segment_destination_idx ON geo.tour_segment (destination_id);

COMMENT ON TABLE geo.tour_segment IS
    'AA-847 (255): the stretch of a line destination one tour-day follows (substring between the day''s anchors, or a ±15 km window around one anchor, or NULL = the whole feature), versioned with geo.graph_build like geo.tour_stop. Written only by tour_graph_build (store.swap_graph).';
COMMENT ON COLUMN geo.tour_segment.basis IS
    'day_anchors (between the previous and this overnight, both ≤ 15 km from the line and ≥ 2 km apart) | anchor_window (±15 km around the one anchor that fits, or an out-and-back) | feature (no anchor fits: segment NULL)';

-- ── 4. geo.geocode_call: endpoint + credits ─────────────────────────────────────────────────────
ALTER TABLE geo.geocode_call ADD COLUMN IF NOT EXISTS endpoint text NOT NULL DEFAULT 'search';
ALTER TABLE geo.geocode_call ADD COLUMN IF NOT EXISTS credits integer;
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint
                    WHERE conrelid = 'geo.geocode_call'::regclass AND conname = 'geocode_call_endpoint_chk') THEN
        ALTER TABLE geo.geocode_call ADD CONSTRAINT geocode_call_endpoint_chk
            CHECK (endpoint IN ('search', 'place_details', 'overpass'));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint
                    WHERE conrelid = 'geo.geocode_call'::regclass AND conname = 'geocode_call_credits_chk') THEN
        ALTER TABLE geo.geocode_call ADD CONSTRAINT geocode_call_credits_chk CHECK (credits IS NULL OR credits >= 0);
    END IF;
END $$;
UPDATE geo.geocode_call SET credits = requests WHERE credits IS NULL;
COMMENT ON COLUMN geo.geocode_call.endpoint IS
    'AA-847 (255): search (geocode confirm) | place_details (Geoapify Place Details, place_shape) | overpass (OpenStreetMap Overpass, free, place_shape)';
COMMENT ON COLUMN geo.geocode_call.credits IS
    'AA-847 (255): provider credits these requests cost (a Place Details call with full_geometry is 2); NULL on rows written by code older than 255 — the daily guard sums COALESCE(credits, requests)';

-- ── 6. budget row ────────────────────────────────────────────────────────────────────────────────
INSERT INTO shared.spend_budget (provider, scope, per_run_usd, per_day_usd, updated_by)
VALUES ('geocoder', 'job:place_shape', 10.00, NULL, 'migration-255')
ON CONFLICT (provider, scope) DO NOTHING;

-- ── 7. Privileges ────────────────────────────────────────────────────────────────────────────────
REVOKE ALL ON geo.place_shape, geo.tour_segment FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE, DELETE ON geo.place_shape, geo.tour_segment TO cis_app;
DO $$
DECLARE
    r text;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'catalog_owner') THEN
        GRANT SELECT ON geo.place_shape, geo.tour_segment TO catalog_owner;
    END IF;
    FOREACH r IN ARRAY ARRAY['tripplanner', 'booking', 'aa_app_user'] LOOP
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r) THEN
            EXECUTE format('REVOKE ALL ON geo.place_shape, geo.tour_segment FROM %I', r);
        END IF;
    END LOOP;
END $$;

-- ── Guard 1 ──────────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    t text;
    c text;
    r text;
    missing text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint
                    WHERE conrelid = 'shared.destinations'::regclass AND conname = 'destinations_geo_precision_check'
                      AND convalidated AND pg_catalog.pg_get_constraintdef(oid) LIKE '%''line''%'
                      AND pg_catalog.pg_get_constraintdef(oid) LIKE '%''point''%'
                      AND pg_catalog.pg_get_constraintdef(oid) LIKE '%''area''%') THEN
        RAISE EXCEPTION 'migration 255: destinations_geo_precision_check does not accept point / area / line';
    END IF;

    SELECT string_agg(x, ', ') INTO missing
      FROM unnest(ARRAY['place_shape_kind_chk', 'place_shape_status_chk', 'place_shape_source_chk',
                        'place_shape_drawn_chk', 'place_shape_status_source_chk', 'place_shape_geom_chk',
                        'place_shape_geom_mid_chk', 'place_shape_geom_lo_chk', 'place_shape_bbox_chk',
                        'place_shape_osm_chk']) AS x
     WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint
                        WHERE conrelid = 'geo.place_shape'::regclass AND conname = x AND contype = 'c');
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'migration 255: geo.place_shape lacks CHECK constraint(s) %', missing;
    END IF;
    SELECT string_agg(x, ', ') INTO missing
      FROM unnest(ARRAY['tour_segment_basis_chk', 'tour_segment_feature_chk', 'tour_segment_segment_chk']) AS x
     WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint
                        WHERE conrelid = 'geo.tour_segment'::regclass AND conname = x AND contype = 'c');
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'migration 255: geo.tour_segment lacks CHECK constraint(s) %', missing;
    END IF;
    FOREACH c IN ARRAY ARRAY['min_lat', 'min_lng', 'max_lat', 'max_lng'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute
                        WHERE attrelid = 'geo.place_shape'::regclass AND attname = c AND attnotnull) THEN
            RAISE EXCEPTION 'migration 255: geo.place_shape.% must be NOT NULL', c;
        END IF;
    END LOOP;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute
                    WHERE attrelid = 'geo.geocode_call'::regclass AND attname = 'endpoint' AND attnotnull)
       OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute
                       WHERE attrelid = 'geo.geocode_call'::regclass AND attname = 'credits') THEN
        RAISE EXCEPTION 'migration 255: geo.geocode_call lacks endpoint / credits';
    END IF;

    FOREACH t IN ARRAY ARRAY['geo.place_shape', 'geo.tour_segment'] LOOP
        IF NOT pg_catalog.has_table_privilege('cis_app', t, 'SELECT, INSERT, UPDATE, DELETE') THEN
            RAISE EXCEPTION 'migration 255: cis_app lacks DML on %', t;
        END IF;
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'catalog_owner')
           AND NOT pg_catalog.has_table_privilege('catalog_owner', t, 'SELECT') THEN
            RAISE EXCEPTION 'migration 255: catalog_owner cannot read %', t;
        END IF;
        FOREACH r IN ARRAY ARRAY['tripplanner', 'booking', 'aa_app_user'] LOOP
            IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r)
               AND pg_catalog.has_table_privilege(r, t, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE') THEN
                RAISE EXCEPTION 'migration 255: % has a privilege on % (geo is CIS-internal)', r, t;
            END IF;
        END LOOP;
    END LOOP;
END $$;

-- ── 8. Register ──────────────────────────────────────────────────────────────────────────────────
INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('255', now(), 'AA-847: geo_precision += line, geo.place_shape (line geometry), geo.tour_segment (per tour-day stretch, build-versioned), geocode_call endpoint + credits, budget geocoder/job:place_shape')
ON CONFLICT (version) DO NOTHING;

COMMIT;
