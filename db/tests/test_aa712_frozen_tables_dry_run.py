"""AA-712 X4: db/scripts/aa712_frozen_tables_dry_run.py (read-only DRY RUN before tp-018 and CIS 270).

No database: a fake connection answers the script's SQL by matching on it. The SQL itself ran against a local
PostgreSQL 16 stand-in (the eight frozen tables, the five CIS objects with Dev's tripplanner grants) in a
default_transaction_read_only session during S248: a clean set -> drop_ready=true revoke_ready=true; a tour_day row
after the cutoff and a view on tour_stop -> drop_ready=false with both reasons.
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
PATH = "db/scripts/aa712_frozen_tables_dry_run.py"
_spec = importlib.util.spec_from_file_location("aa712_frozen_tables_dry_run", ROOT / PATH)
script = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(script)

UTC = dt.timezone.utc
CUTOFF = dt.datetime(2026, 10, 16, tzinfo=UTC)
BEFORE_CUTOFF = dt.datetime(2026, 10, 12, tzinfo=UTC)


class FakeConn:
    def __init__(self, *, last_write=BEFORE_CUTOFF, dependents=(), grantor_is_owner=True,
                 missing=(), statements=True):
        self.last_write, self.dependents = last_write, list(dependents)
        self.grantor_is_owner, self.missing, self.statements = grantor_is_owner, set(missing), statements
        self.sql = []

    async def fetchval(self, sql, *args):
        self.sql.append(sql)
        if "::timestamptz" in sql:
            return CUTOFF
        if "to_regclass('public.pg_stat_statements')" in sql:
            return self.statements
        if "to_regrole('tripplanner')" in sql:
            return True
        if "to_regclass($1)" in sql:
            return args[0] not in self.missing
        if sql.startswith("SELECT count(*) FROM tripplanner."):
            return 42
        if sql.startswith("SELECT max("):
            return self.last_write
        if "stats_reset" in sql:
            return dt.datetime(2026, 9, 1, tzinfo=UTC)
        raise AssertionError(f"unexpected fetchval: {sql[:80]}")

    async def fetchrow(self, sql, *args):
        self.sql.append(sql)
        if "pg_stat_user_tables" in sql:
            return {"seq_scan": 3, "idx_scan": 0, "n_tup_ins": 0, "n_tup_upd": 0, "n_tup_del": 0,
                    "last_analyze": None, "bytes": 8192}
        if "pg_stat_statements" in sql:
            return {"statements": 0, "calls": 0, "roles": ""}
        if "component_id_map" in sql:
            return {"rows": 750, "events": 12, "drafts": 4}
        raise AssertionError(f"unexpected fetchrow: {sql[:80]}")

    async def fetch(self, sql, *args):
        self.sql.append(sql)
        if "aclexplode(c.relacl) a\n WHERE c.oid = $1::text::regclass" in sql:
            return [{"grantee": "tripplanner", "privileges": "DELETE,INSERT,SELECT,UPDATE"}]
        if "pg_rewrite" in sql:
            return [{"dep": d, "dep_on": "tripplanner.tour_stop", "kind": "view"} for d in self.dependents]
        if "nspacl" in sql:
            return [{"object": "gold_aa_internal", "privilege": "USAGE", "grantor": "cis_owner", "by_owner": True}]
        if "'tripplanner'::regrole" in sql:
            return [{"object": "gold_aa_internal.published_tours", "privilege": "SELECT",
                     "grantor": "cis_owner" if self.grantor_is_owner else "aa_cis_admin",
                     "by_owner": self.grantor_is_owner}]
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

    def test_the_eight_tables_and_the_cutoff_match_tp018(self):
        self.assertEqual(len(script.FROZEN), 8)
        self.assertEqual(script.CUTOFF, "2026-10-16 00:00:00+00")
        self.assertEqual(set(script.WRITE_COLUMN), {"itinerary_components", "tour_day", "tour_graph_build"})


class Verdict(unittest.TestCase):
    def test_clean_set_is_ready_for_both(self):
        rc, lines = _run(FakeConn())
        self.assertEqual(rc, 0)
        self.assertEqual(lines[-1], "SCRIPT verdict drop_ready=true revoke_ready=true reasons=-")
        self.assertEqual(sum(1 for ln in lines if ln.startswith("SCRIPT table ")), 8)
        self.assertIn("SCRIPT id_map rows=750 trip_events_with_old_ids=12 drafts_with_old_ids=4", lines)

    def test_a_write_after_the_cutoff_and_a_dependent_block_the_drop(self):
        rc, lines = _run(FakeConn(last_write=dt.datetime(2026, 10, 20, tzinfo=UTC), dependents=["public.reads"]))
        verdict = lines[-1]
        self.assertTrue(verdict.startswith("SCRIPT verdict drop_ready=false revoke_ready=true"))
        self.assertIn("write_after_cutoff:itinerary_components", verdict)
        self.assertIn("dependent:public.reads", verdict)

    def test_a_grant_not_by_the_owner_blocks_the_revoke(self):
        _, lines = _run(FakeConn(grantor_is_owner=False))
        self.assertIn("revoke_ready=false", lines[-1])
        self.assertTrue(any("grantor=aa_cis_admin by_owner=f" in ln for ln in lines))

    def test_an_already_dropped_table_is_reported_not_counted(self):
        _, lines = _run(FakeConn(missing={"tripplanner.tour_leg"}))
        self.assertIn("SCRIPT table name=tour_leg exists=f", lines)
        self.assertEqual(sum(1 for ln in lines if ln.startswith("SCRIPT table ") and "exists=t" in ln), 7)

    def test_output_has_no_row_values(self):
        _, lines = _run(FakeConn())
        self.assertTrue(all(ln.startswith("SCRIPT ") for ln in lines))


if __name__ == "__main__":
    unittest.main()
