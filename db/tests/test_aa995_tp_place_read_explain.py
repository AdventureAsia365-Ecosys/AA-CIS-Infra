"""AA-995 follow-up (S257): db/scripts/aa995_tp_place_read_explain.py (read-only TripPlanner place-read probe)."""

import importlib.util
import io
import json
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PATH = "db/scripts/aa995_tp_place_read_explain.py"
_spec = importlib.util.spec_from_file_location("aa995_tp_place_read_explain", ROOT / PATH)
mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mod)


class ShapeTest(unittest.TestCase):
    def test_runner_shape_check_accepts_it(self):
        out = subprocess.run([sys.executable, "db/run_migration.py", "--inspect-script", PATH], cwd=ROOT,
                             capture_output=True, text=True)
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.assertEqual(json.loads(out.stdout.strip().splitlines()[-1])["errors"], [])

    def test_read_only(self):
        self.assertIs(mod.READ_ONLY, True)


class SqlTest(unittest.TestCase):
    def test_readers_are_tripplanners_view_reads_by_tour_id_array(self):
        for name, sql in mod.TP_READERS.items():
            self.assertIn("FROM catalog.v_tour_place p", sql, name)
            self.assertIn("p.tour_id = ANY($1::uuid[])", sql, name)

    def test_master_bodies_read_no_internal_catalog_view(self):
        # The master may not read catalog_owner's internal views: they are inlined.
        for label, body in mod.BODIES.items():
            self.assertNotIn("catalog._live_tour", body, label)
            self.assertNotIn("catalog._tour_day_text", body, label)
            self.assertNotIn("@@", body, label)
            self.assertIn("gold_aa_internal.published_tours", body, label)
        self.assertIn("geo.name_norm(gp.name) = g.place_norm", mod.BODIES["cand_a"])
        self.assertIn("gp.name_norm = g.place_norm", mod.BODIES["cand_b"])
        self.assertIn("seg ON true", mod.BODIES["old_inline"])
        self.assertNotIn("tour_segment", mod.BODIES["cand_a"])

    def test_every_reader_column_exists_in_the_candidate(self):
        for reader, cols in mod.PARITY_COLS.items():
            for c in cols:
                self.assertTrue(f" AS {c}" in mod.CAND_BODY or f"g.{c}" in mod.CAND_BODY or f"d.{c}" in mod.CAND_BODY,
                                f"{reader}: {c}")

    def test_uuid_literal_refuses_anything_but_uuids(self):
        ok = "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
        self.assertEqual(mod._uuid_array_literal([ok]), "'{" + ok + "}'::uuid[]")
        with self.assertRaises(ValueError):
            mod._uuid_array_literal(["x'); DROP TABLE t; --"])

    def test_modes_cover_custom_generic_with_and_without_jit(self):
        self.assertEqual({(p, j) for _, p, j in mod.MODES},
                         {("force_custom_plan", "on"), ("force_generic_plan", "on"),
                          ("force_custom_plan", "off"), ("force_generic_plan", "off")})


class ExplainSummaryTest(unittest.TestCase):
    def test_self_time_buffers_and_jit(self):
        doc = [{"Plan": {"Node Type": "Nested Loop", "Actual Total Time": 10.0, "Actual Loops": 1, "Actual Rows": 5,
                         "Shared Hit Blocks": 100, "Shared Read Blocks": 2, "Temp Written Blocks": 0,
                         "Plans": [{"Node Type": "Index Scan", "Relation Name": "tour_place", "Actual Total Time": 0.5,
                                    "Actual Loops": 12, "Actual Rows": 1}]},
                "Planning Time": 1.25, "Execution Time": 10.5,
                "JIT": {"Functions": 125, "Timing": {"Total": 55.5}}}]
        s = mod._explain_summary(doc)
        self.assertEqual((s["exec_ms"], s["plan_ms"], s["hit"], s["read"], s["jit_ms"], s["jit_functions"]),
                         (10.5, 1.2, 100, 2, 55.5, 125))
        self.assertEqual(s["top"][0][1:3], ("Index Scan", "tour_place"))  # 6.0 ms self (12 loops) beats 4.0
        self.assertEqual(s["top"][0][0], 6.0)

    def test_row_key_is_order_free_for_arrays(self):
        a = {"x": ["b", "a"], "y": 1.0000000001}
        b = {"x": ["a", "b"], "y": 1.0}
        self.assertEqual(mod._row_key(a, ("x", "y")), mod._row_key(b, ("x", "y")))


if __name__ == "__main__":
    unittest.main()
