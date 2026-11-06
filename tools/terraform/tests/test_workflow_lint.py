"""Tests of .github/scripts/workflow_lint.py and the Workflow Lint workflow (S271 lessons guard G15).

Offline: synthetic workflows for each rule, then the repo's own workflows (must be clean), then the shape of
.github/workflows/workflow-lint.yml (actionlint pinned by version and SHA-256, checked before it runs).
Run: python3 -m pytest -p no:cacheprovider -q tools/terraform/tests/test_workflow_lint.py
"""
from __future__ import annotations

import importlib.util
import os
import re
import subprocess
import textwrap

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
SCRIPT = os.path.join(REPO_ROOT, ".github", "scripts", "workflow_lint.py")
WORKFLOW = os.path.join(REPO_ROOT, ".github", "workflows", "workflow-lint.yml")

_spec = importlib.util.spec_from_file_location("workflow_lint", SCRIPT)
wl = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(wl)


def _lint(body: str, repo_root: str = REPO_ROOT) -> list[str]:
    return wl.lint_workflow("demo.yml", textwrap.dedent(body), repo_root)


def test_wl1_sensitive_vars_are_refused_secrets_and_plain_vars_pass():
    bad = _lint("""
        on: push
        jobs:
          a:
            runs-on: ubuntu-24.04
            steps:
              - uses: aws-actions/configure-aws-credentials@0000000000000000000000000000000000000000 # v6.3.0
                with:
                  role-to-assume: ${{ vars.DEMO_SCRUB_ROLE_ARN }}
              - run: echo "${{ vars.DEMO_API_KEY }} ${{ vars.Deploy_Role }}"
        """)
    assert len(bad) == 3 and all(":WL1 " in f for f in bad)
    assert "secrets.DEMO_SCRUB_ROLE_ARN" in bad[0]
    ok = _lint("""
        on: push
        jobs:
          a:
            runs-on: ubuntu-24.04
            steps:
              # vars.DEMO_OLD_ROLE_ARN was moved to secrets (a comment is not a use)
              - run: echo "${{ vars.DEMO_APP_ID }} ${{ vars.PROD_ACCOUNT_READY }} ${{ secrets.DEMO_ROLE_ARN }}"
        """)
    assert ok == []


def test_wl2_playwright_jobs_pin_the_runner():
    bad = _lint("""
        on: push
        jobs:
          e2e:
            runs-on: ubuntu-latest
            steps:
              - run: npx playwright install --with-deps chromium
          other:
            runs-on: ubuntu-latest
            steps:
              - run: echo build
        """)
    assert len(bad) == 1 and ":e2e:WL2 " in bad[0] and "ubuntu-24.04" in bad[0]
    ok = _lint("""
        on: push
        jobs:
          e2e:
            runs-on: ubuntu-24.04
            steps:
              - uses: demo-org/playwright-report@0000000000000000000000000000000000000000 # v1.0.0
        """)
    assert ok == []


def test_wl3_npm_ci_needs_a_tracked_lockfile(tmp_path):
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
    (tmp_path / "web").mkdir()
    (tmp_path / "web" / "package-lock.json").write_text("{}")
    (tmp_path / "api").mkdir()
    (tmp_path / "api" / "package-lock.json").write_text("{}")  # exists but not tracked (gitignored, S220)
    subprocess.run(["git", "-C", str(tmp_path), "add", "web/package-lock.json"], check=True)
    body = """
        on: push
        jobs:
          web:
            runs-on: ubuntu-24.04
            defaults:
              run:
                working-directory: web
            steps:
              - run: npm ci && npm test
          api:
            runs-on: ubuntu-24.04
            steps:
              - working-directory: api
                run: |
                  # npm ci in a comment is not a run
                  npm ci
          root:
            runs-on: ubuntu-24.04
            steps:
              - run: npm ci
          dyn:
            runs-on: ubuntu-24.04
            steps:
              - working-directory: ${{ matrix.app }}
                run: npm ci
        """
    findings = _lint(body, str(tmp_path))
    assert [f.split(":")[1] for f in findings] == ["api", "root", "dyn"]
    assert "api/package-lock.json" in findings[0] and "package-lock.json" in findings[1]
    assert "expression working-directory" in findings[2]


def test_the_repo_workflows_are_clean():
    findings = []
    wf_dir = os.path.join(REPO_ROOT, ".github", "workflows")
    for name in sorted(os.listdir(wf_dir)):
        if name.endswith((".yml", ".yaml")):
            with open(os.path.join(wf_dir, name), encoding="utf-8") as fh:
                findings += wl.lint_workflow(name, fh.read())
    assert findings == []


def test_cli_exit_codes(tmp_path):
    good = tmp_path / "good.yml"
    good.write_text("on: push\njobs:\n  a:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: echo ok\n")
    bad = tmp_path / "bad.yml"
    bad.write_text("on: push\njobs:\n  a:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: echo ${{ vars.DEMO_ROLE_ARN }}\n")
    broken = tmp_path / "broken.yml"
    broken.write_text("on: [push\n")
    assert wl.main([str(good)]) == 0
    assert wl.main([str(good), str(bad)]) == 1
    assert wl.main([str(broken)]) == 2


def test_workflow_lint_workflow_pins_and_verifies_actionlint():
    with open(WORKFLOW, encoding="utf-8") as fh:
        text = fh.read()
    wf = yaml.safe_load(text)
    on = wf.get("on", wf.get(True))
    for event in ("pull_request", "push"):
        assert ".github/workflows/**" in on[event]["paths"] and ".github/scripts/workflow_lint.py" in on[event]["paths"]
    assert wf["permissions"] == {"contents": "read"}
    job = wf["jobs"]["workflow-lint"]
    assert job["runs-on"] == "ubuntu-24.04"
    assert re.fullmatch(r"\d+\.\d+\.\d+", job["env"]["ACTIONLINT_VERSION"])
    assert re.fullmatch(r"[0-9a-f]{64}", job["env"]["ACTIONLINT_SHA256"])
    steps = {s.get("name", ""): s for s in job["steps"]}
    install = steps["Install actionlint (pinned, checksum verified)"]["run"]
    assert "sha256sum -c -" in install and install.index("sha256sum -c -") < install.index("tar -xzf")
    assert "releases/download/v${ACTIONLINT_VERSION}/" in install
    assert steps["actionlint"]["run"].startswith("actionlint ")
    assert ".github/scripts/workflow_lint.py" in steps["Repo workflow rules"]["run"]
    assert steps["Checkout"]["with"]["persist-credentials"] is False
    assert "secrets." not in text
