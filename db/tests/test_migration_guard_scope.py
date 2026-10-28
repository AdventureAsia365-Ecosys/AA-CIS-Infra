"""Unit tests for db/migration_guard_scope.py (AA-993 I1). No network.

Run: python3 -m unittest discover -s db/tests -v
"""
import json
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "db"))

import migration_guard_scope as scope  # noqa: E402


class MatchTests(unittest.TestCase):
    def test_migration_file_is_relevant(self):
        self.assertTrue(scope.relevant(["db/migrations/cis/293_x.sql"]))
        self.assertTrue(scope.relevant(["db/migrations/booking/nested/a.sql"]))

    def test_runner_and_workflows_are_relevant(self):
        for p in ("db/run_migration.py", ".github/scripts/migrator-task.sh",
                  ".github/workflows/db-migrate.yml", "db/tests/test_run_migration.py",
                  "db/migration_guard_scope.py"):
            self.assertTrue(scope.relevant([p]), p)

    def test_unrelated_paths_are_not(self):
        for p in ("accounts/aa365/cicd_split.tf", "README.md", "docs/x.md", "db/README.md",
                  "db/migrationsX/a.sql", ".github/workflows/terraform-plan.yml", "modules/vpc/main.tf",
                  "tools/github/db_auto_apply_gate.sh"):
            self.assertFalse(scope.relevant([p]), p)

    def test_single_star_stays_in_one_segment(self):
        rx = scope._glob_to_re("db/*.py")
        self.assertTrue(rx.match("db/a.py"))
        self.assertFalse(rx.match("db/tests/a.py"))

    def test_empty_list_is_not_relevant(self):
        self.assertFalse(scope.relevant([]))
        self.assertFalse(scope.relevant([""]))


class AgreementTests(unittest.TestCase):
    """The pre-push hook's migration-guard list and this module's PATHS stay the same list."""

    def test_pre_push_hook_lists_the_same_paths(self):
        text = (ROOT / "scripts" / "pre-push.sh").read_text(encoding="utf-8")
        block = re.search(r"migration-guard\) # migration-copy-guard\.yml\n(.*?);;", text, re.S)
        self.assertIsNotNone(block, "migration-guard case not found in scripts/pre-push.sh")
        hook = set(re.findall(r"'([^']+)'", block.group(1))) - {r"%s\n"}
        self.assertEqual(hook, set(scope.PATHS))

    def test_workflow_has_no_paths_filter_on_pull_request(self):
        wf = (ROOT / ".github" / "workflows" / "migration-copy-guard.yml").read_text(encoding="utf-8")
        on_block = wf[wf.index("\non:\n"):wf.index("\njobs:\n")]
        pr_block = on_block[on_block.index("pull_request:"):on_block.index("schedule:")]
        self.assertNotIn("paths:", pr_block)

    def test_guard_jobs_fail_closed_when_scope_fails(self):
        """Review S255: a job that needs a failed `scope` is skipped, and a skipped job passes a required check. The
        guard jobs must run unless scope said relevant=false explicitly."""
        wf = (ROOT / ".github" / "workflows" / "migration-copy-guard.yml").read_text(encoding="utf-8")
        conds = re.findall(r"^    needs: scope\n(?:    #.*\n)*    if: (.+)$", wf, re.M)
        self.assertEqual(len(conds), 3, "guard, lint and retention-rows each need scope")
        for c in conds:
            self.assertIn("!cancelled()", c)
            self.assertIn("needs.scope.outputs.relevant != 'false'", c)

    def test_required_checks_are_job_names_of_always_run_workflows(self):
        rules = json.loads((ROOT / "tools" / "github" / "infra-main-ruleset.json").read_text(encoding="utf-8"))
        contexts = [c["context"] for r in rules["rules"] if r["type"] == "required_status_checks"
                    for c in r["parameters"]["required_status_checks"]]
        wf_dir = ROOT / ".github" / "workflows"
        names = {}
        for wf in wf_dir.glob("*.yml"):
            for m in re.finditer(r"^    name: (.+)$", wf.read_text(encoding="utf-8"), re.M):
                names[m.group(1).strip()] = wf.name
        for ctx in contexts:
            self.assertIn(ctx, names, f"required check {ctx!r} is not a job name in .github/workflows")
            text = (wf_dir / names[ctx]).read_text(encoding="utf-8")
            on_block = text[text.index("\non:\n"):text.index("\njobs:\n")]
            trigger = "pull_request_target:" if "pull_request_target:" in on_block else "pull_request:"
            self.assertIn(trigger, on_block, f"{names[ctx]} does not run on pull requests")
            after = on_block[on_block.index(trigger):]
            nxt = re.search(r"\n  [a-z_]+:", after[len(trigger):])
            pr_part = after[: len(trigger) + (nxt.start() if nxt else len(after))]
            self.assertNotIn("paths:", pr_part, f"{names[ctx]} filters pull requests by path: a required check would block")


if __name__ == "__main__":
    unittest.main()
