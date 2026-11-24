"""Unit tests for gitleaksignore_guard.py (S290). Stdlib only; each git test builds a throwaway repo.

Run: python3 -m unittest discover -s tools/repo -p 'test_*.py'
Fingerprints are invented (repeated hex digits, made-up paths); no real commit or value.
"""

from __future__ import annotations

import contextlib
import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import gitleaksignore_guard as gg  # noqa: E402

# Never inherit git's repo-local variables (a pre-push hook exports GIT_DIR and friends, S272).
for _git_var in ("GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CONFIG", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT",
                 "GIT_OBJECT_DIRECTORY", "GIT_DIR", "GIT_WORK_TREE", "GIT_IMPLICIT_WORK_TREE", "GIT_GRAFT_FILE",
                 "GIT_INDEX_FILE", "GIT_NO_REPLACE_OBJECTS", "GIT_REPLACE_REF_BASE", "GIT_PREFIX", "GIT_SHALLOW_FILE",
                 "GIT_COMMON_DIR"):
    os.environ.pop(_git_var, None)


def pin(digit: str, line: int = 7, path: str = "docs/demo/fixture.json", rule: str = "demo-rule") -> str:
    return f"{digit * 40}:{path}:{rule}:{line}"


OLD = pin("a")
NEW = pin("b")
OTHER = pin("c", line=12)
REASON = "commit gone from every ref on GitHub after a support purge"


class ParseTests(unittest.TestCase):
    def test_pins_comments_and_globals(self):
        text = "\n".join(["# header", "", OLD, "  " + OTHER + "  ", "docs/x.md:demo-rule:3", "not a pin"])
        b = gg.parse(text)
        self.assertEqual(b.pins, {OLD, OTHER})  # the global file:rule:line entry is not a pin
        self.assertEqual(b.retired, {})

    def test_retired_line_needs_a_pin_and_a_reason(self):
        b = gg.parse(f"# retired {OLD} {REASON}\n# retired {OLD} short\n# retired docs/x.md:r:1 {REASON}\n")
        self.assertEqual(b.retired, {OLD: REASON})
        self.assertEqual(len(b.bad_retired), 2)


class DroppedTests(unittest.TestCase):
    def test_remap_that_replaces_is_refused(self):
        # S287: the rewrite remap swapped the old pin for the new one; the old commit stays on a PR head.
        self.assertEqual(gg.dropped(gg.parse(f"{OLD}\n{OTHER}\n"), gg.parse(f"{NEW}\n{OTHER}\n")), [OLD])

    def test_remap_that_adds_is_clean(self):
        self.assertEqual(gg.dropped(gg.parse(f"{OLD}\n"), gg.parse(f"{OLD}\n{NEW}\n")), [])

    def test_retired_pin_may_go(self):
        self.assertEqual(gg.dropped(gg.parse(f"{OLD}\n"), gg.parse(f"# retired {OLD} {REASON}\n")), [])

    def test_moving_a_pin_in_the_file_is_clean(self):
        self.assertEqual(gg.dropped(gg.parse(f"{OLD}\n{OTHER}\n"), gg.parse(f"# moved\n{OTHER}\n\n{OLD}\n")), [])


class GitTests(unittest.TestCase):
    def setUp(self):
        self.repo = tempfile.mkdtemp(prefix="gitleaksignore-guard-")
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "user.name", "test")
        self.git("config", "commit.gpgsign", "false")

    def tearDown(self):
        shutil.rmtree(self.repo, ignore_errors=True)

    def git(self, *args: str) -> str:
        return subprocess.run(["git", "-C", self.repo, *args], check=True, capture_output=True, text=True).stdout

    def commit(self, text: str | None, msg: str) -> str:
        path = Path(self.repo, ".gitleaksignore")
        if text is None:
            path.unlink(missing_ok=True)
            Path(self.repo, "readme.txt").write_text(msg)
        else:
            path.write_text(text)
        self.git("add", "-A")
        self.git("commit", "-q", "-m", msg)
        return self.git("rev-parse", "HEAD").strip()

    def run_guard(self, *args: str) -> tuple[int, str]:
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            code = gg.main(["--repo", self.repo, *args])
        return code, out.getvalue()

    def test_replace_refused_with_annotation(self):
        base = self.commit(f"# baseline\n{OLD}\n", "base")
        head = self.commit(f"# baseline\n{NEW}\n", "remap")
        code, out = self.run_guard("--base", base, "--head", head, "--github")
        self.assertEqual(code, 1)
        self.assertIn(f"pinned fingerprint removed: {OLD}", out)
        self.assertIn("::error file=.gitleaksignore,title=gitleaks baseline guard::", out)

    def test_append_clean(self):
        base = self.commit(f"{OLD}\n", "base")
        head = self.commit(f"{OLD}\n{NEW}\n", "add")
        self.assertEqual(self.run_guard("--base", base, "--head", head)[0], 0)

    def test_new_file_and_unrelated_change_clean(self):
        base = self.commit(None, "no baseline yet")
        head = self.commit(f"{OLD}\n", "first baseline")
        self.assertEqual(self.run_guard("--base", base, "--head", head)[0], 0)
        later = self.commit(None, "baseline deleted")
        self.assertEqual(self.run_guard("--base", head, "--head", later)[0], 1)

    def test_bad_retired_line_refused(self):
        base = self.commit(f"{OLD}\n", "base")
        head = self.commit(f"# retired {OLD} too short\n", "retire")
        code, out = self.run_guard("--base", base, "--head", head)
        self.assertEqual(code, 1)
        self.assertIn("malformed retired line", out)

    def test_missing_base(self):
        self.commit(f"{OLD}\n", "base")
        self.assertEqual(self.run_guard("--base", "f" * 40)[0], 2)
        self.assertEqual(self.run_guard("--base", "f" * 40, "--allow-missing-base")[0], 0)


if __name__ == "__main__":
    unittest.main()
