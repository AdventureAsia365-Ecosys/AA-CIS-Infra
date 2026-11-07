#!/usr/bin/env python3
"""Workflow lint (S271 lessons guard G15): the repo-specific rules actionlint does not know.

Each rule comes from a CI incident written in the root lessons log:

  WL1 vars-sensitive   No `vars.<NAME>` whose name says ARN, ROLE, ACCOUNT_ID, SECRET, TOKEN, PASSWORD or KEY. A
                       variable is printed in clear in the run log, and this repo's logs are public; a role ARN
                       carries the account id (Scrub corpus workflow read vars.SCRUB_CORPUS_ROLE_ARN, S249). Use
                       `secrets.*`, which GitHub masks.
  WL2 playwright-pin   A job that runs Playwright pins `runs-on: ubuntu-24.04`: when ubuntu-latest moved to 26.04,
                       "Playwright does not support chromium on ubuntu26.04-x64" blocked a production promotion (S252,
                       S253).
  WL3 npm-ci-lockfile  A step that runs `npm ci` reads a package-lock.json that git tracks in its working directory:
                       a gitignored lockfile broke a workflow at its first run (S220).

The workflow `Workflow Lint` runs this next to a pinned actionlint. Stdlib + PyYAML.
Run: python3 -B .github/scripts/workflow_lint.py [--skip WL1[,WL2]] [WORKFLOW.yml ...]
     (default: every .github/workflows file)
Exit 0 = clean, 1 = findings (one line each: file:job:rule message), 2 = a workflow does not parse.

One file, the same in every repo (AA-CIS-Infra first, vendored into the root, AA-CIS-App, AA-Booking, AA-Partner and
AA-TripPlanner-Web by AA-1024, S272): change it in all of them in the same wave. `--skip` turns a rule off for a repo
that still has uses to move (Booking and Partner read vars.AWS_ROLE_ARN until it moves to a secret, a repo-settings
step for the tech lead); a shell comment inside a `run:` is never a use; a `working-directory` built from an expression
(a matrix of other repos' apps) cannot be checked statically and is listed as unchecked, not as a finding.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys

import yaml

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
SENSITIVE_VAR = re.compile(
    r"\bvars\.([A-Za-z0-9_]*(?:ARN|ROLE|ACCOUNT_ID|SECRET|TOKEN|PASSWORD|PRIVATE_KEY|API_KEY|ACCESS_KEY)[A-Za-z0-9_]*)",
    re.I,
)
PLAYWRIGHT = re.compile(r"playwright", re.I)
NPM_CI = re.compile(r"(?:^|[;&|(]|\s)npm\s+ci\b", re.M)
PINNED_RUNNER = "ubuntu-24.04"


def _strip_comments(text: str) -> str:
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))


def _job_text(job: dict) -> str:
    """The job as text for the Playwright search, without the shell comments of its run: scripts."""
    steps = [{**s, "run": _strip_comments(str(s["run"]))} if isinstance(s, dict) and "run" in s else s
             for s in job.get("steps") or []]
    return yaml.safe_dump({**job, "steps": steps}, sort_keys=False)


def tracked(path: str, repo_root: str) -> bool:
    """True when git tracks the file (falls back to "exists" outside a git checkout)."""
    try:
        proc = subprocess.run(["git", "-C", repo_root, "ls-files", "--error-unmatch", path],
                              capture_output=True, text=True, timeout=30)
        if proc.returncode == 0:
            return True
        if "not a git repository" not in proc.stderr:
            return False
    except (OSError, subprocess.TimeoutExpired):
        pass
    return os.path.isfile(os.path.join(repo_root, path))


RULES = ("WL1", "WL2", "WL3")
UNCHECKED: list[str] = []   # npm ci steps whose working-directory is an expression (printed in the summary)


def lint_workflow(name: str, text: str, repo_root: str = REPO_ROOT, skip: frozenset = frozenset()) -> list[str]:
    wf = yaml.safe_load(text) or {}
    findings = []
    for m in ([] if "WL1" in skip else SENSITIVE_VAR.finditer(_strip_comments(text))):
        findings.append(f"{name}:-:WL1 vars.{m.group(1)} looks sensitive (ARN / role / key): use secrets.{m.group(1)}"
                        " (variables are printed in clear in the public run log)")
    for job_id, job in (wf.get("jobs") or {}).items():
        if not isinstance(job, dict):
            continue
        body = _job_text({k: v for k, v in job.items() if k != "name"})
        runs_on = job.get("runs-on")
        if "WL2" not in skip and PLAYWRIGHT.search(body) and runs_on != PINNED_RUNNER:
            findings.append(f"{name}:{job_id}:WL2 a Playwright job must pin runs-on: {PINNED_RUNNER} (got {runs_on!r})")
        default_dir = ((job.get("defaults") or {}).get("run") or {}).get("working-directory") or "."
        for step in job.get("steps") or []:
            run = _strip_comments(str(step.get("run") or ""))
            if "WL3" in skip or not NPM_CI.search(run):
                continue
            wd = str(step.get("working-directory") or default_dir)
            if "${{" in wd:
                UNCHECKED.append(f"{name}:{job_id}: npm ci in {wd}")
                continue
            lock = os.path.normpath(os.path.join(wd, "package-lock.json")).replace(os.sep, "/")
            if not tracked(lock, repo_root):
                findings.append(f"{name}:{job_id}:WL3 npm ci needs a git-tracked {lock}")
    return findings


def main(argv: list[str]) -> int:
    argv, skip = list(argv), set()
    while argv and argv[0] == "--skip":
        if len(argv) < 2 or not set(argv[1].split(",")) <= set(RULES):
            print(f"--skip needs rule ids from {', '.join(RULES)}", file=sys.stderr)
            return 2
        skip |= set(argv[1].split(","))
        argv = argv[2:]
    wf_dir = os.path.join(REPO_ROOT, ".github", "workflows")
    paths = argv or [os.path.join(wf_dir, n) for n in sorted(os.listdir(wf_dir)) if n.endswith((".yml", ".yaml"))]
    findings = []
    UNCHECKED.clear()
    for path in paths:
        try:
            with open(path, encoding="utf-8") as fh:
                findings += lint_workflow(os.path.basename(path), fh.read(), skip=frozenset(skip))
        except (OSError, yaml.YAMLError) as exc:
            print(f"{path}: cannot read: {exc}", file=sys.stderr)
            return 2
    for f in findings:
        print(f)
    for u in UNCHECKED:
        print(f"unchecked (expression working-directory): {u}")
    skipped = f", skipped {','.join(sorted(skip))}" if skip else ""
    print(f"workflow_lint: {len(paths)} workflows, {len(findings)} findings{skipped}")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
