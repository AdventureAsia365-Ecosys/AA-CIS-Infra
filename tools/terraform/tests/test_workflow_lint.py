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


# git's repo-local variables (`git rev-parse --local-env-vars`). A hook exports GIT_DIR & co.; a test that inherits them
# and runs `git init` in tmp_path works on the real clone instead (S273: core.bare=true in the config every worktree of
# the clone shares). scripts/test_git_env_isolation.py checks this list against git and runs this file with a leak.
GIT_REPO_VARS = ("GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CONFIG", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT",
                 "GIT_OBJECT_DIRECTORY", "GIT_DIR", "GIT_WORK_TREE", "GIT_IMPLICIT_WORK_TREE", "GIT_GRAFT_FILE",
                 "GIT_INDEX_FILE", "GIT_NO_REPLACE_OBJECTS", "GIT_REPLACE_REF_BASE", "GIT_PREFIX", "GIT_SHALLOW_FILE",
                 "GIT_COMMON_DIR")


def _git_in(tmp_path, monkeypatch, *args: str) -> None:
    """Run git in the temporary repo only: none of the repo-local variables, cwd = tmp_path, no user/system config.

    The variables are also dropped from os.environ (monkeypatch), so the lint's own `git -C` call inherits none.
    """
    for name in GIT_REPO_VARS:
        monkeypatch.delenv(name, raising=False)
    env = {k: v for k, v in os.environ.items() if k not in GIT_REPO_VARS}
    env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
    subprocess.run(["git", *args], cwd=str(tmp_path), env=env, check=True, capture_output=True)


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


def test_wl3_npm_ci_needs_a_tracked_lockfile(tmp_path, monkeypatch):
    _git_in(tmp_path, monkeypatch, "init", "-q", ".")
    (tmp_path / "web").mkdir()
    (tmp_path / "web" / "package-lock.json").write_text("{}")
    (tmp_path / "api").mkdir()
    (tmp_path / "api" / "package-lock.json").write_text("{}")  # exists but not tracked (gitignored, S220)
    _git_in(tmp_path, monkeypatch, "add", "web/package-lock.json")
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
    wl.UNCHECKED.clear()
    findings = _lint(body, str(tmp_path))
    assert [f.split(":")[1] for f in findings] == ["api", "root"]
    assert "api/package-lock.json" in findings[0] and "package-lock.json" in findings[1]
    # AA-1024 S272: an expression working-directory (a matrix of other repos' apps) is listed as unchecked, not refused
    assert wl.UNCHECKED == ["demo.yml:dyn: npm ci in ${{ matrix.app }}"]


def test_skip_switch_and_shell_comments_are_not_a_playwright_use():
    body = """
        on: push
        jobs:
          a:
            runs-on: ubuntu-latest
            steps:
              - run: |
                  # the invented smoke needs Playwright and a live host, so it is not run here
                  echo ${{ vars.DEMO_ROLE_ARN }}
        """
    assert [f.split(":")[2].split()[0] for f in _lint(body)] == ["WL1"]
    assert wl.lint_workflow("demo.yml", textwrap.dedent(body), REPO_ROOT, frozenset({"WL1"})) == []
    assert wl.main(["--skip", "WL9"]) == 2


def test_the_repo_workflows_are_clean():
    findings = []
    wf_dir = os.path.join(REPO_ROOT, ".github", "workflows")
    for name in sorted(os.listdir(wf_dir)):
        if name.endswith((".yml", ".yaml")):
            with open(os.path.join(wf_dir, name), encoding="utf-8") as fh:
                findings += wl.lint_workflow(name, fh.read())
    assert findings == []


def test_wl4_wl5_cache_saves_and_external_downloads():
    # S273 (AA-1024): the full rule tests live in the vendored unittest file of the app repos; here one bad and one good
    # shape of each, so a change of the shared workflow_lint.py is caught in this repo too.
    bad = _lint("""
        on: pull_request
        jobs:
          a:
            runs-on: ubuntu-24.04
            steps:
              - uses: actions/setup-python@0000000000000000000000000000000000000000 # v7.1.0
                with:
                  cache: pip
              - uses: anchore/sbom-action@0000000000000000000000000000000000000000 # v0.24.3
              - name: Fetch demotool
                run: curl -fsSL -o d.tgz https://github.com/demo-org/demotool/releases/download/v1.0.0/d.tar.gz
        """)
    assert [f.split(":")[2].split()[0] for f in bad] == ["WL4", "WL5", "WL5"]
    ok = _lint("""
        on: push
        jobs:
          a:
            runs-on: ubuntu-24.04
            steps:
              - id: c
                uses: actions/cache/restore@0000000000000000000000000000000000000000 # v6.1.0
                with:
                  path: bin
                  key: demo
              - uses: actions/cache/save@0000000000000000000000000000000000000000 # v6.1.0
                if: github.ref == 'refs/heads/main' && steps.c.outputs.cache-hit != 'true'
                with:
                  path: bin
                  key: demo
              - uses: ./.github/actions/release-bin
                with:
                  tool: demotool
        """)
    assert ok == []


def test_the_repo_composite_actions_are_clean():
    actions = os.path.join(REPO_ROOT, ".github", "actions")
    findings = []
    for name in sorted(os.listdir(actions)):
        path = os.path.join(actions, name, "action.yml")
        if os.path.isfile(path):
            with open(path, encoding="utf-8") as fh:
                findings += wl.lint_action(name, fh.read())
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
    steps = {s.get("name", ""): s for s in job["steps"]}
    # S273 (AA-1024): actionlint from the cached, sha256-pinned release-bin action (pins.txt), not a bare download.
    install = steps["Install actionlint (pinned, checksum verified)"]
    assert install["uses"] == "./.github/actions/release-bin" and install["with"] == {"tool": "actionlint"}
    pins = os.path.join(REPO_ROOT, ".github", "actions", "release-bin", "pins.txt")
    with open(pins, encoding="utf-8") as fh:
        assert re.search(r"(?m)^actionlint v\d+\.\d+\.\d+ x86_64 [0-9a-f]{64} https://github\.com/rhysd/", fh.read())
    for needle in ("test_release_bin.py", "test_cache_cleanup.py"):
        assert needle in steps["Repo workflow rules"]["run"]
    assert steps["actionlint"]["run"].startswith("actionlint ")
    assert ".github/scripts/workflow_lint.py" in steps["Repo workflow rules"]["run"]
    assert steps["Checkout"]["with"]["persist-credentials"] is False
    assert "secrets." not in text
