-- Migration 432: AA-1107 (S282, C4.3 W47 finding 2) — the catalog HTTP places read gets fast: catalog.v_tour_place
-- reads the atoms per live tour, catalog._tour_day_text matches a day heading once per chunk, and geo.name_norm skips
-- its accent table on an ASCII-only name. Same rows, same columns, same function results.
--
-- Why. The catalog HTTP places read (services/catalog_http/reader.py, `places`: WHERE source_system = 'cis' AND
-- tour_id = ANY($1)) took 606 ms on Dev for 50 listed tours (S282 audit c43-w47, explain-places-50-tours.txt, all
-- buffer hits: the time is CPU):
--   * ~310 ms: the place-pipeline lookup on geo.tour_place ran geo.name_norm on every candidate row. CIS 431 indexes
--     (source_id, day_index, geo.name_norm(name)), so only the place name's key is computed, once per output row.
--     That one call is still most of it: geo.name_norm spends ~80 % of its time in translate() over its 504-character
--     accent table (local measure: 30 us per call, 5 us without translate; Dev's CPU is a few times slower).
--   * ~77 ms: 256's `JOIN acp_contract.tour_atoms a ON a.tour_id = t.tour_id` was planned as a parallel sequential
--     scan of all ~25,900 placed atoms, sorted for a merge join: PostgreSQL does not carry an `= ANY` filter across the
--     join's equivalence class (lessons, Data: "col = ANY($1) is not pushed down through a JOIN").
--   * ~115 ms: the per-tour day text (catalog._tour_day_text, 289): subquery pull-up substitutes the heading match
--     `m` into every m[1] / m[2] reference, so regexp_match ran several times per chunk instead of once.
--
-- What.
--   1. geo.name_norm(text): 226's body with an ASCII fast path around translate(): when octet_length(p) =
--      char_length(p) (no multi-byte character; the database is UTF8) the input is passed on as is. Every character
--      of the accent table and of the six replace() patterns is non-ASCII, so on such an input translate() and the
--      replaces are the identity: the result is the same string by construction. Non-ASCII and NULL inputs take 226's
--      path unchanged. Same signature, IMMUTABLE PARALLEL SAFE, owner and grants kept (CREATE OR REPLACE). The
--      expression index of 431 stays valid (same results). The twin services/places/names.py::name_norm is unchanged.
--   2. catalog._tour_day_text: 289's statement with the heading match in a LATERAL subquery (OFFSET 0, so it is
--      evaluated once per chunk); same columns, same rows, security_barrier kept.
--   3. catalog.v_tour_place: 256's statement with ONE change in the `atom` step: the atoms of a tour are read in a
--      LATERAL subquery keyed by t.tour_id (OFFSET 0 keeps it from being flattened back into the join the tour filter
--      cannot reach; the partial index idx_tour_atoms_tour_id serves it), with the same predicates (the
--      v_active_tour_atoms rule of 203 on the base table, a non-blank place) and the same output; CROSS JOIN LATERAL
--      drops a tour without placed atoms exactly like the JOIN. Same columns, same rows, security_barrier kept, grants
--      restated. The pipeline lookup text is 256's: 431 makes its name match an index condition.
-- Not here: catalog.v_tour_place_name (298, Booking) and catalog.v_tour_day pick up 1 and 2 without a restatement.
--
-- Guards (RAISE rolls the whole file back). Before: 253, 256, 289 and 431 registered, the objects present, schema
-- catalog owned by cis_owner, the database encoding UTF8 (the fast path's premise). geo.name_norm: its result over
-- every distinct place string the catalogue holds (geo.tour_place.name, acp_contract.tour_atoms.place and its btrim,
-- shared.destinations.name, acp_shared.place_card.display_name) is identical before and after (md5 in "C" order). As
-- catalog_owner (the role the views run as): the row count and an md5 over every row of catalog.v_tour_place (key
-- order tour_id, day_number, position), catalog._tour_day_text and catalog.v_tour_day (tour_id, day_number) are
-- identical before and after. After, as cis_owner: owner, security_barrier, the v_tour_place column list and types,
-- SELECT for aa_app_user / tripplanner / booking, catalog_owner without CREATE on schema catalog, geo.name_norm still
-- IMMUTABLE.
--
-- Class: contract (root ADR 0017 d3: a function and two view definitions change). On Dev, Infra Migration Apply
-- applies it once every job table is idle (root ADR 0017a), after 431.
--
-- Recipe. The function as the file's role (cis_owner, its owner). The views by the X1 S22 catalog recipe, as 253 /
-- 256 / 289 / 298: GRANT CREATE ON SCHEMA catalog TO catalog_owner; SET LOCAL ROLE catalog_owner; the view DDL; SET
-- LOCAL ROLE cis_owner; REVOKE CREATE. Never RESET ROLE, no SECURITY DEFINER, no role DDL. The conftest replay skips
-- this file (it needs 253 / 256 / 289 and the catalog recipe); tests/integration/test_aa1107_migration_432.py applies
-- 253 + 256 + 257 + 258 + 273 + 289 + 431 + 432 the DB Migrate way inside one transaction and rolls back.
--
-- Number. 430 is the highest on main (16/11/2026, CIS 430 of AA-1003 R6); 431 is the index the v_tour_place
-- lookup uses and this file is 432.
--
-- Locks. No table is locked beyond ACCESS SHARE. ACCESS EXCLUSIVE on catalog._tour_day_text and catalog.v_tour_place
-- from their replace until COMMIT: the closing checks read v_tour_place, _tour_day_text and v_tour_day once over every
-- live tour with the new plans (seconds on Dev; TripPlanner and catalog HTTP day / place reads wait that long). The
-- "before" reads run first under ACCESS SHARE only. lock_timeout 10s, statement_timeout 5min. Idempotent (CREATE OR
-- REPLACE, re-runnable grants, ON CONFLICT DO NOTHING), one transaction, self-registering.
--
-- Rollback: re-run 226's geo.name_norm statement as cis_owner, and 289's catalog._tour_day_text and 256's
-- catalog.v_tour_place statements under the catalog recipe (same columns, so CREATE OR REPLACE works), then DELETE FROM
-- shared.schema_versions WHERE version = '432'. Readers see no difference either way.

BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '5min';

-- ── Preconditions (as the file's role: cis_owner on Dev) ─────────────────────────────────────────────────────────
DO $$
BEGIN
    IF (SELECT count(*) FROM shared.schema_versions WHERE version IN ('253', '256', '289', '431')) <> 4 THEN
        RAISE EXCEPTION 'migration 432: apply 253, 256, 289 and 431 first';
    END IF;
    IF to_regclass('catalog._live_tour') IS NULL OR to_regclass('catalog._tour_day_text') IS NULL
       OR to_regclass('catalog.v_tour_place') IS NULL OR to_regclass('catalog.v_tour_day') IS NULL
       OR to_regprocedure('geo.name_norm(text)') IS NULL THEN
        RAISE EXCEPTION 'migration 432: catalog._live_tour / _tour_day_text / v_tour_place / v_tour_day or '
                        'geo.name_norm(text) missing';
    END IF;
    IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'catalog') <> 'cis_owner' THEN
        RAISE EXCEPTION 'migration 432: schema catalog is not owned by cis_owner (apply 245 first)';
    END IF;
    IF current_setting('server_encoding') <> 'UTF8' THEN
        RAISE EXCEPTION 'migration 432: the geo.name_norm ASCII fast path needs a UTF8 database (found %)',
                        current_setting('server_encoding');
    END IF;
END $$;

-- ── Before, as cis_owner: geo.name_norm over every distinct place string of the catalogue ────────────────────────
DO $$
BEGIN
    PERFORM set_config('aa1107.norm', (
        SELECT count(*) || ' ' || md5(COALESCE(string_agg(s || E'\t' || geo.name_norm(s), E'\n'
                                                          ORDER BY s COLLATE "C"), ''))
          FROM (SELECT name AS s FROM geo.tour_place
                UNION SELECT place FROM acp_contract.tour_atoms WHERE place IS NOT NULL
                UNION SELECT btrim(place) FROM acp_contract.tour_atoms WHERE place IS NOT NULL
                UNION SELECT name FROM shared.destinations
                UNION SELECT display_name FROM acp_shared.place_card) corpus), true);
END $$;

-- ── Before, as catalog_owner (the role the views run as): every row of the three views ───────────────────────────
GRANT CREATE ON SCHEMA catalog TO catalog_owner;
SET LOCAL ROLE catalog_owner;

DO $$
BEGIN
    PERFORM set_config('app.tenant_id', '00000000-0000-0000-0000-000000000000', true);
    PERFORM set_config('aa1107.place', (
        SELECT count(*) || ' ' || md5(COALESCE(string_agg(v::text, E'\n' ORDER BY v.tour_id, v.day_number, v.position),
                                               ''))
          FROM catalog.v_tour_place v), true);
    PERFORM set_config('aa1107.day_text', (
        SELECT count(*) || ' ' || md5(COALESCE(string_agg(v::text, E'\n' ORDER BY v.tour_id, v.day_number), ''))
          FROM catalog._tour_day_text v), true);
    PERFORM set_config('aa1107.day', (
        SELECT count(*) || ' ' || md5(COALESCE(string_agg(v::text, E'\n' ORDER BY v.tour_id, v.day_number), ''))
          FROM catalog.v_tour_day v), true);
    PERFORM set_config('app.tenant_id', '', true);
END $$;

SET LOCAL ROLE cis_owner;

-- ── 1. geo.name_norm: 226's body, translate() skipped on an ASCII-only input (the identity there) ────────────────
CREATE OR REPLACE FUNCTION geo.name_norm(p text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $fn$
    SELECT COALESCE(NULLIF(regexp_replace(s, '^((the|a|an) )+', ''), ''), s)
      FROM (
        SELECT btrim(regexp_replace(
                   replace(lower(
                       -- 432: no multi-byte character, so nothing for the accent table or the replaces below
                       CASE WHEN octet_length(p) = char_length(p) THEN p
                       ELSE translate(
                       replace(replace(replace(replace(replace(replace(COALESCE(p, ''),
                           'ß', 'ss'), 'æ', 'ae'), 'Æ', 'ae'), 'œ', 'oe'), 'Œ', 'oe'), '’', ''''),
                       'ÀÁÂÃÄÅÇÈÉÊËÌÍÎÏÑÒÓÔÕÖÙÚÛÜÝàáâãäåçèéêëìíîïñòóôõöùúûüýÿĀāĂăĄąĆćĈĉĊċČčĎďĒēĔĕĖėĘęĚěĜĝĞğĠġĢģĤĥĨĩĪīĬĭĮįİĴĵĶķĹĺĻļĽľŃńŅņŇňŌōŎŏŐőŔŕŖŗŘřŚśŜŝŞşŠšŢţŤťŨũŪūŬŭŮůŰűŲųŴŵŶŷŸŹźŻżŽžſƠơƯưǍǎǏǐǑǒǓǔǕǖǗǘǙǚǛǜǞǟǠǡǦǧǨǩǪǫǬǭǰǴǵǸǹǺǻȀȁȂȃȄȅȆȇȈȉȊȋȌȍȎȏȐȑȒȓȔȕȖȗȘșȚțȞȟȦȧȨȩȪȫȬȭȮȯȰȱȲȳḀḁḂḃḄḅḆḇḈḉḊḋḌḍḎḏḐḑḒḓḔḕḖḗḘḙḚḛḜḝḞḟḠḡḢḣḤḥḦḧḨḩḪḫḬḭḮḯḰḱḲḳḴḵḶḷḸḹḺḻḼḽḾḿṀṁṂṃṄṅṆṇṈṉṊṋṌṍṎṏṐṑṒṓṔṕṖṗṘṙṚṛṜṝṞṟṠṡṢṣṤṥṦṧṨṩṪṫṬṭṮṯṰṱṲṳṴṵṶṷṸṹṺṻṼṽṾṿẀẁẂẃẄẅẆẇẈẉẊẋẌẍẎẏẐẑẒẓẔẕẖẗẘẙẛẠạẢảẤấẦầẨẩẪẫẬậẮắẰằẲẳẴẵẶặẸẹẺẻẼẽẾếỀềỂểỄễỆệỈỉỊịỌọỎỏỐốỒồỔổỖỗỘộỚớỜờỞởỠỡỢợỤụỦủỨứỪừỬửỮữỰựỲỳỴỵỶỷỸỹđĐøØłŁıħĦŧŦƀɨʉ',
                       'aaaaaaceeeeiiiinooooouuuuyaaaaaaceeeeiiiinooooouuuuyyaaaaaaccccccccddeeeeeeeeeegggggggghhiiiiiiiiijjkkllllllnnnnnnoooooorrrrrrssssssssttttuuuuuuuuuuuuwwyyyzzzzzzsoouuaaiioouuuuuuuuuuaaaaggkkoooojggnnaaaaaaeeeeiiiioooorrrruuuusstthhaaeeooooooooyyaabbbbbbccddddddddddeeeeeeeeeeffgghhhhhhhhhhiiiikkkkkkllllllllmmmmmmnnnnnnnnoooooooopppprrrrrrrrssssssssssttttttttuuuuuuuuuuvvvvwwwwwwwwwwxxxxyyzzzzzzhtwysaaaaaaaaaaaaaaaaaaaaaaaaeeeeeeeeeeeeeeeeiiiioooooooooooooooooooooooouuuuuuuuuuuuuuyyyyyyyyddoollihhttbiu') END), '''', ''),
                   '[^a-z0-9]+', ' ', 'g')) AS s
      ) x
$fn$;
COMMENT ON FUNCTION geo.name_norm(text) IS
    'AA-712 — place-name key (accent-folded, lowercased, punctuation to space, leading the/a/an dropped). '
    'Twin of services/places/names.py::name_norm. 432: an ASCII-only input skips the accent table (identity there).';

-- ── After, as cis_owner: the same key for every place string ─────────────────────────────────────────────────────
DO $$
DECLARE
    got text;
BEGIN
    SELECT count(*) || ' ' || md5(COALESCE(string_agg(s || E'\t' || geo.name_norm(s), E'\n'
                                                      ORDER BY s COLLATE "C"), ''))
      INTO got
      FROM (SELECT name AS s FROM geo.tour_place
            UNION SELECT place FROM acp_contract.tour_atoms WHERE place IS NOT NULL
            UNION SELECT btrim(place) FROM acp_contract.tour_atoms WHERE place IS NOT NULL
            UNION SELECT name FROM shared.destinations
            UNION SELECT display_name FROM acp_shared.place_card) corpus;
    IF got <> current_setting('aa1107.norm') THEN
        RAISE EXCEPTION 'migration 432: geo.name_norm results changed (now %, before %)', got,
                        current_setting('aa1107.norm');
    END IF;
    RAISE NOTICE 'migration 432: geo.name_norm identical on the catalogue''s place strings (%)', got;
END $$;

SET LOCAL ROLE catalog_owner;

-- ── 2. Day text (internal): 289's statement, the heading matched once per chunk ──────────────────────────────────
CREATE OR REPLACE VIEW catalog._tour_day_text WITH (security_barrier = true) AS
WITH chunk AS (
    SELECT 'cis'::text AS source_system, t.source_id, t.tour_id, t.country AS tour_country, c.ord, h.m
      FROM catalog._live_tour t
     CROSS JOIN LATERAL regexp_split_to_table(t.aa_itineraries,
                                              '\n(?=Days?\s+\d+(?:[ \t]*(?:[-–]|to)[ \t]*\d{1,3})?\s+—)')
           WITH ORDINALITY AS c(txt, ord)
     -- 432: OFFSET 0 keeps the match from being substituted into each m[...] reference below
     CROSS JOIN LATERAL (
         SELECT regexp_match(btrim(c.txt, E' \t\r\n'),
                             '^Days?\s+(\d+)(?:[ \t]*(?:[-–]|to)[ \t]*(\d{1,3}))?\s+—[ \t]*([^\n]*)(.*)$') AS m
         OFFSET 0
     ) h
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

-- ── 3. Places per tour day: 256's statement, the atoms read per live tour ────────────────────────────────────────
CREATE OR REPLACE VIEW catalog.v_tour_place WITH (security_barrier = true) AS
WITH atom AS (
    SELECT 'cis'::text AS source_system, t.source_id, t.tour_id, t.country AS tour_country,
           a.itinerary_day, a.place, lower(a.place) AS place_key,
           a.atom_id, a.activity_type, a.created_at,
           dm.days ->> a.itinerary_day::text AS day_text,
           pc.card_id
      FROM catalog._live_tour t
      CROSS JOIN LATERAL (
          SELECT jsonb_object_agg(d.day_number::text, d.title || E'\n' || d.body) AS days
            FROM catalog._tour_day_text d
           WHERE d.tour_id = t.tour_id
      ) dm
      -- 432: the v_active_tour_atoms rule (203) on the base table, keyed by this live tour (an index scan per tour);
      -- OFFSET 0 keeps the subquery from being flattened into a join the tour filter cannot reach
      CROSS JOIN LATERAL (
          SELECT ta.itinerary_day, btrim(ta.place) AS place, ta.atom_id, ta.activity_type, ta.created_at
            FROM acp_contract.tour_atoms ta
           WHERE ta.tour_id = t.tour_id
             AND NOT ta.deleted AND NOT ta.is_empty_marker
             AND ta.place IS NOT NULL AND btrim(ta.place) <> ''
          OFFSET 0
      ) a
      LEFT JOIN acp_shared.atom_place_card apc ON apc.atom_id = a.atom_id
      LEFT JOIN acp_shared.place_card pc ON pc.card_id = apc.card_id AND pc.status <> 'rejected'
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
  --    is name_norm of the itinerary spelling, 226 / services/places/components.py); 431 indexes
  --    (source_id, day_index, geo.name_norm(name)), so the name match is an index condition
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

-- ── Grants (CREATE OR REPLACE keeps the existing ones; restated, unguarded) ──────────────────────────────────────
GRANT SELECT ON catalog.v_tour_place TO aa_app_user, tripplanner, booking;

-- ── After, as catalog_owner: the same rows, byte for byte ────────────────────────────────────────────────────────
DO $$
DECLARE
    got text;
BEGIN
    PERFORM set_config('app.tenant_id', '00000000-0000-0000-0000-000000000000', true);
    SELECT count(*) || ' ' || md5(COALESCE(string_agg(v::text, E'\n' ORDER BY v.tour_id, v.day_number, v.position),
                                           ''))
      INTO got FROM catalog.v_tour_place v;
    IF got <> current_setting('aa1107.place') THEN
        RAISE EXCEPTION 'migration 432: catalog.v_tour_place changed (now %, before %)', got,
                        current_setting('aa1107.place');
    END IF;
    SELECT count(*) || ' ' || md5(COALESCE(string_agg(v::text, E'\n' ORDER BY v.tour_id, v.day_number), ''))
      INTO got FROM catalog._tour_day_text v;
    IF got <> current_setting('aa1107.day_text') THEN
        RAISE EXCEPTION 'migration 432: catalog._tour_day_text changed (now %, before %)', got,
                        current_setting('aa1107.day_text');
    END IF;
    SELECT count(*) || ' ' || md5(COALESCE(string_agg(v::text, E'\n' ORDER BY v.tour_id, v.day_number), ''))
      INTO got FROM catalog.v_tour_day v;
    IF got <> current_setting('aa1107.day') THEN
        RAISE EXCEPTION 'migration 432: catalog.v_tour_day changed (now %, before %)', got,
                        current_setting('aa1107.day');
    END IF;
    RAISE NOTICE 'migration 432: as catalog_owner v_tour_place (%), _tour_day_text (%), v_tour_day (%) unchanged',
                 current_setting('aa1107.place'), current_setting('aa1107.day_text'), current_setting('aa1107.day');
    PERFORM set_config('app.tenant_id', '', true);
END $$;

SET LOCAL ROLE cis_owner;
REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;

-- ── Closing check as cis_owner: owner, barrier, columns, consumer grants, the function's volatility ──────────────
DO $$
DECLARE
    r text;
BEGIN
    IF (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'catalog.v_tour_place'::regclass)
       <> 'catalog_owner' THEN
        RAISE EXCEPTION 'migration 432: catalog.v_tour_place is not catalog_owner''s';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_class
                WHERE oid IN ('catalog.v_tour_place'::regclass, 'catalog._tour_day_text'::regclass)
                  AND NOT 'security_barrier=true' = ANY(COALESCE(reloptions, '{}'))) THEN
        RAISE EXCEPTION 'migration 432: catalog.v_tour_place / _tour_day_text is not security_barrier';
    END IF;
    IF (SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum)
          FROM pg_attribute a
         WHERE a.attrelid = 'catalog.v_tour_place'::regclass AND a.attnum > 0 AND NOT a.attisdropped)
       <> 'source_system text, source_id text, tour_id uuid, day_number smallint, position bigint, place_name text, '
          'place_card_id uuid, place_display_name text, locality text, region text, country text, '
          'destination_id uuid, destination_name text, lat double precision, lng double precision, '
          'activity_types text[], atom_count bigint, located_by text, precision text, segment jsonb, '
          'segment_basis text, segment_from_destination_id uuid, segment_to_destination_id uuid, '
          'segment_km double precision' THEN
        RAISE EXCEPTION 'migration 432: catalog.v_tour_place columns changed';
    END IF;
    IF pg_catalog.has_schema_privilege('catalog_owner', 'catalog', 'CREATE') THEN
        RAISE EXCEPTION 'migration 432: catalog_owner still has CREATE on schema catalog';
    END IF;
    IF (SELECT provolatile FROM pg_proc WHERE oid = 'geo.name_norm(text)'::regprocedure) <> 'i' THEN
        RAISE EXCEPTION 'migration 432: geo.name_norm is not IMMUTABLE (431''s index needs it)';
    END IF;
    FOREACH r IN ARRAY ARRAY['aa_app_user', 'tripplanner', 'booking'] LOOP
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r)
           AND NOT pg_catalog.has_table_privilege(r, 'catalog.v_tour_place', 'SELECT') THEN
            RAISE EXCEPTION 'migration 432: % cannot read catalog.v_tour_place', r;
        END IF;
    END LOOP;
END $$;

-- S282 review: 431's expression index evaluates geo.name_norm on every geo.tour_place write as the writing role
-- (cis_app, place_extract). Today cis_app has EXECUTE only through the default PUBLIC grant; 228 grants it explicitly
-- to catalog_owner, aa_app_user, tripplanner and booking. Grant it to cis_app too, so a later REVOKE ... FROM PUBLIC on
-- geo cannot break place_extract writes.
GRANT EXECUTE ON FUNCTION geo.name_norm(text) TO cis_app;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('432', now(), 'AA-1107: fast catalog places read: v_tour_place reads atoms per live tour, _tour_day_text '
                      'matches a heading once per chunk, geo.name_norm ASCII fast path; same rows and results')
ON CONFLICT (version) DO NOTHING;

COMMIT;
