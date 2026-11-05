"""AA-969 part 2 (root ADR 0019 d16): the run-script PII guard of db/run_migration.py against a real PostgreSQL planner.

Skipped unless AA969_TEST_PG_DSN names a throw-away server's superuser DSN (and asyncpg is importable): the CI job of
db/tests has neither, so this file runs locally (and the pure plan reading is covered in CI by test_aa969_pii_guard.py,
whose canned plans are the JSON this planner prints). It creates the database `aa969_pii_guard_test` (dropped first)
with invented tenant tables whose personal-data columns carry DM-6.1 `pii:` comments, a partitioned table, a shared
table with and without tenant_id, then runs statements through PiiGuardedConnection in a read-only session.

  AA969_TEST_PG_DSN=postgresql://postgres@127.0.0.1:55469/postgres python3 -m unittest db.tests.test_aa969_pii_guard_pg
"""
import asyncio
import os
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import run_migration as rm  # noqa: E402

DSN = os.environ.get("AA969_TEST_PG_DSN", "")
try:
    import asyncpg
except ImportError:  # CI image of db/tests: standard library + pyyaml only
    asyncpg = None

DB = "aa969_pii_guard_test"
SCHEMA = """
CREATE SCHEMA crm; CREATE SCHEMA booking; CREATE SCHEMA shared;
CREATE TABLE crm.traveler (traveler_id uuid PRIMARY KEY, tenant_id uuid NOT NULL, email text, display_name text,
                           status text NOT NULL DEFAULT 'active');
COMMENT ON COLUMN crm.traveler.email IS 'pii:contact';
COMMENT ON COLUMN crm.traveler.display_name IS 'pii:name';
CREATE TABLE crm.trip (trip_id uuid PRIMARY KEY, tenant_id uuid NOT NULL, traveler_id uuid, notes text);
COMMENT ON COLUMN crm.trip.notes IS 'pii:free_text';
CREATE TABLE crm.audit_event (tenant_id uuid NOT NULL, at timestamptz NOT NULL, detail text) PARTITION BY RANGE (at);
COMMENT ON COLUMN crm.audit_event.detail IS 'pii:free_text';
CREATE TABLE crm.audit_event_2026_11 PARTITION OF crm.audit_event
    FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');
CREATE TABLE booking.customers (id uuid PRIMARY KEY, email text, created_at timestamptz NOT NULL DEFAULT now());
COMMENT ON COLUMN booking.customers.email IS 'pii:contact';
CREATE TABLE shared.tenants (tenant_id uuid PRIMARY KEY, name text, billing_email text, is_pilot boolean);
COMMENT ON COLUMN shared.tenants.billing_email IS 'pii:contact';
CREATE TABLE shared.admin_users (id uuid PRIMARY KEY, email text);
COMMENT ON COLUMN shared.admin_users.email IS 'pii:contact';
CREATE VIEW booking.v_customer_mail AS SELECT id, email FROM booking.customers;
INSERT INTO crm.traveler VALUES ('00000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-0000000000a1',
                                 'invented@example.test', 'Invented Person', 'active');
INSERT INTO crm.audit_event VALUES ('00000000-0000-4000-8000-0000000000a1', '2026-11-05', 'invented detail');
"""

REFUSED = [
    "SELECT email FROM crm.traveler",
    "SELECT t.email, t.status FROM crm.traveler t",
    "SELECT * FROM crm.traveler",
    "SELECT row_to_json(t) FROM crm.traveler t",
    "SELECT lower(email) AS e FROM crm.traveler",
    "SELECT min(display_name) FROM crm.traveler",
    "SELECT string_agg(email, ',') FROM crm.traveler",
    "SELECT tr.trip_id, t.email FROM crm.trip tr JOIN crm.traveler t USING (traveler_id)",
    "WITH c AS MATERIALIZED (SELECT email FROM crm.traveler) SELECT * FROM c",
    "SELECT s.e FROM (SELECT email AS e FROM crm.traveler OFFSET 0) s",
    "SELECT (SELECT email FROM crm.traveler LIMIT 1) AS x",
    "SELECT detail FROM crm.audit_event",                       # a partition's rows
    "SELECT email FROM booking.v_customer_mail",                # through a view
    "SELECT billing_email FROM shared.tenants",                 # a shared table with tenant_id
    "SELECT email FROM crm.traveler WHERE traveler_id = $1",
]
ALLOWED = [
    "SELECT count(*) AS n FROM crm.traveler",
    "SELECT count(DISTINCT email) AS n FROM crm.traveler",
    "SELECT count(*) FILTER (WHERE email IS NOT NULL) AS n FROM crm.traveler",
    "SELECT (email IS NULL) AS missing, count(*) AS n FROM crm.traveler GROUP BY 1",
    "SELECT status, count(*) AS n FROM crm.traveler WHERE email LIKE '%@example.test' GROUP BY status",
    "SELECT traveler_id FROM crm.traveler WHERE display_name = 'x'",
    "SELECT tenant_id, count(*) AS n FROM crm.trip GROUP BY tenant_id",
    "SELECT email FROM shared.admin_users",                     # staff table: no tenant_id
    "SELECT name, is_pilot FROM shared.tenants",
    "SELECT 1 AS ok",
    "SHOW server_version",
]


@unittest.skipUnless(DSN and asyncpg is not None, "set AA969_TEST_PG_DSN (and install asyncpg) to run")
class PiiGuardPgTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        async def setup():
            admin = await asyncpg.connect(DSN)
            try:
                await admin.execute(f"DROP DATABASE IF EXISTS {DB}")
                await admin.execute(f"CREATE DATABASE {DB}")
            finally:
                await admin.close()
            conn = await asyncpg.connect(cls.dsn())
            try:
                await conn.execute(SCHEMA)
            finally:
                await conn.close()
        asyncio.run(setup())

    @classmethod
    def dsn(cls):
        base, _, _ = DSN.rpartition("/")
        return f"{base}/{DB}"

    def run_in_guard(self, body):
        async def go():
            conn = await asyncpg.connect(self.dsn(), server_settings={"default_transaction_read_only": "on"})
            try:
                protected = await rm.load_pii_columns(conn)
                return await body(rm.PiiGuardedConnection(conn, protected), protected)
            finally:
                await conn.close()
        return asyncio.run(go())

    def test_the_catalogue_names_tenant_pii_columns_and_partitions(self):
        async def body(_g, protected):
            return protected
        protected = self.run_in_guard(body)
        self.assertEqual(protected[("crm", "traveler")], {"email", "display_name"})
        self.assertEqual(protected[("crm", "audit_event_2026_11")], {"detail"})
        self.assertEqual(protected[("shared", "tenants")], {"billing_email"})
        self.assertNotIn(("shared", "admin_users"), protected)

    def test_reads_of_personal_data_are_refused(self):
        for query in REFUSED:
            with self.subTest(query=query):
                async def body(g, _p, q=query):
                    args = ("00000000-0000-4000-8000-000000000001",) if "$1" in q else ()
                    with self.assertRaises(rm.PiiReadRefused):
                        await g.fetch(q, *args)
                self.run_in_guard(body)

    def test_counts_and_filters_are_allowed(self):
        for query in ALLOWED:
            with self.subTest(query=query):
                async def body(g, _p, q=query):
                    return await g.fetch(q)
                self.run_in_guard(body)

    def test_every_row_returning_call_is_guarded(self):
        async def body(g, _p):
            for call in (lambda: g.fetchrow("SELECT email FROM crm.traveler"),
                         lambda: g.fetchval("SELECT email FROM crm.traveler"),
                         lambda: g.prepare("SELECT email FROM crm.traveler"),
                         lambda: g.copy_from_table("traveler", schema_name="crm", output=lambda b: None),
                         lambda: g.fetchmany("SELECT email FROM crm.traveler WHERE traveler_id = $1",
                                             [("00000000-0000-4000-8000-000000000001",)])):
                with self.assertRaises(rm.PiiReadRefused):
                    await call()
            async with g.transaction():
                with self.assertRaises(rm.PiiReadRefused):
                    async for _row in g.cursor("SELECT email FROM crm.traveler"):
                        pass
                # the refused EXPLAIN aborted nothing: the transaction goes on
                self.assertEqual(await g.fetchval("SELECT count(*) AS n FROM crm.traveler"), 1)
            with self.assertRaises(rm.PiiReadRefused):
                g.add_log_listener(lambda *a: None)
            self.assertEqual(await g.fetchval("SELECT count(*) FROM crm.audit_event"), 1)
        self.run_in_guard(body)

    def test_a_statement_the_planner_cannot_explain_is_refused(self):
        async def body(g, _p):
            with self.assertRaises(rm.PiiReadRefused):
                await g.fetch("SELECT * FROM crm.no_such_table")
        self.run_in_guard(body)


if __name__ == "__main__":
    unittest.main()
