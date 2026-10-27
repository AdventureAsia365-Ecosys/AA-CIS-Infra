"""AA-993 G4/G5 live-proof run-scripts: db/scripts/aa993_g4_bk_noop_enqueue.py, aa993_g4_bk_noop_report.py,
aa993_g5_gate_proof_rows.py.

Shape (the runner's own checks), merged defaults (DRY RUN / READ ONLY) and the dry-run path against a fake connection
that records SQL: the write scripts insert inside a transaction that is rolled back, as their owner role.
Run: python3 -m unittest discover -s db/tests -v
"""
import asyncio
import contextlib
import importlib.util
import io
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import run_migration as rm  # noqa: E402

ROOT = HERE.parent.parent
ENQUEUE = "db/scripts/aa993_g4_bk_noop_enqueue.py"
REPORT = "db/scripts/aa993_g4_bk_noop_report.py"
SEED = "db/scripts/aa993_g5_gate_proof_rows.py"


def _load(path):
    spec = importlib.util.spec_from_file_location(Path(path).stem, ROOT / path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class FakeTx:
    def __init__(self, conn):
        self.conn = conn

    async def start(self):
        self.conn.log.append("BEGIN")

    async def commit(self):
        self.conn.log.append("COMMIT")

    async def rollback(self):
        self.conn.log.append("ROLLBACK")


class FakeConn:
    def __init__(self, active=()):
        self.active, self.log = list(active), []

    def transaction(self):
        return FakeTx(self)

    async def execute(self, sql, *args):
        self.log.append(sql)

    async def fetch(self, sql, *args):
        self.log.append(sql)
        return self.active if "status IN ('queued', 'running')" in sql else []

    async def fetchval(self, sql, *args):
        self.log.append(sql)
        if "INSERT INTO" in sql:
            return "00000000-0000-0000-0000-0000000000a1"
        return len(self.active) if "count(*)" in sql and "created_by" in sql else 1

    async def fetchrow(self, sql, *args):
        self.log.append(sql)
        if "INSERT INTO" in sql:
            return {"id": "00000000-0000-0000-0000-0000000000b1", "status": "running", "lease_until": "00:10:00"}
        return {"status": "queued", "attempt": 0, "max_attempts": 1, "slept": None, "locked": False}


def _run(coro):
    with contextlib.redirect_stdout(io.StringIO()) as buf:
        code = asyncio.run(coro)
    return code, buf.getvalue()


class ShapeTest(unittest.TestCase):
    def test_runner_shape_and_merged_defaults(self):
        for path in (ENQUEUE, REPORT, SEED):
            source = (ROOT / path).read_text()
            self.assertEqual(rm.script_errors(source, path), [], path)
        self.assertTrue(rm.script_is_read_only((ROOT / REPORT).read_text()))
        self.assertFalse(rm.script_is_read_only((ROOT / ENQUEUE).read_text()))
        self.assertEqual(_load(ENQUEUE).MODE, "dry_run")
        self.assertEqual(_load(SEED).MODE, "dry_run")


class EnqueueTest(unittest.TestCase):
    def test_dry_run_inserts_as_bk_owner_and_rolls_back(self):
        conn = FakeConn()
        code, out = _run(_load(ENQUEUE).run(conn, "dry_run"))
        self.assertEqual(code, 0)
        self.assertIn("SET LOCAL ROLE bk_owner", conn.log)
        self.assertTrue(any("INSERT INTO booking.job" in s for s in conn.log))
        self.assertEqual(conn.log[-1], "ROLLBACK")
        self.assertNotIn("COMMIT", conn.log)
        self.assertIn("SCRIPT queued", out)

    def test_refuses_while_a_proof_job_is_active(self):
        conn = FakeConn(active=[{"id": "x", "status": "running"}])
        code, out = _run(_load(ENQUEUE).run(conn, "apply"))
        self.assertEqual(code, 1)
        self.assertIn("SCRIPT refuse", out)
        self.assertFalse(any("INSERT INTO" in s for s in conn.log))
        self.assertEqual(conn.log[-1], "ROLLBACK")


class SeedTest(unittest.TestCase):
    def test_dry_run_seeds_both_tables_as_their_owners_and_rolls_back(self):
        conn = FakeConn()
        code, out = _run(_load(SEED).run(conn, "dry_run"))
        self.assertEqual(code, 0)
        self.assertIn("SET LOCAL ROLE bk_owner", conn.log)
        self.assertIn("SET LOCAL ROLE crm_owner", conn.log)
        inserts = [s for s in conn.log if "INSERT INTO" in s]
        self.assertEqual(len(inserts), 2)
        for sql in inserts:  # inert rows: running, cancel requested, never re-queued by the reaper
            self.assertIn("'running', 1, 1", sql)
            self.assertIn("true", sql)
        self.assertEqual(conn.log.count("ROLLBACK"), 2)
        self.assertNotIn("COMMIT", conn.log)
        self.assertIn("kind=bk_retention_job", out)
        self.assertIn("kind=crm_dispatch", out)


if __name__ == "__main__":
    unittest.main()
