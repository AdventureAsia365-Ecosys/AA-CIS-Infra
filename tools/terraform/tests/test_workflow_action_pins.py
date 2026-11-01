"""AA-1022 (S261 architecture review G12): every action a workflow of this repo runs is pinned to a full commit SHA.

A tag (`@v7`) can be moved by whoever controls the action's repository; a 40-hex commit SHA cannot. The tag the SHA
was resolved from stays in a trailing comment (`# v7.0.1`) so that a reader, and Dependabot (.github/dependabot.yml,
github-actions ecosystem), see the version. Local reusable workflows (`./...`) and `docker://` images are exempt.
Dependabot keeps the SHA and the comment in step when it proposes an update.

Run: python3 -m pytest -q tools/terraform/tests/test_workflow_action_pins.py
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
WORKFLOWS = sorted((ROOT / ".github" / "workflows").glob("*.y*ml"))
USES = re.compile(r"^\s*(?:-\s*)?uses:\s*(\S+)(.*)$")
PINNED = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}$")
VERSION_COMMENT = re.compile(r"^\s+#\s*v\d+(\.\d+){0,2}\b")


def uses_lines():
    for wf in WORKFLOWS:
        for n, line in enumerate(wf.read_text(encoding="utf-8").splitlines(), 1):
            if line.lstrip().startswith("#"):
                continue
            m = USES.match(line)
            if m:
                yield wf.name, n, m.group(1).strip("'\""), m.group(2)


class ActionPinTest(unittest.TestCase):
    def test_there_are_workflows(self):
        self.assertGreater(len(WORKFLOWS), 10)
        self.assertGreater(len(list(uses_lines())), 50)

    def test_every_action_is_pinned_to_a_commit_sha(self):
        for wf, n, ref, rest in uses_lines():
            if ref.startswith("./") or ref.startswith("docker://"):
                continue
            with self.subTest(workflow=wf, line=n, uses=ref):
                self.assertRegex(ref, PINNED, "pin the action to the full commit SHA of its release tag")
                self.assertRegex(rest, VERSION_COMMENT, "keep the release tag in a trailing comment: # vX.Y.Z")

    def test_same_action_same_version_has_one_sha(self):
        seen = {}
        for wf, n, ref, rest in uses_lines():
            if "@" not in ref or ref.startswith("./"):
                continue
            action, sha = ref.split("@", 1)
            version = rest.strip().lstrip("#").strip().split()[0] if rest.strip() else ""
            key = (action, version)
            with self.subTest(workflow=wf, line=n, action=action, version=version):
                self.assertEqual(seen.setdefault(key, sha), sha, "one version tag maps to one commit SHA")


if __name__ == "__main__":
    unittest.main()
