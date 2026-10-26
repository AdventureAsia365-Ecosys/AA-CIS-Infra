"""AA-990: re-point TripPlanner saved pins that a CIS place rebuild left dangling (tripplanner.component_id_map).

Dispatch: DB Migrate, mode=run-script, script=db/scripts/aa990_component_id_backfill.py. Merged with
`READ_ONLY = True`: a DRY RUN that prints counts only (no write, can run during a wave). The apply is a follow-up PR
that sets `READ_ONLY = False` (one line). Re-runnable: a pin that resolves is left alone, so a second apply writes 0.

Why (S252, live Dev): 322 of 371 pins (add_component events, 99 of 103 trips) had no geo.tour_place row after the
S1 v2 place re-sync of 123 tours. A component id is uuid5(source, day, itinerary spelling, country, activity) at a
place's first build; AA-989 keeps an id across a rebuild only on an unambiguous one-to-one pair, so a respelt, retyped,
moved or merged place dropped the pin. One-time: since CIS 285 (decision D1) every rebuild writes its drops to
geo.component_redirect (catalog.v_component_redirect) and TripPlanner follows them; this script covers the pins
dropped BEFORE that.

Resolution = TripPlanner's (backend/shared/component_ids.id_map, AA-990): from the pinned (raw) id, at each hop
tripplanner.component_id_map first, else geo.component_redirect (when CIS 285 is applied), at most 5 hops,
cycle-safe. A pin whose chain ends at an id with no geo.tour_place row (`end`) dangles. The place `end` (or an
earlier id of its chain) was is recovered from, in order:
  rederived  uuid5 recomputed from every atom ever written for the tour (soft-deleted ones included) of every built
             source: (source, itinerary_day, geo.name_norm(place), country, activity) for the 8 activities and every
             country spelling the source used — the exact id the build minted from those atoms. Deterministic: when
             atoms of different versions mint the same id but disagree on the link name, destination, place card or
             locality, that field is None (never the first row's value; the locality then counts as unknown);
  snapshot   the trip_drafts projection entries of that id (name, source_tour_id, source_day_index, destination_id;
             AA-986 L6 keeps it for a stop the catalog stopped serving). Deterministic the same way: a field the
             entries of one id disagree on is None; a disagreeing tour makes the id not recoverable from the
             snapshots (reason=snapshot_conflict when nothing else recovers the chain).
Then the current component of the same source for the same place (the CIS rule, components.redirect_dropped):
destination → place card → spelling + country → link name + country, any day, the nearest day first, then the same
activity, then the smaller id. A generic name ('Night Market', 'Old Quarter': a different place in every town) matches
by spelling or link name only in the same locality: generic = the candidate row's locality_norm is set (its link name
was generic when CIS built it) or the name is the link name of any generic row in geo.tour_place (Infra has no copy of
CIS is_generic_name). The old place's locality: its place card's locality, else the current geo.tour_day.anchor_norm of
that day (the overnight town CIS used as the locality) ONLY when an atom of the same old version on that day names
that town (place or card locality) — a rewrite that moved the days must not hand the old stop the new town. With no
locality the id stays unmatched (reason=generic_no_locality), never guessed by day distance.

Writes (apply only, decision D3): INSERT only, as `tripplanner` (the AA-847 fill path; tp-017 keeps the map
insert-only): one row (end, target, matched_by) per dangling chain end, ON CONFLICT DO NOTHING. TripPlanner follows
the chain raw → … → end → target. matched_by keeps the tp-017 CHECK: 'destination' for the destination rule, 'name'
otherwise.

Output (every line starts with `SCRIPT `; counts, rules and component ids only — no trip, session or person data):
  SCRIPT start / inputs / pins / payload_keys / dangling_origin / dangling_timing / dangling_snapshot / recover /
  match rule=<r> n=<n> / unmatched reason=<r> n=<n> / plan insert=<n> unmatched=<n> / expected_after dangling=<n>
  SCRIPT restore op=insert old_id=<id>        (apply only: the undo)
  SCRIPT apply inserted=<n> skipped_changed=<n> / done
Undo: DELETE the `op=insert` old_ids (as tp_owner / master: `tripplanner` has no DELETE).
Returns 1 when the map is missing or (apply) the role switch is refused.
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
NO_LOCALITY = "?"          # CIS geo.tour_place.locality_norm of a generic name with no locality
REDIRECT_HOPS = 5

ID_MAP_EXISTS_SQL = "SELECT to_regclass('tripplanner.component_id_map') IS NOT NULL"
EVENTS_SQL = """
    SELECT trip_id::text AS trip_id, event_type, payload, created_at
      FROM tripplanner.trip_events
     WHERE event_type IN ('add_component', 'remove_component', 'reorder')
"""
MAP_SQL = "SELECT old_id::text AS old_id, new_id::text AS new_id, created_at FROM tripplanner.component_id_map"
# Ordered (trip_drafts is UPDATEd by the app: the heap order can change between the dry run and the apply).
# snapshot_index does not depend on the order anyway (disagreeing entries of one id become None).
DRAFTS_SQL = "SELECT id::text AS id, updated_at, itinerary FROM tripplanner.trip_drafts ORDER BY updated_at, id"
PLACES_SQL = """
    SELECT component_id::text AS component_id, source_id, day_index, name, name_norm, country_norm, locality_norm,
           activity, destination_id::text AS destination_id, place_card_id::text AS place_card_id
      FROM geo.tour_place
"""
DAYS_SQL = "SELECT source_id, day_index, anchor_norm FROM geo.tour_day WHERE anchor_norm IS NOT NULL"
BUILDS_SQL = "SELECT source_id, country, built_at FROM geo.tour_build"
# CIS 285 (D1): the redirects every rebuild writes since. Read only when the table exists.
REDIRECTS_EXISTS_SQL = "SELECT to_regclass('geo.component_redirect') IS NOT NULL"
REDIRECTS_SQL = "SELECT old_id::text AS old_id, new_id::text AS new_id FROM geo.component_redirect"
LIVE_SQL = "SELECT source_id FROM catalog.v_tour"
VERSIONS_SQL = """
    SELECT rt.tour_id::text AS tour_id, COALESCE(rt.source_group_id, rt.tour_id)::text AS source_id, rt.country
      FROM silver_aa_internal.raw_tours rt
     WHERE rt.tenant_id = $1::uuid AND COALESCE(rt.source_group_id, rt.tour_id)::text = ANY($2::text[])
"""
# Every atom ever written for those versions (soft-deleted included): the ids of earlier builds came from them.
ATOMS_SQL = """
    SELECT a.tour_id::text AS tour_id, a.itinerary_day AS day, btrim(a.place) AS place,
           apc.card_id::text AS card_id, pc.display_name AS card_name, pc.locality AS card_locality,
           pc.destination_id::text AS destination_id
      FROM acp_contract.tour_atoms a
      LEFT JOIN acp_shared.atom_place_card apc ON apc.atom_id = a.atom_id
      LEFT JOIN acp_shared.place_card pc ON pc.card_id = apc.card_id
     WHERE a.tour_id = ANY($1::uuid[]) AND a.itinerary_day IS NOT NULL
       AND a.place IS NOT NULL AND btrim(a.place) <> ''
     ORDER BY a.tour_id, a.itinerary_day, btrim(a.place), apc.card_id NULLS FIRST, a.atom_id
"""
NAME_NORM_SQL = "SELECT x AS name, geo.name_norm(x) AS norm FROM unnest($1::text[]) AS x"
INSERT_SQL = """
    INSERT INTO tripplanner.component_id_map (old_id, new_id, matched_by)
    VALUES ($1::uuid, $2::uuid, $3)
    ON CONFLICT (old_id) DO NOTHING
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


def day_towns(atoms, norm):
    """{(tour_id, day): {name_norm of every place and card locality the version's atoms of that day name}}."""
    towns = {}
    for a in atoms:
        got = towns.setdefault((a["tour_id"], int(a["day"])), set())
        for v in (a.get("place"), a.get("card_locality")):
            if v and norm.get(v):
                got.add(norm[v])
    return towns


def old_locality(atom, sid, norm, anchors, towns):
    """The locality CIS gave this atom's place at the old build, or None when unknown: the card's locality, else the
    current overnight town of that day (anchors: {(source_id, day): anchor_norm}) when an atom of the SAME old version
    on that day names it (towns, from day_towns)."""
    if atom.get("card_locality") and norm.get(atom["card_locality"]):
        return norm[atom["card_locality"]]
    town = (anchors or {}).get((sid, int(atom["day"])))
    if town and town in (towns or {}).get((atom["tour_id"], int(atom["day"])), ()):
        return town
    return None


# Fields of an old place that are not part of the uuid5 key: atoms of different versions (or two atoms of one day)
# mint the same id and can still disagree on them.
AMBIGUOUS_FIELDS = ("link", "destination_id", "card_id", "locality")


def rederive_index(atoms, versions, countries, norm, anchors=None):
    """{uuid5 id: old place} over every atom of every version of each source, all 8 activities, every country.

    atoms: ATOMS_SQL rows; versions: {tour_id: source_id}; countries: {source_id: {country_norm}};
    norm: {text: name_norm}; anchors: {(source_id, day): geo.tour_day.anchor_norm} (the old place's locality).

    Deterministic and conservative: every atom with the same (source, day, spelling, country, activity) mints the
    same id, yet two versions (or a card on one atom only) can disagree on the link name, destination, place card or
    locality. Such a field becomes None (an unknown value counts as a different one) — never the first row's value —
    so the destination / card / link-name rules skip it and a generic name stays unmatched (generic_no_locality)
    instead of being guessed. The result does not depend on the row order (ATOMS_SQL is ordered too)."""
    seen = {}
    towns = day_towns(atoms, norm)
    for a in atoms:
        sid = versions.get(a["tour_id"])
        spelling = norm.get(a["place"]) or ""
        if not sid or not spelling:
            continue
        vals = {"link": norm.get(a.get("card_name")) or spelling, "destination_id": a.get("destination_id"),
                "card_id": a.get("card_id"), "locality": old_locality(a, sid, norm, anchors, towns)}
        for country in sorted(countries.get(sid) or ()):
            for act in ACTIVITIES:
                cid = component_uuid(sid, a["day"], spelling, country, act)
                if cid not in seen:
                    seen[cid] = ({"source_id": sid, "day": int(a["day"]), "spelling": spelling,
                                  "country_norm": country, "activity": act},
                                 {f: set() for f in AMBIGUOUS_FIELDS})
                for f in AMBIGUOUS_FIELDS:
                    seen[cid][1][f].add(vals[f])
    idx = {}
    for cid, (base, fields) in seen.items():
        rec = dict(base)
        for f in AMBIGUOUS_FIELDS:
            rec[f] = next(iter(fields[f])) if len(fields[f]) == 1 else None
        rec["conflicts"] = tuple(f for f in AMBIGUOUS_FIELDS if len(fields[f]) > 1)
        idx[cid] = rec
    return idx


SNAPSHOT_FIELDS = ("source_id", "day", "spelling", "destination_id")


def snapshot_index(drafts, norm):
    """{component id: old place} from the trip_drafts projections (DRAFTS_SQL rows).

    Deterministic and conservative, like rederive_index: AA-989 keeps an id across a respelling, so two drafts can
    hold a different name, day or destination for the same id. Every entry of an id (with a tour key) is gathered;
    a field the entries disagree on (a missing value counts as a different one) becomes None — never the last row's
    value. A disagreeing source_id makes the id not recoverable from the snapshots (source_id None; plan() skips it
    and reports reason=snapshot_conflict when nothing else recovers the chain); a disagreeing spelling turns the
    spelling / link-name rules off for it ('' → no key). The result does not depend on the row order."""
    seen = {}
    for d in drafts:
        raw = _payload(d["itinerary"]) if not isinstance(d["itinerary"], list) else d["itinerary"]
        if not isinstance(raw, list):
            continue
        for e in raw:
            if not isinstance(e, dict) or not e.get("component_id") or not e.get("source_tour_id"):
                continue
            day = e.get("source_day_index")
            vals = {"source_id": str(e["source_tour_id"]), "day": int(day) if day is not None else None,
                    "spelling": norm.get(e.get("name")) or "",
                    "destination_id": str(e["destination_id"]) if e.get("destination_id") else None}
            fields = seen.setdefault(str(e["component_id"]), {f: set() for f in SNAPSHOT_FIELDS})
            for f in SNAPSHOT_FIELDS:
                fields[f].add(vals[f])
    idx = {}
    for cid, fields in seen.items():
        one = {f: next(iter(v)) if len(v) == 1 else None for f, v in fields.items()}
        spelling = one["spelling"] or ""
        idx[cid] = {"source_id": one["source_id"], "day": one["day"], "spelling": spelling, "link": spelling,
                    "country_norm": None, "activity": None, "destination_id": one["destination_id"], "card_id": None,
                    "locality": None, "conflicts": tuple(f for f in SNAPSHOT_FIELDS if len(fields[f]) > 1)}
    return idx


def _key(kind, *, spelling, link, country, destination, card):
    if kind == "destination":
        return str(destination) if destination else None
    if kind == "card":
        return str(card) if card else None
    name = spelling if kind == "spelling" else link
    return f"{name}|{country or '*'}" if name else None


def generic_names(places):
    """Link names CIS built as generic (locality_norm set) anywhere in the catalog: Infra's stand-in for CIS
    is_generic_name when it judges an old spelling / link name."""
    return {r.get("name_norm") for r in places if r.get("locality_norm") and r.get("name_norm")}


def _locality_ok(kind, old, row, generic):
    """(match allowed, skipped because the old locality is unknown). Destination / card: always allowed."""
    if kind not in ("spelling", "link_name"):
        return True, False
    name = old.get("spelling") if kind == "spelling" else old.get("link")
    is_generic = name in generic or (kind == "link_name" and bool(row.get("locality_norm")))
    if not is_generic:
        return True, False
    loc = old.get("locality")
    row_loc = row.get("locality_norm") or ""
    if not loc:
        return False, True
    return bool(row_loc) and row_loc != NO_LOCALITY and row_loc == loc, False


def pick_target(old, rows, generic=frozenset()):
    """(component id, rule, reason) of the current component of the same place; (None, None, reason) when none, reason
    'generic_no_locality' when only a same-named generic component was found and the old locality is unknown, else
    'no_same_place'. rows: the source's geo.tour_place rows; generic: generic_names(). Same rule order, locality rule
    and tie-break as CIS components.redirect_dropped."""
    day = old.get("day")
    skipped_generic = False
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
            if rk != k:
                continue
            ok, unknown = _locality_ok(kind, old, r, generic)
            skipped_generic = skipped_generic or unknown
            if ok:
                cands.append(r)
        if cands:
            best = min(cands, key=lambda r: (abs(int(r["day_index"]) - day) if day is not None else 0,
                                             r.get("activity") != old.get("activity"), int(r["day_index"]),
                                             r["component_id"]))
            return best["component_id"], kind, None
    return None, None, "generic_no_locality" if skipped_generic else "no_same_place"


def resolve_chain(raw, id_map, redirects):
    """[raw, …, end]: TripPlanner's resolution (component_ids.id_map): at each hop the id map first, else the CIS
    redirect; at most REDIRECT_HOPS hops; a cycle stops at the last id before it repeats."""
    path = [raw]
    for _ in range(REDIRECT_HOPS):
        cur = path[-1]
        nxt = id_map.get(cur) or redirects.get(cur)
        if not nxt or nxt == cur or nxt in path:
            break
        path.append(nxt)
    return path


def plan(raw_ids, id_map, places, redirects, rederived, snapshots, live, generic=None):
    """Decisions for every raw id whose chain ends at an id with no tour_place row.

    Returns {raw: decision} where decision = {raw, end, path, in_map, source_id, recovered_by, target, rule,
    matched_by, reason}. Several raw ids can share one `end` (one insert fixes them all). Pure: the tests drive it
    directly. places: PLACES_SQL rows with `spelling` (name_norm of the itinerary name) added; redirects: {old: new}
    of geo.component_redirect; live: set of live source ids; generic: generic_names() (default: from places)."""
    generic = generic_names(places) if generic is None else generic
    by_id = {r["component_id"]: r for r in places}
    by_source = {}
    for r in places:
        by_source.setdefault(r["source_id"], []).append(r)
    decisions = {}
    for raw in sorted(raw_ids):
        path = resolve_chain(raw, id_map, redirects)
        end = path[-1]
        if end in by_id:
            continue
        d = {"raw": raw, "end": end, "path": path, "in_map": raw in id_map, "source_id": None, "recovered_by": None,
             "target": None, "rule": None, "matched_by": None, "reason": None}
        if end in id_map:                     # the chain stopped on a cycle: never add a second row for `end`
            d["reason"] = "chain_cycle"
            decisions[raw] = d
            continue
        old = None
        for cid in reversed(path):            # the id nearest the end that we can recover
            old = rederived.get(cid)
            if old is not None:
                d["recovered_by"] = "rederived"
                break
        snapshot_conflict = False
        if old is None:
            for cid in reversed(path):
                snap = snapshots.get(cid)
                if snap is not None and snap.get("source_id") is None:
                    snapshot_conflict = True      # drafts disagree on the tour: never pick one of them
                    continue
                if snap is not None:
                    old = snap
                    d["recovered_by"] = "snapshot"
                    break
        if old is None:
            d["reason"] = "snapshot_conflict" if snapshot_conflict else "not_recoverable"
            decisions[raw] = d
            continue
        d["source_id"] = old["source_id"]
        rows = by_source.get(old["source_id"]) or []
        if not rows:
            d["reason"] = "source_not_live" if old["source_id"] not in live else "source_not_built"
            decisions[raw] = d
            continue
        target, rule, reason = pick_target(old, rows, generic)
        if target is None:
            d["reason"] = reason
        else:
            d.update(target=target, rule=rule, matched_by="destination" if rule == "destination" else "name")
        decisions[raw] = d
    return decisions


def inserts_of(decisions):
    """(one (end, target, matched_by) per chain end, the ends left out). Raw ids that reach one end agree whenever the
    end itself is recoverable; when only earlier ids of their chains are and those point at different targets, the
    end is left out (never guessed; printed as unmatched reason=conflicting_end). Deterministic."""
    by_end, bad = {}, set()
    for d in sorted(decisions.values(), key=lambda x: x["raw"]):
        if not d["target"]:
            continue
        got = by_end.setdefault(d["end"], (d["end"], d["target"], d["matched_by"]))
        if got[1] != d["target"]:
            bad.add(d["end"])
    return [v for k, v in sorted(by_end.items()) if k not in bad], bad


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
    days = await _pinned_fetch(conn, DAYS_SQL)
    builds = await _pinned_fetch(conn, BUILDS_SQL)
    live = {r["source_id"] for r in await _pinned_fetch(conn, LIVE_SQL)}
    has_redirects = bool(await conn.fetchval(REDIRECTS_EXISTS_SQL))
    redirect_rows = await _pinned_fetch(conn, REDIRECTS_SQL) if has_redirects else []
    id_map = {r["old_id"]: r["new_id"] for r in id_rows}
    map_from = min((r["created_at"] for r in id_rows), default=None)
    redirects = {r["old_id"]: r["new_id"] for r in redirect_rows}
    built_at, countries = {}, {}
    for b in builds:
        built_at[b["source_id"]] = b["built_at"]
    sources = sorted({b["source_id"] for b in builds} | {r["source_id"] for r in places})
    versions = {r["tour_id"]: r["source_id"] for r in await _pinned_fetch(conn, VERSIONS_SQL, AA_TENANT_ID, sources)}
    atoms = await _pinned_fetch(conn, ATOMS_SQL, [uuid.UUID(t) for t in sorted(versions)]) if versions else []

    pins, raw_ids, keys = pins_and_ids(events)
    names = {a["place"] for a in atoms} | {a["card_name"] for a in atoms if a.get("card_name")}
    names |= {a["card_locality"] for a in atoms if a.get("card_locality")}
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
    anchors = {(r["source_id"], int(r["day_index"])): r["anchor_norm"] for r in days}
    rederived = rederive_index(atoms, versions, countries, norm, anchors)
    snapshots = snapshot_index(drafts, norm)
    out("inputs", events=len(events), pins=len(pins), raw_ids=len(raw_ids), map_rows=len(id_map),
        map_fill_from=map_from, place_rows=len(places), built_sources=len(builds), live_sources=len(live),
        redirect_table=has_redirects, redirect_entries=len(redirects), versions=len(versions), atoms=len(atoms),
        rederivable_ids=len(rederived), snapshot_entries=len(snapshots), generic_names=len(generic_names(places)),
        rederived_with_locality=sum(1 for v in rederived.values() if v.get("locality")),
        rederived_conflicting=sum(1 for v in rederived.values() if v.get("conflicts")),
        snapshot_conflicting=sum(1 for v in snapshots.values() if v.get("conflicts")))
    for k, n in sorted(keys.items()):
        out("payload_keys", event="add_component", keys=k, n=n)

    decisions = plan(raw_ids, id_map, places, redirects, rederived, snapshots, live)
    has_row = {r["component_id"] for r in places}
    dangling = [p for p in pins if resolve_chain(p["raw"], id_map, redirects)[-1] not in has_row]
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
        has = any(c in snapshots for c in d["path"])
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
    inserts, conflicting = inserts_of(decisions)
    fixed_ends = {e for e, _, _ in inserts}
    if conflicting:
        out("unmatched", reason="conflicting_end", n=len(conflicting))
    out("plan", insert=len(inserts), unmatched=sum(1 for d in decisions.values() if d["end"] not in fixed_ends))
    out("expected_after", dangling=sum(1 for p in dangling if decisions[p["raw"]]["end"] not in fixed_ends))

    if READ_ONLY or not inserts:
        out("done", read_only=READ_ONLY, written=0)
        return 0
    inserted = skipped = 0
    async with conn.transaction():
        try:
            async with conn.transaction():
                await conn.execute("SET LOCAL ROLE tripplanner")
        except Exception as e:  # noqa: BLE001
            out("refuse", what="set_role", role="tripplanner", error=type(e).__name__)
            return 1
        await conn.execute("SET LOCAL ROLE tripplanner")
        for end, target, matched_by in inserts:
            status = await conn.execute(INSERT_SQL, end, target, matched_by)
            if str(status).endswith(" 1"):
                inserted += 1
                out("restore", op="insert", old_id=end)
            else:
                skipped += 1
    out("apply", inserted=inserted, skipped_changed=skipped)
    out("done", read_only=READ_ONLY, written=inserted)
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
