"""Tests for tools/terraform/drift_report.py and the shape of .github/workflows/terraform-drift.yml (AA-879 part B).

Offline: synthetic `terraform plan -json` logs, no AWS. Run: python3 -m pytest -p no:cacheprovider -q tools/terraform/tests
"""
from __future__ import annotations

import json
import os
import re
import sys

import yaml

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))

import drift_report as dr  # noqa: E402

REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
WORKFLOWS = os.path.join(REPO_ROOT, ".github", "workflows")
DRIFT_WF = os.path.join(WORKFLOWS, "terraform-drift.yml")
PLAN_WF = os.path.join(WORKFLOWS, "terraform-plan.yml")
ACC = "111122223333"  # documentation placeholder, not a real account


def _change(kind: str, addr: str, action: str) -> str:
    return json.dumps({"@level": "info", "@message": f"{addr}: {action}", "type": kind,
                       "change": {"resource": {"addr": addr, "resource_type": addr.split(".")[0]}, "action": action}})


VERSION = json.dumps({"@level": "info", "@message": "Terraform 1.15.5", "type": "version"})
SUMMARY_2 = json.dumps({"@level": "info", "@message": "Plan: 0 to add, 1 to change, 0 to destroy.",
                        "type": "change_summary", "changes": {"add": 0, "change": 1, "remove": 0}})


def _log(tmp_path, *lines: str) -> str:
    p = tmp_path / "plan.jsonl"
    p.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return str(p)


def _load(path: str) -> dict:
    with open(path, encoding="utf-8") as fh:
        return yaml.safe_load(fh)


# --- parser / report ---------------------------------------------------------------------------------------------

def test_parse_collects_drift_planned_outputs_and_errors():
    rep = dr.parse_plan_log([
        VERSION,
        _change("resource_drift", "aws_security_group.alb", "update"),
        _change("planned_change", "aws_security_group.alb", "update"),
        _change("planned_change", "data.aws_iam_policy_document.x", "read"),
        _change("planned_change", "aws_s3_bucket.noop", "noop"),
        json.dumps({"type": "outputs", "outputs": {"b": {"action": "create"}, "a": {"action": "noop"}}}),
        json.dumps({"type": "diagnostic", "diagnostic": {"severity": "warning", "summary": "deprecated"}}),
        json.dumps({"type": "diagnostic", "diagnostic": {"severity": "error", "summary": "boom", "detail": "d"}}),
        SUMMARY_2,
        "not json at all",
        "",
    ])
    assert rep.drift == [("aws_security_group.alb", "update")]
    assert rep.planned == [("aws_security_group.alb", "update")]  # read and noop are not changes
    assert rep.outputs == [("b", "create")]
    assert rep.errors == [("boom", "d")]
    assert rep.change_summary.startswith("Plan: 0 to add, 1 to change")
    assert rep.skipped_lines == 1


def test_in_sync_is_green(tmp_path, capsys):
    summary = tmp_path / "summary.md"
    log = _log(tmp_path, VERSION, json.dumps({"type": "change_summary", "@message": "No changes."}))
    assert dr.main(["--plan-log", log, "--exit-code", "0", "--root", "accounts/aa365", "--summary", str(summary)]) == 0
    text = summary.read_text(encoding="utf-8")
    assert "In sync" in text and "accounts/aa365" in text
    assert "::error" not in capsys.readouterr().out


def test_exit_2_fails_and_lists_drift_and_planned_changes(tmp_path, capsys):
    summary = tmp_path / "summary.md"
    log = _log(tmp_path, VERSION,
               _change("resource_drift", "module.ecs.aws_ecs_service.api", "update"),
               _change("planned_change", "module.ecs.aws_ecs_service.api", "update"),
               _change("planned_change", "aws_cloudwatch_log_group.new", "create"),
               SUMMARY_2)
    assert dr.main(["--plan-log", log, "--exit-code", "2", "--root", "accounts/aa365", "--summary", str(summary)]) == 1
    text = summary.read_text(encoding="utf-8")
    assert "Not in sync" in text
    assert "Changed outside Terraform** (1)" in text
    assert "An apply of main would** (2)" in text
    assert "`module.ecs.aws_ecs_service.api`" in text and "`aws_cloudwatch_log_group.new`" in text
    out = capsys.readouterr().out
    assert "::error title=Terraform drift::accounts/aa365" in out


def test_exit_2_without_resources_still_fails(tmp_path):
    log = _log(tmp_path, VERSION, json.dumps({"type": "outputs", "outputs": {"x": {"action": "update"}}}))
    assert dr.run(log, 2, "accounts/aa365", None) == 1


def test_plan_error_fails_and_masks_account_ids_and_arns(tmp_path, capsys):
    summary = tmp_path / "summary.md"
    detail = (f"User: arn:aws:sts::{ACC}:assumed-role/aa-cis-infra-tf-plan/GitHubActions is not authorized to "
              f"perform: bedrock:GetGuardrail on resource: arn:aws:bedrock:us-west-1:{ACC}:guardrail/abc "
              f"in account {ACC} sg-0123456789abcdef0 " + "x" * 600)
    log = _log(tmp_path, VERSION, json.dumps({"type": "diagnostic", "diagnostic": {
        "severity": "error", "summary": "reading Bedrock Guardrail", "detail": detail,
        "snippet": {"code": "secret = \"hunter2\"", "values": [{"traversal": "var.db_password", "statement": "x"}]}}}))
    assert dr.main(["--plan-log", log, "--exit-code", "1", "--root", "accounts/aa365", "--summary", str(summary)]) == 1
    text = summary.read_text(encoding="utf-8")
    out = capsys.readouterr().out
    assert "Plan failed" in text and "reading Bedrock Guardrail" in text
    assert ACC not in text + out and "arn:aws:" not in text + out and "sg-0123456789abcdef0" not in text
    assert "aa-cis-infra-tf-plan" in text  # the role name stays readable
    assert "hunter2" not in text and "db_password" not in text  # snippets are never rendered
    assert "..." in text  # long details are cut
    assert "::error title=Terraform drift check failed::accounts/aa365" in out


def test_plan_error_without_diagnostic(tmp_path):
    log = _log(tmp_path, VERSION)
    assert dr.run(log, 1, "accounts/aa365", None) == 1


def test_no_attribute_values_reach_the_report(tmp_path):
    msg = json.loads(_change("planned_change", "aws_secretsmanager_secret_version.db", "update"))
    msg["change"]["before"] = {"secret_string": "topsecret"}  # never in -json UI output, but never rendered anyway
    rep = dr.parse_plan_log([json.dumps(msg)])
    _, lines, notes = dr.render("accounts/aa365", 2, rep)
    assert "topsecret" not in "\n".join(lines + notes)


def test_bad_input_exits_3(tmp_path, capsys):
    assert dr.main(["--plan-log", str(tmp_path / "missing.jsonl"), "--exit-code", "0", "--root", "r"]) == 3
    log = _log(tmp_path, VERSION)
    assert dr.main(["--plan-log", log, "--exit-code", "137", "--root", "r"]) == 3
    assert "::error title=Terraform drift check failed::r" in capsys.readouterr().out


def test_long_lists_are_capped(tmp_path):
    rep = dr.parse_plan_log([_change("planned_change", f"aws_sns_topic.t{i}", "create") for i in range(dr.LIST_MAX + 5)])
    _, lines, _ = dr.render("accounts/aa365", 2, rep)
    assert f"... 5 more" in "\n".join(lines)


# --- AA-1004: --mode plan / --mode apply, e-mail masking ------------------------------------------------------------

def _applied(addr: str, action: str) -> str:
    return json.dumps({"@level": "info", "@message": f"{addr}: complete", "type": "apply_complete",
                       "hook": {"resource": {"addr": addr}, "action": action}})


def _error(summary: str, detail: str) -> str:
    return json.dumps({"@level": "error", "@message": summary, "type": "diagnostic",
                       "diagnostic": {"severity": "error", "summary": summary, "detail": detail}})


def test_plan_mode_changes_are_not_a_failure(tmp_path):
    log = _log(tmp_path, VERSION, _change("planned_change", 'aws_identitystore_user.this["techlead"]', "create"),
               SUMMARY_2)
    summary = tmp_path / "s.md"
    assert dr.run(log, 2, "accounts/management", str(summary), mode="plan") == 0
    text = summary.read_text(encoding="utf-8")
    assert "Terraform plan" in text and "**Changes**" in text and 'aws_identitystore_user.this["techlead"]' in text
    assert dr.run(_log(tmp_path, VERSION), 0, "accounts/management", str(summary), mode="plan") == 0
    assert "**No changes.**" in summary.read_text(encoding="utf-8")


def test_plan_mode_failure_fails(tmp_path):
    log = _log(tmp_path, VERSION, _error("AccessDenied", f"arn:aws:iam::{ACC}:role/aa-terraform-plan is not allowed"))
    assert dr.run(log, 1, "accounts/management", str(tmp_path / "s.md"), mode="plan") == 1


def test_apply_mode_lists_applied_and_fails_on_error(tmp_path):
    summary = tmp_path / "s.md"
    ok = _log(tmp_path, VERSION, _applied('aws_organizations_policy.scp["aa-scp-region-allowlist"]', "update"))
    assert dr.run(ok, 0, "accounts/management", str(summary), mode="apply") == 0
    assert "**Applied.**" in summary.read_text(encoding="utf-8")
    bad = _log(tmp_path, VERSION, _error("creating budget", "x"))
    assert dr.run(bad, 1, "accounts/management", str(summary), mode="apply") == 1
    assert "**Apply failed**" in summary.read_text(encoding="utf-8")


def test_apply_mode_rejects_exit_2(tmp_path):
    assert dr.main(["--plan-log", _log(tmp_path, VERSION), "--exit-code", "2", "--root", "r", "--mode", "apply"]) == 3


def test_emails_and_account_ids_never_reach_the_report(tmp_path):
    log = _log(tmp_path, VERSION, _error("ValidationException",
                                         f"user jane.doe@example.com in account {ACC} already exists"))
    summary = tmp_path / "s.md"
    for mode in ("drift", "plan", "apply"):
        dr.run(log, 1, "accounts/management", str(summary), mode=mode)
    text = summary.read_text(encoding="utf-8")
    assert "jane.doe@example.com" not in text and ACC not in text
    assert "{email}" in text


# --- workflow shape ------------------------------------------------------------------------------------------------

def _plan_wf_roots() -> set[tuple[str, str]]:
    """(root, state key) of every Terraform root terraform-plan.yml plans."""
    wf = _load(PLAN_WF)
    roots = set()
    for job in wf["jobs"].values():
        root = job.get("defaults", {}).get("run", {}).get("working-directory")
        for step in job["steps"]:
            run = step.get("run") or ""
            m = re.search(r'key=([^"\s]+)', run)
            if "terraform init" in run and m:
                roots.add((step.get("working-directory", root), m.group(1)))
    assert roots, "terraform-plan.yml: no terraform init found"
    return roots


def test_drift_covers_every_root_the_pr_plan_covers():
    job = next(iter(_load(DRIFT_WF)["jobs"].values()))
    matrix = {(e["root"], e["state_key"]) for e in job["strategy"]["matrix"]["include"]}
    assert matrix == _plan_wf_roots()
    assert job["strategy"]["fail-fast"] is False  # one red root must not hide the others


def test_drift_workflow_is_scheduled_read_only_and_main_only():
    with open(DRIFT_WF, encoding="utf-8") as fh:
        text = fh.read()
    wf = yaml.safe_load(text)
    on = wf.get("on", wf.get(True))
    assert "workflow_dispatch" in on and on["schedule"][0]["cron"].split()[2:] == ["*", "*", "*"]  # nightly
    assert wf["permissions"] == {"id-token": "write", "contents": "read"}
    assert wf["concurrency"]["cancel-in-progress"] is False
    job = next(iter(wf["jobs"].values()))
    assert "environment" not in job  # sub ref:refs/heads/main = the read-only plan role only
    assert job["if"] == "github.ref == 'refs/heads/main'"
    assert "*:assumed-role/aa-cis-infra-tf-plan/*" in text  # fail closed on any other role
    steps = {s.get("name", ""): s for s in job["steps"]}
    assert steps["Setup Terraform"]["with"]["terraform_wrapper"] is False
    assert job["steps"][0]["with"]["persist-credentials"] is False
    plan = steps["Terraform Plan (detailed exit code, no state lock)"]["run"]
    for flag in ("-detailed-exitcode", "-lock=false", "-input=false", "-json", "umask 077", "trap 'rm -f",
                 "tools/terraform/drift_report.py", '--exit-code "$RC"', "$GITHUB_STEP_SUMMARY"):
        assert flag in plan, flag
    assert "-lockfile=readonly" in steps["Terraform Init (read-only lockfile)"]["run"]
    # Nothing that writes, and no plan file or artifact that could carry secret values.
    assert not re.search(r"-out[= ]", plan)  # no saved plan file
    for bad in ("terraform apply", "force-unlock", "upload-artifact", "terraform show", "aws s3 cp",
                "git push", "setup-python", "pip install"):
        assert bad not in text, bad


def test_drift_uses_the_same_terraform_version_as_the_pr_plan():
    def version(path):
        for job in _load(path)["jobs"].values():
            for s in job["steps"]:
                if str(s.get("uses", "")).startswith("hashicorp/setup-terraform"):
                    return s["with"]["terraform_version"]
    assert version(DRIFT_WF) == version(PLAN_WF)


def test_guard_test_workflow_triggers_on_the_workflows_these_tests_read():
    wf = _load(os.path.join(WORKFLOWS, "tf-plan-guard-test.yml"))
    on = wf.get("on", wf.get(True))
    for event in ("pull_request", "push"):
        paths = on[event]["paths"]
        for needed in (".github/workflows/terraform-drift.yml", ".github/workflows/terraform-plan.yml",
                       "tools/docs/aws_mask.py"):
            assert needed in paths, (event, needed)
