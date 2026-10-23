"""Tests for tools/terraform/plan_guard.py (AA-846). Run from the repo root:

    python3 -m pytest -p no:cacheprovider -q tools/terraform/tests

Offline: synthetic plan JSON fixtures (tests/fixtures/), no Terraform, no AWS. The last tests read
.github/workflows/terraform-apply.yml and check that the guard stays wired in front of the apply.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys

import pytest
import yaml

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))

import plan_guard as pg  # noqa: E402

FIXTURES = os.path.join(HERE, "fixtures")
SCRIPT = os.path.join(HERE, "..", "plan_guard.py")
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
APPLY_WORKFLOW = os.path.join(REPO_ROOT, ".github", "workflows", "terraform-apply.yml")


def _fixture(name: str) -> str:
    return os.path.join(FIXTURES, name)


def _load(name: str) -> dict:
    with open(_fixture(name), encoding="utf-8") as fh:
        return json.load(fh)


def _run(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, "-B", SCRIPT, *args], capture_output=True, text=True, check=False
    )


def _plan(*changes: tuple[str, str, list[str]], importing: bool = False) -> dict:
    rcs = []
    for address, rtype, actions in changes:
        change = {"actions": actions}
        if importing:
            change["importing"] = {"id": "placeholder"}
        rcs.append({"address": address, "mode": "managed", "type": rtype, "change": change})
    return {"format_version": "1.2", "planned_values": {}, "resource_changes": rcs}


# --- find_guarded_changes -------------------------------------------------------------------------


def test_noop_fixture_has_no_guarded_change():
    assert pg.find_guarded_changes(_load("plan_noop.json")) == []


def test_clean_fixture_with_other_changes_passes():
    # Updates/replaces on other types (incl. aws_secretsmanager_secret, not the version) are fine.
    assert pg.find_guarded_changes(_load("plan_clean.json")) == []


def test_guarded_fixture_lists_each_guarded_change():
    found = pg.find_guarded_changes(_load("plan_guarded.json"))
    assert [(c.address, c.type, c.action) for c in found] == [
        ("aws_secretsmanager_secret_version.rotated", "aws_secretsmanager_secret_version", "update"),
        ("random_password.regenerated", "random_password", "delete,create"),
        ("module.rds.aws_db_instance.replica", "aws_db_instance", "update"),
    ]


@pytest.mark.parametrize(
    "actions",
    [["create"], ["update"], ["delete"], ["delete", "create"], ["create", "delete"], ["forget"]],
)
@pytest.mark.parametrize("rtype", sorted(pg.GUARDED_TYPES))
def test_every_non_safe_action_on_a_guarded_type_is_found(rtype, actions):
    found = pg.find_guarded_changes(_plan((f"module.x.{rtype}.y", rtype, actions)))
    assert len(found) == 1 and found[0].action == ",".join(actions)


@pytest.mark.parametrize("actions", [["no-op"], ["read"]])
def test_noop_and_read_are_safe(actions):
    assert pg.find_guarded_changes(_plan(("aws_db_instance.main", "aws_db_instance", actions))) == []


def test_import_of_a_guarded_type_is_found_even_as_noop():
    found = pg.find_guarded_changes(
        _plan(("random_password.p", "random_password", ["no-op"]), importing=True)
    )
    assert [c.action for c in found] == ["import"]


def test_plan_without_resource_changes_is_clean():
    assert pg.find_guarded_changes({"format_version": "1.2", "planned_values": {}}) == []


@pytest.mark.parametrize(
    "bad",
    [
        [],
        {"resource_changes": []},  # no format_version
        {"format_version": "1.0", "values": {}},  # a state, not a plan
        {"format_version": "1.2", "planned_values": {}, "resource_changes": {}},
        {"format_version": "1.2", "planned_values": {}, "resource_changes": [
            {"address": "aws_db_instance.main", "type": "aws_db_instance", "change": {}}
        ]},
    ],
)
def test_malformed_plan_is_an_input_error(bad):
    with pytest.raises(pg.InputError):
        pg.find_guarded_changes(bad)


# --- Object Lock rule (AA-932) ---------------------------------------------------------------------

LOCK = "aws_s3_bucket_object_lock_configuration"


def _lock_plan(actions, mode=None, before_mode=None, importing=False, rtype=LOCK, before=None):
    change = {"actions": actions}
    if mode is not None:
        change["after"] = {"rule": [{"default_retention": [{"mode": mode, "days": 365, "years": None}]}]}
    if before_mode is not None:
        change["before"] = {"rule": [{"default_retention": [{"mode": before_mode, "days": 365}]}]}
    if before is not None:
        change["before"] = before
    if importing:
        change["importing"] = {"id": "placeholder"}
    return {"format_version": "1.2", "planned_values": {}, "resource_changes": [
        {"address": f'{rtype}.crm_audit["audit-c"]', "mode": "managed", "type": rtype, "change": change}]}


def test_governance_lock_create_passes():
    assert pg.find_guarded_changes(_lock_plan(["create"], mode="GOVERNANCE")) == []


def test_compliance_lock_create_is_refused():
    found = pg.find_guarded_changes(_lock_plan(["create"], mode="COMPLIANCE"))
    assert [(c.type, c.action) for c in found] == [(LOCK, "create (COMPLIANCE)")]


@pytest.mark.parametrize("actions", [["update"], ["delete"], ["delete", "create"], ["create", "delete"], ["forget"]])
def test_any_change_to_an_existing_lock_is_refused(actions):
    found = pg.find_guarded_changes(_lock_plan(actions, mode="GOVERNANCE", before_mode="GOVERNANCE"))
    assert len(found) == 1 and found[0].action.startswith(",".join(actions))


def test_replace_into_compliance_is_labelled():
    found = pg.find_guarded_changes(_lock_plan(["delete", "create"], mode="COMPLIANCE", before_mode="GOVERNANCE"))
    assert found[0].action == "delete,create (COMPLIANCE)"


def test_lock_import_is_refused_and_noop_passes():
    assert [c.action for c in pg.find_guarded_changes(_lock_plan(["no-op"], importing=True))] == ["import"]
    assert pg.find_guarded_changes(_lock_plan(["no-op"], mode="GOVERNANCE", before_mode="GOVERNANCE")) == []


@pytest.mark.parametrize("actions", [["delete"], ["delete", "create"], ["create", "delete"]])
def test_deleting_an_object_lock_bucket_is_refused(actions):
    plan = _lock_plan(actions, rtype="aws_s3_bucket", before={"object_lock_enabled": True})
    found = pg.find_guarded_changes(plan)
    assert len(found) == 1 and found[0].action.endswith("(Object Lock bucket)")


def test_other_bucket_changes_pass():
    assert pg.find_guarded_changes(_lock_plan(["delete"], rtype="aws_s3_bucket",
                                              before={"object_lock_enabled": False})) == []
    assert pg.find_guarded_changes(_lock_plan(["update"], rtype="aws_s3_bucket",
                                              before={"object_lock_enabled": True})) == []
    assert pg.find_guarded_changes(_lock_plan(["create"], rtype="aws_s3_bucket")) == []


def test_cli_compliance_lock_is_refused_and_names_the_mode(tmp_path):
    p = tmp_path / "plan.json"
    p.write_text(json.dumps(_lock_plan(["create"], mode="COMPLIANCE")), encoding="utf-8")
    res = _run(str(p))
    assert res.returncode == 1
    assert "create (COMPLIANCE)" in res.stderr


def test_terraform_never_puts_dev_in_compliance():
    # Static guard on the source (design v3 §3.6: Dev governance only): only audit-c can switch, behind a
    # variable that defaults to false and a precondition that refuses it on Dev; audit-g is GOVERNANCE.
    tf = open(os.path.join(REPO_ROOT, "accounts", "aa365", "crm_storage.tf"), encoding="utf-8").read()
    var = tf.split('variable "crm_audit_compliance_enabled"', 1)[1].split("\n}", 1)[0]
    assert "default     = false" in var
    assert tf.count('"COMPLIANCE"') == 1
    assert 'mode = var.crm_audit_compliance_enabled ? "COMPLIANCE" : "GOVERNANCE", days = 365' in tf
    assert 'audit-g = { mode = "GOVERNANCE", days = null, years = 7 }' in tf
    assert 'each.value.mode == "GOVERNANCE" || (each.key == "audit-c" && var.environment != "dev")' in tf


# --- CLI ------------------------------------------------------------------------------------------


def test_cli_guarded_fixture_exits_non_zero_and_names_addresses():
    res = _run(_fixture("plan_guarded.json"))
    assert res.returncode == 1
    assert "REFUSED" in res.stderr
    assert "module.rds.aws_db_instance.replica" in res.stderr


@pytest.mark.parametrize("name", ["plan_clean.json", "plan_noop.json"])
def test_cli_clean_fixtures_exit_zero(name):
    res = _run(_fixture(name))
    assert res.returncode == 0, res.stderr
    assert "OK" in res.stdout


def test_cli_allow_reason_lets_guarded_changes_through_and_records_reason(tmp_path):
    summary = tmp_path / "summary.md"
    res = _run(_fixture("plan_guarded.json"), "--allow-reason=rotate the DB master password",
               "--summary", str(summary))
    assert res.returncode == 0
    text = summary.read_text(encoding="utf-8")
    assert "ALLOWED" in text and "rotate the DB master password" in text
    assert "random_password.regenerated" in text


def test_cli_blank_allow_reason_still_refuses():
    assert _run(_fixture("plan_guarded.json"), "--allow-reason=   ").returncode == 1


def test_cli_reason_starting_with_dash_is_accepted():
    assert _run(_fixture("plan_guarded.json"), "--allow-reason=-- planned rotation").returncode == 0


@pytest.mark.parametrize("content", ["", "[command]/usr/bin/terraform-bin show -json tfplan\n{}", "{"])
def test_cli_bad_json_fails_closed(tmp_path, content):
    p = tmp_path / "plan.json"
    p.write_text(content, encoding="utf-8")
    res = _run(str(p))
    assert res.returncode == 2
    assert "fail closed" in res.stderr


def test_cli_missing_file_fails_closed(tmp_path):
    assert _run(str(tmp_path / "nope.json")).returncode == 2


def test_report_never_contains_attribute_values(tmp_path):
    plan = _plan(("aws_secretsmanager_secret_version.s", "aws_secretsmanager_secret_version", ["update"]))
    plan["resource_changes"][0]["change"].update(
        {"before": {"secret_string": "OLD-SENTINEL"}, "after": {"secret_string": "NEW-SENTINEL"}}
    )
    p = tmp_path / "plan.json"
    p.write_text(json.dumps(plan), encoding="utf-8")
    res = _run(str(p))
    assert res.returncode == 1
    assert "SENTINEL" not in res.stdout + res.stderr


# --- workflow wiring ------------------------------------------------------------------------------


def _apply_steps() -> list[dict]:
    with open(APPLY_WORKFLOW, encoding="utf-8") as fh:
        wf = yaml.safe_load(fh)
    return wf["jobs"]["terraform-apply"]["steps"]


def _step(steps: list[dict], name: str) -> tuple[int, dict]:
    for i, step in enumerate(steps):
        if step.get("name") == name:
            return i, step
    raise AssertionError(f"step {name!r} missing from terraform-apply.yml")


def test_workflow_runs_the_guard_before_the_apply():
    steps = _apply_steps()
    gi, guard = _step(steps, "Plan guard")
    ai, apply = _step(steps, "Terraform Apply")
    assert gi < ai
    assert "tools/terraform/plan_guard.py" in guard["run"]
    # The apply must not run in self-test mode, nor with a failure/always() override that would
    # bypass a refused guard.
    assert "GUARD_SELFTEST != 'true'" in apply["if"]
    for word in ("always()", "failure()", "continue-on-error"):
        assert word not in str(apply.get("if", "")) and word not in apply
    assert "continue-on-error" not in guard


def test_workflow_selftest_feeds_the_guarded_fixture_and_skips_aws():
    steps = _apply_steps()
    _, select = _step(steps, "Select self-test plan")
    assert "tools/terraform/tests/fixtures/plan_guarded.json" in select["run"]
    for name in ("Configure AWS credentials (OIDC)", "Terraform Init", "Terraform Plan"):
        _, step = _step(steps, name)
        assert "GUARD_SELFTEST != 'true'" in step["if"], name


def test_workflow_dispatch_inputs_exist():
    with open(APPLY_WORKFLOW, encoding="utf-8") as fh:
        wf = yaml.safe_load(fh)
    on = wf.get("on", wf.get(True))  # PyYAML reads the bare key `on` as True
    inputs = on["workflow_dispatch"]["inputs"]
    assert inputs["allow_guarded"]["default"] is False
    assert inputs["guard_selftest"]["default"] is False
    assert "allow_reason" in inputs
