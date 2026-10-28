"""AA-993 Phase E slice M2a: `-- migrate: expand`, the apply lock, lock risk (exit 15), CIC validity (exit 16).

No database: the fakes of test_run_migration answer the new catalog queries. Run:
  python3 -m unittest discover -s db/tests -v
"""
import asyncio
import contextlib
import hashlib
import io
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "db"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import run_migration as rm  # noqa: E402
from test_run_migration import FakeConn, TODAY_OWNERS, job  # noqa: E402


def reg(version="240"):
    return (f"INSERT INTO shared.schema_versions (version, applied_at, description)\n"
            f"VALUES ('{version}', now(), 'AA-993: x') ON CONFLICT (version) DO NOTHING;\n")


def tx(body, version="240", header="-- migrate: expand\n"):
    return f"-- Migration {version}: AA-993 probe.\n{header}BEGIN;\n{body}\n{reg(version)}COMMIT;\n"


EXPAND_OK = tx("""CREATE TABLE booking.aa993_probe (id bigint PRIMARY KEY, trip_id bigint REFERENCES booking.trip (id),
  note text);
ALTER TABLE booking.aa993_probe ENABLE ROW LEVEL SECURITY;
ALTER TABLE booking.aa993_probe FORCE ROW LEVEL SECURITY;
CREATE POLICY p ON booking.aa993_probe USING (true);
CREATE INDEX ix_probe_trip ON booking.aa993_probe (trip_id);
GRANT SELECT, INSERT ON booking.aa993_probe TO booking;
ALTER TABLE booking.trip ADD COLUMN IF NOT EXISTS aa993_note text, ADD COLUMN aa993_n numeric(10,2) DEFAULT 0;
COMMENT ON COLUMN booking.trip.aa993_note IS 'pii:free_text';""", version="bk-099")

CIC = """-- Migration 241: AA-993 index.
-- migrate: no-transaction
-- migrate: expand
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_a ON shared.decision_log (stage, created_at);
""" + reg("241")


def errors(sql, path="booking/099_x.sql"):
    d = rm.parse_directives(sql)
    return rm.lint(sql, d, path)[0]


class DirectiveTests(unittest.TestCase):
    def test_expand_flag_and_30s_timeout(self):
        d = rm.parse_directives(EXPAND_OK)
        self.assertTrue(d.expand)
        self.assertEqual(d.settings["statement_timeout"], "30s")
        self.assertTrue(d.as_json()["expand"])

    def test_cic_file_keeps_the_default_timeout(self):
        self.assertEqual(rm.parse_directives(CIC).settings["statement_timeout"], "15min")

    def test_contract_file_unchanged(self):
        d = rm.parse_directives(tx("ALTER TABLE shared.tenants ADD COLUMN x int;", header=""))
        self.assertFalse(d.expand)
        self.assertEqual(d.settings, rm.DEFAULT_SETTINGS)

    def test_timeout_override_above_30s_refused_below_allowed(self):
        hi = tx("CREATE TABLE booking.t (id int);", header="-- migrate: expand\n-- migrate: statement_timeout=2min\n")
        lo = tx("CREATE TABLE booking.t (id int);", header="-- migrate: expand\n-- migrate: statement_timeout=10s\n")
        self.assertTrue(any("statement_timeout=2min" in e for e in errors(hi)))
        self.assertEqual(errors(lo), [])
        self.assertEqual(rm.parse_directives(lo).settings["statement_timeout"], "10s")


class StaticLintTests(unittest.TestCase):
    def test_allowed_expand_file_passes(self):
        self.assertEqual(errors(EXPAND_OK), [])

    def test_cic_file_passes_even_on_a_hot_table(self):
        self.assertEqual(errors(CIC, "cis/241_x.sql"), [])
        hot = CIC.replace("shared.decision_log", "shared.job")
        self.assertEqual(errors(hot, "cis/241_x.sql"), [])

    def test_expand_with_destructive_is_refused(self):
        sql = tx("CREATE TABLE booking.t (id int);", header="-- migrate: expand\n-- migrate: destructive\n")
        self.assertTrue(any("exclude each other" in e for e in errors(sql)))

    def test_contract_statements_are_refused(self):
        cases = {
            "REVOKE": "REVOKE SELECT ON booking.trip FROM booking;",
            "policy": "CREATE POLICY p2 ON booking.trip USING (true);",
            "trigger": "CREATE TRIGGER t BEFORE INSERT ON booking.trip FOR EACH ROW EXECUTE FUNCTION f();",
            "constraint": "ALTER TABLE booking.trip ADD CONSTRAINT c CHECK (id > 0);",
            "not null": "ALTER TABLE booking.trip ADD COLUMN y int NOT NULL;",
            "volatile": "ALTER TABLE booking.trip ADD COLUMN y uuid DEFAULT gen_random_uuid();",
            "generated": "ALTER TABLE booking.trip ADD COLUMN y int GENERATED ALWAYS AS (id * 2) STORED;",
            "fk on existing": "ALTER TABLE booking.trip ADD COLUMN y bigint REFERENCES booking.supplier (id);",
            "rls flag": "ALTER TABLE booking.trip DISABLE ROW LEVEL SECURITY;",
            "type": "ALTER TABLE booking.trip ALTER COLUMN note TYPE varchar(10);",
            "update": "UPDATE booking.trip SET note = '';",
            "insert": "INSERT INTO booking.config (k, v) VALUES ('a', 'b');",
            "replace view": "CREATE OR REPLACE VIEW booking.v_x AS SELECT 1;",
            "default privileges": "ALTER DEFAULT PRIVILEGES IN SCHEMA booking GRANT SELECT ON TABLES TO booking;",
            "unique index": "CREATE UNIQUE INDEX ux ON booking.trip (note);",
            "do block": "DO $$ BEGIN PERFORM 1; END $$;",
            "select": "SELECT pg_catalog.set_config('x', 'y', true);",
            "hot add column": "ALTER TABLE booking.job ADD COLUMN y int;",
            "hot fk": "CREATE TABLE booking.t (id int, job_id bigint REFERENCES booking.job (id));",
            "catalog": "CREATE VIEW catalog.v_new AS SELECT 1;",
            "grant other app": "CREATE TABLE booking.t (id int);\nGRANT SELECT ON booking.t TO cis_app;",
            "grant schema": "GRANT USAGE ON SCHEMA booking TO booking;",
            "grant existing": "GRANT SELECT ON booking.trip TO booking;",
            "alter function": "ALTER FUNCTION booking.f() OWNER TO booking;",
        }
        for name, stmt in cases.items():
            with self.subTest(case=name):
                self.assertNotEqual(errors(tx(stmt, version="bk-099")), [], stmt)

    def test_body_set_cannot_lift_or_disable_a_timeout(self):
        """Review S255: a body SET must not undo the 30 s cap of the header lint, nor set anything else."""
        refused = {
            "statement 15min": "SET LOCAL statement_timeout = '15min';",
            "statement 0": "SET statement_timeout TO 0;",
            "lock 0": "SET LOCAL lock_timeout = 0;",
            "lock 2min": "SET LOCAL lock_timeout = '2min';",
            "replication role": "SET LOCAL session_replication_role = replica;",
            "session authorization": "SET SESSION AUTHORIZATION booking;",
        }
        for name, stmt in refused.items():
            with self.subTest(case=name):
                self.assertNotEqual(errors(tx(stmt + "\nCREATE TABLE booking.t (id int);", version="bk-099")), [])
        for stmt in ("SET LOCAL lock_timeout = '5s';", "SET LOCAL statement_timeout = '20s';",
                     "SET LOCAL search_path = booking, public;"):
            with self.subTest(ok=stmt):
                self.assertEqual(errors(tx(stmt + "\nCREATE TABLE booking.t (id int);", version="bk-099")), [])

    def test_header_timeout_zero_is_refused(self):
        for hdr in ("statement_timeout=0", "lock_timeout=0", "lock_timeout=1min"):
            sql = tx("CREATE TABLE booking.t (id int);", header=f"-- migrate: expand\n-- migrate: {hdr}\n")
            with self.subTest(header=hdr):
                self.assertNotEqual(errors(sql), [])

    def test_serial_column_on_an_existing_table_is_refused(self):
        for t in ("serial", "bigserial", "smallserial", "serial8"):
            with self.subTest(type=t):
                self.assertNotEqual(errors(tx(f"ALTER TABLE booking.trip ADD COLUMN y {t};", version="bk-099")), [])
        self.assertEqual(errors(tx("CREATE TABLE booking.t (id bigserial PRIMARY KEY);", version="bk-099")), [])

    def test_expand_only_in_owner_dirs(self):
        sql = tx("CREATE TABLE shared.t (id int);", version="rl-009")
        self.assertTrue(any("only for owner dirs" in e for e in errors(sql, "roles/009_x.sql")))

    def test_set_role_catalog_owner_refused(self):
        sql = tx("SET LOCAL ROLE catalog_owner;\nCREATE TABLE shared.t (id int);")
        self.assertTrue(any("catalog_owner" in e for e in errors(sql, "cis/250_x.sql")))

    def test_no_transaction_expand_allows_only_cic(self):
        bad = CIC.replace("CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_a",
                          "CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS ix_a")
        self.assertNotEqual(errors(bad, "cis/241_x.sql"), [])
        no_ine = CIC.replace(" IF NOT EXISTS", "")
        self.assertNotEqual(errors(no_ine, "cis/241_x.sql"), [])

    def test_every_infra_copy_still_lints(self):
        """No copy on main carries the header yet, and the new code changes nothing for them."""
        files = sorted((ROOT / "db" / "migrations").glob("*/*.sql"))
        self.assertGreater(len(files), 100)
        for f in files:
            sql = f.read_text(encoding="utf-8")
            d = rm.parse_directives(sql)
            with self.subTest(file=f.name):
                self.assertFalse(d.expand)
                self.assertEqual(rm.lint(sql, d, str(f.relative_to(ROOT)))[0], [])


class RunTaskExpandTests(unittest.TestCase):
    def run_task(self, sql, mode="apply", conn=None, version="bk-099", file="booking/099_x.sql"):
        raw = sql.encode()
        env = {"MIGRATION_URL": "u", "MIGRATION_SHA256": hashlib.sha256(raw).hexdigest(),
               "MIGRATION_VERSION": version, "MIGRATION_MODE": mode, "MIGRATION_FILE": file,
               "DATABASE_URL": "postgresql://x"}
        conn = conn or FakeConn()
        self.settings, self.sleeps = None, []

        async def connect(dsn, settings, **kw):
            self.settings = settings
            return conn

        async def sleep(s):
            self.sleeps.append(s)

        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = asyncio.run(rm.run_task(env, fetch=lambda url: raw, connect=connect, sleep=sleep,
                                           get_secret=lambda sid: (_ for _ in ()).throw(LookupError(sid))))
        return code, conn, out.getvalue()

    def test_apply_runs_with_30s_and_skips_the_idle_wait(self):
        busy = FakeConn(states=[({"booking": [job("bk_x6_probe")], "shared": []}, 0)])
        code, conn, log = self.run_task(EXPAND_OK, conn=busy)
        self.assertEqual(code, 0, log)
        self.assertEqual(self.settings["statement_timeout"], "30s")
        self.assertEqual(self.sleeps, [])
        self.assertIn("idle wait skipped", log)
        self.assertIn("apply lock: taken", log)

    def test_contract_file_still_waits_and_refuses_when_busy(self):
        busy = FakeConn(states=[({"booking": [job("bk_x6_probe")], "shared": []}, 0)])
        code, conn, _ = self.run_task(tx("ALTER TABLE shared.tenants ADD COLUMN x int;", header="", version="240"),
                                      conn=busy, version="240", file="cis/240_x.sql")
        self.assertEqual((code, conn.executed), (7, []))

    def test_lock_risk_on_a_large_table_exits_15_before_anything(self):
        sql = tx("CREATE INDEX ix_big ON booking.trip (note);", version="bk-099")
        for mode in ("apply", "check"):
            conn = FakeConn()
            conn.reltuples = {"booking.trip": 200_000}
            code, conn, log = self.run_task(sql, mode=mode, conn=conn)
            with self.subTest(mode=mode):
                self.assertEqual(code, 15, log)
                self.assertEqual(conn.executed, [])
                self.assertEqual(getattr(conn, "lock_tries", 0), 0)     # refused before the apply lock
                self.assertIn("booking.trip: ~200000 rows", log)

    def test_small_table_passes_the_size_check(self):
        conn = FakeConn()
        conn.reltuples = {"booking.trip": 5_000}
        code, _, log = self.run_task(EXPAND_OK, conn=conn)
        self.assertEqual(code, 0, log)
        self.assertIn("lock-risk check ok (1 existing table(s)", log)

    def test_unknown_row_count_is_lock_risk(self):
        """Review S255: reltuples -1 (never analyzed, not empty) must not read as a small table."""
        conn = FakeConn()
        conn.reltuples = {"booking.trip": -1}
        code, conn, log = self.run_task(EXPAND_OK, conn=conn)
        self.assertEqual((code, conn.executed), (15, []), log)
        self.assertIn("booking.trip: row count unknown", log)

    def test_if_not_exists_of_an_existing_relation_is_lock_risk(self):
        """Review S255: CREATE TABLE IF NOT EXISTS of an existing table makes the lint treat it as new."""
        sql = tx("CREATE TABLE IF NOT EXISTS booking.trip (id int);\n"
                 "ALTER TABLE booking.trip ADD CONSTRAINT c CHECK (id > 0);", version="bk-099")
        self.assertEqual(errors(sql), [])          # the static lint cannot know: the runtime check does
        conn = FakeConn()
        conn.existing = {"booking.trip"}
        code, conn, log = self.run_task(sql, conn=conn)
        self.assertEqual((code, conn.executed), (15, []), log)
        self.assertIn("booking.trip already exists", log)
        code, _, log = self.run_task(sql, conn=FakeConn())
        self.assertEqual(code, 0, log)

    def test_if_not_exists_index_is_qualified_with_the_table_schema(self):
        sql = tx("CREATE INDEX IF NOT EXISTS ix_new ON booking.trip (note);", version="bk-099")
        self.assertEqual(rm.if_not_exists_relations(sql, rm.parse_directives(sql)), ["booking.ix_new"])
        self.assertEqual(rm.if_not_exists_relations(CIC, rm.parse_directives(CIC)), [])

    def test_already_applied_expand_file_skips_the_pre_check(self):
        conn = FakeConn(applied="2026-10-01 00:00:00+00")
        conn.reltuples = {"booking.trip": 500_000}
        code, conn, log = self.run_task(EXPAND_OK, conn=conn)
        self.assertEqual((code, conn.executed), (0, []), log)
        self.assertIn("already applied", log)

    def test_invalid_cic_exits_16_and_does_not_register(self):
        conn = FakeConn()
        conn.index_valid = {"shared.ix_a": False}
        code, conn, log = self.run_task(CIC, conn=conn, version="241", file="cis/241_x.sql")
        self.assertEqual(code, 16, log)
        self.assertEqual(len(conn.executed), 1)                 # the CIC ran, the registration did not
        self.assertIn("CREATE INDEX CONCURRENTLY", conn.executed[0])
        self.assertIn("shared.ix_a (INVALID)", log)

    def test_valid_cic_registers(self):
        code, conn, log = self.run_task(CIC, version="241", file="cis/241_x.sql")
        self.assertEqual(code, 0, log)
        self.assertEqual(len(conn.executed), 2)

    def test_invalid_cic_under_the_role_switch(self):
        sql = CIC.replace("shared.decision_log", "booking.trip").replace("'241'", "'bk-099'")
        conn = FakeConn(owners={**TODAY_OWNERS, "booking": "bk_owner"}, members={"bk_owner"})
        conn.index_valid = {"booking.ix_a": None}
        code, conn, log = self.run_task(sql, conn=conn)
        self.assertEqual(code, 16, log)
        self.assertFalse(any("schema_versions" in e for e in conn.executed))
        self.assertIn("booking.ix_a (missing)", log)

    def test_hot_cic_waits_for_an_open_wave(self):
        hot = CIC.replace("shared.decision_log", "shared.job")
        code, conn, log = self.run_task(hot, conn=FakeConn(states=[({"booking": [], "shared": []}, 1)]),
                                        version="241", file="cis/241_x.sql")
        self.assertEqual((code, conn.executed), (7, []))
        self.assertEqual(len(self.sleeps), rm.IDLE_WAITS)
        self.assertIn("names hot table shared.job", log)
        code, _, log = self.run_task(hot, conn=FakeConn(states=[({"booking": [], "shared": []}, 0)]),
                                     version="241", file="cis/241_x.sql")
        self.assertEqual(code, 0, log)

    def test_non_hot_expand_runs_during_an_open_wave(self):
        code, _, log = self.run_task(EXPAND_OK, conn=FakeConn(states=[({"booking": [], "shared": []}, 1)]))
        self.assertEqual(code, 0, log)


class ApplyLockTests(unittest.TestCase):
    def test_waits_then_takes_the_lock(self):
        conn = FakeConn()
        conn.lock_busy = 2
        sleeps = []

        async def sleep(s):
            sleeps.append(s)

        with contextlib.redirect_stdout(io.StringIO()) as out:
            ok = asyncio.run(rm.take_apply_lock(conn, sleep, "apply x"))
        self.assertTrue(ok)
        self.assertEqual(sleeps, [rm.APPLY_LOCK_POLL_S] * 2)
        self.assertIn("after 30 s", out.getvalue())

    def test_gives_up_with_17_and_runs_nothing(self):
        conn = FakeConn()
        conn.lock_busy = 10 ** 6
        raw = tx("ALTER TABLE shared.tenants ADD COLUMN x int;", header="").encode()
        env = {"MIGRATION_URL": "u", "MIGRATION_SHA256": hashlib.sha256(raw).hexdigest(), "MIGRATION_VERSION": "240",
               "MIGRATION_MODE": "apply", "MIGRATION_FILE": "cis/240_x.sql", "DATABASE_URL": "postgresql://x"}

        async def connect(dsn, settings, **kw):
            return conn

        async def sleep(s):
            pass

        with contextlib.redirect_stdout(io.StringIO()) as out:
            code = asyncio.run(rm.run_task(env, fetch=lambda u: raw, connect=connect, sleep=sleep))
        self.assertEqual((code, conn.executed), (17, []))
        self.assertIn("still holds it", out.getvalue())

    def test_check_mode_takes_no_lock(self):
        conn = FakeConn()
        raw = tx("ALTER TABLE shared.tenants ADD COLUMN x int;", header="").encode()
        env = {"MIGRATION_URL": "u", "MIGRATION_SHA256": hashlib.sha256(raw).hexdigest(), "MIGRATION_VERSION": "240",
               "MIGRATION_MODE": "check", "MIGRATION_FILE": "cis/240_x.sql", "DATABASE_URL": "postgresql://x"}

        async def connect(dsn, settings, **kw):
            return conn

        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(asyncio.run(rm.run_task(env, fetch=lambda u: raw, connect=connect)), 0)
        self.assertEqual(getattr(conn, "lock_tries", 0), 0)

    def test_two_concurrent_applies_serialize(self):
        """One shared lock: the second apply waits until the first one's connection closes, and never overlaps."""
        state = {"holder": None, "events": []}

        class LockConn(FakeConn):
            def __init__(self, name):
                super().__init__()
                self.name = name

            async def fetchval(self, query, *args):
                if query == rm.APPLY_LOCK_SQL:
                    if state["holder"] in (None, self.name):
                        state["holder"] = self.name
                        return True
                    return False
                return await super().fetchval(query, *args)

            async def execute(self, sql):
                state["events"].append((self.name, "start"))
                await asyncio.sleep(0)                  # yield: the other task runs here if it can
                await super().execute(sql)
                state["events"].append((self.name, "end"))

            async def close(self):
                if state["holder"] == self.name:
                    state["holder"] = None
                await super().close()

        def env_for(version):
            raw = tx(f"ALTER TABLE shared.tenants ADD COLUMN x{version} int;", header="", version=version).encode()
            return raw, {"MIGRATION_URL": "u", "MIGRATION_SHA256": hashlib.sha256(raw).hexdigest(),
                         "MIGRATION_VERSION": version, "MIGRATION_MODE": "apply",
                         "MIGRATION_FILE": f"cis/{version}_x.sql", "DATABASE_URL": "postgresql://x"}

        async def main():
            async def one(name, version):
                raw, env = env_for(version)
                conn = LockConn(name)

                async def connect(dsn, settings, **kw):
                    return conn
                return await rm.run_task(env, fetch=lambda u: raw, connect=connect, sleep=lambda s: asyncio.sleep(0))
            return await asyncio.gather(one("a", "240"), one("b", "241"))

        with contextlib.redirect_stdout(io.StringIO()):
            codes = asyncio.run(main())
        self.assertEqual(codes, [0, 0])
        names = [n for n, _ in state["events"]]
        self.assertEqual(names, sorted(names, key=lambda n: names.index(n)))   # a's events, then b's: no interleave
        self.assertEqual(len(set(names[:2])), 1)

    def test_run_script_that_writes_takes_the_lock_read_only_does_not(self):
        self.assertIn("take_apply_lock(conn, sleep, f\"run-script {path}\")",
                      (ROOT / "db" / "run_migration.py").read_text(encoding="utf-8"))
        self.assertIn("if not read_only and not await take_apply_lock",
                      (ROOT / "db" / "run_migration.py").read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
