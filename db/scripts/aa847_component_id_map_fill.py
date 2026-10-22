"""AA-847 (AA-712 slice 6c): fill tripplanner.component_id_map (tp-017), frozen component id -> catalog component id.

Dispatch: DB Migrate, mode=run-script, script=db/scripts/aa847_component_id_map_fill.py. Merged with
`READ_ONLY = True`: a DRY RUN that prints the match counts by rule (no write, can run during a wave). The apply is a
follow-up PR that sets `READ_ONLY = False` (one line), dispatched in the flip window, after the last CIS place
build (the paid run, the validity fixes and their graph build): a rebuild after it changes uuid5 component ids.
Re-runnable: ON CONFLICT (old_id) DO NOTHING keeps the first mapping.

Why: with PLACES_SOURCE=cis TripPlanner serves the catalog's component ids; drafts from before the flip (trip_events)
and browse answers a browser cached for up to 30 minutes hold the frozen tripplanner.itinerary_components ids. The
assembly readers resolve every id through this map (TripPlanner backend/shared/component_ids.py).

Passes (each its own transaction):
  1. as `tripplanner` (SET LOCAL ROLE, as the Lambdas read): the live catalog sources (catalog.v_tour) and every
     catalog component (catalog.v_tour_component: source_id, day_index, name, activity, destination_id);
  2. as the master: the frozen components (tripplanner.itinerary_components), their tour keys mapped to catalog
     source ids through silver_aa_internal.raw_tours (an old key is a version tour_id; AA tenant named explicitly:
     the master's policies are USING true), and geo.name_norm of every name (the CIS key normaliser);
  3. apply only (READ_ONLY = False): as `tripplanner` again, one INSERT … ON CONFLICT DO NOTHING of the matches.

Rules, in order (design 03 §6.4), for a frozen component whose tour key maps to a LIVE source:
  name         (source_id, day, geo.name_norm(name), activity)
  destination  (source_id, day, destination_id)
Several candidates: the smallest component_id (deterministic). No candidate: not inserted (the pin drops from that
draft; accepted on Dev). Reasons for a row left out: no_source (the key maps to no catalog source), not_live (the
source is not live: AA-731 orphans), unmatched (live, no candidate).

Output (every line starts with `SCRIPT `):
  SCRIPT start read_only=<t|f> ...
  SCRIPT inputs frozen=<n> frozen_keys=<n> keys_mapped=<n> live_sources=<n> cis_components=<n> existing=<n>
  SCRIPT match country=<c> frozen=<n> name=<n> destination=<n> unmatched=<n> not_live=<n> no_source=<n>
  SCRIPT match_total frozen=<n> name=<n> destination=<n> unmatched=<n> not_live=<n> no_source=<n> live_share=<x>
  SCRIPT unmatched country=<c> source_id=<id> day=<d> name=<n>          (capped)
  SCRIPT apply inserted=<n> skipped_existing=<n>                         (apply only)
  SCRIPT done ...
Returns 1 when the switch to tripplanner is refused or tripplanner.component_id_map is missing (apply tp-017 first).
"""

READ_ONLY = False

AA_TENANT_ID = "00000000-0000-0000-0000-000000000001"
UNMATCHED_CAP = 40

ID_MAP_EXISTS_SQL = "SELECT to_regclass('tripplanner.component_id_map') IS NOT NULL"
EXISTING_SQL = "SELECT count(*) FROM tripplanner.component_id_map"
LIVE_SOURCES_SQL = "SELECT source_id, country FROM catalog.v_tour"
CIS_COMPONENTS_SQL = """
    SELECT component_id::text AS component_id, source_id, day_index, name, activity,
           destination_id::text AS destination_id
      FROM catalog.v_tour_component
"""
FROZEN_SQL = """
    SELECT id::text AS id, source_tour_id AS key, source_day_index AS day, name, activity,
           destination_id::text AS destination_id
      FROM tripplanner.itinerary_components
"""
KEY_MAP_SQL = """
    SELECT rt.tour_id::text AS key, COALESCE(rt.source_group_id, rt.tour_id)::text AS source_id
      FROM silver_aa_internal.raw_tours rt
     WHERE rt.tenant_id = $1::uuid AND rt.tour_id::text = ANY($2::text[])
"""
NAME_NORM_SQL = "SELECT x AS name, geo.name_norm(x) AS norm FROM unnest($1::text[]) AS x"
INSERT_SQL = """
    INSERT INTO tripplanner.component_id_map (old_id, new_id, matched_by)
    SELECT o, n, m FROM unnest($1::uuid[], $2::uuid[], $3::text[]) AS t(o, n, m)
    ON CONFLICT (old_id) DO NOTHING
"""


def _fmt(v):
    if v is None:
        return "-"
    if isinstance(v, bool):
        return "t" if v else "f"
    if isinstance(v, float):
        return f"{v:.3f}"
    s = str(v)
    return '"' + s.replace('"', "'") + '"' if (" " in s or not s) else s


def out(kind, **fields):
    print("SCRIPT " + kind + "".join(f" {k}={_fmt(v)}" for k, v in fields.items()), flush=True)


def source_of(key, key_map, live):
    """Catalog source id of a frozen tour key: an old version tour_id through raw_tours, else the key itself when it
    is a catalog source id already (TripPlanner keyed some tours by source_id)."""
    if key in key_map:
        return key_map[key]
    return key if key in live else None


def match(frozen, cis, key_map, live, norm):
    """[(old_id, new_id, rule)], {country: counts}, [unmatched rows]. Pure: the tests drive it directly.

    frozen: {id, key, day, name, activity, destination_id}; cis: {component_id, source_id, day_index, name,
    activity, destination_id}; key_map: {old key: source_id}; live: {source_id: country}; norm: {name: name_norm}."""
    by_name, by_dest = {}, {}
    for c in sorted(cis, key=lambda r: r["component_id"]):
        sid, day = c["source_id"], int(c["day_index"])
        by_name.setdefault((sid, day, norm.get(c["name"]), c["activity"]), c["component_id"])
        if c["destination_id"]:
            by_dest.setdefault((sid, day, c["destination_id"]), c["component_id"])
    pairs, counts, unmatched = [], {}, []
    for f in sorted(frozen, key=lambda r: r["id"]):
        sid = source_of(f["key"], key_map, live)
        country = live.get(sid, "-") if sid else "-"
        row = counts.setdefault(country, {"frozen": 0, "name": 0, "destination": 0, "unmatched": 0, "not_live": 0,
                                          "no_source": 0})
        row["frozen"] += 1
        if sid is None:
            row["no_source"] += 1
            continue
        if sid not in live:
            row["not_live"] += 1
            continue
        day = int(f["day"]) if f["day"] is not None else None
        new = by_name.get((sid, day, norm.get(f["name"]), f["activity"]))
        rule = "name"
        if new is None and f["destination_id"]:
            new, rule = by_dest.get((sid, day, f["destination_id"])), "destination"
        if new is None:
            row["unmatched"] += 1
            unmatched.append({"country": country, "source_id": sid, "day": day, "name": f["name"]})
            continue
        row[rule] += 1
        pairs.append((f["id"], new, rule))
    return pairs, counts, unmatched


async def main(conn):
    out("start", read_only=READ_ONLY)
    async with conn.transaction():
        try:
            async with conn.transaction():
                await conn.execute("SET LOCAL ROLE tripplanner")
        except Exception as e:  # noqa: BLE001
            out("refuse", what="set_role", role="tripplanner", error=type(e).__name__)
            return 1
        await conn.execute("SET LOCAL ROLE tripplanner")
        if not await conn.fetchval(ID_MAP_EXISTS_SQL):
            out("refuse", what="id_map_missing", hint="apply tp-017 first")
            return 1
        existing = await conn.fetchval(EXISTING_SQL)
        live = {r["source_id"]: r["country"] for r in await conn.fetch(LIVE_SOURCES_SQL)}
        cis = [dict(r) for r in await conn.fetch(CIS_COMPONENTS_SQL)]
    async with conn.transaction():
        frozen = [dict(r) for r in await conn.fetch(FROZEN_SQL)]
        keys = sorted({f["key"] for f in frozen if f["key"]})
        key_map = {r["key"]: r["source_id"] for r in await conn.fetch(KEY_MAP_SQL, AA_TENANT_ID, keys)}
        names = sorted({r["name"] for r in frozen + cis if r["name"]})
        norm = {r["name"]: r["norm"] for r in await conn.fetch(NAME_NORM_SQL, names)}
    out("inputs", frozen=len(frozen), frozen_keys=len(keys), keys_mapped=len(key_map), live_sources=len(live),
        cis_components=len(cis), existing=existing)

    pairs, counts, unmatched = match(frozen, cis, key_map, live, norm)
    total = {k: 0 for k in ("frozen", "name", "destination", "unmatched", "not_live", "no_source")}
    for country, row in sorted(counts.items()):
        out("match", country=country, **row)
        for k, v in row.items():
            total[k] += v
    live_rows = total["name"] + total["destination"] + total["unmatched"]
    out("match_total", **total, live_share=(len(pairs) / live_rows) if live_rows else None)
    for u in unmatched[:UNMATCHED_CAP]:
        out("unmatched", **u)
    if len(unmatched) > UNMATCHED_CAP:
        out("truncated", section="unmatched", shown=UNMATCHED_CAP, of=len(unmatched))

    if not READ_ONLY and pairs:
        async with conn.transaction():
            await conn.execute("SET LOCAL ROLE tripplanner")
            status = await conn.execute(INSERT_SQL, [p[0] for p in pairs], [p[1] for p in pairs],
                                        [p[2] for p in pairs])
            inserted = int(str(status).split()[-1]) if status else 0
        out("apply", inserted=inserted, skipped_existing=len(pairs) - inserted)
    out("done", read_only=READ_ONLY, pairs=len(pairs))
    return 0
