-- Migration 298: AA-996 follow-up (S256) — catalog.v_tour_place_name, the places of a tour day by name only, for the
-- AA-Booking trip-plans list.
--
-- Why. Booking's trip-plans list shows each tour's places in first-seen order (destinations). It read them from
-- catalog.v_tour_place keyed by tour_id = ANY($1): 380 ms for 25 tours and 994 ms for 100 on Dev (28/10, role booking,
-- against the 1 s statement_timeout of a list extra; Booking #134 bounded it with chunks, a page budget and a cache).
-- Booking reads only tour_id, day_number, position and place_name, but v_tour_place also resolves, for every place,
-- the place card, the destination (three LEFT JOIN LATERAL lookups: the place pipeline link in geo.tour_place with
-- geo.name_norm on both sides, the legacy name + country match in shared.destinations, the chosen destination) and
-- the current build's line stretch in geo.tour_segment. PostgreSQL does not drop an unused LATERAL … LIMIT 1 join,
-- so the reader pays for all of them.
--
-- What:
--   1. catalog.v_tour_place_name (new, security_barrier): source_system, source_id, tour_id, day_number, position,
--      place_name — exactly those columns of catalog.v_tour_place, row for row. It is v_tour_place's atom / spelled /
--      grouped steps (256) without the place card join and without the four lookups: the same live tours
--      (catalog._live_tour), the same day text per tour (the 235 LATERAL over catalog._tour_day_text, so a
--      tour_id filter reaches the parse), the same spelling rule for place_name and the same position order (where
--      the day text names the place, then the first atom, then the place key). Owner catalog_owner; SELECT to booking
--      only (its one reader; TripPlanner and aa_app_user read v_tour_place for coordinates and keep doing so).
--   2. Register 298.
-- Not here: no change to v_tour_place or any other view; no Booking change (Booking reads the new view in its own PR,
-- after this file is applied on Dev).
--
-- Guards (RAISE rolls the whole file back): before — 253, 256 and 289 registered, catalog._live_tour,
-- catalog._tour_day_text and catalog.v_tour_place present, schema catalog owned by cis_owner. After, as catalog_owner
-- (the role the view runs as, so the rows its readers see) — the view's six columns with v_tour_place's types, and
-- the SAME ROWS as v_tour_place's projection on every live tour (EXCEPT ALL both ways, one snapshot). After, as
-- cis_owner — the view is catalog_owner's and security_barrier, booking can read it, tripplanner and aa_app_user
-- cannot, catalog_owner has no CREATE on schema catalog any more.
--
-- Recipe. The X1 S22 catalog recipe, as 253 / 256 / 285 / 289: GRANT CREATE ON SCHEMA catalog TO catalog_owner;
-- SET LOCAL ROLE catalog_owner; the view DDL; SET LOCAL ROLE cis_owner; REVOKE CREATE. DB Migrate runs the file as
-- cis_owner (login db_migrator). Never RESET ROLE, no SECURITY DEFINER, no role DDL. The conftest replay skips this
-- file (it needs 253 and the catalog recipe); tests/integration/test_aa996_migration_298.py applies 253 + 256 + 257 +
-- 258 + 273 + 289 + 298 the DB Migrate way inside one transaction and rolls back.
--
-- Number. 298 was reserved in S255 for this view (297: AA-920 WM-25); 299 (AA-850) was applied first. DB Migrate keys a
-- run by the version and only skips a version already registered, so a number below the highest applied one is
-- accepted; the role lint covers it (298 >= the cis/ role_lint_from 243).
--
-- Order with the code. Apply BEFORE the Booking change that reads the view (until then that read would fail soft:
-- the list drops its destinations and names them in `degraded`). Nothing reads the view before that change.
--
-- Locks. One new view: nothing existing is rewritten or locked beyond ACCESS SHARE for the closing check, which reads
-- v_tour_place and the new view once over every live tour (seconds on Dev). lock_timeout 5s, statement_timeout 3min.
-- Apply while the job tables are idle (DB Migrate waits for it). Idempotent (CREATE OR REPLACE, re-runnable grant,
-- ON CONFLICT DO NOTHING), one transaction, self-registering. Applied on Dev from the byte-identical copy in
-- AA-CIS-Infra db/migrations/cis/. After apply the DB Schema Dump workflow regenerates
-- docs/architecture/db-schema-reference.md.
--
-- Rollback: under the same recipe DROP VIEW catalog.v_tour_place_name (deploy Booking without the read first, or it
-- fails soft as above), then DELETE FROM shared.schema_versions WHERE version = '298'.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '3min';

-- ── Preconditions (as the file's role: cis_owner on Dev) ─────────────────────────────────────────────────────────
DO $$
BEGIN
    IF (SELECT count(*) FROM shared.schema_versions WHERE version IN ('253', '256', '289')) <> 3 THEN
        RAISE EXCEPTION 'migration 298: apply 253, 256 and 289 first';
    END IF;
    IF to_regclass('catalog._live_tour') IS NULL OR to_regclass('catalog._tour_day_text') IS NULL
       OR to_regclass('catalog.v_tour_place') IS NULL THEN
        RAISE EXCEPTION 'migration 298: catalog._live_tour / _tour_day_text / v_tour_place missing';
    END IF;
    IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'catalog') <> 'cis_owner' THEN
        RAISE EXCEPTION 'migration 298: schema catalog is not owned by cis_owner (apply 245 first)';
    END IF;
END $$;

GRANT CREATE ON SCHEMA catalog TO catalog_owner;
SET LOCAL ROLE catalog_owner;

-- ── 1. Places of a tour day by name only (v_tour_place's 256 steps without the card and the lookups) ────────────
CREATE OR REPLACE VIEW catalog.v_tour_place_name WITH (security_barrier = true) AS
WITH atom AS (
    SELECT 'cis'::text AS source_system, t.source_id, t.tour_id,
           a.itinerary_day, btrim(a.place) AS place, lower(btrim(a.place)) AS place_key,
           a.created_at,
           dm.days ->> a.itinerary_day::text AS day_text
      FROM catalog._live_tour t
      CROSS JOIN LATERAL (
          SELECT jsonb_object_agg(d.day_number::text, d.title || E'\n' || d.body) AS days
            FROM catalog._tour_day_text d
           WHERE d.tour_id = t.tour_id
      ) dm
      -- the v_active_tour_atoms rule (203) on the base table: t is already a live master tour
      JOIN acp_contract.tour_atoms a ON a.tour_id = t.tour_id AND NOT a.deleted AND NOT a.is_empty_marker
     WHERE a.place IS NOT NULL AND btrim(a.place) <> ''
),
spelled AS (
    SELECT atom.*,
           count(*) OVER (PARTITION BY tour_id, itinerary_day, place) AS spelling_n,
           strpos(COALESCE(day_text, ''), place) > 0                  AS spelled_in_text
      FROM atom
),
grouped AS (
    SELECT source_system, source_id, tour_id,
           itinerary_day                                                      AS day_number,
           place_key,
           (array_agg(place ORDER BY spelled_in_text DESC, spelling_n DESC,
                                     place COLLATE "C"))[1]                   AS place_name,
           min(created_at)                                                    AS first_seen_at,
           NULLIF(strpos(lower(COALESCE(max(day_text), '')), place_key), 0)   AS text_pos
      FROM spelled
     GROUP BY source_system, source_id, tour_id, itinerary_day, place_key
)
SELECT g.source_system, g.source_id, g.tour_id, g.day_number,
       row_number() OVER (PARTITION BY g.tour_id, g.day_number
                          ORDER BY g.text_pos NULLS LAST, g.first_seen_at,
                                   g.place_key COLLATE "C") AS position,
       g.place_name
  FROM grouped g;

COMMENT ON VIEW catalog.v_tour_place_name IS
    'AA-996 (298): the places of each live tour day by name only — source_system, source_id, tour_id, day_number, '
    'position, place_name, row for row the same as those columns of catalog.v_tour_place, without its place card, '
    'destination and line-stretch lookups. Read it keyed by tour_id (= $1 or = ANY($1::uuid[])): only a tour_id '
    'filter reaches the day-text parse. AA-Booking only (trip-plans list destinations). catalog.tour contract: a '
    'projection of v_tour_place, appended in the next minor version.';
GRANT SELECT ON catalog.v_tour_place_name TO booking;

-- ── Closing check as catalog_owner: the six columns and the same rows as v_tour_place ────────────────────────────
DO $$
DECLARE
    cols text;
    n bigint;
    diff bigint;
BEGIN
    SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum) INTO cols
      FROM pg_attribute a
     WHERE a.attrelid = 'catalog.v_tour_place_name'::regclass AND a.attnum > 0 AND NOT a.attisdropped;
    IF cols IS DISTINCT FROM (
        SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum)
          FROM pg_attribute a
         WHERE a.attrelid = 'catalog.v_tour_place'::regclass AND NOT a.attisdropped
           AND a.attname IN ('source_system', 'source_id', 'tour_id', 'day_number', 'position', 'place_name'))
       OR cols NOT LIKE 'source_system %, source_id %, tour_id %, day_number %, position %, place_name %' THEN
        RAISE EXCEPTION 'migration 298: catalog.v_tour_place_name columns are %', cols;
    END IF;
    PERFORM set_config('app.tenant_id', '00000000-0000-0000-0000-000000000000', true);
    SELECT count(*) INTO n FROM catalog.v_tour_place_name;
    SELECT count(*) INTO diff FROM (
        (SELECT source_system, source_id, tour_id, day_number, position, place_name FROM catalog.v_tour_place
         EXCEPT ALL
         SELECT source_system, source_id, tour_id, day_number, position, place_name FROM catalog.v_tour_place_name)
        UNION ALL
        (SELECT source_system, source_id, tour_id, day_number, position, place_name FROM catalog.v_tour_place_name
         EXCEPT ALL
         SELECT source_system, source_id, tour_id, day_number, position, place_name FROM catalog.v_tour_place)
    ) d;
    IF diff <> 0 THEN
        RAISE EXCEPTION 'migration 298: catalog.v_tour_place_name differs from catalog.v_tour_place in % row(s)', diff;
    END IF;
    RAISE NOTICE 'migration 298: as catalog_owner, v_tour_place_name = v_tour_place (% rows)', n;
    PERFORM set_config('app.tenant_id', '', true);
END $$;

SET LOCAL ROLE cis_owner;
REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;

-- ── Closing check as cis_owner: owner, barrier, exact consumer grant ─────────────────────────────────────────────
DO $$
DECLARE
    r text;
BEGIN
    IF (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'catalog.v_tour_place_name'::regclass)
       <> 'catalog_owner' THEN
        RAISE EXCEPTION 'migration 298: catalog.v_tour_place_name is not catalog_owner''s';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = 'catalog.v_tour_place_name'::regclass
                                            AND 'security_barrier=true' = ANY(reloptions)) THEN
        RAISE EXCEPTION 'migration 298: catalog.v_tour_place_name is not security_barrier';
    END IF;
    IF pg_catalog.has_schema_privilege('catalog_owner', 'catalog', 'CREATE') THEN
        RAISE EXCEPTION 'migration 298: catalog_owner still has CREATE on schema catalog';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'booking')
       AND NOT pg_catalog.has_table_privilege('booking', 'catalog.v_tour_place_name', 'SELECT') THEN
        RAISE EXCEPTION 'migration 298: booking cannot read catalog.v_tour_place_name';
    END IF;
    FOREACH r IN ARRAY ARRAY['tripplanner', 'aa_app_user', 'cis_app'] LOOP
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r)
           AND pg_catalog.has_table_privilege(r, 'catalog.v_tour_place_name', 'SELECT') THEN
            RAISE EXCEPTION 'migration 298: % can read catalog.v_tour_place_name (booking only)', r;
        END IF;
    END LOOP;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('298', now(), 'AA-996: catalog.v_tour_place_name (booking) — the places of a tour day by name only, '
                      'row for row v_tour_place''s names without the card / destination / segment lookups')
ON CONFLICT (version) DO NOTHING;

COMMIT;
