"""AA-986 L7b: db/tour_liveness_gate.py (the nightly DB Tour Liveness Gate's verdict from the task log).

The logs are built by running the real probe (db/scripts/s248_tour_deletion_probe.py) on the fake connection of
test_s248_tour_deletion_probe.py, so a change of the probe's output format breaks these tests, not the nightly run.
Run: python3 -m unittest discover -s db/tests -v
"""
import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))

import tour_liveness_gate as gate  # noqa: E402
import test_s248_tour_deletion_probe as tp  # noqa: E402

RAN_AS = ("MIGRATE ran as: aa_cis_admin (run-script, READ_ONLY: default_transaction_read_only=on)")
HEADER = ["MIGRATE run-script: file=db/scripts/s248_tour_deletion_probe.py sha256=0123456789ab",
          "MIGRATE master login: aa_cis_admin (in-task DSN from aa-cis/dev/rds)", RAN_AS,
          "MIGRATE run-script: READ_ONLY script, the idle check is report-only (no wait, no refusal)",
          "MIGRATE run-script: main(conn) starts; its output follows"]
FOOTER = ["MIGRATE run-script: done"]


def probe_lines(**kw):
    _, lines = tp.run(tp.FakeConn(**kw))
    return lines


def log(**kw):
    return HEADER + probe_lines(**kw) + FOOTER


class EvaluateTest(unittest.TestCase):
    def test_clean_run_is_green_with_pending_checks_listed(self):
        g = gate.evaluate(log(), "0")
        self.assertTrue(g["green"], g["failures"])
        self.assertEqual(g["failures"], [])
        self.assertEqual(g["pending"], ["tombstone_disagrees_with_state"])
        self.assertEqual(g["catalog_role"], "booking")
        self.assertEqual(g["verdict"]["violations"], "0")

    def test_violation_is_red_and_named(self):
        g = gate.evaluate(log(masters_dup=["k-sup"]), "0")
        self.assertFalse(g["green"])
        self.assertEqual(g["violations"], ["check.masters_active_in_one_group"])
        self.assertTrue(any("1 violation(s): check.masters_active_in_one_group" in f for f in g["failures"]))

    def test_layer_error_is_red(self):
        err = tp.PgError('column "x" does not exist', "42703")
        g = gate.evaluate(log(layer_errors={"tp_drafts_open": err}), "0")
        self.assertFalse(g["green"])
        self.assertTrue(any("failed to run" in f for f in g["failures"]))
        self.assertTrue(all(e["sqlstate"] == "42703" for e in g["errors"]))

    def test_keep_warn_hits_warn_but_stay_green(self):
        g = gate.evaluate(log(layer_hits={"bk_b2b_holds_confirmed_upcoming": {"k-dead": ["h1"]}}), "0")
        self.assertTrue(g["green"], g["failures"])
        self.assertEqual(g["keep_warn"], [{"where": "group_dead.bk_b2b_holds_confirmed_upcoming", "n": 1,
                                           "sample": ["h1"]}])
        self.assertEqual(g["warnings"], ["kept and flagged: group_dead.bk_b2b_holds_confirmed_upcoming n=1"])

    def test_unreadable_catalog_is_red(self):
        g = gate.evaluate(log(refuse_roles={"booking", "tripplanner"}), "0")
        self.assertFalse(g["green"])
        self.assertTrue(any("no catalog role" in f for f in g["failures"]))

    def test_non_zero_task_exit_is_red_with_its_meaning(self):
        for code, word in (("13", "raised"), ("8", "role refused"), ("1", "did not finish normally")):
            g = gate.evaluate(log(), code)
            self.assertFalse(g["green"])
            self.assertIn(word, g["failures"][0])
        self.assertFalse(gate.evaluate(log(), None)["green"])
        self.assertFalse(gate.evaluate(log(), "")["green"])

    def test_run_that_was_not_read_only_is_red(self):
        lines = [x for x in log() if x != RAN_AS] + ["MIGRATE ran as: aa_cis_admin (run-script)"]
        g = gate.evaluate(lines, "0")
        self.assertFalse(g["green"])
        self.assertTrue(any("READ_ONLY" in f for f in g["failures"]))

    def test_probe_that_never_finished_is_red(self):
        lines = [x for x in log() if not x.startswith(("SCRIPT verdict", "SCRIPT json"))]
        g = gate.evaluate(lines, "0")
        self.assertFalse(g["green"])
        self.assertTrue(any("found 0" in f for f in g["failures"]))
        self.assertFalse(gate.evaluate(HEADER, "0")["green"])
        self.assertFalse(gate.evaluate([], "0")["green"])

    def test_two_verdicts_or_bad_json_are_red(self):
        lines = log()
        v = [x for x in lines if x.startswith("SCRIPT verdict")][0]
        self.assertFalse(gate.evaluate(lines + [v], "0")["green"])
        bad = [("SCRIPT json {not json" if x.startswith("SCRIPT json") else x) for x in lines]
        self.assertFalse(gate.evaluate(bad, "0")["green"])

    def test_verdict_line_that_disagrees_with_the_json_is_red(self):
        lines = [("SCRIPT verdict violations=0 errors=0 list=- pending=1" if x.startswith("SCRIPT verdict") else x)
                 for x in log(masters_dup=["k-sup"])]
        g = gate.evaluate(lines, "0")
        self.assertFalse(g["green"])
        self.assertTrue(any("disagree" in f for f in g["failures"]))

    def test_verdict_without_numbers_is_red(self):
        lines = [("SCRIPT verdict violations=? errors=0 list=-" if x.startswith("SCRIPT verdict") else x)
                 for x in log()]
        self.assertFalse(gate.evaluate(lines, "0")["green"])


class MainTest(unittest.TestCase):
    def _main(self, lines, code="0"):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            (p / "task.log").write_text("\n".join(lines) + "\n", encoding="utf-8")
            (p / "summary.md").write_text("", encoding="utf-8")
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                rc = gate.main(["--log", str(p / "task.log"), "--exit-code", code, "--summary", str(p / "summary.md"),
                                "--out", str(p / "gate.json"), "--reason", "nightly"])
            return rc, out.getvalue(), (p / "summary.md").read_text(encoding="utf-8"), \
                json.loads((p / "gate.json").read_text(encoding="utf-8"))

    def test_green_run_writes_summary_and_json(self):
        rc, stdout, summary, data = self._main(log())
        self.assertEqual(rc, 0)
        self.assertIn("tour liveness gate: GREEN", stdout)
        self.assertNotIn("::error::", stdout)
        self.assertIn("### Tour liveness gate (nightly)", summary)
        self.assertIn("- GREEN: violations 0, errors 0, pending checks 1", summary)
        self.assertIn("| `tombstone_disagrees_with_state` | L4 | pending | - | catalog.v_tour_retired |", summary)
        self.assertEqual((data["green"], data["reason"], data["pending"]),
                         (True, "nightly", ["tombstone_disagrees_with_state"]))

    def test_red_run_annotates_and_tables_the_violation(self):
        rc, stdout, summary, data = self._main(log(masters_dead=["t-sup1"]))
        self.assertEqual(rc, 1)
        self.assertIn("::error::tour liveness gate: 1 violation(s): check.master_active_over_dead_source", stdout)
        self.assertIn("| `check.master_active_over_dead_source` | 1 | t-sup1 |", summary)
        self.assertFalse(data["green"])

    def test_error_table_never_carries_a_data_message(self):
        secret = 'invalid input syntax for type uuid: "Jane Doe +84"'
        rc, stdout, summary, _ = self._main(log(layer_errors={"tp_drafts_open": tp.PgError(secret, "22P02")}))
        self.assertEqual(rc, 1)
        self.assertNotIn("Jane", summary + stdout)
        self.assertIn("22P02", summary)

    def test_missing_log_is_red(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = gate.main(["--log", "/nonexistent/task.log", "--exit-code", "0"])
        self.assertEqual(rc, 1)
        self.assertIn("cannot read the task log", out.getvalue())


class WorkflowTest(unittest.TestCase):
    """The nightly workflow runs the probe the DB Migrate run-script way, read-only, and gates on this script."""
    TEXT = (HERE.parent.parent / ".github" / "workflows" / "db-tour-liveness-gate.yml").read_text(encoding="utf-8")

    def test_nightly_dispatchable_main_only_own_group(self):
        t = self.TEXT
        self.assertIn('    - cron: "43 4 * * *"', t)
        self.assertIn("  workflow_dispatch:", t)
        self.assertRegex(t, r"concurrency:\n  group: db-tour-liveness-gate\n  cancel-in-progress: false")
        self.assertIn("    if: github.ref == 'refs/heads/main'", t)
        self.assertIn("    environment: prod", t)

    def test_runs_the_probe_as_a_read_only_run_script(self):
        t = self.TEXT
        self.assertIn("SCRIPT: db/scripts/s248_tour_deletion_probe.py", t)
        self.assertIn('--arg mode "run-script:$SCRIPT"', t)
        self.assertIn('python3 db/run_migration.py --inspect-script "$SCRIPT"', t)
        self.assertIn("r.script_is_read_only(", t)
        source = (HERE.parent / "scripts" / "s248_tour_deletion_probe.py").read_text(encoding="utf-8")
        self.assertIn("\nREAD_ONLY = True\n", source)

    def test_runner_hash_is_checked_in_the_task(self):
        t = self.TEXT
        self.assertIn("RUNNER_SHA=$(sha256sum db/run_migration.py | cut -d' ' -f1)", t)
        self.assertIn("exec(b) if h=='$RUNNER_SHA' else exit(", t)
        self.assertIn('command: ["python3", "-c", $boot]', t)

    def test_verdict_comes_from_this_script_and_the_task_exit_code(self):
        t = self.TEXT
        self.assertIn('python3 db/tour_liveness_gate.py --log task.log --exit-code "$EXIT"', t)
        self.assertIn('--summary "$GITHUB_STEP_SUMMARY" --out gate.json', t)
        self.assertIn("if: always() && steps.task.outputs.arn != ''", t)

    def test_no_account_id_in_the_workflow(self):
        self.assertNotRegex(self.TEXT, r"\b\d{12}\b")
        self.assertIn('echo "BUCKET=aa-cis-bronze-$ACCOUNT" >> "$GITHUB_ENV"', self.TEXT)

    def test_uploads_go_to_their_own_prefix_and_are_removed(self):
        t = self.TEXT
        self.assertIn('PREFIX="db-tour-liveness-gate/${{ github.run_id }}"', t)
        self.assertRegex(t, r"- name: Remove S3 objects\n\s+if: always\(\) && steps\.task\.outputs\.prefix != ''")


if __name__ == "__main__":
    unittest.main()
