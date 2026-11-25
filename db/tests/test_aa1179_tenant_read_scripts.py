"""AA-1179 (S293): db/scripts/aa1179_tenant_read_cost.py and aa1179_tenant_read_parity.py (read-only, run-script).

Standard library only (the db/tests CI image has no asyncpg): the runner's shape check, the verbatim statements, the
pure helpers, and one run of each main() on a fake connection that checks no id or tour id is printed. The scripts'
SQL ran against a replayed CIS schema through the real PII guard during development (lane notes in AA-CIS-App
docs/implementation-notes/AA-1179.md)."""

import asyncio
import contextlib
import datetime
import importlib.util
import io
import json
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
COST = "db/scripts/aa1179_tenant_read_cost.py"
PARITY = "db/scripts/aa1179_tenant_read_parity.py"


def _load(path):
    spec = importlib.util.spec_from_file_location(Path(path).stem, ROOT / path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


cost = _load(COST)
parity = _load(PARITY)

TENANT = "0a117900-0000-4000-8000-000000000001"
REQS = [f"0a117900-0000-4000-8000-0000000001{i:02d}" for i in range(5)]
TOUR = "0a117900-0000-4000-8000-000000000201"
MEMBER = "0a117900-0000-4000-8000-000000000202"


class _Tx:
    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False


class FakeConn:
    """Answers by statement text; the new and old request statements return the same rows unless ``drift``."""

    def __init__(self, drift=False, member=True):
        self.drift, self.member, self.sql = drift, member, []

    def transaction(self):
        return _Tx()

    async def execute(self, sql, *args):
        self.sql.append(sql)

    async def fetchval(self, sql, *args):
        self.sql.append(sql)
        if "pg_has_role" in sql:
            return self.member
        if "pg_extension" in sql:
            return "public"
        if "to_regclass" in sql:
            return True
        if "current_setting" in sql:
            return "off"
        if "set_config" in sql:
            return args[0]
        if "percentile_cont" in sql:
            return 1.5
        return None

    async def fetchrow(self, sql, *args):
        self.sql.append(sql)
        if "pg_stat_statements" in sql:
            n = sum(1 for s in self.sql if "aa1179_probe" in s and "pg_stat_statements" not in s)
            return {"calls": n, "ms": 2.0 * n, "hit": 10 * n, "rd": 0, "temp_w": 0, "nrows": n}
        return None

    async def fetch(self, sql, *args):
        self.sql.append(sql)
        if "GROUP BY r.tenant_id" in sql:
            return [{"tenant_id": TENANT, "n": len(REQS)}]
        if "pg_stat_xact_user_tables" in sql:
            return [{"rel": "silver_aa_internal.raw_tours", "seq": 0, "idx": len(self.sql)}]
        if "AS rep" in sql:
            return [{"request_id": r, "rep": TOUR, "retired": i == 0} for i, r in enumerate(REQS)]
        if "AS tour_id" in sql and "request_id = ANY" in sql:
            ids = args[0]
            moved = self.drift and "OFFSET 0" in sql
            return [{"request_id": r, "tour_id": MEMBER if (moved or r == REQS[0]) else TOUR} for r in ids]
        if "SELECT r.request_id::text AS request_id" in sql:
            return [{"request_id": r} for r in REQS]
        return []


def _run(mod, conn):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = asyncio.run(mod.main(conn))
    return rc, buf.getvalue()


class ShapeTest(unittest.TestCase):
    def test_runner_shape_check_accepts_both(self):
        for path in (COST, PARITY):
            out = subprocess.run([sys.executable, "db/run_migration.py", "--inspect-script", path], cwd=ROOT,
                                 capture_output=True, text=True)
            self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
            self.assertEqual(json.loads(out.stdout.strip().splitlines()[-1])["errors"], [], path)

    def test_read_only(self):
        self.assertIs(cost.READ_ONLY, True)
        self.assertIs(parity.READ_ONLY, True)


class SqlTest(unittest.TestCase):
    def test_both_scripts_carry_the_same_statements(self):
        for name in ("W48_REQUEST_TOURS_SQL", "S291_REQUEST_TOURS_SQL", "W48_BASELINE_SQL", "S291_BASELINE_SQL",
                     "S293_BASELINE_SQL"):
            self.assertEqual(getattr(cost, name), getattr(parity, name), name)

    def test_request_statements_are_the_w48_join_and_the_s291_lateral_lookup(self):
        self.assertIn("LEFT JOIN gold_aa_internal.v_tour_liveness tl_rq\n", cost.W48_REQUEST_TOURS_SQL)
        self.assertNotIn("LATERAL", cost.W48_REQUEST_TOURS_SQL)
        self.assertIn("CROSS JOIN LATERAL (SELECT COALESCE(r.trip_id, ta.tour_id) AS tour_id) rep",
                      cost.S291_REQUEST_TOURS_SQL)
        self.assertIn("OFFSET 0", cost.S291_REQUEST_TOURS_SQL)
        for sql in (cost.W48_REQUEST_TOURS_SQL, cost.S291_REQUEST_TOURS_SQL):
            self.assertIn("WHERE r.request_id = ANY($1::uuid[]) AND r.tenant_id = $2::uuid", sql)

    def test_baseline_statements_are_the_three_generations(self):
        self.assertIn("WHERE d.day = (l.created_at AT TIME ZONE 'UTC')::date", cost.W48_BASELINE_SQL)
        self.assertIn("raw_days AS (", cost.S291_BASELINE_SQL)
        self.assertIn("LEFT JOIN LATERAL (", cost.S293_BASELINE_SQL)
        self.assertNotIn("(l.created_at AT TIME ZONE 'UTC')", cost.S293_BASELINE_SQL)

    def test_wrapped_statement_keeps_the_statement_under_the_marker(self):
        w = cost.wrapped(cost.S293_BASELINE_SQL, cost.marker("baseline", "cis_7d", "s293", "master"))
        self.assertTrue(w.startswith("SELECT /* aa1179_probe baseline cis_7d s293 master */ q.* FROM ("))
        self.assertTrue(w.endswith(") q"))
        self.assertNotIn("EXPLAIN", w)                     # the pgss read leaves EXPLAIN rows out

    def test_marker_and_schema_refuse_anything_but_plain_names(self):
        with self.assertRaises(AssertionError):
            cost.marker("x */ DROP", "a", "b", "c")
        with self.assertRaises(AssertionError):
            cost.pgss_sql("public; DROP")


class PureTest(unittest.TestCase):
    def test_percentile_nearest_rank(self):
        vals = [float(v) for v in range(1, 21)]
        self.assertEqual(cost.percentile(vals, 50), 10.0)
        self.assertEqual(cost.percentile(vals, 95), 19.0)
        self.assertEqual(cost.percentile([7.0], 95), 7.0)

    def test_deltas_keep_only_counters_that_moved(self):
        self.assertEqual(cost.deltas({"a": 1, "b": 2}, {"a": 1, "b": 5, "c": 3}), {"b": 3, "c": 3})
        self.assertEqual(cost.fmt_counts({}, 20), "-")
        self.assertEqual(cost.fmt_counts({"t.x": 40, "t.y": 20}, 20), "t.x:2,t.y:1")

    def test_chunks_and_compare(self):
        self.assertEqual(parity.chunks(list(range(5)), 2), [[0, 1], [2, 3], [4]])
        self.assertEqual(parity.compare({"a": "1", "b": "2"}, {"a": "1", "b": "2"}), 0)
        self.assertEqual(parity.compare({"a": "1", "b": "2"}, {"a": "1", "b": "3", "c": None}), 2)


class RunTest(unittest.TestCase):
    def _no_ids(self, out):
        for v in [TENANT, TOUR, MEMBER, *REQS]:
            self.assertNotIn(v, out)
        for line in out.strip().splitlines():
            self.assertTrue(line.startswith("SCRIPT "), line)

    def test_parity_ok_when_rows_match(self):
        rc, out = _run(parity, FakeConn())
        self.assertEqual(rc, 0)
        self._no_ids(out)
        self.assertIn("SCRIPT parity check=request_tours tenants=1 requests=5 rows_old=5 rows_new=5 differing=0 "
                      "retired_rep=1 moved_by_subject_rule=1", out)
        self.assertIn("check=request_tours_role role=aa_app_user requests=5 differing=0", out)
        self.assertIn("SCRIPT parity check=baseline cases=30 differing=0", out)
        self.assertIn(" ok=True ", out)

    def test_parity_reports_differing_rows(self):
        rc, out = _run(parity, FakeConn(drift=True, member=False))
        self.assertEqual(rc, 0)
        self._no_ids(out)
        self.assertIn("differing=4", out)
        self.assertIn("skipped=master_not_member", out)
        self.assertIn(" ok=False ", out)

    def test_cost_prints_per_call_counters_and_verdicts(self):
        old_repeats = cost.REPEATS
        cost.REPEATS = 2
        try:
            rc, out = _run(cost, FakeConn())
        finally:
            cost.REPEATS = old_repeats
        self.assertEqual(rc, 0)
        self._no_ids(out)
        self.assertIn("SCRIPT setup pgss_schema=yes key_expr_idx=True master_may_set_role_aa_app_user=True", out)
        self.assertIn("check=request_tours label=t1_page50 variant=s291 role=aa_app_user", out)
        self.assertIn("check=baseline label=crm_28d variant=s293 role=master", out)
        self.assertIn("SCRIPT verdict request_tours buffers_ratio_min=", out)
        self.assertIn("SCRIPT verdict baseline new_temp_written_max=0 target=0 ok=True", out)
        self.assertNotIn("SCRIPT error", out)
        today = datetime.datetime.now(datetime.timezone.utc).date().isoformat()
        self.assertNotIn(today, out)


if __name__ == "__main__":
    unittest.main()
