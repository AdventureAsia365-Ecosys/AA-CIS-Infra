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
from pathlib import Path

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


class PgError(Exception):
    def __init__(self, msg, sqlstate):
        super().__init__(msg)
        self.sqlstate = sqlstate


class FakeConn:
    def __init__(self, *, catalog=CATALOG, refuse_roles=(), layer_hits=None, layer_errors=None, plans=(),
                 drafts=(), legs=()):
        self.catalog, self.refuse_roles = catalog, set(refuse_roles)
        self.layer_hits, self.layer_errors = layer_hits or {}, layer_errors or {}
        self.plans, self.drafts, self.legs = list(plans), list(drafts), list(legs)
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
        return "aa_cis_admin"

    async def fetch(self, sql, *args):
        self.sql_seen.append(sql)
        if sql == script.CATALOG_SQL:
            return self.catalog
        if sql == script.VERSIONS_SQL:
            assert args == (script.AA_MASTER,)
            return VERSIONS
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


def result(lines):
    [line] = [x for x in lines if x.startswith("SCRIPT json ")]
    return json.loads(line[len("SCRIPT json "):])


class ShapeTest(unittest.TestCase):
    def test_runner_accepts_the_file_and_it_is_read_only(self):
        source = (ROOT / PATH).read_text(encoding="utf-8")
        self.assertEqual(rm.script_errors(source, PATH), [])
        self.assertTrue(rm.script_is_read_only(source))
        self.assertIs(script.READ_ONLY, True)

    def test_every_statement_is_a_read(self):
        sqls = [script.VERSIONS_SQL, script.CATALOG_SQL, script.PLANS_SQL, script.DRAFT_REFS_SQL,
                script.LEG_REFS_SQL, script.WRAP] + [inner for *_, inner in script.LAYERS]
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
        self.assertEqual(kinds, {"catalog", "bucket", "layer", "global", "verdict", "json"})
        self.assertIn("SCRIPT catalog role=booking rows=3 refused=-", lines)
        self.assertIn("SCRIPT verdict violations=0 errors=0 list=-", lines)
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
            if m and not x.startswith("SCRIPT json"):
                for v in m.group(1).split(","):
                    self.assertRegex(v, r"^([A-Za-z0-9:_-]+|-)$")
        self.assertEqual(script.safe_id("00000000-0000-0000-0000-000000000001"),
                         "00000000-0000-0000-0000-000000000001")
        self.assertEqual(script.safe_id("tp:123"), "tp:123")
        self.assertEqual(script.safe_id("a b"), "masked")


if __name__ == "__main__":
    unittest.main()
