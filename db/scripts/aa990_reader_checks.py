"""AA-990 evidence (read-only): do the readers that sit outside CIS follow the S1 v2 rewrite?

Two checks that need the master login (they read `tripplanner.*` and `crm.*` next to CIS views):
- TripPlanner saved trips: every pinned component (`add_component` events, mapped through
  `tripplanner.component_id_map`) still resolves to a `geo.tour_place` row, and how many of those rows sit on
  replaced atoms (atom ids no longer in `acp_contract.v_active_tour_atoms`).
- TripPlanner coverage over the active catalogue (S252, Nghiệp: "cho cả tripplanner"): tour/day layers, components,
  place builds, components on replaced atoms, tour graph, feed jobs, narration cache, spend, pins served, retired
  rows, purge delivery, TP-owned row counts.
- CRM AA catalog cache: per served state, how many cached tours have the live `catalog.v_tour.content_hash`, and how
  many CIS catalog tours are not cached yet; plus the cache's pass state.

Output (DB Migrate mode=run-script; db/scripts/README.md): `SCRIPT pins {...}`, `SCRIPT crm_state {...}`,
`SCRIPT crm_cache {...}` per served state, `SCRIPT crm_coverage {...}`. Counts and timestamps only: no trip,
person or tour text. Always returns 0 (evidence, not a gate).

Local test: `python3 db/scripts/aa990_reader_checks.py <DSN>`.
"""

import json

READ_ONLY = True

PINS_SQL = """
WITH pins AS (
  SELECT DISTINCT e.trip_id, e.payload->>'component_id' AS cid
    FROM tripplanner.trip_events e
   WHERE e.event_type = 'add_component' AND e.payload ? 'component_id'),
r AS (
  SELECT p.trip_id, COALESCE(m.new_id::text, p.cid) AS cid
    FROM pins p
    LEFT JOIN tripplanner.component_id_map m ON m.old_id::text = p.cid)
SELECT count(DISTINCT r.trip_id) AS trips, count(*) AS pins,
       count(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM geo.tour_place g
                                           WHERE g.component_id::text = r.cid)) AS dangling,
       count(*) FILTER (WHERE EXISTS (SELECT 1 FROM geo.tour_place g
                                       WHERE g.component_id::text = r.cid
                                         AND NOT EXISTS (SELECT 1 FROM acp_contract.v_active_tour_atoms a
                                                          WHERE a.atom_id = ANY (g.atom_ids)))) AS on_replaced_atoms
  FROM r
"""

CRM_STATE_SQL = """
SELECT pass_started_at, last_full_pass_at, last_ok_at, failures, last_error_class
  FROM crm.aa_catalog_state
"""

CRM_CACHE_SQL = """
SELECT c.served_state, count(*) AS cached,
       count(*) FILTER (WHERE c.content_hash = v.content_hash) AS hash_matches_live,
       min(c.fetched_at) AS oldest_fetch, max(c.fetched_at) AS newest_fetch
  FROM crm.aa_catalog_tour c
  LEFT JOIN catalog.v_tour v ON v.source_system = 'cis' AND v.source_id = c.source_id
 GROUP BY 1
 ORDER BY 1
"""

CRM_COVERAGE_SQL = """
SELECT count(*) AS catalog_tours,
       count(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM crm.aa_catalog_tour c
                                           WHERE c.source_id = v.source_id)) AS not_cached
  FROM catalog.v_tour v
 WHERE v.source_system = 'cis'
"""


AA_MASTER_TENANT = "00000000-0000-0000-0000-000000000001"

# ── 1. What TripPlanner can show per live tour (catalog.v_tour = the served set; every TP read starts here) ────────
# components = planner stops / map pins / tiles / search / suggestions (catalog.v_tour_component over geo.tour_place);
# day list = catalog.v_tour_day (parsed from v_tour.itinerary_text, "Day N —"); places = tour-page pins
# (catalog.v_tour_place, lat/lng NULL when no destination could be linked); route = current tour graph build
# (catalog.v_tour_stop / v_tour_leg; a leg needs >= 2 days, so a 1-day tour never has one).
TP_TOUR_LAYERS_SQL = """
WITH t AS (
  SELECT source_id, itinerary_text FROM catalog.v_tour),
c AS (
  SELECT source_id, count(*) AS n,
         count(*) FILTER (WHERE is_stale) AS stale,
         count(*) FILTER (WHERE embedding IS NOT NULL) AS embedded
    FROM catalog.v_tour_component GROUP BY source_id),
d AS (
  SELECT source_id, count(*) AS n FROM catalog.v_tour_day GROUP BY source_id),
p AS (
  SELECT source_id, count(*) AS n, count(*) FILTER (WHERE lat IS NOT NULL) AS located
    FROM catalog.v_tour_place GROUP BY source_id),
s AS (
  SELECT source_id, count(*) AS n FROM catalog.v_tour_stop GROUP BY source_id),
l AS (
  SELECT source_id, count(*) AS n FROM catalog.v_tour_leg GROUP BY source_id)
SELECT count(*) AS live_tours,
       count(*) FILTER (WHERE c.n > 0) AS with_components,
       round(100.0 * count(*) FILTER (WHERE c.n > 0) / NULLIF(count(*), 0), 1) AS pct_with_components,
       count(*) FILTER (WHERE c.stale > 0) AS with_stale_components,
       count(*) FILTER (WHERE c.embedded > 0) AS with_embedded_components,
       count(*) FILTER (WHERE c.n > 0 AND c.embedded < c.n) AS with_unembedded_components,
       count(*) FILTER (WHERE t.itinerary_text IS NULL) AS without_itinerary_text,
       count(*) FILTER (WHERE d.n > 0) AS with_day_list,
       round(100.0 * count(*) FILTER (WHERE d.n > 0) / NULLIF(count(*), 0), 1) AS pct_with_day_list,
       count(*) FILTER (WHERE p.n > 0) AS with_places,
       count(*) FILTER (WHERE p.located > 0) AS with_located_places,
       count(*) FILTER (WHERE p.n > 0 AND p.located = 0) AS places_none_located,
       count(*) FILTER (WHERE s.n > 0) AS with_route_stops,
       count(*) FILTER (WHERE l.n > 0) AS with_route_legs,
       round(100.0 * count(*) FILTER (WHERE s.n > 0) / NULLIF(count(*), 0), 1) AS pct_with_route_stops,
       (array_agg(t.source_id ORDER BY t.source_id) FILTER (WHERE c.n IS NULL))[1:5] AS sample_no_components,
       (array_agg(t.source_id ORDER BY t.source_id) FILTER (WHERE c.stale > 0))[1:5] AS sample_stale_components,
       (array_agg(t.source_id ORDER BY t.source_id) FILTER (WHERE d.n IS NULL))[1:5] AS sample_no_day_list
  FROM t
  LEFT JOIN c ON c.source_id = t.source_id
  LEFT JOIN d ON d.source_id = t.source_id
  LEFT JOIN p ON p.source_id = t.source_id
  LEFT JOIN s ON s.source_id = t.source_id
  LEFT JOIN l ON l.source_id = t.source_id
"""

# ── 2. Component-level totals (what search / suggestions / the trip fold read) ─────────────────────────────────────
TP_COMPONENTS_SQL = """
SELECT (SELECT count(*) FROM catalog.v_tour_component) AS served_components,
       (SELECT count(*) FROM catalog.v_tour_component WHERE is_stale) AS stale_components,
       (SELECT count(*) FROM catalog.v_tour_component WHERE embedding IS NOT NULL) AS embedded_components,
       (SELECT count(*) FROM catalog.v_component_embedding WHERE embedding IS NOT NULL) AS search_index_rows,
       (SELECT count(*) FROM geo.tour_place) AS tour_place_rows,
       (SELECT count(*) FROM geo.tour_place WHERE destination_id IS NULL) AS tour_place_unlinked,
       (SELECT count(*) FROM geo.tour_place WHERE embedding IS NULL) AS tour_place_unembedded
"""

# ── 3. Place build per live tour vs the S1 v2 rewrite (master updated) and the re-made atoms ───────────────────────
# geo.tour_build is one row per catalog key (source_id = raw_tours.source_key = v_tour.source_id, 258).
# v_tour.updated_at = GREATEST(published_at, Master updated_at, newest photo) (273), so a photo change also counts.
TP_PLACE_BUILD_SQL = """
WITH t AS (
  SELECT source_id, tour_id, updated_at FROM catalog.v_tour),
a AS (
  SELECT tour_id, max(created_at) AS newest_atom,
         count(*) FILTER (WHERE place IS NOT NULL AND btrim(place) <> '') AS place_atoms
    FROM acp_contract.v_active_tour_atoms GROUP BY tour_id)
SELECT count(*) AS live_tours,
       count(b.source_id) AS with_place_build,
       round(100.0 * count(b.source_id) / NULLIF(count(*), 0), 1) AS pct_with_place_build,
       count(*) FILTER (WHERE b.status = 'ok') AS build_ok,
       count(*) FILTER (WHERE b.status = 'partial') AS build_partial,
       count(*) FILTER (WHERE b.status IN ('pending', 'failed')) AS build_pending_or_failed,
       count(*) FILTER (WHERE b.status = 'retired') AS build_retired_but_live,
       count(*) FILTER (WHERE b.tour_id <> t.tour_id) AS build_on_older_tour_version,
       count(*) FILTER (WHERE b.built_at < t.updated_at) AS built_before_tour_update,
       count(*) FILTER (WHERE b.built_at < a.newest_atom) AS built_before_newest_atom,
       count(*) FILTER (WHERE a.tour_id IS NULL) AS live_without_active_atoms,
       count(*) FILTER (WHERE a.place_atoms = 0) AS live_without_place_atoms,
       min(b.built_at) AS oldest_build, max(b.built_at) AS newest_build,
       (array_agg(t.source_id ORDER BY t.source_id) FILTER (WHERE b.source_id IS NULL))[1:5] AS sample_unbuilt,
       (array_agg(t.source_id ORDER BY t.source_id)
          FILTER (WHERE b.built_at < a.newest_atom))[1:5] AS sample_built_before_atoms
  FROM t
  LEFT JOIN geo.tour_build b ON b.source_id = t.source_id
  LEFT JOIN a ON a.tour_id = t.tour_id
"""

# ── 4. Served components whose atoms were replaced (same rule as PINS_SQL on_replaced_atoms) ───────────────────────
TP_COMPONENT_ATOMS_SQL = """
WITH comp AS (
  SELECT source_id, component_id FROM catalog.v_tour_component),
ga AS (
  SELECT g.component_id, unnest(g.atom_ids) AS atom_id
    FROM geo.tour_place g
   WHERE g.component_id IN (SELECT component_id FROM comp)),
per AS (
  SELECT ga.component_id,
         bool_or(act.atom_id IS NOT NULL) AS any_active,
         bool_and(act.atom_id IS NOT NULL) AS all_active
    FROM ga
    LEFT JOIN (SELECT DISTINCT atom_id FROM acp_contract.v_active_tour_atoms) act ON act.atom_id = ga.atom_id
   GROUP BY ga.component_id)
SELECT count(*) AS served_components,
       count(*) FILTER (WHERE per.component_id IS NULL) AS without_atom_ids,
       count(*) FILTER (WHERE NOT per.any_active) AS on_replaced_atoms_only,
       count(*) FILTER (WHERE per.any_active AND NOT per.all_active) AS partly_replaced,
       count(DISTINCT comp.source_id) FILTER (WHERE NOT per.any_active) AS tours_with_replaced,
       (array_agg(DISTINCT comp.source_id) FILTER (WHERE NOT per.any_active))[1:5] AS sample_tours
  FROM comp
  LEFT JOIN per ON per.component_id = comp.component_id
"""

# ── 5. Tour graph (map routes, "Customise this trip", suggestions) vs the newest place build ───────────────────────
TP_GRAPH_SQL = """
SELECT b.build_id, b.built_at,
       (SELECT max(tb.built_at) FROM geo.tour_build tb) AS newest_place_build,
       (SELECT count(*) FROM geo.tour_build tb WHERE tb.built_at > b.built_at) AS place_builds_after_graph,
       (SELECT count(*) FROM catalog.v_graph_node) AS graph_nodes,
       (SELECT count(DISTINCT source_id) FROM catalog.v_tour_stop) AS tours_with_stops,
       (SELECT count(DISTINCT source_id) FROM catalog.v_tour_leg) AS tours_with_legs
  FROM geo.graph_build b
 WHERE b.is_current
"""

# ── 6. CIS jobs that feed the TripPlanner layers (last 7 days) ─────────────────────────────────────────────────────
TP_FEED_JOBS_SQL = """
SELECT kind, status, payload->>'reason' AS reason, count(*) AS jobs,
       sum(cost_usd) AS cost_usd, max(finished_at) AS last_finished
  FROM shared.job
 WHERE kind IN ('place_extract', 'place_geocode', 'tour_graph_build', 'place_shape', 'tripplanner_purge')
   AND created_at > now() - interval '7 days'
 GROUP BY 1, 2, 3
 ORDER BY 1, 2, 3
"""

# ── 7. Narration cache (key = hash of prompt version + mode + per-day component + master day text; no tour column,
#       so it cannot be counted per tour). A changed master day text changes the key: old rows are simply missed. ──
TP_NARRATION_CACHE_SQL = """
SELECT count(*) AS rows,
       count(*) FILTER (WHERE mode = 'compose') AS compose,
       count(*) FILTER (WHERE mode = 'renarrate') AS renarrate,
       count(*) FILTER (WHERE source = 'llm') AS source_llm,
       count(*) FILTER (WHERE source = 'mixed') AS source_mixed,
       count(*) FILTER (WHERE created_at > now() - interval '168 hours') AS within_default_ttl,
       count(*) FILTER (WHERE created_at < (SELECT max(updated_at) FROM catalog.v_tour)) AS older_than_newest_tour_update,
       sum(hits) AS hits, min(created_at) AS oldest, max(created_at) AS newest
  FROM tripplanner.narration_cache
"""

# ── 8. TripPlanner model spend (tp_compose narration, tp_search_embed query embeds), last 14 days ──────────────────
TP_SPEND_SQL = """
SELECT stage, sum(cost_usd) AS cost_usd, sum(calls) AS calls, sum(unpriced_calls) AS unpriced_calls,
       max(day) AS last_day
  FROM tripplanner.llm_spend_daily
 WHERE day > current_date - 14
 GROUP BY stage
 ORDER BY stage
"""

# ── 9. Pins as TripPlanner serves them (PINS_SQL resolution, then the view the trip fold reads) ────────────────────
# A pin of a retired / paused tour is kept by design (AA-986 L6: listed as an unavailable stop, not deleted).
TP_PINS_SERVED_SQL = """
WITH pins AS (
  SELECT DISTINCT e.trip_id, e.payload->>'component_id' AS cid
    FROM tripplanner.trip_events e
   WHERE e.event_type = 'add_component' AND e.payload ? 'component_id'),
r AS (
  SELECT p.trip_id, COALESCE(m.new_id::text, p.cid) AS cid
    FROM pins p
    LEFT JOIN tripplanner.component_id_map m ON m.old_id::text = p.cid),
served AS (
  SELECT component_id::text AS cid FROM catalog.v_tour_component),
k AS (
  SELECT r.trip_id, r.cid, (s.cid IS NOT NULL) AS is_served, g.source_id
    FROM r
    LEFT JOIN served s ON s.cid = r.cid
    LEFT JOIN geo.tour_place g ON g.component_id::text = r.cid)
SELECT count(*) AS pins,
       count(*) FILTER (WHERE k.is_served) AS served,
       count(*) FILTER (WHERE NOT k.is_served AND k.source_id IS NULL) AS no_component_row,
       count(*) FILTER (WHERE NOT k.is_served AND rt.state = 'retired') AS on_retired_tour,
       count(*) FILTER (WHERE NOT k.is_served AND rt.state = 'paused') AS on_paused_tour,
       count(*) FILTER (WHERE NOT k.is_served AND k.source_id IS NOT NULL AND rt.state IS NULL) AS hidden_other,
       count(DISTINCT k.trip_id) FILTER (WHERE NOT k.is_served) AS trips_with_unserved_pin
  FROM k
  LEFT JOIN catalog.v_tour_retired rt ON rt.source_id = k.source_id AND rt.state IN ('retired', 'paused')
"""

# ── 10. Retired / paused keys: what TripPlanner still serves of them (every *_served must be 0) ────────────────────
TP_RETIRED_SQL = """
WITH gone AS (
  SELECT source_id, state FROM catalog.v_tour_retired WHERE state IN ('retired', 'paused'))
SELECT (SELECT count(*) FROM gone WHERE state = 'retired') AS retired_keys,
       (SELECT count(*) FROM gone WHERE state = 'paused') AS paused_keys,
       (SELECT count(*) FROM catalog.v_tour v JOIN gone USING (source_id)) AS tours_served,
       (SELECT count(*) FROM catalog.v_tour_component c JOIN gone USING (source_id)) AS components_served,
       (SELECT count(*) FROM catalog.v_tour_stop s JOIN gone USING (source_id)) AS route_stops_served,
       (SELECT count(*) FROM catalog.v_tour_day d JOIN gone USING (source_id)) AS days_served,
       (SELECT count(*) FROM geo.tour_build b JOIN gone USING (source_id) WHERE b.status <> 'retired') AS builds_not_marked
"""

# ── 11. AA-987 purge delivery: one tripplanner_purge job per lifecycle event (key 'tripplanner_purge:' || event key) ─
TP_PURGE_SQL = """
SELECT COALESCE(j.status, 'no_job') AS job_status, j.result->>'delivered' AS delivered,
       count(*) AS events, max(o.occurred_at) AS newest_event
  FROM catalog.v_tour_lifecycle_outbox o
  LEFT JOIN shared.job j ON j.idempotency_key = 'tripplanner_purge:' || o.idempotency_key
 GROUP BY 1, 2
 ORDER BY 1, 2
"""

# ── 12. TripPlanner-owned rows (traveller side; not generated from CIS, counts only) ───────────────────────────────
TP_OWN_ROWS_SQL = """
SELECT (SELECT count(*) FROM tripplanner.sessions) AS sessions,
       (SELECT count(*) FROM tripplanner.trip_drafts) AS trip_drafts,
       (SELECT count(*) FROM tripplanner.trip_drafts WHERE status = 'sent') AS trips_sent,
       (SELECT count(DISTINCT trip_id) FROM tripplanner.trip_events) AS trips_with_events,
       (SELECT count(*) FROM tripplanner.component_id_map) AS component_id_map_rows,
       (SELECT count(*) FROM tripplanner.customers) AS customers,
       (SELECT count(*) FROM tripplanner.traveller_accounts) AS traveller_accounts,
       (SELECT count(*) FROM tripplanner.outbox) AS outbox_rows
"""


def _line(tag: str, row) -> None:
    print(f"SCRIPT {tag} {json.dumps(dict(row), default=str, sort_keys=True)}", flush=True)


async def _pinned(conn, sql: str, many: bool = False):
    """Run a catalog read with app.tenant_id = AA master for this transaction only (how CIS reads
    acp_contract.v_active_tour_atoms / catalog.*, services/places/store._catalog_fetch). SET is allowed in a
    read-only transaction; the views also answer without it (owner policies), so this is belt and braces."""
    async with conn.transaction():
        await conn.execute("SELECT set_config('app.tenant_id', $1, true)", AA_MASTER_TENANT)
        return await (conn.fetch(sql) if many else conn.fetchrow(sql))


async def _safe(tag: str, coro) -> None:
    """One check failing (SQLSTATE, missing view) must not hide the others: print its error class and go on."""
    try:
        res = await coro
    except Exception as exc:  # noqa: BLE001 - evidence script: report and continue
        print(f"SCRIPT {tag} error={type(exc).__name__} sqlstate={getattr(exc, 'sqlstate', '')}", flush=True)
        return
    rows = res if isinstance(res, list) else [res]
    for row in rows:
        _line(tag, row if row is not None else {"none": True})


async def main(conn):
    await _safe("pins", conn.fetchrow(PINS_SQL))
    await _safe("crm_state", conn.fetch(CRM_STATE_SQL))
    await _safe("crm_cache", conn.fetch(CRM_CACHE_SQL))
    await _safe("crm_coverage", conn.fetchrow(CRM_COVERAGE_SQL))
    await _safe("tp_tour_layers", _pinned(conn, TP_TOUR_LAYERS_SQL))
    await _safe("tp_components", _pinned(conn, TP_COMPONENTS_SQL))
    await _safe("tp_place_build", _pinned(conn, TP_PLACE_BUILD_SQL))
    await _safe("tp_component_atoms", _pinned(conn, TP_COMPONENT_ATOMS_SQL))
    await _safe("tp_graph", _pinned(conn, TP_GRAPH_SQL))
    await _safe("tp_feed_jobs", _pinned(conn, TP_FEED_JOBS_SQL, many=True))
    await _safe("tp_narration_cache", _pinned(conn, TP_NARRATION_CACHE_SQL))
    await _safe("tp_spend", conn.fetch(TP_SPEND_SQL))
    await _safe("tp_pins_served", _pinned(conn, TP_PINS_SERVED_SQL))
    await _safe("tp_retired", _pinned(conn, TP_RETIRED_SQL))
    await _safe("tp_purge", _pinned(conn, TP_PURGE_SQL, many=True))
    await _safe("tp_own_rows", conn.fetchrow(TP_OWN_ROWS_SQL))
    return 0


if __name__ == "__main__":
    import asyncio
    import sys

    import asyncpg

    async def _local(dsn: str) -> None:
        conn = await asyncpg.connect(dsn)
        try:
            await main(conn)
        finally:
            await conn.close()

    asyncio.run(_local(sys.argv[1]))
