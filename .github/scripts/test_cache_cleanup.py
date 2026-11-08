"""Tests of .github/scripts/cache_cleanup.py and the Cache cleanup workflow (S273, AA-1024).

Offline, stdlib unittest + PyYAML: a fake `gh` answers the cache and pull request listings and records deletes. Which
caches each mode picks (a pull request's refs; merge-queue refs idle for more than 2 h; both kinds for pull requests
that are not open), that the default branch and other branches are never picked, dry run vs --apply, a failed delete,
then the shape of this repo's .github/workflows/cache-cleanup.yml. Invented names only. The same file in all six repos.
Run: python3 -B -m unittest discover -s .github/scripts -p 'test_cache_cleanup.py'
"""
from __future__ import annotations

import importlib.util
import io
import json
import subprocess
import sys
import unittest
import unittest.mock
from datetime import datetime, timezone
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "cache-cleanup.yml"

_spec = importlib.util.spec_from_file_location("cache_cleanup", HERE / "cache_cleanup.py")
cc = importlib.util.module_from_spec(_spec)
sys.modules["cache_cleanup"] = cc
_spec.loader.exec_module(cc)

NOW = datetime(2026, 11, 8, 12, 0, tzinfo=timezone.utc)
REPO = "demo-org/demo-app"


def cache(cid: int, ref: str, size: int, accessed: str, key: str = "setup-uv-1-demo") -> dict:
    return {"id": cid, "ref": ref, "key": key, "size_in_bytes": size, "last_accessed_at": accessed,
            "created_at": accessed}


CACHES = [
    cache(1, "refs/heads/main", 900, "2026-11-01T00:00:00Z"),
    cache(2, "refs/heads/feature/demo", 50, "2026-11-01T00:00:00Z"),
    cache(3, "refs/pull/41/merge", 100, "2026-11-08T11:00:00Z"),
    cache(4, "refs/pull/41/head", 10, "2026-11-08T11:00:00Z"),
    cache(5, "refs/pull/42/merge", 200, "2026-11-08T11:59:00Z"),
    cache(6, "refs/heads/gh-readonly-queue/main/pr-42-abc", 300, "2026-11-08T09:00:00Z"),
    cache(7, "refs/heads/gh-readonly-queue/main/pr-43-def", 400, "2026-11-08T11:30:00Z"),
    cache(8, "refs/pull/7/merge-extra", 5, "2026-11-01T00:00:00Z"),
]


class FakeGh:
    def __init__(self, caches=CACHES, open_prs=(42,), fail_delete=(), list_fails=False):
        self.caches, self.open_prs, self.fail_delete, self.list_fails = caches, open_prs, set(fail_delete), list_fails
        self.deleted: list[int] = []

    def __call__(self, cmd, **kw):
        assert cmd[0] == "gh", cmd
        if "DELETE" in cmd:
            cid = int(cmd[-1].rsplit("/", 1)[1])
            if cid in self.fail_delete:
                return subprocess.CompletedProcess(cmd, 1, "", "HTTP 403: Resource not accessible")
            self.deleted.append(cid)
            return subprocess.CompletedProcess(cmd, 0, "", "")
        path = cmd[3]
        if self.list_fails:
            return subprocess.CompletedProcess(cmd, 1, "", "HTTP 502")
        if "/actions/caches" in path:
            return subprocess.CompletedProcess(cmd, 0, "\n".join(json.dumps(c) for c in self.caches) + "\n", "")
        if "/pulls" in path:
            return subprocess.CompletedProcess(cmd, 0, "\n".join(str(n) for n in self.open_prs) + "\n", "")
        raise AssertionError(cmd)


def ids(caches):
    return [c["id"] for c in caches]


class Select(unittest.TestCase):
    def test_pr_mode_takes_only_that_pull_requests_refs(self):
        self.assertEqual(ids(cc.select(CACHES, "pr", pr=41, now=NOW)), [3, 4])
        self.assertEqual(ids(cc.select(CACHES, "pr", pr=99, now=NOW)), [])

    def test_queue_mode_takes_queue_refs_idle_longer_than_the_age(self):
        self.assertEqual(ids(cc.select(CACHES, "queue", now=NOW)), [6])
        self.assertEqual(ids(cc.select(CACHES, "queue", now=NOW, max_age_hours=0.25)), [6, 7])

    def test_stale_mode_keeps_open_pull_requests_and_branches(self):
        self.assertEqual(ids(cc.select(CACHES, "stale", open_prs={42}, now=NOW)), [3, 4, 6])
        picked = set(ids(cc.select(CACHES, "stale", open_prs=set(), now=NOW, max_age_hours=0)))
        self.assertEqual(picked, {3, 4, 5, 6, 7})  # never main, a branch, or a ref that only looks like a PR ref

    def test_unknown_mode(self):
        with self.assertRaises(ValueError):
            cc.select(CACHES, "everything", now=NOW)


class RunMode(unittest.TestCase):
    def test_dry_run_deletes_nothing(self):
        fake, logs = FakeGh(), []
        result = cc.run_mode(REPO, "stale", run=fake, now=NOW, log=logs.append)
        self.assertEqual((result["drop"], result["drop_bytes"], result["deleted"]), (3, 410, 0))
        self.assertEqual(fake.deleted, [])
        self.assertIn("dry run", logs[0])

    def test_apply_deletes_and_counts_failures(self):
        fake = FakeGh(fail_delete={4})
        result = cc.run_mode(REPO, "pr", pr=41, apply=True, run=fake, now=NOW, log=lambda m: None)
        self.assertEqual(fake.deleted, [3])
        self.assertEqual((result["deleted"], result["failed"]), (1, 1))

    def test_cli_exit_codes(self):
        with unittest.mock.patch("sys.stdout", io.StringIO()), unittest.mock.patch("sys.stderr", io.StringIO()):
            self.assertEqual(cc.main(["queue", "--repo", REPO, "--apply"], run=FakeGh()), 0)
            self.assertEqual(cc.main(["pr", "--repo", REPO, "--pr", "41", "--apply"], run=FakeGh(fail_delete={3})), 1)
            self.assertEqual(cc.main(["stale", "--repo", REPO], run=FakeGh(list_fails=True)), 1)


class ThisRepoWorkflow(unittest.TestCase):
    def setUp(self):
        self.wf = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))

    def test_triggers_and_least_privilege(self):
        on = self.wf.get("on", self.wf.get(True))
        self.assertEqual(on["pull_request"], {"types": ["closed"]})
        self.assertIn("schedule", on)
        self.assertIn("workflow_dispatch", on)
        self.assertNotIn("pull_request_target", on)
        self.assertEqual(self.wf["permissions"], {"actions": "write", "contents": "read"})
        self.assertEqual(self.wf["defaults"]["run"]["shell"], "bash")

    def test_jobs_run_the_script_on_the_default_branch(self):
        jobs = self.wf["jobs"]
        pr, queue = jobs["pr-caches"], jobs["queue-caches"]
        self.assertEqual(pr["if"], "github.event_name == 'pull_request'")
        self.assertEqual(queue["if"], "github.event_name != 'pull_request'")
        checkout = pr["steps"][0]
        self.assertEqual(checkout["with"]["ref"], "${{ github.event.repository.default_branch }}")
        for job in (pr, queue):
            self.assertIs(job["steps"][0]["with"]["persist-credentials"], False)
            self.assertNotIn("permissions", job)
        self.assertIn("cache_cleanup.py pr --repo \"$REPO\" --pr \"$PR\" --apply", pr["steps"][1]["run"])
        self.assertIn("cache_cleanup.py queue --repo \"$REPO\" --max-age-hours 2 --apply", queue["steps"][1]["run"])
        self.assertNotIn("secrets.", WORKFLOW.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
