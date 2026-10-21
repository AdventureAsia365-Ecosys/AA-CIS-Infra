-- Migration 258: AA-847 — a stored, leakproof live-tour join key (raw_tours.source_key) under catalog._live_tour, and
-- catalog.v_tour_component's day stretch as a plain left join on the current build. Needs 253, 256 and 257.
--
-- Why (step-18 gate diagnosis, S246; reproduced on a PG 15 replica with FORCE RLS and the real view owners).
-- silver_aa_internal.raw_tours has FORCE RLS. 253's _live_tour joins on COALESCE(rt.source_group_id, rt.tour_id)::text
-- = gp.source_id. A CoalesceExpr and the uuid -> text I/O cast are not leakproof, so under the RLS quals that join can
-- never become an index condition: every reader that joins _live_tour per component scans raw_tours. On Dev this is
-- ~80% of the search time (the per-destination component_count runs a seq scan of raw_tours per loop), the destination
-- detail components read (a raw_tours scan for 2 rows), and at catalog scale (50k places) the HNSW top-k can only
-- check liveness through a Join Filter, so the natural plan is a hash join + sort. An expression index on the same
-- expression is ignored under RLS (refuted). A stored column makes the join a plain text = text (leakproof): an
-- index condition under RLS.
-- 256's v_tour_component day stretch was a LEFT JOIN LATERAL (graph_build JOIN tour_segment ... LIMIT 1) run once per
-- component row, also for tiles, which never reads those columns. tour_segment_pkey is (build_id, source_id,
-- day_index, destination_id) and graph_build_one_current_uq allows one current build, so the LATERAL could only
-- ever return one row: a plain left join on the current build is the same rows, and the planner can remove it.
--
-- What (same columns — names, types, order — and same rows; CREATE OR REPLACE VIEW cannot drop, rename, reorder or
-- retype a column):
--   1. silver_aa_internal.raw_tours.source_key text GENERATED ALWAYS AS ((COALESCE(source_group_id, tour_id))::text)
--      STORED + btree raw_tours_source_key_idx (not partial: ~1k rows, no predicate to prove). Not the same as
--      raw_tours.source_id (uuid, the upload source).
--   2. catalog._live_tour: 253's statement with `rt.source_key AS source_id` (same text column, same rows). Every view
--      on it (v_tour, _tour_day_text, v_tour_place, v_tour_photo, v_tour_day_route, _live_stop, v_tour_leg,
--      v_graph_edge, v_component_embedding) picks the key up without being restated.
--   3. catalog.v_tour_component: 256's DO / EXECUTE body (the optional embedding column) with the LATERAL replaced by
--      LEFT JOIN geo.tour_segment seg ON the current build_id and the three keys (alias seg kept). 256's grants
--      restated.
--   4. ANALYZE raw_tours; closing checks: the row counts of _live_tour, _live_stop, v_tour_component, v_tour_place,
--      v_destination and v_component_embedding are unchanged (and _live_tour's (tour_id, source_id) set and
--      v_tour_component's day stretch columns are the same: an md5 that reads segment_*, so the new join really runs),
--      source_key equals the expression on every row, and the column is a stored generated one.
-- Not here: 256's v_tour_place LATERAL (no failing reader reads it).
-- Not changed: tripplanner's column grant on raw_tours (country, tour_id), every RLS policy, REQUIRED_CIS_SCHEMA (no
-- code depends on 258).
--
-- Recipe: the X1 S22 catalog recipe, as 253 / 256. The column and the index are cis_owner's (the file's role, owner
-- of raw_tours); the view DDL runs under GRANT CREATE ON SCHEMA catalog TO catalog_owner; SET LOCAL ROLE
-- catalog_owner; ...; SET LOCAL ROLE cis_owner; REVOKE CREATE. DB Migrate runs the file as cis_owner (login
-- db_migrator). Never RESET ROLE, no SECURITY DEFINER, no role DDL. The conftest replay skips this file (it needs 253 /
-- 256 / 257); tests/integration/test_aa847_migration_258.py applies 253 + 256 + 257 + 258 the DB Migrate way inside
-- one transaction and rolls back.
--
-- Locks: the column add rewrites raw_tours (~5 MB on Dev) under ACCESS EXCLUSIVE (well under a second) and the two
-- views take ACCESS EXCLUSIVE until COMMIT; lock_timeout 10s (fail fast, re-run when idle). Apply while the job
-- tables are idle (DB Migrate waits for it). Idempotent (IF NOT EXISTS, CREATE OR REPLACE, re-runnable grants), one
-- transaction, self-registering. Applied on Dev from the byte-identical copy in AA-CIS-Infra db/migrations/cis/.
--
-- Rollback: re-run 253's catalog._live_tour statement and 256's v_tour_component DO block under the same recipe, then
-- DROP INDEX silver_aa_internal.raw_tours_source_key_idx; ALTER TABLE silver_aa_internal.raw_tours DROP COLUMN
-- source_key; DELETE FROM shared.schema_versions WHERE version = '258'.

BEGIN;
SET LOCAL lock_timeout = '10s';

-- ── Preconditions (as the file's role: cis_owner on Dev) ─────────────────────────────────────────────────────────
DO $$
BEGIN
    IF (SELECT count(*) FROM shared.schema_versions WHERE version IN ('253', '256', '257')) <> 3 THEN
        RAISE EXCEPTION 'migration 258: apply 253, 256 and 257 first';
    END IF;
    IF to_regclass('catalog._live_tour') IS NULL OR to_regclass('catalog.v_tour_component') IS NULL THEN
        RAISE EXCEPTION 'migration 258: catalog._live_tour / v_tour_component missing (apply 253 first)';
    END IF;
    IF to_regclass('geo.tour_segment') IS NULL THEN
        RAISE EXCEPTION 'migration 258: geo.tour_segment missing (apply 255 first)';
    END IF;
    IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'catalog') <> 'cis_owner' THEN
        RAISE EXCEPTION 'migration 258: schema catalog is not owned by cis_owner (apply 245 first)';
    END IF;
    -- a source_key column that is not this file's generated one would be kept by ADD COLUMN IF NOT EXISTS
    IF EXISTS (SELECT 1 FROM pg_attribute
                WHERE attrelid = 'silver_aa_internal.raw_tours'::regclass AND attname = 'source_key'
                  AND NOT attisdropped AND (attgenerated <> 's' OR atttypid <> 'text'::regtype)) THEN
        RAISE EXCEPTION 'migration 258: raw_tours.source_key exists and is not a stored generated text column';
    END IF;
END $$;

-- ── 1. The stored join key (owner cis_owner) ──────────────────────────────────────────────────────────────────────
ALTER TABLE silver_aa_internal.raw_tours
    ADD COLUMN IF NOT EXISTS source_key text
    GENERATED ALWAYS AS ((COALESCE(source_group_id, tour_id))::text) STORED;

COMMENT ON COLUMN silver_aa_internal.raw_tours.source_key IS
    'Catalog source key = COALESCE(source_group_id, tour_id)::text; join key of catalog._live_tour (AA-847, 258). '
    'Not the same as source_id (uuid).';

CREATE INDEX IF NOT EXISTS raw_tours_source_key_idx ON silver_aa_internal.raw_tours (source_key);

GRANT CREATE ON SCHEMA catalog TO catalog_owner;
SET LOCAL ROLE catalog_owner;

-- ── What the closing check compares with (as catalog_owner: only its RLS policy admits rows) ─────────────────────
DO $$
DECLARE
    v      text;
    n      bigint;
    counts jsonb := '{}';
BEGIN
    PERFORM set_config('app.tenant_id', '00000000-0000-0000-0000-000000000000', true);
    FOREACH v IN ARRAY ARRAY['_live_tour', '_live_stop', 'v_tour_component', 'v_tour_place', 'v_destination',
                             'v_component_embedding'] LOOP
        IF to_regclass('catalog.' || v) IS NOT NULL THEN
            EXECUTE format('SELECT count(*) FROM catalog.%I', v) INTO n;
            counts := counts || jsonb_build_object(v, n);
        END IF;
    END LOOP;
    PERFORM set_config('aa847.expected_258_counts', counts::text, true);
    PERFORM set_config('aa847.expected_258_live_keys',
                       (SELECT md5(COALESCE(string_agg(tour_id::text || '/' || source_id, '|'
                                                       ORDER BY tour_id, source_id), ''))
                          FROM catalog._live_tour), true);
    -- the day stretch columns themselves: a count(*) alone lets the planner remove the segment join (no column read)
    PERFORM set_config('aa847.expected_258_segments',
                       (SELECT md5(COALESCE(string_agg(s::text, '|' ORDER BY s::text), ''))
                          FROM (SELECT component_id, source_id, day_index, destination_id, segment, segment_basis,
                                       segment_from_destination_id, segment_to_destination_id, segment_km
                                  FROM catalog.v_tour_component) s), true);
    PERFORM set_config('app.tenant_id', '', true);
END $$;

-- ── 2. Live tours (internal): 253's statement, the join key from the stored column ───────────────────────────────
CREATE OR REPLACE VIEW catalog._live_tour AS
SELECT rt.tour_id,
       rt.source_key AS source_id,
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
    'source active and not deleted), with the source columns v_tour shows. source_id is raw_tours.source_key (258: a '
    'stored column, so the join is an index condition under FORCE RLS). Not security_barrier so the views that '
    'join it can flatten it; not granted to consumers; may change without notice.';

-- ── 3. Components: 256's body, the day stretch as a left join on the current build (same dynamic build) ──────────
DO $do$
DECLARE
    emb text := '';
BEGIN
    IF EXISTS (SELECT 1 FROM pg_attribute
                WHERE attrelid = 'geo.tour_place'::regclass AND attname = 'embedding' AND NOT attisdropped) THEN
        emb := E',\n               gp.embedding';
    ELSE
        RAISE NOTICE 'migration 258: geo.tour_place.embedding missing (no pgvector), '
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
          -- 258: at most one row (tour_segment_pkey; one current build, graph_build_one_current_uq)
          LEFT JOIN geo.tour_segment seg
                 ON seg.build_id = (SELECT b.build_id FROM geo.graph_build b WHERE b.is_current)
                AND seg.source_id = gp.source_id
                AND seg.day_index = gp.day_index
                AND seg.destination_id = gp.destination_id
    $v$, emb);
END $do$;

-- ── Grants (CREATE OR REPLACE keeps the existing ones; 256's restated, unguarded) ────────────────────────────────
GRANT SELECT ON catalog.v_tour_component TO aa_app_user, tripplanner, booking;

-- ── Closing check as catalog_owner: same rows ────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v      text;
    n      bigint;
    before jsonb := current_setting('aa847.expected_258_counts')::jsonb;
BEGIN
    PERFORM set_config('app.tenant_id', '00000000-0000-0000-0000-000000000000', true);
    FOREACH v IN ARRAY ARRAY['_live_tour', '_live_stop', 'v_tour_component', 'v_tour_place', 'v_destination',
                             'v_component_embedding'] LOOP
        IF to_regclass('catalog.' || v) IS NOT NULL THEN
            EXECUTE format('SELECT count(*) FROM catalog.%I', v) INTO n;
            IF n IS DISTINCT FROM (before ->> v)::bigint THEN
                RAISE EXCEPTION 'migration 258: catalog.% has % rows, % before', v, n, before ->> v;
            END IF;
        END IF;
    END LOOP;
    IF (SELECT md5(COALESCE(string_agg(tour_id::text || '/' || source_id, '|' ORDER BY tour_id, source_id), ''))
          FROM catalog._live_tour) <> current_setting('aa847.expected_258_live_keys') THEN
        RAISE EXCEPTION 'migration 258: catalog._live_tour (tour_id, source_id) changed';
    END IF;
    IF (SELECT md5(COALESCE(string_agg(s::text, '|' ORDER BY s::text), ''))
          FROM (SELECT component_id, source_id, day_index, destination_id, segment, segment_basis,
                       segment_from_destination_id, segment_to_destination_id, segment_km
                  FROM catalog.v_tour_component) s) <> current_setting('aa847.expected_258_segments') THEN
        RAISE EXCEPTION 'migration 258: catalog.v_tour_component day stretch columns changed';
    END IF;
    RAISE NOTICE 'migration 258: as catalog_owner, row counts unchanged: %', before;
    PERFORM set_config('app.tenant_id', '', true);
END $$;

SET LOCAL ROLE cis_owner;
REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;

-- ── 4. Fresh statistics for the new column + the key check (as cis_owner: its policy reads every row) ────────────
ANALYZE silver_aa_internal.raw_tours;

DO $$
DECLARE
    n bigint;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_attribute
                    WHERE attrelid = 'silver_aa_internal.raw_tours'::regclass AND attname = 'source_key'
                      AND NOT attisdropped AND attgenerated = 's') THEN
        RAISE EXCEPTION 'migration 258: raw_tours.source_key is not a stored generated column';
    END IF;
    IF to_regclass('silver_aa_internal.raw_tours_source_key_idx') IS NULL THEN
        RAISE EXCEPTION 'migration 258: index raw_tours_source_key_idx missing';
    END IF;
    SELECT count(*) INTO n FROM silver_aa_internal.raw_tours
     WHERE source_key IS DISTINCT FROM (COALESCE(source_group_id, tour_id))::text;
    IF n <> 0 THEN
        RAISE EXCEPTION 'migration 258: % raw_tours rows have a source_key other than COALESCE(source_group_id, tour_id)', n;
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('258', now(), 'AA-847: raw_tours.source_key (stored COALESCE(source_group_id, tour_id)::text, indexed) as the '
                      'join key of catalog._live_tour (an index condition under FORCE RLS), v_tour_component day '
                      'stretch as a left join on the current build; same columns and rows')
ON CONFLICT (version) DO NOTHING;

COMMIT;
