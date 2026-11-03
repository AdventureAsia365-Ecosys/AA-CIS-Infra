"""AA-1027 E5: db/scripts/aa1027_tp_spend_daily_dry_run.py (read-only DRY RUN before TripPlanner tp-025 and CIS 351).

No database: a fake connection answers the script's SQL by matching on it. The SQL itself ran against a local
PostgreSQL 16 stand-in (the counter table with two rows, a ledger, the two gateway tables with 173's grant to
tripplanner, the two contract views) in a default_transaction_read_only session during S265.
Run: python3 -m unittest discover -s db/tests -v
"""
import asyncio
import contextlib
import datetime as dt
import importlib.util
import io
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import run_migration as rm  # noqa: E402

ROOT = HERE.parent.parent
PATH = "db/scripts/aa1027_tp_spend_daily_dry_run.py"
_spec = importlib.util.spec_from_file_location("aa1027_tp_spend_daily_dry_run", ROOT / PATH)
script = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(script)

UTC = dt.timezone.utc


class FakeConn:
    def __init__(self, *, table=True, recent=False, dependents=(), grantor_is_owner=True, grants=True,
                 views=True, statements=True):
        self.table, self.recent, self.dependents = table, recent, list(dependents)
        self.grantor_is_owner, self.grants, self.views, self.statements = grantor_is_owner, grants, views, statements
        self.sql = []

    async def fetchval(self, sql, *args):
        self.sql.append(sql)
        if "to_regclass('public.pg_stat_statements')" in sql:
            return self.statements
        if "to_regrole('tripplanner')" in sql:
            return True
        if "to_regclass($1)" in sql:
            if args[0] == script.TABLE:
                return self.table
            if args[0] in script.CONTRACT_VIEWS:
                return self.views
            return True
        if "has_table_privilege('tripplanner', $1, 'SELECT')" in sql:
            return self.views
        if "stats_reset" in sql:
            return dt.datetime(2026, 9, 1, tzinfo=UTC)
        raise AssertionError(f"unexpected fetchval: {sql[:80]}")

    async def fetchrow(self, sql, *args):
        self.sql.append(sql)
        if "FROM tripplanner.llm_spend_daily" in sql:
            return {"rows": 9, "days": 6, "first_day": dt.date(2026, 10, 19), "last_day": dt.date(2026, 10, 31),
                    "last_write": dt.datetime(2026, 10, 31, 13, 8, tzinfo=UTC), "cost_usd": 0.0123, "calls": 981,
                    "recent": self.recent}
        if "pg_stat_user_tables" in sql:
            return {"seq_scan": 1677, "idx_scan": 36, "n_tup_ins": 10, "n_tup_upd": 1539, "n_tup_del": 0,
                    "bytes": 65536}
        if "shared.llm_call_log" in sql:
            assert args[0] == ["tp_compose", "tp_search_embed"] and args[1] == dt.date(2026, 10, 19)
            return {"days": 6, "cost_usd": 0.0125, "calls": 990}
        raise AssertionError(f"unexpected fetchrow: {sql[:80]}")

    async def fetch(self, sql, *args):
        self.sql.append(sql)
        if "pg_rewrite" in sql:
            return [{"dep": d, "kind": "view"} for d in self.dependents]
        if "aclexplode(c.relacl) a\n WHERE c.oid = $1::text::regclass" in sql:
            return [{"grantee": "tripplanner", "privileges": "DELETE,INSERT,SELECT,UPDATE"}]
        if "pg_stat_statements" in sql:
            return [{"role": "tripplanner", "calls": 2516}]
        if "'tripplanner'::regrole" in sql:
            assert set(args[0]) == set(script.CIS_351_TABLES)
            if not self.grants:
                return []
            return [{"object": t, "privilege": "SELECT",
                     "grantor": "cis_owner" if self.grantor_is_owner else "aa_cis_admin",
                     "by_owner": self.grantor_is_owner} for t in script.CIS_351_TABLES]
        raise AssertionError(f"unexpected fetch: {sql[:80]}")


def _run(conn) -> tuple:
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = asyncio.run(script.main(conn))
    return rc, out.getvalue().splitlines()


class Shape(unittest.TestCase):
    def test_runner_accepts_the_script_as_read_only(self):
        source = (ROOT / PATH).read_text(encoding="utf-8")
        self.assertEqual(rm.script_errors(source, PATH), [])
        self.assertTrue(rm.script_is_read_only(source))

    def test_the_objects_match_tp025_and_cis_351(self):
        self.assertEqual(script.TABLE, "tripplanner.llm_spend_daily")
        self.assertEqual(script.CIS_351_TABLES, ("shared.llm_role_config", "shared.llm_model_catalog"))
        self.assertEqual(script.WRITE_GUARD, "1 hour")
        self.assertIn("interval '1 hour'", script.SUMMARY_SQL)


class Verdict(unittest.TestCase):
    def test_clean_state_is_ready_for_both(self):
        rc, lines = _run(FakeConn())
        self.assertEqual(rc, 0)
        self.assertEqual(lines[-1], "SCRIPT verdict drop_ready=true revoke_ready=true reasons=-")
        self.assertIn("SCRIPT ledger days=6 cost_usd=0.012500 calls=990", lines)
        table = next(ln for ln in lines if ln.startswith("SCRIPT table "))
        self.assertIn("exists=t rows=9 days=6 first_day=2026-10-19 last_day=2026-10-31", table)
        self.assertIn("ins=10 upd=1539 del=0", table)
        self.assertIn("SCRIPT statements role=tripplanner calls=2516", lines)
        self.assertEqual(sum(1 for ln in lines if ln.startswith("SCRIPT cis_grant ")), 2)
        self.assertIn("SCRIPT contract view=catalog.v_llm_gateway_config_v1 tripplanner_select=t exists=t", lines)

    def test_a_recent_write_and_a_dependent_block_the_drop(self):
        _, lines = _run(FakeConn(recent=True, dependents=["public.reads_it"]))
        verdict = lines[-1]
        self.assertTrue(verdict.startswith("SCRIPT verdict drop_ready=false revoke_ready=true"), verdict)
        self.assertIn("written_within:1_hour", verdict)
        self.assertIn("dependent:public.reads_it", verdict)

    def test_a_grant_not_by_the_owner_blocks_the_revoke(self):
        _, lines = _run(FakeConn(grantor_is_owner=False))
        self.assertIn("revoke_ready=false", lines[-1])
        self.assertTrue(any("grantor=aa_cis_admin by_owner=f" in ln for ln in lines))

    def test_a_missing_contract_view_blocks_the_revoke(self):
        _, lines = _run(FakeConn(views=False))
        self.assertIn("revoke_ready=false", lines[-1])

    def test_after_both_applies_it_is_the_verify(self):
        _, lines = _run(FakeConn(table=False, grants=False))
        self.assertIn(f"SCRIPT table name={script.TABLE} exists=f", lines)
        self.assertIn("SCRIPT cis_grant none=t", lines)
        self.assertFalse(any(ln.startswith("SCRIPT ledger") for ln in lines))
        self.assertEqual(lines[-1], "SCRIPT verdict drop_ready=true revoke_ready=true reasons=-")

    def test_output_has_only_script_lines(self):
        _, lines = _run(FakeConn())
        self.assertTrue(all(ln.startswith("SCRIPT ") for ln in lines))


if __name__ == "__main__":
    unittest.main()
