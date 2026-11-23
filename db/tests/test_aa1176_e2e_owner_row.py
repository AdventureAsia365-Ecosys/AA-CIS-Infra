"""AA-1176 (S288): db/scripts/aa1176_e2e_owner_row.py (the A10h E2E owner's CIS directory row, Booking grant and owner
marker) against an in-memory stand-in of shared.admin_users / staff_app_grant / staff_crm_grant / audit_log.

The stand-in answers the script's SQL by its exact text (a changed statement fails the test) and enforces the CIS 473
CHECK branch of the address (admin, no custom role, no password, never the business owner). Covered: the shape check
(READ_ONLY as merged, no PII printed), the DRY RUN plans, apply from no row and from a Staff-page row, idempotence,
every refusal, the removal mode, and the 473 guard.
Run: python3 -m unittest discover -s db/tests -v
"""
import asyncio
import importlib.util
import io
import json
import sys
import unittest
import uuid
from contextlib import asynccontextmanager, redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import run_migration as rm  # noqa: E402

ROOT = HERE.parent.parent
PATH = "db/scripts/aa1176_e2e_owner_row.py"


def load():
    spec = importlib.util.spec_from_file_location("aa1176_e2e_owner_row", ROOT / PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


script = load()
EMAIL = script.OWNER_EMAIL
CHECK_473 = f"CHECK (... OR ((email = '{EMAIL}'::text) AND (role = 'admin'::shared.admin_role) ...))"


class FakeDB:
    def __init__(self, *, check=CHECK_473, crm_table=True):
        self.rows = []
        self.grants = {}
        self.crm = {}
        self.audit = []
        self.check = check
        self.crm_table = crm_table
        self.writes = 0

    def add(self, **over):
        row = {"id": uuid.uuid4(), "username": over.pop("username", "e2e-owner"), "email": EMAIL, "role": "admin",
               "custom_role": None, "is_active": True, "is_owner": False, "is_business_owner": False,
               "password_hash": None, "cognito_sub": None}
        row.update(over)
        self.rows.append(row)
        return row

    def _mine(self, email):
        return [r for r in self.rows if (r["email"] or "").lower() == email]

    def _chk(self, r):
        if r["email"] == EMAIL and not (r["role"] == "admin" and r["custom_role"] is None
                                        and not r["is_business_owner"] and r["password_hash"] is None):
            raise RuntimeError("check_violation admin_users_email_chk")

    @asynccontextmanager
    async def transaction(self):
        snap = json.dumps([self.rows, self.grants, self.audit], default=str)
        try:
            yield
        except BaseException:
            rows, grants, audit = json.loads(snap)
            for r in rows:
                r["id"] = uuid.UUID(r["id"])
            self.rows, self.grants, self.audit = rows, {k: v for k, v in grants.items()}, audit
            raise

    async def fetch(self, sql, *args):
        if sql == script.ROW_SQL:
            out = []
            for r in self._mine(args[0]):
                out.append({"id": r["id"], "role": r["role"], "custom_role": r["custom_role"],
                            "is_active": r["is_active"], "is_owner": r["is_owner"],
                            "is_business_owner": r["is_business_owner"], "no_local_login": r["password_hash"] is None,
                            "has_identity": r["cognito_sub"] is not None,
                            "booking_role": self.grants.get(str(r["id"]))})
            return out
        if sql == script.ROW_LOCK_SQL:
            return [{"id": r["id"]} for r in self._mine(args[0])]
        raise AssertionError(f"unexpected fetch: {sql}")

    async def fetchval(self, sql, *args):
        if sql == script.CHECK_SQL:
            return self.check
        if sql == script.CRM_TABLE_SQL:
            return self.crm_table
        if sql == script.CRM_COUNT_SQL:
            return self.crm.get(args[0], 0)
        if sql == script.USERNAME_TAKEN_SQL:
            return sum(1 for r in self.rows if r["username"] == args[0])
        if sql == script.INSERT_ROW_SQL:
            row = self.add(username=args[0], email=args[1], display_name=args[2])
            self._chk(row)
            self.writes += 1
            return row["id"]
        if sql == script.GRANT_VIEW_SQL:
            return sum(1 for r in self._mine(args[0]) if r["cognito_sub"] and r["is_owner"]
                       and self.grants.get(str(r["id"])) == args[1])
        raise AssertionError(f"unexpected fetchval: {sql}")

    async def execute(self, sql, *args):
        if sql.startswith("SET LOCAL"):
            return "SET"
        self.writes += 1
        if sql == script.UPSERT_GRANT_SQL:
            self.grants[args[0]] = args[2]
            return "INSERT 0 1"
        if sql == script.DELETE_GRANT_SQL:
            self.grants.pop(args[0], None)
            return "DELETE 1"
        if sql == script.SET_OWNER_SQL:
            hit = [r for r in self.rows if str(r["id"]) == args[0] and r["role"] == "admin" and r["is_active"]
                   and not r["is_business_owner"] and r["custom_role"] is None and r["password_hash"] is None]
            for r in hit:
                r["is_owner"] = True
            return f"UPDATE {len(hit)}"
        if sql == script.REMOVE_SQL:
            hit = [r for r in self.rows if str(r["id"]) == args[0] and not r["is_active"]]
            for r in hit:
                r["is_owner"] = False
            return f"UPDATE {len(hit)}"
        if sql == script.AUDIT_SQL:
            self.audit.append({"actor": args[0], "action": args[1], "resource_id": args[2],
                               "details": json.loads(args[3])})
            return "INSERT 0 1"
        raise AssertionError(f"unexpected execute: {sql}")


def run(db, *, apply, remove=False):
    script.REMOVE = remove
    buf = io.StringIO()
    try:
        with redirect_stdout(buf):
            result = asyncio.run(script.run(db, apply_changes=apply))
    finally:
        script.REMOVE = False
    return result, buf.getvalue()


def lines(text, label):
    return [json.loads(line.split(" ", 2)[2]) for line in text.splitlines() if line.startswith(f"SCRIPT {label} ")]


class Shape(unittest.TestCase):
    def test_merged_read_only_with_a_valid_shape(self):
        source = (ROOT / PATH).read_text()
        self.assertEqual(rm.script_errors(source, PATH), [])
        # S288 one-shot write window (dry run reviewed, run 45197375276): READ_ONLY False for one DB Migrate run;
        # the follow-up PR restores READ_ONLY True and these two asserts.
        self.assertFalse(rm.script_is_read_only(source))
        self.assertIs(script.READ_ONLY, False)
        self.assertIs(script.REMOVE, False)

    def test_constants_match_the_trigger_and_the_tool(self):
        workforce = (ROOT / "accounts/aa365/lambda_src/identity_triggers/workforce.py").read_text()
        tool = (ROOT / "tools/identity/crm_dev_identity.py").read_text()
        self.assertIn(f'E2E_OWNER_TEST_STAFF_EMAIL = "{EMAIL}"', workforce)
        self.assertIn('E2E_OWNER: tuple[str, tuple[str, ...], str] = ("e2e-owner", ("booking-admin", "cis-admin")', tool)
        self.assertEqual((script.CIS_ROLE, script.BOOKING_ROLE), ("admin", "admin"))

    def test_the_owner_update_holds_the_473_scope(self):
        for clause in ("role = 'admin'", "NOT is_business_owner", "custom_role IS NULL", "password_hash IS NULL",
                       "is_active"):
            self.assertIn(clause, script.SET_OWNER_SQL)
        self.assertNotIn("is_business_owner = true", " ".join([script.SET_OWNER_SQL, script.INSERT_ROW_SQL]))
        self.assertNotIn("email", script.ROW_SQL.split("FROM", 1)[0])   # the e-mail is never selected


class DryRun(unittest.TestCase):
    def test_no_row_plans_three_writes_and_writes_nothing(self):
        db = FakeDB()
        result, text = run(db, apply=False)
        self.assertEqual(result, 0)
        self.assertEqual(lines(text, "summary")[-1], {"rows_matched": 0, "writes_planned": 3, "dry_run": True})
        self.assertEqual((db.writes, db.rows, db.audit), (0, [], []))
        self.assertNotIn(EMAIL, text)

    def test_a_staff_page_row_plans_grant_and_marker(self):
        db = FakeDB()
        db.add()
        _, text = run(db, apply=False)
        self.assertEqual(lines(text, "summary")[-1]["writes_planned"], 2)
        self.assertEqual(db.writes, 0)


class Apply(unittest.TestCase):
    def test_from_no_row(self):
        db = FakeDB()
        result, text = run(db, apply=True)
        self.assertEqual(result, 0)
        (row,) = db.rows
        self.assertEqual((row["role"], row["is_owner"], row["is_business_owner"], row["is_active"],
                          row["password_hash"], row["display_name"]),
                         ("admin", True, False, True, None, "E2E owner (agent, Dev only)"))
        self.assertEqual(db.grants[str(row["id"])], "admin")
        self.assertEqual([a["action"] for a in db.audit],
                         ["staff.created", "staff.roles_changed", "staff.owner_marker_set"])
        for a in db.audit:
            self.assertEqual(a["actor"], "script:db-migrate-aa1176")
            self.assertEqual((a["details"]["source"], a["details"]["e2e_owner"]), ("db-script:aa1176", True))
        self.assertEqual(db.audit[2]["details"]["is_owner"], {"before": False, "after": True})
        self.assertIn("no Cognito identity linked yet", text)
        self.assertNotIn(EMAIL, text)
        self.assertNotIn(str(row["id"]), text)

    def test_second_apply_writes_nothing(self):
        db = FakeDB()
        run(db, apply=True)
        audits, writes = len(db.audit), db.writes
        _, text = run(db, apply=True)
        self.assertEqual((len(db.audit), db.writes), (audits, writes))
        self.assertEqual(lines(text, "summary")[-1]["audit_rows"], 0)

    def test_a_linked_row_shows_in_the_booking_view(self):
        db = FakeDB()
        db.add(cognito_sub="sub-1")
        _, text = run(db, apply=True)
        self.assertEqual(lines(text, "summary")[-1]["booking_owner_view_rows"], 1)

    def refused(self, db, needle, *, apply=True):
        before = json.dumps([db.rows, db.grants, db.audit], default=str)
        with self.assertRaises(RuntimeError) as err:
            run(db, apply=apply)
        self.assertIn(needle, str(err.exception))
        self.assertEqual(json.dumps([db.rows, db.grants, db.audit], default=str), before)

    def test_refusals(self):
        cases = [
            ({"is_business_owner": True}, "business owner"),
            ({"role": "content_lead"}, "needs admin"),
            ({"custom_role": "custom_content", "role": "content_lead"}, "needs admin"),
            ({"password_hash": "x"}, "password"),
            ({"is_active": False}, "disabled"),
        ]
        for over, needle in cases:
            for apply in (False, True):
                with self.subTest(over=over, apply=apply):
                    db = FakeDB()
                    db.add(**over)
                    self.refused(db, needle, apply=apply)

    def test_two_rows_or_a_crm_role_or_a_taken_username_refuse(self):
        db = FakeDB()
        db.add()
        db.add(username="other", email=EMAIL.upper())
        self.refused(db, "at most one")
        db = FakeDB()
        row = db.add()
        db.crm[str(row["id"])] = 1
        self.refused(db, "CRM role")
        db = FakeDB()
        db.add(email="someone@adventure.asia")   # username e2e-owner taken by another address
        self.refused(db, "username is taken")

    def test_without_migration_473_nothing_runs(self):
        db = FakeDB(check="CHECK (email ~ 'adventure[.]asia')")
        with self.assertRaises(RuntimeError):
            run(db, apply=True)
        self.assertEqual((db.rows, db.audit), ([], []))


class Remove(unittest.TestCase):
    def test_remove_refuses_while_the_row_is_active(self):
        """REMOVE makes no Cognito call, so it never stands in for Staff › Disable (the token alone still opens
        Booking and the CRM): an active row is refused in the DRY RUN and the apply, nothing changes."""
        db = FakeDB()
        run(db, apply=True)
        before = json.dumps([db.rows, db.grants, db.audit], default=str)
        for apply in (False, True):
            with self.subTest(apply=apply), self.assertRaises(RuntimeError) as err:
                run(db, apply=apply, remove=True)
            self.assertIn("Platform › Staff first", str(err.exception))
            self.assertIn("never instead of it", str(err.exception))
        self.assertEqual(json.dumps([db.rows, db.grants, db.audit], default=str), before)

    def test_remove_after_staff_disable_clears_the_marker_and_drops_the_grant(self):
        db = FakeDB()
        run(db, apply=True)
        (row,) = db.rows
        row["is_active"] = False          # Platform › Staff › Disable ran first
        _, dry = run(db, apply=False, remove=True)
        self.assertEqual(lines(dry, "summary")[-1]["writes_planned"], 2)
        self.assertEqual(lines(dry, "cognito")[-1]["cognito_user"], "NOT touched by this script")
        db.audit.clear()
        result, text = run(db, apply=True, remove=True)
        self.assertEqual(result, 0)
        self.assertEqual((row["is_owner"], row["is_active"]), (False, False))
        self.assertEqual(db.grants, {})
        self.assertEqual([a["action"] for a in db.audit], ["staff.owner_marker_cleared", "staff.roles_changed"])
        self.assertEqual(lines(text, "cognito")[-1]["cognito_user"], "NOT touched by this script")
        _, again = run(db, apply=True, remove=True)
        self.assertEqual(lines(again, "summary")[-1]["audit_rows"], 0)

    def test_remove_without_a_row_is_a_no_op(self):
        db = FakeDB()
        result, text = run(db, apply=True, remove=True)
        self.assertEqual((result, db.audit), (0, []))
        self.assertEqual(lines(text, "summary")[-1]["rows_matched"], 0)


if __name__ == "__main__":
    unittest.main()
