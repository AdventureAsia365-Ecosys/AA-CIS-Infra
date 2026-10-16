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


class FakeConn:
    """`states` is one (jobs, waves) pair per idle check, the last one repeating: jobs maps an owner
    schema to its job rows (job()), or to an Exception raised on read; waves is the number of open
    shared.rerun_wave rows, or None when the table does not exist."""

    def __init__(self, applied=None, registers=True, fail=None, states=None):
        self.applied, self.registers, self.fail = applied, registers, fail
        self.executed, self.closed, self.ran = [], False, False
        self.states = states or [({"booking": [], "shared": []}, 0)]
        self.checks, self.busy_queries = 0, []

    def state(self):
        return self.states[min(self.checks, len(self.states)) - 1]

    async def fetch(self, query, *args):
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
    def run_task(self, sql, mode="apply", conn=None, version="240", **extra):
        raw = sql.encode()
        env = {"MIGRATION_URL": "u", "MIGRATION_SHA256": hashlib.sha256(raw).hexdigest(),
               "MIGRATION_VERSION": version, "MIGRATION_MODE": mode, "MIGRATION_FILE": "cis/x.sql",
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
        self.assertIn("MIGRATE idle: shared.job running=0 queued=0 (exempt: ops_rds_role_connections)\n", log)
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
        state = ({"booking": [job("bk_inquiry_pull"), job("bk_inquiry_pull", "running")],
                  "shared": [job("ops_rds_role_connections"), job("ops_rds_role_connections", "running"),
                             job("a3_atomize", "succeeded"), job("a3_atomize", "failed")]}, 0)
        code, conn, _, log = self.run_task(PLAIN, conn=FakeConn(states=[state]))
        self.assertEqual((code, conn.executed, self.sleeps), (0, [PLAIN], []))
        self.assertIn("MIGRATE idle: booking.job running=0 queued=0 (exempt: bk_inquiry_pull)", log)

    def test_exemptions_are_per_owner(self):
        # A CIS-exempt kind name in booking.job is not exempt there (and cannot exist: bk_ CHECK).
        state = ({"booking": [job("ops_rds_role_connections")], "shared": []}, 0)
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
                                             ("shared", ["ops_rds_role_connections"]),
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

    def test_clean_repo_passes_and_lint_errors_fail(self):
        root = self.make_repo({"cis/240_a.sql": PLAIN, "tripplanner/011_b.sql": NO_TX})
        self.assertEqual(files.run(files.all_copies(root), root, out=io.StringIO()), 0)
        root = self.make_repo({"cis/240_a.sql": "BEGIN;\nDROP TABLE x;\nCOMMIT;\n"})
        out = io.StringIO()
        self.assertEqual(files.run(files.all_copies(root), root, out=out), 1)
        self.assertIn("DROP TABLE needs", out.getvalue())


if __name__ == "__main__":
    unittest.main()
