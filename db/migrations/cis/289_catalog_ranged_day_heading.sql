-- Migration 289: AA-990 (S253) — catalog day readers apply the one ranged-heading rule: a canonical heading
-- "Day 12-15 — Title" covers days 12..15.
--
-- Why. A writer v2 page (and some sources) group several days under one heading, "Day 12-15 — Beach leisure". The
-- catalog read model only knew "Day N —": catalog._tour_day_text split on '\n(?=Day\s+\d+\s+—)', so the ranged block
-- stayed glued to the end of Day 11's body and days 12-15 had no row in catalog.v_tour_day (TripPlanner's day list,
-- v_tour_place's day text); catalog.v_tour's duration fallback (no number in the duration text) took the highest
-- "Day N —" number, so a range at the end of a tour was not counted. The CIS code now applies one rule everywhere
-- (services/content_generation/day_parse.py: day_range, CANONICAL_HEAD, canonical_blocks); this file is its SQL twin.
--
-- The rule. A heading at the start of a line: "Day" or "Days", the first day, optionally a range end after a hyphen,
-- an en dash or "to" (the em dash is the title separator, never a range separator), whitespace, the em dash. The
-- range end counts only when first < end <= first + 14; otherwise (backwards "Day 15-12", a span over two weeks) the
-- heading is the single first day. Every day of a valid range gets the block's title and body; a day written twice
-- keeps the LAST block (as before, and as itinerary_utils.parse_canonical_itinerary_days).
--
-- What (same columns — names, types, order; CREATE OR REPLACE VIEW cannot drop, rename, reorder or retype a column):
--   1. catalog._tour_day_text: 253's statement with the range-aware split and heading, and one row per covered day
--      (generate_series over first..last). Rows of a tour whose itinerary has no ranged and no "Days N —" heading are
--      unchanged (checked below).
--   2. catalog.v_tour: 273's statement with the duration fallback taking the highest COVERED day. duration_days of
--      a tour with no ranged / "Days N —" heading is unchanged (checked below); no other column changes.
--   3. Register 289.
-- Not here: v_tour_day and v_tour_place read _tour_day_text and pick the new rows up without being restated.
--
-- Guards (RAISE rolls the whole file back): before — 253, 258 and 273 registered, schema catalog owned by cis_owner;
-- a probe of the heading expression on literal headings (hyphen, en dash, "to", "Days", invalid ranges). After, as
-- catalog_owner — _tour_day_text and v_tour keep their columns; v_tour keeps its row count; for every tour without a
-- ranged / "Days N —" heading, _tour_day_text rows and v_tour.duration_days are byte-identical to before.
--
-- Recipe. The X1 S22 catalog recipe, as 253 / 256 / 258 / 273: GRANT CREATE ON SCHEMA catalog TO catalog_owner;
-- SET LOCAL ROLE catalog_owner; the view DDL; SET LOCAL ROLE cis_owner; REVOKE CREATE. DB Migrate runs the file as
-- cis_owner (login db_migrator). Never RESET ROLE, no SECURITY DEFINER, no role DDL. The conftest replay skips this
-- file (it needs 253 / 273's catalog part); tests/integration/test_aa990_migration_289.py applies 253 + 256 + 257 +
-- 258 + 273 + 289 the DB Migrate way inside one transaction and rolls back.
--
-- Order with the code. Independent: the CIS code change (AA-990 S253) and this file can ship in either order; the
-- view and the Python parser agree once both are live (test_aa990_migration_289 pins the parity).
--
-- Locks. The two views take ACCESS EXCLUSIVE until COMMIT (TripPlanner browse and day reads wait milliseconds);
-- lock_timeout 10s: fail fast, re-run when idle. Apply while the job tables are idle (DB Migrate waits for it).
-- Idempotent (CREATE OR REPLACE, ON CONFLICT DO NOTHING), one transaction, self-registering. Applied on Dev from the
-- byte-identical copy in AA-CIS-Infra db/migrations/cis/.
--
-- Rollback: re-run 253's catalog._tour_day_text statement and 273's catalog.v_tour statement under the same recipe,
-- then DELETE FROM shared.schema_versions WHERE version = '289'.

BEGIN;
SET LOCAL lock_timeout = '10s';

-- ── Preconditions (as the file's role: cis_owner on Dev) ─────────────────────────────────────────────────────────
DO $$
DECLARE
    m text[];
BEGIN
    IF (SELECT count(*) FROM shared.schema_versions WHERE version IN ('253', '258', '273')) <> 3 THEN
        RAISE EXCEPTION 'migration 289: apply 253, 258 and 273 first';
    END IF;
    IF to_regclass('catalog._tour_day_text') IS NULL OR to_regclass('catalog.v_tour') IS NULL THEN
        RAISE EXCEPTION 'migration 289: catalog._tour_day_text / catalog.v_tour missing (apply 253 first)';
    END IF;
    IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'catalog') <> 'cis_owner' THEN
        RAISE EXCEPTION 'migration 289: schema catalog is not owned by cis_owner (apply 245 first)';
    END IF;
    -- the heading expression on literal headings: [first, range end or NULL, title]
    m := regexp_match('Day 12-15 — Beach leisure',
                      '^Days?\s+(\d+)(?:[ \t]*(?:[-–]|to)[ \t]*(\d{1,3}))?\s+—[ \t]*([^\n]*)(.*)$');
    IF m IS DISTINCT FROM ARRAY['12', '15', 'Beach leisure', '']::text[] THEN
        RAISE EXCEPTION 'migration 289: heading probe (hyphen) gave %', m;
    END IF;
    m := regexp_match('Days 12 to 15 — Beach',
                      '^Days?\s+(\d+)(?:[ \t]*(?:[-–]|to)[ \t]*(\d{1,3}))?\s+—[ \t]*([^\n]*)(.*)$');
    IF m[1] <> '12' OR m[2] IS DISTINCT FROM '15' OR m[3] <> 'Beach' THEN
        RAISE EXCEPTION 'migration 289: heading probe ("Days … to …") gave %', m;
    END IF;
    m := regexp_match('Day 12–15 — Beach',
                      '^Days?\s+(\d+)(?:[ \t]*(?:[-–]|to)[ \t]*(\d{1,3}))?\s+—[ \t]*([^\n]*)(.*)$');
    IF m[2] IS DISTINCT FROM '15' THEN
        RAISE EXCEPTION 'migration 289: heading probe (en dash) gave %', m;
    END IF;
    m := regexp_match('Day 12 — 15 km ride',
                      '^Days?\s+(\d+)(?:[ \t]*(?:[-–]|to)[ \t]*(\d{1,3}))?\s+—[ \t]*([^\n]*)(.*)$');
    IF m[1] <> '12' OR m[2] IS NOT NULL OR m[3] <> '15 km ride' THEN
        RAISE EXCEPTION 'migration 289: heading probe (single day, numeric title) gave %', m;
    END IF;
    IF (SELECT count(*) FROM regexp_split_to_table(E'Day 11 — A\nx\nDay 12-15 — B\ny\nDays 16 to 17 — C\nz',
                                                   '\n(?=Days?\s+\d+(?:[ \t]*(?:[-–]|to)[ \t]*\d{1,3})?\s+—)'))
       <> 3 THEN
        RAISE EXCEPTION 'migration 289: the split probe did not cut before every heading';
    END IF;
END $$;

GRANT CREATE ON SCHEMA catalog TO catalog_owner;
SET LOCAL ROLE catalog_owner;

-- ── What the closing check compares with (as catalog_owner: only its RLS policy admits rows) ─────────────────────
-- A tour "without the new shapes" has no line starting with a ranged heading or with "Days N": the old and the new
-- view must give it exactly the same rows.
DO $$
BEGIN
    PERFORM set_config('app.tenant_id', '00000000-0000-0000-0000-000000000000', true);
    PERFORM set_config('aa990.day_text_cols',
                       (SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', '
                                          ORDER BY a.attnum)
                          FROM pg_attribute a
                         WHERE a.attrelid = 'catalog._tour_day_text'::regclass AND a.attnum > 0
                           AND NOT a.attisdropped),
                       true);
    PERFORM set_config('aa990.v_tour_cols',
                       (SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', '
                                          ORDER BY a.attnum)
                          FROM pg_attribute a
                         WHERE a.attrelid = 'catalog.v_tour'::regclass AND a.attnum > 0 AND NOT a.attisdropped),
                       true);
    PERFORM set_config('aa990.v_tour_rows', (SELECT count(*) FROM catalog.v_tour)::text, true);
    PERFORM set_config('aa990.plain_day_text',
                       (SELECT md5(coalesce(string_agg(r::text, '|' ORDER BY r::text), ''))
                          FROM (SELECT d.* FROM catalog._tour_day_text d
                                  JOIN catalog._live_tour l ON l.tour_id = d.tour_id
                                 WHERE l.aa_itineraries !~ '(?:^|\n)(?:Days\s+\d|Day\s+\d+[ \t]*(?:[-–]|to)[ \t]*\d)')
                               r),
                       true);
    PERFORM set_config('aa990.plain_duration',
                       (SELECT md5(coalesce(string_agg(t.tour_id::text || ':' || coalesce(t.duration_days::text, '-'),
                                                       '|' ORDER BY t.tour_id), ''))
                          FROM catalog.v_tour t
                         WHERE coalesce(t.itinerary_text, '')
                               !~ '(?:^|\n)(?:Days\s+\d|Day\s+\d+[ \t]*(?:[-–]|to)[ \t]*\d)'),
                       true);
    PERFORM set_config('app.tenant_id', '', true);
END $$;

-- ── 1. Day text (internal): 253's statement, a ranged heading covers each of its days ────────────────────────────
CREATE OR REPLACE VIEW catalog._tour_day_text WITH (security_barrier = true) AS
WITH chunk AS (
    SELECT 'cis'::text AS source_system, t.source_id, t.tour_id, t.country AS tour_country, c.ord,
           regexp_match(btrim(c.txt, E' \t\r\n'),
                        '^Days?\s+(\d+)(?:[ \t]*(?:[-–]|to)[ \t]*(\d{1,3}))?\s+—[ \t]*([^\n]*)(.*)$') AS m
      FROM catalog._live_tour t
     CROSS JOIN LATERAL regexp_split_to_table(t.aa_itineraries,
                                              '\n(?=Days?\s+\d+(?:[ \t]*(?:[-–]|to)[ \t]*\d{1,3})?\s+—)')
           WITH ORDINALITY AS c(txt, ord)
     WHERE t.aa_itineraries IS NOT NULL
),
block AS (
    -- day_parse.day_range: a range end counts only when first < end <= first + 14
    SELECT source_system, source_id, tour_id, tour_country, ord,
           (m[1])::int AS first_day,
           CASE WHEN m[2] IS NOT NULL AND (m[2])::int > (m[1])::int AND (m[2])::int <= (m[1])::int + 14
                THEN (m[2])::int ELSE (m[1])::int END AS last_day,
           btrim(m[3])             AS title,
           btrim(m[4], E' \t\r\n') AS body
      FROM chunk
     WHERE m IS NOT NULL
)
-- a repeated day number keeps the LAST block (parse_canonical_itinerary_days dict semantics)
SELECT DISTINCT ON (b.tour_id, d.day_number)
       b.source_system, b.source_id, b.tour_id, b.tour_country,
       d.day_number,
       b.title,
       b.body
  FROM block b
 CROSS JOIN LATERAL generate_series(b.first_day, b.last_day) AS d(day_number)
 ORDER BY b.tour_id, d.day_number, b.ord DESC;

-- ── 2. Tours: 273's statement, the duration fallback counts a ranged heading's last day ─────────────────────────
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
       )::text)                   AS content_hash
  FROM enriched e;

-- ── Closing check as catalog_owner: same columns, same rows where no new shape is written ───────────────────────
DO $$
DECLARE
    v text;
    n bigint;
BEGIN
    PERFORM set_config('app.tenant_id', '00000000-0000-0000-0000-000000000000', true);
    SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum) INTO v
      FROM pg_attribute a WHERE a.attrelid = 'catalog._tour_day_text'::regclass AND a.attnum > 0
       AND NOT a.attisdropped;
    IF v IS DISTINCT FROM current_setting('aa990.day_text_cols') THEN
        RAISE EXCEPTION 'migration 289: catalog._tour_day_text columns changed: %', v;
    END IF;
    SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum) INTO v
      FROM pg_attribute a WHERE a.attrelid = 'catalog.v_tour'::regclass AND a.attnum > 0 AND NOT a.attisdropped;
    IF v IS DISTINCT FROM current_setting('aa990.v_tour_cols') THEN
        RAISE EXCEPTION 'migration 289: catalog.v_tour columns changed: %', v;
    END IF;
    SELECT count(*) INTO n FROM catalog.v_tour;
    IF n <> current_setting('aa990.v_tour_rows')::bigint THEN
        RAISE EXCEPTION 'migration 289: catalog.v_tour has % rows, % before', n, current_setting('aa990.v_tour_rows');
    END IF;
    SELECT md5(coalesce(string_agg(r::text, '|' ORDER BY r::text), '')) INTO v
      FROM (SELECT d.* FROM catalog._tour_day_text d
              JOIN catalog._live_tour l ON l.tour_id = d.tour_id
             WHERE l.aa_itineraries !~ '(?:^|\n)(?:Days\s+\d|Day\s+\d+[ \t]*(?:[-–]|to)[ \t]*\d)') r;
    IF v IS DISTINCT FROM current_setting('aa990.plain_day_text') THEN
        RAISE EXCEPTION 'migration 289: _tour_day_text changed for a tour without a ranged heading';
    END IF;
    SELECT md5(coalesce(string_agg(t.tour_id::text || ':' || coalesce(t.duration_days::text, '-'),
                                   '|' ORDER BY t.tour_id), '')) INTO v
      FROM catalog.v_tour t
     WHERE coalesce(t.itinerary_text, '') !~ '(?:^|\n)(?:Days\s+\d|Day\s+\d+[ \t]*(?:[-–]|to)[ \t]*\d)';
    IF v IS DISTINCT FROM current_setting('aa990.plain_duration') THEN
        RAISE EXCEPTION 'migration 289: v_tour.duration_days changed for a tour without a ranged heading';
    END IF;
    RAISE NOTICE 'migration 289: as catalog_owner, v_tour rows unchanged (%), plain tours unchanged', n;
    PERFORM set_config('app.tenant_id', '', true);
END $$;

SET LOCAL ROLE cis_owner;
REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('289', now(), 'AA-990 S253: catalog._tour_day_text and v_tour.duration_days read a ranged day heading '
                      '("Day 12-15 —") as every day it covers (day_parse.day_range); same columns, same rows otherwise')
ON CONFLICT (version) DO NOTHING;

COMMIT;
