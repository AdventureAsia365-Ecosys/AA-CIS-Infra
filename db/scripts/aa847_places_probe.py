"""AA-847 (places L4 + flip gate), read-only: coverage, reader timings, view fingerprints, defects, environment.

Dispatch: DB Migrate, mode=run-script, script=db/scripts/aa847_places_probe.py. READ_ONLY = True: the session is
default-read-only and the idle check only reports, so it can run during a wave. Dispatch it as the baseline, after
CIS 253, after the paid place run and after the PLACES_SOURCE=cis flip (root docs/audits/2026-10-21-S246-aa847/).

Three passes (each its own transaction):
  * pass 1 runs as `tripplanner` (SET LOCAL ROLE inside one transaction, the role the TripPlanner Lambdas log in
    as), so every catalog.* read goes through the views exactly as the Lambdas read them. If the master may not
    switch to tripplanner the probe prints `SCRIPT refuse set_role` and returns 1;
  * pass 2 runs as the master (its own transaction), only for what tripplanner cannot read: the old tour_id ->
    source_id mapping through silver_aa_internal.raw_tours, geo build state, the environment. The master is a member
    of cis_owner (USING true policies), so every master query names the AA tenant explicitly;
  * pass 3 runs as `tripplanner` again for section 5, which needs pass 2's old tour_id -> source_id map.

Sections (every line starts with `SCRIPT `; aggregates, ids, statuses, catalog titles and place names only):
  1. coverage per country, the ADR 0007 decision 10 / design §7 b2 flip gate:
       SCRIPT coverage country=<c> live=<n> cis_components=<n> cis_graph=<n> frozen_live=<n> frozen_not_live=<n>
              missing_in_cis_live=<n>
       SCRIPT coverage_missing country=<c> source_id=<id> title=<t>          (capped)
       SCRIPT coverage_gate missing_in_cis_live=<n> verdict=PASS|FAIL
  2. reader timings as tripplanner, legacy vs cis, with the readers' exact SQL (READERS block below, generated from
     the TripPlanner source) and filter shapes, for COUNTRIES, REPEATS times (default 3); the slowest call of each
     (reader, source) over all runs is EXPLAINed (ANALYZE, BUFFERS): top nodes by own time, and where each consumer
     filter landed (pushed into a base scan or left above a security_barrier subquery):
       SCRIPT timing reader=<r> country=<c> source=<legacy|cis> calls=<n per run> rows=<n run 1> total_ms=<median>
              per_call_ms=<median> max_ms=<max of all runs> errors=<n> repeats=<n full runs> partial=<n cut short>
              runs=<aggregate per run, a/b/c>
       SCRIPT calls reader=routes_single|routes_single_auto country=<c> source=<s> repeat=<n> ms=<per call, in order>
       SCRIPT plan reader=<r> country=<c> source=<s> node=<type>:<relation> own_ms=<x> rows=<n> loops=<n>
       SCRIPT plan_flag reader=<r> ... flag=seq_scan_raw_tours loops=<n>        (a liveness probe re-scanning raw_tours)
       SCRIPT qual reader=<r> country=<c> source=<s> marker=<m> at=<type>:<relation> pushed=<t|f>
       SCRIPT parity reader=<r> country=<c> legacy=<median> cis=<median> target=<t> verdict=PASS|FAIL runs=<n>
              partial=<n> cis_runs=<a/b/c> legacy_runs=<a/b/c>
              a run the budget cut short (fewer calls of the reader than a full run) stays out of the median and is
              counted in partial=; runs= and the a/b/c lists are the full runs only.
              target = max(1.5 x legacy, 200 ms) on the MEDIAN of the runs (one noisy run neither fails nor rescues a
              reader); aggregation (S237): countries, by_country and routes per call,
              tiles = sum of the country's 1-degree tiles (cap 80) + the 10-degree tile, detail = sum over the union
              of the country's destinations (cap), search = mean per query, tour_route = mean per sampled tour.
       SCRIPT parity_total passes=<n> fails=<n> runs=<n>
     The cis routes_single + routes_chain calls run under plan_cache_mode=force_custom_plan, as TripPlanner's
     proposals() runs them (set_config(..., true) before, the session value restored right after: a SET LOCAL would
     survive the released savepoints and reach every later reader). routes_single_auto (run 1, cis, not scored) is
     the same read left at the session plan_cache_mode under its own statement text: a jump from call 6 on is the
     generic cached plan. The search readers run under TripPlanner's hnsw.ef_search / hnsw.iterative_scan in a
     savepoint that is rolled back after them (TripPlanner scopes them to the search's own transaction), so routes
     and assembly (incl. assembly_route_candidates) run at the session values; the EXPLAIN of the slowest search call
     gets the same settings back.
  2b. env_topk, as tripplanner with TripPlanner's hnsw.ef_search / hnsw.iterative_scan: EXPLAIN of the generated
     TOPK_SQL_CIS (the query vector bound as $1), natural and with enable_sort=off (forced):
       SCRIPT env_topk mode=natural|forced exec_ms=<x> uses_hnsw=<t|f> hnsw_order_by=<t|f> live_probe=<path to the
              raw_tours scan of the liveness semi-join> live_index=<index|-> join_filter_source_id=<t|f>
              raw_tours_seq_loops=<n>
       SCRIPT env_topk_summary uses_hnsw_natural=<t|f> uses_hnsw_forced=<t|f> live_probe=<forced> ...
              verdict_full=PASS|FAIL (step 18 revised: no raw_tours seq scan loops>1 in the natural plan; forced = HNSW
              ordered by distance, liveness on raw_tours_source_key_idx, no Join Filter on source_id)
              verdict_pre258=PASS|FAIL (forced plan reaches the HNSW index ordered by distance)
  2c. generic-plan proof: PREPARE of the cis single route read, EXPLAIN EXECUTE under force_generic_plan and
     force_custom_plan (days 21, slack 3):
       SCRIPT generic_plan reader=routes_single country=<c> generic_exec_ms=<x> custom_exec_ms=<x> jit=<setting>
  3. fingerprints as tripplanner of every catalog.* view it may read (before / after CIS 253 must be equal):
       SCRIPT fingerprint view=<v> rows=<n> md5=<x> ms=<x>
  4. defects named in AA-847 (HCM Trail by Bicycle, Laos Kuang Si tours): duration, canonical and ranged day
     headings, components per day with destination, precision, located_by, review_reason, geocoder result_type;
     Kuang Si destinations and their pairwise km; geo build state of those tours:
       SCRIPT defect_tour ... / SCRIPT defect_component ... / SCRIPT defect_place ... / SCRIPT defect_pair ...
  5. AA-819 check: does the component's own tour-day text name it? frozen tripplanner.itinerary_components (live
     tours) and catalog.v_tour_component, per country:
       SCRIPT day_text source=<frozen|cis> country=<c> components=<n> no_day_text=<n> not_named=<n>
  6. environment: pgvector version, hnsw.iterative_scan, jit, live tours sharing a source_id (CIS 253's closing
     count), tripplanner's privileges in silver_aa_internal / acp_contract, cross-app references to
     shared.destinations, pg_stat_statements readability, last ANALYZE of the geo tables:
       SCRIPT env ... / SCRIPT grant ... / SCRIPT xref ... / SCRIPT stats ...

Time budget: the workflow waits 30 minutes; the probe stops a section at BUDGET_S (about 20 minutes) with
`SCRIPT truncated <section>`, caps every sample, and keeps every statement short. A further timing run starts only
when 1.5 x the first run's time + 300 s still fits (`SCRIPT truncated section="repeat <n>"` otherwise; parity then
uses the runs that finished, `runs=<n>` says how many, and drops a run a section cut short, `partial=<n>`). Ends with
`SCRIPT done elapsed_s=<x>`. Returns 1 only when the tripplanner switch is refused.
"""

import contextlib
import json
import math
import re
import time
import unicodedata

READ_ONLY = True

AA_TENANT_ID = "00000000-0000-0000-0000-000000000001"  # TripPlanner config.MASTER_CONTENT_TENANT_ID
COUNTRIES = ["Laos", "Vietnam"]
BUDGET_S = 20 * 60
TILE_CAP = 80
DETAIL_CAP = 150
SEARCH_QUERIES = 8
ROUTE_DAYS = range(3, 22)
ROUTE_SLACK = 3  # TripPlanner browse.routes.SLACK
ROUTE_TOURS_CAP = 10
TOUR_SAMPLE = 60
TOPK_K = 200  # TripPlanner vector_topk.TOPK_PASSES[0]
REPEATS = 3  # timing runs; parity is judged on the median (S246 gate diagnosis: legacy alone moved 2-3x between runs)
HNSW_INDEX = "tour_place_embedding_hnsw"
LIVE_KEY_INDEX = "raw_tours_source_key_idx"  # CIS 258 (stored COALESCE(source_group_id, tour_id)::text)
GENERIC_STMT = "aa847_single_generic"
COVERAGE_MISSING_CAP = 40
DEFECT_TOURS_CAP = 8
DAY_TEXT_EXAMPLES = 5

# BEGIN GENERATED READERS (root docs/audits/2026-10-21-S246-aa847/gen_probe_sql.py; do not edit by hand)
READERS_FROM = "AA-TripPlanner-Web@ee5b0bac5652"
READERS_ABSENT = ['browse.search.CIS_SEARCH_SQL']
READERS = {
    'assembly.activities.ACTIVITIES_SQL': """
    SELECT (array_agg(c.id::text ORDER BY c.source_tour_id, c.source_day_index))[1] AS component_id,
           array_agg(c.id::text) AS component_ids,
           c.name, c.activity, (array_agg(c.intensity_level))[1] AS intensity_level,
           (array_agg(c.duration_hint))[1] AS duration_hint,
           (array_agg(c.text_extract ORDER BY length(c.text_extract) DESC))[1] AS text_extract,
           count(DISTINCT c.source_tour_id) AS tour_count
    FROM tripplanner.itinerary_components c
    WHERE c.destination_id = $1::uuid
    GROUP BY c.name, c.activity
    ORDER BY count(DISTINCT c.source_tour_id) DESC, c.name
""",
    'assembly.activities.ACTIVITIES_SQL_CIS': """
    SELECT (array_agg(c.component_id::text ORDER BY c.source_id, c.day_index))[1] AS component_id,
           array_agg(c.component_id::text) AS component_ids,
           c.name, c.activity, (array_agg(c.intensity_level))[1] AS intensity_level,
           (array_agg(c.duration_hint))[1] AS duration_hint,
           (array_agg(c.text_extract ORDER BY length(c.text_extract) DESC))[1] AS text_extract,
           count(DISTINCT c.source_id) AS tour_count
    FROM catalog.v_tour_component c
    WHERE c.destination_id = $1::uuid
    GROUP BY c.name, c.activity
    ORDER BY count(DISTINCT c.source_id) DESC, c.name
""",
    'assembly.coverage.OPTIONS_SQL': """
    SELECT DISTINCT destination_id::text AS destination_id, source_tour_id, source_day_index
    FROM tripplanner.itinerary_components
    WHERE destination_id = ANY($1::uuid[])
""",
    'assembly.coverage.OPTIONS_SQL_CIS': """
    SELECT DISTINCT destination_id::text AS destination_id, source_id AS source_tour_id,
           day_index AS source_day_index
    FROM catalog.v_tour_component
    WHERE destination_id = ANY($1::uuid[])
""",
    'assembly.events.COMPONENTS_SQL': """
    SELECT c.id, c.name, c.activity, c.duration_hint, c.text_extract,
           c.source_tour_id, c.source_day_index, c.destination_id,
           d.name AS destination_name, d.lat AS lat, d.lng AS lng
    FROM tripplanner.itinerary_components c
    JOIN shared.destinations d ON d.id = c.destination_id
    WHERE c.id = ANY($1::uuid[])
""",
    'assembly.events.COMPONENTS_SQL_CIS': """
    SELECT c.component_id AS id, c.name, c.activity, c.duration_hint, c.text_extract,
           c.source_id AS source_tour_id, c.day_index AS source_day_index, c.destination_id,
           d.name AS destination_name, d.lat AS lat, d.lng AS lng, d.located_by, d.precision,
           c.segment, c.segment_basis, c.segment_from_destination_id, c.segment_to_destination_id, c.segment_km
    FROM catalog.v_tour_component c
    JOIN catalog.v_destination d ON d.destination_id = c.destination_id
    WHERE c.component_id = ANY($1::uuid[])
""",
    'assembly.suggestions.ROUTE_CANDIDATES_SQL': """
    WITH near AS (
        SELECT n.destination_id, 2 * 6371 * asin(sqrt(power(sin(radians(n.lat - $2) / 2), 2) + cos(radians($2)) * cos(radians(n.lat)) * power(sin(radians(n.lng - $3) / 2), 2))) AS transfer_km
        FROM tripplanner.tour_graph_node n
        WHERE 2 * 6371 * asin(sqrt(power(sin(radians(n.lat - $2) / 2), 2) + cos(radians($2)) * cos(radians(n.lat)) * power(sin(radians(n.lng - $3) / 2), 2))) <= $4
    ), here AS (
        SELECT s.source_tour_id, s.day_index, s.destination_id, nr.transfer_km
        FROM tripplanner.tour_stop s JOIN near nr ON nr.destination_id = s.destination_id
    ), nxt AS (
        -- the tour's next stop somewhere else (a stay of several nights is skipped over)
        SELECT h.source_tour_id, h.day_index AS from_day, h.transfer_km,
               (SELECT min(s2.day_index) FROM tripplanner.tour_stop s2
                WHERE s2.source_tour_id = h.source_tour_id AND s2.day_index > h.day_index
                  AND s2.destination_id <> h.destination_id) AS to_day
        FROM here h
    )
    SELECT d.id, d.name, d.lat, d.lng, d.country,
           COUNT(DISTINCT c.id) AS component_count,
           MIN(c.embedding <=> $1::vector) AS best_distance,
           MIN(nx.transfer_km) AS transfer_km,
           COUNT(DISTINCT nx.source_tour_id) AS tour_count
    FROM nxt nx
    JOIN tripplanner.itinerary_components c
      ON c.source_tour_id = nx.source_tour_id
     AND c.source_day_index > nx.from_day AND c.source_day_index <= nx.to_day
    JOIN shared.destinations d ON d.id = c.destination_id
    WHERE nx.to_day IS NOT NULL AND c.embedding IS NOT NULL AND d.id <> ALL($5::uuid[])
      AND ($7::text IS NULL OR c.activity = $7::text)
      AND ($8::text IS NULL OR c.intensity_level = $8::text)
    GROUP BY d.id, d.name, d.lat, d.lng, d.country
    ORDER BY best_distance ASC
    LIMIT $6
""",
    'assembly.suggestions.ROUTE_CANDIDATES_SQL_CIS': """
    WITH near AS (
        SELECT n.destination_id, 2 * 6371 * asin(sqrt(power(sin(radians(n.lat - $2) / 2), 2) + cos(radians($2)) * cos(radians(n.lat)) * power(sin(radians(n.lng - $3) / 2), 2))) AS transfer_km
        FROM catalog.v_graph_node n
        WHERE 2 * 6371 * asin(sqrt(power(sin(radians(n.lat - $2) / 2), 2) + cos(radians($2)) * cos(radians(n.lat)) * power(sin(radians(n.lng - $3) / 2), 2))) <= $4
    ), stops AS MATERIALIZED (
        SELECT source_id, day_index, destination_id FROM catalog.v_tour_stop
    ), here AS (
        SELECT s.source_id, s.day_index, s.destination_id, nr.transfer_km
        FROM stops s JOIN near nr ON nr.destination_id = s.destination_id
    ), nxt AS MATERIALIZED (
        -- the tour's next stop somewhere else (a stay of several nights is skipped over)
        SELECT h.source_id, h.day_index AS from_day, h.transfer_km, min(s2.day_index) AS to_day
        FROM here h
        JOIN stops s2 ON s2.source_id = h.source_id AND s2.day_index > h.day_index
                     AND s2.destination_id <> h.destination_id
        GROUP BY h.source_id, h.day_index, h.destination_id, h.transfer_km
    )
    SELECT d.destination_id AS id, d.name, d.lat, d.lng, d.country,
           COUNT(DISTINCT c.component_id) AS component_count,
           MIN(c.embedding <=> $1::vector) AS best_distance,
           MIN(nx.transfer_km) AS transfer_km,
           COUNT(DISTINCT nx.source_id) AS tour_count
    FROM nxt nx
    JOIN catalog.v_tour_component c
      ON c.source_id = nx.source_id
     AND c.day_index > nx.from_day AND c.day_index <= nx.to_day
    JOIN catalog.v_destination d ON d.destination_id = c.destination_id
    WHERE c.embedding IS NOT NULL AND d.destination_id <> ALL($5::uuid[])
      AND ($7::text IS NULL OR c.activity = $7::text)
      AND ($8::text IS NULL OR c.intensity_level = $8::text)
    GROUP BY d.destination_id, d.name, d.lat, d.lng, d.country
    ORDER BY best_distance ASC, d.destination_id
    LIMIT $6
""",
    'assembly.suggestions.TASTE_SQL': """
    SELECT c.embedding, d.country
    FROM tripplanner.itinerary_components c
    JOIN shared.destinations d ON d.id = c.destination_id
    WHERE c.id = ANY($1::uuid[])
""",
    'assembly.suggestions.TASTE_SQL_CIS': """
    SELECT c.embedding, d.country
    FROM catalog.v_tour_component c
    JOIN catalog.v_destination d ON d.destination_id = c.destination_id
    WHERE c.component_id = ANY($1::uuid[])
""",
    'browse.countries.COUNTRIES_SQL': """
    SELECT d.country AS country, COUNT(c.id) AS component_count
    FROM shared.destinations d
    JOIN tripplanner.itinerary_components c ON c.destination_id = d.id
    WHERE d.country IS NOT NULL AND d.country <> ''
    GROUP BY d.country
    HAVING COUNT(c.id) > 0
    ORDER BY d.country ASC
""",
    'browse.countries.COUNTRIES_SQL_CIS': """
    SELECT d.country AS country, COUNT(c.component_id) AS component_count
    FROM catalog.v_destination d
    JOIN catalog.v_tour_component c ON c.destination_id = d.destination_id
    WHERE d.country IS NOT NULL AND d.country <> ''
    GROUP BY d.country
    HAVING COUNT(c.component_id) > 0
    ORDER BY d.country ASC
""",
    'browse.countries.COUNTRY_DESTINATIONS_SQL': """
    SELECT d.id, d.name, d.lat, d.lng, COUNT(c.id) AS component_count
    FROM shared.destinations d
    JOIN tripplanner.itinerary_components c ON c.destination_id = d.id
    WHERE d.country = $1
    GROUP BY d.id, d.name, d.lat, d.lng
    HAVING COUNT(c.id) > 0
    ORDER BY component_count DESC
""",
    'browse.countries.COUNTRY_DESTINATIONS_SQL_CIS': """
    SELECT d.destination_id AS id, d.name, d.lat, d.lng, d.located_by, d.precision, d.shape_kind, d.shape_status, d.length_km, d.min_lat, d.min_lng, d.max_lat, d.max_lng,
           COUNT(c.component_id) AS component_count
    FROM catalog.v_destination d
    JOIN catalog.v_tour_component c ON c.destination_id = d.destination_id
    WHERE d.country = $1
    GROUP BY d.destination_id, d.name, d.lat, d.lng, d.located_by, d.precision, d.shape_kind, d.shape_status, d.length_km, d.min_lat, d.min_lng, d.max_lat, d.max_lng
    HAVING COUNT(c.component_id) > 0
    ORDER BY component_count DESC
""",
    'browse.destinations.COMPONENTS_SQL': """
    SELECT id, name, activity, intensity_level, duration_hint,
           text_extract
    FROM tripplanner.itinerary_components
    WHERE destination_id = $1
    ORDER BY name
""",
    'browse.destinations.COMPONENTS_SQL_CIS': """
    SELECT component_id AS id, name, activity, intensity_level, duration_hint, text_extract
    FROM catalog.v_tour_component
    WHERE destination_id = $1::uuid
    ORDER BY name, component_id
""",
    'browse.destinations.DEST_SQL': """SELECT id, name, country, cover_image_url FROM shared.destinations WHERE id = $1""",
    'browse.destinations.DEST_SQL_CIS': """
    SELECT destination_id AS id, name, country, cover_image_url, located_by, precision, shape_kind, shape_status, length_km, min_lat, min_lng, max_lat, max_lng
    FROM catalog.v_destination WHERE destination_id = $1::uuid
""",
    'browse.routes.CHAIN_SQL': """
    WITH a AS (
        SELECT l.* FROM tripplanner.tour_leg l
        WHERE $1 = ANY(l.countries) AND l.days < $2::int
          AND l.day_from = (SELECT min(s.day_index) FROM tripplanner.tour_stop s
                            WHERE s.source_tour_id = l.source_tour_id)
    ), b AS (
        SELECT l.* FROM tripplanner.tour_leg l WHERE $1 = ANY(l.countries) AND l.days < $2::int
    )
    SELECT a.source_tour_id AS a_tour, a.day_from AS a_from, a.day_to AS a_to, a.days AS a_days,
           b.source_tour_id AS b_tour, b.day_from AS b_from, b.day_to AS b_to, b.days AS b_days,
           coalesce(j.km, 0) AS transfer_km,
           cardinality(a.destination_ids) + cardinality(b.destination_ids) AS places
    FROM a
    JOIN b ON b.source_tour_id <> a.source_tour_id AND a.days + b.days BETWEEN $2::int - $3::int AND $2::int
    LEFT JOIN tripplanner.tour_junction j
           ON j.destination_a = a.end_destination_id AND j.destination_b = b.start_destination_id
    WHERE b.start_destination_id = a.end_destination_id OR j.destination_a IS NOT NULL
    ORDER BY abs(a.days + b.days - $2::int), coalesce(j.km, 0), places DESC
    LIMIT 40
""",
    'browse.routes.CHAIN_SQL_CIS': """
    WITH span AS MATERIALIZED (
        SELECT source_id, min(day_index) AS first_day FROM catalog.v_tour_stop GROUP BY source_id
    ), legs AS MATERIALIZED (
        SELECT l.source_id, l.day_from, l.day_to, l.days, l.start_destination_id, l.end_destination_id,
               l.destination_ids
        FROM catalog.v_tour_leg l WHERE $1 = ANY(l.countries) AND l.days < $2::int
    ), a AS MATERIALIZED (
        SELECT l.* FROM legs l JOIN span sp ON sp.source_id = l.source_id AND l.day_from = sp.first_day
    ), j AS MATERIALIZED (
        SELECT destination_a, destination_b, km FROM catalog.v_tour_junction
    ), hop AS (
        SELECT a.*, a.end_destination_id AS next_start, NULL::double precision AS km FROM a
        UNION ALL
        SELECT a.*, j.destination_b AS next_start, j.km
        FROM a JOIN j ON j.destination_a = a.end_destination_id AND j.destination_b <> a.end_destination_id
    )
    SELECT h.source_id AS a_tour, h.day_from AS a_from, h.day_to AS a_to, h.days AS a_days,
           b.source_id AS b_tour, b.day_from AS b_from, b.day_to AS b_to, b.days AS b_days,
           coalesce(h.km, 0) AS transfer_km,
           cardinality(h.destination_ids) + cardinality(b.destination_ids) AS places
    FROM hop h
    JOIN legs b ON b.start_destination_id = h.next_start AND b.source_id <> h.source_id
               AND h.days + b.days BETWEEN $2::int - $3::int AND $2::int
    ORDER BY abs(h.days + b.days - $2::int), coalesce(h.km, 0), places DESC,
             h.source_id, h.day_from, h.day_to, b.source_id, b.day_from, b.day_to
    LIMIT 40
""",
    'browse.routes.COMPONENTS_SQL': """
    SELECT source_tour_id AS tour_id, source_day_index AS day_index, destination_id::text AS destination_id,
           id::text AS component_id
    FROM tripplanner.itinerary_components
    WHERE source_tour_id = ANY($1::text[]) AND embedding IS NOT NULL
    ORDER BY source_tour_id, source_day_index, id
""",
    'browse.routes.COMPONENTS_SQL_CIS': """
    SELECT source_id AS tour_id, day_index, destination_id::text AS destination_id,
           component_id::text AS component_id
    FROM catalog.v_tour_component
    WHERE source_id = ANY($1::text[]) AND embedding IS NOT NULL
    ORDER BY source_id, day_index, component_id
""",
    'browse.routes.DAYS_SQL': """
    SELECT s.source_tour_id AS tour_id, s.day_index, s.destination_id::text AS destination_id,
           d.name, d.lat, d.lng, d.country
    FROM tripplanner.tour_stop s JOIN shared.destinations d ON d.id = s.destination_id
    WHERE s.source_tour_id = ANY($1::text[])
    ORDER BY s.source_tour_id, s.day_index
""",
    'browse.routes.DAYS_SQL_CIS': """
    SELECT s.source_id AS tour_id, s.day_index, s.destination_id::text AS destination_id,
           d.name, d.lat, d.lng, d.country
    FROM catalog.v_tour_stop s JOIN catalog.v_destination d ON d.destination_id = s.destination_id
    WHERE s.source_id = ANY($1::text[])
    ORDER BY s.source_id, s.day_index
""",
    'browse.routes.PLACE_COMPONENTS_SQL': """
    SELECT destination_id::text AS destination_id, id::text AS component_id
    FROM tripplanner.itinerary_components
    WHERE destination_id = ANY($1::uuid[]) AND embedding IS NOT NULL
    ORDER BY destination_id, (source_tour_id = ANY($2::text[])) DESC, source_tour_id, source_day_index, id
""",
    'browse.routes.PLACE_COMPONENTS_SQL_CIS': """
    SELECT destination_id::text AS destination_id, component_id::text AS component_id
    FROM catalog.v_tour_component
    WHERE destination_id = ANY($1::uuid[]) AND embedding IS NOT NULL
    ORDER BY destination_id, (source_id = ANY($2::text[])) DESC, source_id, day_index, component_id
""",
    'browse.routes.SINGLE_SQL': """
    WITH span AS (
        SELECT source_tour_id, min(day_index) AS first_day, max(day_index) AS last_day
        FROM tripplanner.tour_stop GROUP BY source_tour_id
    )
    SELECT DISTINCT ON (l.source_tour_id)
           l.source_tour_id AS tour_id, l.day_from, l.day_to, l.days, cardinality(l.destination_ids) AS places,
           (l.day_from = sp.first_day AND l.day_to = sp.last_day) AS whole
    FROM tripplanner.tour_leg l JOIN span sp USING (source_tour_id)
    WHERE $1 = ANY(l.countries) AND l.days BETWEEN $2::int - $3::int AND $2::int
    ORDER BY l.source_tour_id, (l.day_from = sp.first_day AND l.day_to = sp.last_day) DESC,
             abs(l.days - $2::int), l.day_from
""",
    'browse.routes.SINGLE_SQL_CIS': """
    WITH span AS MATERIALIZED (
        SELECT source_id, min(day_index) AS first_day, max(day_index) AS last_day
        FROM catalog.v_tour_stop GROUP BY source_id
    )
    SELECT DISTINCT ON (l.source_id)
           l.source_id AS tour_id, l.day_from, l.day_to, l.days, cardinality(l.destination_ids) AS places,
           (l.day_from = sp.first_day AND l.day_to = sp.last_day) AS whole
    FROM catalog.v_tour_leg l JOIN span sp USING (source_id)
    WHERE $1 = ANY(l.countries) AND l.days BETWEEN $2::int - $3::int AND $2::int
    ORDER BY l.source_id, (l.day_from = sp.first_day AND l.day_to = sp.last_day) DESC,
             abs(l.days - $2::int), l.day_from
""",
    'browse.routes.SOURCE_BY_TOUR_SQL': """SELECT source_id FROM catalog.v_tour WHERE tour_id = $1::uuid""",
    'browse.routes.TOURS_BY_SOURCE_SQL': """
    SELECT source_id, tour_id::text AS tour_id, title FROM catalog.v_tour
    WHERE source_id = ANY($1::text[])
""",
    'browse.routes.TOUR_DAYS_COUNT_SQL': """
    SELECT GREATEST(COALESCE(t.duration_days, 0),
                    (SELECT count(*) FROM catalog.v_tour_day d WHERE d.tour_id = t.tour_id))
    FROM catalog.v_tour t WHERE t.tour_id = $1::uuid
""",
    'browse.routes.TOUR_NAMES_SQL': """
    SELECT tour_id::text AS tour_id, aa_name FROM gold_aa_internal.published_tours
    WHERE tour_id::text = ANY($1::text[])
""",
    'browse.routes.TOUR_ROUTE_PLACES_SQL': """
    SELECT day_number, position, destination_id::text AS destination_id, destination_name AS name,
           lat, lng, country
    FROM catalog.v_tour_place
    WHERE tour_id = $1::uuid AND day_number IS NOT NULL AND destination_id IS NOT NULL
      AND lat IS NOT NULL AND lng IS NOT NULL
    ORDER BY day_number, position
""",
    'browse.routes.TOUR_TITLE_SQL': """SELECT title FROM catalog.v_tour WHERE tour_id = $1::uuid""",
    'browse.search.ACTIVE_TOUR_SQL': """
    AND EXISTS (SELECT 1 FROM gold_aa_internal.published_tours pt
                WHERE pt.tour_id::text = c.source_tour_id
                  AND pt.master_status = 'active'
                  AND pt.deleted_at IS NULL)
""",
    'browse.tiles.TILE_SQL': """
        SELECT d.id, d.name, d.lat, d.lng, COUNT(c.id) AS component_count
        FROM shared.destinations d
        JOIN tripplanner.itinerary_components c ON c.destination_id = d.id
        WHERE d.lat >= $1 AND d.lat < $2
          AND d.lng >= $3 AND d.lng < $4
          
        GROUP BY d.id, d.name, d.lat, d.lng
        HAVING COUNT(c.id) > 0
        ORDER BY component_count DESC
    """,
    'browse.tiles.TILE_SQL_CIS': """
        SELECT d.destination_id AS id, d.name, d.lat, d.lng, d.located_by, d.precision,
               d.shape_kind, d.shape_status, d.length_km,
               d.min_lat, d.min_lng, d.max_lat, d.max_lng,
               COUNT(c.component_id) AS component_count
        FROM catalog.v_destination d
        JOIN catalog.v_tour_component c ON c.destination_id = d.destination_id
        WHERE d.max_lat >= $1 AND d.min_lat < $2
          AND d.max_lng >= $3 AND d.min_lng < $4
          
        GROUP BY d.destination_id, d.name, d.lat, d.lng, d.located_by, d.precision,
                 d.shape_kind, d.shape_status, d.length_km, d.min_lat, d.min_lng, d.max_lat, d.max_lng
        HAVING COUNT(c.component_id) > 0
        ORDER BY component_count DESC
    """,
    'shared.component_ids.MAP_SQL': """
    SELECT old_id::text AS old_id, new_id::text AS new_id
    FROM tripplanner.component_id_map
    WHERE old_id = ANY($1::uuid[])
""",
    'shared.vector_topk.EXACT_SQL': """
        SELECT d.id, d.name, d.lat, d.lng, COUNT(c.id) AS component_count,
               MIN(c.embedding <=> $1::vector) AS best_distance
        FROM tripplanner.itinerary_components c
        JOIN shared.destinations d ON d.id = c.destination_id
        WHERE c.embedding IS NOT NULL <ACTIVE_TOUR_SQL>
        GROUP BY d.id, d.name, d.lat, d.lng
        ORDER BY best_distance ASC, d.id
        LIMIT 60
    """,
    'shared.vector_topk.EXACT_SQL_CIS': """
        SELECT d.destination_id AS id, d.name, d.lat, d.lng, d.located_by, d.precision, d.shape_kind, d.shape_status, d.length_km, d.min_lat, d.min_lng, d.max_lat, d.max_lng, COUNT(c.id) AS component_count,
               MIN(c.embedding <=> $1::vector) AS best_distance
        FROM (SELECT component_id AS id, source_id AS source_tour_id, day_index AS source_day_index, destination_id, activity, intensity_level, season_months, embedding FROM catalog.v_tour_component) c
        JOIN catalog.v_destination d ON d.destination_id = c.destination_id
        WHERE c.embedding IS NOT NULL 
        GROUP BY d.destination_id, d.name, d.lat, d.lng, d.located_by, d.precision, d.shape_kind, d.shape_status, d.length_km, d.min_lat, d.min_lng, d.max_lat, d.max_lng
        ORDER BY best_distance ASC, d.destination_id
        LIMIT 60
    """,
    'shared.vector_topk.TOPK_SQL': """
        WITH scan AS MATERIALIZED (
            SELECT c.id, c.destination_id, c.source_tour_id,
                   c.embedding <=> $1::vector AS distance
            FROM tripplanner.itinerary_components c
            WHERE c.embedding IS NOT NULL
            ORDER BY c.embedding <=> $1::vector
            LIMIT $2
        ), best AS (
            SELECT c.destination_id, MIN(c.distance) AS best_distance
            FROM scan c
            WHERE TRUE <ACTIVE_TOUR_SQL>
            GROUP BY c.destination_id
        )
        SELECT od.id, od.name, od.lat, od.lng, b.best_distance,
               (SELECT COUNT(*) FROM tripplanner.itinerary_components c
                WHERE c.destination_id = od.id AND c.embedding IS NOT NULL <ACTIVE_TOUR_SQL>) AS component_count
        FROM best b
        JOIN shared.destinations od ON od.id = b.destination_id
        ORDER BY b.best_distance ASC, od.id
        LIMIT 60
    """,
    'shared.vector_topk.TOPK_SQL_CIS': """
        WITH scan AS MATERIALIZED (
            SELECT c.id, c.destination_id, c.source_tour_id,
                   c.embedding <=> $1::vector AS distance
            FROM (SELECT component_id AS id, source_id AS source_tour_id, destination_id, activity, intensity_level, season_months, embedding FROM catalog.v_component_embedding) c
            WHERE c.embedding IS NOT NULL
            ORDER BY c.embedding <=> $1::vector
            LIMIT $2
        ), best AS (
            SELECT c.destination_id, MIN(c.distance) AS best_distance
            FROM scan c
            WHERE TRUE 
            GROUP BY c.destination_id
        )
        SELECT od.destination_id AS id, od.name, od.lat, od.lng, od.located_by, od.precision, od.shape_kind, od.shape_status, od.length_km, od.min_lat, od.min_lng, od.max_lat, od.max_lng, b.best_distance,
               (SELECT COUNT(*) FROM (SELECT component_id AS id, source_id AS source_tour_id, day_index AS source_day_index, destination_id, activity, intensity_level, season_months, embedding FROM catalog.v_tour_component) c
                WHERE c.destination_id = od.destination_id AND c.embedding IS NOT NULL ) AS component_count
        FROM best b
        JOIN catalog.v_destination od ON od.destination_id = b.destination_id
        ORDER BY b.best_distance ASC, od.destination_id
        LIMIT 60
    """,
}
# END GENERATED READERS


# ── helpers ─────────────────────────────────────────────────────────────────────────────────────────────────────────

class Budget:
    def __init__(self, seconds):
        self.start = time.monotonic()
        self.seconds = seconds

    def elapsed(self):
        return time.monotonic() - self.start

    def over(self, section, reserve=0.0):
        if self.elapsed() + reserve > self.seconds:
            out("truncated", section=section, elapsed_s=round(self.elapsed(), 1))
            return True
        return False


def _fmt(v):
    if isinstance(v, bool):
        return "t" if v else "f"
    if isinstance(v, float):
        return f"{v:.1f}"
    if v is None:
        return "-"
    s = str(v).replace("\n", " ")
    return f'"{s}"' if (" " in s or s == "") else s


def out(line_kind, **fields):
    print("SCRIPT " + line_kind + "".join(f" {k}={_fmt(v)}" for k, v in fields.items()), flush=True)


def reader(key):
    """SQL of a generated reader; the legacy top-k gets its keep_where (ACTIVE_TOUR_SQL) put back in."""
    sql = READERS[key]
    if "<ACTIVE_TOUR_SQL>" in sql:
        sql = sql.replace("<ACTIVE_TOUR_SQL>", READERS["browse.search.ACTIVE_TOUR_SQL"])
    return sql


async def timed(conn, sql, *args):
    """(ms, rows, error) of one call inside a savepoint, so a failing reader does not end the pass."""
    t0 = time.monotonic()
    try:
        async with conn.transaction():
            rows = await conn.fetch(sql, *args)
        return (time.monotonic() - t0) * 1000.0, rows, None
    except Exception as e:  # noqa: BLE001 — reported, the pass goes on
        return (time.monotonic() - t0) * 1000.0, [], type(e).__name__


async def guarded(conn, section, coro):
    """Runs one section in a savepoint: an error ends that section only (`SCRIPT section_error`)."""
    try:
        async with conn.transaction():
            await coro
    except Exception as e:  # noqa: BLE001
        out("section_error", section=section, error=type(e).__name__, detail=str(e)[:160])


class Series:
    """Calls of one (reader, country, source)."""

    def __init__(self):
        self.ms = []
        self.rows = 0
        self.errors = 0
        self.slowest = None  # (ms, sql, args)

    def add(self, ms, rows, err, sql, args):
        self.ms.append(ms)
        self.rows += len(rows)
        self.errors += err is not None
        if err is not None:
            out("reader_error", error=err)
        if self.slowest is None or ms > self.slowest[0]:
            self.slowest = (ms, sql, args)

    def total(self):
        return sum(self.ms)

    def per_call(self):
        return self.total() / len(self.ms) if self.ms else 0.0


def _walk(plan, parent_total=None):
    yield plan
    for child in plan.get("Plans", []) or []:
        yield from _walk(child)


def _own_ms(node):
    loops = node.get("Actual Loops", 1) or 1
    total = (node.get("Actual Total Time", 0.0) or 0.0) * loops
    kids = sum((c.get("Actual Total Time", 0.0) or 0.0) * (c.get("Actual Loops", 1) or 1)
               for c in node.get("Plans", []) or [])
    return max(total - kids, 0.0)


def _where(node):
    return f"{node.get('Node Type')}:{node.get('Relation Name') or node.get('Alias') or node.get('CTE Name') or '-'}"


QUAL_KEYS = ("Filter", "Index Cond", "Join Filter", "Hash Cond", "Recheck Cond", "Merge Cond", "Order By")


class _Undo(Exception):
    """Carries an EXPLAIN result out of a savepoint that must be rolled back (so its settings end with it)."""

    def __init__(self, value):
        super().__init__("undo")
        self.value = value


async def set_local(conn, name, value):
    """A transaction-local setting, set_config(name, value, true). Like SET LOCAL it survives a RELEASE SAVEPOINT, so
    a caller that must not leak it to later readers restores the value itself or rolls its savepoint back."""
    await conn.execute("SELECT set_config($1, $2, true)", name, value)


@contextlib.asynccontextmanager
async def scoped_settings(conn, settings):
    """`settings` [(name, value)] for the block only: set in a savepoint that is ROLLED BACK when the block ends, so
    they stop there (a RELEASE would keep them, as SET LOCAL does). For read-only work: the block's reads are kept in
    Python, nothing in the savepoint needs to survive."""
    try:
        async with conn.transaction():
            for name, value in settings:
                await set_local(conn, name, value)
            yield
            raise _Undo(None)
    except _Undo:
        pass


async def explain_doc(conn, sql, args, settings=()):
    """EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) of `sql` with `settings` [(name, value)] in a savepoint that is ROLLED
    BACK, never released: the settings (enable_sort, plan_cache_mode, ...) stop with it."""
    try:
        async with conn.transaction():
            for name, value in settings:
                await set_local(conn, name, value)
            raw = await conn.fetchval("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " + sql, *args)
            raise _Undo(raw)
    except _Undo as u:
        raw = u.value
    return json.loads(raw) if isinstance(raw, str) else raw


def raw_tours_seq_loops(nodes):
    """Loops of the busiest Seq Scan on raw_tours: > 1 is a liveness probe re-scanning the table per outer row."""
    return max((n.get("Actual Loops") or 0 for n in nodes
                if n.get("Node Type") == "Seq Scan" and n.get("Relation Name") == "raw_tours"), default=0)


def report_plan(label, doc, markers):
    root = doc[0]["Plan"]
    nodes = list(_walk(root))
    for n in sorted(nodes, key=_own_ms, reverse=True)[:6]:
        out("plan", **label, node=_where(n), own_ms=round(_own_ms(n), 1), rows=n.get("Actual Rows"),
            loops=n.get("Actual Loops"), shared_hit=n.get("Shared Hit Blocks"), shared_read=n.get("Shared Read Blocks"))
    for m in markers:
        hits = [n for n in nodes if any(m in str(n.get(k, "")) for k in QUAL_KEYS)]
        if not hits:
            out("qual", **label, marker=m, at="-", pushed="-")
        for n in hits[:3]:
            pushed = n.get("Node Type") not in ("Subquery Scan", "CTE Scan", "Result")
            out("qual", **label, marker=m, at=_where(n), pushed=pushed)
    loops = raw_tours_seq_loops(nodes)
    if loops > 1:
        out("plan_flag", **label, flag="seq_scan_raw_tours", loops=loops)
    out("plan_total", **label, exec_ms=round(doc[0].get("Execution Time", 0.0), 1),
        planning_ms=round(doc[0].get("Planning Time", 0.0), 1), jit="JIT" in doc[0])


async def explain(conn, label, sql, args, markers, settings=()):
    """Reports the plan of one call; returns the EXPLAIN document, or None when it failed (`SCRIPT plan_error`)."""
    try:
        doc = await explain_doc(conn, sql, args, settings)
    except Exception as e:  # noqa: BLE001
        out("plan_error", **label, error=type(e).__name__)
        return None
    report_plan(label, doc, markers)
    return doc


def _has_rel(node, rel):
    return any(n.get("Relation Name") == rel for n in _walk(node))


def _where_ix(node):
    ix = node.get("Index Name")
    return _where(node) + (f"[{ix}]" if ix else "")


def topk_plan_facts(doc):
    """What the step-18 structural check reads in a TOPK_SQL_CIS plan. The liveness probe is looked for inside the
    `scan` CTE (the per-destination component_count subquery joins _live_tour too): the first child of a node that
    reaches raw_tours but not tour_place while the node's other side (or the node itself) reads tour_place."""
    root = doc[0]["Plan"]
    nodes = list(_walk(root))
    hnsw = [n for n in nodes if n.get("Index Name") == HNSW_INDEX]
    scope = next((n for n in nodes if n.get("Subplan Name") == "CTE scan"), root)
    live = None
    for n in _walk(scope):
        kids = n.get("Plans") or []
        for c in kids:
            if not _has_rel(c, "raw_tours") or _has_rel(c, "tour_place"):
                continue
            if n.get("Relation Name") == "tour_place" or any(_has_rel(o, "tour_place") for o in kids if o is not c):
                live = c
                break
        if live is not None:
            break
    path = []
    n = live
    while n is not None:
        path.append(n)
        if n.get("Relation Name") == "raw_tours":
            break
        n = next((c for c in n.get("Plans") or [] if _has_rel(c, "raw_tours")), None)
    rt = path[-1] if path and path[-1].get("Relation Name") == "raw_tours" else None
    return {
        "uses_hnsw": bool(hnsw),
        "hnsw_order_by": any("<=>" in str(n.get("Order By", "")) for n in hnsw),
        "live_probe": "/".join(_where_ix(x) for x in path) or "-",
        "live_index": rt.get("Index Name") if rt is not None else None,
        "join_filter_source_id": any("source_id" in str(x.get("Join Filter", "")) for x in _walk(scope)),
        "raw_tours_seq_loops": raw_tours_seq_loops(nodes),
        "nodes": ">".join(x.get("Node Type", "?") for x in nodes[:6]),
    }


def complete_runs(runs):
    """(the runs with every call, how many were cut short). A run the time budget stopped mid-section has fewer calls
    of a reader than a full run; its sum is low, so it stays out of the median (it would pull a FAIL to a PASS)."""
    if not runs:
        return [], 0
    n = max(len(s.ms) for s in runs)
    full = [s for s in runs if len(s.ms) == n]
    return full, len(runs) - len(full)


def median(values):
    v = sorted(values)
    if not v:
        return 0.0
    m = len(v) // 2
    return v[m] if len(v) % 2 else (v[m - 1] + v[m]) / 2.0


def parity_verdict(legacy_runs, cis_runs, cis_errors=0):
    """(legacy, cis, target, ok) on the median of the runs; target = max(1.5 x legacy, 200 ms)."""
    lv, cv = median(legacy_runs), median(cis_runs)
    target = max(1.5 * lv, 200.0)
    return lv, cv, target, cv <= target and cis_errors == 0


def ef_search_for(k):
    """TripPlanner vector_topk.ef_search_for: 2 x k, at least 40, at most pgvector's 1000."""
    return min(1000, max(k * 2, 40))


async def pgvector_iterative(conn):
    """pgvector >= 0.8 (hnsw.iterative_scan), as TripPlanner vector_topk.iterative_scan_supported."""
    try:
        v = await conn.fetchval("SELECT extversion FROM pg_extension WHERE extname = 'vector'")
        return tuple(int(x) for x in re.findall(r"\d+", v or "0")[:2]) >= (0, 8)
    except Exception:  # noqa: BLE001
        return False


def _norm(text):
    text = unicodedata.normalize("NFKD", text or "")
    text = "".join(ch for ch in text if not unicodedata.combining(ch)).lower()
    return re.sub(r"[^a-z0-9]+", " ", text).strip()


GENERIC = {"the", "of", "and", "in", "at", "to", "a", "national", "park", "river", "temple", "village", "city",
           "old", "town", "market", "mount", "mountain", "lake", "waterfall", "falls", "cave", "caves", "island",
           "trail", "road", "province", "district", "area", "centre", "center"}


def names_place(day_text, name):
    """AA-819 check: the day text names the component (whole name, or every distinctive word of it)."""
    t, n = _norm(day_text), _norm(name)
    if not n:
        return True
    if n in t:
        return True
    words = [w for w in n.split() if len(w) >= 3 and w not in GENERIC]
    tw = set(t.split())
    return bool(words) and all(w in tw for w in words)


DAY_RE = re.compile(r"(?:^|\n)Day\s+(\d+)\s+—[ \t]*([^\n]*)")
HEADING_RE = re.compile(r"(?:^|\n)\s*Day\s+(\d+)(?:\s*[-–]\s*(\d+))?\s*(?:—|:|-|–)", re.I)


def day_texts(itinerary):
    """day -> text of the canonical blocks 'Day N — …' (the catalog / itinerary_utils rule: a repeated day keeps the
    LAST block; a 'Day 5-6 —' heading is not a canonical block, its text folds into the previous day)."""
    out_days = {}
    if not itinerary:
        return out_days
    parts = re.split(r"\n(?=Day\s+\d+\s+—)", itinerary)
    for part in parts:
        m = re.match(r"\s*Day\s+(\d+)\s+—", part)
        if m:
            out_days[int(m.group(1))] = part
    return out_days


def heading_days(itinerary):
    """(canonical day numbers, ranged headings, days covered by every heading incl. ranges — days.py style)."""
    canonical, ranged, covered = set(), [], set()
    for m in HEADING_RE.finditer(itinerary or ""):
        a = int(m.group(1))
        b = int(m.group(2)) if m.group(2) else a
        if m.group(2):
            ranged.append(f"{a}-{b}")
        else:
            canonical.add(a)
        if 0 < a <= b <= a + 30:
            covered.update(range(a, b + 1))
    return canonical, ranged, covered


def km(a_lat, a_lng, b_lat, b_lng):
    p1, p2 = math.radians(a_lat), math.radians(b_lat)
    dp, dl = p2 - p1, math.radians(b_lng - a_lng)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * 6371.0 * math.asin(min(1.0, math.sqrt(h)))


# ── pass 1: as tripplanner ──────────────────────────────────────────────────────────────────────────────────────────

LIVE_TOURS_SQL = "SELECT source_id, tour_id::text AS tour_id, title, country FROM catalog.v_tour"
CIS_COMPONENT_SOURCES_SQL = "SELECT DISTINCT source_id FROM catalog.v_tour_component"
CIS_GRAPH_SOURCES_SQL = "SELECT DISTINCT source_id FROM catalog.v_tour_stop"
FROZEN_KEYS_SQL = """
    SELECT DISTINCT source_tour_id AS key FROM tripplanner.itinerary_components
    UNION SELECT DISTINCT source_tour_id FROM tripplanner.tour_stop
"""
COUNTRY_DESTS_SQL = """
    SELECT DISTINCT d.id::text AS id, d.lat, d.lng
      FROM shared.destinations d
     WHERE d.country = $1
       AND (EXISTS (SELECT 1 FROM tripplanner.itinerary_components c WHERE c.destination_id = d.id)
            OR EXISTS (SELECT 1 FROM catalog.v_tour_component c WHERE c.destination_id = d.id))
     ORDER BY 1
"""
QUERY_VECTORS_SQL = """
    SELECT c.embedding::text AS v FROM tripplanner.itinerary_components c
      JOIN shared.destinations d ON d.id = c.destination_id
     WHERE c.embedding IS NOT NULL AND d.country = $1
     ORDER BY c.id LIMIT $2
"""
SAMPLE_TOURS_SQL = """
    SELECT tour_id::text AS tour_id, source_id FROM catalog.v_tour WHERE country = $1 ORDER BY tour_id LIMIT $2
"""
VIEWS_SQL = """
    SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'catalog' AND c.relkind IN ('v', 'm')
       AND has_table_privilege(current_user, c.oid, 'SELECT')
     ORDER BY 1
"""
DEFECT_TOURS_SQL = """
    SELECT tour_id::text AS tour_id, source_id, title, country, duration_raw, duration_days, itinerary_text
      FROM catalog.v_tour
     WHERE title ILIKE '%Ho Chi Minh Trail%'
        OR (country = 'Laos' AND (itinerary_text ILIKE '%Kuang Si%' OR itinerary_text ILIKE '%Kuang Xi%'
                                  OR itinerary_text ILIKE '%Kuangsi%'))
     ORDER BY title LIMIT $1
"""
DEFECT_COMPONENTS_SQL = """
    SELECT c.day_index, c.name, c.destination_id::text AS destination_id, d.name AS destination_name,
           d.geo_precision, d.located_by, d.review_reason, d.geocoder_meta ->> 'result_type' AS result_type,
           d.lat, d.lng
      FROM catalog.v_tour_component c JOIN shared.destinations d ON d.id = c.destination_id
     WHERE c.source_id = $1
     ORDER BY c.day_index, c.name
"""
FROZEN_DAY_COUNTS_SQL = """
    SELECT source_day_index AS day, count(*) AS n FROM tripplanner.itinerary_components
     WHERE source_tour_id = ANY($1::text[]) GROUP BY 1 ORDER BY 1
"""
KUANG_SI_SQL = """
    SELECT id::text AS id, name, country, lat, lng, located_by, geo_precision, geo_status, duplicate_of::text AS dup
      FROM shared.destinations
     WHERE name ILIKE '%kuang%si%' OR name ILIKE '%kuangsi%' OR name ILIKE '%kuang%xi%' OR name ILIKE '%tat kuang%'
     ORDER BY name
"""
FROZEN_COMPONENTS_SQL = """
    SELECT c.name, c.source_tour_id, c.source_day_index FROM tripplanner.itinerary_components c
"""
CIS_COMPONENTS_TEXT_SQL = "SELECT name, source_id, day_index FROM catalog.v_tour_component"
TOUR_TEXTS_SQL = """
    SELECT source_id, tour_id::text AS tour_id, country, itinerary_text FROM catalog.v_tour
"""
# Assembly inputs (TripPlanner 6c twins): component ids at a few destinations of the country, per source.
ASM_IDS_SQL = """
    SELECT id::text AS id FROM tripplanner.itinerary_components
     WHERE destination_id = ANY($1::uuid[]) ORDER BY id LIMIT $2
"""
ASM_IDS_SQL_CIS = """
    SELECT component_id::text AS id FROM catalog.v_tour_component
     WHERE destination_id = ANY($1::uuid[]) ORDER BY component_id LIMIT $2
"""
ASM_DESTS = 8           # destinations per country for the assembly readers
ASM_IDS = 8             # pinned components per call (a typical trip)
ASM_JUNCTION_KM = 150.0  # TripPlanner suggestions.JUNCTION_KM
ASM_CANDIDATES = 24      # suggestions SUGGEST_LIMIT * CANDIDATE_MULTIPLIER
# (series name, legacy reader key, cis reader key): timed only when the generated block has both (6c)
ASSEMBLY_READERS = (
    ("assembly_components", "assembly.events.COMPONENTS_SQL", "assembly.events.COMPONENTS_SQL_CIS"),
    ("assembly_taste", "assembly.suggestions.TASTE_SQL", "assembly.suggestions.TASTE_SQL_CIS"),
    ("assembly_options", "assembly.coverage.OPTIONS_SQL", "assembly.coverage.OPTIONS_SQL_CIS"),
    ("assembly_activities", "assembly.activities.ACTIVITIES_SQL", "assembly.activities.ACTIVITIES_SQL_CIS"),
    ("assembly_route_candidates", "assembly.suggestions.ROUTE_CANDIDATES_SQL",
     "assembly.suggestions.ROUTE_CANDIDATES_SQL_CIS"),
)


async def tripplanner_pass(conn, budget, st):
    # ── 1. coverage inputs ──
    live = {r["source_id"]: dict(r) for r in await conn.fetch(LIVE_TOURS_SQL)}
    st["live"] = live
    st["live_tour_ids"] = {r["tour_id"]: s for s, r in live.items()}
    st["cis_components"] = {r["source_id"] for r in await conn.fetch(CIS_COMPONENT_SOURCES_SQL)}
    st["cis_graph"] = {r["source_id"] for r in await conn.fetch(CIS_GRAPH_SOURCES_SQL)}
    st["frozen_keys"] = sorted({r["key"] for r in await conn.fetch(FROZEN_KEYS_SQL)})
    out("inputs", live_tours=len(live), cis_component_sources=len(st["cis_components"]),
        cis_graph_sources=len(st["cis_graph"]), frozen_keys=len(st["frozen_keys"]))

    # ── 2. reader timings ──
    if not READERS:
        out("truncated", section="timings", reason="READERS block not generated")
    else:
        await guarded(conn, "timings", timings(conn, budget, st))

    # ── 2b. env_topk (step 18 structural check) and 2c. the generic-plan proof ──
    if not budget.over("env_topk", reserve=120):
        await guarded(conn, "env_topk", env_topk(conn, st))
    if not budget.over("generic_plan", reserve=120):
        await guarded(conn, "generic_plan", generic_plan_check(conn, st))

    # ── 3. fingerprints ──
    for r in await conn.fetch(VIEWS_SQL):
        if budget.over("fingerprints", reserve=120):
            break
        v = r["relname"]
        ms, rows, err = await timed(
            conn, f"SELECT count(*) AS n, md5(coalesce(string_agg(x::text, '|' ORDER BY x::text), '')) AS h "
                  f"FROM catalog.{v} x")
        if err:
            out("fingerprint", view=v, error=err)
        else:
            out("fingerprint", view=v, rows=rows[0]["n"], md5=rows[0]["h"], ms=round(ms, 1))

    # ── 4. defects ──
    if not budget.over("defects", reserve=60):
        await guarded(conn, "defects", defects(conn, st))

    # (5. the AA-819 day text check runs in pass 3: it needs pass 2's old tour_id -> source_id map)


async def assembly(conn, country, dests, vectors, run, quiet=False):
    """TripPlanner 6c assembly readers on both sources, with the consumer's argument shapes (uuid[] of pinned
    component ids, one destination id, the destination ids of a trip, the route-candidate parameters)."""
    picked = [d for d in dests[:ASM_DESTS]]
    dest_ids = [d["id"] for d in picked]
    if not dest_ids:
        return
    ids = {"legacy": [r["id"] for r in await conn.fetch(ASM_IDS_SQL, dest_ids, ASM_IDS)],
           "cis": [r["id"] for r in await conn.fetch(ASM_IDS_SQL_CIS, dest_ids, ASM_IDS)]}
    vec = vectors[0] if vectors else None
    for name, legacy_key, cis_key in ASSEMBLY_READERS:
        for source, key in (("legacy", legacy_key), ("cis", cis_key)):
            if name in ("assembly_components", "assembly_taste"):
                await run(name, country, source, key, ids[source])
            elif name == "assembly_options":
                await run(name, country, source, key, dest_ids)
            elif name == "assembly_activities":
                for d in dest_ids:
                    await run(name, country, source, key, d)
            elif vec is not None:
                d = picked[-1]
                await run(name, country, source, key, vec, d["lat"], d["lng"], ASM_JUNCTION_KM, [d["id"]],
                          ASM_CANDIDATES, None, None)
    if "shared.component_ids.MAP_SQL" in READERS and ids["legacy"]:
        await run("assembly_id_map", country, "cis", "shared.component_ids.MAP_SQL", ids["legacy"])
    if not quiet:
        out("assembly_input", country=country, destinations=len(dest_ids), legacy_ids=len(ids["legacy"]),
            cis_ids=len(ids["cis"]))


# Parity readers (S237 aggregation); tiles / detail are summed per country, the rest per call.
PARITY_READERS = ("countries", "by_country", "tiles", "detail", "search", "routes", "tour_route")
TOTAL_AGG = ("tiles", "detail")
# composite series (their parts are EXPLAINed under their own names) and the unscored diagnostic
NO_EXPLAIN = ("routes", "tour_route", "routes_single_auto")
CALL_LISTS = ("routes_single", "routes_single_auto")
# The cis reads TripPlanner proposals() runs under SET LOCAL plan_cache_mode = force_custom_plan (routes fix).
FORCED_CUSTOM = ("routes_single", "routes_chain")
# A distinct statement text, so asyncpg prepares the diagnostic apart from the forced routes_single statement.
AUTO_TAG = "\n-- aa847 probe: routes_single_auto, plan_cache_mode left at the session value\n"
MARKERS = {"countries": ["country"], "by_country": ["country ="],
           "tiles": ["lat >=", "lng >=", "max_lat", "max_lng"],
           "detail": ["destination_id ="], "search": ["<=>"],
           "routes": ["countries", "source_id = ANY", "source_tour_id = ANY"],
           "tour_route": ["source_id =", "tour_id ="], "assembly_components": ["= ANY"],
           "assembly_taste": ["= ANY"], "assembly_options": ["= ANY"], "assembly_activities": ["destination_id ="],
           "assembly_route_candidates": ["<=>"], "assembly_id_map": ["= ANY"]}


def _agg(name):
    return (lambda s: s.total()) if name in TOTAL_AGG else (lambda s: s.per_call())


def _markers(name):
    return next((v for k, v in MARKERS.items() if name.startswith(k)), [])


async def timings(conn, budget, st):
    results = {}  # (reader, country) -> {source: {run: Series}}
    rep = 1

    def series(name, country, source):
        return results.setdefault((name, country), {}).setdefault(source, {}).setdefault(rep, Series())

    async def run(name, country, source, key, *args, sql=None):
        sql = sql if sql is not None else reader(key)
        ms, rows, err = await timed(conn, sql, *args)
        series(name, country, source).add(ms, rows, err, sql, args)
        return rows

    st["iterative"] = iterative = await pgvector_iterative(conn)
    st["search_settings"] = [("hnsw.ef_search", str(ef_search_for(TOPK_K)))] + (
        [("hnsw.iterative_scan", "relaxed_order")] if iterative else [])
    st["plan_cache_mode"] = await conn.fetchval("SELECT current_setting('plan_cache_mode')") or "auto"

    async def one_run():
        first = rep == 1
        await run("countries", "*", "legacy", "browse.countries.COUNTRIES_SQL")
        await run("countries", "*", "cis", "browse.countries.COUNTRIES_SQL_CIS")
        for country in COUNTRIES:
            if budget.over(f"timings {country}", reserve=300):
                break
            await run("by_country", country, "legacy", "browse.countries.COUNTRY_DESTINATIONS_SQL", country)
            await run("by_country", country, "cis", "browse.countries.COUNTRY_DESTINATIONS_SQL_CIS", country)

            dests = [dict(r) for r in await conn.fetch(COUNTRY_DESTS_SQL, country)]
            cells = sorted({(math.floor(d["lat"]), math.floor(d["lng"])) for d in dests})[:TILE_CAP]
            for lat, lng in cells:
                await run("tiles", country, "legacy", "browse.tiles.TILE_SQL", lat, lat + 1, lng, lng + 1)
                await run("tiles", country, "cis", "browse.tiles.TILE_SQL_CIS", lat, lat + 1, lng, lng + 1)
            if dests:
                lat10 = math.floor(sum(d["lat"] for d in dests) / len(dests) / 10) * 10
                lng10 = math.floor(sum(d["lng"] for d in dests) / len(dests) / 10) * 10
                await run("tiles", country, "legacy", "browse.tiles.TILE_SQL", lat10, lat10 + 10, lng10, lng10 + 10)
                await run("tiles", country, "cis", "browse.tiles.TILE_SQL_CIS", lat10, lat10 + 10, lng10, lng10 + 10)
            if first:
                out("tiles_input", country=country, one_degree=len(cells), ten_degree=1 if dests else 0)

            for d in dests[:DETAIL_CAP]:
                if budget.over(f"detail {country}", reserve=240):
                    break
                await run("detail", country, "legacy", "browse.destinations.DEST_SQL", d["id"])
                await run("detail", country, "legacy", "browse.destinations.COMPONENTS_SQL", d["id"])
                await run("detail", country, "cis", "browse.destinations.DEST_SQL_CIS", d["id"])
                await run("detail", country, "cis", "browse.destinations.COMPONENTS_SQL_CIS", d["id"])
            if first:
                out("detail_input", country=country, destinations=min(len(dests), DETAIL_CAP), of=len(dests))

            vectors = [r["v"] for r in await conn.fetch(QUERY_VECTORS_SQL, country, SEARCH_QUERIES)]
            # TripPlanner vector_topk sets these in the search's own transaction; here they end with this block, so
            # the readers after it (routes, assembly incl. assembly_route_candidates) run at the session values, as
            # they do in TripPlanner.
            async with scoped_settings(conn, st["search_settings"]):
                for vec in vectors:
                    if budget.over(f"search {country}", reserve=200):
                        break
                    await run("search", country, "legacy", "shared.vector_topk.TOPK_SQL", vec, TOPK_K)
                    await run("search_exact", country, "legacy", "shared.vector_topk.EXACT_SQL", vec)
                    if "shared.vector_topk.TOPK_SQL_CIS" in READERS:
                        # TripPlanner 6c: the cis search is the same top-k, over catalog.v_component_embedding (253)
                        await run("search", country, "cis", "shared.vector_topk.TOPK_SQL_CIS", vec, TOPK_K)
                        await run("search_exact", country, "cis", "shared.vector_topk.EXACT_SQL_CIS", vec)
                    else:
                        await run("search", country, "cis", "browse.search.CIS_SEARCH_SQL", vec)
            if first:
                out("search_input", country=country, queries=len(vectors))

            for days in ROUTE_DAYS:
                if budget.over(f"routes {country}", reserve=180):
                    break
                for source, suffix in (("legacy", ""), ("cis", "_CIS")):
                    t0 = time.monotonic()
                    forced = source == "cis"
                    if forced:
                        # TripPlanner proposals(): the cis single + chain reads plan per call. set_config, then the
                        # session value back right after: a SET LOCAL here would outlive the released savepoints.
                        await set_local(conn, "plan_cache_mode", "force_custom_plan")
                    try:
                        singles = await run("routes_single", country, source, f"browse.routes.SINGLE_SQL{suffix}",
                                            country, days, ROUTE_SLACK)
                        chains = await run("routes_chain", country, source, f"browse.routes.CHAIN_SQL{suffix}",
                                           country, days, ROUTE_SLACK)
                    finally:
                        if forced:
                            await set_local(conn, "plan_cache_mode", st["plan_cache_mode"])
                    tours = sorted({r["tour_id"] for r in singles} | {r["a_tour"] for r in chains}
                                   | {r["b_tour"] for r in chains})[:ROUTE_TOURS_CAP]
                    if tours:
                        await run("routes_days", country, source, f"browse.routes.DAYS_SQL{suffix}", tours)
                        await run("routes_components", country, source, f"browse.routes.COMPONENTS_SQL{suffix}",
                                  tours)
                    series("routes", country, source).add((time.monotonic() - t0) * 1000.0, singles, None,
                                                          reader(f"browse.routes.CHAIN_SQL{suffix}"),
                                                          (country, days, ROUTE_SLACK))
            if first and "browse.routes.SINGLE_SQL_CIS" in READERS:
                # Diagnostic, not scored: the cis single read at the session plan_cache_mode, its own prepared
                # statement. From the 6th execution PG may keep a generic plan: a jump there is the S246 diagnosis.
                auto_sql = reader("browse.routes.SINGLE_SQL_CIS") + AUTO_TAG
                for days in ROUTE_DAYS:
                    if budget.over(f"routes_single_auto {country}", reserve=180):
                        break
                    await run("routes_single_auto", country, "cis", None, country, days, ROUTE_SLACK, sql=auto_sql)

            sample = [dict(r) for r in await conn.fetch(SAMPLE_TOURS_SQL, country, TOUR_SAMPLE // len(COUNTRIES))]
            for t in sample:
                if budget.over(f"tour_route {country}", reserve=150):
                    break
                for source in ("legacy", "cis"):
                    t0 = time.monotonic()
                    if source == "cis":
                        keys = [t["source_id"]]
                        stops = await run("tour_route_days", country, source, "browse.routes.DAYS_SQL_CIS", keys)
                        if stops:
                            await run("tour_route_components", country, source, "browse.routes.COMPONENTS_SQL_CIS",
                                      keys)
                        place_key = "browse.routes.PLACE_COMPONENTS_SQL_CIS"
                    else:
                        keys = [t["tour_id"]]
                        stops = await run("tour_route_days", country, source, "browse.routes.DAYS_SQL", keys)
                        if stops:
                            await run("tour_route_components", country, source, "browse.routes.COMPONENTS_SQL", keys)
                        place_key = "browse.routes.PLACE_COMPONENTS_SQL"
                    if not stops:
                        places = await run("tour_route_places", country, source,
                                           "browse.routes.TOUR_ROUTE_PLACES_SQL", t["tour_id"])
                        ids = sorted({p["destination_id"] for p in places})
                        if ids:
                            await run("tour_route_place_components", country, source, place_key, ids, keys)
                            await run("tour_route_days_count", country, source, "browse.routes.TOUR_DAYS_COUNT_SQL",
                                      t["tour_id"])
                    series("tour_route", country, source).add((time.monotonic() - t0) * 1000.0, [], None,
                                                              reader("browse.routes.TOUR_ROUTE_PLACES_SQL"),
                                                              (t["tour_id"],))
            if first:
                out("tour_route_input", country=country, tours=len(sample))

            if all(k in READERS for _, lk, ck in ASSEMBLY_READERS for k in (lk, ck)) \
                    and not budget.over(f"assembly {country}", reserve=120):
                await assembly(conn, country, dests, vectors, run, quiet=not first)

    first_run_s = 0.0
    for rep in range(1, REPEATS + 1):
        if rep > 1 and budget.over(f"repeat {rep}", reserve=first_run_s * 1.5 + 300):
            break
        t_run = time.monotonic()
        await one_run()
        if rep == 1:
            first_run_s = time.monotonic() - t_run
        out("repeat", run=rep, of=REPEATS, elapsed_s=round(time.monotonic() - t_run, 1))

    # report (medians over the runs) + EXPLAIN the slowest call of each (reader, country, source) over all runs
    for (name, country), by_source in sorted(results.items()):
        agg = _agg(name)
        for source, reps in sorted(by_source.items()):
            runs = [reps[r] for r in sorted(reps)]
            full, cut = complete_runs(runs)
            all_ms = [m for s in runs for m in s.ms]
            out("timing", reader=name, country=country, source=source, calls=len(runs[0].ms), rows=runs[0].rows,
                total_ms=round(median([s.total() for s in full]), 1),
                per_call_ms=round(median([s.per_call() for s in full]), 1),
                max_ms=round(max(all_ms) if all_ms else 0.0, 1), errors=sum(s.errors for s in runs),
                repeats=len(full), partial=cut, runs="/".join(f"{agg(s):.1f}" for s in runs))
            if name in CALL_LISTS:
                for r in sorted(reps):
                    out("calls", reader=name, country=country, source=source, repeat=r,
                        ms=",".join(f"{m:.1f}" for m in reps[r].ms))
        if name in NO_EXPLAIN:
            continue
        for source, reps in sorted(by_source.items()):
            slowest = max((s.slowest for s in reps.values() if s.slowest), key=lambda x: x[0], default=None)
            if name == "search" and source == "cis" and slowest and "topk_vector" not in st:
                st["topk_vector"] = slowest[2][0]          # env_topk EXPLAINs the slowest cis search's vector
            if slowest and not budget.over("explain", reserve=90):
                await explain(conn, {"reader": name, "country": country, "source": source}, slowest[1],
                              slowest[2], _markers(name),
                              settings=st["search_settings"] if name in ("search", "search_exact") else ())
    passes = fails = 0
    n_runs = 0
    for (name, country), by_source in sorted(results.items()):
        if name not in PARITY_READERS and not name.startswith("assembly_"):
            continue
        leg, leg_cut = complete_runs([s for _, s in sorted(by_source.get("legacy", {}).items()) if s.ms])
        cis, cis_cut = complete_runs([s for _, s in sorted(by_source.get("cis", {}).items()) if s.ms])
        if not leg or not cis:
            continue
        agg = _agg(name)
        lv, cv, target, ok = parity_verdict([agg(s) for s in leg], [agg(s) for s in cis],
                                            sum(s.errors for s in cis))
        passes += ok
        fails += not ok
        n_runs = max(n_runs, len(cis))
        out("parity", reader=name, country=country, legacy=round(lv, 1), cis=round(cv, 1), target=round(target, 1),
            verdict="PASS" if ok else "FAIL", runs=len(cis), partial=leg_cut + cis_cut,
            cis_runs="/".join(f"{agg(s):.1f}" for s in cis), legacy_runs="/".join(f"{agg(s):.1f}" for s in leg))
    out("parity_total", passes=passes, fails=fails, runs=n_runs)


async def env_topk(conn, st):
    """Step 18 (revised): the generated cis top-k as TripPlanner sends it (as tripplanner, its ef_search and
    iterative_scan, the vector bound as $1), natural and with enable_sort=off. At Dev size the natural plan is an exact
    top-N sort (correct and cheaper); the forced plan shows whether the HNSW index CAN serve the order through the
    view and what the liveness EXISTS costs per index row."""
    key = "shared.vector_topk.TOPK_SQL_CIS"
    if key not in READERS:
        out("env_topk", skipped="no_generated_TOPK_SQL_CIS")
        return
    vec = st.get("topk_vector")
    if vec is None:
        rows = await conn.fetch(QUERY_VECTORS_SQL, COUNTRIES[0], 1)
        vec = rows[0]["v"] if rows else None
    if vec is None:
        out("env_topk", skipped="no_query_vector")
        return
    base = [("hnsw.ef_search", str(ef_search_for(TOPK_K)))]
    if st.get("iterative"):
        base.append(("hnsw.iterative_scan", "relaxed_order"))
    facts = {}
    for mode, extra in (("natural", []), ("forced", [("enable_sort", "off")])):
        doc = await explain(conn, {"reader": "env_topk", "mode": mode}, reader(key), (vec, TOPK_K), ["<=>"],
                            settings=base + extra)
        if doc is None:
            continue
        f = facts[mode] = topk_plan_facts(doc)
        out("env_topk", mode=mode, exec_ms=round(doc[0].get("Execution Time", 0.0), 1), uses_hnsw=f["uses_hnsw"],
            hnsw_order_by=f["hnsw_order_by"], live_probe=f["live_probe"], live_index=f["live_index"],
            join_filter_source_id=f["join_filter_source_id"], raw_tours_seq_loops=f["raw_tours_seq_loops"],
            nodes=f["nodes"])
    nat, frc = facts.get("natural"), facts.get("forced")
    pre258 = bool(frc and frc["uses_hnsw"] and frc["hnsw_order_by"])
    full = bool(pre258 and nat and nat["raw_tours_seq_loops"] <= 1 and frc["live_index"] == LIVE_KEY_INDEX
                and not frc["join_filter_source_id"])
    out("env_topk_summary", role=await conn.fetchval("SELECT current_user"), k=TOPK_K,
        ef_search=ef_search_for(TOPK_K), iterative_scan="relaxed_order" if st.get("iterative") else None,
        uses_hnsw_natural=nat["uses_hnsw"] if nat else None, uses_hnsw_forced=frc["uses_hnsw"] if frc else None,
        live_probe=frc["live_probe"] if frc else None, live_index=frc["live_index"] if frc else None,
        join_filter_source_id=frc["join_filter_source_id"] if frc else None,
        raw_tours_seq_loops_gt1=(nat["raw_tours_seq_loops"] > 1) if nat else None,
        verdict_full="PASS" if full else "FAIL", verdict_pre258="PASS" if pre258 else "FAIL")


async def generic_plan_check(conn, st):
    """The S246 routes_single diagnosis: the cis single read's generic plan vs its custom plan, through a named
    PREPARE (SQL level, so the plan_cache_mode setting decides), days 21, slack 3, per country."""
    key = "browse.routes.SINGLE_SQL_CIS"
    if key not in READERS:
        return
    days = max(ROUTE_DAYS)
    jit = await conn.fetchval("SHOW jit")
    try:
        async with conn.transaction():
            await conn.execute(f"PREPARE {GENERIC_STMT}(text, int, int) AS {reader(key)}")
    except Exception as e:  # noqa: BLE001
        out("generic_plan", reader="routes_single", error=type(e).__name__, detail=str(e)[:160])
        return
    try:
        for country in COUNTRIES:
            lit = "'" + country.replace("'", "''") + "'"
            ex = {}
            for mode in ("force_generic_plan", "force_custom_plan"):
                label = {"reader": "routes_single_" + mode.split("_")[1], "country": country, "source": "cis"}
                doc = await explain(conn, label, f"EXECUTE {GENERIC_STMT}({lit}, {days}, {ROUTE_SLACK})", (),
                                    _markers("routes"), settings=[("plan_cache_mode", mode)])
                if doc is not None:
                    ex[mode] = doc[0].get("Execution Time", 0.0)
            out("generic_plan", reader="routes_single", country=country, days=days, slack=ROUTE_SLACK,
                generic_exec_ms=round(ex["force_generic_plan"], 1) if "force_generic_plan" in ex else None,
                custom_exec_ms=round(ex["force_custom_plan"], 1) if "force_custom_plan" in ex else None, jit=jit)
    finally:
        await conn.execute(f"DEALLOCATE {GENERIC_STMT}")


async def defects(conn, st):
    tours = [dict(r) for r in await conn.fetch(DEFECT_TOURS_SQL, DEFECT_TOURS_CAP)]
    st["defect_sources"] = [t["source_id"] for t in tours]
    for t in tours:
        canonical, ranged, covered = heading_days(t["itinerary_text"])
        out("defect_tour", source_id=t["source_id"], title=t["title"], country=t["country"],
            duration_raw=t["duration_raw"], duration_days=t["duration_days"], canonical_days=len(canonical),
            max_canonical=max(canonical) if canonical else None, ranged=",".join(ranged) or None,
            heading_days=len(covered))
        rows = [dict(r) for r in await conn.fetch(DEFECT_COMPONENTS_SQL, t["source_id"])]
        per_day = {}
        for r in rows:
            per_day.setdefault(r["day_index"], 0)
            per_day[r["day_index"]] += 1
            out("defect_component", source_id=t["source_id"][:8], day=r["day_index"], name=r["name"],
                destination=(r["destination_id"] or "")[:8], destination_name=r["destination_name"],
                precision=r["geo_precision"], located_by=r["located_by"], review=r["review_reason"],
                result_type=r["result_type"])
        frozen = await conn.fetch(FROZEN_DAY_COUNTS_SQL, [t["source_id"], t["tour_id"]])
        out("defect_days", source_id=t["source_id"][:8], cis_days=len(per_day),
            frozen_days=len(frozen), frozen_components=sum(r["n"] for r in frozen))
    places = [dict(r) for r in await conn.fetch(KUANG_SI_SQL)]
    for p in places:
        out("defect_place", id=p["id"][:8], name=p["name"], country=p["country"], located_by=p["located_by"],
            precision=p["geo_precision"], geo_status=p["geo_status"], duplicate_of=(p["dup"] or "")[:8] or None)
    for i, a in enumerate(places):
        for b in places[i + 1:]:
            out("defect_pair", a=a["id"][:8], b=b["id"][:8], km=round(km(a["lat"], a["lng"], b["lat"], b["lng"]), 2))


async def day_text_check(conn, st):
    texts = {}
    for r in await conn.fetch(TOUR_TEXTS_SQL):
        entry = (r["country"], day_texts(r["itinerary_text"]))
        texts[r["source_id"]] = entry
        texts[r["tour_id"]] = entry
    # frozen keys are a tour_id or a source_id; old tour_ids are mapped by the master pass (st["key_map"])
    key_map = st.get("key_map", {})
    for label, rows, key, day in (
            ("frozen", await conn.fetch(FROZEN_COMPONENTS_SQL), "source_tour_id", "source_day_index"),
            ("cis", await conn.fetch(CIS_COMPONENTS_TEXT_SQL), "source_id", "day_index")):
        per = {}
        for r in rows:
            k = r[key]
            entry = texts.get(k) or texts.get(key_map.get(k, ""))
            if entry is None:
                continue                      # not a live tour (AA-731 orphans): out of scope
            country, days = entry
            c = per.setdefault(country, {"components": 0, "no_day_text": 0, "not_named": 0, "examples": []})
            c["components"] += 1
            text = days.get(r[day])
            if text is None:
                c["no_day_text"] += 1
            elif not names_place(text, r["name"]):
                c["not_named"] += 1
                if len(c["examples"]) < DAY_TEXT_EXAMPLES:
                    c["examples"].append(f"{r['name']}@day{r[day]}")
        for country, c in sorted(per.items(), key=lambda kv: str(kv[0])):
            out("day_text", source=label, country=country, components=c["components"],
                no_day_text=c["no_day_text"], not_named=c["not_named"], examples="; ".join(c["examples"]) or None)


# ── pass 2: as the master ───────────────────────────────────────────────────────────────────────────────────────────

KEY_MAP_SQL = """
    SELECT rt.tour_id::text AS key, COALESCE(rt.source_group_id, rt.tour_id)::text AS source_id, rt.country
      FROM silver_aa_internal.raw_tours rt
     WHERE rt.tenant_id = $1::uuid AND rt.tour_id::text = ANY($2::text[])
"""
BUILD_STATE_SQL = """
    SELECT source_id, status, built_at, cost_usd, country FROM geo.tour_build WHERE source_id = ANY($1::text[])
"""
BUILD_BY_COUNTRY_SQL = """
    SELECT coalesce(country, '-') AS country, status, count(*) AS n, round(sum(cost_usd), 4) AS cost_usd,
           round(avg(cost_usd), 6) AS avg_cost_usd
      FROM geo.tour_build GROUP BY 1, 2 ORDER BY 1, 2
"""
# CIS 253's closing check counts components per live tour (a JOIN): live tours sharing a source_id count twice.
SHARED_SOURCE_SQL = """
    SELECT count(*) - count(DISTINCT COALESCE(rt.source_group_id, rt.tour_id)) AS extra_live_tours_per_source
      FROM gold_aa_internal.published_tours pt
      JOIN silver_aa_internal.raw_tours rt ON rt.tour_id = pt.tour_id
     WHERE pt.tenant_id = $1::uuid AND pt.master_status = 'active' AND pt.deleted_at IS NULL
       AND rt.source_status = 'active' AND rt.deleted_at IS NULL
"""
TP_GRANTS_SQL = """
    SELECT 'schema' AS kind, n.nspname AS object, has_schema_privilege('tripplanner', n.oid, 'USAGE') AS ok
      FROM pg_namespace n WHERE n.nspname IN ('silver_aa_internal', 'acp_contract')
    UNION ALL
    SELECT 'table', n.nspname || '.' || c.relname || ' ' || a.privilege_type, true
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace, aclexplode(c.relacl) a
     WHERE a.grantee = 'tripplanner'::regrole AND n.nspname IN ('silver_aa_internal', 'acp_contract')
    UNION ALL
    SELECT 'column', n.nspname || '.' || c.relname || '(' || string_agg(at.attname, ',' ORDER BY at.attname) || ') '
           || a.privilege_type, true
      FROM pg_attribute at JOIN pg_class c ON c.oid = at.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace,
           aclexplode(at.attacl) a
     WHERE a.grantee = 'tripplanner'::regrole AND n.nspname IN ('silver_aa_internal', 'acp_contract')
       AND NOT at.attisdropped
     GROUP BY n.nspname, c.relname, a.privilege_type
"""
XREF_SQL = """
    SELECT n.nspname AS table_schema, c.relname AS table_name
      FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE a.attname = 'destination_id' AND NOT a.attisdropped AND c.relkind IN ('r', 'p')
       AND n.nspname IN ('booking', 'tripplanner', 'shared', 'acp_shared', 'geo')
     ORDER BY 1, 2
"""
# relid, not a ::regclass cast of schemaname || '.' || relname: the cast failed on Dev (`relation
# "shared.pg_stats_ext" does not exist`, S246 after-migrations probe) and ended the master pass before stats /
# pg_stat_statements; a join on relid cannot fail on a name.
ANALYZE_SQL = """
    SELECT s.schemaname || '.' || s.relname AS rel, s.n_live_tup, s.last_analyze, s.last_autoanalyze,
           c.reltuples
      FROM pg_stat_user_tables s JOIN pg_class c ON c.oid = s.relid
     WHERE s.schemaname = 'geo' OR (s.schemaname = 'shared' AND s.relname IN ('destinations', 'place_photo'))
     ORDER BY 1
"""
STATEMENTS_SQL = """
    SELECT left(regexp_replace(query, '\\s+', ' ', 'g'), 90) AS q, calls, round(mean_exec_time::numeric, 1) AS mean_ms,
           round(max_exec_time::numeric, 1) AS max_ms
      FROM pg_stat_statements
     WHERE query ILIKE '%catalog.v_%' AND userid = 'tripplanner'::regrole
     ORDER BY mean_exec_time DESC LIMIT 10
"""


async def master_pass(conn, budget, st):
    # ── 1. coverage: old tour_id keys -> source_id (raw_tours, any version) ──
    keys = st["frozen_keys"]
    key_map = {r["key"]: r["source_id"] for r in await conn.fetch(KEY_MAP_SQL, AA_TENANT_ID, keys)}
    st["key_map"] = key_map
    live = st["live"]
    frozen_live, frozen_not_live = {}, 0
    for k in keys:
        src = k if k in live else key_map.get(k)
        if src in live:
            frozen_live.setdefault(live[src]["country"], set()).add(src)
        else:
            frozen_not_live += 1
    by_country = {}
    for src, t in live.items():
        by_country.setdefault(t["country"], set()).add(src)
    missing_total = 0
    for country in sorted(set(by_country) | set(frozen_live), key=str):
        fl = frozen_live.get(country, set())
        missing = sorted(fl - st["cis_components"])
        missing_total += len(missing)
        out("coverage", country=country, live=len(by_country.get(country, ())),
            cis_components=len(by_country.get(country, set()) & st["cis_components"]),
            cis_graph=len(by_country.get(country, set()) & st["cis_graph"]), frozen_live=len(fl),
            missing_in_cis_live=len(missing))
        for src in missing[:COVERAGE_MISSING_CAP]:
            out("coverage_missing", country=country, source_id=src, title=live[src]["title"])
    out("coverage_frozen", keys=len(keys), mapped_by_raw_tours=len(key_map), not_live=frozen_not_live)
    out("coverage_gate", missing_in_cis_live=missing_total, verdict="PASS" if missing_total == 0 else "FAIL")

    for r in await conn.fetch(BUILD_BY_COUNTRY_SQL):
        out("build", country=r["country"], status=r["status"], tours=r["n"], cost_usd=r["cost_usd"],
            avg_cost_usd=r["avg_cost_usd"])
    for r in await conn.fetch(BUILD_STATE_SQL, st.get("defect_sources", [])):
        out("defect_build", source_id=r["source_id"][:8], status=r["status"], built_at=r["built_at"],
            cost_usd=r["cost_usd"])

    # ── 6. environment ──
    if budget.over("environment", reserve=30):
        return
    ext = await conn.fetchval("SELECT extversion FROM pg_extension WHERE extname = 'vector'")
    iterative = await conn.fetchval("SELECT current_setting('hnsw.iterative_scan', true)")
    out("env", pgvector=ext, hnsw_iterative_scan=iterative,
        server=await conn.fetchval("SELECT current_setting('server_version')"),
        jit=await conn.fetchval("SHOW jit"), jit_above_cost=await conn.fetchval("SHOW jit_above_cost"),
        plan_cache_mode=await conn.fetchval("SHOW plan_cache_mode"),
        extra_live_tours_per_source=await conn.fetchval(SHARED_SOURCE_SQL, AA_TENANT_ID))
    # (the index-ordered top-k EXPLAIN moved to pass 1, as tripplanner: SCRIPT env_topk / env_topk_summary)
    for r in await conn.fetch(TP_GRANTS_SQL):
        out("grant", role="tripplanner", kind=r["kind"], object=r["object"], held=r["ok"])
    for r in await conn.fetch(XREF_SQL):
        try:
            async with conn.transaction():
                n = await conn.fetchval(f'SELECT count(*) FROM "{r["table_schema"]}"."{r["table_name"]}" '
                                        f"WHERE destination_id IS NOT NULL")
            out("xref", table=f"{r['table_schema']}.{r['table_name']}", rows_with_destination=n)
        except Exception as e:  # noqa: BLE001
            out("xref", table=f"{r['table_schema']}.{r['table_name']}", error=type(e).__name__)
    try:
        async with conn.transaction():
            stats = await conn.fetch(ANALYZE_SQL)
        for r in stats:
            out("stats", rel=r["rel"], n_live_tup=r["n_live_tup"], reltuples=r["reltuples"],
                last_analyze=r["last_analyze"], last_autoanalyze=r["last_autoanalyze"])
    except Exception as e:  # noqa: BLE001 — reported, pg_stat_statements still runs
        out("stats", error=type(e).__name__, detail=str(e)[:160])
    try:
        async with conn.transaction():
            rows = await conn.fetch(STATEMENTS_SQL)
        out("pg_stat_statements", readable=True, rows=len(rows))
        for r in rows:
            out("statement", calls=r["calls"], mean_ms=r["mean_ms"], max_ms=r["max_ms"], query=r["q"])
    except Exception as e:  # noqa: BLE001
        out("pg_stat_statements", readable=False, error=type(e).__name__)


async def main(conn):
    budget = Budget(BUDGET_S)
    st = {}
    out("start", readers_from=READERS_FROM, readers=len(READERS), readers_absent=",".join(READERS_ABSENT) or None,
        countries=",".join(COUNTRIES))
    async with conn.transaction():
        try:
            async with conn.transaction():
                await conn.execute("SET LOCAL ROLE tripplanner")
        except Exception as e:  # noqa: BLE001
            out("refuse", what="set_role", role="tripplanner", error=type(e).__name__)
            return 1
        await conn.execute("SET LOCAL ROLE tripplanner")
        # what the legacy readers set before reading published_tours (backend/shared/catalog_rls.py); the catalog
        # views read with their owner's rights and are not changed by it
        await conn.execute("SELECT set_config('app.tenant_id', $1, true)", AA_TENANT_ID)
        out("pass", role=await conn.fetchval("SELECT current_user"))
        await guarded(conn, "tripplanner_pass", tripplanner_pass(conn, budget, st))
    async with conn.transaction():
        out("pass", role=await conn.fetchval("SELECT current_user"))
        if "live" in st:
            await guarded(conn, "master_pass", master_pass(conn, budget, st))
    if "live" in st and not budget.over("day_text", reserve=30):
        async with conn.transaction():
            await conn.execute("SET LOCAL ROLE tripplanner")
            out("pass", role=await conn.fetchval("SELECT current_user"))
            await guarded(conn, "day_text", day_text_check(conn, st))
    out("done", elapsed_s=round(budget.elapsed(), 1))
    return 0
