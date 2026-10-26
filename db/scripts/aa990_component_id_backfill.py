"""AA-990: re-point TripPlanner saved pins that a CIS place rebuild left dangling (tripplanner.component_id_map).

Dispatch: DB Migrate, mode=run-script, script=db/scripts/aa990_component_id_backfill.py. Merged with
`READ_ONLY = True`: a DRY RUN that prints counts only (no write, can run during a wave). The apply is a follow-up PR
that sets `READ_ONLY = False` (one line). Re-runnable: a pin that resolves is left alone, so a second apply writes 0;
run it again after every place re-sync wave (CIS keeps its redirects in geo.tour_build.counts.id_redirects).

Why (S252, live Dev): 322 of 371 pins (add_component events, 99 of 103 trips) had no geo.tour_place row after the
S1 v2 place re-sync of 123 tours. A component id is uuid5(source, day, itinerary spelling, country, activity) at a
place's first build; AA-989 keeps an id across a rebuild only on an unambiguous one-to-one pair, so a respelt, retyped,
moved or merged place dropped the pin. TripPlanner resolves every pinned id through tripplanner.component_id_map
(tp-017, ONE hop: backend/shared/component_ids.py) before it reads catalog.v_tour_component.

For each pinned id (raw id of the event; `cur` = the map's new_id when the map knows it, else the raw id) whose `cur`
has no geo.tour_place row, the place it was is recovered from, in order:
  redirect   geo.tour_build.counts.id_redirects (written by CIS place_extract since AA-990; chains followed);
  rederived  uuid5 recomputed from every atom ever written for the tour (soft-deleted ones included) of every built
             source: (source, itinerary_day, geo.name_norm(place), country, activity) for the 8 activities and every
             country spelling the source used — the exact id the build minted from those atoms;
  snapshot   the trip_drafts projection entry of that id (name, source_tour_id, source_day_index, destination_id;
             AA-986 L6 keeps it for a stop the catalog stopped serving).
Then the current component of the same source for the same place (the CIS rule, components.redirect_dropped):
destination → place card → spelling + country → link name + country, any day, the nearest day first, then the same
activity, then the smaller id. Writes (apply only):
  INSERT (raw, target, matched_by) as `tripplanner` (the AA-847 fill path, ON CONFLICT DO NOTHING) for a raw id the
  map does not know;
  UPDATE new_id (and matched_by) as `tp_owner` for a raw id the map knows (a pre-flip TripPlanner id whose catalog id
  the rebuild dropped): `tripplanner` has no UPDATE and the reader follows one hop only. Guarded on the old new_id.
matched_by keeps the tp-017 CHECK: 'destination' for the destination rule, 'name' otherwise.

Output (every line starts with `SCRIPT `; counts, rules and component ids only — no trip, session or person data):
  SCRIPT start / inputs / pins / payload_keys / dangling_origin / dangling_timing / dangling_snapshot / recover /
  match rule=<r> n=<n> / unmatched reason=<r> n=<n> / plan insert=<n> update=<n> / expected_after dangling=<n>
  SCRIPT restore op=insert old_id=<id> | op=update old_id=<id> prev_new_id=<id>        (apply only: the undo)
  SCRIPT apply inserted=<n> updated=<n> skipped_changed=<n> / done
Undo: DELETE the `op=insert` old_ids; UPDATE each `op=update` row back to prev_new_id (as tp_owner).
Returns 1 when the map is missing or (apply) a role switch is refused.
"""

import json
import uuid

READ_ONLY = True

AA_TENANT_ID = "00000000-0000-0000-0000-000000000001"
# CIS services/places/names.py COMPONENT_NS and components.ACTIVITIES — never change (ids would not match).
COMPONENT_NS = uuid.UUID("6f1d6a52-0f7c-5a12-9b1e-712a71200000")
ACTIVITIES = ("trekking", "cultural_heritage", "wildlife_nature", "water_activities", "culinary",
              "wellness_relaxation", "adventure_sport", "local_immersion")
RULES = ("destination", "card", "spelling", "link_name")
REDIRECT_HOPS = 5

ID_MAP_EXISTS_SQL = "SELECT to_regclass('tripplanner.component_id_map') IS NOT NULL"
EVENTS_SQL = """
    SELECT trip_id::text AS trip_id, event_type, payload, created_at
      FROM tripplanner.trip_events
     WHERE event_type IN ('add_component', 'remove_component', 'reorder')
"""
MAP_SQL = "SELECT old_id::text AS old_id, new_id::text AS new_id, created_at FROM tripplanner.component_id_map"
DRAFTS_SQL = "SELECT itinerary FROM tripplanner.trip_drafts"
PLACES_SQL = """
    SELECT component_id::text AS component_id, source_id, day_index, name, name_norm, country_norm, activity,
           destination_id::text AS destination_id, place_card_id::text AS place_card_id
      FROM geo.tour_place
"""
BUILDS_SQL = "SELECT source_id, country, built_at, counts->'id_redirects' AS redirects FROM geo.tour_build"
LIVE_SQL = "SELECT source_id FROM catalog.v_tour"
VERSIONS_SQL = """
    SELECT rt.tour_id::text AS tour_id, COALESCE(rt.source_group_id, rt.tour_id)::text AS source_id, rt.country
      FROM silver_aa_internal.raw_tours rt
     WHERE rt.tenant_id = $1::uuid AND COALESCE(rt.source_group_id, rt.tour_id)::text = ANY($2::text[])
"""
# Every atom ever written for those versions (soft-deleted included): the ids of earlier builds came from them.
ATOMS_SQL = """
    SELECT a.tour_id::text AS tour_id, a.itinerary_day AS day, btrim(a.place) AS place,
           apc.card_id::text AS card_id, pc.display_name AS card_name, pc.destination_id::text AS destination_id
      FROM acp_contract.tour_atoms a
      LEFT JOIN acp_shared.atom_place_card apc ON apc.atom_id = a.atom_id
      LEFT JOIN acp_shared.place_card pc ON pc.card_id = apc.card_id
     WHERE a.tour_id = ANY($1::uuid[]) AND a.itinerary_day IS NOT NULL
       AND a.place IS NOT NULL AND btrim(a.place) <> ''
"""
NAME_NORM_SQL = "SELECT x AS name, geo.name_norm(x) AS norm FROM unnest($1::text[]) AS x"
INSERT_SQL = """
    INSERT INTO tripplanner.component_id_map (old_id, new_id, matched_by)
    VALUES ($1::uuid, $2::uuid, $3)
    ON CONFLICT (old_id) DO NOTHING
"""
UPDATE_SQL = """
    UPDATE tripplanner.component_id_map SET new_id = $3::uuid, matched_by = $4
     WHERE old_id = $1::uuid AND new_id = $2::uuid
"""


def _fmt(v):
    if v is None:
        return "-"
    if isinstance(v, bool):
        return "t" if v else "f"
    s = str(v)
    return '"' + s.replace('"', "'") + '"' if (" " in s or not s) else s


def out(kind, **fields):
    print("SCRIPT " + kind + "".join(f" {k}={_fmt(v)}" for k, v in fields.items()), flush=True)


def _payload(p):
    return json.loads(p) if isinstance(p, str) else (p or {})


def component_uuid(source_id, day, place_norm, country_norm, activity):
    """CIS services/places/names.component_id with the name and country already normalised."""
    key = "|".join([str(source_id), str(int(day)), place_norm, country_norm, (activity or "").strip().lower()])
    return str(uuid.uuid5(COMPONENT_NS, key))


def pins_and_ids(events):
    """([{trip_id, raw, created_at}] one per (trip, raw id) of add_component, earliest), every raw id any
    add/remove/reorder event names, {payload key set: n} of add_component)."""
    pins, ids, keys = {}, set(), {}
    for e in events:
        p = _payload(e["payload"])
        if e["event_type"] == "reorder":
            ids.update(str(i) for i in (p.get("ordered_component_ids") or []) if i)
            continue
        cid = p.get("component_id")
        if not cid:
            continue
        ids.add(str(cid))
        if e["event_type"] == "add_component":
            k = ",".join(sorted(p))
            keys[k] = keys.get(k, 0) + 1
            key = (str(e["trip_id"]), str(cid))
            if key not in pins or e["created_at"] < pins[key]["created_at"]:
                pins[key] = {"trip_id": key[0], "raw": key[1], "created_at": e["created_at"]}
    return list(pins.values()), ids, keys


def rederive_index(atoms, versions, countries, norm):
    """{uuid5 id: old place} over every atom of every version of each source, all 8 activities, every country.

    atoms: ATOMS_SQL rows; versions: {tour_id: source_id}; countries: {source_id: {country_norm}};
    norm: {text: name_norm}."""
    idx = {}
    for a in atoms:
        sid = versions.get(a["tour_id"])
        spelling = norm.get(a["place"]) or ""
        if not sid or not spelling:
            continue
        for country in sorted(countries.get(sid) or ()):
            for act in ACTIVITIES:
                cid = component_uuid(sid, a["day"], spelling, country, act)
                idx.setdefault(cid, {"source_id": sid, "day": int(a["day"]), "spelling": spelling,
                                     "link": norm.get(a.get("card_name")) or spelling, "country_norm": country,
                                     "activity": act, "destination_id": a.get("destination_id"),
                                     "card_id": a.get("card_id")})
    return idx


def snapshot_index(drafts, norm):
    """{component id: old place} from the trip_drafts projections (the newest entry with a tour key wins)."""
    idx = {}
    for d in drafts:
        raw = _payload(d["itinerary"]) if not isinstance(d["itinerary"], list) else d["itinerary"]
        if not isinstance(raw, list):
            continue
        for e in raw:
            if not isinstance(e, dict) or not e.get("component_id") or not e.get("source_tour_id"):
                continue
            spelling = norm.get(e.get("name")) or ""
            day = e.get("source_day_index")
            idx[str(e["component_id"])] = {
                "source_id": str(e["source_tour_id"]), "day": int(day) if day is not None else None,
                "spelling": spelling, "link": spelling, "country_norm": None, "activity": None,
                "destination_id": str(e["destination_id"]) if e.get("destination_id") else None, "card_id": None}
    return idx


def _key(kind, *, spelling, link, country, destination, card):
    if kind == "destination":
        return str(destination) if destination else None
    if kind == "card":
        return str(card) if card else None
    name = spelling if kind == "spelling" else link
    return f"{name}|{country or '*'}" if name else None


def pick_target(old, rows):
    """(component id, rule) of the current component of the same place, or (None, None). rows: the source's
    geo.tour_place rows. Same rule order and tie-break as CIS components.redirect_dropped."""
    day = old.get("day")
    for kind in RULES:
        k = _key(kind, spelling=old.get("spelling"), link=old.get("link"), country=old.get("country_norm"),
                 destination=old.get("destination_id"), card=old.get("card_id"))
        if not k:
            continue
        cands = []
        for r in rows:
            rk = _key(kind, spelling=r["spelling"], link=r.get("name_norm") or "",
                      country=r.get("country_norm") if old.get("country_norm") else None,
                      destination=r.get("destination_id"), card=r.get("place_card_id"))
            if rk == k:
                cands.append(r)
        if cands:
            best = min(cands, key=lambda r: (abs(int(r["day_index"]) - day) if day is not None else 0,
                                             r.get("activity") != old.get("activity"), int(r["day_index"]),
                                             r["component_id"]))
            return best["component_id"], kind
    return None, None


def follow_redirect(cid, redirects, has_row):
    """The redirect target of `cid` that has a geo.tour_place row (chains followed), else None."""
    seen = set()
    for _ in range(REDIRECT_HOPS):
        nxt = redirects.get(cid)
        if not nxt or nxt in seen:
            return None
        if nxt in has_row:
            return nxt
        seen.add(nxt)
        cid = nxt
    return None


def plan(raw_ids, id_map, places, redirects, rederived, snapshots, live):
    """Decisions for every raw id whose current id has no tour_place row.

    Returns {raw: decision} where decision = {raw, cur, in_map, source_id, recovered_by, target, rule,
    matched_by, reason}. Pure: the tests drive it directly. places: PLACES_SQL rows with `spelling` (name_norm of
    the itinerary name) added; redirects: {old: new} over every source; live: set of live source ids."""
    by_id = {r["component_id"]: r for r in places}
    by_source = {}
    for r in places:
        by_source.setdefault(r["source_id"], []).append(r)
    decisions = {}
    for raw in sorted(raw_ids):
        cur = id_map.get(raw, raw)
        if cur in by_id:
            continue
        d = {"raw": raw, "cur": cur, "in_map": raw in id_map, "source_id": None, "recovered_by": None,
             "target": None, "rule": None, "matched_by": None, "reason": None}
        t = follow_redirect(cur, redirects, by_id)
        if t:
            d.update(source_id=by_id[t]["source_id"], recovered_by="redirect", target=t, rule="redirect",
                     matched_by="name")
            decisions[raw] = d
            continue
        old = rederived.get(cur) or rederived.get(raw)
        d["recovered_by"] = "rederived" if old else None
        if old is None:
            old = snapshots.get(cur) or snapshots.get(raw)
            d["recovered_by"] = "snapshot" if old else None
        if old is None:
            d["reason"] = "not_recoverable"
            decisions[raw] = d
            continue
        d["source_id"] = old["source_id"]
        rows = by_source.get(old["source_id"]) or []
        if not rows:
            d["reason"] = "source_not_live" if old["source_id"] not in live else "source_not_built"
            decisions[raw] = d
            continue
        target, rule = pick_target(old, rows)
        if target is None:
            d["reason"] = "no_same_place"
        else:
            d.update(target=target, rule=rule, matched_by="destination" if rule == "destination" else "name")
        decisions[raw] = d
    return decisions


def _bucket(pin, d, map_from, built_at):
    if map_from is not None and pin["created_at"] < map_from and d["in_map"]:
        return "before_flip"
    b = built_at.get(d["source_id"]) if d["source_id"] else None
    if b is None:
        return "source_unknown"
    return "before_current_build" if pin["created_at"] < b else "after_current_build"


async def _pinned_fetch(conn, sql, *args):
    async with conn.transaction():
        await conn.execute("SELECT set_config('app.tenant_id', $1, true)", AA_TENANT_ID)
        return [dict(r) for r in await conn.fetch(sql, *args)]


async def main(conn):
    out("start", read_only=READ_ONLY)
    if not await conn.fetchval(ID_MAP_EXISTS_SQL):
        out("refuse", what="id_map_missing", hint="apply tp-017 first")
        return 1
    events = await _pinned_fetch(conn, EVENTS_SQL)
    id_rows = await _pinned_fetch(conn, MAP_SQL)
    drafts = await _pinned_fetch(conn, DRAFTS_SQL)
    places = await _pinned_fetch(conn, PLACES_SQL)
    builds = await _pinned_fetch(conn, BUILDS_SQL)
    live = {r["source_id"] for r in await _pinned_fetch(conn, LIVE_SQL)}
    id_map = {r["old_id"]: r["new_id"] for r in id_rows}
    map_from = min((r["created_at"] for r in id_rows), default=None)
    redirects, built_at, countries = {}, {}, {}
    for b in builds:
        built_at[b["source_id"]] = b["built_at"]
        redirects.update(_payload(b["redirects"]) if b["redirects"] else {})
    sources = sorted({b["source_id"] for b in builds} | {r["source_id"] for r in places})
    versions = {r["tour_id"]: r["source_id"] for r in await _pinned_fetch(conn, VERSIONS_SQL, AA_TENANT_ID, sources)}
    atoms = await _pinned_fetch(conn, ATOMS_SQL, [uuid.UUID(t) for t in sorted(versions)]) if versions else []

    pins, raw_ids, keys = pins_and_ids(events)
    names = {a["place"] for a in atoms} | {a["card_name"] for a in atoms if a.get("card_name")}
    names |= {r["name"] for r in places}
    names |= {b["country"] for b in builds if b.get("country")}
    for d in drafts:
        it = _payload(d["itinerary"]) if not isinstance(d["itinerary"], list) else d["itinerary"]
        names |= {e.get("name") for e in (it if isinstance(it, list) else []) if isinstance(e, dict) and e.get("name")}
    norm = {r["name"]: r["norm"] for r in await _pinned_fetch(conn, NAME_NORM_SQL, sorted(n for n in names if n))}
    for r in places:
        r["spelling"] = norm.get(r["name"]) or ""
        countries.setdefault(r["source_id"], set()).add(r["country_norm"])
    for b in builds:
        if b.get("country") and norm.get(b["country"]):
            countries.setdefault(b["source_id"], set()).add(norm[b["country"]])
    rederived = rederive_index(atoms, versions, countries, norm)
    snapshots = snapshot_index(drafts, norm)
    out("inputs", events=len(events), pins=len(pins), raw_ids=len(raw_ids), map_rows=len(id_map),
        map_fill_from=map_from, place_rows=len(places), built_sources=len(builds), live_sources=len(live),
        redirect_entries=len(redirects), versions=len(versions), atoms=len(atoms), rederivable_ids=len(rederived),
        snapshot_entries=len(snapshots))
    for k, n in sorted(keys.items()):
        out("payload_keys", event="add_component", keys=k, n=n)

    decisions = plan(raw_ids, id_map, places, redirects, rederived, snapshots, live)
    has_row = {r["component_id"] for r in places}
    dangling = [p for p in pins if id_map.get(p["raw"], p["raw"]) not in has_row]
    out("pins", pins=len(pins), trips=len({p["trip_id"] for p in pins}), dangling=len(dangling),
        trips_with_dangling=len({p["trip_id"] for p in dangling}))
    origin, timing, snap = {}, {}, {"with_snapshot": 0, "without_snapshot": 0}
    for p in dangling:
        d = decisions[p["raw"]]
        if d["in_map"]:
            o = "pre_flip_mapped"            # an old TripPlanner id AA-847 mapped; its catalog id dropped since
        elif map_from is not None and p["created_at"] < map_from:
            o = "pre_flip_unmapped"          # an old TripPlanner id AA-847 found no match for (dangling since 22/10)
        else:
            o = "catalog_id"                 # a catalog id a later rebuild dropped
        origin[o] = origin.get(o, 0) + 1
        b = _bucket(p, d, map_from, built_at)
        timing[b] = timing.get(b, 0) + 1
        has = (d["cur"] in snapshots) or (p["raw"] in snapshots)
        snap["with_snapshot" if has else "without_snapshot"] += 1
    out("dangling_origin", **origin)
    out("dangling_timing", **timing)
    out("dangling_snapshot", **snap)
    rec, rules, reasons = {}, {}, {}
    for d in decisions.values():
        rec[d["recovered_by"] or "none"] = rec.get(d["recovered_by"] or "none", 0) + 1
        if d["target"]:
            rules[d["rule"]] = rules.get(d["rule"], 0) + 1
        else:
            reasons[d["reason"]] = reasons.get(d["reason"], 0) + 1
    out("recover", ids=len(decisions), **rec)
    for r, n in sorted(rules.items()):
        out("match", rule=r, n=n)
    for r, n in sorted(reasons.items()):
        out("unmatched", reason=r, n=n)
    inserts = [d for d in decisions.values() if d["target"] and not d["in_map"]]
    updates = [d for d in decisions.values() if d["target"] and d["in_map"]]
    fixed = {d["raw"] for d in inserts + updates}
    out("plan", insert=len(inserts), update=len(updates), unmatched=len(decisions) - len(fixed))
    out("expected_after", dangling=sum(1 for p in dangling if p["raw"] not in fixed))

    if READ_ONLY or not fixed:
        out("done", read_only=READ_ONLY, written=0)
        return 0
    inserted = updated = skipped = 0
    async with conn.transaction():
        try:
            async with conn.transaction():
                await conn.execute("SET LOCAL ROLE tripplanner")
        except Exception as e:  # noqa: BLE001
            out("refuse", what="set_role", role="tripplanner", error=type(e).__name__)
            return 1
        await conn.execute("SET LOCAL ROLE tripplanner")
        for d in inserts:
            status = await conn.execute(INSERT_SQL, d["raw"], d["target"], d["matched_by"])
            if str(status).endswith(" 1"):
                inserted += 1
                out("restore", op="insert", old_id=d["raw"])
            else:
                skipped += 1
    if updates:
        async with conn.transaction():
            try:
                async with conn.transaction():
                    await conn.execute("SET LOCAL ROLE tp_owner")
            except Exception as e:  # noqa: BLE001
                out("refuse", what="set_role", role="tp_owner", error=type(e).__name__, updates_left=len(updates))
                out("apply", inserted=inserted, updated=0, skipped_changed=skipped)
                return 1
            await conn.execute("SET LOCAL ROLE tp_owner")
            for d in updates:
                status = await conn.execute(UPDATE_SQL, d["raw"], d["cur"], d["target"], d["matched_by"])
                if str(status).endswith(" 1"):
                    updated += 1
                    out("restore", op="update", old_id=d["raw"], prev_new_id=d["cur"])
                else:
                    skipped += 1
    out("apply", inserted=inserted, updated=updated, skipped_changed=skipped)
    out("done", read_only=READ_ONLY, written=inserted + updated)
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
