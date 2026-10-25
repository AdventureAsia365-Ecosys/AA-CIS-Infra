"""AA-991 downstream freshness probe (read-only): does every layer built on a tour's atoms follow its source?

Question (S251, after the AA-645 S1 catalogue rewrite): when a Master is re-published or a tour is paused / retired,
do atoms, segments, ranking, routes, the place layer (geo.tour_place, place-card links), T8 angle requests and SEO
context follow by themselves? The S251 answer took a hand-run coverage query (root .tmp-session/s251/audit-s1prop);
this probe runs the same questions every night and says which links are stale.

Runs nightly as workflow DB Freshness Probe (.github/workflows/db-freshness-probe.yml) through the DB Migrate
run-script mechanism (one-off ECS task, master login, READ_ONLY); db/freshness_gate.py reads the log. Also
dispatchable by hand: DB Migrate, mode=run-script, script=db/scripts/aa991_freshness_probe.py. Local test:
`python3 <this file> <DSN>`. main() always returns 0; the gate reads the verdict line.

Read as `cis_app` (SET LOCAL ROLE inside the read-only snapshot): the S251 baseline was measured as cis_app, every
table read here has a cis_app grant and, where RLS is on, a `<table>_cis_app_all` policy. A refused role switch is an
error (red), never a silent read as the master.

"Tour changed" = GREATEST(published_tours.updated_at, v_tour_liveness.changed_at): updated_at moves only on a Master
publish (lifecycle service `publish`), changed_at on pause / retire / restore. A stale link is `aged` when its tour
changed more than STALE_AFTER_HOURS before the probe; that is what the gate enforces (AA-991: Dev has no traffic, so
no grace beyond the job run time).

Metrics (METRICS below; `gate`: `stale` = a link that must follow its source automatically, counts when the gate
enforces; `info` = coverage or by-design number, reported against the S251 baseline, never red):
  atoms_older_than_master              stale  active tours whose newest active atom is older than the Master text
  active_tours_without_atoms           stale  active tours with no active atom
  active_atoms_without_segment         info   active atoms in no segment (incl. transit / unnamed places, which
                                              never form one: services/acp_contract/segment_matching.forms_segment)
  tours_with_place_atoms_but_no_segment stale active tours with place atoms but not one atom in a segment
                                              (segment match never ran for the tour: the AA-695 failure)
  orphan_segments                      stale  segments with no active atom, no current ranking row, no current route
  ranking_missing                      stale  tours with a (tour, segment) pair of active atoms and no current
                                              atom_ranking row for it (run_atom_ranking ranks every such pair)
  ranking_off_active_pairs             stale  tours with a current atom_ranking row on a pair that no longer exists
  active_tours_without_ranking         info   active tours with no current atom_ranking row at all
  routes_missing                       stale  tours where route detection would build a route that is not current
  routes_differ                        stale  tours with a current route route detection would not build now (or
                                              with other segments), incl. current routes of tours not active
  active_tours_without_route           info   active tours with no current route (many have no 2-day run)
  current_routes_older_than_atoms      info   S251 query: current route created before the tour's newest atom
                                              (an unchanged route is never rewritten, so this is a weak signal)
  routes_with_dead_segment             stale  current routes listing a segment with no active atom
  geo_tour_place_rows_on_inactive_atoms info  S251 query: geo.tour_place rows none of whose atom_ids is active
  geo_tour_place_stale_rows            stale  the same, rows of active tours only
  place_card_links_missing             stale  active place atoms without an atom_place_card row, in tours whose
                                              atoms were carded before (a re-atomize that lost the links)
  active_place_atoms_without_card_link info   every active place atom without an atom_place_card row (AA-784)
  tenant_versions_older_than_master    info   S251 query: tenant versions created before their Master's update
                                              (by design: AA-990 / AA-986, the tenant is told, nothing overwritten)
  angle_gate_requests_on_inactive_atoms stale acp_shared.angle_gate_request rows on an atom that is not active
  seo_context_expired                  info   S251 query: seo_context rows past expires_at (all tours)
  seo_context_expired_active_tours     stale  the same, active tours only

Routes and ranking are checked by parity, not timestamps: derive_routes() below is a verbatim port of
AA-CIS-App services/acp_contract/route_detection.py (derive_routes / _runs / _spans and LEAST_DAYS, LEAST_PLACES,
MOST_DAYS); MOMENTS_SQL is that module's run_route_detection() read. A change there must change this file too.

Output (ids and counts only; no row text):
  SCRIPT role read_as=<role> login=<login>
  SCRIPT metric name=<m> gate=<stale|info> n=<n> aged=<n> sample=<ids>
  SCRIPT totals <k>=<n> ...                     (the visibility floor's inputs and the catalogue size)
  SCRIPT jobs kind=<k> status=<s> n=<n>          (propagation jobs queued / running at probe time)
  SCRIPT verdict stale=<metrics with n>0> stale_aged=<sum of aged> errors=<n> list=<stale metrics with aged>0>
  SCRIPT json[<i>/<n>] <part>|                   (everything as one JSON object, parts of at most JSON_CHUNK chars)
The job log is public (Actions): an error entry carries the exception class and SQLSTATE only; the server message is
kept only for SQLSTATE class 42 (undefined / syntax / privilege: names objects, never row values).
"""

import json
import re
import sys
from datetime import datetime, timezone

READ_ONLY = True

READ_ROLE = "cis_app"
STALE_AFTER_HOURS = 24
SAMPLE = 5
JSON_CHUNK = 8000
SAFE_ID_RE = re.compile(r"^[A-Za-z0-9:_.-]{1,96}$")

# Route detection constants, verbatim from AA-CIS-App services/acp_contract/route_detection.py.
LEAST_DAYS = 2
LEAST_PLACES = 2
MOST_DAYS = 5

# Last change of every tour that has a Master row: Master publish or served-state change.
CHG = """chg AS (
    SELECT pt.tour_id,
           (pt.master_status = 'active' AND pt.deleted_at IS NULL) AS active,
           GREATEST(pt.updated_at, lv.changed_at) AS changed_at
      FROM gold_aa_internal.published_tours pt
      LEFT JOIN (SELECT tour_id, max(changed_at) AS changed_at FROM gold_aa_internal.v_tour_liveness
                  GROUP BY tour_id) lv ON lv.tour_id = pt.tour_id)"""
ACTIVE_PT = "pt.master_status = 'active' AND pt.deleted_at IS NULL"
SEGMENTED = """SELECT 1 FROM acp_contract.atom_segment_member m
                 JOIN acp_contract.v_active_tour_atoms a ON a.atom_id = m.atom_id"""
PLACE_ATOM = "a.place IS NOT NULL AND btrim(a.place) <> ''"

# name -> (gate, unit, inner query returning text `id` + boolean `aged`; $1 = the cutoff timestamptz).
METRICS = {
    "atoms_older_than_master": ("stale", "tours", f"""
        SELECT pt.tour_id::text AS id, c.changed_at < $1 AS aged
          FROM gold_aa_internal.published_tours pt
          JOIN chg c ON c.tour_id = pt.tour_id
          JOIN acp_contract.v_active_tour_atoms a ON a.tour_id = pt.tour_id
         WHERE {ACTIVE_PT}
         GROUP BY pt.tour_id, pt.updated_at, c.changed_at
        HAVING max(coalesce(a.updated_at, a.created_at)) < pt.updated_at"""),
    "active_tours_without_atoms": ("stale", "tours", f"""
        SELECT pt.tour_id::text AS id, c.changed_at < $1 AS aged
          FROM gold_aa_internal.published_tours pt
          JOIN chg c ON c.tour_id = pt.tour_id
         WHERE {ACTIVE_PT}
           AND NOT EXISTS (SELECT 1 FROM acp_contract.v_active_tour_atoms a WHERE a.tour_id = pt.tour_id)"""),
    "active_atoms_without_segment": ("info", "atoms", """
        SELECT a.atom_id AS id, c.changed_at < $1 AS aged
          FROM acp_contract.v_active_tour_atoms a
          JOIN chg c ON c.tour_id = a.tour_id
         WHERE NOT EXISTS (SELECT 1 FROM acp_contract.atom_segment_member m WHERE m.atom_id = a.atom_id)"""),
    "tours_with_place_atoms_but_no_segment": ("stale", "tours", f"""
        SELECT a.tour_id::text AS id, c.changed_at < $1 AS aged
          FROM acp_contract.v_active_tour_atoms a
          JOIN chg c ON c.tour_id = a.tour_id
          LEFT JOIN (SELECT DISTINCT atom_id FROM acp_contract.atom_segment_member) m ON m.atom_id = a.atom_id
         WHERE {PLACE_ATOM}
         GROUP BY a.tour_id, c.changed_at
        HAVING count(m.atom_id) = 0"""),
    "orphan_segments": ("stale", "segments", f"""
        SELECT s.segment_id AS id, s.created_at < $1 AS aged
          FROM acp_contract.atom_segment s
         WHERE NOT EXISTS ({SEGMENTED} WHERE m.segment_id = s.segment_id)
           AND NOT EXISTS (SELECT 1 FROM acp_contract.atom_ranking r
                            WHERE r.segment_id = s.segment_id AND r.superseded_at IS NULL)
           AND NOT EXISTS (SELECT 1 FROM acp_contract.route r
                            CROSS JOIN LATERAL jsonb_array_elements_text(r.ordered_segment_ids) e(id)
                            WHERE r.superseded_at IS NULL AND e.id = s.segment_id)"""),
    "ranking_missing": ("stale", "tours", """
        SELECT p.tour_id::text AS id, c.changed_at < $1 AS aged
          FROM (SELECT DISTINCT a.tour_id, m.segment_id
                  FROM acp_contract.v_active_tour_atoms a
                  JOIN acp_contract.atom_segment_member m ON m.atom_id = a.atom_id) p
          JOIN chg c ON c.tour_id = p.tour_id
         WHERE NOT EXISTS (SELECT 1 FROM acp_contract.atom_ranking r
                            WHERE r.tour_id = p.tour_id AND r.segment_id = p.segment_id
                              AND r.superseded_at IS NULL)"""),
    "ranking_off_active_pairs": ("stale", "tours", f"""
        SELECT r.tour_id::text AS id, coalesce(c.changed_at, r.computed_at) < $1 AS aged
          FROM acp_contract.atom_ranking r
          LEFT JOIN chg c ON c.tour_id = r.tour_id
         WHERE r.superseded_at IS NULL
           AND NOT EXISTS ({SEGMENTED} WHERE m.segment_id = r.segment_id AND a.tour_id = r.tour_id)"""),
    "active_tours_without_ranking": ("info", "tours", f"""
        SELECT pt.tour_id::text AS id, c.changed_at < $1 AS aged
          FROM gold_aa_internal.published_tours pt
          JOIN chg c ON c.tour_id = pt.tour_id
         WHERE {ACTIVE_PT}
           AND NOT EXISTS (SELECT 1 FROM acp_contract.atom_ranking r
                            WHERE r.tour_id = pt.tour_id AND r.superseded_at IS NULL)"""),
    "active_tours_without_route": ("info", "tours", f"""
        SELECT pt.tour_id::text AS id, c.changed_at < $1 AS aged
          FROM gold_aa_internal.published_tours pt
          JOIN chg c ON c.tour_id = pt.tour_id
         WHERE {ACTIVE_PT}
           AND NOT EXISTS (SELECT 1 FROM acp_contract.route r
                            WHERE r.tour_id = pt.tour_id AND r.superseded_at IS NULL)"""),
    "current_routes_older_than_atoms": ("info", "tours", """
        SELECT r.tour_id::text AS id, c.changed_at < $1 AS aged
          FROM acp_contract.route r
          JOIN acp_contract.v_active_tour_atoms a ON a.tour_id = r.tour_id
          JOIN chg c ON c.tour_id = r.tour_id
         WHERE r.superseded_at IS NULL
         GROUP BY r.tour_id, r.created_at, c.changed_at
        HAVING max(coalesce(a.updated_at, a.created_at)) > r.created_at"""),
    "routes_with_dead_segment": ("stale", "routes", f"""
        SELECT r.route_id AS id, coalesce(c.changed_at, r.created_at) < $1 AS aged
          FROM acp_contract.route r
          LEFT JOIN chg c ON c.tour_id = r.tour_id
         WHERE r.superseded_at IS NULL
           AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(r.ordered_segment_ids) s(id)
                        WHERE NOT EXISTS ({SEGMENTED} WHERE m.segment_id = s.id))"""),
    "geo_tour_place_rows_on_inactive_atoms": ("info", "rows", """
        SELECT g.component_id::text AS id, coalesce(c.changed_at, g.created_at) < $1 AS aged
          FROM geo.tour_place g
          LEFT JOIN chg c ON c.tour_id = g.tour_id
         WHERE cardinality(g.atom_ids) > 0
           AND NOT EXISTS (SELECT 1 FROM acp_contract.v_active_tour_atoms a WHERE a.atom_id = ANY(g.atom_ids))"""),
    "geo_tour_place_stale_rows": ("stale", "rows", """
        SELECT g.component_id::text AS id, c.changed_at < $1 AS aged
          FROM geo.tour_place g
          JOIN chg c ON c.tour_id = g.tour_id AND c.active
         WHERE cardinality(g.atom_ids) > 0
           AND NOT EXISTS (SELECT 1 FROM acp_contract.v_active_tour_atoms a WHERE a.atom_id = ANY(g.atom_ids))"""),
    "place_card_links_missing": ("stale", "atoms", f"""
        SELECT a.atom_id AS id, c.changed_at < $1 AS aged
          FROM acp_contract.v_active_tour_atoms a
          JOIN chg c ON c.tour_id = a.tour_id
         WHERE {PLACE_ATOM}
           AND NOT EXISTS (SELECT 1 FROM acp_shared.atom_place_card k WHERE k.atom_id = a.atom_id)
           AND EXISTS (SELECT 1 FROM acp_contract.tour_atoms t
                         JOIN acp_shared.atom_place_card k ON k.atom_id = t.atom_id
                        WHERE t.tour_id = a.tour_id)"""),
    "active_place_atoms_without_card_link": ("info", "atoms", f"""
        SELECT a.atom_id AS id, c.changed_at < $1 AS aged
          FROM acp_contract.v_active_tour_atoms a
          JOIN chg c ON c.tour_id = a.tour_id
         WHERE {PLACE_ATOM}
           AND NOT EXISTS (SELECT 1 FROM acp_shared.atom_place_card k WHERE k.atom_id = a.atom_id)"""),
    "tenant_versions_older_than_master": ("info", "versions", """
        SELECT v.id::text AS id, p.updated_at < $1 AS aged
          FROM gold_aa_internal.tenant_tour_versions v
          JOIN gold_aa_internal.published_tours p ON p.id = v.published_tour_id
         WHERE v.created_at < p.updated_at"""),
    "angle_gate_requests_on_inactive_atoms": ("stale", "requests", """
        SELECT r.request_id::text AS id,
               coalesce(GREATEST(c.changed_at, t.updated_at), r.updated_at) < $1 AS aged
          FROM acp_shared.angle_gate_request r
          LEFT JOIN acp_contract.tour_atoms t ON t.atom_id = r.atom_id
          LEFT JOIN chg c ON c.tour_id = t.tour_id
         WHERE NOT EXISTS (SELECT 1 FROM acp_contract.v_active_tour_atoms a WHERE a.atom_id = r.atom_id)"""),
    "seo_context_expired": ("info", "rows", """
        SELECT s.id::text AS id, s.expires_at < $1 AS aged
          FROM silver_aa_internal.seo_context s
         WHERE s.expires_at < now()"""),
    "seo_context_expired_active_tours": ("stale", "tours", """
        SELECT s.tour_id::text AS id, s.expires_at < $1 AS aged
          FROM silver_aa_internal.seo_context s
          JOIN chg c ON c.tour_id = s.tour_id AND c.active
         WHERE s.expires_at < now()"""),
}
# Computed in Python from MOMENTS_SQL + CURRENT_ROUTES_SQL (route parity); listed here for the order and the gate.
ROUTE_METRICS = {"routes_missing": ("stale", "tours"), "routes_differ": ("stale", "tours")}
ORDER = ["atoms_older_than_master", "active_tours_without_atoms", "active_atoms_without_segment",
         "tours_with_place_atoms_but_no_segment", "orphan_segments", "ranking_missing", "ranking_off_active_pairs",
         "active_tours_without_ranking", "routes_missing", "routes_differ", "active_tours_without_route",
         "current_routes_older_than_atoms", "routes_with_dead_segment", "geo_tour_place_rows_on_inactive_atoms",
         "geo_tour_place_stale_rows", "place_card_links_missing", "active_place_atoms_without_card_link",
         "tenant_versions_older_than_master", "angle_gate_requests_on_inactive_atoms", "seo_context_expired",
         "seo_context_expired_active_tours"]

WRAP = """WITH {chg}, x AS ({inner})
SELECT count(DISTINCT x.id)::bigint AS n,
       count(DISTINCT x.id) FILTER (WHERE x.aged)::bigint AS aged,
       (array_agg(DISTINCT x.id) FILTER (WHERE x.aged))[1:{sample}] AS sample_aged,
       (array_agg(DISTINCT x.id))[1:{sample}] AS sample
  FROM x"""

# AA-CIS-App services/acp_contract/route_detection.py run_route_detection(): the moments route detection reads.
MOMENTS_SQL = """
SELECT ar.segment_id, ar.tour_id::text AS tour_id, asg.canonical_place AS place, MIN(ta.itinerary_day) AS day
  FROM (SELECT DISTINCT segment_id, tour_id FROM acp_contract.atom_ranking
         WHERE excluded_reason IS NULL AND superseded_at IS NULL) ar
  JOIN acp_contract.atom_segment asg ON asg.segment_id = ar.segment_id
  JOIN acp_contract.atom_segment_member asm ON asm.segment_id = ar.segment_id
  JOIN acp_contract.v_active_tour_atoms ta ON ta.atom_id = asm.atom_id AND ta.tour_id = ar.tour_id
 WHERE ta.itinerary_day IS NOT NULL
 GROUP BY ar.segment_id, ar.tour_id, asg.canonical_place, asg.canonical_action
"""
CURRENT_ROUTES_SQL = """
SELECT route_id, tour_id::text AS tour_id, ordered_segment_ids::text AS segs, first_day, last_day, created_at
  FROM acp_contract.route WHERE superseded_at IS NULL
"""
CHG_SQL = "WITH " + CHG + " SELECT tour_id::text AS tour_id, active, changed_at FROM chg"

TOTALS_SQL = f"""
SELECT (SELECT count(*) FROM gold_aa_internal.published_tours pt WHERE {ACTIVE_PT})::bigint AS active_tours,
       (SELECT count(*) FROM acp_contract.v_active_tour_atoms)::bigint AS active_atoms,
       (SELECT count(*) FROM acp_contract.atom_segment)::bigint AS segments,
       (SELECT count(*) FROM acp_contract.route WHERE superseded_at IS NULL)::bigint AS current_routes,
       (SELECT count(*) FROM acp_contract.atom_ranking WHERE superseded_at IS NULL)::bigint AS current_ranking_rows,
       (SELECT count(*) FROM geo.tour_place)::bigint AS tour_place_rows,
       (SELECT count(*) FROM acp_shared.atom_place_card)::bigint AS place_card_links,
       (SELECT count(*) FROM gold_aa_internal.tenant_tour_versions)::bigint AS tenant_versions,
       (SELECT count(*) FROM acp_shared.angle_gate_request)::bigint AS angle_gate_requests,
       (SELECT count(*) FROM silver_aa_internal.seo_context)::bigint AS seo_context_rows
"""
JOBS_SQL = """
SELECT kind, status, count(*)::bigint AS n
  FROM shared.job WHERE status IN ('queued', 'running')
 GROUP BY kind, status ORDER BY kind, status
"""


def out(line, **kw):
    print("SCRIPT " + line + " " + " ".join(f"{k}={v}" for k, v in kw.items()), flush=True)


def safe_id(v):
    """Ids and keys only (uuid, segment id, route id); anything else is masked."""
    v = str(v)
    return v if SAFE_ID_RE.match(v) else "masked"


def sample(ids):
    return [safe_id(v) for v in sorted(ids)[:SAMPLE]]


def emit_json(res):
    """`SCRIPT json[i/n] <part>|` lines (same framing as the tour liveness probe; the gate joins them)."""
    s = json.dumps(res, default=str, separators=(",", ":"))
    parts = [s[i:i + JSON_CHUNK] for i in range(0, len(s), JSON_CHUNK)] or [""]
    for n, part in enumerate(parts, 1):
        print(f"SCRIPT json[{n}/{len(parts)}] {part}|", flush=True)


def error_entry(name, e):
    """A failed metric, safe for the public job log: the server message only for SQLSTATE class 42."""
    state = getattr(e, "sqlstate", None)
    entry = {"metric": name, "error": type(e).__name__, "sqlstate": state}
    if isinstance(state, str) and state.startswith("42"):
        entry["detail"] = str(e).splitlines()[0][:200] if str(e) else ""
    return entry


# ── route parity: verbatim port of route_detection.derive_routes / _runs / _spans ──

def _runs(held):
    runs = []
    for m in held:
        if runs and m["day"] - runs[-1][-1]["day"] <= 1:
            runs[-1].append(m)
        else:
            runs.append([m])
    return runs


def _spans(runs):
    spans = []
    for run in runs:
        days = sorted({m["day"] for m in run})
        cuts = [days[at:at + MOST_DAYS] for at in range(0, len(days), MOST_DAYS)]
        if len(cuts) > 1 and len(cuts[-1]) < LEAST_DAYS:
            cuts[-2] = cuts[-2] + cuts[-1]
            cuts.pop()
        for cut in cuts:
            within = set(cut)
            spans.append([m for m in run if m["day"] in within])
    return spans


def derive_routes(moments):
    """{(tour_id, first_day, last_day): (segment_id, ...)} route detection would build from these moments."""
    by_tour = {}
    for m in moments:
        by_tour.setdefault(m["tour_id"], []).append(m)
    routes = {}
    for tour_id, held in sorted(by_tour.items()):
        for run in _spans(_runs(sorted(held, key=lambda m: (m["day"], m["segment_id"])))):
            places = tuple(dict.fromkeys(m["place"] for m in run))
            days = {m["day"] for m in run}
            if len(days) < LEAST_DAYS or len(places) < LEAST_PLACES:
                continue
            routes[(tour_id, min(days), max(days))] = tuple(m["segment_id"] for m in run)
    return routes


def route_parity(moments, current, chg, cutoff):
    """routes_missing / routes_differ results (n, aged, samples) from the expected and the current route sets."""
    expected = derive_routes(moments)
    cur = {}
    created = {}
    for r in current:
        segs = r["segs"]
        segs = json.loads(segs) if isinstance(segs, str) else segs
        key = (r["tour_id"], int(r["first_day"]), int(r["last_day"]))
        cur[key] = tuple(segs or [])
        created[r["tour_id"]] = min(created.get(r["tour_id"], r["created_at"]), r["created_at"])
    missing = {k[0] for k in expected if k not in cur}
    differ = {k[0] for k, segs in cur.items() if expected.get(k) != segs}

    def aged(tour_id):
        c = chg.get(tour_id)
        moment = (c or {}).get("changed_at") or created.get(tour_id)
        return moment is not None and moment < cutoff

    res = {}
    for name, tours in (("routes_missing", missing), ("routes_differ", differ)):
        old = {t for t in tours if aged(t)}
        res[name] = {"n": len(tours), "aged": len(old), "sample": sample(tours), "sample_aged": sample(old)}
    return res, {"expected_routes": len(expected), "current_routes_compared": len(cur)}


async def probe(conn):
    res = {"probe": "aa991_freshness", "as_of": datetime.now(timezone.utc).isoformat(timespec="seconds"),
           "stale_after_hours": STALE_AFTER_HOURS, "metrics": {}, "errors": [], "jobs_in_flight": []}
    errors = res["errors"]
    try:
        async with conn.transaction(isolation="repeatable_read", readonly=True):
            res["login"] = await conn.fetchval("SELECT session_user")
            await conn.execute(f"SET LOCAL ROLE {READ_ROLE}")
            await conn.execute("SET LOCAL statement_timeout = '120s'")
            res["read_as"] = await conn.fetchval("SELECT current_user")
            cutoff = await conn.fetchval("SELECT now() - make_interval(hours => $1)", STALE_AFTER_HOURS)
            res["cutoff"] = cutoff
            out("role", read_as=res["read_as"], login=res["login"])

            for name, (gate, unit, inner) in METRICS.items():
                try:
                    async with conn.transaction():  # savepoint
                        r = await conn.fetchrow(WRAP.format(chg=CHG, inner=inner, sample=SAMPLE), cutoff)
                    res["metrics"][name] = {"gate": gate, "unit": unit, "n": r["n"], "aged": r["aged"],
                                            "sample": [safe_id(v) for v in (r["sample"] or [])],
                                            "sample_aged": [safe_id(v) for v in (r["sample_aged"] or [])]}
                except Exception as e:  # noqa: BLE001
                    errors.append(error_entry(name, e))
                    res["metrics"][name] = {"gate": gate, "unit": unit, "n": None, "aged": None, "sample": [],
                                            "sample_aged": [], "error": type(e).__name__}

            try:
                async with conn.transaction():
                    moments = [dict(r) for r in await conn.fetch(MOMENTS_SQL)]
                    current = [dict(r) for r in await conn.fetch(CURRENT_ROUTES_SQL)]
                    chg = {r["tour_id"]: dict(r) for r in await conn.fetch(CHG_SQL)}
                parity, res["route_parity"] = route_parity(moments, current, chg, cutoff)
                for name, (gate, unit) in ROUTE_METRICS.items():
                    res["metrics"][name] = {"gate": gate, "unit": unit, **parity[name]}
            except Exception as e:  # noqa: BLE001
                for name, (gate, unit) in ROUTE_METRICS.items():
                    errors.append(error_entry(name, e))
                    res["metrics"][name] = {"gate": gate, "unit": unit, "n": None, "aged": None, "sample": [],
                                            "sample_aged": [], "error": type(e).__name__}

            try:
                async with conn.transaction():
                    res["totals"] = dict(await conn.fetchrow(TOTALS_SQL))
                    res["totals"]["tours_changed_within_window"] = sum(
                        1 for c in chg.values() if c["active"] and c["changed_at"] and c["changed_at"] >= cutoff) \
                        if "route_parity" in res else None
                    res["jobs_in_flight"] = [dict(r) for r in await conn.fetch(JOBS_SQL)]
            except Exception as e:  # noqa: BLE001
                errors.append(error_entry("totals", e))
                res["totals"] = None
    except Exception as e:  # noqa: BLE001 — the role switch or the snapshot itself failed: nothing was measured
        errors.append(error_entry("session", e))

    for name in ORDER:
        m = res["metrics"].get(name)
        if m is None:
            continue
        out("metric", name=name, gate=m["gate"], n="-" if m["n"] is None else m["n"],
            aged="-" if m["aged"] is None else m["aged"], sample=",".join(m["sample"]) or "-")
    totals = res.get("totals") or {}
    if totals:
        out("totals", **{k: "-" if v is None else v for k, v in totals.items()})
    # Visibility floor: under RLS a hidden row set reads as 0 rows and no error, which would make every count pass.
    if totals and (not totals.get("active_tours") or not totals.get("active_atoms")):
        errors.append({"metric": "visibility", "error": "RowsHidden", "sqlstate": None,
                       "detail": f"{READ_ROLE} sees {totals.get('active_tours')} active Masters and "
                                 f"{totals.get('active_atoms')} active atoms"})
    for j in res["jobs_in_flight"]:
        out("jobs", kind=safe_id(j["kind"]), status=safe_id(j["status"]), n=j["n"])

    stale = [n for n in ORDER if n in res["metrics"] and res["metrics"][n]["gate"] == "stale"]
    with_n = [n for n in stale if res["metrics"][n]["n"]]
    aged = [n for n in stale if res["metrics"][n]["aged"]]
    res["verdict"] = {"stale": len(with_n), "stale_aged": sum(res["metrics"][n]["aged"] for n in aged),
                      "errors": len(errors), "list": aged}
    out("verdict", stale=len(with_n), stale_aged=res["verdict"]["stale_aged"], errors=len(errors),
        list=",".join(aged) or "-")
    emit_json(res)


async def main(conn):
    await probe(conn)
    return 0


if __name__ == "__main__":  # local test: python3 <file> <DSN>
    import asyncio

    import asyncpg

    async def _local(dsn):
        conn = await asyncpg.connect(dsn)
        try:
            return await main(conn)
        finally:
            await conn.close()

    sys.exit(asyncio.run(_local(sys.argv[1])))
