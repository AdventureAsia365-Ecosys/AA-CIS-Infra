"""AA-680: db/scripts/aa680_link_staff_cognito.py (one-time link of bridge-era Booking staff rows to Cognito).

No database, no asyncpg: a fake connection answers the script's SQL. The script was also run against a local
PostgreSQL 16 with bk-016 applied (DRY RUN in a default_transaction_read_only session, apply, re-run) during S243.
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
PATH = "db/scripts/aa680_link_staff_cognito.py"
_spec = importlib.util.spec_from_file_location("aa680_link_staff_cognito", ROOT / PATH)
script = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(script)

ISS = "https://cognito-idp.us-west-1.amazonaws.com/us-west-1_bCcFvbSOS"


def row(cis_user_id="00000000-0000-4000-8000-000000000001", *, in_cis=True, sub="11111111-aaaa", linked=None,
        holder=None, has_email=False, has_name=True):
    return {
        "cis_user_id": cis_user_id, "role": "admin", "active": True, "has_email": has_email, "has_name": has_name,
        "linked_iss": linked[0] if linked else None, "linked_sub": linked[1] if linked else None,
        "in_cis": in_cis, "cis_username": "nghieppham" if in_cis else None, "cis_active": True if in_cis else None,
        "cognito_iss": ISS if sub else None, "cognito_sub": sub, "cis_email": "nghieppham@adventure.asia",
        "cis_display_name": "Nghiep Pham", "holder": holder,
    }


class FakeConn:
    def __init__(self, rows, columns=2, update_status="UPDATE 1"):
        self.rows, self.columns, self.update_status = rows, columns, update_status
        self.executed = []
        self.fetched = []
        self.transactions = 0

    async def fetchval(self, sql, *args):
        return self.columns

    async def fetch(self, sql, *args):
        self.fetched.append(sql)
        return self.rows

    async def execute(self, sql, *args):
        self.executed.append((" ".join(sql.split()), args))
        return self.update_status if sql.lstrip().startswith("UPDATE") else "OK"

    @contextlib.asynccontextmanager
    async def transaction(self):
        self.transactions += 1
        yield


def run(coro):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = asyncio.run(coro)
    return rc, out.getvalue()


def counts(output):
    line = next(line for line in output.splitlines() if line.startswith("SCRIPT counts "))
    return json.loads(line[len("SCRIPT counts "):])


class ShapeTest(unittest.TestCase):
    def test_runner_accepts_the_file_and_it_is_a_dry_run_as_merged(self):
        source = (ROOT / PATH).read_text()
        self.assertEqual(rm.script_errors(source, PATH), [])
        self.assertTrue(rm.script_is_read_only(source))
        self.assertIs(script.READ_ONLY, True)


class ClassifyTest(unittest.TestCase):
    def test_outcomes(self):
        self.assertEqual(script.classify(row()), "link")
        self.assertEqual(script.classify(row(linked=(ISS, "11111111-aaaa"))), "already_linked")
        self.assertEqual(script.classify(row(linked=(ISS, "other"))), "conflict_linked_other")
        self.assertEqual(script.classify(row(in_cis=False, sub=None)), "no_cis_user")
        self.assertEqual(script.classify(row(sub=None)), "cis_not_linked")
        self.assertEqual(script.classify(row(holder="cog:11111111-aaaa")), "conflict_cog_row_exists")
        self.assertEqual(script.classify(row(holder="00000000-0000-4000-8000-000000000009")),
                         "conflict_identity_taken")


class RunTest(unittest.TestCase):
    def test_dry_run_writes_nothing_and_prints_the_mapping_without_emails(self):
        conn = FakeConn([row(), row("cathy", in_cis=False, sub=None), row(sub=None)])
        rc, out = run(script.main(conn))
        self.assertEqual(rc, 0)
        self.assertEqual(conn.executed, [])
        self.assertEqual(conn.transactions, 0)
        self.assertNotIn("FOR UPDATE", conn.fetched[0])
        self.assertIn("mode=DRY_RUN", out)
        self.assertEqual(counts(out), {"link": 1, "no_cis_user": 1, "cis_not_linked": 1})
        self.assertNotIn("@adventure.asia", out)
        first = json.loads(out.splitlines()[1][len("SCRIPT row "):])
        self.assertEqual((first["outcome"], first["sub8"], first["fills_email"]), ("link", "11111111", True))

    def test_apply_links_with_an_audit_row_and_skips_the_rest(self):
        conn = FakeConn([row(), row(linked=(ISS, "11111111-aaaa")), row(holder="cog:11111111-aaaa")])
        rc, out = run(script.run(conn, apply=True))
        self.assertEqual(rc, 0)
        self.assertEqual(conn.transactions, 1)
        self.assertTrue(conn.fetched[0].rstrip().endswith("FOR UPDATE OF s"))
        updates = [args for sql, args in conn.executed if sql.startswith("UPDATE booking.staff_users")]
        audits = [args for sql, args in conn.executed if sql.startswith("INSERT INTO booking.audit_logs")]
        self.assertEqual(updates, [("00000000-0000-4000-8000-000000000001", ISS, "11111111-aaaa",
                                    "nghieppham@adventure.asia", "Nghiep Pham")])
        self.assertEqual(len(audits), 1)
        self.assertEqual(audits[0][0], "script:aa680_link_staff_cognito")
        self.assertEqual(audits[0][1], "00000000-0000-4000-8000-000000000001")
        self.assertEqual(counts(out), {"linked": 1, "already_linked": 1, "conflict_cog_row_exists": 1})

    def test_apply_reports_a_row_changed_since_the_read(self):
        conn = FakeConn([row()], update_status="UPDATE 0")
        rc, out = run(script.run(conn, apply=True))
        self.assertEqual(rc, 0)
        self.assertEqual(counts(out), {"changed_concurrently": 1})
        self.assertFalse([sql for sql, _ in conn.executed if sql.startswith("INSERT INTO booking.audit_logs")])

    def test_refuses_before_bk016(self):
        conn = FakeConn([row()], columns=0)
        rc, out = run(script.main(conn))
        self.assertEqual(rc, 1)
        self.assertIn("apply AA-Booking bk-016 first", out)
        self.assertEqual(conn.fetched, [])


if __name__ == "__main__":
    unittest.main()
