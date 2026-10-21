"""AA-816 (root ADR 0006a A10): db/scripts/aa816_delete_e2e_test_staff.py (delete the old E2E test staff row).

No database, no asyncpg: a fake connection answers the script's SQL and records what it ran.
Run: python3 -m unittest discover -s db/tests -v
"""
import asyncio
import contextlib
import importlib.util
import io
import json
import sys
import unittest
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import run_migration as rm  # noqa: E402

ROOT = HERE.parent.parent
PATH = "db/scripts/aa816_delete_e2e_test_staff.py"
_spec = importlib.util.spec_from_file_location("aa816_delete_e2e_test_staff", ROOT / PATH)
script = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(script)

ROW_ID = uuid.UUID("00000000-0000-4000-8000-0000000000e2")
AUDIT_ID = uuid.UUID("00000000-0000-4000-8000-00000000a0d2")
USERNAME = "e2e-secret-username"


def row(**over):
    base = {"id": ROW_ID, "is_active": False, "role": "reviewer", "is_owner": False, "no_password": True,
            "linked": True, "username": USERNAME, "created_at": "2026-10-19 08:00:00+00", "grants": 0}
    base.update(over)
    return base


def fk(name, tbl, on_delete="a", rls_may_hide=False, ncols=1, ref_col="id", col="admin_user_id"):
    return {"name": name, "tbl": tbl, "on_delete": on_delete, "ncols": ncols, "ref_col": ref_col,
            "count_sql": f"SELECT count(*) FROM {tbl} WHERE {col} = $1", "rls_may_hide": rls_may_hide}


LIVE_FKS = [
    fk("staff_app_grant_admin_user_id_fkey", "shared.staff_app_grant", on_delete="c"),
    fk("tenant_api_usage_admin_user_id_fkey", "shared.tenant_api_usage"),
    fk("generated_content_reviewed_by_fkey", "silver_aa_internal.generated_content", rls_may_hide=True,
       col="reviewed_by"),
    fk("raw_tours_reviewed_by_fkey", "silver_aa_internal.raw_tours", rls_may_hide=True, col="reviewed_by"),
]


class FakeConn:
    def __init__(self, rows, fks=None, ref_counts=None, delete_status="DELETE 1", remaining=0, audit_rows=3,
                 audit_id=AUDIT_ID):
        self.rows, self.fks = rows, LIVE_FKS if fks is None else fks
        self.ref_counts = ref_counts or {}
        self.delete_status, self.remaining, self.audit_rows, self.audit_id = delete_status, remaining, audit_rows, \
            audit_id
        self.executed, self.fetched, self.fetchvals = [], [], []
        self.transactions, self.rolled_back = 0, 0

    async def fetch(self, sql, *args):
        flat = " ".join(sql.split())
        self.fetched.append((flat, args))
        if "pg_catalog.pg_constraint" in flat:
            return self.fks
        return self.rows

    async def execute(self, sql, *args):
        flat = " ".join(sql.split())
        self.executed.append((flat, args))
        return self.delete_status if flat.startswith("DELETE") else "SET"

    async def fetchval(self, sql, *args):
        flat = " ".join(sql.split())
        self.fetchvals.append((flat, args))
        if flat.startswith("INSERT INTO acp_shared.audit_log"):
            return self.audit_id
        if "FROM acp_shared.audit_log" in flat:
            return self.audit_rows
        if flat.startswith("SELECT count(*) FROM shared.admin_users"):
            return self.remaining
        table = flat.split(" FROM ")[1].split(" WHERE ")[0]
        return self.ref_counts.get(table, 0)

    @contextlib.asynccontextmanager
    async def transaction(self):
        self.transactions += 1
        try:
            yield
        except BaseException:
            self.rolled_back += 1
            raise


def run(coro):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = asyncio.run(coro)
    return rc, out.getvalue()


def report(output):
    line = next(line for line in output.splitlines() if line.startswith("SCRIPT report "))
    return json.loads(line[len("SCRIPT report "):])


def audits(conn):
    return [args for sql, args in conn.fetchvals if sql.startswith("INSERT INTO acp_shared.audit_log")]


def deletes(conn):
    return [args for sql, args in conn.executed if sql.startswith("DELETE FROM shared.admin_users")]


class ShapeTest(unittest.TestCase):
    def test_runner_accepts_the_file_and_it_is_merged_as_dry_run(self):
        source = (ROOT / PATH).read_text()
        self.assertEqual(rm.script_errors(source, PATH), [])
        self.assertTrue(rm.script_is_read_only(source))
        self.assertIs(script.READ_ONLY, True)

    def test_constants(self):
        # The address of AA-CIS-App api/migrations/250_admin_users_e2e_test_email.sql; the staff directory's names.
        self.assertEqual(script.OLD_E2E_EMAIL, "e2e@e2e-mail.lumiguides.it.com")
        self.assertEqual(script.AUDIT_ACTION, "staff.deleted")
        self.assertEqual(script.RESOURCE_TYPE, "admin_user")
        self.assertLessEqual(len(script.ACTOR), 64)          # acp_shared.audit_log.actor varchar(64)
        self.assertLessEqual(len(script.AUDIT_ACTION), 64)   # acp_shared.audit_log.action varchar(64)

    def test_the_delete_repeats_the_guards(self):
        sql = " ".join(script.DELETE_SQL.split())
        for part in ("id = $1", "lower(btrim(email)) = $2", "NOT is_active", "NOT is_owner", "password_hash IS NULL"):
            self.assertIn(part, sql)

    def test_references_are_read_from_the_catalog(self):
        sql = " ".join(script.FKS_SQL.split())
        self.assertIn("con.contype = 'f' AND con.confrelid = 'shared.admin_users'::regclass", sql)
        self.assertIn("format('SELECT count(*) FROM %s WHERE %I = $1'", sql)


class DryRunTest(unittest.TestCase):
    def test_dry_run_reports_and_writes_nothing(self):
        conn = FakeConn([row()])
        rc, out = run(script.main(conn))   # READ_ONLY = True as merged
        self.assertEqual(rc, 0)
        self.assertIn("mode=DRY_RUN", out)
        self.assertEqual(conn.transactions, 0)
        self.assertEqual(conn.executed, [])
        self.assertEqual(audits(conn), [])
        self.assertNotIn("FOR UPDATE", conn.fetched[0][0])
        self.assertEqual(conn.fetched[0][1], ("e2e@e2e-mail.lumiguides.it.com",))
        data = report(out)
        self.assertEqual((data["outcome"], data["candidates"], data["row_id"], data["deleted"], data["audit_rows_kept"]),
                         ("would_delete", 1, str(ROW_ID), 0, 3))
        self.assertEqual([r["rows"] for r in data["references"]], [0, 0, 0, 0])
        # Each FK was counted with the row id.
        counted = [args for sql, args in conn.fetchvals if sql.startswith("SELECT count(*) FROM ")
                   and "admin_users" not in sql and "audit_log" not in sql]
        self.assertEqual(counted, [(ROW_ID,)] * 4)

    def test_dry_run_refuses_like_apply(self):
        conn = FakeConn([row(is_active=True)])
        rc, out = run(script.run(conn, apply=False))
        self.assertEqual(rc, 1)
        self.assertIn("SCRIPT REFUSED the row is still active", out)
        self.assertEqual(report(out)["outcome"], "refused")


class ApplyTest(unittest.TestCase):
    def test_deletes_one_row_and_writes_the_audit_row_last_in_one_transaction(self):
        conn = FakeConn([row()])
        rc, out = run(script.run(conn, apply=True))
        self.assertEqual(rc, 0)
        self.assertEqual((conn.transactions, conn.rolled_back), (1, 0))
        self.assertEqual(conn.executed[0][0], "SET LOCAL lock_timeout = '5s'")
        self.assertTrue(conn.fetched[0][0].endswith("FOR UPDATE OF a"))
        self.assertEqual(deletes(conn), [(ROW_ID, "e2e@e2e-mail.lumiguides.it.com")])
        self.assertTrue(conn.fetchvals[-1][0].startswith("INSERT INTO acp_shared.audit_log"))  # chain trigger lock
        actor, action, resource_type, resource_id, details = audits(conn)[0]
        self.assertEqual((actor, action, resource_type, resource_id),
                         ("script:aa816_delete_e2e_test_staff", "staff.deleted", "admin_user", str(ROW_ID)))
        restore = json.loads(details)["restore"]
        self.assertEqual((restore["username"], restore["role"], restore["created_at"]),
                         (USERNAME, "reviewer", "2026-10-19 08:00:00+00"))
        data = report(out)
        self.assertEqual((data["outcome"], data["deleted"], data["remaining_rows"], data["audit_row_id"]),
                         ("deleted", 1, 0, str(AUDIT_ID)))
        self.assertIn("SCRIPT committed outcome=deleted deleted=1", out)

    def test_refuses_unless_exactly_the_disabled_test_row(self):
        cases = {
            "none": [],
            "two rows": [row(), row(id=uuid.UUID("00000000-0000-4000-8000-000000000002"))],
            "active": [row(is_active=True)],
            "admin": [row(role="admin")],
            "content": [row(role="content")],
            "owner": [row(is_owner=True)],
            "password": [row(no_password=False)],
            "booking grant": [row(grants=1)],
        }
        for name, rows in cases.items():
            with self.subTest(name):
                conn = FakeConn(rows)
                rc, out = run(script.run(conn, apply=True))
                self.assertEqual(rc, 1)
                self.assertIn("SCRIPT REFUSED", out)
                self.assertEqual(deletes(conn), [])
                self.assertEqual(audits(conn), [])
                self.assertEqual(conn.rolled_back, 1)

    def test_refuses_while_any_row_references_it(self):
        for table in ("shared.staff_app_grant", "shared.tenant_api_usage", "silver_aa_internal.raw_tours"):
            with self.subTest(table):
                conn = FakeConn([row()], ref_counts={table: 2})
                rc, out = run(script.run(conn, apply=True))
                self.assertEqual(rc, 1)
                self.assertIn(f"{table}=2", out)
                self.assertEqual((deletes(conn), audits(conn), conn.rolled_back), ([], [], 1))

    def test_refuses_a_key_it_cannot_count_reliably(self):
        cases = {
            "cascade under row security": [fk("x_fkey", "s.hidden", on_delete="c", rls_may_hide=True)],
            "set null under row security": [fk("x_fkey", "s.hidden", on_delete="n", rls_may_hide=True)],
            "two columns": [fk("x_fkey", "s.t", ncols=2)],
            "not onto id": [fk("x_fkey", "s.t", ref_col="username")],
        }
        for name, fks in cases.items():
            with self.subTest(name):
                conn = FakeConn([row()], fks=fks)
                rc, out = run(script.run(conn, apply=True))
                self.assertEqual(rc, 1)
                self.assertIn("foreign key x_fkey", out)
                self.assertEqual((deletes(conn), audits(conn)), ([], []))

    def test_a_new_key_is_picked_up_from_the_catalog(self):
        conn = FakeConn([row()], fks=LIVE_FKS + [fk("new_fkey", "shared.new_table", col="staff_id")],
                        ref_counts={"shared.new_table": 1})
        rc, out = run(script.run(conn, apply=True))
        self.assertEqual(rc, 1)
        self.assertIn("shared.new_table=1", out)

    def test_not_exactly_one_deleted_row_rolls_back_without_an_audit_row(self):
        for status in ("DELETE 0", "DELETE 2"):
            with self.subTest(status):
                conn = FakeConn([row()], delete_status=status)
                with self.assertRaises(RuntimeError):
                    run(script.run(conn, apply=True))
                self.assertEqual((conn.rolled_back, audits(conn)), (1, []))

    def test_a_remaining_row_rolls_back(self):
        conn = FakeConn([row()], remaining=1)
        with self.assertRaises(RuntimeError):
            run(script.run(conn, apply=True))
        self.assertEqual((conn.rolled_back, audits(conn)), (1, []))

    def test_never_prints_an_email_or_the_username(self):
        for apply in (False, True):
            with self.subTest(apply=apply):
                _, out = run(script.run(FakeConn([row()]), apply=apply))
                self.assertNotIn("@", out)
                self.assertNotIn(USERNAME, out)


if __name__ == "__main__":
    unittest.main()
