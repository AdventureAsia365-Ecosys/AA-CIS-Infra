"""AA-969 part 2 (root ADR 0019 d16): the run-script PII guard of db/run_migration.py without a database.

The canned plans are the EXPLAIN (VERBOSE, FORMAT JSON) shapes PostgreSQL prints for these statements (checked against
a real planner in test_aa969_pii_guard_pg.py, local only). Covers the plan reading (bare and qualified columns, whole
rows, CTEs, subqueries, InitPlans, the allowed count / IS NULL forms), the guarded connection (every row-returning call
planned first, fail closed) and run_script: the guard is on for every script, a refused read fails the run (exit 13)
before the statement runs, a catalogue read failure runs nothing.
"""
import asyncio
import contextlib
import hashlib
import io
import json
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))

import run_migration as rm  # noqa: E402
from test_run_migration import FakeConn  # noqa: E402

PROTECTED = {("crm", "traveler"): {"email", "display_name"}, ("crm", "trip"): {"notes"}}


def scan(alias, out, rel="traveler", schema="crm", **extra):
    return {"Node Type": "Seq Scan", "Relation Name": rel, "Schema": schema, "Alias": alias, "Output": out, **extra}


PLANS = {
    "bare column": (scan("traveler", ["email"]), ["crm.traveler.email"]),
    "aliased column": (scan("t", ["t.status", "t.display_name"]), ["crm.traveler.display_name"]),
    "whole row": (scan("t", ["row_to_json(t.*)"]), ["crm.traveler.*"]),
    "function of a value": (scan("traveler", ["lower(email)"]), ["crm.traveler.email"]),
    "count distinct": ({"Node Type": "Aggregate", "Output": ["count(DISTINCT email)"], "Plans": [
        {"Node Type": "Sort", "Output": ["email"], "Parent Relationship": "Outer",
         "Plans": [scan("traveler", ["email"], **{"Parent Relationship": "Outer"})]}]}, []),
    "count filter": ({"Node Type": "Aggregate", "Output": ["count(*) FILTER (WHERE (email IS NOT NULL))"],
                      "Plans": [scan("traveler", ["email"])]}, []),
    "null test": (scan("t", ["(t.email IS NULL)", "t.status"]), []),
    "a literal that names a column": (scan("t", ["'email'::text", "t.status"]), []),
    "non-personal columns": (scan("t", ["t.traveler_id", "t.status"]), []),
    "materialised CTE": ({"Node Type": "CTE Scan", "CTE Name": "c", "Alias": "c", "Output": ["c.email"], "Plans": [
        scan("traveler", ["traveler.email"], **{"Subplan Name": "CTE c", "Parent Relationship": "InitPlan"})]},
        ["c.email (from a subquery reading personal data)"]),
    "subquery scan": ({"Node Type": "Subquery Scan", "Alias": "s", "Output": ["s.e"], "Plans": [
        {"Node Type": "Limit", "Output": ["traveler.email"], "Parent Relationship": "Subquery",
         "Plans": [scan("traveler", ["traveler.email"])]}]}, ["s.e (from a subquery reading personal data)"]),
    "init plan": ({"Node Type": "Result", "Output": ["$0"], "Plans": [
        {"Node Type": "Limit", "Subplan Name": "InitPlan 1 (returns $0)", "Parent Relationship": "InitPlan",
         "Output": ["traveler.email"], "Plans": [scan("traveler", ["traveler.email"])]}]},
        ["InitPlan 1 (returns $0) (a subplan reading personal data)"]),
    "join": ({"Node Type": "Hash Join", "Output": ["tr.trip_id", "t.email"], "Plans": [
        scan("tr", ["tr.trip_id", "tr.traveler_id"], rel="trip"), scan("t", ["t.email", "t.traveler_id"])]},
        ["crm.traveler.email"]),
    "unprotected table": (scan("admin_users", ["email"], rel="admin_users", schema="shared"), []),
}


class PlanReadingTest(unittest.TestCase):
    def test_canned_plans(self):
        for name, (plan, expected) in PLANS.items():
            with self.subTest(name=name):
                self.assertEqual(rm.pii_plan_reads(plan, PROTECTED), expected)

    def test_strip_allowed(self):
        self.assertEqual(rm._strip_allowed("count(t.email)").strip(), "0")
        self.assertEqual(rm._strip_allowed("count(*) FILTER (WHERE (t.email IS NOT NULL)) + 1").strip(), "0  + 1")
        self.assertNotIn("email", rm._strip_allowed("(email IS NULL)"))
        self.assertIn("email", rm._strip_allowed("account(email)"))      # only count() itself
        self.assertNotIn("email", rm._strip_allowed("'email'::text"))


class ExplainConn:
    """Answers EXPLAIN with a canned plan per statement; records what ran."""

    def __init__(self, plans, fail=False):
        self.plans, self.fail, self.ran, self.savepoints = plans, fail, [], 0

    @contextlib.asynccontextmanager
    async def transaction(self):
        self.savepoints += 1
        yield

    async def fetchval(self, query, *args):
        if query.startswith("EXPLAIN (VERBOSE, FORMAT JSON) "):
            if self.fail:
                raise RuntimeError("syntax error at or near something")
            return json.dumps([{"Plan": self.plans[query[len("EXPLAIN (VERBOSE, FORMAT JSON) "):]]}])
        self.ran.append(query)
        return 1

    fetch = fetchrow = fetchval


class GuardedConnectionTest(unittest.TestCase):
    def test_refuses_before_running_and_passes_counts_through(self):
        conn = ExplainConn({"SELECT email FROM crm.traveler": scan("traveler", ["email"]),
                            "SELECT count(*) FROM crm.traveler": {"Node Type": "Aggregate", "Output": ["count(*)"],
                                                                 "Plans": [scan("traveler", [])]}})
        g = rm.PiiGuardedConnection(conn, PROTECTED)

        async def go():
            with self.assertRaisesRegex(rm.PiiReadRefused, r"crm\.traveler\.email"):
                await g.fetch("SELECT email FROM crm.traveler")
            self.assertEqual(await g.fetchval("SELECT count(*) FROM crm.traveler"), 1)
            self.assertEqual(await g.fetchrow("SHOW server_version"), 1)       # never planned
            with self.assertRaises(rm.PiiReadRefused):
                g.add_log_listener(print)
        asyncio.run(go())
        self.assertEqual(conn.ran, ["SELECT count(*) FROM crm.traveler", "SHOW server_version"])
        self.assertEqual(conn.savepoints, 2)

    def test_fails_closed_when_the_planner_refuses_and_is_off_without_protected_columns(self):
        conn = ExplainConn({}, fail=True)

        async def go():
            with self.assertRaisesRegex(rm.PiiReadRefused, "could not plan a statement"):
                await rm.PiiGuardedConnection(conn, PROTECTED).fetch("SELECT x FROM y")
            self.assertEqual(await rm.PiiGuardedConnection(conn, {}).fetch("SELECT x FROM y"), 1)
        asyncio.run(go())
        self.assertEqual(conn.ran, ["SELECT x FROM y"])


class PiiFakeConn(FakeConn):
    """The runner's FakeConn plus the guard's catalogue read, savepoints and EXPLAIN."""

    def __init__(self, pii_rows=(), pii_error=None, **kw):
        super().__init__(**kw)
        self.pii_rows, self.pii_error = list(pii_rows), pii_error

    @contextlib.asynccontextmanager
    async def transaction(self):
        yield

    async def fetch(self, query, *args):
        if query == rm.PII_COLUMNS_SQL:
            if self.pii_error:
                raise self.pii_error
            self.pii_args = args
            return self.pii_rows
        return await super().fetch(query, *args)

    async def fetchval(self, query, *args):
        if query.startswith("EXPLAIN (VERBOSE, FORMAT JSON) SELECT email"):
            return json.dumps([{"Plan": scan("traveler", ["email"])}])
        if query.startswith("EXPLAIN (VERBOSE, FORMAT JSON) "):
            return json.dumps([{"Plan": {"Node Type": "Result", "Output": ["session_user"]}}])
        return await super().fetchval(query, *args)


READS = """
async def main(conn):
    print("SCRIPT who=" + await conn.fetchval("SELECT session_user::text"))
    rows = await conn.fetch("SELECT email FROM crm.traveler")
    print("SCRIPT leaked " + repr(rows))
"""
PII_ROWS = [{"schema_name": "crm", "rel_name": "traveler", "col": "email"},
            {"schema_name": "crm", "rel_name": "traveler", "col": "display_name"}]


def run_script(source, conn):
    env = {"MIGRATION_MODE": "run-script:db/scripts/x.py", "MIGRATION_FILE": "db/scripts/x.py", "MIGRATION_URL": "u",
           "MIGRATION_SHA256": hashlib.sha256(source.encode()).hexdigest(), "MIGRATION_VERSION": "",
           "DATABASE_URL": "postgresql://x"}

    async def connect(dsn, settings, **kw):
        return conn

    async def sleep(_s):
        return None

    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = asyncio.run(rm.run_task(env, fetch=lambda url: source.encode(), connect=connect, sleep=sleep,
                                       get_secret=lambda sid: "unused"))
    return code, out.getvalue()


class RunScriptGuardTest(unittest.TestCase):
    def test_a_read_of_personal_data_fails_the_run_before_it_runs(self):
        conn = PiiFakeConn(pii_rows=PII_ROWS)
        code, out = run_script(READS, conn)
        self.assertEqual(code, 13, out)
        self.assertEqual(conn.pii_args, (["crm", "booking", "tripplanner"],))
        self.assertIn("MIGRATE run-script: PII guard on: 2 personal-data columns in 1 tenant tables", out)
        self.assertIn("SCRIPT who=aa_cis_admin\n", out)                     # a non-personal read still runs
        self.assertIn("script raised PiiReadRefused", out)
        self.assertIn("crm.traveler.email", out)
        self.assertNotIn("SCRIPT leaked", out)

    def test_a_catalogue_read_failure_runs_nothing(self):
        code, out = run_script(READS, PiiFakeConn(pii_error=RuntimeError("permission denied")))
        self.assertEqual(code, 13)
        self.assertIn("the PII guard could not read the catalogue (RuntimeError). Nothing ran", out)
        self.assertNotIn("SCRIPT who", out)

    def test_the_sql_scopes_tenant_schemas_and_partitions(self):
        sql = " ".join(rm.PII_COLUMNS_SQL.split())
        self.assertIn("d.description LIKE 'pii:%'", sql)
        self.assertIn("n.nspname = ANY($1::text[])", sql)
        self.assertIn("t.attname = 'tenant_id'", sql)
        self.assertIn("pg_catalog.pg_inherits", sql)
        self.assertEqual(rm.PII_TENANT_SCHEMAS, ("crm", "booking", "tripplanner"))


if __name__ == "__main__":
    unittest.main()
