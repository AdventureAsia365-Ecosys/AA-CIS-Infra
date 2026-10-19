"""Unit tests for db/run_migration.py safety defaults and db/check_migration_files.py (AA-807 N5).

No database and no asyncpg: the connection is a fake that records what the runner sends.
Run: python3 -m unittest discover -s db/tests -v
"""
import asyncio
import contextlib
import hashlib
import io
import json
import re
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


def obj(kind, name, owner, mine=True, schema_owner="bk_owner", oid=None):
    """One row of rm.OBJECTS_SQL."""
    return {"kind": kind, "id": oid or name, "name": name, "owner": owner, "mine": mine,
            "schema_owner": schema_owner}


class FakeConn:
    """`states` is one (jobs, waves) pair per idle check, the last one repeating: jobs maps an owner
    schema to its job rows (job()), or to an Exception raised on read; waves is the number of open
    shared.rerun_wave rows, or None when the table does not exist.

    X1: `login` is session_user, `owners` the live owner per anchor schema (missing = no schema),
    `members` the roles the login role is a member of, `base` the ownership snapshot before the file
    (rows of OBJECTS_SQL), `stray` (kind, name) objects the file leaves owned by the login role (they
    appear in every snapshot after the first), `late` the same for objects that only appear after
    COMMIT (third snapshot on), `can_register` the owner's grant on schema_versions, `xact_ids` the
    successive XACT_IDS_SQL counts (default: always 1, so one settle round)."""

    def __init__(self, applied=None, registers=True, fail=None, states=None, login="aa_cis_admin",
                 owners=None, members=(), stray=(), base=(), can_register=True, late=(), xact_ids=()):
        self.applied, self.registers, self.fail = applied, registers, fail
        self.executed, self.closed, self.ran = [], False, False
        self.states = states or [({"booking": [], "shared": []}, 0)]
        self.checks, self.busy_queries = 0, []
        self.login, self.members, self.stray = login, set(members), list(stray)
        self.owners = dict(TODAY_OWNERS if owners is None else owners)
        self.postchecks = []
        self.base, self.can_register = list(base), can_register
        self.late, self.xact_ids = list(late), list(xact_ids)

    def state(self):
        return self.states[min(self.checks, len(self.states)) - 1]

    async def fetch(self, query, *args):
        if query == rm.SET_ROLE_REACH_SQL:
            self.reach_queries = getattr(self, "reach_queries", []) + [list(args[0])]
            return [{"role": r} for r in args[0] if r not in self.members and r != self.login]
        if query == rm.OBJECTS_SQL:
            self.postchecks.append((list(args[0]), args[1]))
            if len(self.postchecks) == 1:
                return list(self.base)
            late = self.late if len(self.postchecks) > 2 else []
            return self.base + [obj(k, n, self.login) for k, n in self.stray + late]
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
        if query == rm.CAN_REGISTER_SQL:
            return self.can_register
        if query == rm.XACT_IDS_SQL:
            return self.xact_ids.pop(0) if self.xact_ids else 1
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


# X1 S22: the master DSN the runner reads in the task (rm.MASTER_SECRET) when DATABASE_URL is db_migrator's.
IN_TASK_MASTER_PW = "in-task-master-pw"                 # fake; f-string keeps the secret scan's URI rule quiet
IN_TASK_MASTER_DSN = f"postgresql://aa_cis_admin:{IN_TASK_MASTER_PW}@db.example:5432/aa_cis_dev"


class RunTaskTest(unittest.TestCase):
    def run_task(self, sql, mode="apply", conn=None, version="240", file="cis/x.sql", master=None, **extra):
        """`conn` answers the task's DATABASE_URL; `master` (X1 S22) the in-task master DSN read from
        rm.MASTER_SECRET (None: the secret read fails). self.seen records connects and secret reads."""
        raw = sql.encode()
        env = {"MIGRATION_URL": "u", "MIGRATION_SHA256": hashlib.sha256(raw).hexdigest(),
               "MIGRATION_VERSION": version, "MIGRATION_MODE": mode, "MIGRATION_FILE": file,
               "DATABASE_URL": "postgresql://x", **extra}
        conn = conn or FakeConn()
        seen = self.seen = {"connects": [], "secret_reads": []}

        async def connect(dsn, settings, **kw):
            seen["settings"] = settings
            seen["connects"].append((dsn, kw))
            return master if dsn == IN_TASK_MASTER_DSN else conn

        def get_secret(sid):
            seen["secret_reads"].append(sid)
            if master is None:
                raise LookupError("no such secret in this test")
            return IN_TASK_MASTER_DSN

        self.sleeps = []

        async def sleep(s):
            self.sleeps.append(s)

        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = asyncio.run(rm.run_task(env, fetch=lambda url: raw, connect=connect, sleep=sleep,
                                           get_secret=get_secret))
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
        env = {"MIGRATION_URL": "u", "MIGRATION_SHA256": "0" * 64, "MIGRATION_MODE": "apply"}   # mode first (X1 S12)
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


# What the runner sends between a switched body and RESET ROLE when one settle round writes nothing.
SETTLE_ONE_ROUND = ["SAVEPOINT x1_settle", "SET CONSTRAINTS ALL IMMEDIATE", "RELEASE SAVEPOINT x1_settle",
                    "CLOSE ALL"]

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
                                         "\n".join(s.text for s in stmts[1:-1]), *SETTLE_ONE_ROUND, "RESET ROLE",
                                         "SET LOCAL search_path TO pg_catalog, pg_temp", stmts[-1].text,
                                         "SET search_path TO pg_catalog, pg_temp", "RESET search_path"])
        self.assertTrue(conn.executed[0].startswith("-- Migration bk-015") and conn.executed[0].endswith("BEGIN;"))
        self.assertEqual(stmts[-1].text, "COMMIT;")
        # Snapshot after BEGIN (as the login role), after RESET ROLE (post-check) and after COMMIT.
        self.assertEqual(conn.postchecks, [(list(rm.OWNER_SCHEMAS), "bk_owner")] * 3)
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
        self.assertEqual(conn.executed[-3:], ["RESET ROLE", "SET LOCAL search_path TO pg_catalog, pg_temp",
                                              "ROLLBACK"])
        self.assertNotIn("COMMIT;", conn.executed)
        self.assertIn("ownership post-check (ran as bk_owner, login aa_cis_admin): relation booking.oops "
                      "(owner aa_cis_admin). Rolled back.", log)

    def test_switched_file_must_be_one_transaction_block(self):
        two_blocks = "BEGIN;\nSELECT 1;\nCOMMIT;\nBEGIN;\nINSERT INTO shared.schema_versions VALUES ('tp-012');\nCOMMIT;\n"
        switched = dict(owners={**TODAY_OWNERS, "tripplanner": "tp_owner"}, members={"tp_owner"})
        # Above the head the lint refuses it before any connection (exit 4, in the PR too).
        code, conn, settings, log = self.run_task(two_blocks, file="tripplanner/014_x.sql", version="tp-014",
                                                  conn=FakeConn(**switched))
        self.assertEqual((code, conn.executed, settings), (4, [], None))
        self.assertIn("MIGRATE ERROR: line 3: transaction control inside the file", log)
        # At or below the head (never shape-linted) the switch still refuses it at run time (exit 8).
        code, conn, _, log = self.run_task(two_blocks, file="tripplanner/012_x.sql", version="tp-012",
                                           conn=FakeConn(**switched))
        self.assertEqual((code, conn.executed), (8, []))
        self.assertIn("line 3: transaction control inside the file", log)
        # Not switched (today): the same file still runs as it always did.
        code, conn, _, _ = self.run_task(two_blocks, file="tripplanner/012_x.sql", version="tp-012")
        self.assertEqual((code, conn.executed), (0, [two_blocks]))

    def test_switched_no_transaction_file_uses_a_session_role(self):
        conn = FakeConn(owners={**TODAY_OWNERS, "shared": "cis_owner"}, members={"cis_owner"})
        code, conn, _, _ = self.run_task(NO_TX, file="cis/247_x.sql", version="247", conn=conn)
        self.assertEqual(code, 0)
        stmts = rm.split_statements(NO_TX)
        # Work as the owner; then the registration as the owner in the runner's own transaction, settled
        # and post-checked before its COMMIT (review S241 round 2: nothing of the file runs after the check).
        self.assertEqual(conn.executed, ['SET ROLE "cis_owner"', stmts[0].text, stmts[1].text, "RESET ROLE",
                                         "BEGIN", 'SET LOCAL ROLE "cis_owner"',
                                         "SET LOCAL search_path TO pg_catalog, pg_temp", stmts[2].text,
                                         *SETTLE_ONE_ROUND, "RESET ROLE",
                                         "SET LOCAL search_path TO pg_catalog, pg_temp", "COMMIT",
                                         "SET search_path TO pg_catalog, pg_temp", "RESET search_path"])
        self.assertEqual(len(conn.postchecks), 3)

    def test_switched_no_transaction_postcheck_failure_leaves_the_version_unregistered(self):
        conn = FakeConn(owners={**TODAY_OWNERS, "shared": "cis_owner"}, members={"cis_owner"},
                        stray=[("relation", "shared.ix_a")], registers=False)
        code, conn, _, log = self.run_task(NO_TX, file="cis/247_x.sql", version="247", conn=conn)
        self.assertEqual(code, 9)
        # The registration ran in the runner's transaction and was rolled back with it.
        self.assertEqual(conn.executed[-3:], ["RESET ROLE", "SET LOCAL search_path TO pg_catalog, pg_temp",
                                              "ROLLBACK"])
        self.assertNotIn("COMMIT", conn.executed)
        self.assertIn("relation shared.ix_a (owner aa_cis_admin)", log)
        self.assertIn("the version is NOT registered", log)

    def test_settle_repeats_while_deferred_work_writes(self):
        """Review S241 round 2: a fired deferred trigger can re-defer and queue more; a round that
        assigned a transaction id (a write) is repeated, a quiet round ends the settle."""
        conn = FakeConn(owners={**TODAY_OWNERS, "booking": "bk_owner"}, members={"bk_owner"},
                        xact_ids=[1, 2, 2, 3, 3, 3])
        code, conn, _, log = self.run_task(BK_FILE, file="booking/015_x.sql", version="bk-015", conn=conn)
        self.assertEqual(code, 0, log)
        self.assertEqual(conn.executed.count("SET CONSTRAINTS ALL IMMEDIATE"), 3)
        settle = conn.executed.index("SAVEPOINT x1_settle")
        self.assertLess(settle, conn.executed.index("RESET ROLE"))       # under the owner role
        self.assertEqual(conn.executed[-3], "COMMIT;")

    def test_settle_that_never_quiets_down_is_refused(self):
        conn = FakeConn(owners={**TODAY_OWNERS, "booking": "bk_owner"}, members={"bk_owner"},
                        xact_ids=list(range(100)))
        code, conn, _, log = self.run_task(BK_FILE, file="booking/015_x.sql", version="bk-015", conn=conn)
        self.assertEqual(code, 9)
        self.assertEqual(conn.executed.count("SET CONSTRAINTS ALL IMMEDIATE"), rm.SETTLE_ROUNDS)
        self.assertEqual(conn.executed[-1], "ROLLBACK")
        self.assertNotIn("COMMIT;", conn.executed)
        self.assertIn(f"deferred trigger work still queues more after {rm.SETTLE_ROUNDS} rounds", log)

    def test_object_appearing_at_commit_is_reported(self):
        for sql, file, version in ((BK_FILE, "booking/015_x.sql", "bk-015"), (NO_TX, "cis/247_x.sql", "247")):
            with self.subTest(file=file):
                conn = FakeConn(owners={**TODAY_OWNERS, "booking": "bk_owner", "shared": "cis_owner"},
                                members={"bk_owner", "cis_owner"}, late=[("relation", "booking.at_commit")])
                code, conn, _, log = self.run_task(sql, file=file, version=version, conn=conn)
                self.assertEqual(code, 9)
                self.assertIn(conn.executed[-3], ("COMMIT;", "COMMIT"))
                self.assertIn("ownership check after COMMIT (ran as ", log)
                self.assertIn("relation booking.at_commit (owner aa_cis_admin). Something ran at COMMIT", log)

    def test_switched_no_transaction_registration_must_be_plain_at_run_time(self):
        """Below the head the lint does not run; the switch still refuses a registration with code in it."""
        sql = NO_TX.replace("VALUES ('241', now(), 'AA-2: covering index')", "SELECT shared.reg()")
        conn = FakeConn(owners={**TODAY_OWNERS, "shared": "cis_owner"}, members={"cis_owner"})
        code, conn, _, log = self.run_task(sql, file="cis/242_x.sql", version="242", conn=conn)
        self.assertEqual((code, conn.executed, conn.postchecks), (8, [], []))
        self.assertIn("MIGRATE ERROR: role: line 6: under the role switch the last statement of a no-transaction", log)
        # Not switched (today): unchanged.
        self.assertEqual(self.run_task(sql, file="cis/242_x.sql", version="242")[0], 0)

    def test_switch_refuses_when_the_owner_cannot_register(self):
        for sql, file, version in ((BK_FILE, "booking/015_x.sql", "bk-015"), (NO_TX, "cis/247_x.sql", "247")):
            with self.subTest(file=file):
                owners = {**TODAY_OWNERS, "booking": "bk_owner", "shared": "cis_owner"}
                conn = FakeConn(owners=owners, members={"bk_owner", "cis_owner"}, can_register=False)
                code, conn, _, log = self.run_task(sql, file=file, version=version, conn=conn)
                self.assertEqual((code, conn.executed, conn.postchecks), (8, [], []))
                self.assertIn("cannot register the version (needs USAGE on schema shared and INSERT on "
                              "shared.schema_versions, X1 plan S4 / CIS 243): nothing ran", log)
                # check mode only reports; an applied file is skipped before the grant matters.
                conn = FakeConn(owners=owners, members={"bk_owner", "cis_owner"}, can_register=False)
                self.assertEqual(self.run_task(sql, mode="check", file=file, version=version, conn=conn)[0], 0)
                conn = FakeConn(owners=owners, members={"bk_owner", "cis_owner"}, can_register=False,
                                applied="2026-10-17")
                self.assertEqual(self.run_task(sql, file=file, version=version, conn=conn)[0], 0)

    def test_roles_dir_runs_only_as_the_master(self):
        code, conn, _, log = self.run_task(ROLES_FILE, file="roles/001_x1_owner_roles.sql", version="rl-001")
        self.assertEqual((code, conn.executed), (0, [ROLES_FILE]))
        self.assertIn("MIGRATE master login: the task's DATABASE_URL\n", log)
        self.assertIn("MIGRATE ran as: aa_cis_admin — roles/ file, runs as the master", log)
        self.assertEqual(self.seen["secret_reads"], [])                        # before S22: no secret read
        # The in-task master DSN logs in as someone else: refused, nothing ran.
        code, conn, _, log = self.run_task(ROLES_FILE, file="roles/001_x1_owner_roles.sql", version="rl-001",
                                           conn=FakeConn(login="db_migrator"), master=FakeConn(login="db_migrator"))
        self.assertEqual((code, conn.executed), (8, []))
        self.assertIn("roles/ files run only as the RDS master aa_cis_admin (login is db_migrator)", log)

    def test_roles_dir_under_db_migrator_reads_the_master_in_the_task(self):
        """X1 S22: DATABASE_URL is db_migrator's; a roles/ file runs on the master DSN read from MASTER_SECRET."""
        login, master = FakeConn(login="db_migrator"), FakeConn()
        code, conn, _, log = self.run_task(ROLES_FILE, file="roles/003_x.sql", version="rl-003", conn=login,
                                           master=master)
        self.assertEqual(code, 0, log)
        self.assertEqual((login.executed, login.closed), ([], True))           # the db_migrator session only asked
        self.assertEqual((master.executed, master.closed), ([ROLES_FILE], True))
        self.assertEqual(self.seen["secret_reads"], ["aa-cis/dev/rds"])
        self.assertEqual(self.seen["connects"], [("postgresql://x", {}), (IN_TASK_MASTER_DSN, {"ssl": "require"})])
        self.assertIn("MIGRATE master login: a roles/ file needs the RDS master aa_cis_admin and the task logs in "
                      "as db_migrator: reading the master DSN in the task from aa-cis/dev/rds (X1 S22)\n", log)
        self.assertIn("MIGRATE master login: in-task DSN from aa-cis/dev/rds\n", log)
        self.assertIn("MIGRATE ran as: aa_cis_admin — roles/ file, runs as the master", log)
        self.assertNotIn(IN_TASK_MASTER_PW, log)

    def test_roles_dir_without_a_readable_master_secret_is_refused(self):
        code, conn, _, log = self.run_task(ROLES_FILE, file="roles/003_x.sql", version="rl-003",
                                           conn=FakeConn(login="db_migrator"))
        self.assertEqual((code, conn.executed), (8, []))
        self.assertIn("MIGRATE ERROR: role: roles/ files run only as the RDS master aa_cis_admin: master DSN secret "
                      "aa-cis/dev/rds unreadable (LookupError). Nothing ran\n", log)

    def test_owner_dirs_never_read_the_master_secret(self):
        conn = FakeConn(login="db_migrator", members={"cis_owner", "bk_owner", "tp_owner", "catalog_owner"},
                        owners={"shared": "cis_owner", "booking": "bk_owner", "tripplanner": "tp_owner"})
        for file, version in (("cis/246_x1_set_role_probe.sql", "246"), ("booking/013_x.sql", "bk-013")):
            with self.subTest(file=file):
                code, _, _, log = self.run_task(PLAIN, mode="check", file=file, version=version, conn=conn,
                                                master=FakeConn())
                self.assertEqual(code, 0, log)
                self.assertEqual(self.seen["secret_reads"], [])
                self.assertNotIn("master login", log)

    def test_master_owned_anchor_is_refused_under_db_migrator(self):
        """X1 S22: a dir whose anchor schema is still the master's cannot run under db_migrator (not a member)."""
        conn = FakeConn(login="db_migrator", members={"cis_owner", "bk_owner", "tp_owner", "catalog_owner"},
                        owners={"shared": "aa_cis_admin", "booking": "bk_owner", "tripplanner": "tp_owner"})
        code, conn, _, log = self.run_task(PLAIN, mode="check", file="cis/246_x.sql", version="246", conn=conn)
        self.assertEqual((code, conn.executed), (8, []))
        self.assertIn("anchor schema shared is owned by aa_cis_admin and the login role db_migrator is not a member",
                      log)

    def test_unknown_dir_is_refused_and_missing_anchor_does_not_switch(self):
        code, conn, _, log = self.run_task(PLAIN, file="crm/001_x.sql", version="crm-001")
        self.assertEqual((code, conn.executed), (8, []))
        self.assertIn("unknown migration dir 'crm'", log)
        code, conn, _, log = self.run_task(PLAIN, file="tripplanner/013_x.sql", version="tp-013",
                                           conn=FakeConn(owners={"shared": "aa_cis_admin"}))
        self.assertEqual((code, conn.executed), (0, [PLAIN]))
        self.assertIn("anchor schema tripplanner does not exist yet, no role switch", log)

    def test_postcheck_sql_shape_is_pinned(self):
        q = rm.OBJECTS_SQL
        for part in ("n.nspname = ANY($1::text[]) AS mine", "r.rolname = $2",
                     "n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')",
                     "t.typrelid = 0 AND t.typcategory <> 'A'", "o.owner IS NULL OR o.owner IS DISTINCT FROM"):
            self.assertIn(part, q)
        # Every catalog that has an owner column a migration can set, plus the role catalog.
        for catalog in ("pg_class", "pg_proc", "pg_type", "pg_namespace", "pg_operator", "pg_opclass",
                        "pg_opfamily", "pg_collation", "pg_conversion", "pg_ts_dict", "pg_ts_config",
                        "pg_statistic_ext", "pg_default_acl", "pg_extension", "pg_language",
                        "pg_foreign_data_wrapper", "pg_foreign_server", "pg_publication", "pg_event_trigger",
                        "pg_largeobject_metadata", "pg_database", "pg_roles", "pg_auth_members",
                        "pg_db_role_setting"):
            self.assertIn(f"FROM pg_catalog.{catalog} ", q.replace("\n", " "))
        # A file cannot shadow a catalog or function: every name is qualified (and search_path pinned).
        self.assertEqual(re.findall(r"(?<![.\w])(pg_[a-z_0-9]+)\s*[(]", q), [])
        self.assertEqual(re.findall(r"\b(?:FROM|JOIN)\s+(?!pg_catalog\.)(pg_[a-z_]+)", q), [])
        self.assertEqual(re.findall(r"(?<![.\w])(md5|has_\w+_privilege)\s*[(]", q + rm.CAN_REGISTER_SQL), [])
        self.assertEqual(rm.SCHEMA_OWNER_SQL,
                         "SELECT pg_get_userbyid(nspowner)::text FROM pg_namespace WHERE nspname = $1")
        self.assertEqual(rm.IS_MEMBER_SQL, "SELECT pg_has_role(session_user, $1, 'MEMBER')")


class OwnershipFindingsTest(unittest.TestCase):
    """ownership_findings(): the diff between the snapshot before and after a switched file."""

    def plan(self, run_as="bk_owner", login="aa_cis_admin"):
        return rm.RolePlan(login, run_as=run_as)

    def test_new_or_re_owned_objects_must_belong_to_the_owner(self):
        before = [obj("relation", "shared.tenants", "aa_cis_admin", mine=True, schema_owner="aa_cis_admin")]
        after = before + [obj("relation", "public.p4", "aa_cis_admin", mine=False, schema_owner="pg_database_owner"),
                          obj("schema", "p2", "aa_cis_admin", mine=False, schema_owner="aa_cis_admin"),
                          obj("schema", "booking", "aa_cis_admin", schema_owner="aa_cis_admin"),
                          obj("default privileges", "booking r", "aa_cis_admin", oid="1:{x}"),
                          obj("relation", "booking.t", "booking")]
        found = rm.ownership_findings(before, after, self.plan(), "booking")
        self.assertEqual(found, ["default privileges booking r (owner aa_cis_admin)",
                                 "relation booking.t (owner booking)",
                                 "relation public.p4 (owner aa_cis_admin)",
                                 "schema booking (owner aa_cis_admin)", "schema p2 (owner aa_cis_admin)"])

    def test_role_catalog_changes_are_refused(self):
        before = [obj("role", "booking", None, oid="h1"), obj("role membership", "aa_cis_admin in bk_owner", None, oid="h2")]
        after = [obj("role", "booking", None, oid="h1b"), obj("role", "x_evil", None, oid="h3")]
        found = rm.ownership_findings(before, after, self.plan(), "booking")
        self.assertEqual(found, ["role booking added or changed", "role booking removed or changed",
                                 "role membership aa_cis_admin in bk_owner removed or changed",
                                 "role x_evil added or changed"])

    def test_view_owner_and_unchanged_rows_pass(self):
        before = [obj("relation", "shared.tenants", "aa_cis_admin", schema_owner="aa_cis_admin"),
                  obj("role", "booking", None, oid="h1")]
        after = before + [obj("relation", "catalog.v_x", "catalog_owner", schema_owner="cis_owner")]
        self.assertEqual(rm.ownership_findings(before, after, self.plan("cis_owner", "db_migrator"), "cis"), [])
        # cis_app (a runtime role, DM-1.3) may not own what a cis file creates.
        after = before + [obj("relation", "shared.x", "cis_app", schema_owner="cis_owner")]
        self.assertEqual(rm.ownership_findings(before, after, self.plan("cis_owner", "db_migrator"), "cis"),
                         ["relation shared.x (owner cis_app)"])

    def test_login_objects_left_in_a_transferred_schema_are_refused_even_if_old(self):
        old = [obj("relation", "booking.old_stray", "aa_cis_admin", schema_owner="bk_owner"),
               obj("default privileges", "booking r", "aa_cis_admin", oid="9:{y}"),
               obj("relation", "shared.tenants", "aa_cis_admin", schema_owner="aa_cis_admin")]
        found = rm.ownership_findings(old, old, self.plan(), "booking")
        self.assertEqual(found, ["relation booking.old_stray (owner aa_cis_admin, in a schema owned by bk_owner)"])


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
            # Review S241 (confirmed on PostgreSQL 16): forms that switched the role past the first lint.
            ("booking/015_x.sql", 'SET "role" TO aa_cis_admin;', "only `SET LOCAL ROLE` is allowed"),
            ("booking/015_x.sql", "SET LOCAL \"role\" = 'aa_cis_admin';", "`SET LOCAL ROLE aa_cis_admin` is not allowed"),
            ("booking/015_x.sql", 'RESET "role";', "RESET ROLE returns"),
            ("booking/015_x.sql", "SET session_authorization = 'x';", "SESSION AUTHORIZATION is not allowed"),
            ("booking/015_x.sql", "RESET session_authorization;", "SESSION AUTHORIZATION is not allowed"),
            ("booking/015_x.sql", "SELECT set_config(E'role', 'aa_cis_admin', true);", "set_config('role', …) switches"),
            ("booking/015_x.sql", "SELECT set_config(U&'role', 'aa_cis_admin', true);", "set_config('role', …) switches"),
            ("booking/015_x.sql", "SELECT \"set_config\"('role', 'aa_cis_admin', true);", "set_config('role', …) switches"),
            ("booking/015_x.sql", "SELECT set_config($q$role$q$, 'aa_cis_admin', true);",
             "set_config() whose parameter name is not a plain string literal"),
            ("booking/015_x.sql", "SELECT pg_catalog.set_config('ro' || 'le', 'x', true);",
             "set_config() whose parameter name is not a plain string literal"),
            ("booking/015_x.sql", "DO $$ BEGIN EXECUTE 'RE' || 'SET ROLE'; END $$;", "dynamic SQL"),
            ("booking/015_x.sql", "DO $$ BEGIN EXECUTE format('%s ROLE', 'RESET'); END $$;", "dynamic SQL"),
            ("booking/015_x.sql", "DO $$ BEGIN EXECUTE E'RESET ROLE'; END $$;", "dynamic SQL 'RESET ROLE'"),
            ("booking/015_x.sql", "DO $$ BEGIN EXECUTE concat('SET LOCAL ', 'ROLE x'); END $$;", "dynamic SQL"),
            ("booking/015_x.sql", "DO $$ DECLARE v text := 'RESET ' || 'ROLE'; BEGIN EXECUTE v; END $$;",
             "dynamic SQL"),
            ("booking/015_x.sql", "DO $$ DECLARE v text; BEGIN v := 'GRANT bk_owner TO booking'; EXECUTE v; END $$;",
             "grants a role membership"),
            ("booking/015_x.sql", "ALTER DATABASE x SET \"role\" = 'aa_cis_admin';", "only `SET LOCAL ROLE`"),
            # Review S241 round 2: work deferred to COMMIT runs after the post-check.
            ("booking/015_x.sql", "CREATE CONSTRAINT TRIGGER t AFTER INSERT ON booking.x DEFERRABLE INITIALLY "
             "DEFERRED FOR EACH ROW EXECUTE FUNCTION booking.f();", "constraint trigger fires at COMMIT"),
            ("booking/015_x.sql", "create constraint trigger t after insert on booking.x deferrable "
             "for each row execute function booking.f();", "constraint trigger fires at COMMIT"),
            ("cis/246_x.sql", "CREATE CONSTRAINT TRIGGER t AFTER UPDATE ON shared.x INITIALLY DEFERRED "
             "FOR EACH ROW EXECUTE FUNCTION shared.f();", "constraint trigger fires at COMMIT"),
            ("booking/015_x.sql", "SET CONSTRAINTS ALL DEFERRED;", "SET CONSTRAINTS … DEFERRED"),
            ("booking/015_x.sql", "SET CONSTRAINTS booking.c_fk, booking.t DEFERRED;", "SET CONSTRAINTS … DEFERRED"),
            ("booking/015_x.sql", "CREATE FUNCTION booking.f() RETURNS trigger LANGUAGE plpgsql AS "
             "'BEGIN SET CONSTRAINTS ALL DEFERRED; RETURN NULL; END';", "SET CONSTRAINTS … DEFERRED"),
            ("booking/015_x.sql", "DO $$ BEGIN EXECUTE 'SET CONSTRAINTS ALL ' || 'DEFERRED'; END $$;",
             "SET CONSTRAINTS … DEFERRED"),
            ("booking/015_x.sql", "DO 'BEGIN EXECUTE ''CREATE CONSTRAINT TRIGGER t AFTER INSERT ON booking.x "
             "DEFERRABLE FOR EACH ROW EXECUTE FUNCTION booking.f()''; END';", "constraint trigger fires at COMMIT"),
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
            'UPDATE booking.members SET "role" = \'admin\' WHERE false;',
            "DO $$ BEGIN EXECUTE format('ALTER TABLE %I.%I OWNER TO bk_owner', 'booking', 't'); END $$;",
            "DO $$ DECLARE r record; BEGIN FOR r IN SELECT tablename FROM pg_tables WHERE schemaname = 'booking' "
            "LOOP EXECUTE format('GRANT SELECT ON booking.%I TO booking', r.tablename); END LOOP; END $$;",
            "DO $$ BEGIN EXECUTE 'ALTER DEFAULT PRIVILEGES FOR ROLE bk_owner IN SCHEMA booking GRANT SELECT ON "
            "TABLES TO booking'; END $$;",
            "GRANT EXECUTE ON FUNCTION booking.f() TO booking;",
            "CREATE TRIGGER t BEFORE INSERT ON booking.x FOR EACH ROW EXECUTE FUNCTION booking.f();",
            "COMMENT ON COLUMN booking.m.role IS E'role of the member';",
            "CREATE TABLE booking.e (note text DEFAULT e'x');",
            "CREATE CONSTRAINT TRIGGER t AFTER INSERT ON booking.x NOT DEFERRABLE FOR EACH ROW "
            "EXECUTE FUNCTION booking.f();",
            "CREATE CONSTRAINT TRIGGER t AFTER INSERT ON booking.x FOR EACH ROW EXECUTE FUNCTION booking.f();",
            "SET CONSTRAINTS ALL IMMEDIATE;",
            "ALTER TABLE booking.c ADD CONSTRAINT c_fk FOREIGN KEY (p) REFERENCES booking.p DEFERRABLE "
            "INITIALLY DEFERRED;",
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

    def test_files_above_the_heads_are_one_transaction_block(self):
        """Review S241: the switch needs one BEGIN … COMMIT block (exit 8 at apply); the lint says so in the PR."""
        reg = "INSERT INTO shared.schema_versions VALUES ('x');\n"
        bad = {"no BEGIN": f"ALTER TABLE booking.x ADD COLUMN y int;\n{reg}",
               "two blocks": f"BEGIN;\nSELECT 1;\nCOMMIT;\nBEGIN;\n{reg}COMMIT;\n",
               "ROLLBACK inside": f"BEGIN;\nSELECT 1;\nROLLBACK;\n{reg}COMMIT;\n",
               "PREPARE TRANSACTION": f"BEGIN;\n{reg}PREPARE TRANSACTION 'x';\nCOMMIT;\n",
               "COMMIT AND CHAIN": f"BEGIN;\n{reg}COMMIT AND CHAIN;\n"}
        for name, sql in bad.items():
            for path in ("cis/243_x.sql", "booking/014_x.sql", "tripplanner/013_x.sql"):
                with self.subTest(case=name, path=path):
                    errors = self.lint(sql, path)
                    self.assertTrue(any("may run under the role switch" in e for e in errors), errors)
        # Below the heads (applied files, never re-run) and in roles/ (never switched): unchanged.
        for path in ("cis/242_x.sql", "booking/013_x.sql", "tripplanner/012_x.sql", "roles/001_x.sql"):
            self.assertEqual(self.lint(bad["two blocks"], path), [], path)
        # A no-transaction file above the head is fine (statement by statement under SET ROLE).
        self.assertEqual(self.lint(NO_TX, "cis/247_x.sql"), [])
        self.assertEqual(self.lint(self.body("SELECT 1;"), "booking/014_x.sql"), [])

    def test_switched_no_transaction_registration_is_plain(self):
        """Review S241 round 2: the registration runs right before the post-check; no code in it."""
        head = "-- migrate: no-transaction\nCREATE INDEX CONCURRENTLY IF NOT EXISTS ix ON booking.x (a);\n"
        ok = ("INSERT INTO shared.schema_versions (version, applied_at, description) VALUES ('bk-015', now(), 'x') "
              "ON CONFLICT (version) DO NOTHING;",
              "INSERT INTO shared.schema_versions VALUES ('bk-015', CURRENT_TIMESTAMP, E'it''s') "
              "ON CONFLICT DO NOTHING;",
              "insert into shared.schema_versions (version) values ('bk-015');",
              "INSERT INTO shared.schema_versions (version, applied_at, description)\nVALUES ('bk-015', NOW( ), NULL);")
        bad = ("INSERT INTO shared.schema_versions (version) SELECT booking.reg();",
               "INSERT INTO shared.schema_versions (version) VALUES (booking.reg());",
               "INSERT INTO shared.schema_versions (version) VALUES ((SELECT 'bk-015'));",
               "INSERT INTO shared.schema_versions (version) VALUES ('bk-015'::text);",
               "INSERT INTO shared.schema_versions (version) VALUES ('bk-015'), ('bk-016');",
               "INSERT INTO shared.schema_versions (version) VALUES ('bk-015') ON CONFLICT (version) DO UPDATE "
               "SET description = booking.f();",
               "INSERT INTO shared.schema_versions (version) VALUES ('bk-015') RETURNING booking.f(version);",
               "WITH x AS (SELECT booking.f()) INSERT INTO shared.schema_versions (version) VALUES ('bk-015');")
        for reg in ok:
            with self.subTest(reg=reg):
                self.assertEqual(self.lint(head + reg + "\n", "booking/015_x.sql"), [])
        for reg in bad:
            with self.subTest(reg=reg):
                errors = self.lint(head + reg + "\n", "booking/015_x.sql")
                self.assertTrue(any("must be a plain `INSERT INTO shared.schema_versions" in e for e in errors), errors)
                # At or below the head (applied, never linted) and transactional files: not this rule.
                self.assertEqual(self.lint(head + reg + "\n", "booking/013_x.sql"), [])
        self.assertEqual(self.lint(self.body("SELECT 1;").replace("VALUES ('x')", "SELECT booking.f()"),
                                   "booking/015_x.sql"), [])

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


CATALOG_RECIPE_246 = """-- Migration 246: X1 S22 probe + one catalog view through the recipe.
BEGIN;
GRANT CREATE ON SCHEMA catalog TO catalog_owner;
SET LOCAL ROLE catalog_owner;
CREATE OR REPLACE VIEW catalog.v_x AS SELECT 1 AS x;
SET LOCAL ROLE cis_owner;
REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;
INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('246', now(), 'X1 probe') ON CONFLICT (version) DO NOTHING;
COMMIT;
"""

GUARD_244 = """-- Migration 244: X1 cis_app guard block.
BEGIN;
INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('244', now(), 'X1 cis_app') ON CONFLICT (version) DO NOTHING;
DO $$ BEGIN SET LOCAL ROLE cis_app; PERFORM 1; END $$;
COMMIT;
"""


class CatalogFreezeLintTest(unittest.TestCase):
    """X1 review (S241): catalog.* view DDL only as catalog_owner (S22 recipe); frozen from S1 until S22 (XD9)."""

    lint = RoleLintTest.lint
    body = RoleLintTest.body

    def test_recipe_passes(self):
        self.assertEqual(self.lint(CATALOG_RECIPE_246, "cis/246_x1_set_role_probe.sql"), [])
        self.assertEqual(rm.set_local_role_targets(CATALOG_RECIPE_246), ["catalog_owner", "cis_owner"])

    def test_catalog_view_ddl_outside_the_recipe_is_refused(self):
        for path, stmt in (
                ("cis/246_x.sql", "CREATE OR REPLACE VIEW catalog.v_tour AS SELECT 1;"),
                ("cis/246_x.sql", 'CREATE VIEW "catalog".v_new AS SELECT 1;'),
                ("cis/246_x.sql", "DROP VIEW IF EXISTS catalog.v_tour;"),
                ("cis/246_x.sql", "ALTER MATERIALIZED VIEW catalog.m RENAME TO m2;"),
                ("cis/246_x.sql", "SET LOCAL ROLE catalog_owner;\nSET LOCAL ROLE cis_owner;\n"
                                  "CREATE OR REPLACE VIEW catalog.v_tour AS SELECT 1;"),
                ("booking/015_x.sql", "CREATE OR REPLACE VIEW catalog.v_tour AS SELECT 1;")):
            with self.subTest(path=path, stmt=stmt):
                errors = self.lint(self.body(stmt), path)
                self.assertTrue(any("catalog.* view changes need the catalog recipe" in e for e in errors),
                                errors)

    def test_old_catalog_dance_names_the_freeze(self):
        errors = self.lint(self.body("GRANT catalog_owner TO CURRENT_USER;"), "cis/246_x.sql")
        self.assertTrue(any("belongs in db/migrations/roles/" in e and "the S1–S22 freeze, XD9, is over" in e
                            for e in errors), errors)

    def test_files_at_or_below_the_head_are_not_linted(self):
        self.assertEqual(self.lint(self.body("CREATE OR REPLACE VIEW catalog.v_tour AS SELECT 1;"),
                                   "cis/235_catalog_v_tour_place_lateral_day_text.sql"), [])


class SetRoleReachTest(unittest.TestCase):
    """X1 review (S241): every SET LOCAL ROLE target must be reachable from the login role (PostgreSQL
    checks the session user), found at `check` time, not as 42501 at apply."""

    run_task = RunTaskTest.run_task

    def test_reach_sql_shape_is_pinned(self):
        q = rm.SET_ROLE_REACH_SQL
        self.assertIn("pg_catalog.pg_has_role(session_user, r.oid, 'MEMBER')", q)
        self.assertIn("r.oid IS NULL", q)          # a missing role is reported, pg_has_role never sees its name

    def test_catalog_recipe_refused_while_the_login_is_the_master(self):
        for mode in ("check", "apply"):
            with self.subTest(mode=mode):
                conn = FakeConn(owners={**TODAY_OWNERS, "shared": "cis_owner"}, members={"cis_owner"})
                code, conn, _, log = self.run_task(CATALOG_RECIPE_246, mode=mode, file="cis/246_x1_set_role_probe.sql",
                                                   version="246", conn=conn)
                self.assertEqual((code, conn.executed), (8, []), log)
                self.assertIn("SET LOCAL ROLE catalog_owner` but the login role aa_cis_admin is not a member", log)
                self.assertIn("catalog.* view changes need the catalog recipe", log)

    def test_catalog_recipe_runs_as_db_migrator(self):
        conn = FakeConn(login="db_migrator", owners={**TODAY_OWNERS, "shared": "cis_owner"},
                        members={"cis_owner", "catalog_owner"})
        code, conn, _, log = self.run_task(CATALOG_RECIPE_246, mode="check", file="cis/246_x1_set_role_probe.sql",
                                           version="246", conn=conn)
        self.assertEqual(code, 0, log)
        self.assertEqual(conn.reach_queries, [["catalog_owner", "cis_owner"]])

    def test_cis_app_guard_needs_cis_app_membership(self):
        # Before S22 the master is a member of cis_app (rl-001); from S22 db_migrator must be (rl-002).
        conn = FakeConn(members={"cis_app"})
        self.assertEqual(self.run_task(GUARD_244, mode="check", file="cis/244_x1_cis_app_runtime.sql",
                                       version="244", conn=conn)[0], 0)
        conn = FakeConn(login="db_migrator", owners={**TODAY_OWNERS, "shared": "cis_owner"}, members={"cis_owner"})
        code, conn, _, log = self.run_task(GUARD_244, mode="check", file="cis/247_x.sql", version="247", conn=conn)
        self.assertEqual(code, 8, log)
        self.assertIn("SET LOCAL ROLE cis_app` but the login role db_migrator is not a member", log)
        self.assertIn("migrator_member_of", log)

    def test_not_checked_below_the_head_or_without_targets(self):
        conn = FakeConn(applied="2026-10-10")
        code, conn, _, log = self.run_task(CATALOG_RECIPE_246, mode="check", conn=conn, version="235",
                                           file="cis/235_catalog_v_tour_place_lateral_day_text.sql")
        self.assertEqual(code, 0, log)
        self.assertFalse(hasattr(conn, "reach_queries"))
        code, conn, _, log = self.run_task(PLAIN, mode="check", file="cis/246_x.sql", version="246")
        self.assertEqual(code, 0, log)
        self.assertFalse(hasattr(conn, "reach_queries"))


if __name__ == "__main__":
    unittest.main()
