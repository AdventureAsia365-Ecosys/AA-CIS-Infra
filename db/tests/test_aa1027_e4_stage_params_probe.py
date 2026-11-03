"""AA-1027 E4: db/scripts/aa1027_e4_stage_params_probe.py (the stage x model params row reaches the TripPlanner view,
rolled back).

No database: a fake connection answers the script's SQL and records whether the transaction committed. The SQL
itself ran on a local PostgreSQL 16 stand-in (stage_model_params, llm_role_config and a view of the 350 shape, a
tripplanner role the master may SET ROLE to) during S265: view_carries_params=true clean=true, no row left.
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
PATH = "db/scripts/aa1027_e4_stage_params_probe.py"
_spec = importlib.util.spec_from_file_location("aa1027_e4_stage_params_probe", ROOT / PATH)
script = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(script)


class FakeTx:
    def __init__(self, conn):
        self.conn = conn

    async def __aenter__(self):
        self.conn.in_tx = True
        return self

    async def __aexit__(self, exc_type, exc, tb):
        self.conn.in_tx = False
        if exc_type is None:
            self.conn.committed = True
        else:
            self.conn.rows = [r for r in self.conn.rows if r not in self.conn.pending]
        self.conn.pending = []
        return False


class FakeConn:
    def __init__(self, *, model="zz-writer", existing=None, can_set_role=True, view_drops_params=False,
                 view_denied_to_master=False):
        self.model, self.can_set_role, self.view_drops_params = model, can_set_role, view_drops_params
        self.view_denied_to_master = view_denied_to_master
        self.rows = [existing] if existing else []
        self.pending, self.in_tx, self.committed, self.role = [], False, False, "master"

    def transaction(self):
        return FakeTx(self)

    async def fetchval(self, sql, *args):
        if "FROM shared.llm_role_config" in sql:
            return self.model
        if "pg_has_role" in sql:
            return self.can_set_role
        if "updated_by = $1" in sql:
            return any(r["updated_by"] == args[0] for r in self.rows)
        if "FROM shared.stage_model_params" in sql:
            return any(r["stage"] == args[0] and r["model_key"] == args[1] for r in self.rows)
        raise AssertionError(f"unexpected fetchval: {sql[:80]}")

    async def execute(self, sql, *args):
        assert self.in_tx, "every write happens inside the transaction"
        if sql.startswith("SET LOCAL ROLE"):
            self.role = sql.split()[-1]
            return
        row = {"stage": args[0], "model_key": args[1], "temperature": args[2], "effort": args[3],
               "updated_by": args[4]}
        self.rows.append(row)
        self.pending.append(row)

    async def fetch(self, sql, *args):
        assert "catalog.v_llm_gateway_config_v1" in sql
        if self.role != "tripplanner" and self.view_denied_to_master:
            raise PermissionError("permission denied for view v_llm_gateway_config_v1")
        out = []
        for pos, key in ((0, self.model), (1, "zz-other")):
            r = next((x for x in self.rows if x["model_key"] == key), None)
            params = None if r is None or self.view_drops_params else {
                "max_tokens": None, "min_output_tokens": None, "temperature": r["temperature"], "effort": r["effort"],
                "reasoning_mode": None}
            out.append({"position": pos, "model_key": key, "supports_temperature": True,
                        "stage_params": json.dumps(params) if params is not None else None})
        return out


def _run(conn) -> tuple:
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = asyncio.run(script.main(conn))
    return rc, out.getvalue().splitlines()


class Shape(unittest.TestCase):
    def test_runner_accepts_the_script(self):
        source = (ROOT / PATH).read_text(encoding="utf-8")
        self.assertEqual(rm.script_errors(source, PATH), [])
        self.assertFalse(rm.script_is_read_only(source))

    def test_probe_values_fit_the_table_checks(self):
        self.assertTrue(0 <= script.PROBE_TEMPERATURE <= 2)
        self.assertIn(script.PROBE_EFFORT, ("low", "medium", "high", "xhigh", "max"))
        self.assertEqual(script.STAGE, "tp_compose")


class Probe(unittest.TestCase):
    def test_the_row_reaches_the_view_and_is_rolled_back(self):
        conn = FakeConn()
        rc, lines = _run(conn)
        self.assertEqual(rc, 0)
        self.assertFalse(conn.committed)
        self.assertEqual(conn.rows, [])
        self.assertIn("SCRIPT probe inserted=t", lines)
        self.assertTrue(any(ln.startswith("SCRIPT view read_as=tripplanner position=0 model=zz-writer") and
                            '"effort": "low"' in ln and '"temperature": 0.3' in ln for ln in lines), lines)
        self.assertIn("SCRIPT view read_as=tripplanner position=1 model=zz-other supports_temperature=t "
                      "stage_params=null", lines)
        self.assertEqual(lines[-1], "SCRIPT verdict view_carries_params=true clean=true")

    def test_a_view_without_the_params_fails_the_run(self):
        rc, lines = _run(FakeConn(view_drops_params=True))
        self.assertEqual(rc, 1)
        self.assertEqual(lines[-1], "SCRIPT verdict view_carries_params=false clean=true")

    def test_an_existing_row_is_read_not_overwritten(self):
        existing = {"stage": "tp_compose", "model_key": "zz-writer", "temperature": 0.9, "effort": "high",
                    "updated_by": "admin"}
        conn = FakeConn(existing=existing)
        rc, lines = _run(conn)
        self.assertEqual(rc, 0)
        self.assertIn("SCRIPT probe inserted=f", lines)
        self.assertEqual(conn.rows, [existing])

    def test_without_set_role_it_reads_as_the_master(self):
        _, lines = _run(FakeConn(can_set_role=False))
        self.assertTrue(any(ln.startswith("SCRIPT view read_as=master") for ln in lines))

    def test_an_unreadable_view_fails_the_run_and_still_rolls_back(self):
        conn = FakeConn(can_set_role=False, view_denied_to_master=True)
        rc, lines = _run(conn)
        self.assertEqual(rc, 1)
        self.assertIn("SCRIPT view read_as=master error=PermissionError", lines)
        self.assertEqual(conn.rows, [])
        self.assertEqual(lines[-1], "SCRIPT verdict view_carries_params=false clean=true")


if __name__ == "__main__":
    unittest.main()
