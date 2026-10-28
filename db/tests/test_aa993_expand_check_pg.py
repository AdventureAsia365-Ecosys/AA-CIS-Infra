"""AA-993 Phase E slice M2b: the expand runtime post-check (exit 14) against a real PostgreSQL.

Skipped unless AA993_TEST_PG_DSN names a throw-away server's superuser DSN (and asyncpg is importable). The "Expand
classify" job of migration-copy-guard.yml runs it on a PostgreSQL 15 container (the RDS major); locally any 15 / 16:
  AA993_TEST_PG_DSN=postgresql://postgres@127.0.0.1:55493/postgres python3 -m unittest db.tests.test_aa993_expand_check_pg
Each test gets a fresh database with a small fixture: an owner role that owns schemas booking / shared / crm, an RLS
table, a config table, a view, a function, a hot table (shared.job) and the registry (shared.schema_versions). The
files run through run_migration.execute_file, the code DB Migrate runs, without the static lint: the runtime check is
the authority, so it must catch what the lint would also refuse.
"""
import asyncio
import contextlib
import io
import json
import os
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import run_migration as rm  # noqa: E402

try:
    import asyncpg
except ImportError:          # the guard job installs it; other jobs skip this file
    asyncpg = None

DSN = os.environ.get("AA993_TEST_PG_DSN", "")
DB = "aa993_expand_check"
OWNER = "aa993_bk_owner"
RUNTIME = "aa993_bk_rt"

FIXTURE = f"""
DO $$ BEGIN
  IF to_regrole('{OWNER}') IS NULL THEN CREATE ROLE {OWNER} NOLOGIN; END IF;
  IF to_regrole('{RUNTIME}') IS NULL THEN CREATE ROLE {RUNTIME} NOLOGIN; END IF;
END $$;
CREATE SCHEMA shared AUTHORIZATION {OWNER};
CREATE SCHEMA booking AUTHORIZATION {OWNER};
CREATE SCHEMA crm AUTHORIZATION {OWNER};
SET ROLE {OWNER};
CREATE TABLE shared.schema_versions (version text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now(),
  description text);
CREATE TABLE shared.job (id bigint PRIMARY KEY, kind text NOT NULL, status text NOT NULL);
CREATE TABLE booking.trip (id bigint PRIMARY KEY, note text);
INSERT INTO booking.trip VALUES (1, 'a'), (2, 'b');
ALTER TABLE booking.trip ENABLE ROW LEVEL SECURITY;
ALTER TABLE booking.trip FORCE ROW LEVEL SECURITY;
CREATE POLICY trip_rt ON booking.trip TO {RUNTIME} USING (id > 0);
CREATE POLICY trip_owner ON booking.trip TO {OWNER} USING (true);
CREATE TABLE booking.config (k text PRIMARY KEY, v text);
INSERT INTO booking.config VALUES ('x', '1');
CREATE VIEW booking.v_trip AS SELECT id FROM booking.trip;
CREATE FUNCTION booking.f(a int) RETURNS int LANGUAGE sql IMMUTABLE AS 'SELECT a';
CREATE TABLE crm.contact (id bigint PRIMARY KEY, tenant_id uuid NOT NULL);
ALTER TABLE crm.contact ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.contact FORCE ROW LEVEL SECURITY;
RESET ROLE;
"""


def reg(version):
    return (f"INSERT INTO shared.schema_versions (version, applied_at, description) "
            f"VALUES ('{version}', now(), 'AA-993 test') ON CONFLICT (version) DO NOTHING;\n")


def tx(body, version="bk-099"):
    return f"-- Migration {version}\n-- migrate: expand\nBEGIN;\n{body}\n{reg(version)}COMMIT;\n"


def _dsn(db):
    head, _, tail = DSN.rpartition("/")
    q = tail.split("?", 1)
    return f"{head}/{db}" + (f"?{q[1]}" if len(q) > 1 else "")


async def _fresh():
    admin = await asyncpg.connect(DSN)
    try:
        await admin.execute(f"DROP DATABASE IF EXISTS {DB} WITH (FORCE)")
        await admin.execute(f"CREATE DATABASE {DB}")
    finally:
        await admin.close()
    conn = await asyncpg.connect(_dsn(DB))
    try:
        await conn.execute(FIXTURE)
    finally:
        await conn.close()


async def _run(sql, switch=True, rehearse=False):
    """(exit code, findings, log, registered?) of one file run like DB Migrate apply (rehearse: like check)."""
    d = rm.parse_directives(sql)
    conn = await asyncpg.connect(_dsn(DB), server_settings=d.settings)
    found, out = [], io.StringIO()
    try:
        login = await conn.fetchval(rm.SESSION_USER_SQL)
        plan = rm.RolePlan(login, OWNER if switch else login, "test")
        with contextlib.redirect_stdout(out):
            code = await rm.execute_file(conn, sql, d, plan, "booking", rehearse=rehearse, report=found)
        if conn.is_in_transaction():
            await conn.execute("ROLLBACK")
        version = sql.split("VALUES ('", 1)[1].split("'", 1)[0]
        registered = await conn.fetchval("SELECT count(*) FROM shared.schema_versions WHERE version = $1", version)
    finally:
        await conn.close()
    return code, found, out.getvalue(), bool(registered)


@unittest.skipUnless(DSN and asyncpg is not None, "set AA993_TEST_PG_DSN (throw-away server) and install asyncpg")
class ExpandPostCheckPgTest(unittest.TestCase):
    def setUp(self):
        asyncio.run(_fresh())

    def run_file(self, sql, **kw):
        return asyncio.run(_run(sql, **kw))

    def assert_contract(self, sql, needle, **kw):
        code, found, log, registered = self.run_file(sql, **kw)
        self.assertEqual(code, 14, log)
        self.assertFalse(registered)
        self.assertTrue(any(needle in f for f in found), found)
        self.assertIn("expand file changed an existing object", log)
        return found

    # ── must exit 14 (design §2 M2b) ──
    def test_policy_using_true_on_an_existing_rls_table(self):
        self.assert_contract(tx("CREATE POLICY open_all ON booking.trip USING (true);"),
                             "policy booking.trip:open_all: new policy on existing table booking.trip")

    def test_trigger_or_check_on_an_existing_table(self):
        trig = tx("CREATE FUNCTION booking.tg() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN RETURN NEW; END$$;\n"
                  "CREATE TRIGGER t_ins BEFORE INSERT ON booking.trip FOR EACH ROW EXECUTE FUNCTION booking.tg();")
        self.assert_contract(trig, "trigger booking.trip:t_ins")
        asyncio.run(_fresh())
        self.assert_contract(tx("ALTER TABLE booking.trip ADD CONSTRAINT trip_pos CHECK (id > 0);"),
                             "constraint booking.trip:trip_pos")

    def test_insert_into_an_existing_config_table(self):
        self.assert_contract(tx("INSERT INTO booking.config VALUES ('y', '2');"),
                             "rows of existing table booking.config: 1 inserted")

    def test_update_and_delete_on_an_existing_table(self):
        found = self.assert_contract(tx("UPDATE booking.trip SET note = 'z' WHERE id = 1;\n"
                                        "DELETE FROM booking.config;"), "rows of existing table")
        self.assertTrue(any("booking.trip: 0 inserted, 1 updated" in f for f in found), found)
        self.assertTrue(any("booking.config: 0 inserted, 0 updated, 1 deleted" in f for f in found), found)

    def test_new_table_without_force_rls_in_an_rls_schema(self):
        self.assert_contract(tx("CREATE TABLE crm.note (id bigint PRIMARY KEY);\n"
                                "ALTER TABLE crm.note ENABLE ROW LEVEL SECURITY;"),
                             "relation crm.note: new table in an RLS schema")

    def test_new_tenant_table_without_rls_anywhere(self):
        self.assert_contract(tx("CREATE TABLE booking.tenant_x (id bigint PRIMARY KEY, tenant_id uuid);"),
                             "relation booking.tenant_x: new table has a tenant_id column")

    def test_create_or_replace_view(self):
        self.assert_contract(tx("CREATE OR REPLACE VIEW booking.v_trip AS SELECT id FROM booking.trip WHERE id > 1;"),
                             "relation booking.v_trip: view definition changed")

    def test_object_owned_by_the_owner_role_is_altered(self):
        """OBJECTS_SQL drops rows owned by the run-as role; this snapshot does not."""
        self.assert_contract(tx(f"GRANT SELECT ON booking.trip TO {RUNTIME};"), "relation booking.trip: grants changed")

    def test_add_column_on_a_hot_table(self):
        self.assert_contract(tx("ALTER TABLE shared.job ADD COLUMN lane text;"),
                             "column shared.job.lane: added to hot table shared.job")

    def test_overload_default_privileges_and_rewrite(self):
        self.assert_contract(tx("CREATE FUNCTION booking.f(a text) RETURNS text LANGUAGE sql AS 'SELECT a';"),
                             "overload of an existing function name booking.f")
        asyncio.run(_fresh())
        self.assert_contract(tx(f"ALTER DEFAULT PRIVILEGES IN SCHEMA booking GRANT SELECT ON TABLES TO {RUNTIME};"),
                             "default privileges")
        asyncio.run(_fresh())
        self.assert_contract(tx("ALTER TABLE booking.trip ADD COLUMN token text DEFAULT md5(random()::text);"),
                             "relation booking.trip: storage (relfilenode: a table rewrite) changed")

    def test_drop_and_type_change_are_contract(self):
        self.assert_contract(tx("ALTER TABLE booking.trip ALTER COLUMN note TYPE varchar(20);"),
                             "column booking.trip.note: type changed")
        asyncio.run(_fresh())
        self.assert_contract(tx("DROP VIEW booking.v_trip;"), "relation booking.v_trip: dropped or renamed")

    def test_registration_cte_cannot_unregister_another_key(self):
        """Review S256: the expand lint skips the registration statement; the runtime check refuses the delete."""
        async def seed():
            conn = await asyncpg.connect(_dsn(DB))
            try:
                await conn.execute(reg("bk-001"))
            finally:
                await conn.close()
        asyncio.run(seed())
        sql = ("-- Migration bk-099\n-- migrate: expand\nBEGIN;\nCREATE TABLE booking.aa993_x (id bigint);\n"
               "WITH d AS (DELETE FROM shared.schema_versions WHERE version = 'bk-001' RETURNING 1) "
               "INSERT INTO shared.schema_versions (version, applied_at, description) "
               "VALUES ('bk-099', now(), 'x');\nCOMMIT;\n")
        self.assert_contract(sql, "rows of the registry shared.schema_versions: 1 inserted, 0 updated, 1 deleted")

    def test_new_security_definer_function(self):
        self.assert_contract(tx("CREATE FUNCTION booking.peek() RETURNS SETOF booking.trip LANGUAGE sql "
                                "SECURITY DEFINER AS 'SELECT * FROM booking.trip';"),
                             "function booking.peek(): new SECURITY DEFINER function")

    def test_plain_path_without_role_switch(self):
        self.assert_contract(tx("CREATE POLICY open_all ON booking.trip USING (true);"), "new policy", switch=False)

    # ── must pass ──
    def test_new_nullable_column_and_constant_default(self):
        sql = tx("ALTER TABLE booking.trip ADD COLUMN aa993_note text, ADD COLUMN aa993_n numeric(10,2) DEFAULT 0;")
        code, found, log, registered = self.run_file(sql)
        self.assertEqual((code, found), (0, []), log)
        self.assertTrue(registered)
        self.assertIn("expand post-check: ok", log)

    def test_new_table_with_fk_to_an_existing_table_and_rls(self):
        sql = tx(f"""CREATE TABLE booking.aa993_probe (id bigint PRIMARY KEY,
  trip_id bigint REFERENCES booking.trip (id), note text);
ALTER TABLE booking.aa993_probe ENABLE ROW LEVEL SECURITY;
ALTER TABLE booking.aa993_probe FORCE ROW LEVEL SECURITY;
CREATE POLICY p ON booking.aa993_probe USING (true);
CREATE INDEX ix_probe_trip ON booking.aa993_probe (trip_id);
CREATE UNIQUE INDEX ux_probe_note ON booking.aa993_probe (note);
GRANT SELECT, INSERT ON booking.aa993_probe TO {RUNTIME};
INSERT INTO booking.aa993_probe VALUES (1, 1, 'seed');
CREATE TABLE crm.aa993_t (id bigint PRIMARY KEY, tenant_id uuid);
ALTER TABLE crm.aa993_t ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.aa993_t FORCE ROW LEVEL SECURITY;
CREATE FUNCTION booking.aa993_new(a int) RETURNS int LANGUAGE sql AS 'SELECT a';
CREATE INDEX ix_trip_note ON booking.trip (note);
COMMENT ON COLUMN booking.trip.note IS 'pii:free_text';""")
        code, found, log, registered = self.run_file(sql)
        self.assertEqual((code, found), (0, []), log)
        self.assertTrue(registered)

    def test_non_unique_cic_file(self):
        sql = ("-- Migration bk-099\n-- migrate: no-transaction\n-- migrate: expand\n"
               "CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_trip_note ON booking.trip (note);\n" + reg("bk-099"))
        code, found, log, registered = self.run_file(sql)
        self.assertEqual((code, found), (0, []), log)
        self.assertTrue(registered)
        bad = sql.replace("CREATE INDEX CONCURRENTLY", "CREATE UNIQUE INDEX CONCURRENTLY").replace("ix_trip_note",
                                                                                                    "ux_trip_note")
        asyncio.run(_fresh())
        code, found, log, registered = self.run_file(bad)
        self.assertEqual(code, 14, log)
        self.assertFalse(registered)
        self.assertTrue(any("unique / primary / exclusion index" in f for f in found), found)

    # ── rehearsal (check mode, classify) ──
    def test_rehearsal_rolls_back_a_clean_file(self):
        sql = tx("CREATE TABLE booking.aa993_r (id int);")
        code, found, log, registered = self.run_file(sql, rehearse=True)
        self.assertEqual((code, found, registered), (0, [], False), log)
        self.assertIn("expand rehearsal: post-check ok", log)

        async def exists():
            conn = await asyncpg.connect(_dsn(DB))
            try:
                return await conn.fetchval("SELECT to_regclass('booking.aa993_r') IS NOT NULL")
            finally:
                await conn.close()
        self.assertFalse(asyncio.run(exists()))

    def test_rehearsal_reports_the_contract_variant(self):
        code, found, log, registered = self.run_file(tx("INSERT INTO booking.config VALUES ('y', '2');"),
                                                     rehearse=True)
        self.assertEqual(code, 14, log)
        self.assertIn("Rehearsal rolled back", log)

    # ── why ADD COLUMN on a hot table is contract (critic 6) ──
    def test_returning_star_in_a_transaction_fails_after_add_column(self):
        async def main():
            app = await asyncpg.connect(_dsn(DB))
            ddl = await asyncpg.connect(_dsn(DB))
            try:
                stmt = "INSERT INTO shared.job (id, kind, status) VALUES ($1, 'k', 'queued') RETURNING *"
                await app.fetch(stmt, 1)                        # prepared and cached by asyncpg
                await ddl.execute("ALTER TABLE shared.job ADD COLUMN lane text")
                async with app.transaction():
                    await app.fetch(stmt, 2)
            finally:
                await app.close()
                await ddl.close()
        with self.assertRaises(asyncpg.exceptions.InvalidCachedStatementError):
            asyncio.run(main())


BASE = """-- Migration bk-001: classify test base (no header: contract).
BEGIN;
CREATE SCHEMA IF NOT EXISTS shared;
CREATE TABLE IF NOT EXISTS shared.schema_versions (version text PRIMARY KEY, applied_at timestamptz NOT NULL
  DEFAULT now(), description text);
CREATE SCHEMA booking;
CREATE TABLE booking.trip (id bigint PRIMARY KEY, note text);
INSERT INTO booking.trip VALUES (1, 'a');
""" + reg("bk-001") + "COMMIT;\n"


@unittest.skipUnless(DSN and asyncpg is not None, "set AA993_TEST_PG_DSN (throw-away server) and install asyncpg")
class ClassifyPgTest(unittest.TestCase):
    """db/expand_check.py --classify end to end, number-order fallback (no dump artifact), on synthetic sources that
    need no role bootstrap (the master owns everything, so no role switch)."""

    def test_classify_labels_from_evidence_and_exits_14(self):
        import tempfile
        import expand_check
        import replay_migrations as rp
        files = {"001_base.sql": BASE,
                 "002_probe.sql": tx("CREATE TABLE booking.aa993_probe (id bigint PRIMARY KEY, trip_id bigint "
                                     "REFERENCES booking.trip (id));\n"
                                     "ALTER TABLE booking.trip ADD COLUMN aa993_note text;", version="bk-002"),
                 "003_contract.sql": tx("CREATE POLICY open_all ON booking.trip USING (true);", version="bk-003"),
                 "004_plain.sql": tx("ALTER TABLE booking.trip ADD COLUMN plain_note text;", version="bk-004")
                 .replace("-- migrate: expand\n", "")}
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "booking"
            src.mkdir()
            (Path(tmp) / "roles").mkdir()
            for name, sql in files.items():
                (src / name).write_text(sql, encoding="utf-8")
            out_file = Path(tmp) / "out.json"
            argv = ["--classify", "--admin-dsn", DSN, "--source", f"booking={src}", "--source", f"roles={tmp}/roles",
                    "--files", "booking/002_probe.sql", "booking/003_contract.sql", "booking/004_plain.sql",
                    "--out", str(out_file), "--decisions", str(Path(tmp) / "none.json")]
            check = rp.check_server_version
            # The replay refuses a server that is not PostgreSQL 15 (role rules differ); these sources create no role.
            rp.check_server_version = lambda version_num, major=rp.REPLAY_MAJOR: None
            try:
                with contextlib.redirect_stdout(io.StringIO()) as log:
                    code = expand_check.main(argv)
            finally:
                rp.check_server_version = check
            out = json.loads(out_file.read_text(encoding="utf-8"))
        by = {e["file"]: e for e in out["files"]}
        self.assertEqual(out["order"], "number")
        self.assertEqual(code, 14, log.getvalue())
        self.assertEqual(by["booking/002_probe.sql"]["class"], "expand", by["booking/002_probe.sql"])
        self.assertEqual(by["booking/003_contract.sql"]["class"], "contract")
        self.assertTrue(any("new policy on existing table booking.trip" in f
                            for f in by["booking/003_contract.sql"]["findings"]))
        self.assertEqual(by["booking/004_plain.sql"]["class"], "contract")       # no header: contract by definition
        self.assertTrue(by["booking/004_plain.sql"]["eligible"])                  # … but the evidence allows expand
        self.assertIn("CLASSIFY expand   booking/002_probe.sql", log.getvalue())


if __name__ == "__main__":
    unittest.main()
