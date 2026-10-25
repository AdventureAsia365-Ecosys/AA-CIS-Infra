"""AA-990 evidence (read-only): do the readers that sit outside CIS follow the S1 v2 rewrite?

Two checks that need the master login (they read `tripplanner.*` and `crm.*` next to CIS views):
- TripPlanner saved trips: every pinned component (`add_component` events, mapped through
  `tripplanner.component_id_map`) still resolves to a `geo.tour_place` row, and how many of those rows sit on
  replaced atoms (atom ids no longer in `acp_contract.v_active_tour_atoms`).
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


def _line(tag: str, row) -> None:
    print(f"SCRIPT {tag} {json.dumps(dict(row), default=str, sort_keys=True)}", flush=True)


async def main(conn):
    _line("pins", await conn.fetchrow(PINS_SQL))
    for row in await conn.fetch(CRM_STATE_SQL):
        _line("crm_state", row)
    for row in await conn.fetch(CRM_CACHE_SQL):
        _line("crm_cache", row)
    _line("crm_coverage", await conn.fetchrow(CRM_COVERAGE_SQL))
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
