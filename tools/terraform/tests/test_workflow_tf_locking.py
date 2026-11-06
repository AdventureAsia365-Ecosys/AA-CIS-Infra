"""S271 lessons guard G9: Terraform runs in CI never fail on a held S3 state lock.

Two PR plans of one root raced the state lock again and again ("Error acquiring the state lock", S243, S248, S256,
S265, S266): the second run went red and had to be rerun by hand. Two rules close it, and this test holds every
workflow of the repo to both:

1. Every Terraform command that takes the state lock (plan, apply, import, refresh, taint, untaint, state mv / rm /
   push, force-unlock) passes `-lock-timeout=<duration>`, so it waits for the lock instead of failing at once.
   `-lock=false` (the nightly drift report, read only) is the one exemption.
2. Every job that runs such a command sits in a concurrency group with `cancel-in-progress: false` whose name is the
   same for every run (no ref, PR number, run id or sha in it), so two runs of that workflow queue instead of racing.
   A pull_request job (the PR plans) uses the job-level group `tf-state-<root>-plan`: plans of one root queue, plans of
   two roots do not wait for each other. The PR plan groups are never an apply group: GitHub cancels the older
   PENDING job of a group, so a queued PR plan would cancel a pending apply.

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
LOCK_TIMEOUT = re.compile(r"(?<![\w-])-lock-timeout=\d+[smh]\b")
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


def job_root(job: dict) -> str:
    """The Terraform root a job works on: defaults.run.working-directory, env ROOT or a step working-directory."""
    root = (job.get("defaults") or {}).get("run", {}).get("working-directory") or (job.get("env") or {}).get("ROOT")
    if not root:
        for step in job.get("steps") or []:
            if step.get("working-directory") and LOCKING.search(step.get("run") or ""):
                root = step["working-directory"]
                break
    return os.path.basename(str(root or "").rstrip("/"))


def check_workflow(wf: dict, name: str = "workflow") -> list[str]:
    """Every rule broken by one parsed workflow, as readable strings (empty = clean)."""
    problems = []
    pr_triggered = "pull_request" in _on(wf) or "pull_request_target" in _on(wf)
    for job_id, job in (wf.get("jobs") or {}).items():
        cmds = list(locking_commands(job))
        if not cmds:
            continue
        where = f"{name}:{job_id}"
        for step, line in cmds:
            if LOCK_OFF.search(line):
                continue
            if not LOCK_TIMEOUT.search(line):
                problems.append(f"{where} step '{step}': add -lock-timeout=10m to `{line[:120]}`")
        conc = job.get("concurrency") or wf.get("concurrency")
        if not isinstance(conc, dict) or not conc.get("group"):
            problems.append(f"{where}: no concurrency group (job or workflow level) around a Terraform run")
            continue
        group = str(conc["group"])
        if conc.get("cancel-in-progress") is not False:
            problems.append(f"{where}: concurrency group '{group}' must set cancel-in-progress: false "
                            "(a cancelled running Terraform can leave a stale state lock)")
        if any(v in group for v in VOLATILE):
            problems.append(f"{where}: concurrency group '{group}' changes per run, so two runs still race")
        if pr_triggered:
            want = f"tf-state-{job_root(job)}-plan"
            if not isinstance(job.get("concurrency"), dict) or group != want:
                problems.append(f"{where}: a PR plan job needs the job-level group '{want}' (got '{group}')")
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


def test_pr_plan_groups_are_per_root_and_never_an_apply_group():
    plan = _load(os.path.join(WORKFLOWS, "terraform-plan.yml"))
    groups = {job_id: job["concurrency"]["group"] for job_id, job in plan["jobs"].items() if "concurrency" in job}
    assert groups == {"terraform-plan": "tf-state-aa365-plan", "terraform-plan-management": "tf-state-management-plan"}
    other = set()
    for name, wf in _all_workflows().items():
        if name == "terraform-plan.yml":
            continue
        for scope in [wf] + list(wf["jobs"].values()):
            if isinstance(scope.get("concurrency"), dict):
                other.add(str(scope["concurrency"]["group"]))
    assert not set(groups.values()) & other


def test_management_plan_joins_its_group_only_when_it_really_plans():
    jobs = _load(os.path.join(WORKFLOWS, "terraform-plan.yml"))["jobs"]
    assert "concurrency" not in jobs["management-paths"]
    assert jobs["management-paths"]["outputs"]["run"] == "${{ steps.paths.outputs.run }}"
    job = jobs["terraform-plan-management"]
    assert job["needs"] == "management-paths"
    assert job["if"] == "needs.management-paths.outputs.run == 'true'"


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


GOOD = {"group": "tf-state-aa365-plan", "cancel-in-progress": False}


def test_checker_accepts_a_good_pr_plan():
    assert check_workflow(_wf("terraform plan -lock-timeout=10m -out=tfplan", GOOD)) == []


def test_checker_flags_a_missing_lock_timeout_also_on_a_continued_line():
    run = "terraform plan \\\n  -out=tfplan \\\n  -detailed-exitcode\n"
    problems = check_workflow(_wf(run, GOOD))
    assert len(problems) == 1 and "-lock-timeout" in problems[0]


def test_checker_flags_apply_state_and_import_commands():
    for cmd in ('terraform -chdir="$ROOT" apply -auto-approve tfplan', "terraform state rm aws_s3_bucket.x",
                "terraform import aws_s3_bucket.x name", "RC=0; terraform-bin apply tfplan",
                "set +e; terraform refresh"):
        problems = check_workflow(_wf(cmd, {"group": "x", "cancel-in-progress": False}, on="workflow_dispatch"))
        assert any("-lock-timeout" in p for p in problems), cmd


def test_checker_ignores_non_locking_commands_and_messages():
    run = ('terraform init -input=false\nterraform validate\nterraform-bin show -json tfplan > "$J"\n'
           'echo "terraform plan exit code: $RC"\nterraform output\n# terraform apply tfplan\n')
    assert check_workflow(_wf(run)) == []


def test_checker_exempts_lock_false_but_still_wants_a_group():
    problems = check_workflow(_wf("terraform plan -lock=false -json", on="schedule"))
    assert problems == ["workflow:plan: no concurrency group (job or workflow level) around a Terraform run"]


def test_checker_wants_cancel_false_and_a_stable_group():
    p1 = check_workflow(_wf("terraform plan -lock-timeout=5m", {"group": "tf-state-aa365-plan", "cancel-in-progress": True}))
    assert any("cancel-in-progress: false" in p for p in p1)
    p2 = check_workflow(_wf("terraform plan -lock-timeout=5m", {"group": "plan-${{ github.ref }}", "cancel-in-progress": False}))
    assert any("changes per run" in p for p in p2)


def test_checker_wants_the_per_root_job_group_on_pr_plans():
    wrong_name = check_workflow(_wf("terraform plan -lock-timeout=5m", {"group": "tf-plan", "cancel-in-progress": False}))
    assert any("tf-state-aa365-plan" in p for p in wrong_name)
    workflow_level = check_workflow(_wf("terraform plan -lock-timeout=5m", GOOD, job_concurrency=False))
    assert any("job-level group" in p for p in workflow_level)
    mgmt = check_workflow(_wf("terraform plan -lock-timeout=5m", GOOD, workdir="accounts/management"))
    assert any("tf-state-management-plan" in p for p in mgmt)
