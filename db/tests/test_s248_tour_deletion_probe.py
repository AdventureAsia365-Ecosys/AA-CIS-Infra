"""AA-986: db/scripts/s248_tour_deletion_probe.py (read-only tour-deletion propagation probe, cross-app half).

No database, no asyncpg: a fake connection answers the script's SQL by matching on it. The SQL itself ran green
against a local PostgreSQL 16 with a stub schema built from docs/architecture/db-schema-reference.md (S248).
Run: python3 -m unittest discover -s db/tests -v
"""
import asyncio
import contextlib
import importlib.util
import io
import json
import re
import sys
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import run_migration as rm  # noqa: E402

ROOT = HERE.parent.parent
PATH = "db/scripts/s248_tour_deletion_probe.py"
_spec = importlib.util.spec_from_file_location("s248_tour_deletion_probe", ROOT / PATH)
script = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(script)

WRITE_RE = re.compile(r"\b(INSERT|UPDATE|DELETE|MERGE|TRUNCATE|CREATE|ALTER|DROP|GRANT|REVOKE|COPY|CALL|DO)\b", re.I)


def ver(tour_id, key, status="active", deleted=False, stage="active"):
    return {"tour_id": tour_id, "source_key": key, "source_status": status, "src_deleted": deleted,
            "lifecycle_stage": stage}


# k-live: one live version. k-dead: trashed only (gone at S0). k-sup: superseded v1 + live v2.
# k-ret: live but lifecycle 'retired'. k-new: live, not in the catalog yet.
VERSIONS = [
    ver("t-live", "k-live"),
    ver("t-dead", "k-dead", "trashed", deleted=True),
    ver("t-sup1", "k-sup", "superseded"), ver("t-sup2", "k-sup"),
    ver("t-ret", "k-ret", stage="retired"),
    ver("t-new", "k-new"),
]
CATALOG = [{"source_id": "k-live", "tour_id": "t-live"}, {"source_id": "k-sup", "tour_id": "t-sup2"},
           {"source_id": "k-ret", "tour_id": "t-ret"}]
T0 = datetime(2026, 10, 20, tzinfo=timezone.utc)


def lv(key, state="served", reason=None, changed_at=T0, tour_id=None):
    return {"source_id": key, "tour_id": tour_id or f"t-{key}", "state": state, "reason": reason,
            "changed_at": changed_at}


# v_tour_liveness agrees with the catalog: every catalog key served.
LIVENESS = [lv("k-live"), lv("k-sup", tour_id="t-sup2"), lv("k-ret")]
L2_OBJECTS = {script.LIVENESS_VIEW: ["source_system", "source_id", "tour_id", "state", "reason", "changed_at"],
              script.LIFECYCLE_RECORD: ["id", "source_system", "source_id", "tour_id", "event", "reason"]}


class PgError(Exception):
    def __init__(self, msg, sqlstate):
        super().__init__(msg)
        self.sqlstate = sqlstate


class FakeConn:
    def __init__(self, *, catalog=CATALOG, refuse_roles=(), layer_hits=None, layer_errors=None, plans=(),
                 drafts=(), legs=(), objects=None, liveness=LIVENESS, events=None, tombstone=None,
                 masters_dup=(), masters_dead=(), after_rows=None, check_errors=None, versions=None,
                 active_masters=None):
        self.catalog, self.refuse_roles = catalog, set(refuse_roles)
        self.layer_hits, self.layer_errors = layer_hits or {}, layer_errors or {}
        self.plans, self.drafts, self.legs = list(plans), list(drafts), list(legs)
        self.objects = dict(L2_OBJECTS) if objects is None else objects
        self.liveness, self.events, self.tombstone = list(liveness), dict(events or {}), dict(tombstone or {})
        self.masters_dup, self.masters_dead = list(masters_dup), list(masters_dead)
        # after_rows: {check name: [(key, created_at, id)]}; check_errors: {check name or sql name: exception}
        self.after_rows, self.check_errors = after_rows or {}, check_errors or {}
        self.after_args = {}
        # Every key of the liveness view has a source group the login can see (the visibility floor compares them).
        known = {v["source_key"] for v in VERSIONS}
        self.versions = list(VERSIONS) + [ver(f"t-{r['source_id']}", r["source_id"],
                                              "trashed" if r["state"] == "retired" else "active",
                                              deleted=r["state"] == "retired")
                                          for r in self.liveness if r["source_id"] not in known] \
            if versions is None else list(versions)
        self.active_masters = len(self.catalog) if active_masters is None else active_masters
        self.executed, self.sql_seen, self.tx = [], [], []
        self.role = None

    async def execute(self, sql, *args):
        s = " ".join(sql.split())
        self.executed.append(s)
        if s.startswith("SET LOCAL ROLE "):
            role = s.rsplit(" ", 1)[1]
            if role in self.refuse_roles:
                raise PgError(f'permission denied to set role "{role}"', "42501")
            self.role = role
        return "SET"

    async def fetchval(self, sql, *args):
        self.sql_seen.append(sql)
        if sql == script.ACTIVE_MASTERS_SQL:
            assert args == (script.AA_MASTER,)
            return self.active_masters
        assert sql == "SELECT current_user", sql[:80]
        return "aa_cis_admin"

    async def fetch(self, sql, *args):
        self.sql_seen.append(sql)
        if sql == script.CATALOG_SQL:
            return self.catalog
        if sql == script.OBJECTS_SQL:
            if "objects" in self.check_errors:
                raise self.check_errors["objects"]
            assert args == ([script.LIVENESS_VIEW, script.LIFECYCLE_RECORD, script.TOMBSTONE_VIEW],)
            return [{"name": n, "columns": c} for n, c in self.objects.items() if n in args[0]]
        if sql == script.LIVENESS_SQL:
            return self.liveness
        if sql == script.LATEST_EVENT_SQL:
            return [{"source_id": k, "event": e} for k, e in self.events.items()]
        if sql == script.TOMBSTONE_SQL:
            assert self.role in ("booking", "tripplanner"), self.role  # catalog views: never as the master
            if "tombstone" in self.check_errors:
                raise self.check_errors["tombstone"]
            return [{"source_id": k, "state": v} for k, v in self.tombstone.items()]
        for name, sql_c, rows in (("masters_active_in_one_group", script.MASTERS_PER_GROUP_SQL, self.masters_dup),
                                  ("master_active_over_dead_source", script.MASTER_OVER_DEAD_SQL, self.masters_dead)):
            if sql == sql_c:
                assert args == (script.AA_MASTER,)
                if name in self.check_errors:
                    raise self.check_errors[name]
                return [{"id": i} for i in rows]
        for name, sql_c in script.AFTER_SQL.items():
            if sql == sql_c:
                keys, since = args
                assert len(keys) == len(since) and all(t.tzinfo for t in since)
                self.after_args[name] = dict(zip(keys, since))
                if name in self.check_errors:
                    raise self.check_errors[name]
                return [{"id": i} for k, created, i in self.after_rows.get(name, [])
                        if k in self.after_args[name] and created > self.after_args[name][k]]
        if sql == script.VERSIONS_SQL:
            assert args == (script.AA_MASTER,)
            return self.versions
        if sql == script.PLANS_SQL:
            return self.plans
        if sql == script.DRAFT_REFS_SQL:
            return self.drafts
        if sql == script.LEG_REFS_SQL:
            return self.legs
        raise AssertionError(f"unexpected SQL: {sql[:80]}")

    async def fetchrow(self, sql, *args):
        self.sql_seen.append(sql)
        # Longest match first: one layer's SQL can be a prefix of another's (bk_trip_plans / _sellable).
        for name, _expect, _desc, inner in sorted(script.LAYERS, key=lambda x: -len(x[3])):
            if inner in sql:
                keys, refs = args
                assert isinstance(keys, list) and isinstance(refs, list)
                if name in self.layer_errors:
                    raise self.layer_errors[name]
                hit = self.layer_hits.get(name, {})
                ids = sorted(i for k, ids in hit.items() if k in refs for i in ids)
                return {"n": len(ids), "refs": len({k for k in hit if k in refs}), "sample": ids[:script.SAMPLE]}
        raise AssertionError(f"unexpected SQL: {sql[:80]}")

    @contextlib.asynccontextmanager
    async def transaction(self, isolation=None, readonly=False):
        self.tx.append((isolation, readonly))
        yield
        self.role = None


def run(conn):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = asyncio.run(script.main(conn))
    return rc, out.getvalue().splitlines()


JSON_PART_RE = re.compile(r"^SCRIPT json\[(\d+)/(\d+)\] (.*)\|$")


def result(lines):
    parts = [JSON_PART_RE.match(x) for x in lines if x.startswith("SCRIPT json[")]
    assert parts and all(parts) and [int(m[1]) for m in parts] == list(range(1, int(parts[0][2]) + 1))
    return json.loads("".join(m[3] for m in parts))


class ShapeTest(unittest.TestCase):
    def test_runner_accepts_the_file_and_it_is_read_only(self):
        source = (ROOT / PATH).read_text(encoding="utf-8")
        self.assertEqual(rm.script_errors(source, PATH), [])
        self.assertTrue(rm.script_is_read_only(source))
        self.assertIs(script.READ_ONLY, True)

    def test_every_statement_is_a_read(self):
        sqls = [script.VERSIONS_SQL, script.CATALOG_SQL, script.PLANS_SQL, script.DRAFT_REFS_SQL,
                script.LEG_REFS_SQL, script.WRAP, script.OBJECTS_SQL, script.LIVENESS_SQL, script.LATEST_EVENT_SQL,
                script.TOMBSTONE_SQL, script.MASTERS_PER_GROUP_SQL, script.MASTER_OVER_DEAD_SQL,
                script.ACTIVE_MASTERS_SQL]
        sqls += [inner for *_, inner in script.LAYERS] + list(script.AFTER_SQL.values())
        for sql in sqls:
            self.assertRegex(sql.strip(), r"^(SELECT|WITH)\b")
            self.assertIsNone(WRITE_RE.search(sql), sql[:80])

    def test_layer_expectations_are_known(self):
        names = [n for n, *_ in script.LAYERS]
        self.assertEqual(len(names), len(set(names)))
        self.assertTrue(all(e in ("zero", "keep_warn", "info") for _, e, *_ in script.LAYERS))


class BucketTest(unittest.TestCase):
    def test_buckets_follow_the_live_rule(self):
        b, totals = script.build_buckets(VERSIONS, {c["source_id"] for c in CATALOG})
        self.assertEqual(totals, {"groups": 5, "groups_dead": 1, "versions": 6})
        self.assertEqual(b["group_dead"], {"keys": {"k-dead"}, "tour_ids": {"t-dead"}})
        self.assertEqual(b["trashed_versions"]["tour_ids"], {"t-dead"})
        self.assertEqual(b["superseded_versions"]["tour_ids"], {"t-sup1"})
        self.assertEqual(b["lifecycle_retired"], {"keys": {"k-ret"}, "tour_ids": {"t-ret"}})
        self.assertEqual(b["live_source_not_in_catalog"], {"keys": {"k-new"}, "tour_ids": {"t-new"}})

    def test_active_row_with_deleted_at_is_not_live(self):
        b, _ = script.build_buckets([ver("t1", "k1", deleted=True)], set())
        self.assertEqual(b["group_dead"]["keys"], {"k1"})
        self.assertEqual(b["live_source_not_in_catalog"]["keys"], set())

    def test_no_catalog_skips_the_not_in_catalog_bucket(self):
        b, _ = script.build_buckets(VERSIONS, None)
        self.assertEqual(b["live_source_not_in_catalog"]["keys"], set())


class RunTest(unittest.TestCase):
    def test_clean_run_shape(self):
        conn = FakeConn()
        rc, lines = run(conn)
        self.assertEqual(rc, 0)
        self.assertTrue(lines and all(x.startswith("SCRIPT ") for x in lines))
        kinds = {x.split(" ", 2)[1] for x in lines}
        self.assertEqual(kinds, {"catalog", "bucket", "layer", "global", "check", "visibility", "verdict",
                                 "json[1/1]"})
        self.assertIn("SCRIPT catalog role=booking rows=3 refused=-", lines)
        # The L4 tombstone view is not there yet: its check is pending, never a violation.
        self.assertIn("SCRIPT verdict violations=0 errors=0 list=- pending=1", lines)
        res = result(lines)
        self.assertEqual(res["db_role"], "aa_cis_admin")
        self.assertEqual(res["violations"], [])
        self.assertEqual(set(res["buckets"]), {"group_dead", "trashed_versions", "superseded_versions",
                                               "lifecycle_retired", "lifecycle_phasing_out",
                                               "live_source_not_in_catalog"})
        layers = res["buckets"]["group_dead"]["layers"]
        self.assertEqual(set(layers), {"catalog_v_tour"} | {n for n, *_ in script.LAYERS})
        self.assertEqual(res["buckets"]["lifecycle_phasing_out"]["layers"], {})  # empty bucket: no layer runs
        # Q9: a live tour with lifecycle_stage 'retired' is still served by the catalog; context, not a violation.
        retired = res["buckets"]["lifecycle_retired"]["layers"]
        self.assertEqual(retired["catalog_v_tour"], {"n": 1, "refs": 1, "sample": ["k-ret"], "expect": "info"})
        self.assertTrue(all(r["expect"] == "info" for r in retired.values()))

    def test_reads_only_in_read_only_transactions_and_never_writes(self):
        conn = FakeConn()
        run(conn)
        self.assertTrue(all(ro for iso, ro in conn.tx if iso is not None))
        self.assertIn(("repeatable_read", True), conn.tx)
        for s in conn.executed:
            self.assertRegex(s, r"^SET LOCAL (ROLE (booking|tripplanner)|statement_timeout = '\d+s')$")
        for sql in conn.sql_seen:
            self.assertIsNone(WRITE_RE.search(sql), sql[:80])

    def test_violations_are_listed(self):
        catalog = CATALOG + [{"source_id": "k-dead", "tour_id": "t-dead"}]  # the catalog still serves a dead tour
        conn = FakeConn(catalog=catalog, layer_hits={
            "bk_trip_plans_sellable": {"k-dead": ["p1"]},
            "bk_b2b_holds_confirmed_upcoming": {"k-dead": ["h1"]},  # keep_warn: reported, not a violation
        })
        rc, lines = run(conn)
        self.assertEqual(rc, 0)  # evidence, not a gate
        res = result(lines)
        self.assertIn("group_dead.catalog_v_tour", res["violations"])
        self.assertIn("group_dead.bk_trip_plans_sellable", res["violations"])
        self.assertNotIn("group_dead.bk_b2b_holds_confirmed_upcoming", res["violations"])
        self.assertIn("SCRIPT layer bucket=group_dead layer=bk_trip_plans_sellable expect=zero n=1 refs=1 sample=p1",
                      lines)

    def test_sold_departure_is_kept_and_only_the_unsold_one_is_a_violation(self):
        # Q4: a dead tour with one sold (confirmed hold) and one unsold upcoming departure.
        conn = FakeConn(layer_hits={
            "bk_departures_upcoming_unsold": {"k-dead": ["dep-unsold"]},
            "bk_departures_upcoming_sold": {"k-dead": ["dep-sold"]},
            "bk_b2b_holds_confirmed_upcoming": {"k-dead": ["h1"]},
        })
        _, lines = run(conn)
        res = result(lines)
        self.assertEqual(res["violations"], ["group_dead.bk_departures_upcoming_unsold"])
        layers = res["buckets"]["group_dead"]["layers"]
        self.assertEqual(layers["bk_departures_upcoming_unsold"],
                         {"n": 1, "refs": 1, "sample": ["dep-unsold"], "expect": "zero"})
        self.assertEqual(layers["bk_departures_upcoming_sold"],
                         {"n": 1, "refs": 1, "sample": ["dep-sold"], "expect": "keep_warn"})
        self.assertIn("SCRIPT verdict violations=1 errors=0 list=group_dead.bk_departures_upcoming_unsold pending=1",
                      lines)

    def test_sold_and_unsold_departures_split_on_the_same_confirmed_hold_test(self):
        sql = {n: " ".join(inner.split()) for n, _e, _d, inner in script.LAYERS}
        sold_test = ("EXISTS (SELECT 1 FROM booking.b2b_hold_lines hl JOIN booking.b2b_holds h ON h.id = hl.hold_id "
                     "WHERE hl.departure_id = d.id AND h.status = 'confirmed')")
        self.assertTrue(sql["bk_departures_upcoming_sold"].endswith("AND " + sold_test))
        self.assertTrue(sql["bk_departures_upcoming_unsold"].endswith("AND NOT " + sold_test))
        self.assertEqual(sql["bk_departures_upcoming_sold"].removesuffix(" AND " + sold_test),
                         sql["bk_departures_upcoming_unsold"].removesuffix(" AND NOT " + sold_test))
        self.assertNotIn("bk_departures_upcoming", sql)

    def test_catalog_falls_back_to_tripplanner(self):
        rc, lines = run(FakeConn(refuse_roles={"booking"}))
        self.assertEqual(rc, 0)
        self.assertIn("SCRIPT catalog role=tripplanner rows=3 refused=booking:PgError", lines)

    def test_no_catalog_role_skips_catalog_layer_and_globals(self):
        rc, lines = run(FakeConn(refuse_roles={"booking", "tripplanner"}))
        self.assertEqual(rc, 0)
        self.assertIn("SCRIPT catalog role=- rows=None refused=booking:PgError,tripplanner:PgError", lines)
        self.assertFalse([x for x in lines if x.startswith("SCRIPT global ")])
        self.assertNotIn("catalog_v_tour", result(lines)["buckets"]["group_dead"]["layers"])
        # The checks that compare with the catalog cannot run: errors, so the nightly gate turns red.
        errors = result(lines)["errors"]
        self.assertEqual({e["layer"] for e in errors},
                         {"check.catalog_key_not_served", "check.served_key_not_in_catalog"})
        self.assertIn("SCRIPT verdict violations=0 errors=2 list=- pending=1", lines)

    def test_globals_count_references_the_catalog_no_longer_resolves(self):
        conn = FakeConn(
            plans=[{"id": "p1", "source_id": "k-dead", "sellable": True},
                   {"id": "p2", "source_id": "k-live", "sellable": True}],
            drafts=[{"id": "d1", "status": "draft", "ref": "t-dead"}, {"id": "d2", "status": "sent", "ref": "t-live"}],
            legs=[{"id": "c1", "source_id": None, "source_tour_id": "t-dead", "status": "open", "deleted": False}])
        _, lines = run(conn)
        g = result(lines)["global"]
        self.assertEqual(g["bk_sellable_plans_not_in_catalog"], {"n": 1, "sample": ["p1"]})
        self.assertEqual(g["tp_open_drafts_with_ref_not_in_catalog"], {"n": 1, "sample": ["d1"]})
        self.assertEqual(g["bk_open_cases_with_leg_not_in_catalog"], {"n": 1, "sample": ["c1"]})
        self.assertEqual(g["counts"], {"bk_trip_plans": 2, "bk_sellable": 2, "tp_draft_refs": 2, "bk_case_legs": 1})


def checks(lines):
    return result(lines)["checks"]


def verdict(lines):
    [line] = [x for x in lines if x.startswith("SCRIPT verdict ")]
    return line


class CheckTest(unittest.TestCase):
    """ADR 0015 decision 6: the served-state invariants, pending until their slice's objects exist."""

    def test_clean_l2_state_passes_and_later_slices_wait(self):
        _, lines = run(FakeConn())
        c = checks(lines)
        self.assertEqual(set(c), set(script.CHECKS))
        for name in ("masters_active_in_one_group", "master_active_over_dead_source", "catalog_key_not_served",
                     "lifecycle_record_contradicts_state"):
            self.assertEqual(c[name], {"slice": "L2", "expect": "zero", "n": 0, "sample": []}, name)
        self.assertEqual(c["tombstone_disagrees_with_state"],
                         {"slice": "L4", "expect": "pending", "n": None, "sample": [],
                          "requires": "catalog.v_tour_retired"})
        for name in ("t2_rewrite_after_not_served", "b2b_quotes_after_not_served", "b2b_holds_after_not_served"):
            self.assertEqual(c[name]["expect"], "keep_warn", name)  # ENFORCED_SINCE not set
        self.assertIn("SCRIPT check name=tombstone_disagrees_with_state slice=L4 expect=pending n=- sample=- "
                      "requires=catalog.v_tour_retired", lines)
        self.assertEqual(result(lines)["pending"], ["tombstone_disagrees_with_state"])

    def test_two_active_masters_and_master_over_dead_source_are_violations(self):
        _, lines = run(FakeConn(masters_dup=["k-sup"], masters_dead=["t-sup1"]))
        self.assertEqual(result(lines)["violations"],
                         ["check.masters_active_in_one_group", "check.master_active_over_dead_source"])
        self.assertIn("SCRIPT check name=masters_active_in_one_group slice=L2 expect=zero n=1 sample=k-sup", lines)

    def test_catalog_serving_a_key_the_view_calls_not_served_is_split_brain(self):
        liveness = [lv("k-live"), lv("k-sup", "paused", "master_inactive"), lv("k-ret"), lv("k-x")]
        _, lines = run(FakeConn(liveness=liveness))
        c = checks(lines)
        self.assertEqual((c["catalog_key_not_served"]["n"], c["catalog_key_not_served"]["sample"]), (1, ["k-sup"]))
        # A served key the catalog does not list is reported only (catalog.v_tour may filter more).
        self.assertEqual((c["served_key_not_in_catalog"]["expect"], c["served_key_not_in_catalog"]["n"]), ("info", 1))
        self.assertEqual(result(lines)["violations"], ["check.catalog_key_not_served"])

    def test_latest_lifecycle_event_must_match_the_derived_state(self):
        liveness = LIVENESS + [lv("k-gone", "retired", "source_deleted"), lv("k-swap", "paused", "superseded_pending"),
                               lv("k-old", "paused", "master_inactive"), lv("k-back")]
        events = {"k-gone": "retired", "k-swap": "superseded", "k-back": "restored",
                  "k-live": "retired"}  # k-live: retired in the record but served by the derived state
        _, lines = run(FakeConn(liveness=liveness, events=events))
        c = checks(lines)
        self.assertEqual(c["lifecycle_record_contradicts_state"]["sample"], ["k-live"])
        # k-old: paused with no event at all (changed before L2): kept, reported, never a violation.
        self.assertEqual(c["not_served_without_record"],
                         {"slice": "L2", "expect": "keep_warn", "n": 1, "sample": ["k-old"]})
        self.assertEqual(result(lines)["violations"], ["check.lifecycle_record_contradicts_state"])

    def test_all_superseded_group_with_a_master_needs_a_retired_record(self):
        liveness = LIVENESS + [lv("k-orph", "retired", "superseded_orphan"),
                               lv("k-orph-ok", "retired", "superseded_orphan"),
                               lv("k-old", "paused", "master_inactive")]
        _, lines = run(FakeConn(liveness=liveness, events={"k-orph-ok": "retired"}))
        c = checks(lines)
        self.assertEqual(c["superseded_orphan_without_retired"],
                         {"slice": "L2", "expect": "zero", "n": 1, "sample": ["k-orph"]})
        # The orphan is not also a keep_warn hit: not_served_without_record covers the other reasons.
        self.assertEqual(c["not_served_without_record"]["sample"], ["k-old"])
        self.assertEqual(result(lines)["violations"], ["check.superseded_orphan_without_retired"])

    def test_event_for_a_key_the_view_does_not_have_is_a_contradiction(self):
        _, lines = run(FakeConn(events={"k-ghost": "paused"}))
        self.assertEqual(checks(lines)["lifecycle_record_contradicts_state"]["sample"], ["k-ghost"])

    def test_tombstone_turns_strict_once_the_l4_view_exists(self):
        objects = dict(L2_OBJECTS, **{script.TOMBSTONE_VIEW: ["source_system", "source_id", "state", "reason"]})
        liveness = LIVENESS + [lv("k-gone", "retired", "source_deleted"), lv("k-swap", "paused", "superseded_pending"),
                               lv("k-miss", "retired", "master_trashed"), lv("k-old", "paused", "master_inactive")]
        events = {"k-gone": "retired", "k-swap": "superseded", "k-miss": "retired", "k-live": "restored"}
        tombstone = {"k-gone": "retired", "k-swap": "superseded_pending",  # agree
                     "k-live": "paused"}  # served again but its paused row was left open
        conn = FakeConn(objects=objects, liveness=liveness, events=events, tombstone=tombstone)
        _, lines = run(conn)
        c = checks(lines)["tombstone_disagrees_with_state"]
        # k-miss: retired with an event but no tombstone row. k-old: no event, so not compared.
        self.assertEqual((c["expect"], c["n"], c["sample"]), ("zero", 2, ["k-live", "k-miss"]))
        self.assertIn("check.tombstone_disagrees_with_state", result(lines)["violations"])
        self.assertIn("pending=0", verdict(lines))
        self.assertIn("SET LOCAL ROLE booking", conn.executed)

    def test_tombstone_with_other_column_names_is_an_error_not_a_silent_pass(self):
        objects = dict(L2_OBJECTS, **{script.TOMBSTONE_VIEW: ["key", "served_state"]})
        _, lines = run(FakeConn(objects=objects))
        [err] = result(lines)["errors"]
        self.assertEqual(err["layer"], "check.tombstone_disagrees_with_state")
        self.assertIn("lacks column(s) source_id, state", err["detail"])
        self.assertEqual(checks(lines)["tombstone_disagrees_with_state"]["error"], "tombstone unreadable")
        self.assertIn("errors=1", verdict(lines))

    def test_tombstone_read_error_is_counted(self):
        objects = dict(L2_OBJECTS, **{script.TOMBSTONE_VIEW: ["source_id", "state"]})
        _, lines = run(FakeConn(objects=objects, check_errors={"tombstone": PgError("permission denied", "42501")}))
        self.assertEqual([e["sqlstate"] for e in result(lines)["errors"]], ["42501"])

    def test_landed_l2_objects_that_go_missing_are_red_not_pending(self):
        # L2 is live: a later migration dropping / renaming its view or record must not turn the night green.
        self.assertIn("L2", script.LANDED)
        _, lines = run(FakeConn(objects={}))
        res = result(lines)
        c = res["checks"]
        self.assertEqual(c["masters_active_in_one_group"]["expect"], "zero")  # base tables only: always runs
        # The L4 check needs the L2 objects too: it cannot run, so it is an error as well (pending only when every
        # missing object belongs to a slice that has not landed).
        self.assertEqual(res["pending"], [])
        self.assertEqual([(e["layer"], e["error"]) for e in res["errors"]],
                         [("check.objects", "ObjectMissing")] * 2)
        self.assertIn(script.LIVENESS_VIEW, " ".join(e["detail"] for e in res["errors"]))
        for name in (n for n, d in script.CHECKS.items() if d[2]):
            self.assertTrue(c[name]["error"].startswith("object missing: "), name)
            self.assertNotIn(script.TOMBSTONE_VIEW, c[name]["error"])  # only landed objects are named
        self.assertIn("SCRIPT verdict violations=0 errors=2 list=- pending=0", lines)

    def test_not_landed_slice_stays_pending(self):
        with mock.patch.object(script, "LANDED", frozenset()):
            _, lines = run(FakeConn(objects={}))
        self.assertEqual(set(result(lines)["pending"]), {n for n, d in script.CHECKS.items() if d[2]})
        self.assertIn("errors=0", verdict(lines))

    def test_landed_l4_tombstone_that_goes_missing_is_red(self):
        with mock.patch.object(script, "LANDED", frozenset({"L2", "L4"})):
            _, lines = run(FakeConn())
        res = result(lines)
        self.assertEqual(res["pending"], [])
        self.assertEqual(res["checks"]["tombstone_disagrees_with_state"]["error"],
                         "object missing: " + script.TOMBSTONE_VIEW)
        self.assertEqual(res["landed"], ["L2", "L4"])
        self.assertIn("errors=1", verdict(lines))

    def test_after_checks_are_keep_warn_until_the_slice_is_live(self):
        retired_at = T0 + timedelta(days=1)
        liveness = LIVENESS + [lv("k-gone", "retired", "source_deleted", changed_at=retired_at)]
        rows = {"b2b_quotes_after_not_served": [("k-gone", retired_at - timedelta(hours=1), "q-before"),
                                                ("k-gone", retired_at + timedelta(hours=1), "q-after")],
                "b2b_holds_after_not_served": [("k-gone", retired_at + timedelta(days=5), "h-late")]}
        conn = FakeConn(liveness=liveness, events={"k-gone": "retired"}, after_rows=rows)
        _, lines = run(conn)
        c = checks(lines)
        self.assertEqual(c["b2b_quotes_after_not_served"],
                         {"slice": "L5", "expect": "keep_warn", "n": 1, "sample": ["q-after"]})
        self.assertEqual(conn.after_args["b2b_quotes_after_not_served"], {"k-gone": retired_at})
        self.assertEqual(result(lines)["violations"], [])

        # L5 live on Dev from retired_at + 2 days: only what was created after that date counts, as a violation.
        with mock.patch.dict(script.ENFORCED_SINCE, {"L5": (retired_at + timedelta(days=2)).date().isoformat()}):
            conn = FakeConn(liveness=liveness, events={"k-gone": "retired"}, after_rows=rows)
            _, lines = run(conn)
        c = checks(lines)
        self.assertEqual((c["b2b_quotes_after_not_served"]["expect"], c["b2b_quotes_after_not_served"]["n"]),
                         ("zero", 0))
        self.assertEqual(c["b2b_holds_after_not_served"]["sample"], ["h-late"])
        self.assertEqual(c["t2_rewrite_after_not_served"]["expect"], "keep_warn")  # L3 still not live
        self.assertEqual(result(lines)["violations"], ["check.b2b_holds_after_not_served"])
        self.assertEqual(result(lines)["enforced_since"]["L5"], (retired_at + timedelta(days=2)).date().isoformat())

    def test_no_key_out_of_service_runs_no_after_query(self):
        conn = FakeConn()
        run(conn)
        self.assertEqual(conn.after_args, {})

    def test_failed_check_query_is_an_error_with_sqlstate_only(self):
        secret = 'invalid input syntax for type uuid: "Jane Doe"'
        _, lines = run(FakeConn(check_errors={"master_active_over_dead_source": PgError(secret, "22P02")}))
        self.assertNotIn("Jane", "\n".join(lines))
        [err] = result(lines)["errors"]
        self.assertEqual((err["layer"], err["sqlstate"], "detail" in err),
                         ("check.master_active_over_dead_source", "22P02", False))
        self.assertIn("SCRIPT check name=master_active_over_dead_source slice=L2 expect=zero n=- sample=-", lines)

    def test_unreadable_object_catalog_fails_every_check_loudly(self):
        _, lines = run(FakeConn(check_errors={"objects": PgError("boom", "57014")}))
        res = result(lines)
        self.assertEqual([e["layer"] for e in res["errors"]], ["check.objects"])
        self.assertTrue(all(r.get("error") == "objects unreadable" for r in res["checks"].values()))
        self.assertIn("errors=1", verdict(lines))

    def test_enforced_since_values_are_dates_or_none(self):
        self.assertEqual(set(script.ENFORCED_SINCE), {"L3", "L5"})
        for v in script.ENFORCED_SINCE.values():
            self.assertTrue(v is None or re.fullmatch(r"\d{4}-\d{2}-\d{2}", v), v)
        self.assertTrue(all(d[0] in ("L2", "L3", "L4", "L5") for d in script.CHECKS.values()))
        self.assertTrue(all(d[1] in ("zero", "keep_warn", "info") or d[1] in ("after:L3", "after:L5")
                            for d in script.CHECKS.values()))
        self.assertEqual(set(script.AFTER_SQL), {n for n, d in script.CHECKS.items() if d[1].startswith("after:")})


class VisibilityFloorTest(unittest.TestCase):
    """raw_tours / published_tours are FORCE RLS: a login that lost its cis_owner / cis_app membership reads 0 rows
    with no error. Every `zero` result would then be a silent pass; the floor makes the run red instead."""

    def test_clean_run_reports_its_visibility(self):
        _, lines = run(FakeConn())
        self.assertEqual(result(lines)["visibility"],
                         {"versions": 6, "groups": 5, "active_masters": 3, "catalog_rows": 3, "catalog_keys": 3,
                          "liveness_keys": 3, "liveness_served": 3})
        self.assertIn("SCRIPT visibility versions=6 groups=5 active_masters=3 catalog_rows=3 catalog_keys=3 "
                      "liveness_keys=3 liveness_served=3", lines)

    def test_login_that_sees_no_rows_is_red(self):
        # Every master read empty (RLS hides all), the catalog role and the owner-rights view still see rows.
        _, lines = run(FakeConn(versions=[], active_masters=0))
        res = result(lines)
        floor = [e["detail"] for e in res["errors"] if e["layer"] == "check.visibility"]
        self.assertEqual(len(floor), 3, floor)
        self.assertTrue(any("0 AA source versions" in d for d in floor))
        self.assertTrue(any("0 active AA Masters" in d for d in floor))
        self.assertTrue(any("more keys than the login sees" in d for d in floor))
        self.assertEqual(res["violations"], [])  # nothing to see, so nothing found: only the floor catches it
        self.assertIn("errors=3", verdict(lines))

    def test_liveness_view_with_fewer_served_keys_than_the_catalog_is_red(self):
        _, lines = run(FakeConn(liveness=[lv("k-live")]))
        floor = [e["detail"] for e in result(lines)["errors"] if e["layer"] == "check.visibility"]
        self.assertEqual(len(floor), 1)
        self.assertIn("fewer served keys than catalog.v_tour", floor[0])

    def test_no_catalog_skips_the_catalog_comparisons_only(self):
        _, lines = run(FakeConn(refuse_roles={"booking", "tripplanner"}, active_masters=0))
        self.assertFalse([e for e in result(lines)["errors"] if e["layer"] == "check.visibility"])


UUIDS = [f"00000000-0000-0000-0000-{i:012d}" for i in range(1, 6)]


class JsonSizeTest(unittest.TestCase):
    """CloudWatch (awslogs) splits a container log line over ~16 KB into several events: no line may get near it."""

    def worst_case(self):
        # Every bucket non-empty, every layer and check with 5 uuid-long samples, keep_warn hits everywhere.
        versions = list(VERSIONS) + [ver("t-pho", "k-pho", stage="phasing_out")]
        refs = {v["tour_id"] for v in versions} | {v["source_key"] for v in versions}
        hits = {name: {r: UUIDS for r in refs} for name, *_ in script.LAYERS}
        catalog = [{"source_id": v["source_key"], "tour_id": v["tour_id"]} for v in versions]
        liveness = [lv(f"{c['source_id']}") for c in catalog[:1]] + [
            lv(f"k-{i:034d}", "retired", "source_deleted") for i in range(40)] + [
            lv(f"k-o{i:033d}", "retired", "superseded_orphan") for i in range(40)]
        events = {f"k-{i:034d}": "paused" for i in range(40)}
        after = {n: [(r["source_id"], r["changed_at"] + timedelta(days=1), u) for r in liveness[1:] for u in UUIDS]
                 for n in script.AFTER_SQL}
        conn = FakeConn(versions=versions, catalog=catalog, liveness=liveness, events=events, after_rows=after,
                        layer_hits=hits, masters_dup=UUIDS, masters_dead=UUIDS,
                        plans=[{"id": u, "source_id": "gone", "sellable": True} for u in UUIDS],
                        drafts=[{"id": u, "status": "draft", "ref": u} for u in UUIDS],
                        legs=[{"id": u, "source_id": u, "source_tour_id": None, "status": "open", "deleted": False}
                              for u in UUIDS])
        return run(conn)[1]

    def test_worst_case_lines_stay_well_under_the_split_size(self):
        lines = self.worst_case()
        self.assertLess(max(len(x.encode()) for x in lines), 12_000)
        res = result(lines)
        self.assertGreater(len(json.dumps(res)), script.JSON_CHUNK)  # big enough to need several parts
        self.assertGreater(len([x for x in lines if x.startswith("SCRIPT json[")]), 1)
        self.assertTrue(res["violations"])

    def test_parts_keep_their_edge_spaces_and_rejoin_exactly(self):
        res = {"detail": " a  b " * 5000, "n": 1}
        out = io.StringIO()
        with contextlib.redirect_stdout(out), mock.patch.object(script, "JSON_CHUNK", 7):
            script.emit_json(res)
        parts = [JSON_PART_RE.match(x) for x in out.getvalue().splitlines()]
        self.assertTrue(all(parts))
        self.assertTrue(all(len(m[3]) <= 7 for m in parts))
        self.assertTrue(any(m[3] != m[3].strip() for m in parts))  # cut inside a run of spaces, kept by the `|`
        self.assertEqual(json.loads("".join(m[3] for m in parts)), res)


class PublicLogTest(unittest.TestCase):
    """The Actions log is public: ids, keys, statuses and counts only."""

    def test_data_error_message_is_not_printed(self):
        secret = 'invalid input syntax for type uuid: "Jane Doe +84 90 000 0000"'
        conn = FakeConn(layer_errors={"tp_drafts_open": PgError(secret, "22P02"),
                                      "bk_trip_cases_open": PgError('column "x" does not exist', "42703")})
        rc, lines = run(conn)
        self.assertEqual(rc, 0)
        text = "\n".join(lines)
        self.assertNotIn("Jane", text)
        self.assertNotIn("+84", text)
        errors = result(lines)["errors"]
        drafts = [e for e in errors if e["layer"].endswith(".tp_drafts_open")]
        self.assertTrue(drafts and all("detail" not in e and e["sqlstate"] == "22P02" for e in drafts))
        cases = [e for e in errors if e["layer"].endswith(".bk_trip_cases_open")]
        self.assertTrue(cases and all(e["detail"] == 'column "x" does not exist' for e in cases))
        self.assertIn(f"errors={len(errors)}", [x for x in lines if x.startswith("SCRIPT verdict ")][0])

    def test_free_text_refs_are_masked(self):
        conn = FakeConn(drafts=[{"id": "d1", "status": "draft", "ref": "call me at jane@example.com"}])
        _, lines = run(conn)
        text = "\n".join(lines)
        self.assertNotIn("@", text)
        self.assertEqual(result(lines)["global"]["tp_draft_refs_not_in_catalog"]["sample"], ["masked"])

    def test_sample_values_are_id_shaped(self):
        conn = FakeConn(layer_hits={"bk_trip_plans": {"k-dead": ["p1"]}})
        _, lines = run(conn)
        for x in lines:
            m = re.search(r" sample=(\S*)", x)
            if m and not x.startswith("SCRIPT json["):
                for v in m.group(1).split(","):
                    self.assertRegex(v, r"^([A-Za-z0-9:_-]+|-)$")
        self.assertEqual(script.safe_id("00000000-0000-0000-0000-000000000001"),
                         "00000000-0000-0000-0000-000000000001")
        self.assertEqual(script.safe_id("tp:123"), "tp:123")
        self.assertEqual(script.safe_id("a b"), "masked")


if __name__ == "__main__":
    unittest.main()
