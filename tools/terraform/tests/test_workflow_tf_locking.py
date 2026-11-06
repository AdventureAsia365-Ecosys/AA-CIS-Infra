"""S271 lessons guard G9: Terraform runs in CI never fail on a held S3 state lock.

Two PR plans of one root raced the state lock again and again ("Error acquiring the state lock", S243, S248, S256,
S265, S266): the second run went red and had to be rerun by hand. The rules below close it, and this test holds every
workflow of the repo to them:

1. Every Terraform command that takes the state lock (plan, apply, import, refresh, taint, untaint, state mv / rm /
   push, force-unlock) passes `-lock-timeout=<duration>`, so it waits for the lock instead of failing at once. In a
   pull_request workflow (the PR plans) the wait is at least 20 minutes: it must cover a Dev apply and a burst of PR
   plans queueing on the same lock. `-lock=false` (the nightly drift report, read only) is the one exemption. A job
   with `timeout-minutes` must outlast its longest lock wait.
2. A pull_request job that takes the lock has NO concurrency group (job or workflow level). GitHub keeps one PENDING
   job per group and cancels the older pending one, so a shared group would cancel the required plan check of all
   but two PRs of a burst (the bot migration-copy PRs arrive five or six at a time); the lock wait of rule 1 already
   lets them pass one after the other. A per-PR group adds nothing over the lock wait, and with cancel-in-progress a
   cancelled running plan could leave a stale lock.
3. Every other job that takes the lock sits in a concurrency group with `cancel-in-progress: false` whose name is the
   same for every run (no ref, PR number, run id or sha in it), so two dispatched runs of that workflow queue instead
   of racing (one pending apply at a time is the intended behaviour there).

Offline (PyYAML only). Run: python3 -m pytest -p no:cacheprovider -q tools/terraform/tests/test_workflow_tf_locking.py
"""
from __future__ import annotations

import os
import re

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
WORKFLOWS = os.path.join(REPO_ROOT, ".github", "workflows")

# A Terraform command at the start of a shell command (line start, after ; && || | ( $( or `!`).
LOCKING = re.compile(
    r"(?:^|[;&|(!]|\$\()\s*(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*terraform(?:-bin)?(?:\s+-chdir=\S+)?\s+"
    r"(?P<cmd>plan|apply|import|refresh|taint|untaint|force-unlock|state\s+(?:mv|rm|push|replace-provider))\b"
)
LOCK_TIMEOUT = re.compile(r"(?<![\w-])-lock-timeout=(?P<n>\d+)(?P<unit>[smh])\b")
PR_MIN_WAIT_S = 20 * 60  # rule 1: a PR plan waits at least this long for the lock
LOCK_OFF = re.compile(r"(?<![\w-])-lock=false\b")
VOLATILE = ("github.ref", "github.head_ref", "github.event", "github.run_id", "github.run_number", "github.sha")


def _load(path: str) -> dict:
    with open(path, encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def _on(wf: dict) -> dict:
    on = wf.get("on", wf.get(True))  # PyYAML reads a bare `on:` key as True
    if isinstance(on, str):
        return {on: None}
    if isinstance(on, list):
        return {k: None for k in on}
    return on or {}


def _logical_lines(script: str):
    """Shell lines with backslash continuations joined; comment-only lines and echo / printf lines dropped."""
    for line in re.sub(r"\\\n\s*", " ", script).splitlines():
        text = line.strip()
        if not text or text.startswith("#") or re.match(r"(echo|printf)\b", text):
            continue
        yield text


def locking_commands(job: dict):
    """(step name, command line) of every state-locking Terraform command in the job's run steps."""
    for step in job.get("steps") or []:
        for line in _logical_lines(step.get("run") or ""):
            if LOCKING.search(line):
                yield step.get("name", step.get("uses", "?")), line


def _seconds(m: re.Match) -> int:
    return int(m.group("n")) * {"s": 1, "m": 60, "h": 3600}[m.group("unit")]


def check_workflow(wf: dict, name: str = "workflow") -> list[str]:
    """Every rule broken by one parsed workflow, as readable strings (empty = clean)."""
    problems = []
    pr_triggered = "pull_request" in _on(wf) or "pull_request_target" in _on(wf)
    for job_id, job in (wf.get("jobs") or {}).items():
        cmds = list(locking_commands(job))
        if not cmds:
            continue
        where = f"{name}:{job_id}"
        waits = []
        for step, line in cmds:
            if LOCK_OFF.search(line):
                continue
            m = LOCK_TIMEOUT.search(line)
            if not m:
                want = "20m" if pr_triggered else "10m"
                problems.append(f"{where} step '{step}': add -lock-timeout={want} to `{line[:120]}`")
                continue
            waits.append(_seconds(m))
            if pr_triggered and _seconds(m) < PR_MIN_WAIT_S:
                problems.append(f"{where} step '{step}': a PR plan waits at least -lock-timeout=20m "
                                f"(covers an apply and a burst of PR plans), got `{m.group(0)}`")
        limit = job.get("timeout-minutes")
        if isinstance(limit, int) and waits and limit * 60 <= max(waits):
            problems.append(f"{where}: timeout-minutes {limit} ends the job before its lock wait does")
        conc = job.get("concurrency") or wf.get("concurrency")
        if pr_triggered:
            if conc:
                problems.append(f"{where}: a PR plan job has no concurrency group (job or workflow level): GitHub "
                                "cancels the older pending job of a group, so a burst of PRs gets cancelled required "
                                "checks; -lock-timeout already makes the plans wait for each other")
            continue
        if not isinstance(conc, dict) or not conc.get("group"):
            problems.append(f"{where}: no concurrency group (job or workflow level) around a Terraform run")
            continue
        group = str(conc["group"])
        if conc.get("cancel-in-progress") is not False:
            problems.append(f"{where}: concurrency group '{group}' must set cancel-in-progress: false "
                            "(a cancelled running Terraform can leave a stale state lock)")
        if any(v in group for v in VOLATILE):
            problems.append(f"{where}: concurrency group '{group}' changes per run, so two runs still race")
    return problems


def _all_workflows() -> dict[str, dict]:
    return {n: _load(os.path.join(WORKFLOWS, n)) for n in sorted(os.listdir(WORKFLOWS)) if n.endswith((".yml", ".yaml"))}


# --- the repo --------------------------------------------------------------------------------------------------------

def test_every_terraform_run_waits_for_the_lock_and_is_serialised():
    problems = []
    for name, wf in _all_workflows().items():
        problems += check_workflow(wf, name)
    assert problems == [], "\n".join(problems)


def test_the_scan_sees_the_known_terraform_runs():
    """Guards against a vacuous pass: the parser must find the plan / apply jobs it is meant to hold."""
    found = {}
    for name, wf in _all_workflows().items():
        for job_id, job in wf["jobs"].items():
            n = len(list(locking_commands(job)))
            if n:
                found[f"{name}:{job_id}"] = n
    for key in ("terraform-plan.yml:terraform-plan", "terraform-plan.yml:terraform-plan-management",
                "terraform-apply.yml:terraform-apply", "terraform-apply.yml:plan-management",
                "terraform-apply.yml:terraform-apply-management", "terraform-drift.yml:drift"):
        assert key in found, (key, found)
    assert found["terraform-apply.yml:terraform-apply"] == 2  # plan + apply
    assert sum(found.values()) >= 10


def test_pr_plans_have_no_group_and_wait_twenty_minutes():
    """Review finding (S271): a shared PR-plan group cancelled the required check of all but two PRs of a burst."""
    plan = _load(os.path.join(WORKFLOWS, "terraform-plan.yml"))
    assert "concurrency" not in plan
    for job_id in ("terraform-plan", "terraform-plan-management"):
        job = plan["jobs"][job_id]
        assert "concurrency" not in job, job_id
        lines = [line for _, line in locking_commands(job)]
        assert lines and all("-lock-timeout=20m" in line for line in lines), (job_id, lines)


def test_dev_apply_waits_as_long_as_a_pr_plan():
    job = _load(os.path.join(WORKFLOWS, "terraform-apply.yml"))["jobs"]["terraform-apply"]
    lines = [line for _, line in locking_commands(job)]
    assert len(lines) == 2 and all("-lock-timeout=20m" in line for line in lines), lines


def test_drift_report_stays_lock_free():
    job = _load(os.path.join(WORKFLOWS, "terraform-drift.yml"))["jobs"]["drift"]
    lines = [line for _, line in locking_commands(job)]
    assert lines and all(LOCK_OFF.search(line) for line in lines)


# --- the checker itself (synthetic workflows) ------------------------------------------------------------------------

def _wf(run: str, concurrency=None, on="pull_request", job_concurrency=True, workdir="accounts/aa365") -> dict:
    job = {"runs-on": "ubuntu-24.04", "defaults": {"run": {"working-directory": workdir}}, "steps": [{"name": "Plan", "run": run}]}
    wf = {True: {on: None}, "jobs": {"plan": job}}
    if concurrency is not None:
        (job if job_concurrency else wf)["concurrency"] = concurrency
    return wf


GROUP = {"group": "terraform-apply-dev", "cancel-in-progress": False}


def test_checker_accepts_a_good_pr_plan():
    assert check_workflow(_wf("terraform plan -lock-timeout=20m -out=tfplan")) == []


def test_checker_flags_a_missing_lock_timeout_also_on_a_continued_line():
    run = "terraform plan \\\n  -out=tfplan \\\n  -detailed-exitcode\n"
    problems = check_workflow(_wf(run))
    assert len(problems) == 1 and "-lock-timeout=20m" in problems[0]


def test_checker_wants_a_twenty_minute_wait_on_pr_plans_only():
    short = check_workflow(_wf("terraform plan -lock-timeout=10m -out=tfplan"))
    assert len(short) == 1 and "at least -lock-timeout=20m" in short[0]
    assert check_workflow(_wf("terraform plan -lock-timeout=1h -out=tfplan")) == []
    assert check_workflow(_wf("terraform plan -lock-timeout=10m", GROUP, on="workflow_dispatch")) == []


def test_checker_flags_apply_state_and_import_commands():
    for cmd in ('terraform -chdir="$ROOT" apply -auto-approve tfplan', "terraform state rm aws_s3_bucket.x",
                "terraform import aws_s3_bucket.x name", "RC=0; terraform-bin apply tfplan",
                "set +e; terraform refresh"):
        problems = check_workflow(_wf(cmd, GROUP, on="workflow_dispatch"))
        assert any("-lock-timeout" in p for p in problems), cmd


def test_checker_ignores_non_locking_commands_and_messages():
    run = ('terraform init -input=false\nterraform validate\nterraform-bin show -json tfplan > "$J"\n'
           'echo "terraform plan exit code: $RC"\nterraform output\n# terraform apply tfplan\n')
    assert check_workflow(_wf(run, {"group": "x"})) == []


def test_checker_exempts_lock_false_but_still_wants_a_group():
    problems = check_workflow(_wf("terraform plan -lock=false -json", on="schedule"))
    assert problems == ["workflow:plan: no concurrency group (job or workflow level) around a Terraform run"]


def test_checker_wants_cancel_false_and_a_stable_group_outside_prs():
    p1 = check_workflow(_wf("terraform plan -lock-timeout=5m", dict(GROUP, **{"cancel-in-progress": True}),
                            on="workflow_dispatch"))
    assert any("cancel-in-progress: false" in p for p in p1)
    p2 = check_workflow(_wf("terraform plan -lock-timeout=5m", {"group": "plan-${{ github.ref }}", "cancel-in-progress": False},
                            on="workflow_dispatch"))
    assert any("changes per run" in p for p in p2)


def test_checker_refuses_any_group_on_a_pr_plan():
    for group, job_level in ((GROUP, True), (GROUP, False),
                             ({"group": "tf-state-aa365-plan", "cancel-in-progress": False}, True),
                             ({"group": "plan-${{ github.event.pull_request.number }}", "cancel-in-progress": True}, True)):
        problems = check_workflow(_wf("terraform plan -lock-timeout=20m", group, job_concurrency=job_level))
        assert len(problems) == 1 and "no concurrency group" in problems[0], (group, problems)


def test_checker_wants_the_job_to_outlast_its_lock_wait():
    wf = _wf("terraform plan -lock-timeout=20m")
    wf["jobs"]["plan"]["timeout-minutes"] = 20
    assert any("timeout-minutes 20" in p for p in check_workflow(wf))
    wf["jobs"]["plan"]["timeout-minutes"] = 30
    assert check_workflow(wf) == []
