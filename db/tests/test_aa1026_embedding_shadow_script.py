"""AA-1026 D5: db/scripts/aa1026_embedding_shadow.py — the owner steps of a re-embed (prepare, drop shadow, swap,
rollback, status) around the CIS migration 341 functions.

Shape (the runner's own checks), merged defaults (DRY RUN, status) and every action against a fake connection that
records SQL: a write action runs as cis_owner inside a transaction that a dry run rolls back.
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
SCRIPT = "db/scripts/aa1026_embedding_shadow.py"


def _load():
    spec = importlib.util.spec_from_file_location(Path(SCRIPT).stem, ROOT / SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class FakeTx:
    def __init__(self, conn, readonly=False):
        self.conn, self.readonly = conn, readonly

    async def start(self):
        self.conn.log.append("BEGIN READ ONLY" if self.readonly else "BEGIN")

    async def commit(self):
        self.conn.log.append("COMMIT")

    async def rollback(self):
        self.conn.log.append("ROLLBACK")

    async def __aenter__(self):
        await self.start()
        return self

    async def __aexit__(self, *a):
        await self.commit()
        return False


class FakeConn:
    def __init__(self, registered=True):
        self.registered, self.log = registered, []

    def transaction(self, readonly=False):
        return FakeTx(self, readonly)

    async def execute(self, sql, *args):
        self.log.append(sql)

    async def fetchrow(self, sql, *args):
        self.log.append(sql)
        return {"swap_group": "f10_embed"} if self.registered else None

    async def fetch(self, sql, *args):
        self.log.append(sql)
        return [{"table_schema": "acp_contract", "table_name": "question_embedding", "column_name": "embedding",
                 "space_key": "cohere-embed-v4/1536/v1", "shadow_column": "embedding__shadow",
                 "shadow_space_key": "titan-embed-text-v2/1024/v1", "previous_column": None,
                 "previous_space_key": None}]

    async def fetchval(self, sql, *args):
        self.log.append((sql, args) if "shared.embedding_" in sql and "SELECT shared." in sql else sql)
        if "swap_group FROM" in sql:
            return "f10_embed"
        return 7 if "count(*)" in sql else "ok"


def _run(coro):
    with contextlib.redirect_stdout(io.StringIO()) as buf:
        code = asyncio.run(coro)
    return code, buf.getvalue()


class ShapeTest(unittest.TestCase):
    def test_runner_shape_and_merged_defaults(self):
        source = (ROOT / SCRIPT).read_text()
        self.assertEqual(rm.script_errors(source, SCRIPT), [])
        self.assertFalse(rm.script_is_read_only(source))
        mod = _load()
        self.assertEqual((mod.MODE, mod.ACTION), ("dry_run", "status"))
        self.assertNotIn("embedding_drop_previous(", source.split('"""', 2)[2])   # destructive: not offered


class ActionTest(unittest.TestCase):
    def test_status_reads_only(self):
        conn = FakeConn()
        code, out = _run(_load().run(conn, "apply", "status"))
        self.assertEqual(code, 0)
        self.assertEqual(conn.log[0], "BEGIN READ ONLY")
        self.assertNotIn("SET LOCAL ROLE cis_owner", conn.log)
        self.assertIn("SCRIPT column group=f10_embed", out)
        self.assertIn("without_shadow_vector=7", out)

    def test_dry_run_prepare_runs_as_cis_owner_and_rolls_back(self):
        conn = FakeConn()
        code, out = _run(_load().run(conn, "dry_run", "prepare"))
        self.assertEqual(code, 0)
        self.assertIn("SET LOCAL ROLE cis_owner", conn.log)
        calls = [c for c in conn.log if isinstance(c, tuple)]
        self.assertEqual(calls, [("SELECT shared.embedding_prepare_shadow($1, $2, $3, $4)",
                                  ("acp_contract", "question_embedding", "embedding", "titan-embed-text-v2/1024/v1"))])
        self.assertEqual(conn.log[-1], "ROLLBACK")
        self.assertNotIn("COMMIT", conn.log)
        self.assertIn("SCRIPT rolled_back", out)

    def test_apply_swap_and_drop_shadow_commit(self):
        for action, sql, args in (("swap", "SELECT shared.embedding_swap($1, $2)", ("f10_embed", False)),
                                  ("rollback", "SELECT shared.embedding_rollback($1, $2)", ("f10_embed", False)),
                                  ("drop_shadow", "SELECT shared.embedding_drop_shadow($1, $2, $3)",
                                   ("acp_contract", "question_embedding", "embedding"))):
            conn = FakeConn()
            code, _ = _run(_load().run(conn, "apply", action))
            self.assertEqual(code, 0, action)
            self.assertIn((sql, args), conn.log, action)
            self.assertEqual(conn.log[-1], "COMMIT", action)

    def test_refusals(self):
        code, out = _run(_load().run(FakeConn(), "apply", "drop_previous"))
        self.assertEqual(code, 1)
        self.assertIn("SCRIPT refuse", out)
        conn = FakeConn(registered=False)
        code, out = _run(_load().run(conn, "apply", "prepare"))
        self.assertEqual(code, 1)
        self.assertEqual(conn.log[-1], "ROLLBACK")
        with self.assertRaises(ValueError):
            _load().split_column("acp_contract.question_embedding")


if __name__ == "__main__":
    unittest.main()
