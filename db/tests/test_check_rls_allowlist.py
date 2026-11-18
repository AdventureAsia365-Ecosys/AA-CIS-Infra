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


class AddedEntryTest(unittest.TestCase):
    """Review S284: a PR that adds an entry for an object whose migration is not applied on Dev yet must not go red."""

    BASE = {"a": {"shared.kite_meter": "fixture: platform table"}, "g": {}}
    HEAD = {"a": {"shared.kite_meter": "fixture: platform table", "shared.lantern_queue": "fixture: new, not applied"},
            "g": {}}

    def test_an_added_entry_whose_object_is_missing_is_not_stale(self):
        d = dump({"shared": {"kite_meter": table(("id", "tenant_id"))}})
        self.assertEqual(cra.stale_entries(d, self.HEAD), [("a", "shared.lantern_queue")])
        self.assertEqual(cra.stale_entries(d, self.HEAD, base=self.BASE), [])
        self.assertEqual(cra.added_entries(self.HEAD, self.BASE), [("a", "shared.lantern_queue")])

    def test_an_entry_already_on_the_base_still_fails(self):
        d = dump({"shared": {}})
        self.assertEqual(cra.stale_entries(d, self.HEAD, base=self.BASE), [("a", "shared.kite_meter")])

    def test_a_removed_entry_is_not_reported(self):
        d = dump({"shared": {"kite_meter": table(("id", "tenant_id"))}})
        self.assertEqual(cra.stale_entries(d, self.BASE, base=self.HEAD), [])
        self.assertEqual(cra.added_entries(self.BASE, self.HEAD), [])


def write_rules(tmp: str, allowlist: dict) -> str:
    """A stand-in for the rules file at the base commit: only ALLOWLIST is read from it."""
    p = Path(tmp) / "rls_catalogue_rules_base.py"
    p.write_text(f"ALLOWLIST = {allowlist!r}\n", encoding="utf-8")
    return str(p)


class MainTest(unittest.TestCase):
    def run_main(self, payload, github_actions="", base=None):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "schema.json"
            p.write_text(payload if isinstance(payload, str) else json.dumps(payload), encoding="utf-8")
            argv = [str(p)]
            if base is not None:
                argv += ["--base", base if isinstance(base, str) else write_rules(tmp, base)]
            out = io.StringIO()
            with mock.patch.dict(os.environ, {"GITHUB_ACTIONS": github_actions}):
                code = cra.main(argv, out=out)
        return code, out.getvalue()

    def test_base_skips_the_entries_the_pr_adds(self):
        with mock.patch.object(rls, "ALLOWLIST", ALLOW):
            code, out = self.run_main(dump({"shared": {"kite_meter": table(
                ("id", "tenant_id"), grants=[{"grantee": "booking", "privileges": "SELECT"}])}}),
                base={"a": {"shared.kite_meter": "x"}, "g": {"shared.kite_meter:booking": "x"}})
        self.assertEqual(code, 0, out)
        self.assertIn("SKIP  [a] shared.gone_table: added by this pull request", out)
        self.assertIn("3 allowlist entry(ies), 0 stale", out)

    def test_base_still_fails_a_stale_entry_the_base_had(self):
        with mock.patch.object(rls, "ALLOWLIST", ALLOW):
            code, out = self.run_main(dump({"shared": {}}), base=ALLOW)
        self.assertEqual(code, 1, out)
        self.assertNotIn("SKIP", out)
        self.assertIn("3 allowlist entry(ies), 3 stale", out)

    def test_unreadable_base_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            missing = str(Path(tmp) / "nope.py")
            no_allowlist = Path(tmp) / "empty.py"
            no_allowlist.write_text("X = 1\n", encoding="utf-8")
            self.assertEqual(self.run_main(dump({"shared": {}}), base=missing)[0], 2)
            self.assertEqual(self.run_main(dump({"shared": {}}), base=str(no_allowlist))[0], 2)

    def test_the_real_base_file_loads_without_touching_the_imported_copy(self):
        real = Path(cra.__file__).resolve().parent / "rls_catalogue_rules.py"
        before = rls.ALLOWLIST
        self.assertEqual(cra.load_allowlist(real), rls.ALLOWLIST)
        self.assertIs(rls.ALLOWLIST, before)

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

    def test_stale_step_on_pull_request_runs_only_for_allowlist_changes_and_skips_added_entries(self):
        # Review S284: db/migration_sync.py merge-check refuses a copy PR on ANY failed check, so a result that depends
        # on Dev (not on the PR) must not run on a migration copy PR.
        root = Path(__file__).resolve().parent.parent.parent
        wf = (root / ".github" / "workflows" / "migration-copy-guard.yml").read_text(encoding="utf-8")
        job = wf.split("\n  retention-rows:\n", 1)[1].split("\n  classify:\n", 1)[0]
        step = job.split("- name: RLS allowlist has no stale entry", 1)[1]
        self.assertIn('git diff --name-only "$BASE_SHA"...HEAD -- db/rls_catalogue_rules.py db/check_rls_allowlist.py', step)
        self.assertIn('if [ -z "$CHANGED" ]; then', step)
        self.assertIn('git show "$BASE_SHA:db/rls_catalogue_rules.py"', step)
        self.assertIn('"${BASE_ARGS[@]}"', step)
        self.assertIn("fetch-depth: 0", job)


if __name__ == "__main__":
    unittest.main()
