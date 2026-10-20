"""AA-805: db/scripts/aa805_ai_guards_read.py (read-only DB half of the TripPlanner AI Phase 0 evidence).

No database, no asyncpg: a fake connection answers the script's SQL by matching on it. The SQL itself was run against a
local PostgreSQL 16 with stub tables (same column names as docs/architecture/db-schema-reference.md, 19/10) in a
default_transaction_read_only session during S245: clean set -> PASS, an inactive-only and a not-embedded destination
-> FAIL with both named, candidates split into no_structured_text / own_day_missing.
Run: python3 -m unittest discover -s db/tests -v
"""
import asyncio
import contextlib
import importlib.util
import io
import re
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import run_migration as rm  # noqa: E402

ROOT = HERE.parent.parent
PATH = "db/scripts/aa805_ai_guards_read.py"
_spec = importlib.util.spec_from_file_location("aa805_ai_guards_read", ROOT / PATH)
script = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(script)

UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


class FakeConn:
    def __init__(self, *, violations=(), inactive_only=3, inactive_only_returned=0):
        self.violations = set(violations)
        self.inactive_only, self.inactive_only_returned = inactive_only, inactive_only_returned
        self.executed = []
        self.in_transaction = False
        self.tenant_reads_outside_transaction = 0

    def _note_tenant_read(self):
        if not self.in_transaction:
            self.tenant_reads_outside_transaction += 1

    async def execute(self, sql, *args):
        self.executed.append((" ".join(sql.split()), args))
        return "SELECT 1"

    async def fetchval(self, sql, *args):
        return 0.0123

    async def fetch(self, sql, *args):
        if "FROM tripplanner.llm_spend_daily" in sql:
            return [{"day": "2026-10-20", "stage": "tp_search_embed", "cost_usd": 0.0003, "calls": 30,
                     "unpriced_calls": 0}]
        if "FROM shared.llm_call_log" in sql:
            return [{"day": "2026-10-20", "stage": "tp_search_embed", "calls": 30, "cost_usd": 0.0003}]
        if "FROM tripplanner.narration_cache" in sql:
            return [{"source": "llm", "mode": "compose", "rows": 2, "hits": 3, "rows_hit": 1, "fresh_rows": 2,
                     "max_created": "t", "max_last_hit": "t"}]
        if "unnest($2::uuid[])" in sql:
            self._note_tenant_read()
            return [{"destination_id": d, "found": True, "embedded_components": 1,
                     "has_active_component": d not in self.violations} for d in args[1]]
        if "no_structured_text" in sql:
            self._note_tenant_read()
            return [{"kind": "no_structured_text", "n": 1, "sample": ["c1"]}]
        raise AssertionError(f"unexpected SQL: {sql[:80]}")

    async def fetchrow(self, sql, *args):
        self._note_tenant_read()
        if "inactive_only_returned" in sql:
            return {"inactive_only": self.inactive_only, "inactive_only_returned": self.inactive_only_returned}
        return {"embedded": 100, "embedded_not_active": 7}

    @contextlib.asynccontextmanager
    async def transaction(self):
        self.in_transaction = True
        try:
            yield
        finally:
            self.in_transaction = False


def run(conn):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        result = asyncio.run(script.main(conn))
    return result, out.getvalue()


class Aa805AiGuardsReadTest(unittest.TestCase):
    def test_runner_accepts_the_file_as_read_only(self):
        source = (ROOT / PATH).read_text(encoding="utf-8")
        self.assertEqual(rm.script_errors(source, PATH), [])
        self.assertTrue(rm.script_is_read_only(source))

    def test_returned_destinations_are_725_distinct_uuids(self):
        ids, digest = script.returned_destinations()
        self.assertEqual(len(ids), 725)
        self.assertTrue(all(UUID_RE.match(i) for i in ids))
        self.assertEqual(digest, "a0a419e9ccb805bf")  # sha256 of the S245 aa805_search_results.json id set

    def test_clean_run_passes_and_reads_the_catalog_as_the_aa_tenant(self):
        conn = FakeConn()
        result, out = run(conn)
        self.assertIsNone(result)
        self.assertIn("SCRIPT search returned=725 found=725 without_active_component=0", out)
        self.assertIn("SCRIPT control inactive_only_destinations=3 of_them_returned=0", out)
        self.assertIn("SCRIPT verdict search_no_inactive=PASS control_has_inactive_only=True", out)
        self.assertIn("under_cap=True", out)
        self.assertEqual(conn.tenant_reads_outside_transaction, 0)
        self.assertEqual(conn.executed[0][1], (script.AA_TENANT_ID,))
        self.assertTrue(all(line.startswith("SCRIPT ") for line in out.splitlines()))

    def test_a_returned_inactive_destination_fails_and_is_named(self):
        ids, _ = script.returned_destinations()
        conn = FakeConn(violations=[ids[0]], inactive_only_returned=1)
        _, out = run(conn)
        self.assertIn("without_active_component=1", out)
        self.assertIn(f"SCRIPT search_violation destination={ids[0]}", out)
        self.assertIn("search_no_inactive=FAIL", out)

    def test_every_published_tours_read_names_the_aa_tenant(self):
        # The master sees every tenant (cis_owner policy USING true): the tenant filter must be in the SQL itself.
        for sql in (script.SEARCH_SQL, script.CONTROL_SQL, script.COMPONENTS_SQL, script.CANDIDATES_SQL):
            self.assertIn("published_tours", sql)
            self.assertIn("tenant_id = $1::uuid", sql)
            self.assertIn("master_status = 'active'", sql)
            self.assertIn("deleted_at IS NULL", sql)


if __name__ == "__main__":
    unittest.main()
