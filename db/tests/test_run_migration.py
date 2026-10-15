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


class FakeConn:
    def __init__(self, applied=None, registers=True, fail=None):
        self.applied, self.registers, self.fail = applied, registers, fail
        self.executed, self.closed, self.ran = [], False, False

    async def fetchval(self, query, *args):
        if "ORDER BY version DESC" in query:
            return "230"
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

        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = asyncio.run(rm.run_task(env, fetch=lambda url: raw, connect=connect))
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
