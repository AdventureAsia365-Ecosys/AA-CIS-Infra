"""X1 S15 (AA-860): does the new photo-sync itinerary read (schema geo, AA-CIS-App services/photos/sync.py
itinerary_places, X1 S15) cover what the old one (frozen tripplanner.itinerary_components / tour_stop) gave?
Read-only. The master reads tripplanner.* through its tp_owner membership (rl-001).

Dispatch: DB Migrate, mode=run-script, script=db/scripts/x1_photo_itinerary_parity.py.

Per country (shared.destinations.country), the distinct (tour_id, destination_id) pairs of each query:
  SCRIPT parity country=<name> old=<n> new=<n> both=<n> old_only=<n> new_only=<n>
  SCRIPT parity_total old=<n> new=<n> both=<n> old_only=<n> new_only=<n>
Counts only, no ids or names of tours. old_only > 0 means the photo sync would offer fewer destination
candidates after the switch for that country (expected where the CIS place pipeline has not run yet).
"""

READ_ONLY = True

MASTER_TENANT_ID = "00000000-0000-0000-0000-000000000001"

# AA-CIS-App services/photos/sync.py before X1 S15 (tour_id = TripPlanner source_tour_id, text).
OLD_SQL = """
    SELECT DISTINCT x.source_tour_id::text AS tour_id, d.id AS destination_id, d.country
      FROM (SELECT source_tour_id, destination_id FROM tripplanner.itinerary_components
            UNION SELECT source_tour_id, destination_id FROM tripplanner.tour_stop) x
      JOIN shared.destinations d ON d.id = x.destination_id
"""

# AA-CIS-App services/photos/sync.py after X1 S15, without the country filter (the liveness rule is
# services/places/store.py _LIVE_SQL, copied here: scripts import no app code).
NEW_SQL = """
    WITH live AS (
        SELECT pt.tour_id::text AS tour_id, COALESCE(rt.source_group_id, rt.tour_id)::text AS source_id
          FROM gold_aa_internal.published_tours pt
          JOIN silver_aa_internal.raw_tours rt ON rt.tour_id = pt.tour_id
         WHERE pt.tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
           AND pt.master_status = 'active' AND pt.deleted_at IS NULL
           AND rt.source_status = 'active' AND rt.deleted_at IS NULL)
    SELECT DISTINCT x.tour_id, d.id AS destination_id, d.country
      FROM (SELECT tp.tour_id::text AS tour_id, tp.destination_id
              FROM geo.tour_place tp
             WHERE tp.destination_id IS NOT NULL
            UNION
            SELECT l.tour_id, ts.destination_id
              FROM geo.tour_stop ts
              JOIN geo.graph_build gb ON gb.build_id = ts.build_id AND gb.is_current
              JOIN live l ON l.source_id = ts.source_id) x
      JOIN shared.destinations d ON d.id = x.destination_id
"""


async def _pairs(conn, sql):
    out = {}
    for r in await conn.fetch(sql):
        out.setdefault(r["country"] or "<blank>", set()).add((r["tour_id"], str(r["destination_id"])))
    return out


async def main(conn):
    async with conn.transaction():
        # The app pins the AA master tenant for its catalog reads (published_tours / raw_tours are FORCE-RLS).
        await conn.execute("SELECT set_config('app.tenant_id', $1, true)", MASTER_TENANT_ID)
        old = await _pairs(conn, OLD_SQL)
        new = await _pairs(conn, NEW_SQL)
    totals = [0, 0, 0, 0, 0]
    for country in sorted(set(old) | set(new)):
        o, n = old.get(country, set()), new.get(country, set())
        row = [len(o), len(n), len(o & n), len(o - n), len(n - o)]
        totals = [a + b for a, b in zip(totals, row)]
        print(f"SCRIPT parity country={country} old={row[0]} new={row[1]} both={row[2]} old_only={row[3]} "
              f"new_only={row[4]}", flush=True)
    print(f"SCRIPT parity_total old={totals[0]} new={totals[1]} both={totals[2]} old_only={totals[3]} "
          f"new_only={totals[4]}", flush=True)
