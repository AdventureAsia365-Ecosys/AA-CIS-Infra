-- Migration 359: AA-1040 (EU AI Act Art. 50(2), root ADR 0019 d19) — catalog.v_tour appends text_updated_at, the
-- time the served Master text last changed, so the machine-readable AI mark of a catalog tour states when its text
-- was generated.
--
-- Why. The AI mark of a catalog tour (CIS catalog.http.v1 1.3 `Tour.ai`, the TripPlanner browse JSON `ai`) carries
-- `generated_at`, which must be when the AI-written Master text was produced. catalog.v_tour has only `published_at`
-- (the first publish) and `updated_at` = GREATEST(published_at, master_updated_at, photos_updated_at) (273 / 289):
-- a photo change moves updated_at although the text was not regenerated, so a mark built on it would report a later
-- generation time than the CIS tenant tour reads (they use published_tours.updated_at, moved only by a Master
-- publish). catalog._live_tour already has master_updated_at (273); consumers may not read _live_tour, so v_tour
-- exposes it.
--
-- What (CREATE OR REPLACE VIEW may only append columns; every existing column keeps its name, type, order and value):
--   1. catalog.v_tour: 289's statement unchanged, plus one LAST column
--        text_updated_at  timestamptz  COALESCE(master_updated_at, published_at): the last Master publish / promote
--                                      of the served text, else its first publish. NOT NULL in practice (273 made
--                                      published_tours.updated_at NOT NULL). Not a change cursor either: consumers
--                                      keep diffing content_hash (catalog.tour.v1).
--      The ACL (aa_app_user, booking, tripplanner: SELECT) and the owner are kept by CREATE OR REPLACE.
--   2. Register 359.
-- Contract: an additive column of catalog.tour.v1 (root docs/contracts/README.md row "catalog.tour.v1.3.json
-- (v_tour text_updated_at)"), no new JSON file; folded into the next catalog.tour minor, as 298's projection.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no expand header): a view definition change under the catalog.* recipe
-- (role switch, GRANT / REVOKE CREATE). MIG-4: a migration-only PR (shipped with 358 as one CIS batch); on Dev, Infra
-- Migration Apply applies it when every job table is idle (root ADR 0017a). DM-7.1: a view column, no new table.
--
-- Order with the code. Independent: the CIS catalog.http.v1 reader and the TripPlanner browse Lambda probe for the
-- column (pg_attribute) and fall back to updated_at while it is absent, so either can ship first; the mark is exact
-- once both this file and the code are live.
--
-- Guards (RAISE rolls the whole file back): before — 273 and 289 registered, schema catalog owned by cis_owner, the
-- view catalog_owner's with 289's 26 columns (or this file's 27, a re-run). After, as catalog_owner — the columns are
-- the 26 before plus text_updated_at timestamptz; the same rows, and the 26 old columns hash to the same value;
-- no row has text_updated_at NULL or later than updated_at. After, as cis_owner — owner catalog_owner,
-- security_barrier, grants exactly aa_app_user / booking / tripplanner SELECT, catalog_owner has no CREATE.
--
-- Recipe. The X1 S22 catalog recipe (as 253 / 273 / 289): GRANT CREATE ON SCHEMA catalog TO catalog_owner; SET
-- LOCAL ROLE catalog_owner; the view DDL; SET LOCAL ROLE cis_owner; REVOKE CREATE. DB Migrate runs the file as
-- cis_owner (login db_migrator). Never RESET ROLE, no SECURITY DEFINER, no role DDL, no dynamic SQL. The conftest
-- replay skips this file (it needs 253 / 273 / 289's catalog part); tests/integration/test_aa1040_migration_359.py
-- applies 253 + 256 + 257 + 258 + 273 + 289 + 359 the DB Migrate way in one transaction and rolls back.
--
-- Number. Follows 358 (same PR); see 358's note if the numbers move.
--
-- Locks. One CREATE OR REPLACE VIEW (ACCESS EXCLUSIVE on catalog.v_tour until COMMIT; TripPlanner browse and Booking
-- reads wait milliseconds), lock_timeout 10s: fail fast, re-run when idle. Idempotent (CREATE OR REPLACE with the
-- same statement, ON CONFLICT DO NOTHING), one transaction, self-registering. Applied on Dev from the byte-identical
-- copy in AA-CIS-Infra db/migrations/cis/.
--
-- Rollback: a view cannot drop a column with CREATE OR REPLACE. Revert the consumer code first (or leave it: it falls
-- back when the column is absent), then a new forward migration DROPs and re-creates catalog.v_tour with 289's
-- statement, its grants and every dependent view, under the same recipe.

BEGIN;
SET LOCAL lock_timeout = '10s';

-- ── Preconditions (as the file's role: cis_owner on Dev) ─────────────────────────────────────────────────────────
DO $$
DECLARE
    cols text;
BEGIN
    IF (SELECT count(*) FROM shared.schema_versions WHERE version IN ('273', '289')) <> 2 THEN
        RAISE EXCEPTION 'migration 359: apply 273 and 289 first';
    END IF;
    IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'catalog') IS DISTINCT FROM 'cis_owner' THEN
        RAISE EXCEPTION 'migration 359: schema catalog is not owned by cis_owner (apply 245 first)';
    END IF;
    IF to_regclass('catalog.v_tour') IS NULL
       OR (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = to_regclass('catalog.v_tour'))
          <> 'catalog_owner' THEN
        RAISE EXCEPTION 'migration 359: catalog.v_tour is missing or not catalog_owner''s';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'catalog._live_tour'::regclass
                                                AND attname = 'master_updated_at' AND NOT attisdropped) THEN
        RAISE EXCEPTION 'migration 359: catalog._live_tour has no master_updated_at (apply 273 first)';
    END IF;
    SELECT string_agg(a.attname, ',' ORDER BY a.attnum) INTO cols
      FROM pg_attribute a WHERE a.attrelid = 'catalog.v_tour'::regclass AND a.attnum > 0 AND NOT a.attisdropped;
    IF cols NOT IN ('source_system,source_id,tour_id,source_version,sku,slug,title,subtitle,summary,description,'
                    'highlights,country,duration_raw,duration_days,activities,inclusions,exclusions,best_time_to_go,'
                    'group_size,lifecycle_stage,itinerary_text,cover_photo_path,photo_count,published_at,updated_at,'
                    'content_hash',
                    'source_system,source_id,tour_id,source_version,sku,slug,title,subtitle,summary,description,'
                    'highlights,country,duration_raw,duration_days,activities,inclusions,exclusions,best_time_to_go,'
                    'group_size,lifecycle_stage,itinerary_text,cover_photo_path,photo_count,published_at,updated_at,'
                    'content_hash,text_updated_at') THEN
        RAISE EXCEPTION 'migration 359: catalog.v_tour has unexpected columns: %', cols;
    END IF;
END $$;

GRANT CREATE ON SCHEMA catalog TO catalog_owner;
SET LOCAL ROLE catalog_owner;

-- ── What the closing check compares with (as catalog_owner: only its RLS policy admits rows) ─────────────────────
DO $$
BEGIN
    PERFORM set_config('app.tenant_id', '00000000-0000-0000-0000-000000000000', true);
    PERFORM set_config('aa1040.v_tour_cols',
                       (SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', '
                                          ORDER BY a.attnum)
                          FROM pg_attribute a
                         WHERE a.attrelid = 'catalog.v_tour'::regclass AND a.attnum > 0 AND NOT a.attisdropped
                           AND a.attname <> 'text_updated_at'),
                       true);
    PERFORM set_config('aa1040.v_tour_rows', (SELECT count(*) FROM catalog.v_tour)::text, true);
    PERFORM set_config('aa1040.v_tour_md5',
                       (SELECT md5(coalesce(string_agg(r::text, '|' ORDER BY r::text), ''))
                          FROM (SELECT t.source_system, t.source_id, t.tour_id, t.source_version, t.sku, t.slug,
                                       t.title, t.subtitle, t.summary, t.description, t.highlights, t.country,
                                       t.duration_raw, t.duration_days, t.activities, t.inclusions, t.exclusions,
                                       t.best_time_to_go, t.group_size, t.lifecycle_stage, t.itinerary_text,
                                       t.cover_photo_path, t.photo_count, t.published_at, t.updated_at,
                                       t.content_hash
                                  FROM catalog.v_tour t) r),
                       true);
    PERFORM set_config('app.tenant_id', '', true);
END $$;

-- ── 1. Tours: 289's statement, text_updated_at appended ──────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW catalog.v_tour WITH (security_barrier = true) AS
WITH enriched AS (
    SELECT l.*,
           cover.path AS cover_photo_path,
           COALESCE(photos.n, 0) AS photo_count,
           photos.last_update AS photos_updated_at,
           COALESCE(
               substring(lower(l.duration) FROM '(\d+)\s*-?\s*days?')::int,
               -- 289: the highest day a canonical heading covers (day_parse.day_range)
               (SELECT max(CASE WHEN m[2] IS NOT NULL AND (m[2])::int > (m[1])::int
                                     AND (m[2])::int <= (m[1])::int + 14
                                THEN (m[2])::int ELSE (m[1])::int END)
                  FROM regexp_matches(l.aa_itineraries,
                                      '(?:^|\n)Days?\s+(\d+)(?:[ \t]*(?:[-–]|to)[ \t]*(\d{1,3}))?\s+—', 'g') AS m)
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
       )::text)                   AS content_hash,
       -- 359 (AA-1040): when the served Master text last changed — the Master row's updated_at (moved only by a
       -- Master publish / promote, 273), else the first publish. Photos do not move it (updated_at above does).
       COALESCE(e.master_updated_at, e.published_at) AS text_updated_at
  FROM enriched e;

-- ── Closing checks as catalog_owner: the old columns and rows unchanged, the new column after them ──────────────
DO $$
DECLARE
    v text;
    n bigint;
BEGIN
    PERFORM set_config('app.tenant_id', '00000000-0000-0000-0000-000000000000', true);
    SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum) INTO v
      FROM pg_attribute a WHERE a.attrelid = 'catalog.v_tour'::regclass AND a.attnum > 0 AND NOT a.attisdropped;
    IF v IS DISTINCT FROM current_setting('aa1040.v_tour_cols') || ', text_updated_at timestamp with time zone' THEN
        RAISE EXCEPTION 'migration 359: catalog.v_tour columns are not 289''s plus text_updated_at: %', v;
    END IF;
    SELECT count(*) INTO n FROM catalog.v_tour;
    IF n <> current_setting('aa1040.v_tour_rows')::bigint THEN
        RAISE EXCEPTION 'migration 359: catalog.v_tour has % rows, % before', n,
            current_setting('aa1040.v_tour_rows');
    END IF;
    SELECT md5(coalesce(string_agg(r::text, '|' ORDER BY r::text), '')) INTO v
      FROM (SELECT t.source_system, t.source_id, t.tour_id, t.source_version, t.sku, t.slug,
                   t.title, t.subtitle, t.summary, t.description, t.highlights, t.country,
                   t.duration_raw, t.duration_days, t.activities, t.inclusions, t.exclusions,
                   t.best_time_to_go, t.group_size, t.lifecycle_stage, t.itinerary_text,
                   t.cover_photo_path, t.photo_count, t.published_at, t.updated_at,
                   t.content_hash
              FROM catalog.v_tour t) r;
    IF v IS DISTINCT FROM current_setting('aa1040.v_tour_md5') THEN
        RAISE EXCEPTION 'migration 359: an existing catalog.v_tour column changed value';
    END IF;
    IF EXISTS (SELECT 1 FROM catalog.v_tour WHERE text_updated_at IS NULL OR text_updated_at > updated_at) THEN
        RAISE EXCEPTION 'migration 359: text_updated_at is NULL or later than updated_at on a served tour';
    END IF;
    RAISE NOTICE 'migration 359: as catalog_owner, v_tour rows unchanged (%), of which % with a photo change after '
                 'the last text change', n,
        (SELECT count(*) FROM catalog.v_tour WHERE text_updated_at < updated_at);
    PERFORM set_config('app.tenant_id', '', true);
END $$;

SET LOCAL ROLE cis_owner;
REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;

-- ── Closing checks as cis_owner: owner, barrier, exact consumer grants ───────────────────────────────────────────
DO $$
DECLARE
    privs text;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_class WHERE oid = 'catalog.v_tour'::regclass
                                        AND (pg_get_userbyid(relowner) <> 'catalog_owner'
                                             OR NOT COALESCE(reloptions, '{}') @> ARRAY['security_barrier=true'])) THEN
        RAISE EXCEPTION 'migration 359: catalog.v_tour must be catalog_owner''s and security_barrier';
    END IF;
    SELECT string_agg(r || ':' || p, ', ' ORDER BY r, p) INTO privs FROM (
        SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END AS r, a.privilege_type AS p
          FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a
         WHERE c.oid = 'catalog.v_tour'::regclass AND a.grantee <> c.relowner) x;
    IF privs IS DISTINCT FROM 'aa_app_user:SELECT, booking:SELECT, tripplanner:SELECT' THEN
        RAISE EXCEPTION 'migration 359: unexpected grants on catalog.v_tour: %', privs;
    END IF;
    IF has_schema_privilege('catalog_owner', 'catalog', 'CREATE') THEN
        RAISE EXCEPTION 'migration 359: catalog_owner still has CREATE on schema catalog';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('359', now(), 'AA-1040: catalog.v_tour appends text_updated_at (the last Master publish of the served text, '
                      'photos excluded) for the generated_at of the catalog tour AI mark')
ON CONFLICT (version) DO NOTHING;

COMMIT;
