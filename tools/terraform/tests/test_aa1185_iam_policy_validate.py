"""AA-1185: tests for tools/terraform/iam_policy_validate.py (IAM Access Analyzer ValidatePolicy on a plan).

Offline: synthetic plan JSON and a fake `aws` runner, no Terraform, no AWS. The last test reads
.github/workflows/terraform-plan.yml: the step runs in the required "Terraform Plan (dev)" job and the plan file is
deleted after it.

Run from the repo root:
    python3 -m pytest -p no:cacheprovider -q tools/terraform/tests/test_aa1185_iam_policy_validate.py
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

import iam_policy_validate as ipv  # noqa: E402

REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
PLAN_WF = os.path.join(REPO_ROOT, ".github", "workflows", "terraform-plan.yml")
AWS = "registry.terraform.io/hashicorp/aws"
ACCOUNT = "111122223333"  # the AWS documentation example account

IDENTITY = json.dumps({"Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Action": "s3:GetObject", "Resource": "*"}]})
TRUST = json.dumps({"Version": "2012-10-17", "Statement": [
    {"Effect": "Allow", "Principal": {"Service": "ecs-tasks.amazonaws.com"}, "Action": "sts:AssumeRole"}]})


def rc(address: str, rtype: str, actions: list[str], after: dict, *, before: dict | None = None,
       unknown: dict | None = None, provider: str = AWS) -> dict:
    return {
        "address": address, "mode": "managed", "type": rtype, "provider_name": provider,
        "change": {"actions": actions, "before": before, "after": after, "after_unknown": unknown or {}},
    }


def plan(*changes: dict) -> dict:
    return {"format_version": "1.2", "resource_changes": list(changes)}


class FakeAws:
    def __init__(self, findings: dict[str, list[dict]] | None = None):
        self.calls: list[list[str]] = []
        self.findings = findings or {}

    def __call__(self, args: list[str]) -> str:
        self.calls.append(args)
        doc = args[args.index("--policy-document") + 1]
        return json.dumps({"findings": self.findings.get(doc, [])})


def finding(ftype: str, code: str, detail: str = "detail") -> dict:
    return {"findingType": ftype, "issueCode": code, "findingDetails": detail, "learnMoreLink": "https://example.com"}


def write(tmp_path, data, name="plan.json") -> str:
    p = tmp_path / name
    p.write_text(json.dumps(data), encoding="utf-8")
    return str(p)


# -- documents() ------------------------------------------------------------------------------------------------------


def test_documents_takes_created_and_updated_policies_with_their_types():
    docs = ipv.documents(plan(
        rc("aws_iam_policy.a", "aws_iam_policy", ["create"], {"policy": IDENTITY}),
        rc("aws_iam_role.r", "aws_iam_role", ["create"], {"assume_role_policy": TRUST}),
        rc("aws_s3_bucket_policy.b", "aws_s3_bucket_policy", ["delete", "create"], {"policy": IDENTITY}),
        rc("aws_sns_topic_policy.t", "aws_sns_topic_policy", ["update"], {"policy": IDENTITY}, before={"policy": "{}"}),
    ))
    got = {(d.address, d.policy_type, d.resource_type) for d in docs}
    assert got == {
        ("aws_iam_policy.a", "IDENTITY_POLICY", None),
        ("aws_iam_role.r", "RESOURCE_POLICY", "AWS::IAM::AssumeRolePolicyDocument"),
        ("aws_s3_bucket_policy.b", "RESOURCE_POLICY", "AWS::S3::Bucket"),
        ("aws_sns_topic_policy.t", "RESOURCE_POLICY", None),
    }


def test_documents_skips_noop_delete_read_other_providers_and_unchanged_updates():
    docs = ipv.documents(plan(
        rc("aws_iam_policy.noop", "aws_iam_policy", ["no-op"], {"policy": IDENTITY}),
        rc("aws_iam_policy.gone", "aws_iam_policy", ["delete"], {}),
        rc("aws_iam_role.tags_only", "aws_iam_role", ["update"], {"assume_role_policy": TRUST},
           before={"assume_role_policy": json.dumps(json.loads(TRUST), indent=2)}),
        rc("other_iam_policy.x", "aws_iam_policy", ["create"], {"policy": IDENTITY}, provider="registry.example/x/aws"),
        rc("aws_s3_bucket.not_a_policy", "aws_s3_bucket", ["create"], {"policy": IDENTITY}),
    ))
    assert docs == []


def test_unknown_document_is_listed_not_sent():
    fake = FakeAws()
    docs = ipv.documents(plan(rc("aws_iam_role_policy.p", "aws_iam_role_policy", ["create"], {}, unknown={"policy": True})))
    assert len(docs) == 1 and docs[0].text is None
    assert fake.calls == []


def test_not_a_plan_is_refused():
    with pytest.raises(ipv.InputError):
        ipv.documents({"hello": 1})


# -- validate() and main() --------------------------------------------------------------------------------------------


def test_validate_passes_the_resource_type_for_trust_and_bucket_policies():
    fake = FakeAws()
    docs = ipv.documents(plan(rc("aws_iam_role.r", "aws_iam_role", ["create"], {"assume_role_policy": TRUST})))
    ipv.validate(docs[0], fake)
    args = fake.calls[0]
    assert args[:4] == ["accessanalyzer", "validate-policy", "--policy-type", "RESOURCE_POLICY"]
    assert args[args.index("--validate-policy-resource-type") + 1] == "AWS::IAM::AssumeRolePolicyDocument"


def test_clean_plan_exits_zero(tmp_path, capsys):
    path = write(tmp_path, plan(rc("aws_iam_policy.a", "aws_iam_policy", ["create"], {"policy": IDENTITY})))
    fake = FakeAws({IDENTITY: [finding("SUGGESTION", "EMPTY_ARRAY_RESOURCE")]})
    summary = tmp_path / "summary.md"
    assert ipv.main([path, "--allow", str(tmp_path / "none.json"), "--summary", str(summary)], run=fake) == 0
    text = summary.read_text(encoding="utf-8")
    assert "1 policy documents checked" in text and "EMPTY_ARRAY_RESOURCE" in text


@pytest.mark.parametrize("ftype", ["ERROR", "SECURITY_WARNING"])
def test_blocking_findings_fail(tmp_path, ftype):
    path = write(tmp_path, plan(rc("aws_iam_policy.a", "aws_iam_policy", ["create"], {"policy": IDENTITY})))
    fake = FakeAws({IDENTITY: [finding(ftype, "PASS_ROLE_WITH_STAR_IN_RESOURCE")]})
    assert ipv.main([path, "--allow", str(tmp_path / "none.json")], run=fake) == 1


def test_warning_does_not_fail(tmp_path):
    path = write(tmp_path, plan(rc("aws_iam_policy.a", "aws_iam_policy", ["create"], {"policy": IDENTITY})))
    fake = FakeAws({IDENTITY: [finding("WARNING", "MISSING_VERSION")]})
    assert ipv.main([path, "--allow", str(tmp_path / "none.json")], run=fake) == 0


def test_allow_row_accepts_exactly_that_address_and_code(tmp_path):
    path = write(tmp_path, plan(
        rc("aws_iam_policy.a", "aws_iam_policy", ["create"], {"policy": IDENTITY}),
    ))
    allow = write(tmp_path, {"allow": [{"address": "aws_iam_policy.a", "issueCode": "PASS_ROLE_WITH_STAR_IN_RESOURCE",
                                        "reason": "Invented reason long enough for the rule."}]}, "allow.json")
    fake = FakeAws({IDENTITY: [finding("SECURITY_WARNING", "PASS_ROLE_WITH_STAR_IN_RESOURCE")]})
    assert ipv.main([path, "--allow", allow], run=fake) == 0
    fake2 = FakeAws({IDENTITY: [finding("SECURITY_WARNING", "ANOTHER_CODE")]})
    assert ipv.main([path, "--allow", allow], run=fake2) == 1


def test_allow_row_without_a_reason_is_refused(tmp_path):
    path = write(tmp_path, plan())
    allow = write(tmp_path, {"allow": [{"address": "aws_iam_policy.a", "issueCode": "X", "reason": "short"}]}, "a.json")
    assert ipv.main([path, "--allow", allow], run=FakeAws()) == 2


def test_aws_error_fails_closed(tmp_path):
    path = write(tmp_path, plan(rc("aws_iam_policy.a", "aws_iam_policy", ["create"], {"policy": IDENTITY})))

    def broken(args):
        raise ipv.InputError("aws accessanalyzer validate-policy failed: AccessDenied")

    assert ipv.main([path, "--allow", str(tmp_path / "none.json")], run=broken) == 2


def test_output_masks_account_ids_and_arns(tmp_path, capsys):
    path = write(tmp_path, plan(rc("aws_iam_policy.a", "aws_iam_policy", ["create"], {"policy": IDENTITY})))
    detail = f"Resource arn:aws:iam::{ACCOUNT}:role/example-role is too broad for account {ACCOUNT}."
    fake = FakeAws({IDENTITY: [finding("SECURITY_WARNING", "CODE", detail)]})
    summary = tmp_path / "s.md"
    ipv.main([path, "--allow", str(tmp_path / "none.json"), "--summary", str(summary)], run=fake)
    out = capsys.readouterr()
    for text in (out.out, out.err, summary.read_text(encoding="utf-8")):
        assert ACCOUNT not in text
        assert "arn:aws:iam::" not in text
    # The policy text itself is never printed.
    assert "s3:GetObject" not in out.out + out.err


def test_shipped_allow_file_is_valid():
    assert isinstance(ipv.load_allow(ipv.DEFAULT_ALLOW), dict)


def test_step_is_in_the_required_plan_job_and_deletes_the_plan_last():
    wf = yaml.safe_load(open(PLAN_WF, encoding="utf-8"))
    job = next(j for j in wf["jobs"].values() if j.get("name") == "Terraform Plan (dev)")
    names = [s.get("name") for s in job["steps"]]
    assert "IAM policy validation" in names
    assert names.index("Tag guard") < names.index("IAM policy validation")
    step = job["steps"][names.index("IAM policy validation")]
    assert step.get("if") == "${{ !cancelled() }}"
    assert "iam_policy_validate.py" in step["run"] and "--summary" in step["run"]
    assert "trap 'rm -f \"$J\" tfplan' EXIT" in step["run"]
    tag = job["steps"][names.index("Tag guard")]
    assert "tfplan' EXIT" not in tag["run"], "the tag guard must not delete the plan the next step reads"
