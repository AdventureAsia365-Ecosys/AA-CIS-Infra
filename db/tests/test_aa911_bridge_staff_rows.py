"""AA-911: db/scripts/aa911_bridge_staff_rows.py (link or deactivate the bridge-era Booking staff rows).

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
PATH = "db/scripts/aa911_bridge_staff_rows.py"
_spec = importlib.util.spec_from_file_location("aa911_bridge_staff_rows", ROOT / PATH)
script = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(script)

ISS = "https://cognito-idp.us-west-1.amazonaws.com/us-west-1_bCcFvbSOS"
ADMIN_ID = "00000000-0000-4000-8000-000000000001"
E2E_ID = "00000000-0000-4000-8000-0000000000e2"
E2E2_ID = "00000000-0000-4000-8000-0000000000e3"


def row(cis_user_id=ADMIN_ID, *, username="admin", active=True, in_cis=True, cis_active=True,
        sub="11111111-aaaa", linked=None, holder=None):
    return {
        "cis_user_id": cis_user_id, "role": "admin", "active": active, "has_email": False, "has_name": True,
        "booking_name": "Booking Name", "linked_iss": linked[0] if linked else None,
        "linked_sub": linked[1] if linked else None, "in_cis": in_cis,
        "cis_username": username if in_cis else None, "cis_active": cis_active if in_cis else None,
        "cognito_iss": ISS if (sub and in_cis) else None, "cognito_sub": sub if in_cis else None,
        "cis_email": "someone@adventure.asia", "cis_display_name": "Display Name", "holder": holder,
    }


class FakeConn:
    def __init__(self, rows, columns=2, update_status="UPDATE 1", active_unlinked=0):
        self.rows, self.columns, self.update_status = rows, columns, update_status
        self.active_unlinked = active_unlinked
        self.executed = []
        self.fetched = []
        self.transactions = 0

    async def fetchval(self, sql, *args):
        if "information_schema" in sql:
            return self.columns
        return self.active_unlinked

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


def payload(output, prefix):
    return [json.loads(line[len(prefix):]) for line in output.splitlines() if line.startswith(prefix)]


def writes(conn, prefix):
    return [args for sql, args in conn.executed if sql.startswith(prefix)]


class ShapeTest(unittest.TestCase):
    def test_runner_accepts_the_file_and_it_is_a_dry_run_as_merged(self):
        source = (ROOT / PATH).read_text()
        self.assertEqual(rm.script_errors(source, PATH), [])
        self.assertTrue(rm.script_is_read_only(source))
        self.assertIs(script.READ_ONLY, True)


class ClassifyTest(unittest.TestCase):
    def test_link_only_for_an_active_cis_identity_nobody_else_holds(self):
        self.assertEqual(script.classify(row()), ("link", None))

    def test_deactivate_reasons(self):
        self.assertEqual(script.classify(row(in_cis=False)), ("deactivate", "no_cis_user"))
        self.assertEqual(script.classify(row(cis_active=False)), ("deactivate", "cis_inactive"))
        self.assertEqual(script.classify(row(sub=None)), ("deactivate", "cis_not_linked"))
        self.assertEqual(script.classify(row(holder="cog:11111111-aaaa")), ("deactivate", "cog_row_exists"))
        self.assertEqual(script.classify(row(holder="00000000-0000-4000-8000-000000000009")),
                         ("deactivate", "identity_taken"))

    def test_e2e_accounts_always_deactivate_even_when_linked(self):
        self.assertEqual(script.classify(row(E2E_ID, username="e2e-claude-code")), ("deactivate", "e2e_account"))
        linked = row(E2E2_ID, username="e2e-claude-code-2", linked=(ISS, "11111111-aaaa"))
        self.assertEqual(script.classify(linked), ("deactivate", "e2e_account"))

    def test_no_ops(self):
        self.assertEqual(script.classify(row(active=False)), ("already_inactive", None))
        self.assertEqual(script.classify(row(username="e2e-claude-code", active=False)), ("already_inactive", None))
        self.assertEqual(script.classify(row(linked=(ISS, "11111111-aaaa"))), ("already_linked", None))
        self.assertEqual(script.classify(row(linked=(ISS, "other"))), ("linked_other", None))


class GuardTest(unittest.TestCase):
    def test_known_usernames_pass(self):
        rows = [row(), row(E2E_ID, username="e2e-claude-code"), row(E2E2_ID, username="e2e-claude-code-2")]
        self.assertEqual(script.guard_violations(rows), [])

    def test_unknown_and_null_usernames_fail(self):
        rows = [row("00000000-0000-4000-8000-00000000000a", username="cathy"),
                row("00000000-0000-4000-8000-00000000000b", in_cis=False)]
        self.assertEqual(script.guard_violations(rows),
                         ["00000000-0000-4000-8000-00000000000a", "00000000-0000-4000-8000-00000000000b"])

    def test_inactive_or_linked_unknown_rows_are_not_a_violation(self):
        rows = [row(username="cathy", active=False), row(username="cathy", linked=(ISS, "11111111-aaaa"))]
        self.assertEqual(script.guard_violations(rows), [])

    def test_dry_run_with_an_unknown_user_fails_and_writes_nothing(self):
        conn = FakeConn([row(in_cis=False)], active_unlinked=1)
        rc, out = run(script.main(conn))
        self.assertEqual(rc, 1)
        self.assertEqual(conn.executed, [])
        self.assertIn("SCRIPT ERROR active unlinked bridge-era rows", out)

    def test_apply_with_an_unknown_user_fails_before_any_write(self):
        conn = FakeConn([row(), row("00000000-0000-4000-8000-00000000000a", username="cathy")])
        rc, out = run(script.run(conn, apply=True))
        self.assertEqual(rc, 1)
        self.assertEqual(writes(conn, "UPDATE"), [])
        self.assertEqual(writes(conn, "INSERT"), [])


class RunTest(unittest.TestCase):
    def rows(self):
        return [row(), row(E2E_ID, username="e2e-claude-code"),
                row(E2E2_ID, username="e2e-claude-code-2", cis_active=False)]

    def test_dry_run_prints_the_plan_and_writes_nothing(self):
        conn = FakeConn(self.rows(), active_unlinked=3)
        rc, out = run(script.main(conn))
        self.assertEqual(rc, 0)
        self.assertEqual(conn.executed, [])
        self.assertEqual(conn.transactions, 0)
        self.assertNotIn("FOR UPDATE", conn.fetched[0])
        self.assertIn("mode=DRY_RUN", out)
        [counts] = payload(out, "SCRIPT counts ")
        self.assertEqual(counts, {"link": 1, "deactivate": 2})
        printed = payload(out, "SCRIPT row ")
        self.assertEqual([(x["cis_username"], x["action"], x["reason"]) for x in printed],
                         [("admin", "link", None), ("e2e-claude-code", "deactivate", "e2e_account"),
                          ("e2e-claude-code-2", "deactivate", "e2e_account")])
        self.assertEqual(printed[0]["sub8"], "11111111")
        self.assertIn("SCRIPT verdict active_unlinked=3", out)
        self.assertNotIn("@adventure.asia", out)

    def test_apply_links_and_deactivates_with_audit_rows(self):
        conn = FakeConn(self.rows(), active_unlinked=0)
        rc, out = run(script.run(conn, apply=True))
        self.assertEqual(rc, 0)
        self.assertEqual(conn.transactions, 1)
        self.assertTrue(conn.fetched[0].rstrip().endswith("FOR UPDATE OF s"))
        self.assertIn(("SET LOCAL lock_timeout = '5s'", ()), conn.executed)
        links = writes(conn, "UPDATE booking.staff_users SET cognito_iss")
        self.assertEqual(links, [(ADMIN_ID, ISS, "11111111-aaaa", "someone@adventure.asia", "Display Name")])
        deactivations = writes(conn, "UPDATE booking.staff_users SET active = false")
        self.assertEqual(deactivations, [(E2E_ID,), (E2E2_ID,)])
        audits = writes(conn, "INSERT INTO booking.audit_logs")
        self.assertEqual([(a[0], a[1], a[2]) for a in audits],
                         [("script:aa911_bridge_staff_rows", "staff.identity_linked", ADMIN_ID),
                          ("script:aa911_bridge_staff_rows", "staff.deactivated", E2E_ID),
                          ("script:aa911_bridge_staff_rows", "staff.deactivated", E2E2_ID)])
        self.assertEqual(json.loads(audits[1][4]), {"cis_user_id": E2E_ID, "active": False, "reason": "e2e_account"})
        self.assertEqual(audits[0][5], "Booking Name")
        [counts] = payload(out, "SCRIPT counts ")
        self.assertEqual(counts, {"linked": 1, "deactivated": 2})
        self.assertIn("SCRIPT verdict active_unlinked=0", out)

    def test_second_apply_is_a_no_op(self):
        rows = [row(linked=(ISS, "11111111-aaaa")), row(E2E_ID, username="e2e-claude-code", active=False),
                row(E2E2_ID, username="e2e-claude-code-2", active=False)]
        conn = FakeConn(rows)
        rc, out = run(script.run(conn, apply=True))
        self.assertEqual(rc, 0)
        self.assertEqual(writes(conn, "UPDATE"), [])
        self.assertEqual(writes(conn, "INSERT"), [])
        [counts] = payload(out, "SCRIPT counts ")
        self.assertEqual(counts, {"already_linked": 1, "already_inactive": 2})

    def test_a_row_changed_since_the_read_writes_no_audit(self):
        conn = FakeConn([row()], update_status="UPDATE 0")
        rc, out = run(script.run(conn, apply=True))
        self.assertEqual(rc, 0)
        self.assertEqual(writes(conn, "INSERT"), [])
        [counts] = payload(out, "SCRIPT counts ")
        self.assertEqual(counts, {"changed_concurrently": 1})

    def test_refuses_before_bk016(self):
        conn = FakeConn([row()], columns=0)
        rc, out = run(script.main(conn))
        self.assertEqual(rc, 1)
        self.assertIn("apply AA-Booking bk-016 first", out)
        self.assertEqual(conn.fetched, [])


if __name__ == "__main__":
    unittest.main()
