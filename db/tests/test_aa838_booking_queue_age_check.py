"""AA-838 D8: the pure label of db/scripts/aa838_booking_queue_age_check.py and its run-script shape."""

import datetime as dt
import importlib.util
import pathlib
import subprocess
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "db" / "scripts" / "aa838_booking_queue_age_check.py"

spec = importlib.util.spec_from_file_location("aa838_bq", SCRIPT)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

UTC = dt.timezone.utc


def row(**kw):
    base = {"run_after": m.SPIKE_AT - dt.timedelta(seconds=m.SPIKE_AGE_S),
            "created_at": dt.datetime(2026, 10, 23, 16, 0, tzinfo=UTC),
            "updated_at": dt.datetime(2026, 10, 23, 16, 0, tzinfo=UTC),
            "started_at": None, "attempt": 0, "cancel_requested": False}
    base.update(kw)
    return base


class ExplainRow(unittest.TestCase):
    def test_spike_centre_matches_the_sample(self):
        centre = m.SPIKE_AT - dt.timedelta(seconds=m.SPIKE_AGE_S)
        self.assertEqual(centre, dt.datetime(2026, 10, 23, 16, 29, 1, tzinfo=UTC))

    def test_not_due(self):
        self.assertEqual(m.explain_row(row(run_after=m.SPIKE_AT + dt.timedelta(seconds=1))), "not_due_at_spike")

    def test_created_after(self):
        self.assertEqual(m.explain_row(row(created_at=m.SPIKE_AT + dt.timedelta(seconds=5))), "created_after_spike")

    def test_enqueued_during_deploy(self):
        self.assertEqual(m.explain_row(row(created_at=m.PREV_ZERO_AT + dt.timedelta(seconds=30))),
                         "enqueued_during_deploy_with_old_run_after")

    def test_requeued_during_deploy(self):
        self.assertEqual(m.explain_row(row(attempt=1, updated_at=m.PREV_ZERO_AT + dt.timedelta(seconds=60))),
                         "requeued_during_deploy_keeping_run_after")

    def test_started_before_prev_zero(self):
        self.assertEqual(m.explain_row(row(started_at=m.PREV_ZERO_AT - dt.timedelta(seconds=1))),
                         "already_started_before_prev_zero")

    def test_cancel_requested(self):
        self.assertEqual(m.explain_row(row(cancel_requested=True)), "cancel_requested")

    def test_plain_unclaimed(self):
        self.assertEqual(m.explain_row(row()), "queued_and_due_unclaimed")


class Shape(unittest.TestCase):
    def test_runner_inspect_passes(self):
        out = subprocess.run([sys.executable, "-B", str(ROOT / "db" / "run_migration.py"), "--inspect-script",
                              str(SCRIPT.relative_to(ROOT))], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.assertIn('"errors": []', out.stdout)

    def test_read_only(self):
        self.assertTrue(m.READ_ONLY)


if __name__ == "__main__":
    unittest.main()
