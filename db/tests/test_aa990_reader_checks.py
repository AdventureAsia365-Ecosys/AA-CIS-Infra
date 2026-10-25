"""AA-990: db/scripts/aa990_reader_checks.py (read-only reader evidence: TripPlanner pins, CRM catalog cache)."""

import ast
import asyncio
import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PATH = "db/scripts/aa990_reader_checks.py"
_spec = importlib.util.spec_from_file_location("aa990_reader_checks", ROOT / PATH)
mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mod)


class _Conn:
    def __init__(self):
        self.sql = []

    async def fetchrow(self, sql, *args):
        self.sql.append(sql)
        return {"n": 1}

    async def fetch(self, sql, *args):
        self.sql.append(sql)
        return [{"n": 1}]

    async def execute(self, sql, *args):
        return "SELECT 1"

    def transaction(self):
        class _Tx:
            async def __aenter__(self_inner):
                return self_inner

            async def __aexit__(self_inner, *exc):
                return False
        return _Tx()


class ReaderChecksTest(unittest.TestCase):
    def test_declares_read_only(self):
        tree = ast.parse((ROOT / PATH).read_text())
        assigns = [n for n in tree.body if isinstance(n, ast.Assign) and any(
            isinstance(t, ast.Name) and t.id == "READ_ONLY" for t in n.targets)]
        self.assertEqual(len(assigns), 1)
        self.assertIs(mod.READ_ONLY, True)

    def test_no_write_statements(self):
        for name in [n for n in dir(mod) if n.endswith("_SQL")]:
            sql = getattr(mod, name).upper()
            for verb in ("INSERT ", "UPDATE ", "DELETE ", "TRUNCATE ", "ALTER ", "DROP ", "CREATE "):
                self.assertNotIn(verb, sql, f"{name} contains {verb.strip()}")

    def test_main_runs_every_query_and_returns_zero(self):
        conn = _Conn()
        self.assertEqual(asyncio.run(mod.main(conn)), 0)
        self.assertEqual(len(conn.sql), 16)



class FailingCheckTest(unittest.TestCase):
    def test_one_failing_query_does_not_stop_the_rest(self):
        class _Bad(_Conn):
            async def fetchrow(self, sql, *args):
                self.sql.append(sql)
                if "trip_events" in sql:
                    raise RuntimeError("boom")
                return {"n": 1}
        conn = _Bad()
        self.assertEqual(asyncio.run(mod.main(conn)), 0)
        self.assertEqual(len(conn.sql), 16)


if __name__ == "__main__":
    unittest.main()
