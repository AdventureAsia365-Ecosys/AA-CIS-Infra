"""AA-969 part 2 (root ADR 0019 d16): the run-script PII guard of db/run_migration.py without a database.

The canned plans are the EXPLAIN (VERBOSE, FORMAT JSON) shapes PostgreSQL prints for these statements (checked against
a real planner in test_aa969_pii_guard_pg.py, local only). Covers the plan reading (bare and qualified columns, whole
rows, CTEs, subqueries, InitPlans, the allowed count / IS NULL forms), the guarded connection (every row-returning call
planned first, fail closed; execute() statement kinds, multi-statement strings, the private wrapped connection), the
writes and side channels (INSERT … SELECT into an unprotected table, set_config, query_to_xml), the Append / Merge
Append / Recursive Union members, the error text a script failure may log, and run_script: the guard is on for every
script, a refused read fails the run (exit 13) before the statement runs, a catalogue read failure runs nothing.
"""
import asyncio
import contextlib
import hashlib
import io
import json
import sys
import unittest
from unittest import mock
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))

import run_migration as rm  # noqa: E402
from test_run_migration import FakeConn  # noqa: E402

PROTECTED = {("crm", "traveler"): {"email", "display_name"}, ("crm", "trip"): {"notes"},
             ("crm", "audit_event_2026_11"): {"detail"}, ("crm", "audit_event_2026_12"): {"detail"}}


def scan(alias, out, rel="traveler", schema="crm", **extra):
    return {"Node Type": "Seq Scan", "Relation Name": rel, "Schema": schema, "Alias": alias, "Output": out, **extra}


def member(node):
    return {**node, "Parent Relationship": "Member"}


PARTITIONS = [member(scan("audit_event_1", ["audit_event_1.detail", "audit_event_1.at"], rel="audit_event_2026_11")),
              member(scan("audit_event_2", ["audit_event_2.detail", "audit_event_2.at"], rel="audit_event_2026_12"))]
BOTH_PARTITIONS = ["crm.audit_event_2026_11.detail", "crm.audit_event_2026_12.detail"]


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
    # EXPLAIN prints no Output for Append / Merge Append / Recursive Union: their members are the output.
    "append of two partitions": ({"Node Type": "Append", "Plans": PARTITIONS}, BOTH_PARTITIONS),
    "merge append of two partitions": ({"Node Type": "Merge Append", "Sort Key": ["audit_event.at"],
                                        "Plans": PARTITIONS}, BOTH_PARTITIONS),
    "union all": ({"Node Type": "Append", "Plans": [
        member(scan("traveler", ["traveler.email"])), member({"Node Type": "Result", "Output": ["'x'::text"]})]},
        ["crm.traveler.email"]),
    "sort above partitions names the parent alias": ({"Node Type": "Sort", "Output": [
        "audit_event.detail", "audit_event.at"], "Plans": [
        {"Node Type": "Append", "Parent Relationship": "Outer", "Plans": PARTITIONS}]}, BOTH_PARTITIONS),
    "subquery scan over a union all": ({"Node Type": "Subquery Scan", "Alias": "s", "Output": ["s.email"], "Plans": [
        {"Node Type": "Append", "Parent Relationship": "Subquery", "Plans": [
            member(scan("traveler", ["traveler.email"])), member({"Node Type": "Result", "Output": ["'x'::text"]})]}]},
        ["s.email (from a subquery reading personal data)"]),
    "recursive CTE": ({"Node Type": "CTE Scan", "CTE Name": "r", "Alias": "r", "Output": ["r.e"], "Plans": [
        {"Node Type": "Recursive Union", "Parent Relationship": "InitPlan", "Subplan Name": "CTE r", "Plans": [
            scan("traveler", ["traveler.email"], **{"Parent Relationship": "Outer"}),
            {"Node Type": "Result", "Parent Relationship": "Inner", "Output": ["e"]}]}]},
        ["r.e (from a subquery reading personal data)"]),
    "append of counts": ({"Node Type": "Append", "Plans": [
        member({"Node Type": "Aggregate", "Output": ["count(traveler.email)"], "Plans": [scan("traveler", ["email"])]}),
        member({"Node Type": "Result", "Output": ["0"]})]}, []),
}

INSERT_SELECT = {"Node Type": "ModifyTable", "Operation": "Insert", "Relation Name": "admin_users", "Schema": "shared",
                 "Alias": "admin_users", "Plans": [
                     scan("traveler", ["gen_random_uuid()", "traveler.email"], **{"Parent Relationship": "Outer"})]}
WRITES = {
    "insert … select into an unprotected table": (INSERT_SELECT, ["crm.traveler.email written into shared.admin_users"]),
    "update … set from a subquery": ({"Node Type": "ModifyTable", "Operation": "Update", "Relation Name": "admin_users",
                                     "Schema": "shared", "Alias": "admin_users", "Plans": [
        {"Node Type": "Limit", "Parent Relationship": "InitPlan", "Subplan Name": "InitPlan 1 (returns $0)",
         "Output": ["traveler.email"], "Plans": [scan("traveler", ["traveler.email"])]},
        scan("admin_users", ["$0", "admin_users.ctid"], rel="admin_users", schema="shared",
             **{"Parent Relationship": "Outer"})]},
        ["InitPlan 1 (returns $0) (a subplan reading personal data) written into shared.admin_users"]),
    "insert inside a CTE": ({"Node Type": "Aggregate", "Output": ["count(*)"], "Plans": [
        {**INSERT_SELECT, "Parent Relationship": "InitPlan", "Subplan Name": "CTE i", "Output": ["admin_users.id"]},
        {"Node Type": "CTE Scan", "Parent Relationship": "Outer", "CTE Name": "i", "Alias": "i", "Output": ["i.id"]}]},
        ["crm.traveler.email written into shared.admin_users"]),
    "rewriting a protected table in place": ({"Node Type": "ModifyTable", "Operation": "Update",
                                              "Relation Name": "traveler", "Schema": "crm", "Alias": "traveler",
                                              "Plans": [scan("traveler", ["lower(email)", "ctid"],
                                                             **{"Parent Relationship": "Outer"})]}, []),
    "insert of a count": ({**INSERT_SELECT, "Plans": [{"Node Type": "Aggregate", "Parent Relationship": "Outer",
                                                       "Output": ["count(*)"], "Plans": [scan("traveler", [])]}]}, []),
}


class PlanReadingTest(unittest.TestCase):
    def test_canned_plans(self):
        for name, (plan, expected) in PLANS.items():
            with self.subTest(name=name):
                self.assertEqual(rm.pii_plan_reads(plan, PROTECTED), expected)

    def test_canned_writes(self):
        for name, (plan, expected) in WRITES.items():
            with self.subTest(name=name):
                self.assertEqual(rm.pii_plan_writes(plan, PROTECTED), expected)

    def test_side_channels(self):
        sql_text = {"Node Type": "Result", "Output": [
            "query_to_xml('SELECT email FROM crm.traveler'::text, true, false, ''::text)"]}
        self.assertEqual(rm.pii_plan_side_channels(sql_text, PROTECTED),
                         ["query_to_xml() runs SQL text the guard cannot plan"])
        for func in ("table_to_xml('crm.traveler'::regclass)", "ts_stat('SELECT 1'::text)", "dblink('x', 'y')"):
            self.assertTrue(rm.pii_plan_side_channels({"Node Type": "Result", "Output": [func]}, PROTECTED), func)
        on_protected = scan("traveler", ["count(*)"], Filter="(set_config('x.y'::text, email, false) <> ''::text)")
        self.assertEqual(rm.pii_plan_side_channels(on_protected, PROTECTED),
                         ["set_config() in a statement that reads a personal-data table"])
        tenant_setting = {"Node Type": "Result", "Output": ["set_config('app.tenant_id'::text, $1, true)"]}
        self.assertEqual(rm.pii_plan_side_channels(tenant_setting, PROTECTED), [])

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

    async def execute(self, query, *args):
        self.ran.append(query)
        return "OK"


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


class SqlSplitTest(unittest.TestCase):
    def test_statements_split_on_top_level_semicolons_only(self):
        sql = ("SET a = 'x;y'; -- a ; comment\nSELECT $$;$$, $t$ ; $t$, E'\\';', \"q;\"\"x\" /* ; /* ; */ */ FROM t;"
               "  ;\n")
        stmts = rm.sql_statements(sql)
        self.assertEqual(len(stmts), 2)
        self.assertEqual(stmts[0][1].strip(), "SET a = ''")
        self.assertNotIn(";", stmts[1][1].replace('"q;""x"', ""))
        self.assertIn('"q;""x"', stmts[1][1])
        self.assertEqual(rm.sql_statements("SELECT 1"), [("SELECT 1", "SELECT 1")])
        self.assertEqual(rm._sql_head("  ( SELECT 1)"), "SELECT")


class ErrorTextTest(unittest.TestCase):
    def test_a_database_error_shows_class_and_sqlstate_only(self):
        class InvalidTextRepresentationError(Exception):
            sqlstate, column_name, table_name = "22P02", None, None
        e = InvalidTextRepresentationError('invalid input syntax for type integer: "invented@example.test"')
        text = rm.script_error_text(e)
        self.assertIn("InvalidTextRepresentationError 22P02 (message withheld", text)
        self.assertNotIn("invented@example.test", text)
        try:
            try:
                raise e
            except Exception as inner:
                raise RuntimeError(f"wrapped: {inner}") from None
        except RuntimeError as wrapped:
            self.assertNotIn("invented@example.test", rm.script_error_text(wrapped))

    def test_names_postgres_attaches_are_kept(self):
        class UniqueViolationError(Exception):
            sqlstate, table_name, constraint_name = "23505", "traveler", "traveler_email_key"
        text = rm.script_error_text(UniqueViolationError("Key (email)=(invented@example.test) already exists."))
        self.assertIn("[table_name=traveler, constraint_name=traveler_email_key]", text)
        self.assertNotIn("invented", text)

    def test_script_and_guard_errors_keep_their_text(self):
        self.assertEqual(rm.script_error_text(RuntimeError("boom")), "RuntimeError boom")
        self.assertEqual(rm.script_error_text(rm.PiiReadRefused("run-script: x")), "PiiReadRefused run-script: x")


class StatementKindsTest(unittest.TestCase):
    """execute(): what is planned, what passes unplanned, what is refused before anything is asked of the server."""

    def run_execute(self, query, plans=None, args=()):
        conn = ExplainConn(plans or {})
        g = rm.PiiGuardedConnection(conn, PROTECTED)
        asyncio.run(g.execute(query, *args))
        return conn

    def test_code_the_planner_cannot_see_is_refused_unasked(self):
        for query in ("DO $$ BEGIN RAISE NOTICE '%', 1; END $$", "CALL crm.p()", "COPY crm.traveler TO STDOUT",
                      "CREATE OR REPLACE FUNCTION f() RETURNS text LANGUAGE sql AS $$ SELECT 1 $$",
                      "create procedure p() language sql as $$ select 1 $$", "CREATE TRIGGER t AFTER INSERT ON x "
                      "FOR EACH ROW EXECUTE FUNCTION f()", "CREATE CONSTRAINT TRIGGER t AFTER INSERT ON x FOR EACH "
                      "ROW EXECUTE FUNCTION f()", "CREATE RULE r AS ON INSERT TO x DO ALSO NOTIFY c",
                      "CREATE EXTENSION dblink", "/* x */ DO 'BEGIN END'"):
            with self.subTest(query=query):
                conn = ExplainConn({})
                with self.assertRaisesRegex(rm.PiiReadRefused, "cannot plan the code it runs"):
                    asyncio.run(rm.PiiGuardedConnection(conn, PROTECTED).execute(query))
                self.assertEqual((conn.ran, conn.savepoints), ([], 0))

    def test_utility_statements_run_unplanned(self):
        for query in ("SET LOCAL ROLE booking", "SET LOCAL lock_timeout = '5s'", "BEGIN", "LOCK TABLE crm.trip",
                      "ALTER TABLE crm.trip ADD COLUMN x int", "CREATE INDEX ON crm.trip (tenant_id)",
                      "CREATE VIEW v AS SELECT 1", "CREATE TEMP TABLE y (n int)", "COMMENT ON TABLE crm.trip IS 'x'",
                      "PREPARE p AS SELECT 1", "ANALYZE crm.trip", "GRANT SELECT ON crm.trip TO x"):
            with self.subTest(query=query):
                conn = self.run_execute(query)
                self.assertEqual((conn.ran, conn.savepoints), ([query], 0))

    def test_queries_and_create_as_are_planned(self):
        insert = "INSERT INTO shared.admin_users SELECT gen_random_uuid(), email FROM crm.traveler"
        with self.assertRaisesRegex(rm.PiiReadRefused, "written into shared.admin_users"):
            self.run_execute(insert, {insert: INSERT_SELECT})
        ctas = "CREATE TEMP TABLE x AS SELECT email FROM crm.traveler"
        with self.assertRaisesRegex(rm.PiiReadRefused, r"crm\.traveler\.email"):
            self.run_execute(ctas, {ctas: scan("traveler", ["email"])})
        lock = "SELECT pg_advisory_xact_lock(hashtext($1))"
        conn = self.run_execute(lock, {lock: {"Node Type": "Result", "Output": ["pg_advisory_xact_lock(hashtext($1))"]}},
                                ("x",))
        self.assertEqual((conn.ran, conn.savepoints), ([lock], 1))

    def test_a_multi_statement_execute_checks_each_statement_before_it_runs(self):
        first, second = "CREATE TEMP TABLE x (e text)", " INSERT INTO x SELECT email FROM crm.traveler"
        plan = {**INSERT_SELECT, "Relation Name": "x", "Schema": "pg_temp_3", "Alias": "x"}
        conn = ExplainConn({second: plan})
        with self.assertRaisesRegex(rm.PiiReadRefused, "written into pg_temp_3.x"):
            asyncio.run(rm.PiiGuardedConnection(conn, PROTECTED).execute(first + ";" + second))
        self.assertEqual(conn.ran, [first])
        self.assertEqual(conn.savepoints, 2)                # the script's own transaction + the EXPLAIN savepoint

    def test_a_row_returning_call_takes_one_statement(self):
        conn = ExplainConn({})
        with self.assertRaisesRegex(rm.PiiReadRefused, "one statement per call"):
            asyncio.run(rm.PiiGuardedConnection(conn, PROTECTED).fetch("SET x = 1; SELECT email FROM crm.traveler"))
        self.assertEqual(conn.ran, [])

    def test_the_wrapped_connection_is_private(self):
        g = rm.PiiGuardedConnection(ExplainConn({}), PROTECTED)
        for name in ("_conn", "_PiiGuardedConnection__conn", "_PiiGuardedConnection__protected", "_protocol"):
            with self.subTest(name=name), self.assertRaises(rm.PiiReadRefused):
                getattr(g, name)
        with self.assertRaises(rm.PiiReadRefused):
            g.check = None
        for name in ("add_listener", "add_query_logger", "add_log_listener"):
            with self.subTest(name=name), self.assertRaises(rm.PiiReadRefused):
                getattr(g, name)
        self.assertFalse(hasattr(g, "__dict__"))


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

    def test_a_database_error_never_puts_its_text_in_the_log(self):
        source = ("class InvalidTextRepresentationError(Exception):\n    sqlstate = '22P02'\n\n"
                  "async def main(conn):\n"
                  "    raise InvalidTextRepresentationError("
                  "'invalid input syntax for type integer: \"invented@example.test\"')\n")
        code, out = run_script(source, PiiFakeConn(pii_rows=PII_ROWS))
        self.assertEqual(code, 13, out)
        self.assertIn("script raised InvalidTextRepresentationError 22P02 (message withheld", out)
        self.assertNotIn("invented@example.test", out)

    def test_a_catalogue_read_failure_runs_nothing(self):
        code, out = run_script(READS, PiiFakeConn(pii_error=RuntimeError("permission denied")))
        self.assertEqual(code, 13)
        self.assertIn("the PII guard could not read the catalogue (RuntimeError). Nothing ran", out)
        self.assertNotIn("SCRIPT who", out)

    def test_an_empty_or_implausibly_small_catalogue_runs_nothing(self):
        with mock.patch.object(rm, "PII_MIN_COLUMNS", 20):
            for rows in ([], PII_ROWS):
                with self.subTest(columns=len(rows)):
                    code, out = run_script(READS, PiiFakeConn(pii_rows=rows))
                    self.assertEqual(code, 13, out)
                    self.assertIn(f"the PII guard read only {len(rows)} personal-data columns (fewer than 20)", out)
                    self.assertNotIn("SCRIPT who", out)
            many = [{"schema_name": "crm", "rel_name": f"t{i}", "col": "email"} for i in range(20)]
            code, out = run_script(READS, PiiFakeConn(pii_rows=many))
            self.assertIn("PII guard on: 20 personal-data columns in 20 tenant tables", out)

    def test_the_guarded_connection_fails_closed_on_a_short_catalogue(self):
        async def go():
            with mock.patch.object(rm, "PII_MIN_COLUMNS", 20):
                for protected in ({}, PROTECTED):
                    with self.assertRaisesRegex(rm.PiiReadRefused, "catalogue is empty or implausibly small"):
                        await rm.PiiGuardedConnection(ExplainConn({}), protected).fetch("SELECT 1")
        asyncio.run(go())

    def test_the_sql_scopes_tenant_schemas_and_partitions(self):
        sql = " ".join(rm.PII_COLUMNS_SQL.split())
        self.assertIn("d.description LIKE 'pii:%'", sql)
        self.assertIn("n.nspname = ANY($1::text[])", sql)
        self.assertIn("t.attname = 'tenant_id'", sql)
        self.assertIn("pg_catalog.pg_inherits", sql)
        self.assertIn("NOT (n.nspname = 'booking' AND c.relname = 'staff_users')", sql)
        self.assertEqual(rm.PII_TENANT_SCHEMAS, ("crm", "booking", "tripplanner"))


if __name__ == "__main__":
    unittest.main()
