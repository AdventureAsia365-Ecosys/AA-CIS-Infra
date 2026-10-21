"""AA-680: db/scripts/aa680_staff_users_readonly_check.py (read-only evidence that Booking holds no staff row for
the refused E2E WORKFORCE user, plus the booking.staff_users link state).

No database, no asyncpg: a fake connection answers the script's SQL.
Run: python3 -m unittest discover -s db/tests -v
"""
import asyncio
import contextlib
import importlib.util
import io
import json
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import run_migration as rm  # noqa: E402

ROOT = HERE.parent.parent
PATH = "db/scripts/aa680_staff_users_readonly_check.py"
_spec = importlib.util.spec_from_file_location("aa680_staff_users_readonly_check", ROOT / PATH)
script = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(script)

SUB = "11111111-aaaa-bbbb-cccc-000000000000"


def staff_row(cis_user_id="00000000-0000-4000-8000-000000000001", *, linked=True, active=True, in_cis=True):
    cog = cis_user_id.startswith("cog:")
    return {
        "cis_user_id": cis_user_id, "role": "admin", "active": active, "linked": linked,
        "cognito_sub": (cis_user_id[4:] if cog else SUB) if linked else None, "last_seen": "2026-10-19",
        "in_cis": in_cis and not cog, "cis_username": "nghieppham" if in_cis and not cog else None,
        "cis_active": True if in_cis and not cog else None,
    }


class FakeConn:
    def __init__(self, e2e, rows, email_only=0):
        self.e2e, self.rows, self.email_only = e2e, rows, email_only
        self.calls = []

    async def fetchrow(self, sql, *args):
        self.calls.append(("fetchrow", args))
        return self.e2e

    async def fetchval(self, sql, *args):
        self.calls.append(("fetchval", args))
        return self.email_only

    async def fetch(self, sql, *args):
        self.calls.append(("fetch", args))
        return self.rows

    async def execute(self, sql, *args):  # pragma: no cover - the script must never call it
        raise AssertionError("read-only script executed a statement")


def run(conn):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = asyncio.run(script.main(conn))
    return rc, out.getvalue().splitlines()


def payload(lines, prefix):
    return [json.loads(x[len(prefix):]) for x in lines if x.startswith(prefix)]


E2E_OK = {"id": "00000000-0000-4000-8000-0000000000e2", "cis_role": "reviewer", "is_active": True,
          "cognito_linked": True, "booking_rows": 0}


class ShapeTest(unittest.TestCase):
    def test_runner_accepts_the_file_and_it_is_read_only(self):
        source = (ROOT / PATH).read_text()
        self.assertEqual(rm.script_errors(source, PATH), [])
        self.assertTrue(rm.script_is_read_only(source))


class RunTest(unittest.TestCase):
    def test_no_booking_row_for_the_e2e_user_passes_and_lists_rows(self):
        rows = [staff_row(), staff_row("00000000-0000-4000-8000-000000000002", linked=False),
                staff_row("cog:" + SUB)]
        conn = FakeConn(E2E_OK, rows)
        rc, lines = run(conn)
        self.assertEqual(rc, 0)
        self.assertEqual(conn.calls[0], ("fetchrow", (script.E2E_EMAIL,)))
        [e2e] = payload(lines, "SCRIPT e2e ")
        self.assertEqual(e2e["booking_rows"], 0)
        self.assertEqual(e2e["cis_role"], "reviewer")
        printed = payload(lines, "SCRIPT row ")
        self.assertEqual([x["kind"] for x in printed], ["cis", "cis", "cog"])
        self.assertEqual(printed[2]["id"], "cog:11111111")
        self.assertEqual(printed[0]["sub8"], "11111111")
        self.assertIsNone(printed[1]["sub8"])
        [c] = payload(lines, "SCRIPT counts ")
        self.assertEqual(c, {"total": 3, "cog_rows": 1, "cis_rows": 2, "linked": 2, "unlinked": 1,
                             "unlinked_active": 1})
        self.assertIn("SCRIPT verdict e2e_has_no_booking_row=true", lines)
        self.assertIn("SCRIPT verdict active_unlinked=1", lines)

    def test_active_unlinked_verdict_counts_only_active_rows_without_identity(self):
        rows = [staff_row(), staff_row("00000000-0000-4000-8000-000000000002", linked=False, active=False),
                staff_row("cog:" + SUB)]
        rc, lines = run(FakeConn(E2E_OK, rows))
        self.assertEqual(rc, 0)
        self.assertIn("SCRIPT verdict active_unlinked=0", lines)

    def test_a_booking_row_for_the_e2e_user_fails_the_run(self):
        rc, lines = run(FakeConn({**E2E_OK, "booking_rows": 1}, []))
        self.assertEqual(rc, 1)
        self.assertIn("SCRIPT verdict e2e_has_no_booking_row=false", lines)

    def test_missing_e2e_user_falls_back_to_the_email_match(self):
        conn = FakeConn(None, [], email_only=0)
        rc, lines = run(conn)
        self.assertEqual(rc, 0)
        self.assertIn(("fetchval", (script.E2E_EMAIL,)), conn.calls)
        [e2e] = payload(lines, "SCRIPT e2e ")
        self.assertEqual(e2e, {"in_cis": False, "booking_rows": 0})

    def test_prints_no_email_and_no_full_sub(self):
        _, lines = run(FakeConn(E2E_OK, [staff_row(), staff_row("cog:" + SUB)]))
        text = "\n".join(lines)
        self.assertNotIn("@", text)
        self.assertNotIn(SUB, text)


if __name__ == "__main__":
    unittest.main()
