"""Unit tests for db/run_migration.py safety defaults and db/check_migration_files.py (AA-807 N5).

No database and no asyncpg: the connection is a fake that records what the runner sends.
Run: python3 -m unittest discover -s db/tests -v
"""
import asyncio
import contextlib
import hashlib
import io
import json
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import check_migration_files as files  # noqa: E402
import run_migration as rm  # noqa: E402

PLAIN = """-- Migration 240: AA-1 — add a column.
--
BEGIN;
ALTER TABLE shared.tenants ADD COLUMN IF NOT EXISTS x int;
INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('240', now(), 'AA-1; add x') ON CONFLICT (version) DO NOTHING;
COMMIT;
"""

NO_TX = """-- Migration 241: AA-2 — covering index.
-- migrate: no-transaction
-- migrate: statement_timeout=1h
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_a ON shared.decision_log (stage, created_at);
DROP INDEX CONCURRENTLY IF EXISTS shared.ix_old;
INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('241', now(), 'AA-2: covering index') ON CONFLICT (version) DO NOTHING;
"""

DESTRUCTIVE = """-- Migration bk-012: AA-3 — drop the retired table.
-- migrate: destructive
BEGIN;
DROP TABLE IF EXISTS booking.old_things;
INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-012', now(), 'AA-3') ON CONFLICT (version) DO NOTHING;
COMMIT;
"""


class DirectiveTest(unittest.TestCase):
    def test_defaults_without_header(self):
        d = rm.parse_directives(PLAIN)
        self.assertEqual(d.settings, {"lock_timeout": "5s", "statement_timeout": "15min",
                                      "application_name": "db-migrate"})
        self.assertFalse(d.no_transaction or d.destructive)
        self.assertEqual(d.errors, [])

    def test_flags_and_overrides(self):
        d = rm.parse_directives(NO_TX)
        self.assertTrue(d.no_transaction)
        self.assertEqual(d.settings["statement_timeout"], "1h")
        self.assertEqual(d.settings["lock_timeout"], "5s")
        d = rm.parse_directives("-- migrate: lock_timeout = '30s'\n-- MIGRATE: Destructive\nSELECT 1;")
        self.assertEqual(d.settings["lock_timeout"], "30s")
        self.assertTrue(d.destructive)

    def test_trailing_note_after_directive(self):
        d = rm.parse_directives("-- migrate: no-transaction   -- CIC below\n"
                                "-- migrate: lock_timeout=30s -- job runner is busy\nSELECT 1;\n")
        self.assertEqual(d.errors, [])
        self.assertTrue(d.no_transaction)
        self.assertEqual(d.settings["lock_timeout"], "30s")

    def test_unknown_directive_and_bad_values_fail(self):
        for header, needle in [
            ("-- migrate: no-transation", "unknown directive"),
            ("-- migrate: work_mem=64MB", "unknown setting"),
            ("-- migrate: lock_timeout=5 seconds", "not a duration"),
            ("-- migrate: lock_timeout=5s; DROP TABLE x", "not a duration"),
            ("-- migrate: application_name=x", "fixed to 'db-migrate'"),
            ("-- migrate: lock_timeout=5s\n-- migrate: lock_timeout=9s", "set twice"),
        ]:
            with self.subTest(header=header):
                d = rm.parse_directives(header + "\nSELECT 1;\n")
                self.assertTrue(any(needle in e for e in d.errors), d.errors)

    def test_directive_after_first_statement_is_an_error(self):
        d = rm.parse_directives("BEGIN;\n-- migrate: destructive\nDROP TABLE x;\nCOMMIT;\n")
        self.assertFalse(d.destructive)
        self.assertIn("line 2", d.errors[0])


class SplitTest(unittest.TestCase):
    def test_quotes_comments_and_dollar_bodies(self):
        sql = (
            "-- head; with a semicolon\n"
            "SELECT 'a;b', E'it\\'s;', \"we;ird\" FROM t; /* c; /* nested; */ still; */\n"
            "DO $body$ BEGIN PERFORM 1; DROP TABLE x; END $body$;\n"
            "CREATE FUNCTION f() RETURNS int AS $$ SELECT 1; $$ LANGUAGE sql;\n"
            "SELECT $1::int;\n"
            "-- trailing comment only\n"
        )
        stmts = rm.split_statements(sql)
        self.assertEqual(len(stmts), 4, [s.code for s in stmts])
        self.assertEqual(stmts[0].line, 2)
        self.assertIn("\"WE;IRD\"", stmts[0].code)
        self.assertEqual(stmts[1].code, "DO $$")
        self.assertEqual(stmts[1].line, 3)
        self.assertTrue(stmts[3].code.startswith("SELECT $1"))

    def test_real_copies_split_into_begin_commit(self):
        root = Path(__file__).resolve().parent.parent / "migrations"
        for f in sorted(root.glob("*/*.sql")):
            sql = f.read_text(encoding="utf-8")
            if rm.parse_directives(sql).no_transaction:
                continue
            with self.subTest(file=f.name):
                stmts = rm.split_statements(sql)
                self.assertEqual(stmts[0].code, "BEGIN")
                self.assertEqual(stmts[-1].code, "COMMIT")


class LintTest(unittest.TestCase):
    def lint(self, sql):
        return rm.lint(sql, rm.parse_directives(sql))

    def test_existing_shapes_pass(self):
        for sql in (PLAIN, NO_TX, DESTRUCTIVE):
            self.assertEqual(self.lint(sql), ([], []))

    def test_concurrently_needs_no_transaction(self):
        errors, _ = self.lint("BEGIN;\nCREATE INDEX CONCURRENTLY ix ON t (a);\nCOMMIT;\n")
        self.assertIn("line 2: CONCURRENTLY", errors[0])

    def test_refresh_concurrently_is_allowed_in_a_transaction(self):
        sql = "BEGIN;\nREFRESH MATERIALIZED VIEW CONCURRENTLY a.mv;\nCOMMIT;\n"
        self.assertEqual(self.lint(sql), ([], []))

    def test_vacuum_needs_no_transaction(self):
        errors, _ = self.lint("BEGIN;\nCOMMIT;\nVACUUM ANALYZE a.b;\n")
        self.assertEqual(len(errors), 1, errors)
        self.assertIn("line 3: VACUUM", errors[0])
        ok = ("-- migrate: no-transaction\nVACUUM ANALYZE a.b;\n"
              "INSERT INTO shared.schema_versions VALUES ('1', now(), 'x') ON CONFLICT DO NOTHING;\n")
        self.assertEqual(self.lint(ok)[0], [])

    def test_destructive_statements_need_the_header(self):
        cases = {
            "DROP TABLE IF EXISTS a.b;": "DROP TABLE",
            "drop schema retired cascade;": "DROP SCHEMA",
            "DROP MATERIALIZED VIEW a.mv;": "DROP MATERIALIZED VIEW",
            "TRUNCATE a.b;": "TRUNCATE",
            "ALTER TABLE a.b DROP COLUMN c;": "DROP COLUMN",
            "ALTER TABLE ONLY a.b DROP IF EXISTS c;": "DROP COLUMN",
        }
        for stmt, label in cases.items():
            with self.subTest(stmt=stmt):
                errors, _ = self.lint(f"BEGIN;\n{stmt}\nCOMMIT;\n")
                self.assertEqual(len(errors), 1, errors)
                self.assertIn(label, errors[0])

    def test_non_destructive_drops_pass(self):
        sql = ("BEGIN;\nDROP POLICY IF EXISTS p ON a.b;\nDROP VIEW IF EXISTS a.v;\nDROP INDEX IF EXISTS a.i;\n"
               "ALTER TABLE a.b ALTER COLUMN c DROP DEFAULT;\nALTER TABLE a.b ALTER COLUMN c DROP NOT NULL;\n"
               "ALTER TABLE a.b DROP CONSTRAINT IF EXISTS k;\nREVOKE DELETE, TRUNCATE ON a.b FROM booking;\n"
               "-- ALTER TABLE a.b DROP COLUMN c;  (rollback note in a comment)\n"
               "COMMENT ON TABLE a.b IS 'safe to DROP TABLE later';\nCOMMIT;\n")
        self.assertEqual(self.lint(sql), ([], []))

    def test_delete_is_a_warning(self):
        errors, warnings = self.lint("BEGIN;\nDELETE FROM shared.llm_role_config WHERE stage = 'n7';\nCOMMIT;\n")
        self.assertEqual(errors, [])
        self.assertIn("DELETE", warnings[0])

    def test_no_transaction_rules(self):
        errors, _ = self.lint("-- migrate: no-transaction\nBEGIN;\nCREATE INDEX CONCURRENTLY i ON t (a);\n"
                              "INSERT INTO shared.schema_versions VALUES ('1', now(), 'x');\nCOMMIT;\n")
        self.assertTrue(any("BEGIN/COMMIT" in e for e in errors))
        self.assertTrue(any("LAST statement" in e for e in errors))

    def test_inspect_prints_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "241_x.sql"
            p.write_text(NO_TX, encoding="utf-8")
            buf = io.StringIO()
            self.assertEqual(rm.inspect(str(p), out=buf), 0)
            data = json.loads(buf.getvalue())
            self.assertTrue(data["no_transaction"])
            self.assertFalse(data["destructive"])
            p.write_text("BEGIN;\nTRUNCATE x;\nCOMMIT;\n", encoding="utf-8")
            buf = io.StringIO()
            self.assertEqual(rm.inspect(str(p), out=buf), 1)

    def test_version_pattern_per_owner(self):
        self.assertEqual(rm.version_pattern("229"), "^[0-9]{3}$")
        self.assertEqual(rm.version_pattern("bk-009"), "^bk\\-[0-9]{3}$")
        self.assertEqual(rm.version_pattern("tp-010"), "^tp\\-[0-9]{3}$")


def job(kind, status="queued", due=True):
    return {"kind": kind, "status": status, "due": due}


TODAY_OWNERS = {"shared": "aa_cis_admin", "booking": "aa_cis_admin", "tripplanner": "aa_cis_admin"}


class FakeConn:
    """`states` is one (jobs, waves) pair per idle check, the last one repeating: jobs maps an owner
    schema to its job rows (job()), or to an Exception raised on read; waves is the number of open
    shared.rerun_wave rows, or None when the table does not exist.

    X1: `login` is session_user, `owners` the live owner per anchor schema (missing = no schema),
    `members` the roles the login role is a member of, `stray` the rows of the ownership post-check."""

    def __init__(self, applied=None, registers=True, fail=None, states=None, login="aa_cis_admin",
                 owners=None, members=(), stray=()):
        self.applied, self.registers, self.fail = applied, registers, fail
        self.executed, self.closed, self.ran = [], False, False
        self.states = states or [({"booking": [], "shared": []}, 0)]
        self.checks, self.busy_queries = 0, []
        self.login, self.members, self.stray = login, set(members), list(stray)
        self.owners = dict(TODAY_OWNERS if owners is None else owners)
        self.postchecks = []

    def state(self):
        return self.states[min(self.checks, len(self.states)) - 1]

    async def fetch(self, query, *args):
        if query == rm.OWNED_BY_LOGIN_SQL:
            self.postchecks.append(list(args[0]))
            return [{"kind": k, "name": n} for k, n in self.stray]
        if query == rm.JOB_TABLES_SQL:
            self.checks += 1
            return [(schema,) for schema in sorted(self.state()[0])]
        schema = query.split("FROM ", 1)[1].split(".job", 1)[0].strip('"')
        # The rows below are filtered in Python, so pin the SQL text: an edit to JOB_BUSY_SQL must
        # come with a test change (IdleCheckTest.test_busy_sql_predicates_are_pinned).
        assert query == rm.JOB_BUSY_SQL.format(table=f'"{schema}".job'), query
        self.busy_queries.append((schema, list(args[0])))
        rows = self.state()[0][schema]
        if isinstance(rows, Exception):
            raise rows
        groups = {}
        for r in rows:
            if r["kind"] in args[0] or r["status"] not in ("queued", "running"):
                continue
            g = groups.setdefault((r["kind"], r["status"]), {"kind": r["kind"], "status": r["status"],
                                                             "n": 0, "due": 0})
            g["n"] += 1
            g["due"] += int(r["status"] == "queued" and r["due"])
        return [groups[k] for k in sorted(groups)]

    async def fetchval(self, query, *args):
        if query == rm.SESSION_USER_SQL:
            return self.login
        if query == rm.SCHEMA_OWNER_SQL:
            return self.owners.get(args[0])
        if query == rm.IS_MEMBER_SQL:
            return args[0] in self.members
        if "ORDER BY version DESC" in query:
            return "230"
        if query == rm.WAVE_TABLE_SQL:
            return self.state()[1] is not None
        if query == rm.OPEN_WAVES_SQL:
            return self.state()[1]
        return self.applied

    async def execute(self, sql):
        if self.fail:
            raise self.fail
        self.executed.append(sql)
        self.ran = True
        if self.registers:
            self.applied = "2026-10-15 00:00:00+00"

    async def close(self):
        self.closed = True


class PgError(Exception):
    def __init__(self, sqlstate, msg):
        super().__init__(msg)
        self.sqlstate = sqlstate


class RunTaskTest(unittest.TestCase):
    def run_task(self, sql, mode="apply", conn=None, version="240", file="cis/x.sql", **extra):
        raw = sql.encode()
        env = {"MIGRATION_URL": "u", "MIGRATION_SHA256": hashlib.sha256(raw).hexdigest(),
               "MIGRATION_VERSION": version, "MIGRATION_MODE": mode, "MIGRATION_FILE": file,
               "DATABASE_URL": "postgresql://x", **extra}
        conn = conn or FakeConn()
        seen = {}

        async def connect(dsn, settings):
            seen["settings"] = settings
            return conn

        self.sleeps = []

        async def sleep(s):
            self.sleeps.append(s)

        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = asyncio.run(rm.run_task(env, fetch=lambda url: raw, connect=connect, sleep=sleep))
        return code, conn, seen.get("settings"), out.getvalue()

    def test_apply_sends_whole_file_with_defaults(self):
        code, conn, settings, log = self.run_task(PLAIN)
        self.assertEqual(code, 0)
        self.assertEqual(conn.executed, [PLAIN])
        self.assertEqual(conn.postchecks, [])          # no switch, no post-check (X1 no-op today)
        self.assertEqual(settings, {"lock_timeout": "5s", "statement_timeout": "15min",
                                    "application_name": "db-migrate"})
        self.assertIn("latest_registered_same_owner=230", log)
        self.assertTrue(conn.closed)

    def test_check_mode_changes_nothing(self):
        code, conn, _, _ = self.run_task(PLAIN, mode="check")
        self.assertEqual((code, conn.executed), (0, []))

    def test_already_applied_is_skipped(self):
        code, conn, _, log = self.run_task(PLAIN, conn=FakeConn(applied="2026-10-01"))
        self.assertEqual((code, conn.executed), (0, []))
        self.assertIn("skip: already applied", log)

    def test_no_transaction_runs_statements_one_by_one(self):
        code, conn, settings, _ = self.run_task(NO_TX, version="241")
        self.assertEqual(code, 0)
        self.assertEqual(len(conn.executed), 3)
        self.assertTrue(conn.executed[0].startswith("-- Migration 241"))
        self.assertIn("CREATE INDEX CONCURRENTLY", conn.executed[0])
        self.assertTrue(conn.executed[2].startswith("INSERT INTO shared.schema_versions"))
        self.assertEqual(settings["statement_timeout"], "1h")

    def test_destructive_needs_snapshot(self):
        code, conn, _, log = self.run_task(DESTRUCTIVE, version="bk-012")
        self.assertEqual((code, conn.executed), (5, []))
        self.assertIn("MIGRATION_SNAPSHOT is empty", log)
        code, conn, _, log = self.run_task(DESTRUCTIVE, version="bk-012",
                                           MIGRATION_SNAPSHOT="db-migrate-bk-012-1")
        self.assertEqual(code, 0)
        self.assertEqual(conn.executed, [DESTRUCTIVE])
        self.assertIn("db-migrate-bk-012-1", log)

    def test_destructive_check_needs_no_snapshot(self):
        code, _, _, _ = self.run_task(DESTRUCTIVE, mode="check", version="bk-012")
        self.assertEqual(code, 0)

    def test_lint_error_stops_before_connecting(self):
        code, conn, settings, log = self.run_task("BEGIN;\nTRUNCATE shared.job;\nCOMMIT;\n")
        self.assertEqual(code, 4)
        self.assertIsNone(settings)
        self.assertIn("ERROR: line 2: TRUNCATE", log)

    def test_sha_mismatch(self):
        raw = PLAIN.encode()
        env = {"MIGRATION_URL": "u", "MIGRATION_SHA256": "0" * 64}
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(asyncio.run(rm.run_task(env, fetch=lambda url: raw)), 2)

    def test_unregistered_file_fails(self):
        code, _, _, _ = self.run_task(PLAIN, conn=FakeConn(registers=False))
        self.assertEqual(code, 3)

    def test_lock_timeout_reports_hint(self):
        conn = FakeConn(fail=PgError("55P03", "canceling statement due to lock timeout"))
        code, _, _, log = self.run_task(PLAIN, conn=conn)
        self.assertEqual(code, 6)
        self.assertIn("lock_timeout (5s) hit", log)
        self.assertTrue(conn.closed)


BUSY_BOOKING = ({"booking": [job("bk_x6_probe")], "shared": []}, 0)
IDLE = ({"booking": [], "shared": []}, 0)
REFUSAL = ("MIGRATE ERROR: refusing apply — busy: {}. Wait until every job table is idle, or "
           "re-dispatch with override_busy_jobs=<reason> (Nghiệp only)")


class IdleCheckTest(unittest.TestCase):
    """AA-751: DB Migrate refuses apply while any owner job table is busy (plan §4)."""

    run_task = RunTaskTest.run_task

    def test_busy_booking_job_refuses_apply_after_three_waits(self):
        code, conn, _, log = self.run_task(PLAIN, conn=FakeConn(states=[BUSY_BOOKING]))
        self.assertEqual((code, conn.executed), (7, []))
        self.assertEqual(self.sleeps, [20, 20, 20])
        self.assertEqual(conn.checks, 4)            # the report + one re-check after each wait
        self.assertIn("MIGRATE busy: booking.job running=0 queued=1 due=1 kinds=[bk_x6_probe:queued=1]\n", log)
        self.assertIn(REFUSAL.format("booking.job (queued=1)") + "\n", log)
        self.assertIn("MIGRATE idle: shared.job running=0 queued=0\n", log)   # no CIS exempt kind (AA-751)
        self.assertTrue(conn.closed)

    def test_busy_shared_job_refuses_and_names_it(self):
        state = ({"booking": [], "shared": [job("a3_atomize", "running"), job("a3_atomize", due=False),
                                            job("place_extract")]}, 0)
        code, conn, _, log = self.run_task(PLAIN, conn=FakeConn(states=[state]))
        self.assertEqual((code, conn.executed), (7, []))
        self.assertIn("MIGRATE busy: shared.job running=1 queued=2 due=1 kinds=[a3_atomize:queued=1, "
                      "a3_atomize:running=1, place_extract:queued=1]", log)
        self.assertIn(REFUSAL.format("shared.job (running=1, queued=2)"), log)
        self.assertIn("MIGRATE idle: booking.job running=0 queued=0 (exempt: bk_inquiry_pull)", log)

    def test_check_mode_reports_busy_and_returns_0(self):
        code, conn, _, log = self.run_task(PLAIN, mode="check", conn=FakeConn(states=[BUSY_BOOKING]))
        self.assertEqual((code, conn.executed, self.sleeps), (0, [], []))
        self.assertIn("MIGRATE busy: booking.job", log)
        self.assertNotIn("refusing", log)

    def test_idle_tables_pass_without_waiting(self):
        code, conn, _, log = self.run_task(PLAIN, conn=FakeConn(states=[IDLE]))
        self.assertEqual((code, conn.executed, self.sleeps, conn.checks), (0, [PLAIN], [], 1))
        self.assertIn("MIGRATE idle: shared.rerun_wave open=0", log)
        self.assertNotIn("busy", log)

    def test_exempt_kinds_queued_and_running_are_ignored(self):
        # shared.job has no exempt kind since AA-751; a test-only one keeps the mechanism covered.
        state = ({"booking": [job("bk_inquiry_pull"), job("bk_inquiry_pull", "running")],
                  "shared": [job("x_test_recurring"), job("x_test_recurring", "running"),
                             job("a3_atomize", "succeeded"), job("a3_atomize", "failed")]}, 0)
        with mock.patch.dict(rm.IDLE_EXEMPT_KINDS, {"shared": frozenset({"x_test_recurring"})}):
            code, conn, _, log = self.run_task(PLAIN, conn=FakeConn(states=[state]))
        self.assertEqual((code, conn.executed, self.sleeps), (0, [PLAIN], []))
        self.assertIn("MIGRATE idle: booking.job running=0 queued=0 (exempt: bk_inquiry_pull)", log)
        self.assertIn("MIGRATE idle: shared.job running=0 queued=0 (exempt: x_test_recurring)", log)

    def test_removed_ops_rds_role_connections_kind_is_busy(self):
        # AA-751: the kind is gone from the CIS registry, so a leftover queued row is not exempt.
        state = ({"booking": [], "shared": [job("ops_rds_role_connections")]}, 0)
        code, conn, _, log = self.run_task(PLAIN, conn=FakeConn(states=[state]))
        self.assertEqual((code, conn.executed), (7, []))
        self.assertIn(REFUSAL.format("shared.job (queued=1)"), log)

    def test_exemptions_are_per_owner(self):
        # A CIS-exempt kind name in booking.job is not exempt there (and cannot exist: bk_ CHECK).
        state = ({"booking": [job("x_test_recurring")], "shared": []}, 0)
        with mock.patch.dict(rm.IDLE_EXEMPT_KINDS, {"shared": frozenset({"x_test_recurring"})}):
            code, _, _, log = self.run_task(PLAIN, conn=FakeConn(states=[state]))
        self.assertEqual(code, 7)
        self.assertIn(REFUSAL.format("booking.job (queued=1)"), log)

    def test_override_logs_reason_and_proceeds(self):
        code, conn, _, log = self.run_task(PLAIN, conn=FakeConn(states=[BUSY_BOOKING]),
                                           MIGRATION_IDLE_OVERRIDE="  hotfix AA-999, probe row is harmless ")
        self.assertEqual((code, conn.executed, self.sleeps), (0, [PLAIN], []))
        self.assertIn("MIGRATE busy: booking.job", log)
        self.assertIn("MIGRATE WARNING: idle check OVERRIDDEN (hotfix AA-999, probe row is harmless), "
                      "busy: booking.job (queued=1)\n", log)

    def test_override_when_idle_and_in_check_mode_is_only_noted(self):
        code, conn, _, log = self.run_task(PLAIN, conn=FakeConn(states=[IDLE]), MIGRATION_IDLE_OVERRIDE="x")
        self.assertEqual((code, conn.executed), (0, [PLAIN]))
        self.assertIn("but nothing is busy", log)
        code, _, _, log = self.run_task(PLAIN, mode="check", conn=FakeConn(states=[BUSY_BOOKING]),
                                        MIGRATION_IDLE_OVERRIDE="x")
        self.assertEqual(code, 0)
        self.assertIn("only applies to mode=apply", log)

    def test_open_rerun_wave_refuses(self):
        code, conn, _, log = self.run_task(PLAIN, conn=FakeConn(states=[({"booking": [], "shared": []}, 1)]))
        self.assertEqual((code, conn.executed), (7, []))
        self.assertIn("MIGRATE busy: shared.rerun_wave open=1\n", log)
        self.assertIn(REFUSAL.format("shared.rerun_wave (open=1)"), log)

    def test_wait_loop_passes_when_idle_on_second_check(self):
        conn = FakeConn(states=[BUSY_BOOKING, IDLE])
        code, conn, _, log = self.run_task(PLAIN, conn=conn)
        self.assertEqual((code, conn.executed, self.sleeps, conn.checks), (0, [PLAIN], [20], 2))
        self.assertIn("MIGRATE waiting 20s for idle job tables (re-check 1/3), busy: booking.job (queued=1)", log)
        self.assertIn("MIGRATE idle: booking.job running=0 queued=0", log)

    def test_already_applied_skips_before_the_wait(self):
        code, conn, _, log = self.run_task(PLAIN, conn=FakeConn(applied="2026-10-01", states=[BUSY_BOOKING]))
        self.assertEqual((code, conn.executed, self.sleeps), (0, [], []))
        self.assertIn("skip: already applied", log)
        self.assertNotIn("refusing", log)

    def test_destructive_refusal_comes_before_the_snapshot_check(self):
        code, conn, _, _ = self.run_task(DESTRUCTIVE, version="bk-012", conn=FakeConn(states=[BUSY_BOOKING]))
        self.assertEqual((code, conn.executed), (7, []))

    def test_any_owner_job_table_is_found_in_the_catalog(self):
        state = ({"booking": [], "shared": [], "tripplanner": [job("tp_redact", "running")]}, 0)
        code, conn, _, log = self.run_task(PLAIN, conn=FakeConn(states=[state]))
        self.assertEqual(code, 7)
        self.assertIn("MIGRATE busy: tripplanner.job running=1 queued=0 due=0 kinds=[tp_redact:running=1]", log)
        self.assertIn(("tripplanner", []), conn.busy_queries)

    def test_exempt_list_is_passed_per_owner(self):
        state = ({"booking": [], "shared": [], "tripplanner": []}, 0)
        _, conn, _, _ = self.run_task(PLAIN, conn=FakeConn(states=[state]))
        self.assertEqual(conn.busy_queries, [("booking", ["bk_inquiry_pull"]),
                                             ("shared", []),
                                             ("tripplanner", [])])

    def test_busy_sql_predicates_are_pinned(self):
        # FakeConn filters rows in Python; these pin the real predicates (a too-narrow filter fails
        # open: apply would go ahead while jobs are queued).
        where = rm.JOB_BUSY_SQL.split("FROM {table}", 1)[1]
        self.assertIn("WHERE status IN ('queued', 'running') AND NOT (kind = ANY($1::text[]))", where)
        self.assertNotIn("run_after", where)       # every queued row counts, due or not
        self.assertIn("count(*) FILTER (WHERE status = 'queued' AND run_after <= now())", rm.JOB_BUSY_SQL)
        for part in ("c.relname = 'job'", "c.relkind IN ('r', 'p')", "a.attname = 'status'",
                     "NOT a.attisdropped"):
            self.assertIn(part, rm.JOB_TABLES_SQL)
        self.assertIn("to_regclass('shared.rerun_wave')", rm.WAVE_TABLE_SQL)
        self.assertIn("WHERE status = 'open'", rm.OPEN_WAVES_SQL)

    def test_missing_tables_warn_but_do_not_block(self):
        code, conn, _, log = self.run_task(PLAIN, conn=FakeConn(states=[({"shared": []}, None)]))
        self.assertEqual((code, conn.executed), (0, [PLAIN]))
        self.assertIn("MIGRATE WARNING: booking.job not found (not checked)", log)
        self.assertIn("MIGRATE WARNING: shared.rerun_wave not found (wave check skipped)", log)

    def test_unreadable_table_counts_as_busy(self):
        state = ({"booking": PgError("42501", "permission denied for table job"), "shared": []}, 0)
        code, conn, _, log = self.run_task(PLAIN, conn=FakeConn(states=[state]))
        self.assertEqual((code, conn.executed), (7, []))
        self.assertIn("MIGRATE busy: booking.job unreadable (PgError: permission denied for table job)", log)
        self.assertIn(REFUSAL.format("booking.job (unreadable)"), log)


BK_FILE = """-- Migration bk-015: X1 probe.
BEGIN;
DO $$ BEGIN
  IF current_user <> 'bk_owner' THEN RAISE EXCEPTION 'bk-015 ran as %', current_user; END IF;
END $$;
INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-015', now(), 'X1 probe') ON CONFLICT (version) DO NOTHING;
COMMIT;
"""

ROLES_FILE = """-- Migration rl-001: X1 owner roles.
BEGIN;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bk_owner') THEN CREATE ROLE bk_owner NOLOGIN; END IF;
END $$;
GRANT bk_owner TO aa_cis_admin;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('rl-001', now(), 'X1 owner roles') ON CONFLICT (version) DO NOTHING;
COMMIT;
"""


class RoleSwitchTest(unittest.TestCase):
    """X1 plan S1 item 4 (XD8): the live owner of the anchor schema decides the role."""

    run_task = RunTaskTest.run_task

    def test_today_every_dir_runs_as_the_login_role_unchanged(self):
        for file, version in (("cis/242_job_table_template_conformance.sql", "242"),
                              ("booking/013_job_template_catch_up.sql", "bk-013"),
                              ("tripplanner/012_retire_plaintext_guest_token.sql", "tp-012")):
            with self.subTest(file=file):
                code, conn, _, log = self.run_task(PLAIN, file=file, version=version)
                self.assertEqual((code, conn.executed, conn.postchecks), (0, [PLAIN], []))
                self.assertIn("MIGRATE ran as: aa_cis_admin — login role owns anchor schema ", log)

    def test_check_mode_reports_the_role(self):
        code, conn, _, log = self.run_task(PLAIN, mode="check", file="cis/242_job_table_template_conformance.sql",
                                           version="242", conn=FakeConn(applied="2026-10-16"))
        self.assertEqual((code, conn.executed), (0, []))
        self.assertIn("MIGRATE ran as: aa_cis_admin (check mode: the role apply uses) — login role owns "
                      "anchor schema shared, no role switch", log)

    def test_switch_picks_bk_owner_from_the_catalog(self):
        conn = FakeConn(owners={**TODAY_OWNERS, "booking": "bk_owner"}, members={"bk_owner"})
        code, conn, _, log = self.run_task(BK_FILE, file="booking/015_x1_set_role_probe.sql",
                                           version="bk-015", conn=conn)
        self.assertEqual(code, 0, log)
        stmts = rm.split_statements(BK_FILE)
        self.assertEqual(conn.executed, [stmts[0].text, 'SET LOCAL ROLE "bk_owner"',
                                         "\n".join(s.text for s in stmts[1:-1]), "RESET ROLE", stmts[-1].text])
        self.assertTrue(conn.executed[0].startswith("-- Migration bk-015") and conn.executed[0].endswith("BEGIN;"))
        self.assertEqual(conn.executed[-1], "COMMIT;")
        self.assertEqual(conn.postchecks, [list(rm.OWNER_SCHEMAS)])
        self.assertIn("MIGRATE ran as: bk_owner — login aa_cis_admin, anchor schema booking owned by bk_owner", log)

    def test_cis_after_245_runs_as_cis_owner_under_db_migrator(self):
        conn = FakeConn(login="db_migrator", members={"cis_owner", "bk_owner", "tp_owner", "catalog_owner"},
                        owners={"shared": "cis_owner", "booking": "bk_owner", "tripplanner": "tp_owner"})
        code, conn, _, log = self.run_task(PLAIN, file="cis/246_x1_set_role_probe.sql", version="246", conn=conn)
        self.assertEqual(code, 0)
        self.assertIn('SET LOCAL ROLE "cis_owner"', conn.executed)
        self.assertIn("MIGRATE ran as: cis_owner", log)

    def test_login_not_member_of_the_owner_is_refused(self):
        conn = FakeConn(owners={**TODAY_OWNERS, "booking": "bk_owner"})
        for mode in ("check", "apply"):
            with self.subTest(mode=mode):
                code, c, _, log = self.run_task(BK_FILE, mode=mode, file="booking/015_x.sql", version="bk-015",
                                                conn=FakeConn(owners=conn.owners))
                self.assertEqual((code, c.executed), (8, []))
                self.assertIn("MIGRATE ERROR: role: anchor schema booking is owned by bk_owner and the login "
                              "role aa_cis_admin is not a member of it", log)
                self.assertTrue(c.closed)

    def test_postcheck_failure_rolls_back_before_commit(self):
        conn = FakeConn(owners={**TODAY_OWNERS, "booking": "bk_owner"}, members={"bk_owner"},
                        stray=[("relation", "booking.oops")])
        code, conn, _, log = self.run_task(BK_FILE, file="booking/015_x.sql", version="bk-015", conn=conn)
        self.assertEqual(code, 9)
        self.assertEqual(conn.executed[-2:], ["RESET ROLE", "ROLLBACK"])
        self.assertNotIn("COMMIT;", conn.executed)
        self.assertIn("ownership post-check: 1 object(s) owned by the login role aa_cis_admin instead of "
                      "bk_owner: relation booking.oops. Rolled back.", log)

    def test_switched_file_must_be_one_transaction_block(self):
        two_blocks = "BEGIN;\nSELECT 1;\nCOMMIT;\nBEGIN;\nINSERT INTO shared.schema_versions VALUES ('tp-014');\nCOMMIT;\n"
        conn = FakeConn(owners={**TODAY_OWNERS, "tripplanner": "tp_owner"}, members={"tp_owner"})
        code, conn, _, log = self.run_task(two_blocks, file="tripplanner/014_x.sql", version="tp-014", conn=conn)
        self.assertEqual((code, conn.executed), (8, []))
        self.assertIn("line 3: transaction control inside the file", log)
        # Not switched (today): the same file still runs as it always did.
        code, conn, _, _ = self.run_task(two_blocks, file="tripplanner/014_x.sql", version="tp-014")
        self.assertEqual((code, conn.executed), (0, [two_blocks]))

    def test_switched_no_transaction_file_uses_a_session_role(self):
        conn = FakeConn(owners={**TODAY_OWNERS, "shared": "cis_owner"}, members={"cis_owner"})
        code, conn, _, _ = self.run_task(NO_TX, file="cis/247_x.sql", version="247", conn=conn)
        self.assertEqual(code, 0)
        self.assertEqual(conn.executed[0], 'SET ROLE "cis_owner"')
        self.assertEqual(conn.executed[-1], "RESET ROLE")
        self.assertEqual(len(conn.executed), 5)
        self.assertEqual(len(conn.postchecks), 1)

    def test_switched_no_transaction_postcheck_failure_reports_committed(self):
        conn = FakeConn(owners={**TODAY_OWNERS, "shared": "cis_owner"}, members={"cis_owner"},
                        stray=[("relation", "shared.ix_a")])
        code, _, _, log = self.run_task(NO_TX, file="cis/247_x.sql", version="247", conn=conn)
        self.assertEqual(code, 9)
        self.assertIn("The no-transaction file is committed", log)

    def test_roles_dir_runs_only_as_the_master(self):
        code, conn, _, log = self.run_task(ROLES_FILE, file="roles/001_x1_owner_roles.sql", version="rl-001")
        self.assertEqual((code, conn.executed), (0, [ROLES_FILE]))
        self.assertIn("MIGRATE ran as: aa_cis_admin — roles/ file, runs as the master", log)
        code, conn, _, log = self.run_task(ROLES_FILE, file="roles/001_x1_owner_roles.sql", version="rl-001",
                                           conn=FakeConn(login="db_migrator"))
        self.assertEqual((code, conn.executed), (8, []))
        self.assertIn("roles/ files run only as the RDS master aa_cis_admin (login is db_migrator)", log)

    def test_unknown_dir_is_refused_and_missing_anchor_does_not_switch(self):
        code, conn, _, log = self.run_task(PLAIN, file="crm/001_x.sql", version="crm-001")
        self.assertEqual((code, conn.executed), (8, []))
        self.assertIn("unknown migration dir 'crm'", log)
        code, conn, _, log = self.run_task(PLAIN, file="tripplanner/013_x.sql", version="tp-013",
                                           conn=FakeConn(owners={"shared": "aa_cis_admin"}))
        self.assertEqual((code, conn.executed), (0, [PLAIN]))
        self.assertIn("anchor schema tripplanner does not exist yet, no role switch", log)

    def test_postcheck_sql_shape_is_pinned(self):
        q = rm.OWNED_BY_LOGIN_SQL
        for part in ("nspname = ANY($1::text[])", "rolname = session_user", "FROM pg_class c",
                     "FROM pg_proc p", "FROM pg_type t", "t.typrelid = 0 AND t.typcategory <> 'A'",
                     "o.nspowner <> me.oid OR o.x = pg_current_xact_id()::xid"):
            self.assertIn(part, q)
        self.assertEqual(rm.SCHEMA_OWNER_SQL,
                         "SELECT pg_get_userbyid(nspowner)::text FROM pg_namespace WHERE nspname = $1")
        self.assertEqual(rm.IS_MEMBER_SQL, "SELECT pg_has_role(session_user, $1, 'MEMBER')")


# Shapes of the planned X1 files (plan S16 = 244, S21 = 245 + S22 catalog recipe), trimmed.
DRAFT_244 = """-- Migration 244: X1 cis_app runtime grants.
-- migrate: lock_timeout=5s
BEGIN;
GRANT USAGE ON SCHEMA shared, geo TO cis_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA shared TO cis_app;
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA shared TO cis_app;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA geo TO cis_app;
REVOKE INSERT, UPDATE, DELETE ON shared.schema_versions FROM cis_app;
ALTER DEFAULT PRIVILEGES FOR ROLE aa_cis_admin IN SCHEMA shared GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO cis_app;
CREATE POLICY content_piece_cis_app_all ON acp_shared.content_piece AS PERMISSIVE FOR ALL TO cis_app USING (true) WITH CHECK (true);
INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('244', now(), 'X1 cis_app') ON CONFLICT (version) DO NOTHING;
DO $$
DECLARE n bigint;
BEGIN
  IF pg_has_role('cis_app', 'aa_app_user', 'MEMBER') THEN RAISE EXCEPTION 'cis_app must not SET ROLE aa_app_user'; END IF;
  SET LOCAL ROLE cis_app;
  PERFORM set_config('app.tenant_id', '00000000-0000-0000-0000-000000000001', true);
  SELECT count(*) INTO n FROM gold_aa_internal.published_tours;
  BEGIN
    PERFORM 1 FROM booking.customers LIMIT 1;
    RAISE EXCEPTION 'cis_app reads booking.customers';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  UPDATE shared.tenant_members SET role = role WHERE false;
END $$;
COMMIT;
"""

DRAFT_245 = """-- Migration 245: X1 CIS objects to cis_owner.
BEGIN;
ALTER SCHEMA shared OWNER TO cis_owner;
ALTER TABLE shared.job OWNER TO cis_owner;
ALTER FUNCTION geo.name_norm(text) OWNER TO cis_owner;
ALTER DEFAULT PRIVILEGES FOR ROLE cis_owner IN SCHEMA shared GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO cis_app;
ALTER DEFAULT PRIVILEGES FOR ROLE aa_cis_admin IN SCHEMA shared REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLES FROM cis_app;
GRANT CREATE ON SCHEMA catalog TO catalog_owner;
SET LOCAL ROLE catalog_owner;
CREATE OR REPLACE VIEW catalog.v_x AS SELECT 1 AS x;
SET LOCAL ROLE cis_owner;        -- the way back; never RESET ROLE
REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;
INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('245', now(), 'X1 cis_owner') ON CONFLICT (version) DO NOTHING;
COMMIT;
"""


class RoleLintTest(unittest.TestCase):
    """X1 plan S1 item 6: role statements in owner files above today's heads."""

    def lint(self, sql, path):
        return rm.lint(sql, rm.parse_directives(sql), path)[0]

    def body(self, stmt):
        return f"BEGIN;\n{stmt}\nINSERT INTO shared.schema_versions VALUES ('x');\nCOMMIT;\n"

    def test_planned_244_and_245_pass(self):
        self.assertEqual(self.lint(DRAFT_244, "db/migrations/cis/244_x1_cis_app_runtime.sql"), [])
        self.assertEqual(self.lint(DRAFT_245, "db/migrations/cis/245_x1_cis_owner.sql"), [])

    def test_refused_statements(self):
        cases = [
            ("booking/015_x.sql", "DO $$ BEGIN RESET ROLE; END $$;", "RESET ROLE returns to the login role"),
            ("cis/246_x.sql", "RESET ROLE;", "RESET ROLE returns"),
            ("cis/246_x.sql", "CREATE EXTENSION IF NOT EXISTS vector;", "EXTENSION belongs in db/migrations/roles/"),
            ("tripplanner/013_x.sql", "DROP EXTENSION x;", "EXTENSION belongs"),
            ("cis/246_x.sql", "DO $$ BEGIN SET LOCAL ROLE aa_app_user; END $$;",
             "`SET LOCAL ROLE aa_app_user` is not allowed in cis/ (allowed: catalog_owner, cis_app, cis_owner"),
            ("booking/015_x.sql", "SET LOCAL ROLE bk_owner;", "is not allowed in booking/ (allowed: none"),
            ("cis/246_x.sql", "SET LOCAL ROLE NONE;", "`SET LOCAL ROLE none` is not allowed"),
            ("cis/246_x.sql", "SET ROLE cis_app;", "only `SET LOCAL ROLE` is allowed"),
            ("cis/246_x.sql", "SET SESSION ROLE cis_app;", "only `SET LOCAL ROLE` is allowed"),
            ("cis/246_x.sql", "set role = 'cis_owner';", "only `SET LOCAL ROLE` is allowed"),
            ("cis/246_x.sql", "ALTER FUNCTION f() SET role TO cis_owner;", "only `SET LOCAL ROLE` is allowed"),
            ("cis/246_x.sql", "SET SESSION AUTHORIZATION cis_app;", "SESSION AUTHORIZATION is not allowed"),
            ("cis/246_x.sql", "SELECT set_config('role', 'cis_app', true);", "set_config('role', …) switches"),
            ("cis/246_x.sql", "DO $$ BEGIN EXECUTE format('SET LOCAL ROLE %I', 'x'); END $$;",
             "dynamic SQL 'SET LOCAL ROLE %I' switches or defines a role"),
            ("cis/246_x.sql", "CREATE ROLE cis_reader NOLOGIN;", "ROLE belongs in db/migrations/roles/"),
            ("booking/015_x.sql", "DO $$ BEGIN IF true THEN CREATE ROLE x; END IF; END $$;", "ROLE belongs"),
            ("cis/246_x.sql", "ALTER ROLE cis_app CONNECTION LIMIT 120;", "ROLE belongs"),
            ("cis/246_x.sql", "GRANT catalog_owner TO CURRENT_USER;", "role membership `GRANT CATALOG_OWNER TO`"),
            ("cis/246_x.sql", "REVOKE catalog_owner FROM aa_cis_admin;", "role membership"),
            ("cis/246_x.sql", "DO $$ BEGIN EXECUTE format('GRANT aa_app_user TO %I', current_user); END $$;",
             "grants a role membership"),
        ]
        for path, stmt, needle in cases:
            with self.subTest(stmt=stmt):
                errors = self.lint(self.body(stmt), path)
                self.assertTrue(any(needle in e for e in errors), errors)
                self.assertTrue(errors[0].startswith("line 2: "), errors)

    def test_allowed_look_alikes(self):
        for stmt in (
            "UPDATE shared.tenant_members SET role = 'admin' WHERE false;",
            "INSERT INTO t (a, role) VALUES (1, 'x') ON CONFLICT (a) DO UPDATE SET role = EXCLUDED.role;",
            "-- never RESET ROLE here; CREATE EXTENSION lives in roles/",
            "DO $$ BEGIN RAISE EXCEPTION 'must be able to SET ROLE catalog_owner (GRANT catalog_owner TO x)'; END $$;",
            "COMMENT ON TABLE t IS 'RESET ROLE is forbidden';",
            "GRANT SELECT ON booking.v_x TO tripplanner WITH GRANT OPTION;",
            "REVOKE ALL ON SCHEMA booking FROM PUBLIC;",
            "ALTER DEFAULT PRIVILEGES FOR ROLE bk_owner IN SCHEMA booking GRANT EXECUTE ON FUNCTIONS TO booking;",
            "ALTER TABLE booking.customers OWNER TO bk_owner;",
            "SELECT set_config('app.tenant_id', '', true);",
            "CREATE USER MAPPING FOR x SERVER y;",
            "CREATE TABLE booking.role_x (role text);",
        ):
            with self.subTest(stmt=stmt):
                self.assertEqual(self.lint(self.body(stmt), "booking/015_x.sql"), [])

    def test_only_files_above_the_heads_and_owner_dirs(self):
        sql = self.body("DO $$ BEGIN SET LOCAL ROLE aa_app_user; RESET ROLE; END $$;")
        self.assertEqual(self.lint(sql, "cis/242_x.sql"), [])
        self.assertEqual(self.lint(sql, "booking/013_x.sql"), [])
        self.assertEqual(self.lint(sql, "tripplanner/012_x.sql"), [])
        self.assertNotEqual(self.lint(sql, "cis/243_x.sql"), [])
        self.assertNotEqual(self.lint(sql, "booking/014_x.sql"), [])
        self.assertNotEqual(self.lint(sql, "tripplanner/013_x.sql"), [])
        self.assertEqual(self.lint(ROLES_FILE, "db/migrations/roles/001_x1_owner_roles.sql"), [])
        self.assertEqual(self.lint(sql, None), [])                  # no path: legacy callers

    def test_real_copies_still_pass(self):
        root = Path(__file__).resolve().parent.parent.parent
        out = io.StringIO()
        self.assertEqual(files.run(files.all_copies(root), root, out=out), 0, out.getvalue())

    def test_inspect_applies_the_role_lint(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "booking" / "015_x.sql"
            p.parent.mkdir()
            p.write_text(self.body("RESET ROLE;"), encoding="utf-8")
            out = io.StringIO()
            self.assertEqual(rm.inspect(str(p), out=out), 1)
            self.assertIn("RESET ROLE returns", json.loads(out.getvalue())["errors"][0])

    def test_run_task_lints_with_the_migration_file(self):
        code, conn, settings, log = RunTaskTest.run_task(self, self.body("RESET ROLE;"),
                                                         file="booking/015_x.sql", version="bk-015")
        self.assertEqual((code, settings), (4, None))
        self.assertIn("MIGRATE ERROR: line 2: RESET ROLE returns", log)


class CheckFilesTest(unittest.TestCase):
    def make_repo(self, layout):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        for rel, body in layout.items():
            p = root / "db" / "migrations" / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(body, encoding="utf-8")
        return root

    def test_duplicate_number_in_one_owner_fails(self):
        root = self.make_repo({"cis/232_a.sql": PLAIN, "cis/232_b.sql": PLAIN, "booking/232_c.sql": PLAIN})
        errors = files.duplicate_numbers(root)
        self.assertEqual(len(errors), 1)
        self.assertIn("db/migrations/cis: number 232", errors[0])
        out = io.StringIO()
        self.assertEqual(files.run(files.all_copies(root), root, out=out), 1)

    def test_roles_dir_numbers_are_unique_and_linted(self):
        root = self.make_repo({"roles/001_a.sql": PLAIN, "roles/001_b.sql": PLAIN, "cis/001_c.sql": PLAIN})
        errors = files.duplicate_numbers(root)
        self.assertEqual(len(errors), 1)
        self.assertIn("db/migrations/roles: number 001", errors[0])

    def test_role_lint_runs_on_new_owner_copies(self):
        root = self.make_repo({"booking/014_x.sql": "BEGIN;\nRESET ROLE;\nCOMMIT;\n",
                               "roles/001_x.sql": ROLES_FILE})
        out = io.StringIO()
        self.assertEqual(files.run(files.all_copies(root), root, out=out), 1)
        self.assertIn("FAIL  db/migrations/booking/014_x.sql: line 2: RESET ROLE returns", out.getvalue())
        self.assertIn("ok    db/migrations/roles/001_x.sql", out.getvalue())

    def test_clean_repo_passes_and_lint_errors_fail(self):
        root = self.make_repo({"cis/240_a.sql": PLAIN, "tripplanner/011_b.sql": NO_TX})
        self.assertEqual(files.run(files.all_copies(root), root, out=io.StringIO()), 0)
        root = self.make_repo({"cis/240_a.sql": "BEGIN;\nDROP TABLE x;\nCOMMIT;\n"})
        out = io.StringIO()
        self.assertEqual(files.run(files.all_copies(root), root, out=out), 1)
        self.assertIn("DROP TABLE needs", out.getvalue())


if __name__ == "__main__":
    unittest.main()
