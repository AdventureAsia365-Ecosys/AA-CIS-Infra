"""Unit tests for db/check_rls_allowlist.py (AA-1112: a stale X2 RLS allowlist entry fails).

Run: python3 -m unittest discover -s db/tests -v
"""
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import check_rls_allowlist as cra  # noqa: E402
import rls_catalogue_rules as rls  # noqa: E402


def table(columns=("id",), rls_on=False, grants=()):
    return {"kind": "table", "rls": rls_on, "columns": [{"name": c} for c in columns], "policies": [],
            "constraints": [], "grants": list(grants), "column_grants": []}


def dump(relations):
    return {"format": 2, "schemas": [{"schema": s, "grants": []} for s in sorted(relations)],
            "relations": relations}


ALLOW = {"a": {"shared.kite_meter": "fixture: platform table", "shared.gone_table": "fixture: dropped since"},
         "g": {"shared.kite_meter:booking": "fixture: contract read"}}


class StaleEntriesTest(unittest.TestCase):
    def test_an_entry_that_matches_nothing_is_stale(self):
        d = dump({"shared": {"kite_meter": table(("id", "tenant_id"), grants=[{"grantee": "booking",
                                                                                "privileges": "SELECT"}])}})
        self.assertEqual(cra.stale_entries(d, ALLOW), [("a", "shared.gone_table")])

    def test_wildcard_entry_used_by_one_object_is_not_stale(self):
        d = dump({"shared": {"kite_meter": table(grants=[{"grantee": "booking", "privileges": "SELECT"}])}})
        self.assertEqual(cra.stale_entries(d, {"g": {"shared.*:booking": "fixture"}}), [])


class MainTest(unittest.TestCase):
    def run_main(self, payload, github_actions=""):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "schema.json"
            p.write_text(payload if isinstance(payload, str) else json.dumps(payload), encoding="utf-8")
            out = io.StringIO()
            with mock.patch.dict(os.environ, {"GITHUB_ACTIONS": github_actions}):
                code = cra.main([str(p)], out=out)
        return code, out.getvalue()

    def test_stale_entry_fails_and_names_the_file_to_edit(self):
        with mock.patch.object(rls, "ALLOWLIST", ALLOW):
            code, out = self.run_main(dump({"shared": {"kite_meter": table(
                ("id", "tenant_id"), grants=[{"grantee": "booking", "privileges": "SELECT"}])}}))
        self.assertEqual(code, 1, out)
        fails = [line for line in out.splitlines() if line.startswith("FAIL  ")]
        self.assertEqual(len(fails), 1, out)
        self.assertIn("[a] shared.gone_table", fails[0])
        self.assertIn("AA-CIS-App tests/integration/rls_catalogue_rules.py", fails[0])
        self.assertIn("db/rls_catalogue_rules.py", fails[0])
        self.assertIn("3 allowlist entry(ies), 1 stale", out)
        self.assertNotIn("::error", out)

    def test_github_actions_adds_one_annotation_per_stale_entry(self):
        with mock.patch.object(rls, "ALLOWLIST", ALLOW):
            code, out = self.run_main(dump({"shared": {}}), github_actions="true")
        self.assertEqual(code, 1)
        notes = [line for line in out.splitlines() if line.startswith("::error file=db/rls_catalogue_rules.py::")]
        self.assertEqual(len(notes), 3, out)

    def test_no_stale_entry_passes(self):
        with mock.patch.object(rls, "ALLOWLIST", {"a": {"shared.kite_meter": "fixture"}}):
            code, out = self.run_main(dump({"shared": {"kite_meter": table(("id", "tenant_id"))}}))
        self.assertEqual(code, 0, out)
        self.assertIn("1 allowlist entry(ies), 0 stale", out)

    def test_unreadable_or_wrong_format_dump_fails_closed(self):
        self.assertEqual(self.run_main("not json")[0], 2)
        self.assertEqual(self.run_main({"format": 1})[0], 2)
        self.assertEqual(self.run_main([1, 2])[0], 2)


class WorkflowTest(unittest.TestCase):
    def test_copy_guard_runs_the_stale_check_on_the_latest_dump(self):
        root = Path(__file__).resolve().parent.parent.parent
        wf = (root / ".github" / "workflows" / "migration-copy-guard.yml").read_text(encoding="utf-8")
        job = wf.split("\n  retention-rows:\n", 1)[1].split("\n  classify:\n", 1)[0]
        self.assertIn("python3 db/check_rls_allowlist.py dump/schema.json", job)
        self.assertIn("--workflow db-schema-dump.yml --branch main --status success", job)
        self.assertIn("actions: read", job)


if __name__ == "__main__":
    unittest.main()
