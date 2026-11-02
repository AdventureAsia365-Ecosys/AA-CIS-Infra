"""AA-1023: tools/terraform/job_idle_scope.py and the job-idle gate wiring in terraform-apply.yml.

Offline: synthetic plan JSON, no Terraform, no AWS. Run from the repo root:
    python3 -m pytest -p no:cacheprovider -q tools/terraform/tests
"""
from __future__ import annotations

import json
import os
import subprocess
import sys

import yaml

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))

import job_idle_scope as js  # noqa: E402

REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
SCRIPT = os.path.join(HERE, "..", "job_idle_scope.py")
APPLY_WORKFLOW = os.path.join(REPO_ROOT, ".github", "workflows", "terraform-apply.yml")


def rc(address: str, actions: list, rtype: str | None = None) -> dict:
    rtype = rtype or address.split(".")[-2]
    return {"address": address, "type": rtype, "change": {"actions": actions, "before": {"password": "x"}}}


def plan(*changes: dict) -> dict:
    return {"format_version": "1.2", "resource_changes": list(changes)}


def test_ecs_service_update_is_gated():
    s = js.find_scope(plan(rc("module.ecs.aws_ecs_service.worker", ["update"])))
    assert s.needs_gate
    assert [c.address for c in s.gated] == ["module.ecs.aws_ecs_service.worker"]


def test_every_gated_type_and_replace_label():
    changes = [rc(f"aws_x.{t}", ["delete", "create"], t) for t in js.GATED_TYPES]
    s = js.find_scope(plan(*changes))
    assert sorted(c.type for c in s.gated) == sorted(js.GATED_TYPES)
    assert {c.actions for c in s.gated} == {"replace"}


def test_task_definition_only_is_listed_not_gated():
    s = js.find_scope(plan(rc("aws_ecs_task_definition.crm_api", ["create"]),
                           rc("aws_ecs_service.crm_api", ["no-op"]),
                           rc("aws_db_instance.main", ["read"])))
    assert not s.needs_gate
    assert [c.address for c in s.info] == ["aws_ecs_task_definition.crm_api"]


def test_other_types_are_ignored():
    s = js.find_scope(plan(rc("aws_cloudwatch_metric_alarm.a", ["update"]), rc("aws_sqs_queue.q", ["delete"])))
    assert not s.needs_gate and not s.info


def test_unreadable_plans_fail_closed(tmp_path):
    bad = tmp_path / "bad.json"
    bad.write_text("{not json")
    for scope in (js.load(str(bad)), js.load(str(tmp_path / "missing.json")),
                  js.find_scope({"resource_changes": "nope"}), js.find_scope([])):
        assert scope.error and scope.needs_gate


def test_cli_writes_output_and_summary_without_values(tmp_path):
    p = tmp_path / "plan.json"
    p.write_text(json.dumps(plan(rc("aws_ecs_service.booking", ["update"]))))
    out, summary = tmp_path / "out", tmp_path / "summary"
    r = subprocess.run([sys.executable, "-B", SCRIPT, str(p), "--github-output", str(out), "--summary", str(summary)],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    assert out.read_text() == "gated=true\n"
    text = summary.read_text()
    assert "### Job-idle scope" in text and "`aws_ecs_service.booking` (update)" in text
    assert "password" not in text and "password" not in r.stdout

    p.write_text(json.dumps(plan(rc("aws_sqs_queue.q", ["update"]))))
    out.unlink()
    subprocess.run([sys.executable, "-B", SCRIPT, str(p), "--github-output", str(out)], check=True,
                   capture_output=True)
    assert out.read_text() == "gated=false\n"


# ── wiring in terraform-apply.yml ──
def _workflow() -> dict:
    with open(APPLY_WORKFLOW, encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def _steps(job: str = "terraform-apply") -> list:
    return _workflow()["jobs"][job]["steps"]


def _index(steps: list, name: str) -> int:
    for i, s in enumerate(steps):
        if s.get("name") == name:
            return i
    raise AssertionError(f"step {name!r} missing")


def test_scope_runs_before_the_plan_guard_deletes_the_json_and_gate_right_before_apply():
    steps = _steps()
    export, scope, guard = (_index(steps, n) for n in ("Export plan JSON", "Job-idle scope", "Plan guard"))
    gate, apply = _index(steps, "Job-idle gate"), _index(steps, "Terraform Apply")
    assert export < scope < guard < gate < apply
    assert gate == apply - 1
    assert steps[scope]["id"] == "scope"
    assert 'tools/terraform/job_idle_scope.py "$PLAN_JSON" --github-output "$GITHUB_OUTPUT"' in steps[scope]["run"]
    assert "steps.scope.outputs.gated == 'true'" in steps[gate]["if"]
    assert "env.GUARD_SELFTEST != 'true'" in steps[gate]["if"]
    assert steps[gate]["run"] == "bash .github/scripts/job-idle-gate.sh"
    for key in ("CLUSTER", "SERVICE", "BUCKET", "LOG_GROUP"):
        assert key in steps[gate]["env"]


def test_override_input_reaches_the_gate_only_through_env():
    wf = _workflow()
    inputs = wf[True]["workflow_dispatch"]["inputs"] if True in wf else wf["on"]["workflow_dispatch"]["inputs"]
    assert inputs["override_busy_jobs"]["type"] == "string" and inputs["override_busy_jobs"]["default"] == ""
    assert inputs["idle_gate_check"]["type"] == "boolean" and inputs["idle_gate_check"]["default"] is False
    job = wf["jobs"]["terraform-apply"]
    assert job["env"]["OVERRIDE"] == "${{ inputs.override_busy_jobs }}"
    for s in job["steps"]:
        assert "inputs.override_busy_jobs" not in (s.get("run") or "")
    check = _steps()[_index(_steps(), "Check guard inputs")]["run"]
    assert "override_busy_jobs must be empty, or one non-blank line of at most 200 characters" in check


def test_check_only_job_runs_the_same_gate_without_terraform():
    wf = _workflow()
    job = wf["jobs"]["idle-gate-check"]
    assert job["environment"] == "prod"
    assert "inputs.idle_gate_check" in job["if"] and "refs/heads/main" in job["if"]
    runs = " ".join(s.get("run") or "" for s in job["steps"])
    assert "bash .github/scripts/job-idle-gate.sh" in runs
    assert "terraform" not in runs
    gate = job["steps"][-1]
    assert gate["env"]["OVERRIDE"] == "${{ inputs.override_busy_jobs }}"
    # The apply job never runs on a check-only dispatch.
    assert "!inputs.idle_gate_check" in wf["jobs"]["terraform-apply"]["if"]
