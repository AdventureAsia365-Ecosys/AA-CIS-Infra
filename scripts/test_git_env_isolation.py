"""The pre-push hook, scripts/pre-push.sh and the tests they run never inherit git's repo-local variables (AA-1024).

S273 incident: git exports GIT_DIR (and in some setups GIT_WORK_TREE, GIT_INDEX_FILE, ...) to the hooks it runs. In a
worktree GIT_DIR is <clone>/.git/worktrees/<name>. Under the pre-push hook the docs unittest
(tools/docs/test_docs_tools.py, test_journals_are_out_of_scope) listed the real repo instead of its temporary dir and
failed, and a test that runs `git init` in a temporary dir initialised the inherited GIT_DIR instead: git guessed a bare
repo and wrote core.bare=true into the config every worktree of the clone shares, which broke the main checkout.
The root repo fixed the same class in S272 (root tools/github/test_git_env_isolation.py); this is the Infra copy.

Layers, all tested here against a sentinel clone (a linked worktree, the incident shape), never the real checkout:
  1. .githooks/pre-push cds to the top level and unsets `git rev-parse --local-env-vars` before any check;
  2. scripts/pre-push.sh unsets them again (it is also run by hand) and its --self-test checks it;
  3. every test that runs git in a temporary repo drops them itself (tools/terraform/tests/test_workflow_lint.py).

Offline: git runs only in temporary repositories. Needs pytest and PyYAML (the workflow lint test).
Run: python3 -m unittest scripts/test_git_env_isolation.py   (the hook-self-test check of scripts/pre-push.sh runs it)
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SELF = "scripts/test_git_env_isolation.py"


def local_vars() -> list[str]:
    # works outside a repo too: git only prints the names
    out = subprocess.run(["git", "rev-parse", "--local-env-vars"], capture_output=True, text=True, check=True,
                         cwd=tempfile.gettempdir())
    names = out.stdout.split()
    assert "GIT_DIR" in names and "GIT_INDEX_FILE" in names, names
    return names


# This test runs git itself: same scrub as every other helper, before anything else.
for _name in local_vars():
    os.environ.pop(_name, None)

BASE_ENV = {**os.environ, "GIT_AUTHOR_NAME": "T", "GIT_AUTHOR_EMAIL": "t@example.invalid", "GIT_COMMITTER_NAME": "T",
            "GIT_COMMITTER_EMAIL": "t@example.invalid", "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}

# Where tests live and what counts as "runs git" (an argv list in Python, statement position in bash).
SCAN_DIRS = ("tools/", "db/", "scripts/", "accounts/", ".github/scripts/")
PY_GIT = re.compile(r"""(\[\s*["']git["']\s*,|\(\s*["']git["']\s*,)""")
SH_GIT = re.compile(r"(^|[;&|({]\s*|\$\(\s*)git\s+(-C|-c|init|clone|config|commit|worktree|add|checkout|fetch|push|"
                    r"tag|branch|remote)\b", re.MULTILINE)
SH_UNSET = "unset $(git rev-parse --local-env-vars)"
# Files the scan must find, so a regex change cannot silently make it empty.
KNOWN = {"tools/terraform/tests/test_workflow_lint.py"}
WL3 = "tools/terraform/tests/test_workflow_lint.py::test_wl3_npm_ci_needs_a_tracked_lockfile"
DOCS_TEST = "test_docs_tools.AwsMultilineTest.test_journals_are_out_of_scope"


def git(cwd: Path, *args: str) -> str:
    p = subprocess.run(["git", *args], cwd=cwd, env=BASE_ENV, capture_output=True, text=True, check=True)
    return p.stdout.strip()


def is_test(path: str) -> bool:
    name = path.rsplit("/", 1)[-1]
    if not path.startswith(SCAN_DIRS) or path == SELF:
        return False
    return (name.startswith("test_") and name.endswith((".py", ".sh"))) or name in ("conftest.py",) or \
        name.endswith("_fakes.py") or ("/tests/" in path and name.endswith((".py", ".sh")))


def git_running_tests() -> dict[str, str]:
    out = {}
    for rel in git(ROOT, "ls-files", "--", *SCAN_DIRS).splitlines():
        if not is_test(rel):
            continue
        text = (ROOT / rel).read_text(encoding="utf-8", errors="replace")
        if (PY_GIT if rel.endswith(".py") else SH_GIT).search(text):
            out[rel] = text
    return out


class SentinelClone:
    """A clone with a linked worktree standing in for the real checkout (the S273 shape: GIT_DIR = .git/worktrees/x).

    It tracks docs/ops/sentinel.md, so a docs test that lists this repo instead of its temp dir sees an extra page.
    """

    def __init__(self, base: Path) -> None:
        self.main = base / "real-clone"
        self.main.mkdir()
        git(self.main, "init", "-q", "-b", "main")
        (self.main / "docs" / "ops").mkdir(parents=True)
        (self.main / "docs" / "ops" / "sentinel.md").write_text("sentinel\n", encoding="utf-8")
        git(self.main, "add", "-A")
        git(self.main, "commit", "-q", "-m", "start")
        git(self.main, "config", "core.hooksPath", ".githooks")
        self.wt = base / "real-wt"
        git(self.main, "worktree", "add", "-q", "-b", "lane", str(self.wt))
        self.git_dir = Path(git(self.wt, "rev-parse", "--absolute-git-dir"))
        assert self.git_dir.parent.name == "worktrees", self.git_dir

    def leaked_env(self, work_tree: bool = True) -> dict:
        env = {**BASE_ENV, "GIT_DIR": str(self.git_dir), "GIT_INDEX_FILE": str(self.git_dir / "index")}
        if work_tree:
            env["GIT_WORK_TREE"] = str(self.wt)
        return env

    def snapshot(self) -> tuple[str, str, str]:
        return ((self.main / ".git" / "config").read_text(encoding="utf-8"),
                git(self.main, "for-each-ref", "--format=%(refname) %(objectname)"),
                git(self.main, "worktree", "list", "--porcelain"))

    def assert_untouched(self, case: unittest.TestCase, before: tuple[str, str, str]) -> None:
        case.assertEqual(git(self.main, "config", "--local", "--get", "core.bare"), "false",
                         "a test initialised the inherited GIT_DIR: core.bare flipped in the shared config")
        case.assertEqual(git(self.main, "config", "--local", "--get", "core.hooksPath"), ".githooks")
        case.assertEqual(self.snapshot(), before, "something rewrote the repo it inherited through GIT_DIR")


class ScanTest(unittest.TestCase):
    def test_every_git_running_test_drops_the_repo_local_variables(self):
        names = local_vars()
        found = git_running_tests()
        self.assertTrue(KNOWN <= set(found), f"scan missed {sorted(KNOWN - set(found))}: fix PY_GIT / SH_GIT")
        problems = []
        for rel, text in sorted(found.items()):
            if rel.endswith(".sh") and SH_UNSET in text:
                continue
            missing = [n for n in names if f'"{n}"' not in text]
            if missing:
                problems.append(f"{rel}: does not drop {', '.join(missing)}")
        self.assertEqual(problems, [], "a test that runs git in a temporary repo must drop git's repo-local variables "
                         "and run git with cwd = its temp dir (Python: GIT_REPO_VARS + _git_in of "
                         f"tools/terraform/tests/test_workflow_lint.py; bash: `{SH_UNSET}`):\n" + "\n".join(problems))


class LeakTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="git-env-")
        self.base = Path(self.tmp.name)
        self.real = SentinelClone(self.base)
        self.before = self.real.snapshot()

    def tearDown(self):
        self.tmp.cleanup()

    def run_docs_test(self, env: dict) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, "-B", "-m", "unittest", "-q", DOCS_TEST], cwd=ROOT / "tools" / "docs",
                              env=env, capture_output=True, text=True, timeout=120)

    def test_the_sentinel_sees_a_leak(self):
        # control: with GIT_DIR inherited the docs test lists the sentinel (docs/ops/sentinel.md) and fails, so the
        # hook test below proves the scrub, not a test that cannot see a leak
        r = self.run_docs_test(self.real.leaked_env(work_tree=False))
        self.assertNotEqual(r.returncode, 0, "the docs test passed with GIT_DIR leaked: the sentinel no longer "
                            "detects a leak, rework this control before trusting the hook test")
        self.assertIn("sentinel.md", r.stdout + r.stderr)
        self.real.assert_untouched(self, self.before)

    def test_hook_runs_the_checks_from_the_top_level_without_git_variables(self):
        wt = self.real.wt
        (wt / ".githooks").mkdir()
        shutil.copy(ROOT / ".githooks" / "pre-push", wt / ".githooks" / "pre-push")
        (wt / "scripts").mkdir()
        seen = self.base / "seen.env"
        docs = ROOT / "tools" / "docs"
        # the check runner: record what it got, then the docs unittest and the git-init test of the incident
        (wt / "scripts" / "pre-push.sh").write_text(
            f'env > "{seen}"\npwd >> "{seen}"\n'
            f'cd "{docs}" && "{sys.executable}" -B -m unittest -q {DOCS_TEST} || exit 11\n'
            f'cd "{ROOT}" && "{sys.executable}" -B -m pytest -p no:cacheprovider -q "{WL3}" || exit 12\n',
            encoding="utf-8")
        head = git(wt, "rev-parse", "HEAD")
        push = f"refs/heads/lane {head} refs/heads/lane {'0' * 40}\n"
        # git runs pre-push in the top level with GIT_DIR exported (GIT_WORK_TREE / GIT_INDEX_FILE in some setups)
        r = subprocess.run(["bash", str(wt / ".githooks" / "pre-push"), "origin", "https://example.invalid/x.git"],
                           cwd=wt, env=self.real.leaked_env(), input=push, capture_output=True, text=True,
                           timeout=300)
        self.assertEqual(r.returncode, 0, r.stdout[-3000:] + r.stderr[-3000:])
        lines = seen.read_text(encoding="utf-8").splitlines()
        names = set(local_vars())
        leaked = [ln.split("=", 1)[0] for ln in lines if ln.split("=", 1)[0] in names]
        self.assertEqual(leaked, [], "the hook passed git's repo-local variables to the checks")
        self.assertEqual(lines[-1], str(wt), "the checks must run from the top level")
        self.real.assert_untouched(self, self.before)

    def test_prepush_script_drops_them_too(self):
        # by hand or from another wrapper: GIT_DIR of the sentinel worktree, cwd = this repo's top level
        r = subprocess.run(["bash", str(ROOT / "scripts" / "pre-push.sh"), "--self-test"], cwd=ROOT,
                           env=self.real.leaked_env(work_tree=False), capture_output=True, text=True, timeout=300)
        self.assertEqual(r.returncode, 0, r.stdout[-3000:] + r.stderr[-3000:])
        self.assertIn("ok   no GIT_DIR / GIT_WORK_TREE / GIT_INDEX_FILE in the environment", r.stdout)
        self.real.assert_untouched(self, self.before)

    def test_git_init_test_never_touches_the_inherited_repo(self):
        # the exact S273 shape, without the hook: the workflow lint test runs `git init` in tmp_path with GIT_DIR set
        r = subprocess.run([sys.executable, "-B", "-m", "pytest", "-p", "no:cacheprovider", "-q", WL3], cwd=ROOT,
                           env=self.real.leaked_env(), capture_output=True, text=True, timeout=300)
        self.assertEqual(r.returncode, 0, r.stdout[-3000:] + r.stderr[-3000:])
        self.real.assert_untouched(self, self.before)


if __name__ == "__main__":
    unittest.main()
