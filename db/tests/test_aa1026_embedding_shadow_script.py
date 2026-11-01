"""AA-1026 D5: db/scripts/aa1026_embedding_shadow.py — the owner steps of a re-embed (prepare, drop shadow, swap,
rollback, purge of blank cache rows, status).

Shape (the runner's own checks), merged defaults (DRY RUN, status) and the actions against a fake connection that
records SQL: a write action runs as cis_owner inside a transaction that a dry run rolls back. The DDL itself (swap,
rollback, view rebuild, trigger) runs on a real PostgreSQL in test_aa1026_embedding_shadow_script_pg.py (local only).
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
    """Answers the script's catalog and registry reads with one registered column of group f10_embed (no shadow unless
    `shadow`); records every SQL statement."""

    def __init__(self, registered=True, shadow=False):
        self.registered, self.shadow, self.log = registered, shadow, []

    def _registry(self):
        return {"table_schema": "acp_contract", "table_name": "question_embedding", "column_name": "embedding",
                "space_key": "cohere-embed-v4/1536/v1", "swap_group": "f10_embed",
                "shadow_column": "embedding__shadow" if self.shadow else None,
                "shadow_space_key": "titan-embed-text-v2/1024/v1" if self.shadow else None,
                "previous_column": None, "previous_space_key": None}

    def transaction(self, readonly=False):
        return FakeTx(self, readonly)

    async def execute(self, sql, *args):
        self.log.append(sql)

    async def fetchrow(self, sql, *args):
        self.log.append(sql)
        if not self.registered:
            return None
        if "FROM shared.embedding_space" in sql:
            return {"dimension": 1024, "status": "standby"}
        return self._registry()

    async def fetch(self, sql, *args):
        self.log.append(sql)
        if "FROM pg_attribute" in sql:
            cols = [{"attname": "embedding", "attnum": 3, "attnotnull": True, "typ": "vector(1536)"}]
            if self.shadow:
                cols.append({"attname": "embedding__shadow", "attnum": 4, "attnotnull": False, "typ": "vector(1024)"})
            return cols
        if "FROM pg_index" in sql or "pg_depend" in sql:
            return []
        return [self._registry()]

    async def fetchval(self, sql, *args):
        self.log.append(sql)
        if "swap_group FROM" in sql:
            return "f10_embed"
        if "SELECT dimension FROM" in sql:
            return 1024
        if "IS NULL" in sql and ("to_regprocedure" in sql or "to_regtype" in sql):
            return False                                   # 329 applied, pgvector installed
        if "FROM pg_trigger" in sql:
            return False
        if "SELECT shadow_column FROM" in sql:
            return "embedding__shadow" if self.shadow else None
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
        self.assertEqual((mod.MODE, mod.ACTION, mod.ALLOW_MISSING, mod.SHADOW_TYPE), ("dry_run", "status", False, None))
        self.assertEqual(mod.WRITE_ROLE, "cis_owner")
        code = source.split('"""', 2)[2]
        # the old vectors are dropped by a destructive cis/ migration (snapshot first), never by this script
        self.assertNotIn("drop_previous", code)
        self.assertNotRegex(code, r"DROP COLUMN \{_q\(c\[.previous_column.\]")
        # the only role switch is the literal SET LOCAL ROLE to WRITE_ROLE at the start of the transaction
        self.assertEqual(code.count("SET LOCAL ROLE"), 1)
        self.assertIn('f"SET LOCAL ROLE {WRITE_ROLE}"', code)
        # the CIS SQL functions of the first 329 draft are gone: everything runs here
        self.assertNotRegex(code, r"shared\.embedding_(swap|rollback|prepare_shadow|drop_shadow)\(")

    def test_identifiers_and_column_split(self):
        mod = _load()
        self.assertEqual(mod._q('a"b'), '"a""b"')
        self.assertEqual(mod._lit("it's"), "'it''s'")
        self.assertEqual(mod.split_column("acp_contract.question_embedding.embedding"),
                         ("acp_contract", "question_embedding", "embedding"))
        for bad in ("acp_contract.question_embedding", "a.b.c;drop", "a.b.c.d"):
            with self.assertRaises(ValueError):
                mod.split_column(bad)
        with self.assertRaises(mod.Refused):
            mod._name_fits("x" * 64, "index")


class ActionTest(unittest.TestCase):
    def test_status_reads_only(self):
        conn = FakeConn()
        code, out = _run(_load().run(conn, "apply", "status"))
        self.assertEqual(code, 0)
        self.assertEqual(conn.log[0], "BEGIN READ ONLY")
        self.assertNotIn("SET LOCAL ROLE cis_owner", conn.log)
        self.assertIn("SCRIPT column group=f10_embed", out)
        self.assertNotIn("without_shadow_vector=7", out)                 # no shadow: nothing to count

    def test_dry_run_prepare_runs_as_cis_owner_and_rolls_back(self):
        conn = FakeConn()
        code, out = _run(_load().run(conn, "dry_run", "prepare"))
        self.assertEqual(code, 0, out)
        self.assertEqual(conn.log[1], "SET LOCAL ROLE cis_owner")
        self.assertIn('ALTER TABLE "acp_contract"."question_embedding" ADD COLUMN "embedding__shadow" vector(1024)',
                      conn.log)
        trigger = [c for c in conn.log if isinstance(c, str) and c.startswith("CREATE TRIGGER")]
        self.assertEqual(len(trigger), 1)
        self.assertIn('"embedding__shadow_reset" BEFORE UPDATE OF "embedding"', trigger[0])
        self.assertIn("EXECUTE FUNCTION shared._embedding_shadow_reset('embedding__shadow')", trigger[0])
        self.assertTrue(any(isinstance(c, str) and c.startswith("UPDATE shared.embedding_column SET shadow_column")
                            for c in conn.log))
        self.assertIn("SCRIPT ddl sql=ALTER TABLE", out)
        self.assertIn("SCRIPT done action=prepare result=embedding__shadow", out)
        self.assertEqual(conn.log[-1], "ROLLBACK")
        self.assertNotIn("COMMIT", conn.log)
        self.assertIn("SCRIPT rolled_back", out)

    def test_apply_drop_shadow_commits(self):
        conn = FakeConn(shadow=True)
        code, out = _run(_load().run(conn, "apply", "drop_shadow"))
        self.assertEqual(code, 0, out)
        self.assertIn('ALTER TABLE "acp_contract"."question_embedding" DROP COLUMN "embedding__shadow"', conn.log)
        self.assertEqual(conn.log[-1], "COMMIT")

    def test_swap_refuses_rows_without_a_shadow_vector(self):
        conn = FakeConn(shadow=True)                       # the fake counts 7 rows still without a shadow vector
        code, out = _run(_load().run(conn, "apply", "swap"))
        self.assertEqual(code, 1)
        self.assertIn("7 row(s) have a vector but no shadow vector", out)
        self.assertFalse(any(isinstance(c, str) and ("RENAME" in c or "DROP VIEW" in c) for c in conn.log))
        self.assertNotIn("COMMIT", conn.log)
        self.assertEqual(conn.log[-1], "ROLLBACK")

    def test_swap_without_a_shadow_and_rollback_without_previous_refuse(self):
        for action, why in (("swap", "prepare and fill it first"), ("rollback", "nothing to roll back")):
            conn = FakeConn()
            code, out = _run(_load().run(conn, "apply", action))
            self.assertEqual(code, 1, action)
            self.assertIn(why, out)
            self.assertEqual(conn.log[-1], "ROLLBACK")

    def test_purge_blank_deletes_only_the_expected_cache_rows(self):
        mod = _load()
        mod.EXPECT_BLANK = 7                                   # the fake DELETE ... count(*) answers 7
        conn = FakeConn(shadow=True)
        code, out = _run(mod.run(conn, "apply", "purge_blank"))
        self.assertEqual(code, 0, out)
        delete = [c for c in conn.log if isinstance(c, str) and c.startswith("WITH d AS (DELETE")]
        self.assertEqual(len(delete), 1)
        self.assertIn("FROM acp_contract.question_embedding t", delete[0])
        self.assertIn("t.embedding__shadow IS NULL", delete[0])
        self.assertIn("SCRIPT done action=purge_blank result=7", out)
        self.assertEqual(conn.log[-1], "COMMIT")

        mod.COLUMN = "acp_contract.atom_embedding.embedding"
        conn = FakeConn(shadow=True)
        code, _ = _run(mod.run(conn, "dry_run", "purge_blank"))
        self.assertEqual(code, 0)
        delete = [c for c in conn.log if isinstance(c, str) and c.startswith("WITH d AS (DELETE")][0]
        self.assertIn("NOT EXISTS (SELECT 1 FROM acp_contract.tour_atoms a", delete)
        self.assertEqual(conn.log[-1], "ROLLBACK")

    def test_purge_blank_refusals_roll_back(self):
        for column, expect, shadow, why in (
                ("acp_contract.question_embedding.embedding", 3, True, "nothing deleted"),
                ("acp_contract.question_embedding.embedding", None, True, "set EXPECT_BLANK"),
                ("acp_contract.question_embedding.embedding", 7, False, "has no shadow column"),
                ("acp_shared.content_piece.content_embedding", 7, True, "not an embedding cache")):
            mod = _load()
            mod.COLUMN, mod.EXPECT_BLANK = column, expect
            conn = FakeConn(shadow=shadow)
            code, out = _run(mod.run(conn, "apply", "purge_blank"))
            self.assertEqual(code, 1, why)
            self.assertIn(why, out)
            self.assertNotIn("COMMIT", conn.log)
            self.assertEqual(conn.log[-1], "ROLLBACK")

    def test_refusals(self):
        code, out = _run(_load().run(FakeConn(), "apply", "drop_previous"))
        self.assertEqual(code, 1)
        self.assertIn("SCRIPT refuse", out)
        conn = FakeConn(registered=False)
        code, out = _run(_load().run(conn, "apply", "prepare"))
        self.assertEqual(code, 1)
        self.assertEqual(conn.log[-1], "ROLLBACK")
        mod = _load()
        mod.SHADOW_TYPE = "text; select 1"
        code, out = _run(mod.run(FakeConn(), "apply", "prepare"))
        self.assertEqual(code, 1)
        self.assertIn("bad column type", out)


if __name__ == "__main__":
    unittest.main()
