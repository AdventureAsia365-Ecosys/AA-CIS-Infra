"""S248 tour-deletion propagation probe, cross-app half (read-only): catalog, AA-Booking, TripPlanner (AA-986).

Question (Nghiep, S248): when a tour is deleted at S0/A0, are all of its derivatives hidden across the system? This
half follows the deletion into the consumers outside CIS: the real `catalog.v_tour` (read as `booking`, else
`tripplanner`: the master has no grant on it), `booking.*` (trip plans, departures, B2B quotes and holds, trip
cases) and `tripplanner.trip_drafts`. The CIS and tenant layers (Master, atoms, ranking / routes, T2 copies,
Slate, T8, T9 pieces, T11 posts, warnings) are in the CIS half (ECS exec as cis_app; root repo audit
docs/audits/2026-10-23-S248-tour-deletion-propagation).

Dispatch: DB Migrate, mode=run-script, script=db/scripts/s248_tour_deletion_probe.py (READ_ONLY: the session is
read-only and the idle check only reports). The file must be merged to AA-CIS-Infra main first (db/scripts/README.md,
Flow 1-3). Local test: `python3 <this file> <DSN>`. Always returns 0: it is evidence, not a gate (a nightly gate that
fails on `violations > 0` is a later slice of AA-986).

Layer expectations (`expect`) follow the S248 memo's proposed answers, pending Nghiep's decision: Q4 (sold Booking
departures / confirmed holds are kept and flagged, new holds / quotes blocked) and Q9 (`lifecycle_stage` is not a
deletion signal: the two lifecycle buckets are context only, every layer there reports `expect=info`). Under Q4 an
upcoming departure is split by whether a confirmed hold sold it: `bk_departures_upcoming_unsold` (zero) and
`bk_departures_upcoming_sold` (keep_warn). Changing an answer = changing one `expect` value in LAYERS, or the
CONTEXT_BUCKETS set.

Keys: the catalog key is `source_id` = `raw_tours.source_key` = coalesce(source_group_id, tour_id)::text (CIS 258);
`booking.trip_plans.source_id` and `booking.trip_case_legs.source_id` hold it. `trip_case_legs.source_tour_id`,
`trip_case_version_itinerary.source_tour_id` and TripPlanner itinerary entries (`source_tour_id`) hold either the
catalog key or a version `tour_id` (AA-Booking app/inquiry/leg_keys.py), so those are matched on both.

Buckets (AA master tenant):
  group_dead              source groups with no live version (live = source_status 'active' AND deleted_at IS NULL):
                          the tour is gone at S0; keys + every version tour_id of the group
  trashed_versions        tour_ids of trashed versions (catches references by version id)
  superseded_versions     tour_ids of superseded versions whose group lives on (stale version references)
  lifecycle_retired       keys / tour_ids whose live version has lifecycle_stage 'retired' (no app writer today)
  lifecycle_phasing_out   same for 'phasing_out'
  live_source_not_in_catalog  groups with a live source version but no catalog.v_tour row (Master not active,
                          not published yet, or superseded before the new version was published)

Output (ids, keys, statuses and counts only; no row text, no money, no personal data):
  SCRIPT catalog role=<role|-> rows=<n> refused=<...>
  SCRIPT bucket name=<b> keys=<n> tour_ids=<n> sample=<ids>
  SCRIPT layer bucket=<b> layer=<l> expect=<zero|keep_warn|info> n=<n> refs=<n> sample=<ids>
  SCRIPT global name=<g> n=<n> sample=<ids>
  SCRIPT verdict violations=<n> errors=<n> list=<bucket.layer,...>   (errors = layers that failed to run)
  SCRIPT json {...}                                         (everything above as one JSON object)
The job log is public (Actions): an error entry carries the exception class and SQLSTATE only; the server message is
kept only for SQLSTATE class 42 (undefined / syntax / privilege: names objects, never row values).
"""

import json
import re
import sys
from datetime import datetime, timezone

READ_ONLY = True

AA_MASTER = "00000000-0000-0000-0000-000000000001"
SAMPLE = 5
CATALOG_ROLES = ("booking", "tripplanner")
SAFE_ID_RE = re.compile(r"^[A-Za-z0-9:_-]{1,64}$")
# Q9 (proposed, pending Nghiep): lifecycle_stage is not a deletion signal, so these buckets never count as violations.
CONTEXT_BUCKETS = frozenset({"lifecycle_retired", "lifecycle_phasing_out"})

VERSIONS_SQL = """
SELECT rt.tour_id::text AS tour_id, rt.source_key, rt.source_status::text AS source_status,
       rt.deleted_at IS NOT NULL AS src_deleted, rt.lifecycle_stage::text AS lifecycle_stage
  FROM silver_aa_internal.raw_tours rt
 WHERE rt.tenant_id = $1::uuid
"""

CATALOG_SQL = "SELECT source_id, tour_id::text AS tour_id FROM catalog.v_tour"

# Inner queries: $1 = keys text[] (catalog source_id), $2 = refs text[] (keys + version tour_ids).
# Each returns text columns id, ref.
LAYERS = [
    ("bk_trip_plans", "info", "booking.trip_plans on the key (any sellable state)",
     """SELECT p.id::text AS id, p.source_id AS ref FROM booking.trip_plans p
         WHERE p.source_system = 'cis' AND p.source_id = ANY($1::text[])"""),
    ("bk_trip_plans_sellable", "zero", "booking.trip_plans sellable = true",
     """SELECT p.id::text AS id, p.source_id AS ref FROM booking.trip_plans p
         WHERE p.source_system = 'cis' AND p.source_id = ANY($1::text[]) AND p.sellable"""),
    ("bk_plan_components", "info", "booking.trip_plan_components of those plans",
     """SELECT c.id::text AS id, p.source_id AS ref FROM booking.trip_plan_components c
          JOIN booking.trip_plans p ON p.id = c.trip_plan_id
         WHERE p.source_system = 'cis' AND p.source_id = ANY($1::text[])"""),
    # Q4 (proposed, pending Nghiep): an upcoming departure with a confirmed hold is sold, kept and flagged
    # (keep_warn); one with no confirmed hold must be closed (zero). "Sold" matches bk_b2b_holds_confirmed_upcoming.
    ("bk_departures_upcoming_unsold", "zero",
     "booking.departures start_date >= today, status <> 'cancelled', no confirmed b2b hold on it",
     """SELECT d.id::text AS id, p.source_id AS ref FROM booking.departures d
          JOIN booking.trip_plans p ON p.id = d.trip_plan_id
         WHERE p.source_system = 'cis' AND p.source_id = ANY($1::text[])
           AND d.start_date >= current_date AND d.status <> 'cancelled'
           AND NOT EXISTS (SELECT 1 FROM booking.b2b_hold_lines hl JOIN booking.b2b_holds h ON h.id = hl.hold_id
                            WHERE hl.departure_id = d.id AND h.status = 'confirmed')"""),
    ("bk_departures_upcoming_sold", "keep_warn",
     "booking.departures start_date >= today, status <> 'cancelled', with a confirmed b2b hold (sold: ops must handle)",
     """SELECT d.id::text AS id, p.source_id AS ref FROM booking.departures d
          JOIN booking.trip_plans p ON p.id = d.trip_plan_id
         WHERE p.source_system = 'cis' AND p.source_id = ANY($1::text[])
           AND d.start_date >= current_date AND d.status <> 'cancelled'
           AND EXISTS (SELECT 1 FROM booking.b2b_hold_lines hl JOIN booking.b2b_holds h ON h.id = hl.hold_id
                        WHERE hl.departure_id = d.id AND h.status = 'confirmed')"""),
    ("bk_b2b_quotes_open", "zero",
     "booking.b2b_quotes valid_until > now() with a trip_plan line (tp:<plan id>) or a line on one of its departures",
     """SELECT DISTINCT q.id::text AS id, p.source_id AS ref
          FROM booking.b2b_quotes q
          JOIN booking.b2b_quote_lines l ON l.quote_id = q.id
          LEFT JOIN booking.departures d ON d.id = l.departure_id
          JOIN booking.trip_plans p
            ON (l.component_kind = 'trip_plan' AND l.component_id = 'tp:' || p.id::text) OR p.id = d.trip_plan_id
         WHERE p.source_system = 'cis' AND p.source_id = ANY($1::text[]) AND q.valid_until > now()"""),
    ("bk_b2b_holds_active", "zero",
     "booking.b2b_holds status 'active' on one of the plan's departures or on a quote with its trip_plan line",
     """SELECT DISTINCT h.id::text AS id, p.source_id AS ref
          FROM booking.b2b_holds h
          JOIN booking.trip_plans p ON p.source_system = 'cis' AND p.source_id = ANY($1::text[])
         WHERE h.status = 'active'
           AND (EXISTS (SELECT 1 FROM booking.b2b_hold_lines hl JOIN booking.departures d ON d.id = hl.departure_id
                         WHERE hl.hold_id = h.id AND d.trip_plan_id = p.id)
                OR EXISTS (SELECT 1 FROM booking.b2b_quote_lines ql
                            WHERE ql.quote_id = h.quote_id AND ql.component_kind = 'trip_plan'
                              AND ql.component_id = 'tp:' || p.id::text))"""),
    ("bk_b2b_holds_confirmed_upcoming", "keep_warn",
     "booking.b2b_holds status 'confirmed' on a departure that has not started (sold: ops must handle)",
     """SELECT DISTINCT h.id::text AS id, p.source_id AS ref
          FROM booking.b2b_holds h
          JOIN booking.b2b_hold_lines hl ON hl.hold_id = h.id
          JOIN booking.departures d ON d.id = hl.departure_id
          JOIN booking.trip_plans p ON p.id = d.trip_plan_id
         WHERE h.status = 'confirmed' AND d.start_date >= current_date
           AND p.source_system = 'cis' AND p.source_id = ANY($1::text[])"""),
    ("bk_trip_cases_open", "keep_warn",
     "booking.trip_cases not deleted, status not completed/cancelled, with a leg or itinerary item on the tour",
     """WITH m AS (
            SELECT l.trip_case_id,
                   CASE WHEN l.source_id = ANY($1::text[]) THEN l.source_id ELSE l.source_tour_id END AS ref
              FROM booking.trip_case_legs l
             WHERE l.source_id = ANY($1::text[]) OR l.source_tour_id = ANY($2::text[])
            UNION
            SELECT v.trip_case_id, i.source_tour_id
              FROM booking.trip_case_version_itinerary i
              JOIN booking.trip_case_versions v ON v.id = i.trip_case_version_id
             WHERE v.deleted_at IS NULL AND i.source_tour_id = ANY($2::text[]))
        SELECT tc.id::text AS id, m.ref FROM booking.trip_cases tc JOIN m ON m.trip_case_id = tc.id
         WHERE tc.deleted_at IS NULL AND tc.status NOT IN ('completed', 'cancelled')"""),
    ("bk_trip_cases_closed", "info", "same, trip case completed / cancelled / deleted",
     """WITH m AS (
            SELECT l.trip_case_id,
                   CASE WHEN l.source_id = ANY($1::text[]) THEN l.source_id ELSE l.source_tour_id END AS ref
              FROM booking.trip_case_legs l
             WHERE l.source_id = ANY($1::text[]) OR l.source_tour_id = ANY($2::text[])
            UNION
            SELECT v.trip_case_id, i.source_tour_id
              FROM booking.trip_case_version_itinerary i
              JOIN booking.trip_case_versions v ON v.id = i.trip_case_version_id
             WHERE i.source_tour_id = ANY($2::text[]))
        SELECT tc.id::text AS id, m.ref FROM booking.trip_cases tc JOIN m ON m.trip_case_id = tc.id
         WHERE tc.deleted_at IS NOT NULL OR tc.status IN ('completed', 'cancelled')"""),
    ("tp_drafts_open", "keep_warn", "tripplanner.trip_drafts status 'draft' with an itinerary entry on the tour",
     """SELECT DISTINCT d.id::text AS id, e ->> 'source_tour_id' AS ref
          FROM tripplanner.trip_drafts d
          CROSS JOIN LATERAL jsonb_array_elements(
              CASE WHEN jsonb_typeof(d.itinerary) = 'array' THEN d.itinerary ELSE '[]'::jsonb END) e
         WHERE d.status = 'draft' AND e ->> 'source_tour_id' = ANY($2::text[])"""),
    ("tp_drafts_sent", "info", "tripplanner.trip_drafts status 'sent' with an itinerary entry on the tour",
     """SELECT DISTINCT d.id::text AS id, e ->> 'source_tour_id' AS ref
          FROM tripplanner.trip_drafts d
          CROSS JOIN LATERAL jsonb_array_elements(
              CASE WHEN jsonb_typeof(d.itinerary) = 'array' THEN d.itinerary ELSE '[]'::jsonb END) e
         WHERE d.status = 'sent' AND e ->> 'source_tour_id' = ANY($2::text[])"""),
]

WRAP = """SELECT count(DISTINCT x.id)::bigint AS n, count(DISTINCT x.ref)::bigint AS refs,
                 (array_agg(DISTINCT x.id))[1:{sample}] AS sample
            FROM ({inner}) x
           WHERE cardinality($1::text[]) >= 0 AND cardinality($2::text[]) >= 0"""  # types both params for every layer

PLANS_SQL = "SELECT p.id::text AS id, p.source_id, p.sellable FROM booking.trip_plans p WHERE p.source_system = 'cis'"
DRAFT_REFS_SQL = """
SELECT DISTINCT d.id::text AS id, d.status, e ->> 'source_tour_id' AS ref
  FROM tripplanner.trip_drafts d
  CROSS JOIN LATERAL jsonb_array_elements(
      CASE WHEN jsonb_typeof(d.itinerary) = 'array' THEN d.itinerary ELSE '[]'::jsonb END) e
 WHERE e ->> 'source_tour_id' IS NOT NULL
"""
LEG_REFS_SQL = """
SELECT l.trip_case_id::text AS id, l.source_id, l.source_tour_id, tc.status, tc.deleted_at IS NOT NULL AS deleted
  FROM booking.trip_case_legs l JOIN booking.trip_cases tc ON tc.id = l.trip_case_id
"""


def out(kind, **kw):
    print("SCRIPT " + kind + " " + " ".join(f"{k}={v}" for k, v in kw.items()), flush=True)


def is_live(v):
    return v["source_status"] == "active" and not v["src_deleted"]


def build_buckets(versions, catalog_keys):
    groups = {}
    for v in versions:
        groups.setdefault(v["source_key"], []).append(v)
    b = {n: {"keys": set(), "tour_ids": set()} for n in (
        "group_dead", "trashed_versions", "superseded_versions", "lifecycle_retired", "lifecycle_phasing_out",
        "live_source_not_in_catalog")}
    for key, vs in groups.items():
        live = [v for v in vs if is_live(v)]
        if not live:
            b["group_dead"]["keys"].add(key)
            b["group_dead"]["tour_ids"].update(v["tour_id"] for v in vs)
        for v in vs:
            if v["source_status"] == "trashed":
                b["trashed_versions"]["tour_ids"].add(v["tour_id"])
            if v["source_status"] == "superseded" and live:
                b["superseded_versions"]["tour_ids"].add(v["tour_id"])
        for stage, name in (("retired", "lifecycle_retired"), ("phasing_out", "lifecycle_phasing_out")):
            hit = [v for v in live if v["lifecycle_stage"] == stage]
            if hit:
                b[name]["keys"].add(key)
                b[name]["tour_ids"].update(v["tour_id"] for v in hit)
        if live and catalog_keys is not None and key not in catalog_keys:
            b["live_source_not_in_catalog"]["keys"].add(key)
            b["live_source_not_in_catalog"]["tour_ids"].update(v["tour_id"] for v in live)
    return b, {"groups": len(groups), "groups_dead": len(b["group_dead"]["keys"]), "versions": len(versions)}


def safe_id(v):
    """Ids and keys only (uuid / catalog key / tp:<id>); anything else (a free-text ref in a draft) is masked."""
    v = str(v)
    return v if SAFE_ID_RE.match(v) else "masked"


def sample(ids):
    return [safe_id(v) for v in sorted(ids)[:SAMPLE]]


def error_entry(name, e):
    """A failed layer, safe for the public job log: a data error message can quote a row value, so the server
    message is kept only for SQLSTATE class 42 (undefined column / table, syntax, privilege)."""
    state = getattr(e, "sqlstate", None)
    entry = {"layer": name, "error": type(e).__name__, "sqlstate": state}
    if isinstance(state, str) and state.startswith("42"):
        entry["detail"] = str(e).splitlines()[0][:200] if str(e) else ""
    return entry


async def read_catalog(conn):
    refused = []
    for role in CATALOG_ROLES:
        try:
            async with conn.transaction(isolation="repeatable_read", readonly=True):
                await conn.execute(f"SET LOCAL ROLE {role}")
                rows = await conn.fetch(CATALOG_SQL)
            return role, [dict(r) for r in rows], refused
        except Exception as e:  # noqa: BLE001 — a refused role switch or read: try the next role
            refused.append(f"{role}:{type(e).__name__}")
    return None, None, refused


async def layer(conn, inner, keys, refs, errors, name):
    try:
        async with conn.transaction():  # savepoint
            r = await conn.fetchrow(WRAP.format(inner=inner, sample=SAMPLE), sorted(keys), sorted(refs))
        return {"n": r["n"], "refs": r["refs"], "sample": [safe_id(v) for v in (r["sample"] or [])]}
    except Exception as e:  # noqa: BLE001
        errors.append(error_entry(name, e))
        return {"n": None, "refs": None, "sample": [], "error": type(e).__name__}


async def probe(conn):
    res = {"probe": "tour_deletion_master", "as_of": datetime.now(timezone.utc).isoformat(timespec="seconds"),
           "schema_ref": "db-schema-reference.md Verified 2026-10-23 06:35 UTC (CIS 270, tp-018, bk-021)",
           "errors": []}
    errors = res["errors"]

    role, catalog, refused = await read_catalog(conn)
    res["catalog"] = {"role": role, "rows": None if catalog is None else len(catalog), "refused": refused}
    out("catalog", role=role or "-", rows=res["catalog"]["rows"], refused=",".join(refused) or "-")
    cat_keys = None if catalog is None else {r["source_id"] for r in catalog}
    cat_tour_ids = None if catalog is None else {r["tour_id"] for r in catalog}

    async with conn.transaction(isolation="repeatable_read", readonly=True):
        await conn.execute("SET LOCAL statement_timeout = '120s'")
        res["db_role"] = await conn.fetchval("SELECT current_user")
        versions = [dict(r) for r in await conn.fetch(VERSIONS_SQL, AA_MASTER)]
        buckets, totals = build_buckets(versions, cat_keys)
        res["totals"] = totals

        res["buckets"] = {}
        violations = []
        for name, b in buckets.items():
            keys, tids = b["keys"], b["tour_ids"]
            refs = keys | tids
            entry = {"keys": len(keys), "tour_ids": len(tids), "sample_keys": sample(keys),
                     "sample_tour_ids": sample(tids), "layers": {}}
            out("bucket", name=name, keys=len(keys), tour_ids=len(tids), sample=",".join(sample(refs)) or "-")
            if refs:
                if catalog is not None:
                    hit = sorted({r["source_id"] for r in catalog if r["source_id"] in keys or r["tour_id"] in tids})
                    entry["layers"]["catalog_v_tour"] = {"n": len(hit), "refs": len(hit), "sample": sample(hit),
                                                         "expect": "info" if name in CONTEXT_BUCKETS else "zero"}
                for lname, expect, _desc, inner in LAYERS:
                    r = await layer(conn, inner, keys, refs, errors, f"{name}.{lname}")
                    r["expect"] = "info" if name in CONTEXT_BUCKETS else expect
                    entry["layers"][lname] = r
                for lname, r in entry["layers"].items():
                    out("layer", bucket=name, layer=lname, expect=r["expect"], n=r["n"], refs=r.get("refs"),
                        sample=",".join(r["sample"]) or "-")
                    if r["expect"] == "zero" and r["n"]:
                        violations.append(f"{name}.{lname}")
            res["buckets"][name] = entry

        # Global: consumer references the catalog no longer resolves (whatever the cause).
        glob = {}
        plans = [dict(r) for r in await conn.fetch(PLANS_SQL)]
        drafts = [dict(r) for r in await conn.fetch(DRAFT_REFS_SQL)]
        legs = [dict(r) for r in await conn.fetch(LEG_REFS_SQL)]
        if catalog is not None:
            def gone(ref):
                return ref is not None and ref not in cat_keys and ref not in cat_tour_ids
            g = {
                "bk_sellable_plans_not_in_catalog": {p["id"] for p in plans if p["sellable"] and gone(p["source_id"])},
                "bk_plans_not_in_catalog": {p["id"] for p in plans if gone(p["source_id"])},
                "bk_open_cases_with_leg_not_in_catalog": {
                    lg["id"] for lg in legs
                    if not lg["deleted"] and lg["status"] not in ("completed", "cancelled")
                    and gone(lg["source_id"] or lg["source_tour_id"])},
                "tp_open_drafts_with_ref_not_in_catalog": {d["id"] for d in drafts
                                                           if d["status"] == "draft" and gone(d["ref"])},
                "tp_draft_refs_not_in_catalog": {d["ref"] for d in drafts if gone(d["ref"])},
            }
            for gname, ids in g.items():
                glob[gname] = {"n": len(ids), "sample": sample(ids)}
                out("global", name=gname, n=len(ids), sample=",".join(sample(ids)) or "-")
        glob["counts"] = {"bk_trip_plans": len(plans), "bk_sellable": sum(1 for p in plans if p["sellable"]),
                          "tp_draft_refs": len(drafts), "bk_case_legs": len(legs)}
        res["global"] = glob

    res["violations"] = violations
    res["layer_definitions"] = {n: {"expect": e, "what": d} for n, e, d, _ in LAYERS}
    res["layer_definitions"]["catalog_v_tour"] = {"expect": "zero", "what": "catalog.v_tour rows on the key or tour_id"}
    out("verdict", violations=len(violations), errors=len(errors), list=",".join(violations) or "-")
    print("SCRIPT json " + json.dumps(res, default=str, separators=(",", ":")), flush=True)


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
