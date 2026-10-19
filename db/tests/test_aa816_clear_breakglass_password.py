"""AA-816 B6 (N-B): db/scripts/aa816_clear_breakglass_password.py (clear the break-glass row's legacy hash).

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
PATH = "db/scripts/aa816_clear_breakglass_password.py"
_spec = importlib.util.spec_from_file_location("aa816_clear_breakglass_password", ROOT / PATH)
script = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(script)

ROW_ID = uuid.UUID("00000000-0000-4000-8000-0000000000ad")
AUDIT_ID = uuid.UUID("00000000-0000-4000-8000-00000000a0d1")
FAKE_HASH = "$2b$12$not-a-real-hash-only-for-the-test"


def row(*, username="admin", email="admin@adventure.asia", has_hash=True, row_id=ROW_ID):
    return {"id": row_id, "username_norm": username, "email_norm": email, "has_hash": has_hash,
            "is_active": True, "role_is_admin": True, "is_owner": False, "linked": True}


class FakeConn:
    def __init__(self, rows, update_status="UPDATE 1", has_hash_after=False, audit_id=AUDIT_ID):
        self.rows, self.update_status = rows, update_status
        self.has_hash_after, self.audit_id = has_hash_after, audit_id
        self.executed, self.fetched, self.fetchvals = [], [], []
        self.transactions, self.rolled_back = 0, 0

    async def fetch(self, sql, *args):
        self.fetched.append((sql, args))
        return self.rows

    async def execute(self, sql, *args):
        self.executed.append((" ".join(sql.split()), args))
        return self.update_status if sql.lstrip().startswith("UPDATE") else "SET"

    async def fetchval(self, sql, *args):
        flat = " ".join(sql.split())
        self.fetchvals.append((flat, args))
        if flat.startswith("INSERT INTO acp_shared.audit_log"):
            return self.audit_id
        return self.has_hash_after

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


def updates(conn):
    return [args for sql, args in conn.executed if sql.startswith("UPDATE shared.admin_users")]


class ShapeTest(unittest.TestCase):
    def test_runner_accepts_the_file_and_it_applies_as_merged(self):
        source = (ROOT / PATH).read_text()
        self.assertEqual(rm.script_errors(source, PATH), [])
        self.assertFalse(rm.script_is_read_only(source))
        self.assertIs(script.READ_ONLY, False)

    def test_constants_match_the_cis_staff_directory(self):
        # AA-CIS-App api/services/staff_directory.py BREAKGLASS_USERNAMES / BREAKGLASS_EMAILS
        self.assertEqual(script.BREAKGLASS_USERNAME, "admin")
        self.assertEqual(set(script.BREAKGLASS_EMAILS), {"admin@adventure.asia", "breakglass@adventure.asia"})
        self.assertTrue(script.AUDIT_ACTION.startswith("staff."))
        self.assertLessEqual(len(script.ACTOR), 64)          # acp_shared.audit_log.actor varchar(64)
        self.assertLessEqual(len(script.AUDIT_ACTION), 64)   # acp_shared.audit_log.action varchar(64)
        self.assertLessEqual(len(script.RESOURCE_TYPE), 32)  # acp_shared.audit_log.resource_type varchar(32)


class ApplyTest(unittest.TestCase):
    def test_clears_the_hash_and_writes_one_audit_row_in_one_transaction(self):
        conn = FakeConn([row()])
        rc, out = run(script.main(conn))
        self.assertEqual(rc, 0)
        self.assertEqual(conn.transactions, 1)
        self.assertEqual(conn.rolled_back, 0)
        sql, args = conn.fetched[0]
        self.assertTrue(sql.rstrip().endswith("FOR UPDATE"))
        self.assertEqual(args, ("admin", ["admin@adventure.asia", "breakglass@adventure.asia"]))
        self.assertEqual(conn.executed[0][0], "SET LOCAL lock_timeout = '5s'")
        self.assertEqual(updates(conn), [(ROW_ID,)])
        self.assertEqual(len(audits(conn)), 1)
        actor, action, resource_type, resource_id, details = audits(conn)[0]
        self.assertEqual((actor, action, resource_type, resource_id),
                         ("script:aa816_clear_breakglass_password", "staff.legacy_password_cleared", "admin_user",
                          str(ROW_ID)))
        self.assertEqual(json.loads(details)["has_password"], {"before": True, "after": False})
        # the audit INSERT is the last statement of the transaction (audit chain trigger lock, QRY-4)
        self.assertTrue(conn.fetchvals[-1][0].startswith("INSERT INTO acp_shared.audit_log"))
        data = report(out)
        self.assertEqual(data, {
            "candidates": 1, "row_found": True, "outcome": "cleared", "had_hash_before": True,
            "has_hash_after": False, "is_active": True, "role_is_admin": True, "is_owner": False, "linked": True,
            "audit_row_id": str(AUDIT_ID),
        })
        self.assertIn("SCRIPT committed outcome=cleared", out)

    def test_second_run_reports_already_null_and_writes_nothing(self):
        conn = FakeConn([row(has_hash=False)])
        rc, out = run(script.main(conn))
        self.assertEqual(rc, 0)
        self.assertEqual(updates(conn), [])
        self.assertEqual(audits(conn), [])
        data = report(out)
        self.assertEqual((data["outcome"], data["had_hash_before"], data["has_hash_after"], data["audit_row_id"]),
                         ("already_null", False, False, None))

    def test_refuses_unless_exactly_the_break_glass_row(self):
        cases = {
            "none": [],
            "two rows": [row(), row(username="nghiep", email="breakglass@adventure.asia",
                                    row_id=uuid.UUID("00000000-0000-4000-8000-000000000002"))],
            "email only": [row(username="someone-else")],
            "username only": [row(email=None)],
            "username, other email": [row(email="nghieppham@adventure.asia")],
        }
        for name, rows in cases.items():
            with self.subTest(name):
                conn = FakeConn(rows)
                rc, out = run(script.main(conn))
                self.assertEqual(rc, 1)
                self.assertIn("SCRIPT REFUSED", out)
                self.assertEqual(updates(conn), [])
                self.assertEqual(audits(conn), [])
                self.assertEqual(conn.rolled_back, 1)
                self.assertEqual(report(out)["outcome"], "refused")

    def test_a_row_changed_since_the_lock_rolls_back_without_an_audit_row(self):
        conn = FakeConn([row()], update_status="UPDATE 0")
        with self.assertRaises(RuntimeError):
            run(script.main(conn))
        self.assertEqual(conn.rolled_back, 1)
        self.assertEqual(audits(conn), [])

    def test_hash_still_set_after_update_rolls_back(self):
        conn = FakeConn([row()], has_hash_after=True)
        with self.assertRaises(RuntimeError):
            run(script.main(conn))
        self.assertEqual(conn.rolled_back, 1)
        self.assertEqual(audits(conn), [])

    def test_never_prints_the_hash_or_an_email(self):
        conn = FakeConn([dict(row(), password_hash=FAKE_HASH)])
        _, out = run(script.main(conn))
        self.assertNotIn(FAKE_HASH, out)
        self.assertNotIn("$2b$", out)
        self.assertNotIn("@adventure.asia", out)


class DryRunTest(unittest.TestCase):
    def test_dry_run_reports_and_writes_nothing(self):
        conn = FakeConn([row()])
        rc, out = run(script.run(conn, apply=False))
        self.assertEqual(rc, 0)
        self.assertEqual(conn.transactions, 0)
        self.assertEqual(conn.executed, [])
        self.assertEqual(conn.fetchvals, [])
        self.assertNotIn("FOR UPDATE", conn.fetched[0][0])
        self.assertIn("mode=DRY_RUN", out)
        data = report(out)
        self.assertEqual((data["outcome"], data["had_hash_before"], data["audit_row_id"]),
                         ("would_clear", True, None))

    def test_dry_run_refuses_like_apply(self):
        conn = FakeConn([row(), row(row_id=uuid.UUID("00000000-0000-4000-8000-000000000002"))])
        rc, out = run(script.run(conn, apply=False))
        self.assertEqual(rc, 1)
        self.assertIn("SCRIPT REFUSED expected exactly 1", out)


if __name__ == "__main__":
    unittest.main()
