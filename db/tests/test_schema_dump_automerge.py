"""Unit tests for db/schema_dump_automerge.py (AA-993 M1). No network.

Run: python3 -m unittest discover -s db/tests -v
"""
import io
import json
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "db"))

import schema_dump_automerge as am  # noqa: E402

OK = dict(after_apply="true", drift_changed="false", erd_drift="success", design_ref="", publish="false",
          pr_existed="false")


class DecideTests(unittest.TestCase):
    def test_all_conditions_merge(self):
        self.assertEqual(am.decide(**OK)[0], True)

    def test_each_condition_alone_keeps_the_pr_open(self):
        for key, value in (("after_apply", "false"), ("after_apply", ""), ("drift_changed", "true"),
                           ("drift_changed", ""), ("erd_drift", "failure"), ("erd_drift", ""),
                           ("design_ref", "test/x"), ("publish", "true"), ("pr_existed", "true"),
                           ("pr_existed", "")):
            args = dict(OK, **{key: value})
            ok, why = am.decide(**args)
            self.assertFalse(ok, f"{key}={value!r} must not merge")
            self.assertTrue(why)


class FilesTests(unittest.TestCase):
    REF = "docs/architecture/db-schema-reference.md"
    ERD = "docs/architecture/erd"

    def test_generated_files_only(self):
        ok, bad = am.files_ok([self.REF, f"{self.ERD}/booking.md", f"{self.ERD}/README.md"], self.REF, self.ERD)
        self.assertTrue(ok)
        self.assertEqual(bad, [])

    def test_design_page_or_other_file_refused(self):
        for extra in (f"{self.ERD}/design/booking.md", "docs/adr/0017-x.md", f"{self.ERD}/erd.json",
                      ".github/workflows/docs-lint.yml"):
            ok, bad = am.files_ok([self.REF, extra], self.REF, self.ERD)
            self.assertFalse(ok, extra)
            self.assertEqual(bad, [extra])

    def test_empty_diff_refused(self):
        self.assertFalse(am.files_ok([], self.REF, self.ERD)[0])


def run(name, status="completed", conclusion="success"):
    return {"name": name, "status": status, "conclusion": conclusion}


class ChecksTests(unittest.TestCase):
    REQ = ["Docs lint", "gitleaks"]

    def test_green(self):
        rc, _ = am.checks_verdict([run("Docs lint"), run("gitleaks"), run("Docs freshness report", conclusion="skipped")],
                                  self.REQ)
        self.assertEqual(rc, 0)

    def test_pending(self):
        rc, why = am.checks_verdict([run("Docs lint", status="in_progress", conclusion=None), run("gitleaks")], self.REQ)
        self.assertEqual(rc, 2)
        self.assertIn("Docs lint", why)

    def test_red_any_check(self):
        for concl in ("failure", "cancelled", "timed_out", "action_required", None):
            rc, _ = am.checks_verdict([run("Docs lint"), run("gitleaks"), run("Other", conclusion=concl)], self.REQ)
            self.assertEqual(rc, 1, concl)

    def test_required_missing_is_pending(self):
        rc, why = am.checks_verdict([run("Docs lint")], self.REQ)
        self.assertEqual(rc, 2)
        self.assertIn("gitleaks", why)

    def test_cli_exit_codes(self):
        payload = json.dumps({"check_runs": [run("Docs lint"), run("gitleaks", conclusion="failure")]})
        with mock.patch("sys.stdin", io.StringIO(payload)), redirect_stdout(io.StringIO()) as out:
            rc = am.main(["checks", "--required", "Docs lint,gitleaks"])
        self.assertEqual(rc, 1)
        self.assertIn("gitleaks", out.getvalue())

    def test_cli_decide_prints_both_lines(self):
        with redirect_stdout(io.StringIO()) as out:
            am.main(["decide", "--after-apply", "true", "--drift-changed", "false", "--erd-drift", "success",
                     "--publish", "false", "--pr-existed", "false"])
        self.assertIn("merge=yes", out.getvalue())
        self.assertIn("reason=", out.getvalue())


class WorkflowWiringTests(unittest.TestCase):
    """The workflow calls this module the way the tests assume."""

    def setUp(self):
        self.wf = (ROOT / ".github" / "workflows" / "db-schema-dump.yml").read_text(encoding="utf-8")

    def test_design_drift_runs_before_the_pr_step(self):
        self.assertLess(self.wf.index("- name: Design ERD drift (report)"),
                        self.wf.index("- name: Open or update the root PR when the structure changed"))

    def test_merge_step_uses_match_head_commit_and_the_decision(self):
        step = self.wf[self.wf.index("- name: Merge the root PR after an apply"):]
        self.assertIn("--match-head-commit", step)
        self.assertIn("schema_dump_automerge.py decide", step)
        self.assertIn("schema_dump_automerge.py files", step)
        self.assertIn("schema_dump_automerge.py checks", step)

    def test_design_ref_never_written_into_the_root_checkout(self):
        step = self.wf[self.wf.index("- name: Design ERD drift (report)"):self.wf.index("- name: Open or update")]
        self.assertNotIn("git -C root checkout", step)


if __name__ == "__main__":
    unittest.main()
