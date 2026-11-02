"""AA-1023: the job-idle gate of terraform-apply.yml.

Two parts, no database, no asyncpg, no AWS:
  * db/run_migration.py MIGRATION_MODE=idle-gate with the FakeConn of test_run_migration (same idle check as apply);
  * .github/scripts/job-idle-gate.sh with a fake `aws` and a fake migrator-task.sh on PATH: what it sends to the task,
    how it reads the answer (exit 0 + pass line / 7 / other), the override, and that the per-run revision and the S3
    objects are always cleaned up.
Run: python3 -m unittest discover -s db/tests -v
"""
import asyncio
import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))

import run_migration as rm  # noqa: E402
from test_run_migration import FakeConn, job  # noqa: E402
from test_runner_modes import MIGRATOR_DSN, TASK_ENV_NAMES  # noqa: E402

ROOT = HERE.parent.parent
GATE = ROOT / ".github" / "scripts" / "job-idle-gate.sh"


def boom(*a, **k):
    raise AssertionError("must not be called")


async def no_sleep(_s):
    return None


class IdleGateModeTest(unittest.TestCase):
    def run_gate(self, conn, override=""):
        self.settings = None

        async def connect(dsn, settings, **kw):
            self.assertEqual(dsn, MIGRATOR_DSN)
            self.settings = settings
            return conn

        env = {"MIGRATION_MODE": "idle-gate", "DATABASE_URL": MIGRATOR_DSN, "MIGRATION_IDLE_OVERRIDE": override}
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = asyncio.run(rm.run_task(env, fetch=boom, connect=connect, sleep=no_sleep, get_secret=boom))
        return code, out.getvalue()

    def test_mode_is_allowlisted(self):
        self.assertEqual(rm.parse_mode("idle-gate"), rm.Mode("idle-gate"))
        for value in ("idle-gate:x", "idle_gate", "Idle-gate", "idle-gate "):
            with self.subTest(value=value), self.assertRaises(ValueError):
                rm.parse_mode(value)

    def test_idle_passes_read_only_without_fetch_or_lock(self):
        conn = FakeConn(login="db_migrator", states=[({"shared": [], "booking": [], "crm": []}, 0)])
        code, out = self.run_gate(conn)
        self.assertEqual(code, 0, out)
        self.assertIn("MIGRATE ran as: db_migrator (idle-gate, read-only, no apply lock)", out)
        self.assertIn("MIGRATE idle-gate: pass (every job table idle, no open rerun wave)", out)
        self.assertEqual(self.settings, {**rm.DEFAULT_SETTINGS, "default_transaction_read_only": "on"})
        self.assertFalse(hasattr(conn, "lock_tries"))           # never takes the apply lock
        self.assertEqual(conn.executed, [])                      # writes nothing
        self.assertTrue(conn.closed)

    def test_busy_then_idle_passes_after_a_recheck(self):
        conn = FakeConn(login="db_migrator", states=[({"shared": [job("s1_batch_ingest", "running")]}, 0),
                                                     ({"shared": []}, 0)])
        code, out = self.run_gate(conn)
        self.assertEqual(code, 0, out)
        self.assertIn("waiting 20s for idle job tables (re-check 1/3)", out)
        self.assertIn("idle-gate: pass", out)

    def test_still_busy_refuses_with_7(self):
        for name, state in {
            "running CIS job": ({"shared": [job("noop_sleep", "running")]}, 0),
            "queued due Booking job": ({"shared": [], "booking": [job("bk_retention_job")]}, 0),
            "crm job": ({"shared": [], "crm": [job("crm_import", "running")]}, 0),
            "open wave": ({"shared": []}, 1),
            "unreadable table": ({"shared": RuntimeError("permission denied for table job")}, 0),
        }.items():
            with self.subTest(name):
                conn = FakeConn(login="db_migrator", states=[state])
                code, out = self.run_gate(conn)
                self.assertEqual(code, 7, out)
                self.assertIn("MIGRATE ERROR: idle-gate refused", out)
                self.assertNotIn("idle-gate: pass", out)
                self.assertTrue(conn.closed)

    def test_exempt_and_later_rows_do_not_block(self):
        conn = FakeConn(login="db_migrator", states=[({
            "shared": [job("place_geocode", later=True)],
            "booking": [job("bk_inquiry_pull")],
            "crm": [job("crm_heartbeat", "running"), job("crm_membership_pull"), job("crm_booking_sync")]}, 0)])
        code, out = self.run_gate(conn)
        self.assertEqual(code, 0, out)

    def test_override_passes_a_busy_answer_with_a_warning(self):
        conn = FakeConn(login="db_migrator", states=[({"shared": [job("noop_sleep", "running")]}, 0)])
        code, out = self.run_gate(conn, override="  SEV1 fix: the NAT change cannot wait  ")
        self.assertEqual(code, 0, out)
        self.assertIn("MIGRATE WARNING: idle gate OVERRIDDEN (SEV1 fix: the NAT change cannot wait), busy: shared.job", out)
        self.assertIn("idle-gate: pass (override)", out)
        self.assertNotIn("waiting", out)                          # no wait when overridden

    def test_runner_reads_no_new_env_names(self):
        self.assertIn("MIGRATION_IDLE_OVERRIDE", TASK_ENV_NAMES)


FAKE_AWS = r"""#!/usr/bin/env bash
# Fake aws CLI for job-idle-gate.sh tests: records each call, answers from $FAKE_DIR.
echo "$*" >> "$FAKE_DIR/calls"
case "$1 $2" in
  "s3 cp") [ -f "$FAKE_DIR/fail_cp" ] && exit 1; exit 0 ;;
  "s3 presign") echo "https://bucket.example/db-migrate/x/run_migration.py?X-Amz-Signature=sig" ;;
  "s3 rm") exit 0 ;;
  "ecs run-task")
    while [ $# -gt 0 ]; do [ "$1" = "--overrides" ] && printf '%s' "$2" > "$FAKE_DIR/overrides"; shift; done
    echo "arn:aws:ecs:us-west-1:005097885195:task/aa-cis-dev-cluster/abc123" ;;
  "ecs wait") exit 0 ;;
  "logs get-log-events")
    jq -n --rawfile log "$FAKE_DIR/log" '{events: [$log | split("\n")[] | select(length > 0) | {message: .}], nextForwardToken: "t1"}'
    ;;
  "ecs describe-tasks")
    jq -n --arg exit "$(cat "$FAKE_DIR/exit")" --arg st "$(cat "$FAKE_DIR/status")" \
      '{tasks: [{lastStatus: $st, containers: [{name: "migrate", exitCode: ($exit | tonumber? // null)}]}]}' ;;
  *) echo "unexpected aws call: $*" >&2; exit 9 ;;
esac
"""

FAKE_MIGRATOR = r"""#!/usr/bin/env bash
echo "migrator $*" >> "$FAKE_DIR/calls"
case "$1" in
  prepare)
    [ -f "$FAKE_DIR/fail_prepare" ] && exit 1
    echo "arn=arn:aws:ecs:us-west-1:005097885195:task-definition/aa-cis-dev-db-migrate:99" >> "$GITHUB_OUTPUT"
    echo 'network={"awsvpcConfiguration":{"subnets":["subnet-1"],"securityGroups":["sg-1"],"assignPublicIp":"DISABLED"}}' >> "$GITHUB_OUTPUT" ;;
  deregister) exit 0 ;;
esac
"""


@unittest.skipUnless(shutil.which("jq") and shutil.which("bash"), "needs bash + jq")
class JobIdleGateScriptTest(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="aa1023-gate-"))
        self.addCleanup(shutil.rmtree, self.dir, True)
        (self.dir / "bin").mkdir()
        (self.dir / "bin" / "aws").write_text(FAKE_AWS)
        (self.dir / "bin" / "aws").chmod(0o755)
        (self.dir / "migrator.sh").write_text(FAKE_MIGRATOR)
        (self.dir / "calls").write_text("")

    def gate(self, exit_code="0", log="MIGRATE idle-gate: pass (every job table idle, no open rerun wave)\n",
             status="STOPPED", override=None):
        (self.dir / "exit").write_text(exit_code)
        (self.dir / "log").write_text(log)
        (self.dir / "status").write_text(status)
        summary = self.dir / "summary.md"
        env = {**os.environ, "PATH": f"{self.dir / 'bin'}:{os.environ['PATH']}", "FAKE_DIR": str(self.dir),
               "MIGRATOR_TASK": str(self.dir / "migrator.sh"), "CLUSTER": "aa-cis-dev-cluster",
               "SERVICE": "aa-cis-dev-api", "BUCKET": "aa-cis-bronze-005097885195", "LOG_GROUP": "/ecs/aa-cis-dev",
               "GITHUB_RUN_ID": "4242", "GITHUB_RUN_ATTEMPT": "1", "GITHUB_STEP_SUMMARY": str(summary)}
        env.pop("OVERRIDE", None)
        if override is not None:
            env["OVERRIDE"] = override
        r = subprocess.run(["bash", str(GATE)], env=env, capture_output=True, text=True, timeout=60)
        calls = (self.dir / "calls").read_text()
        return r, calls, summary.read_text() if summary.exists() else ""

    def overrides(self):
        return json.loads((self.dir / "overrides").read_text())

    def assert_cleaned(self, calls):
        self.assertIn("migrator deregister arn:aws:ecs:us-west-1:005097885195:task-definition/aa-cis-dev-db-migrate:99",
                      calls)
        self.assertIn("s3 rm s3://aa-cis-bronze-005097885195/db-migrate/4242-1-idle-gate/ --recursive", calls)

    def test_idle_answer_passes(self):
        r, calls, summary = self.gate()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("job-idle gate: pass", r.stdout)
        self.assertIn("**job-idle gate: pass**", summary)
        self.assert_cleaned(calls)
        o = self.overrides()["containerOverrides"][0]
        self.assertEqual(o["name"], "migrate")
        env = {e["name"]: e["value"] for e in o["environment"]}
        self.assertLessEqual(set(env), TASK_ENV_NAMES)
        self.assertEqual(env["MIGRATION_MODE"], "idle-gate")
        self.assertEqual(env["MIGRATION_IDLE_OVERRIDE"], "")
        self.assertEqual(env["MIGRATION_URL"], "")
        self.assertIn("--started-by gh-tf-apply-idle-gate-4242", calls)
        self.assertIn("--task-definition arn:aws:ecs:us-west-1:005097885195:task-definition/aa-cis-dev-db-migrate:99",
                      calls)

    def test_busy_answer_refuses(self):
        r, calls, summary = self.gate("7", "MIGRATE busy: shared.job running=1 queued=0\nMIGRATE ERROR: idle-gate refused\n")
        self.assertEqual(r.returncode, 1)
        self.assertIn("::error::job-idle gate refused the apply: a job table is busy", r.stdout)
        self.assertIn("job-idle gate: refused", summary)
        self.assertIn("MIGRATE busy: shared.job", summary)
        self.assert_cleaned(calls)

    def test_no_clean_answer_refuses(self):
        for name, kw in {
            "exit 0 without the pass line": {"exit_code": "0", "log": "MIGRATE ran as: db_migrator\n"},
            "other exit code": {"exit_code": "1", "log": "Traceback\n"},
            "no exit code": {"exit_code": "null", "log": ""},
            "not stopped": {"exit_code": "0", "status": "RUNNING"},
        }.items():
            with self.subTest(name):
                r, calls, _ = self.gate(**kw)
                self.assertEqual(r.returncode, 1, r.stdout)
                self.assertIn("::error::job-idle gate refused the apply", r.stdout)
                self.assert_cleaned(calls)

    def test_override_lets_a_busy_answer_through_and_reaches_the_task(self):
        r, calls, summary = self.gate("7", "MIGRATE busy\n", override=" SEV1: NAT fix ")
        # The runner itself answers 0 under an override; a 7 here would mean the task ignored it: still let through.
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("::warning::job-idle gate OVERRIDDEN (SEV1: NAT fix)", r.stdout)
        self.assertIn("job-idle gate overridden", summary)
        env = {e["name"]: e["value"] for e in self.overrides()["containerOverrides"][0]["environment"]}
        self.assertEqual(env["MIGRATION_IDLE_OVERRIDE"], "SEV1: NAT fix")
        self.assert_cleaned(calls)

    def test_override_also_covers_a_task_that_cannot_start(self):
        (self.dir / "fail_prepare").write_text("")
        r, calls, _ = self.gate(override="DB is what this apply fixes")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("OVERRIDDEN", r.stdout)
        self.assertNotIn("deregister", calls)                    # nothing was registered
        r, _, _ = self.gate()
        self.assertEqual(r.returncode, 1)

    def test_bad_override_values_are_refused_before_any_aws_call(self):
        for value in ("   ", "x" * 201, "line one\nline two"):
            with self.subTest(value=value[:12]):
                (self.dir / "calls").write_text("")
                r, calls, _ = self.gate(override=value)
                self.assertEqual(r.returncode, 1)
                self.assertIn("::error::override_busy_jobs", r.stdout)
                self.assertEqual(calls, "")

    def test_upload_failure_refuses_and_cleans_up(self):
        (self.dir / "fail_cp").write_text("")
        r, calls, _ = self.gate()
        self.assertEqual(r.returncode, 1)
        self.assertIn("runner upload failed", r.stdout)
        self.assertNotIn("ecs run-task", calls)
        self.assert_cleaned(calls)


if __name__ == "__main__":
    unittest.main()
