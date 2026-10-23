"""Tests for tools/terraform/crm_key_policy_diff.py (AA-932). Offline: synthetic state JSON, a fake fetcher.

Run: python3 -m pytest -p no:cacheprovider -q tools/terraform/tests
"""
from __future__ import annotations

import json
import os
import sys

import pytest
import yaml

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))

import crm_key_policy_diff as kd  # noqa: E402

REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
WORKFLOW = os.path.join(REPO_ROOT, ".github", "workflows", "crm-key-policy-diff.yml")
ACC = "111122223333"  # documentation placeholder, not a real account

POLICY = {
    "Version": "2012-10-17",
    "Statement": [
        {"Sid": "IamAdministration", "Effect": "Allow", "Principal": {"AWS": f"arn:aws:iam::{ACC}:root"},
         "Action": ["kms:DescribeKey", "kms:PutKeyPolicy"], "Resource": "*"},
        {"Sid": "DenyCryptoOutsideCrmRuntime", "Effect": "Deny", "Principal": {"AWS": "*"},
         "Action": ["kms:Decrypt", "kms:Encrypt"], "Resource": "*",
         "Condition": {"ArnNotEquals": {"aws:PrincipalArn": [f"arn:aws:iam::{ACC}:role/a", f"arn:aws:iam::{ACC}:role/b"]},
                       "Bool": {"aws:PrincipalIsAWSService": "false"}}},
    ],
}


def _state(*names: str, policy=POLICY) -> dict:
    res = [{"address": f"aws_kms_key.{n}", "mode": "managed", "type": "aws_kms_key", "name": n,
            "values": {"key_id": f"{n}-id", "policy": json.dumps(policy)}} for n in names]
    res.append({"address": "aws_kms_key.other", "mode": "managed", "type": "aws_kms_key", "name": "other",
                "values": {"key_id": "x", "policy": "{}"}})
    return {"format_version": "1.0", "values": {"root_module": {"resources": res}}}


def _reshuffled(policy: dict) -> dict:
    """Same policy as KMS might return it: statements and lists reordered, one-element lists as strings."""
    p = json.loads(json.dumps(policy))
    p["Statement"].reverse()
    for s in p["Statement"]:
        if isinstance(s.get("Action"), list):
            s["Action"].reverse()
        s["Resource"] = ["*"]
        cond = s.get("Condition", {})
        if "ArnNotEquals" in cond:
            cond["ArnNotEquals"]["aws:PrincipalArn"].reverse()
        if "Bool" in cond:
            cond["Bool"]["aws:PrincipalIsAWSService"] = ["false"]
    return p


def test_equivalent_policies_have_no_diff():
    assert kd.diff(POLICY, _reshuffled(POLICY)) == []
    assert kd.diff(json.dumps(POLICY), json.dumps(_reshuffled(POLICY))) == []


def test_added_removed_and_changed_statements_are_named_by_sid_only():
    live = json.loads(json.dumps(POLICY))
    live["Statement"][1]["Action"].append("kms:GenerateDataKey")      # changed
    live["Statement"].pop(0)                                           # removed
    live["Statement"].append({"Sid": "Sneaky", "Effect": "Allow", "Principal": {"AWS": "*"},
                              "Action": "kms:Decrypt", "Resource": "*"})  # added
    out = kd.diff(POLICY, live)
    assert out == [
        "statement IamAdministration: in Terraform, missing live",
        "statement Sneaky: live only (not in Terraform)",
        "statement DenyCryptoOutsideCrmRuntime: content differs",
    ]
    assert not any(ACC in line for line in out)


def test_state_policies_reads_only_the_three_crm_keys():
    got = kd.state_policies(_state("crm_data", "crm_ingest", "crm_seal"))
    assert sorted(got) == ["data", "ingest", "seal"]
    assert got["data"]["key_id"] == "crm_data-id"


@pytest.mark.parametrize("bad", [[], {"values": {}}])
def test_not_a_state_is_an_input_error(bad):
    with pytest.raises(kd.InputError):
        kd.state_policies(bad)


def test_empty_state_has_no_keys():
    assert kd.state_policies({"format_version": "1.0"}) == {}


def test_run_ok_and_skips_keys_not_applied_yet():
    text, code = kd.run(_state("crm_data", "crm_ingest"), lambda key_id: json.dumps(_reshuffled(POLICY)))
    assert code == 0
    assert "`seal`: not in the Terraform state" in text


def test_run_reports_drift_with_exit_1():
    live = json.loads(json.dumps(POLICY))
    live["Statement"][0]["Action"].append("kms:Decrypt")

    def fetch(key_id):
        return json.dumps(live if key_id == "crm_ingest-id" else POLICY)

    text, code = kd.run(_state("crm_data", "crm_ingest", "crm_seal"), fetch)
    assert code == 1
    assert "`ingest`: **DRIFT**" in text and "IamAdministration: content differs" in text
    assert "`data`: live policy = Terraform state" in text


def test_failed_fetch_fails_closed():
    def fetch(key_id):
        raise kd.InputError("GetKeyPolicy failed: AccessDeniedException")

    with pytest.raises(kd.InputError, match="data: GetKeyPolicy failed"):
        kd.run(_state("crm_data"), fetch)


def test_cli_bad_state_exits_2(tmp_path):
    p = tmp_path / "s.json"
    p.write_text("{", encoding="utf-8")
    assert kd.main(["--state", str(p)]) == 2


def test_workflow_is_read_only_nightly_and_uses_the_plan_role():
    with open(WORKFLOW, encoding="utf-8") as fh:
        text = fh.read()
    wf = yaml.safe_load(text)
    on = wf.get("on", wf.get(True))
    assert "schedule" in on and "workflow_dispatch" in on
    assert wf["permissions"] == {"id-token": "write", "contents": "read"}
    job = next(iter(wf["jobs"].values()))
    assert "environment" not in job  # sub ref:refs/heads/main = the read-only plan role only
    assert job["if"] == "github.ref == 'refs/heads/main'"
    assert "aa-cis-infra-tf-plan" in text
    assert "tools/terraform/crm_key_policy_diff.py" in text
    for verb in ("terraform apply", "terraform plan", "put-key-policy", "aws s3 cp", "git push"):
        assert verb not in text


def test_guard_test_workflow_triggers_on_the_files_its_tests_read():
    """Two tests here read files outside tools/terraform: an edit to only one of them must still run the tests."""
    path = os.path.join(REPO_ROOT, ".github", "workflows", "tf-plan-guard-test.yml")
    with open(path, encoding="utf-8") as fh:
        wf = yaml.safe_load(fh)
    on = wf.get("on", wf.get(True))
    for event in ("pull_request", "push"):
        paths = on[event]["paths"]
        for needed in ("accounts/aa365/crm_storage.tf", ".github/workflows/crm-key-policy-diff.yml"):
            assert needed in paths, (event, needed)
