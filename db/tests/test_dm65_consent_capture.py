"""DM-6.5 (AA-886): db/scripts/dm65_consent_capture.py — read-only consent value / time / source check.

No database, no asyncpg: a fake connection answers the script's four queries by identity and records them.
The script itself was run against a local PostgreSQL 16 with the Dev columns of booking.customers,
booking.inbox_events and tripplanner.customers, in a `default_transaction_read_only = on` session like the
runner opens: all four queries ran, a write in the same session failed with SQLSTATE 25006.
Run: python3 -m unittest discover -s db/tests -v
"""
import asyncio
import contextlib
import importlib.util
import io
import re
import sys
import unittest
import uuid
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import run_migration as rm  # noqa: E402

ROOT = HERE.parent.parent
PATH = "db/scripts/dm65_consent_capture.py"
_spec = importlib.util.spec_from_file_location("dm65_consent_capture", ROOT / PATH)
script = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(script)

AT = datetime(2026, 10, 20, 1, 0, tzinfo=timezone.utc)
TP_ID = uuid.UUID("00000000-0000-4000-8000-000000000001")
BK_ID = uuid.UUID("00000000-0000-4000-8000-0000000000b1")


def _norm(sql: str) -> str:
    return " ".join(sql.split())


class FakeConn:
    def __init__(self, test_rows=None):
        self.calls = []
        self.answers = {
            "coverage": [
                {"app": "booking", "source": "tripplanner_lead", "contact_consent": True, "has_time": True, "n": 1},
                {"app": "tripplanner", "source": "tripplanner_form", "contact_consent": True, "has_time": True,
                 "n": 1},
            ],
            "integrity": [
                {"app": "booking", "consent_without_time": 0, "time_without_consent": 0},
                {"app": "tripplanner", "consent_without_time": 0, "time_without_consent": 0},
            ],
            "chain": {"tp_customers": 1, "tp_customers_in_booking": 1, "booking_leads": 1, "value_mismatch": 0,
                      "time_mismatch": 0, "wrong_source": 0},
            "test_inquiry": test_rows if test_rows is not None else [
                {"step": "tripplanner.customers", "id": str(TP_ID), "source": None, "consent": True,
                 "consent_at": AT, "at": AT},
                {"step": "booking.customers", "id": str(BK_ID), "source": "tripplanner_lead", "consent": True,
                 "consent_at": AT, "at": AT},
            ],
        }

    def _key(self, sql):
        return {script.Q1: "coverage", script.Q2: "integrity", script.Q3: "chain", script.Q4: "test_inquiry"}[sql]

    async def fetch(self, sql, *args):
        self.calls.append(("fetch", self._key(sql), args))
        return self.answers[self._key(sql)]

    async def fetchrow(self, sql, *args):
        self.calls.append(("fetchrow", self._key(sql), args))
        return self.answers[self._key(sql)]

    async def execute(self, sql, *args):  # pragma: no cover - the script must never call it
        raise AssertionError(f"read-only script executed: {sql}")


def run(conn):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = asyncio.run(script.main(conn))
    return rc, out.getvalue()


class ShapeTest(unittest.TestCase):
    def test_runner_accepts_the_file_as_read_only(self):
        source = (ROOT / PATH).read_text()
        self.assertEqual(rm.script_errors(source, PATH), [])
        self.assertTrue(rm.script_is_read_only(source))
        self.assertIs(script.READ_ONLY, True)

    def test_queries_only_select(self):
        for name in ("Q1", "Q2", "Q3", "Q4"):
            with self.subTest(name):
                sql = _norm(getattr(script, name)).upper()
                self.assertTrue(sql.startswith("SELECT "))
                for word in ("INSERT", "UPDATE", "DELETE", "TRUNCATE", "ALTER", "DROP", "CREATE", "GRANT",
                             "SET", "COPY", "CALL", "LOCK"):
                    self.assertIsNone(re.search(rf"\b{word}\b", sql), word)

    def test_queries_read_only_the_three_consent_tables(self):
        tables = set()
        for name in ("Q1", "Q2", "Q3", "Q4"):
            tables |= set(re.findall(r"(?<!DISTINCT )\b(?:FROM|JOIN)\s+([a-z_]+\.[a-z_]+)", _norm(getattr(script, name))))
        self.assertEqual(tables, {"booking.customers", "booking.inbox_events", "tripplanner.customers"})

    def test_no_personal_column_is_read_except_the_q4_email_filter(self):
        for name in ("Q1", "Q2", "Q3", "Q4"):
            sql = _norm(getattr(script, name))
            with self.subTest(name):
                self.assertIsNone(re.search(r"\b(?:name|phone|address)\b", sql))
                if name != "Q4":
                    self.assertNotIn("email", sql)
        # Q4: email only ever appears as `lower(<email>) LIKE $1`, once per branch
        q4 = _norm(script.Q4)
        self.assertEqual(q4.count("email"), 3)
        self.assertEqual(len(re.findall(r"lower\([^()]*email'?\) LIKE \$1", q4)), 3)

    def test_soft_deleted_booking_rows_are_left_out(self):
        for name in ("Q1", "Q2", "Q3", "Q4"):
            sql = _norm(getattr(script, name))
            with self.subTest(name):
                self.assertEqual(len(re.findall(r"\b(?:FROM|JOIN) booking\.customers\b", sql)),
                                 sql.count("deleted_at IS NULL"))

    def test_test_inquiry_pattern_only_matches_the_reserved_test_domain(self):
        self.assertTrue(script.TEST_EMAIL_PATTERN.endswith("@example.com"))
        self.assertTrue(script.TEST_EMAIL_PATTERN.startswith("aa886-consent-test"))
        self.assertEqual(script.TEST_EMAIL_PATTERN, script.TEST_EMAIL_PATTERN.lower())  # compared to lower(email)


class RunTest(unittest.TestCase):
    def test_runs_the_four_queries_in_order_and_passes_the_pattern_as_a_parameter(self):
        conn = FakeConn()
        rc, out = run(conn)
        self.assertIsNone(rc)
        self.assertEqual([(kind, key) for kind, key, _ in conn.calls],
                         [("fetch", "coverage"), ("fetch", "integrity"), ("fetchrow", "chain"),
                          ("fetch", "test_inquiry")])
        self.assertEqual(conn.calls[3][2], (script.TEST_EMAIL_PATTERN,))
        self.assertEqual([c[2] for c in conn.calls[:3]], [(), (), ()])

    def test_prints_one_grep_able_line_per_row(self):
        _, out = run(FakeConn())
        lines = out.splitlines()
        self.assertTrue(all(line.startswith("SCRIPT ") for line in lines))
        self.assertIn("SCRIPT coverage app=booking source=tripplanner_lead contact_consent=True has_time=True n=1",
                      lines)
        self.assertIn("SCRIPT integrity app=tripplanner consent_without_time=0 time_without_consent=0", lines)
        self.assertIn("SCRIPT chain tp_customers=1 tp_customers_in_booking=1 booking_leads=1 value_mismatch=0 "
                      "time_mismatch=0 wrong_source=0", lines)
        self.assertIn("SCRIPT test_inquiry rows=2", lines)
        self.assertIn(f"SCRIPT test_inquiry step=booking.customers id={BK_ID} source=tripplanner_lead consent=True "
                      f"consent_at={AT} at={AT}", lines)

    def test_no_test_inquiry_yet_still_reports_zero_rows(self):
        rc, out = run(FakeConn(test_rows=[]))
        self.assertIsNone(rc)
        self.assertIn("SCRIPT test_inquiry rows=0", out.splitlines())
        self.assertEqual(sum(line.startswith("SCRIPT test_inquiry ") for line in out.splitlines()), 1)

    def test_never_prints_an_email(self):
        _, out = run(FakeConn())
        self.assertNotIn("@", out)


if __name__ == "__main__":
    unittest.main()
