-- Migration 273: AA-645 step 0 (d06) — a rewrite keeps a Master Content tour's first publish date; the rewrite is
-- recorded in a new gold_aa_internal.published_tours.updated_at, and catalog.v_tour's updated_at follows it.
--
-- Why. Every publish of a new version upserted published_tours with published_at = NOW() (shared/repository/
-- published_catalog_repository.py), and the admin "promote" did the same. A catalogue rewrite (AA-645 S1 rerun,
-- ~890 tours) would reset every tour's publish date to the hour of its wave: the tenant Browse pool and TripPlanner's
-- browse order (catalog.v_tour.published_at) would be shuffled by run order, and old tours would look new. Nghiep's
-- decision d06 (S248, root .tmp-session platform-impact memo section 9): an existing tour keeps its original
-- published_at, a new tour gets its real publish date, and the rewrite is recorded in updated_at. published_tours has
-- no updated_at today (catalog.v_tour says so: "published_tours has no updated_at"), so this file adds it. The code
-- change ships in the same CIS PR: the upsert and promote stop touching published_at and set updated_at = now().
--
-- What.
--   1. gold_aa_internal.published_tours.updated_at timestamptz NOT NULL DEFAULT now(): added NULL, every existing row
--      backfilled to its published_at (its last publish so far, the same instant v_tour.updated_at already shows), then
--      SET DEFAULT now() + SET NOT NULL. Owner cis_owner (the file's role). Table-level grants and every RLS policy
--      cover the new column (no column grants on this table).
--   2. catalog._live_tour: 258's statement with pt.updated_at AS master_updated_at appended as the LAST column
--      (CREATE OR REPLACE VIEW may add columns at the end only). No view outputs _live_tour.* (v_tour's CTE reads it
--      by name), so every view on it keeps its columns.
--   3. catalog.v_tour: 253's statement with updated_at = GREATEST(published_at, master_updated_at, photos_updated_at)
--      (was GREATEST(published_at, photos_updated_at)) and the comment that said published_tours has no updated_at
--      corrected. Same columns (name, type, order), same rows. Before this file a rewrite moved published_at, so
--      updated_at moved with it; after it, published_at stays and updated_at still moves (TripPlanner's sitemap
--      lastmod and catalog.tour.v1 consumers see the rewrite as before). Contract catalog.tour.v1 is unchanged:
--      updated_at stays informative, consumers diff content_hash.
--   4. Register 273.
--
-- Guards (RAISE rolls the whole file back): before — 253 / 256 / 257 / 258 registered, schema catalog owned by
-- cis_owner, published_tours.updated_at absent or already this file's column (timestamptz); after — the column is
-- NOT NULL with default now() and no row is NULL; every row's updated_at >= published_at; v_tour has the same
-- columns (name, type, order) as before and, read as catalog_owner, the same number of rows as _live_tour before;
-- _live_tour has the same 19 columns plus master_updated_at at the end.
--
-- Recipe. The column add is cis_owner's (the file's role, owner of published_tours). The view DDL uses the X1 S22
-- catalog recipe, as 253 / 256 / 258: GRANT CREATE ON SCHEMA catalog TO catalog_owner; SET LOCAL ROLE catalog_owner;
-- the view DDL; SET LOCAL ROLE cis_owner; REVOKE CREATE. DB Migrate runs the file as cis_owner (login db_migrator).
-- Never RESET ROLE, no SECURITY DEFINER, no role DDL. The conftest replay applies only part 1 (it skips 253-258, so
-- the catalog part cannot run there); tests/integration/test_aa645_migration_273.py applies 253 + 256 + 257 + 258 +
-- 273 the DB Migrate way in one transaction and rolls back.
--
-- Order with the code. Apply this file BEFORE the CIS deploy that writes updated_at (the publish upsert would fail
-- on a missing column). The current code keeps working after this file (it does not name the column; the DEFAULT
-- fills it on insert, and an upsert that does not set it leaves it at the backfill / last value).
--
-- Locks. ADD COLUMN without a default is a catalog-only change; the backfill UPDATE rewrites ~900 rows (~5 MB on Dev)
-- under ROW EXCLUSIVE; SET NOT NULL scans the table under ACCESS EXCLUSIVE (milliseconds at this size); the two
-- views take ACCESS EXCLUSIVE until COMMIT. lock_timeout 10s: fail fast and re-run when idle. Apply while the job
-- tables are idle (DB Migrate waits for it). Idempotent (IF NOT EXISTS, a backfill of NULLs only, CREATE OR REPLACE),
-- one transaction, self-registering. Applied on Dev from the byte-identical copy in AA-CIS-Infra db/migrations/cis/.
--
-- Rollback: roll forward. CREATE OR REPLACE VIEW cannot drop _live_tour's new last column, so a new migration
-- recreates v_tour with 253's updated_at expression under the same recipe (the extra _live_tour column is
-- harmless). Dropping the table column afterwards needs a `-- migrate: destructive` file and the CIS code that writes
-- it reverted first.

BEGIN;
SET LOCAL lock_timeout = '10s';

-- ── Preconditions (as the file's role: cis_owner on Dev) ─────────────────────────────────────────────────────────
DO $$
BEGIN
    IF (SELECT count(*) FROM shared.schema_versions WHERE version IN ('253', '256', '257', '258')) <> 4 THEN
        RAISE EXCEPTION 'migration 273: apply 253, 256, 257 and 258 first';
    END IF;
    IF to_regclass('catalog._live_tour') IS NULL OR to_regclass('catalog.v_tour') IS NULL THEN
        RAISE EXCEPTION 'migration 273: catalog._live_tour / catalog.v_tour missing (apply 253 first)';
    END IF;
    IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'catalog') <> 'cis_owner' THEN
        RAISE EXCEPTION 'migration 273: schema catalog is not owned by cis_owner (apply 245 first)';
    END IF;
    -- an updated_at that is not this file's column would be kept by ADD COLUMN IF NOT EXISTS
    IF EXISTS (SELECT 1 FROM pg_attribute
                WHERE attrelid = 'gold_aa_internal.published_tours'::regclass AND attname = 'updated_at'
                  AND NOT attisdropped AND atttypid <> 'timestamptz'::regtype) THEN
        RAISE EXCEPTION 'migration 273: published_tours.updated_at exists and is not a timestamptz column';
    END IF;
END $$;

-- ── 1. The column (owner cis_owner) ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE gold_aa_internal.published_tours ADD COLUMN IF NOT EXISTS updated_at timestamptz;
UPDATE gold_aa_internal.published_tours SET updated_at = published_at WHERE updated_at IS NULL;
ALTER TABLE gold_aa_internal.published_tours ALTER COLUMN updated_at SET DEFAULT now();
ALTER TABLE gold_aa_internal.published_tours ALTER COLUMN updated_at SET NOT NULL;

COMMENT ON COLUMN gold_aa_internal.published_tours.updated_at IS
    'AA-645 d06 (273): when this Master Content row last changed (a publish of a new version, a promote). '
    'published_at is the first publish and is never moved by a rewrite.';

GRANT CREATE ON SCHEMA catalog TO catalog_owner;
SET LOCAL ROLE catalog_owner;

-- ── What the closing check compares with (as catalog_owner: only its RLS policy admits rows) ─────────────────────
DO $$
BEGIN
    PERFORM set_config('app.tenant_id', '00000000-0000-0000-0000-000000000000', true);
    PERFORM set_config('aa645.v_tour_cols',
                       (SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', '
                                          ORDER BY a.attnum)
                          FROM pg_attribute a
                         WHERE a.attrelid = 'catalog.v_tour'::regclass AND a.attnum > 0 AND NOT a.attisdropped),
                       true);
    PERFORM set_config('aa645.live_tour_cols',
                       (SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', '
                                          ORDER BY a.attnum)
                          FROM pg_attribute a
                         WHERE a.attrelid = 'catalog._live_tour'::regclass AND a.attnum > 0
                           AND NOT a.attisdropped AND a.attname <> 'master_updated_at'),
                       true);
    PERFORM set_config('aa645.expected_live', (SELECT count(*) FROM catalog._live_tour)::text, true);
    PERFORM set_config('app.tenant_id', '', true);
END $$;

-- ── 2. Live tours (internal): 258's statement + the Master row's updated_at as the last column ───────────────────
CREATE OR REPLACE VIEW catalog._live_tour AS
SELECT rt.tour_id,
       rt.source_key AS source_id,
       rt.source_version, rt.sku, rt.country, rt.duration, rt.inclusions, rt.exclusions,
       rt.activities, rt.best_time_to_go, rt.group_size, rt.lifecycle_stage,
       pt.aa_name, pt.aa_subtitle, pt.aa_summary, pt.aa_description, pt.aa_highlights,
       pt.aa_itineraries, pt.published_at,
       pt.updated_at AS master_updated_at
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
    'stored column, so the join is an index condition under FORCE RLS). master_updated_at (273) is the Master row''s '
    'last change. Not security_barrier so the views that join it can flatten it; not granted to consumers; may change '
    'without notice.';

-- ── 3. Tours: 253's statement, updated_at follows the Master row's last change ────────────────────────────────────
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
       -- 273: published_at is the first publish (a rewrite keeps it); the Master row's updated_at records the
       -- rewrite. Still not a change cursor (catalog.tour.v1): consumers diff content_hash.
       GREATEST(e.published_at, e.master_updated_at, e.photos_updated_at) AS updated_at,
       md5(jsonb_build_array(
           e.aa_name, e.aa_subtitle, e.aa_summary, e.aa_description, e.aa_highlights, e.aa_itineraries,
           e.country, e.duration, e.activities, e.inclusions, e.exclusions, e.best_time_to_go,
           e.group_size, e.lifecycle_stage::text, e.sku, e.cover_photo_path
       )::text)                   AS content_hash
  FROM enriched e;

-- ── Closing check as catalog_owner: same columns, same rows ──────────────────────────────────────────────────────
DO $$
DECLARE
    cols text;
    n    bigint;
BEGIN
    PERFORM set_config('app.tenant_id', '00000000-0000-0000-0000-000000000000', true);
    SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum) INTO cols
      FROM pg_attribute a WHERE a.attrelid = 'catalog.v_tour'::regclass AND a.attnum > 0 AND NOT a.attisdropped;
    IF cols IS DISTINCT FROM current_setting('aa645.v_tour_cols') THEN
        RAISE EXCEPTION 'migration 273: catalog.v_tour columns changed: %', cols;
    END IF;
    SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum) INTO cols
      FROM pg_attribute a WHERE a.attrelid = 'catalog._live_tour'::regclass AND a.attnum > 0 AND NOT a.attisdropped;
    IF cols IS DISTINCT FROM current_setting('aa645.live_tour_cols') || ', master_updated_at timestamp with time zone'
    THEN
        RAISE EXCEPTION 'migration 273: catalog._live_tour columns are not 258''s plus master_updated_at: %', cols;
    END IF;
    SELECT count(*) INTO n FROM catalog.v_tour;
    IF n <> current_setting('aa645.expected_live')::bigint THEN
        RAISE EXCEPTION 'migration 273: catalog.v_tour has % rows, _live_tour had % before', n,
            current_setting('aa645.expected_live');
    END IF;
    RAISE NOTICE 'migration 273: as catalog_owner, v_tour rows unchanged (%)', n;
    PERFORM set_config('app.tenant_id', '', true);
END $$;

SET LOCAL ROLE cis_owner;
REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;

-- ── Column check (as cis_owner: its policy reads every row) ──────────────────────────────────────────────────────
DO $$
DECLARE
    n bigint;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_attribute a
                    JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
                   WHERE a.attrelid = 'gold_aa_internal.published_tours'::regclass AND a.attname = 'updated_at'
                     AND NOT a.attisdropped AND a.attnotnull AND a.atttypid = 'timestamptz'::regtype
                     AND pg_get_expr(d.adbin, d.adrelid) = 'now()') THEN
        RAISE EXCEPTION 'migration 273: published_tours.updated_at is not timestamptz NOT NULL DEFAULT now()';
    END IF;
    SELECT count(*) INTO n FROM gold_aa_internal.published_tours WHERE updated_at < published_at;
    IF n <> 0 THEN
        RAISE EXCEPTION 'migration 273: % published_tours rows have updated_at before published_at', n;
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('273', now(), 'AA-645 d06: published_tours.updated_at (a rewrite keeps published_at, records updated_at); '
                      'catalog._live_tour.master_updated_at, v_tour.updated_at follows it; same v_tour columns and rows')
ON CONFLICT (version) DO NOTHING;

COMMIT;
