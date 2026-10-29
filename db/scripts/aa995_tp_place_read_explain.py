"""AA-995 follow-up (S257, data standards C4.3 W44), read-only: why TripPlanner's catalog.v_tour_place reads are slow.

W44 pg_stat_statements (role tripplanner): the fallback-cover read (TripPlanner backend/browse/catalog.py
TOUR_DESTINATIONS_SQL) 4,141 calls, mean 335 ms, p95 ~2.5 s, max 7.75 s, 31 % of all DB time, every block a buffer
hit (99 reads) but 50k temp blocks written; the destination-page read (COUNTRY_PLACES_SQL) mean ~450 ms. The browse
Lambda keeps ONE pooled connection for its life and asyncpg caches prepared statements, so after five runs Postgres
may plan these reads generically (the AA-847 trap TripPlanner already fixed for routes.proposals()). This probe
measures, for the same tour id lists:

  1. the readers exactly as TripPlanner runs them, as `tripplanner` (SET LOCAL ROLE, like the Lambda), under a
     CUSTOM plan (plan_cache_mode = force_custom_plan) and a GENERIC plan (force_generic_plan, what a long-lived
     pooled connection can get), each with the server's jit setting and with jit off (the TripPlanner S257 read
     settings are custom + jit off; a local stand-in spent ~55 of ~78 ms per call compiling 125 JIT functions for
     this view): PREPARE + EXPLAIN (ANALYZE, BUFFERS) EXECUTE (planning, buffers, temp, JIT time), then REPEATS timed
     EXECUTEs per mode;
  2. as the master, the same reads over the view BODY inlined (`old_inline`, CIS 256's statement verbatim, with the
     internal views _live_tour (273) and _tour_day_text (289) inlined as well, since the master may not read them;
     to check the master-inline numbers against the view numbers) and over a candidate narrower CIS view
     (`cand_a` = catalog.v_tour_destination: v_tour_place's rows and destination columns without the day-text parse,
     the spelling / position windows, the place-card display columns and the line-stretch lookup; the place name is
     normalised once per place instead of per pipeline row; `cand_b` = cand_a matching the pipeline row on the
     stored geo.tour_place.name_norm instead of geo.name_norm(name));
  3. parity: the candidates' rows against the view's rows for every set (multiset of the reader's columns);
  4. how often geo.tour_place.name_norm differs from geo.name_norm(name) (cand_b is only usable when never);
  5. pg_stat_statements for every catalog.v_tour_place statement (per role) and the planner settings.

Sets: `n25` = 25 tours of the country with the most tours (slug order), `n100` = 100 tours (slug order), `country`
= every listed tour of that country (the destination page). Output lines start with `SCRIPT `; counts, ids of no
tour, timings, plan node types only (no tour text). Time budget BUDGET_S (`SCRIPT truncated ...`). Always returns 0.

Dispatch (after the Infra PR adds it under db/scripts/): DB Migrate, mode=run-script,
script=db/scripts/aa995_tp_place_read_explain.py. Read the output:
`gh api repos/AdventureAsia365-Ecosys/AA-CIS-Infra/actions/jobs/<id>/logs | grep -o 'SCRIPT .*'`.
Local: `python3 aa995_tp_place_read_explain.py <DSN>` (a superuser on a throwaway database with the catalog views).
"""

import asyncio
import collections
import json
import statistics
import sys
import time
import uuid

READ_ONLY = True

REPEATS = 3
BUDGET_S = 20 * 60
SET_SIZES = (25, 100)
TOP_NODES = 6
HIDDEN_LIFECYCLE = "retired"  # TripPlanner catalog.HIDDEN_LIFECYCLE

# ── TripPlanner readers (AA-TripPlanner-Web backend/browse/catalog.py), verbatim ─────────────────────────────────────
TP_READERS = {
    # fallback covers of a tour list / tour page / destination page (before S257)
    "tour_destinations": """
    SELECT p.tour_id::text AS tour_id, p.destination_id::text AS destination_id, p.destination_name,
           p.day_number
    FROM catalog.v_tour_place p
    WHERE p.tour_id = ANY($1::uuid[]) AND p.destination_id IS NOT NULL
""",
    # destination page places (before S257)
    "country_places_old": """
    SELECT p.destination_id::text AS destination_id, p.destination_name, p.lat, p.lng,
           p.tour_id::text AS tour_id, p.activity_types, p.located_by, p.precision
    FROM catalog.v_tour_place p
    WHERE p.tour_id = ANY($1::uuid[])
      AND p.destination_id IS NOT NULL AND p.lat IS NOT NULL AND p.lng IS NOT NULL
""",
    # destination page places (S257: the page's only place read, + day_number, places without coordinates too)
    "country_places_new": """
    SELECT p.destination_id::text AS destination_id, p.destination_name, p.lat, p.lng,
           p.tour_id::text AS tour_id, p.activity_types, p.located_by, p.precision, p.day_number
    FROM catalog.v_tour_place p
    WHERE p.tour_id = ANY($1::uuid[]) AND p.destination_id IS NOT NULL
""",
}

# The columns parity compares per reader (all readers' select lists are subsets of the candidate's columns).
PARITY_COLS = {
    "tour_destinations": ("tour_id", "destination_id", "destination_name", "day_number"),
    "country_places_old": ("destination_id", "destination_name", "lat", "lng", "tour_id", "activity_types",
                           "located_by", "precision"),
    "country_places_new": ("destination_id", "destination_name", "lat", "lng", "tour_id", "activity_types",
                           "located_by", "precision", "day_number"),
}

# ── catalog.v_tour_place body, CIS migration 256 (the current statement), verbatim ──────────────────────────────────
OLD_BODY = r"""
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
  ) seg ON true
"""

# ── Candidate catalog.v_tour_destination body (a CIS migration only if this probe shows the gain) ──────────────────
# Same live tours, same atom filter, same grouping (tour, day, place key), same place-card pick and the same three
# destination candidates in the same order as v_tour_place, so the same rows and destination columns. Left out: the
# day-text parse (only place_name's spelling and position need it), the windows, the place-card display columns and
# the line-stretch lookup. The pipeline match normalises the place once per group: every spelling of a group has the
# same lower() (the group key), and geo.name_norm lowercases after folding accents, so any spelling gives the same
# key (parity below checks it on live data). The legacy match uses the group key itself (= lower(place_name)).
CAND_BODY = r"""
WITH atom AS (
    SELECT t.source_id, t.tour_id, t.country AS tour_country,
           a.itinerary_day, btrim(a.place) AS place, lower(btrim(a.place)) AS place_key,
           a.activity_type, a.created_at,
           pc.card_id
      FROM catalog._live_tour t
      JOIN acp_contract.tour_atoms a ON a.tour_id = t.tour_id AND NOT a.deleted AND NOT a.is_empty_marker
      LEFT JOIN acp_shared.atom_place_card apc ON apc.atom_id = a.atom_id
      LEFT JOIN acp_shared.place_card pc ON pc.card_id = apc.card_id AND pc.status <> 'rejected'
     WHERE a.place IS NOT NULL AND btrim(a.place) <> ''
),
grouped AS (
    SELECT source_id, tour_id, tour_country,
           itinerary_day                                                      AS day_number,
           place_key,
           geo.name_norm(min(place COLLATE "C"))                              AS place_norm,
           (array_agg(card_id ORDER BY created_at, card_id)
                FILTER (WHERE card_id IS NOT NULL))[1]                        AS place_card_id,
           array_agg(DISTINCT activity_type) FILTER (WHERE activity_type IS NOT NULL) AS activity_types
      FROM atom
     GROUP BY source_id, tour_id, tour_country, itinerary_day, place_key
)
SELECT 'cis'::text AS source_system, g.source_id, g.tour_id, g.day_number,
       d.id   AS destination_id,
       d.name AS destination_name,
       d.lat,
       d.lng,
       COALESCE(g.activity_types, ARRAY[]::text[]) AS activity_types,
       d.located_by,
       d.geo_precision AS precision
  FROM grouped g
  LEFT JOIN acp_shared.place_card pc ON pc.card_id = g.place_card_id
  LEFT JOIN LATERAL (
      SELECT gp.destination_id
        FROM geo.tour_place gp
       WHERE gp.source_id = g.source_id
         AND gp.day_index = g.day_number
         AND gp.destination_id IS NOT NULL
         AND @@PIPELINE_NAME@@ = g.place_norm
       ORDER BY gp.component_id
       LIMIT 1
  ) pipeline ON true
  LEFT JOIN LATERAL (
      SELECT k.id
        FROM shared.destinations dd
        JOIN shared.destinations k ON k.id = COALESCE(dd.duplicate_of, dd.id)
       WHERE lower(dd.name) IN (lower(pc.display_name), g.place_key)
         AND lower(dd.country) = lower(COALESCE(pc.country, g.tour_country))
         AND k.geo_status <> 'suspect' AND k.duplicate_of IS NULL
       ORDER BY (lower(dd.name) = lower(pc.display_name)) DESC NULLS LAST, dd.id
       LIMIT 1
  ) legacy ON true
  LEFT JOIN LATERAL (
      SELECT dd.id, dd.name, dd.lat, dd.lng, dd.located_by, dd.geo_precision
        FROM (VALUES (1, pipeline.destination_id), (2, pc.destination_id), (3, legacy.id)) AS c(rank, id)
        JOIN shared.destinations dd ON dd.id = c.id
       WHERE dd.geo_status <> 'suspect' AND dd.duplicate_of IS NULL
       ORDER BY c.rank
       LIMIT 1
  ) d ON true
"""

# The internal catalog views the bodies read are catalog_owner's and granted to nobody, so the master inlines them too:
# catalog._live_tour (CIS 273's statement) and catalog._tour_day_text (CIS 289's statement), verbatim.
LIVE_TOUR_BODY = r"""
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
   AND rt.deleted_at IS NULL
"""
DAY_TEXT_BODY = r"""
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
 ORDER BY b.tour_id, d.day_number, b.ord DESC
"""


def _inline(body):
    body = body.replace("catalog._tour_day_text", f"({DAY_TEXT_BODY})")
    return body.replace("catalog._live_tour", f"({LIVE_TOUR_BODY})")


BODIES = {
    "old_inline": _inline(OLD_BODY),
    "cand_a": _inline(CAND_BODY.replace("@@PIPELINE_NAME@@", "geo.name_norm(gp.name)")),
    "cand_b": _inline(CAND_BODY.replace("@@PIPELINE_NAME@@", "gp.name_norm")),
}

SETS_SQL = f"""
    SELECT t.tour_id::text AS tour_id, t.country, t.slug
      FROM catalog.v_tour t
     WHERE t.lifecycle_stage IS DISTINCT FROM '{HIDDEN_LIFECYCLE}'
     ORDER BY t.slug
"""

NAME_NORM_PARITY_SQL = """
    SELECT count(*) AS rows,
           count(*) FILTER (WHERE name_norm IS DISTINCT FROM geo.name_norm(name)) AS differ,
           count(*) FILTER (WHERE destination_id IS NOT NULL
                              AND name_norm IS DISTINCT FROM geo.name_norm(name)) AS differ_linked
      FROM geo.tour_place
"""

PGSS_SQL = r"""
    SELECT r.rolname, s.calls, round(s.mean_exec_time::numeric, 1) AS mean_ms,
           round(s.max_exec_time::numeric, 1) AS max_ms, round(s.stddev_exec_time::numeric, 1) AS sd_ms,
           round(s.mean_plan_time::numeric, 1) AS plan_ms, s.plans,
           s.shared_blks_hit, s.shared_blks_read, s.temp_blks_written, s.rows,
           left(regexp_replace(s.query, '\s+', ' ', 'g'), 150) AS q
      FROM pg_stat_statements s
      JOIN pg_roles r ON r.oid = s.userid
     WHERE s.query ILIKE '%catalog.v_tour_place%'
     ORDER BY s.total_exec_time DESC
     LIMIT 12
"""

SETTINGS = ("jit", "jit_above_cost", "jit_inline_above_cost", "jit_optimize_above_cost", "plan_cache_mode", "work_mem", "shared_buffers", "random_page_cost",
            "effective_cache_size", "default_statistics_target")


# (label, plan_cache_mode, jit): the server default jit with a custom and a generic plan, then the TripPlanner S257
# read settings (custom plan, jit off) and a generic plan with jit off (which of the two settings matters).
MODES = (
    ("custom", "force_custom_plan", "on"),
    ("generic", "force_generic_plan", "on"),
    ("custom_nojit", "force_custom_plan", "off"),
    ("generic_nojit", "force_generic_plan", "off"),
)


class Budget:
    def __init__(self, seconds):
        self.t0 = time.monotonic()
        self.seconds = seconds

    def left(self):
        return self.seconds - (time.monotonic() - self.t0)


def _uuid_array_literal(ids):
    # Every id comes from catalog.v_tour; re-validate before it is inlined into EXECUTE (no bind params there).
    return "'{" + ",".join(str(uuid.UUID(i)) for i in ids) + "}'::uuid[]"


def _plan_nodes(node, out):
    loops = node.get("Actual Loops", 1) or 1
    total = (node.get("Actual Total Time") or 0.0) * loops
    child_total = sum((c.get("Actual Total Time") or 0.0) * (c.get("Actual Loops", 1) or 1)
                      for c in node.get("Plans", []))
    rel = node.get("Relation Name") or node.get("Function Name") or node.get("CTE Name") or node.get("Alias") or "-"
    out.append((total - child_total, node.get("Node Type"), rel, loops, node.get("Actual Rows")))
    for c in node.get("Plans", []):
        _plan_nodes(c, out)


def _explain_summary(doc):
    top = doc[0]
    plan = top["Plan"]
    nodes = []
    _plan_nodes(plan, nodes)
    nodes.sort(key=lambda n: -n[0])
    jit = top.get("JIT") or {}
    jit_ms = (jit.get("Timing") or {}).get("Total")
    return {
        "exec_ms": round(top.get("Execution Time", 0.0), 1),
        "plan_ms": round(top.get("Planning Time", 0.0), 1),
        "hit": plan.get("Shared Hit Blocks"), "read": plan.get("Shared Read Blocks"),
        "temp_w": plan.get("Temp Written Blocks"),
        "jit_ms": round(jit_ms, 1) if jit_ms is not None else None,
        "jit_functions": jit.get("Functions"),
        "rows": plan.get("Actual Rows"),
        "top": [(round(s, 1), t, r, lo, rw) for s, t, r, lo, rw in nodes[:TOP_NODES]],
    }


def _row_key(r, cols):
    out = []
    for c in cols:
        v = r[c]
        if isinstance(v, list):
            v = tuple(sorted(v))
        elif isinstance(v, float):
            v = round(v, 9)
        elif v is not None and not isinstance(v, (str, int)):
            v = str(v)
        out.append(v)
    return tuple(out)


async def _measure(conn, label, reader, set_name, sql, ids, role, budget):
    """PREPARE the reader; per MODES entry EXPLAIN (ANALYZE, BUFFERS) it once, then time REPEATS plain EXECUTEs.
    Returns the rows of the first EXECUTE (for parity; every mode returns the same rows)."""
    stmt = f"aa995_{label}_{reader}_{set_name}"[:63]
    lit = _uuid_array_literal(ids)
    rows_out = None
    async with conn.transaction():
        if role:
            await conn.execute(f"SET LOCAL ROLE {role}")
        await conn.execute(f"PREPARE {stmt}(uuid[]) AS {sql}")
        try:
            for m, plan_mode, jit in MODES:
                if budget.left() < 30:
                    print(f"SCRIPT truncated section=measure label={label} reader={reader} set={set_name} mode={m}",
                          flush=True)
                    break
                await conn.execute(f"SET LOCAL plan_cache_mode = {plan_mode}")
                await conn.execute(f"SET LOCAL jit = {jit}")
                raw = await conn.fetchval(f"EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) EXECUTE {stmt}({lit})")
                ex = _explain_summary(json.loads(raw) if isinstance(raw, str) else raw)
                times = []
                for _ in range(REPEATS):
                    t0 = time.perf_counter()
                    rows = await conn.fetch(f"EXECUTE {stmt}({lit})")
                    times.append((time.perf_counter() - t0) * 1000)
                    if rows_out is None:
                        rows_out = rows
                print(f"SCRIPT timing label={label} reader={reader} set={set_name} ids={len(ids)} mode={m} "
                      f"rows={ex['rows']} median_ms={statistics.median(times):.1f} "
                      f"runs={'/'.join(f'{t:.0f}' for t in times)} explain_exec_ms={ex['exec_ms']} "
                      f"plan_ms={ex['plan_ms']} hit={ex['hit']} read={ex['read']} temp_w={ex['temp_w']} "
                      f"jit_ms={ex['jit_ms']} jit_functions={ex['jit_functions']}", flush=True)
                for self_ms, typ, rel, loops, rw in ex["top"]:
                    print(f"SCRIPT plan label={label} reader={reader} set={set_name} mode={m} node={typ}:{rel} "
                          f"self_ms={self_ms} loops={loops} rows={rw}", flush=True)
        finally:
            await conn.execute(f"DEALLOCATE {stmt}")
    return rows_out


async def main(conn):
    budget = Budget(BUDGET_S)
    t_start = time.monotonic()

    # 5. settings + pg_stat_statements first (cheap; the context for everything below)
    for name in SETTINGS:
        try:
            print(f"SCRIPT setting {name}={await conn.fetchval('SELECT current_setting($1)', name)}", flush=True)
        except Exception as e:  # noqa: BLE001
            print(f"SCRIPT setting {name}=error:{type(e).__name__}", flush=True)
    try:
        for r in await conn.fetch(PGSS_SQL):
            print(f"SCRIPT pgss role={r['rolname']} calls={r['calls']} mean_ms={r['mean_ms']} max_ms={r['max_ms']} "
                  f"sd_ms={r['sd_ms']} plan_ms={r['plan_ms']} plans={r['plans']} hit={r['shared_blks_hit']} "
                  f"read={r['shared_blks_read']} temp_w={r['temp_blks_written']} rows={r['rows']} q={r['q']}",
                  flush=True)
    except Exception as e:  # noqa: BLE001
        print(f"SCRIPT pgss error={type(e).__name__}", flush=True)

    # sets, as tripplanner (the served catalog as the Lambda sees it)
    try:
        async with conn.transaction():
            await conn.execute("SET LOCAL ROLE tripplanner")
            tours = await conn.fetch(SETS_SQL)
    except Exception as e:  # noqa: BLE001
        print(f"SCRIPT refuse what=set_role error={type(e).__name__}", flush=True)
        return 0
    by_country = collections.Counter(t["country"] for t in tours if t["country"])
    top_country = by_country.most_common(1)[0][0] if by_country else None
    in_top = [t["tour_id"] for t in tours if t["country"] == top_country]
    sets = {"n25": in_top[:SET_SIZES[0]], "n100": [t["tour_id"] for t in tours][:SET_SIZES[1]], "country": in_top}
    print(f"SCRIPT sets tours={len(tours)} top_country={top_country} "
          + " ".join(f"{k}={len(v)}" for k, v in sets.items()), flush=True)

    # 1 + 2 + 3
    for set_name, ids in sets.items():
        if not ids:
            continue
        for reader, sql in TP_READERS.items():
            if set_name == "country" and reader == "tour_destinations":
                continue  # the list / fallback read never takes a whole country
            if budget.left() < 60:
                print(f"SCRIPT truncated section=set set={set_name} reader={reader}", flush=True)
                continue
            ref = await _measure(conn, "view", reader, set_name, sql, ids, "tripplanner", budget)
            ref_rows = collections.Counter(_row_key(r, PARITY_COLS[reader]) for r in (ref or []))
            for label, body in BODIES.items():
                if budget.left() < 60:
                    print(f"SCRIPT truncated section=body set={set_name} reader={reader} label={label}", flush=True)
                    continue
                inline_sql = sql.replace("FROM catalog.v_tour_place p", f"FROM ({body}) p")
                try:
                    got = await _measure(conn, label, reader, set_name, inline_sql, ids, None, budget)
                except Exception as e:  # noqa: BLE001
                    print(f"SCRIPT error label={label} reader={reader} set={set_name} error={type(e).__name__}: "
                          f"{str(e)[:200]}", flush=True)
                    continue
                if ref is None or got is None:
                    continue
                got_rows = collections.Counter(_row_key(r, PARITY_COLS[reader]) for r in got)
                only_view = sum((ref_rows - got_rows).values())
                only_body = sum((got_rows - ref_rows).values())
                print(f"SCRIPT parity label={label} reader={reader} set={set_name} view_rows={sum(ref_rows.values())} "
                      f"body_rows={sum(got_rows.values())} only_view={only_view} only_body={only_body} "
                      f"verdict={'PASS' if only_view == only_body == 0 else 'FAIL'}", flush=True)

    # 4
    try:
        r = await conn.fetchrow(NAME_NORM_PARITY_SQL)
        print(f"SCRIPT name_norm rows={r['rows']} differ={r['differ']} differ_linked={r['differ_linked']}", flush=True)
    except Exception as e:  # noqa: BLE001
        print(f"SCRIPT name_norm error={type(e).__name__}", flush=True)

    print(f"SCRIPT done elapsed_s={time.monotonic() - t_start:.0f}", flush=True)
    return 0


if __name__ == "__main__":
    import asyncpg

    async def _local(dsn):
        c = await asyncpg.connect(dsn)  # a throwaway database; on Dev only DB Migrate runs it
        try:
            await main(c)
        finally:
            await c.close()

    asyncio.run(_local(sys.argv[1]))
