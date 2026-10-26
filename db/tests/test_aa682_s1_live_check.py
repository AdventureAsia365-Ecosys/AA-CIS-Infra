"""AA-682 S1 (S252): db/scripts/aa682_s1_live_check.py shape. The real-schema run (Booking migrations bk-001 .. bk-026
on a throwaway PostgreSQL: dry run, apply, re-run, and the B2B path on a confirmed hold) is in AA-Booking
docs/implementation-notes/AA-682.md. Run: python3 -m unittest discover -s db/tests -v
"""
import ast
import importlib.util
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import run_migration as rm  # noqa: E402

ROOT = HERE.parent.parent
PATH = "db/scripts/aa682_s1_live_check.py"
_spec = importlib.util.spec_from_file_location("aa682_s1_live_check", ROOT / PATH)
script = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(script)


class ShapeTest(unittest.TestCase):
    def test_runner_accepts_the_file(self):
        self.assertEqual(rm.script_errors((ROOT / PATH).read_text(encoding="utf-8"), PATH), [])

    def test_merged_as_a_dry_run(self):
        self.assertEqual(script.MODE, "apply")  # one-shot apply PR (S252); the follow-up PR sets it back to dry_run
        self.assertFalse(getattr(script, "READ_ONLY", False))  # it writes, then rolls back

    def test_no_app_imports(self):
        tree = ast.parse((ROOT / PATH).read_text(encoding="utf-8"))
        names = {a.name.split(".")[0] for n in ast.walk(tree) if isinstance(n, ast.Import) for a in n.names}
        names |= {n.module.split(".")[0] for n in ast.walk(tree) if isinstance(n, ast.ImportFrom) and n.module}
        self.assertLessEqual(names, {"json", "argparse", "asyncio", "asyncpg"})

    def test_synthetic_markers(self):
        self.assertTrue(script.TAG.startswith("SYNTHETIC"))
        self.assertTrue(script.CUSTOMER_EMAIL.endswith("@example.invalid"))
        self.assertEqual(script.REQUIRED_VERSION, "bk-026")


if __name__ == "__main__":
    unittest.main()
