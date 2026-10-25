"""AA-991: db/scripts/aa991_freshness_probe.py (downstream freshness probe) and db/freshness_gate.py (its verdict).

No database, no asyncpg: a fake connection answers the probe's SQL by matching on it. The SQL itself runs against a
real PostgreSQL in test_aa991_freshness_probe_pg.py (local, AA991_TEST_PG_DSN).
Run: python3 -m unittest discover -s db/tests -v
"""
import asyncio
import contextlib
import importlib.util
import io
import json
import re
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import freshness_gate as gate  # noqa: E402
import run_migration as rm  # noqa: E402

ROOT = HERE.parent.parent
PATH = "db/scripts/aa991_freshness_probe.py"
_spec = importlib.util.spec_from_file_location("aa991_freshness_probe", ROOT / PATH)
probe = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(probe)

WRITE_RE = re.compile(r"\b(INSERT|UPDATE|DELETE|MERGE|TRUNCATE|CREATE|ALTER|DROP|GRANT|REVOKE|COPY|CALL|DO)\b", re.I)
NOW = datetime(2026, 10, 25, 12, tzinfo=timezone.utc)
CUTOFF = NOW - timedelta(hours=24)
RAN_AS = "MIGRATE ran as: aa_cis_admin (run-script, READ_ONLY: default_transaction_read_only=on)"
HEADER = ["MIGRATE run-script: file=db/scripts/aa991_freshness_probe.py sha256=0123456789ab", RAN_AS,
          "MIGRATE run-script: main(conn) starts; its output follows"]
FOOTER = ["MIGRATE run-script: done"]
TOTALS = {"active_tours": 892, "active_atoms": 25877, "segments": 18978, "current_routes": 1200,
          "current_ranking_rows": 90000, "tour_place_rows": 2480, "place_card_links": 291, "tenant_versions": 55,
          "angle_gate_requests": 25, "seo_context_rows": 918}


class PgError(Exception):
    def __init__(self, msg, sqlstate):
        super().__init__(msg)
        self.sqlstate = sqlstate


def m(n=0, aged=0, ids=()):
    ids = list(ids)
    return {"n": n, "aged": aged, "sample": ids[:5], "sample_aged": ids[:aged][:5]}


def mo(tour, seg, day, place):
    return {"tour_id": tour, "segment_id": seg, "day": day, "place": place}


class FakeConn:
    """Answers the probe's statements; records them. `metrics` = {name: {"n", "aged", "sample", "sample_aged"}}."""

    def __init__(self, *, metrics=None, errors=None, refuse_role=False, moments=(), routes=(), chg=(), jobs=(),
                 totals=None, read_as="cis_app"):
        self.metrics, self.errors, self.refuse_role = metrics or {}, errors or {}, refuse_role
        self.moments, self.routes, self.chg, self.jobs = list(moments), list(routes), list(chg), list(jobs)
        self.totals = dict(TOTALS if totals is None else totals)
        self.read_as = read_as
        self.statements, self.tx = [], []

    @contextlib.asynccontextmanager
    async def _tx(self, kw):
        self.tx.append(kw)
        yield

    def transaction(self, **kw):
        return self._tx(kw)

    async def execute(self, sql, *args):
        self.statements.append(sql)
        if "SET LOCAL ROLE" in sql and self.refuse_role:
            raise PgError("permission denied to set role \"cis_app\"", "42501")

    async def fetchval(self, sql, *args):
        self.statements.append(sql)
        if "session_user" in sql:
            return "aa_cis_admin"
        if "current_user" in sql:
            return self.read_as
        if "make_interval" in sql:
            return CUTOFF
        raise AssertionError(sql)

    async def fetchrow(self, sql, *args):
        self.statements.append(sql)
        if sql == probe.TOTALS_SQL:
            return self.totals
        for name, (_g, _u, inner) in probe.METRICS.items():
            if inner in sql:
                if name in self.errors:
                    raise self.errors[name]
                r = self.metrics.get(name, m())
                return {"n": r["n"], "aged": r["aged"], "sample": r["sample"], "sample_aged": r["sample_aged"]}
        raise AssertionError(sql)

    async def fetch(self, sql, *args):
        self.statements.append(sql)
        if sql == probe.MOMENTS_SQL:
            if "routes" in self.errors:
                raise self.errors["routes"]
            return self.moments
        if sql == probe.CURRENT_ROUTES_SQL:
            return self.routes
        if sql == probe.CHG_SQL:
            return self.chg
        if sql == probe.JOBS_SQL:
            return self.jobs
        raise AssertionError(sql)


def run(conn):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = asyncio.run(probe.main(conn))
    lines = buf.getvalue().splitlines()
    return rc, lines


def result(lines):
    res, why = gate.read_json(lines)
    assert why is None, why
    return res


def log(**kw):
    return HEADER + run(FakeConn(**kw))[1] + FOOTER


class ProbeShapeTest(unittest.TestCase):
    def test_runner_accepts_the_file_and_it_is_read_only(self):
        src = (ROOT / PATH).read_text()
        self.assertEqual(rm.script_errors(src, PATH), [])
        self.assertTrue(rm.script_is_read_only(src))

    def test_every_statement_is_a_read(self):
        sqls = [inner for _g, _u, inner in probe.METRICS.values()] + [
            probe.CHG, probe.WRAP, probe.MOMENTS_SQL, probe.CURRENT_ROUTES_SQL, probe.CHG_SQL, probe.TOTALS_SQL,
            probe.JOBS_SQL]
        for sql in sqls:
            self.assertIsNone(WRITE_RE.search(sql), sql)

    def test_metric_lists_agree(self):
        names = list(probe.METRICS) + list(probe.ROUTE_METRICS)
        self.assertEqual(sorted(probe.ORDER), sorted(names))
        self.assertEqual(len(set(probe.ORDER)), len(probe.ORDER))
        self.assertEqual(set(gate.BASELINE), set(names))
        for name, spec in list(probe.METRICS.items()) + list(probe.ROUTE_METRICS.items()):
            self.assertIn(spec[0], ("stale", "info"), name)

    def test_orphan_segments_are_split_by_every_reference_the_cis_gc_respects(self):
        # AA-988: the stale metric = what AA-CIS-App segment_gc deletes; the info twin = what a reference keeps
        sql = " ".join(probe.ORPHAN_SETS.split())
        for frag in ("acp_contract.v_active_tour_atoms", "NOT t.deleted AND NOT t.is_empty_marker",
                     "FROM acp_contract.atom_ranking WHERE superseded_at IS NULL", "FROM acp_contract.atom_ranking)",
                     "segment_id_old", "segment_id_canonical", "FROM acp_shared.subject",
                     "acp_shared.debate_brand_fit_cache", "sj.route_id = r.route_id", "g.route_segment_ids",
                     "WHERE am.segment_id IS NULL AND cr.segment_id IS NULL AND ct.segment_id IS NULL"):
            self.assertIn(frag, sql)
        self.assertIn("WHERE NOT o.referenced", probe.METRICS["orphan_segments"][2])
        self.assertIn("WHERE o.referenced", probe.METRICS["orphan_segments_kept_referenced"][2])
        self.assertEqual(probe.METRICS["orphan_segments_kept_referenced"][0], "info")

    def test_seo_metric_reads_the_newest_row_and_the_s1_reuse_rule(self):
        sql = " ".join(probe.METRICS["seo_context_expired_active_tours"][2].split())
        self.assertIn("DISTINCT ON (tour_id)", sql)
        self.assertIn("ORDER BY tour_id, fetched_at DESC", sql)
        self.assertIn("LIKE '%:ideas_v3'", sql)
        self.assertIn("make_interval(days => 180)", sql)

    def test_every_metric_returns_id_and_aged_and_uses_the_cutoff(self):
        for name, (_g, _u, inner) in probe.METRICS.items():
            with self.subTest(metric=name):
                self.assertIn(" AS id", inner)
                self.assertIn("< $1 AS aged", inner)

    def test_shipped_in_report_mode_and_reads_as_cis_app(self):
        self.assertIs(gate.ENFORCE, False)
        self.assertEqual((probe.READ_ROLE, gate.READ_ROLE), ("cis_app", "cis_app"))
        self.assertEqual(probe.STALE_AFTER_HOURS, 24)


class RoutePortTest(unittest.TestCase):
    """derive_routes() must match AA-CIS-App services/acp_contract/route_detection.py (ported verbatim)."""

    def test_constants_match_route_detection(self):
        self.assertEqual((probe.LEAST_DAYS, probe.LEAST_PLACES, probe.MOST_DAYS), (2, 2, 5))

    def test_two_days_two_places_is_a_route(self):
        r = probe.derive_routes([mo("t", "s2", 2, "Nara"), mo("t", "s1", 1, "Kyoto")])
        self.assertEqual(r, {("t", 1, 2): ("s1", "s2")})

    def test_a_gap_day_breaks_the_run_and_short_runs_are_not_routes(self):
        r = probe.derive_routes([mo("t", "a", 1, "A"), mo("t", "b", 2, "B"), mo("t", "c", 4, "C")])
        self.assertEqual(r, {("t", 1, 2): ("a", "b")})

    def test_one_place_over_two_days_is_a_stay_not_a_route(self):
        self.assertEqual(probe.derive_routes([mo("t", "a", 1, "A"), mo("t", "b", 2, "A")]), {})

    def test_long_runs_are_cut_in_fives_and_a_one_day_tail_joins_the_span_before(self):
        seven = [mo("t", f"s{d}", d, f"P{d}") for d in range(1, 8)]
        self.assertEqual(sorted(probe.derive_routes(seven)), [("t", 1, 5), ("t", 6, 7)])
        six = [mo("t", f"s{d}", d, f"P{d}") for d in range(1, 7)]
        self.assertEqual(sorted(probe.derive_routes(six)), [("t", 1, 6)])

    def test_moments_of_one_day_order_by_segment_id(self):
        r = probe.derive_routes([mo("t", "z", 1, "A"), mo("t", "a", 1, "B"), mo("t", "m", 2, "C")])
        self.assertEqual(r[("t", 1, 2)], ("a", "z", "m"))

    def test_parity_names_missing_and_differing_tours_and_ages_them(self):
        moments = [mo("t1", "a", 1, "A"), mo("t1", "b", 2, "B"), mo("t2", "c", 1, "C"), mo("t2", "d", 2, "D")]
        routes = [{"route_id": "t1:1-2", "tour_id": "t1", "segs": '["a", "b"]', "first_day": 1, "last_day": 2,
                   "created_at": NOW - timedelta(days=9)},
                  {"route_id": "t3:1-2", "tour_id": "t3", "segs": '["x", "y"]', "first_day": 1, "last_day": 2,
                   "created_at": NOW - timedelta(days=9)},
                  {"route_id": "t4:1-3", "tour_id": "t4", "segs": '["e"]', "first_day": 1, "last_day": 3,
                   "created_at": NOW - timedelta(hours=1)}]
        chg = {"t2": {"changed_at": NOW - timedelta(hours=2)}, "t3": {"changed_at": NOW - timedelta(days=3)}}
        res, stats = probe.route_parity(moments, routes, chg, CUTOFF)
        self.assertEqual(res["routes_missing"], {"n": 1, "aged": 0, "sample": ["t2"], "sample_aged": []})
        self.assertEqual(res["routes_differ"]["n"], 2)
        self.assertEqual(res["routes_differ"]["sample_aged"], ["t3"])     # t4: no change record, route 1 h old
        self.assertEqual(stats, {"expected_routes": 2, "current_routes_compared": 3})

    def test_same_identity_with_other_segments_differs(self):
        routes = [{"route_id": "t:1-2", "tour_id": "t", "segs": ["a", "c"], "first_day": 1, "last_day": 2,
                   "created_at": NOW}]
        res, _ = probe.route_parity([mo("t", "a", 1, "A"), mo("t", "b", 2, "B")], routes, {}, CUTOFF)
        self.assertEqual((res["routes_missing"]["n"], res["routes_differ"]["n"]), (0, 1))


class ProbeRunTest(unittest.TestCase):
    def test_clean_run_shape(self):
        conn = FakeConn(jobs=[{"kind": "recompute", "status": "queued", "n": 1}])
        rc, lines = run(conn)
        self.assertEqual(rc, 0)
        res = result(lines)
        self.assertEqual(lines[0], "SCRIPT role read_as=cis_app login=aa_cis_admin")
        self.assertIn("SCRIPT verdict stale=0 stale_aged=0 errors=0 list=-", lines)
        self.assertIn("SCRIPT jobs kind=recompute status=queued n=1", lines)
        self.assertEqual(list(res["metrics"]), list(probe.METRICS) + list(probe.ROUTE_METRICS))
        self.assertEqual([x.split()[2] for x in lines if x.startswith("SCRIPT metric ")],
                         [f"name={n}" for n in probe.ORDER])
        self.assertEqual(res["errors"], [])
        self.assertEqual(res["totals"]["tours_changed_within_window"], 0)

    def test_reads_in_one_read_only_snapshot_as_cis_app_and_never_writes(self):
        conn = FakeConn()
        run(conn)
        self.assertEqual(conn.tx[0], {"isolation": "repeatable_read", "readonly": True})
        self.assertIn("SET LOCAL ROLE cis_app", conn.statements)
        self.assertLess(conn.statements.index("SET LOCAL ROLE cis_app"),
                        min(i for i, s in enumerate(conn.statements) if "acp_contract" in s))
        for sql in conn.statements:
            if sql.startswith("SET LOCAL"):
                continue
            self.assertIsNone(WRITE_RE.search(sql), sql)

    def test_stale_links_are_counted_and_listed_by_aged(self):
        metrics = {"atoms_older_than_master": m(2, 1, ["t1", "t2"]), "ranking_missing": m(3, 0, ["t3"]),
                   "active_atoms_without_segment": m(9004, 9000, ["a1"])}
        res = result(run(FakeConn(metrics=metrics))[1])
        self.assertEqual(res["verdict"], {"stale": 2, "stale_aged": 1, "errors": 0,
                                          "list": ["atoms_older_than_master"]})

    def test_failed_metric_is_an_error_with_sqlstate_only(self):
        errs = {"orphan_segments": PgError("value 'Secret Row Text' is wrong", "22P02"),
                "seo_context_expired": PgError('column "expires_at" does not exist', "42703")}
        res = result(run(FakeConn(errors=errs))[1])
        by = {e["metric"]: e for e in res["errors"]}
        self.assertEqual(by["orphan_segments"], {"metric": "orphan_segments", "error": "PgError", "sqlstate": "22P02"})
        self.assertIn("expires_at", by["seo_context_expired"]["detail"])
        self.assertIsNone(res["metrics"]["orphan_segments"]["n"])
        self.assertEqual(res["verdict"]["errors"], 2)
        self.assertNotIn("Secret Row Text", "\n".join(run(FakeConn(errors=errs))[1]))

    def test_route_read_error_marks_both_route_metrics(self):
        res = result(run(FakeConn(errors={"routes": PgError("boom", "57014")}))[1])
        self.assertEqual({e["metric"] for e in res["errors"]}, {"routes_missing", "routes_differ"})
        self.assertIsNone(res["metrics"]["routes_missing"]["n"])

    def test_refused_role_switch_measures_nothing_and_is_an_error(self):
        rc, lines = run(FakeConn(refuse_role=True))
        res = result(lines)
        self.assertEqual(rc, 0)
        self.assertEqual(res["metrics"], {})
        self.assertEqual(res["errors"][0]["metric"], "session")
        self.assertIn("SCRIPT verdict stale=0 stale_aged=0 errors=1 list=-", lines)

    def test_visibility_floor(self):
        res = result(run(FakeConn(totals=dict(TOTALS, active_tours=0)))[1])
        self.assertEqual([e["metric"] for e in res["errors"]], ["visibility"])

    def test_unsafe_ids_are_masked(self):
        res = result(run(FakeConn(metrics={"orphan_segments": m(1, 1, ["has space; drop"])}))[1])
        self.assertEqual(res["metrics"]["orphan_segments"]["sample"], ["masked"])

    def test_json_parts_rejoin(self):
        many = {name: m(7, 7, [f"id-{i:04d}-{'x' * 60}" for i in range(5)]) for name in probe.METRICS}
        lines = run(FakeConn(metrics=many))[1]
        parts = [x for x in lines if x.startswith("SCRIPT json[")]
        self.assertGreater(len(parts), 1)
        self.assertTrue(all(len(x) < probe.JSON_CHUNK + 40 for x in parts))
        self.assertEqual(result(lines)["metrics"]["orphan_segments"]["n"], 7)


class GateTest(unittest.TestCase):
    def test_clean_report_run_is_green(self):
        g = gate.evaluate(log(), "0")
        self.assertTrue(g["green"], g["failures"])
        self.assertEqual((g["mode"], g["would_fail"], g["warnings"]), ("report", [], []))

    def test_report_mode_stays_green_on_stale_links_and_lists_them(self):
        g = gate.evaluate(log(metrics={"orphan_segments": m(8578, 8578, ["s1"]),
                                       "atoms_older_than_master": m(1, 1, ["t1"])}), "0")
        self.assertTrue(g["green"], g["failures"])
        self.assertEqual(g["would_fail"], ["atoms_older_than_master", "orphan_segments"])
        self.assertEqual(g["above_baseline"], ["atoms_older_than_master"])   # 1 > 0; 8578 is the baseline itself
        self.assertTrue(any(n.startswith("report-only: red once enforced") for n in g["notes"]))

    def test_enforce_is_red_on_aged_stale_links_only(self):
        g = gate.evaluate(log(metrics={"ranking_missing": m(3, 0, ["t3"]),
                                       "active_atoms_without_segment": m(5, 5, ["a"])}), "0", enforce=True)
        self.assertTrue(g["green"], g["failures"])      # not aged, and an info metric never counts
        g = gate.evaluate(log(metrics={"routes_missing": m(0), "orphan_segments": m(2, 2, ["s1", "s2"])}), "0",
                          enforce=True)
        self.assertFalse(g["green"])
        self.assertEqual([f for f in g["failures"] if f.startswith("stale: ")],
                         ["stale: orphan_segments has 2 link(s) of tours changed more than 24 h ago (sample: s1, s2)"])

    def test_probe_failures_are_red_in_both_modes(self):
        cases = {
            "exit": (log(), "13"),
            "not read-only": ([x for x in log() if x != RAN_AS], "0"),
            "no verdict": ([x for x in log() if not x.startswith("SCRIPT verdict")], "0"),
            "cut json": ([x[:-1] if x.startswith("SCRIPT json[1/") else x for x in log()], "0"),
            "metric error": (log(errors={"orphan_segments": PgError("x", "57014")}), "0"),
            "role refused": (log(refuse_role=True), "0"),
            "read as master": (log(read_as="aa_cis_admin"), "0"),
        }
        for name, (lines, code) in cases.items():
            with self.subTest(case=name):
                self.assertFalse(gate.evaluate(lines, code)["green"])

    def test_verdict_and_json_must_agree(self):
        lines = [x.replace("stale_aged=0", "stale_aged=4") if x.startswith("SCRIPT verdict") else x for x in log()]
        g = gate.evaluate(lines, "0")
        self.assertIn("the verdict line and the JSON disagree on errors / stale_aged", g["failures"])

    def test_a_metric_dropped_from_the_probe_is_red(self):
        lines = log()
        res = result(lines)
        del res["metrics"]["seo_context_expired_active_tours"]
        body = json.dumps(res, default=str, separators=(",", ":"))
        lines = [x for x in lines if not x.startswith("SCRIPT json[")] + [f"SCRIPT json[1/1] {body}|"]
        g = gate.evaluate(lines, "0")
        self.assertIn("metric(s) of the baseline missing from the probe: seo_context_expired_active_tours",
                      g["failures"])

    def test_markdown_and_files(self):
        lines = log(metrics={"angle_gate_requests_on_inactive_atoms": m(14, 14, ["r1"])},
                    jobs=[{"kind": "a3_atomize", "status": "running", "n": 1}])
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            (p / "task.log").write_text("\n".join(lines) + "\n")
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = gate.main(["--log", str(p / "task.log"), "--exit-code", "0", "--summary", str(p / "s.md"),
                                "--out", str(p / "g.json"), "--reason", "nightly"])
            self.assertEqual(rc, 0)
            md = (p / "s.md").read_text()
            self.assertIn("### Downstream freshness probe (nightly, mode report)", md)
            self.assertIn("| `angle_gate_requests_on_inactive_atoms` | stale | 14 | 14 | 14 | +0 | r1 |", md)
            self.assertIn("| `routes_missing` | stale | 0 | 0 | first run | - | - |", md)
            self.assertIn("propagation jobs in flight: a3_atomize running 1", md)
            saved = json.loads((p / "g.json").read_text())
            self.assertEqual((saved["mode"], saved["baseline_as_of"]), ("report", "S251 2026-10-25"))
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(gate.main(["--log", str(p / "task.log"), "--exit-code", "0", "--enforce"]), 1)


class WorkflowTest(unittest.TestCase):
    TEXT = (ROOT / ".github" / "workflows" / "db-freshness-probe.yml").read_text()

    def test_runs_this_probe_and_this_gate_nightly_in_its_own_group(self):
        self.assertIn(f"SCRIPT: {PATH}", self.TEXT)
        self.assertIn("python3 db/freshness_gate.py --log task.log", self.TEXT)
        self.assertIn('- cron: "13 5 * * *"', self.TEXT)
        self.assertIn("group: db-freshness-probe", self.TEXT)
        self.assertIn("if: github.ref == 'refs/heads/main'", self.TEXT)

    def test_enforce_is_an_explicit_dispatch_input_off_by_default(self):
        self.assertRegex(self.TEXT, r"enforce:\n\s+description: .*\n\s+required: false\n\s+type: boolean\n"
                                    r"\s+default: false")
        self.assertIn("${{ inputs.enforce && '--enforce' || '' }}", self.TEXT)

    def test_only_read_only_scripts_run_and_the_runner_sha_is_checked(self):
        self.assertIn("r.script_is_read_only(open(sys.argv[1]).read())", self.TEXT)
        self.assertIn("exit('runner sha256 mismatch: '+h)", self.TEXT)


if __name__ == "__main__":
    unittest.main()
