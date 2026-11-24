"""Tests of tools/compliance/aws_checks.py (AA-1173): each nightly check passes on a good account, fails on a bad one,
turns a failed read into an error row, and the bundle never carries an account id or an ARN.

Invented AWS answers only (fake account 000000000000 is never written out). Run:
python3 -m pytest -p no:cacheprovider -q tools/compliance/tests
"""
from __future__ import annotations

import base64
import copy
import importlib.util
import json
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("aws_checks", HERE.parent / "aws_checks.py")
ac = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ac)

CFG = ac.load_config()
ACCOUNT = "000000000000"
REPORT = "user,password_enabled,mfa_active,access_key_1_active,access_key_2_active\n" \
         "<root_account>,not_supported,true,false,false\n" \
         "deploy-bot,false,false,true,false\n" \
         "jane-console,true,true,false,false\n"

GOOD = {
    ("sts", "get-caller-identity"): {"Account": ACCOUNT},
    ("cloudtrail", "describe-trails"): {"trailList": [
        {"Name": "org-trail", "TrailARN": f"arn:aws:cloudtrail:us-west-1:{ACCOUNT}:trail/org-trail",
         "IsMultiRegionTrail": True, "LogFileValidationEnabled": True}]},
    ("cloudtrail", "get-trail-status"): {"IsLogging": True},
    ("s3control", "get-public-access-block"): {"PublicAccessBlockConfiguration": {
        "BlockPublicAcls": True, "IgnorePublicAcls": True, "BlockPublicPolicy": True, "RestrictPublicBuckets": True}},
    ("kms", "list-keys"): {"Keys": [{"KeyId": "11111111-aaaa"}, {"KeyId": "22222222-bbbb"}]},
    ("kms", "describe-key"): {"KeyMetadata": {"KeyManager": "CUSTOMER", "KeyState": "Enabled"}},
    ("kms", "get-key-rotation-status"): {"KeyRotationEnabled": True},
    ("iam", "generate-credential-report"): {"State": "COMPLETE"},
    ("iam", "get-credential-report"): {"Content": base64.b64encode(REPORT.encode()).decode()},
    ("ec2", "describe-security-groups"): {"SecurityGroups": [
        {"GroupName": "web-alb", "IpPermissions": [
            {"IpProtocol": "tcp", "FromPort": 443, "ToPort": 443, "IpRanges": [{"CidrIp": "0.0.0.0/0"}]}]},
        {"GroupName": "internal-db", "IpPermissions": [
            {"IpProtocol": "tcp", "FromPort": 5432, "ToPort": 5432, "IpRanges": [{"CidrIp": "10.0.0.0/16"}]}]}]},
    ("accessanalyzer", "list-analyzers"): {"analyzers": [
        {"type": "ACCOUNT", "status": "ACTIVE", "arn": f"arn:aws:access-analyzer:us-west-1:{ACCOUNT}:analyzer/a"}]},
    ("accessanalyzer", "list-findings-v2"): {"findings": []},
    ("rds", "describe-db-instances"): {"DBInstances": [
        {"DBInstanceIdentifier": "demo-db", "StorageEncrypted": True, "BackupRetentionPeriod": 7,
         "DeletionProtection": True}]},
    ("ecr", "describe-repositories"): {"repositories": [
        {"repositoryName": "demo-api", "imageTagMutability": "IMMUTABLE",
         "imageScanningConfiguration": {"scanOnPush": True}}]},
    ("ecr", "get-registry-scanning-configuration"): {"scanningConfiguration": {"scanType": "BASIC", "rules": []}},
    ("wafv2", "list-web-acls"): {"WebACLs": [{"Name": "demo-acl", "Id": "abc"}]},
    ("wafv2", "get-web-acl"): {"WebACL": {"Rules": [{"Statement": {"RateBasedStatement": {"Limit": 1000}}}]}},
    ("cloudwatch", "describe-alarms"): {"MetricAlarms": [
        {"AlarmName": "demo-5xx", "ActionsEnabled": True,
         "AlarmActions": [f"arn:aws:sns:us-west-1:{ACCOUNT}:aa-cis-dev-acp-alerts"]}]},
    ("auditmanager", "get-account-status"): {"status": "INACTIVE"},
}


class FakeAws:
    def __init__(self, answers: dict, errors: tuple = ()):
        self.answers = answers
        self.errors = errors
        self.calls: list = []

    def __call__(self, args: list):
        self.calls.append(args)
        key = (args[0], args[1])
        if key in self.errors:
            raise ac.AwsError(f"{args[0]} {args[1]}: AccessDenied")
        return copy.deepcopy(self.answers.get(key))


def _rows(answers: dict, errors: tuple = ()) -> dict:
    return {r["check_id"]: r for r in ac.collect(FakeAws(answers, errors), CFG)}


def test_good_account_passes_every_check():
    rows = _rows(GOOD)
    assert [cid for cid, _ in ac.CHECKS] == list(rows)
    assert {cid: r["status"] for cid, r in rows.items() if r["status"] != "pass"} == {}


@pytest.mark.parametrize("key,answer,check_id", [
    (("cloudtrail", "get-trail-status"), {"IsLogging": False}, "aws_cloudtrail_logging"),
    (("s3control", "get-public-access-block"), {"PublicAccessBlockConfiguration": {"BlockPublicAcls": True}},
     "aws_s3_account_public_block"),
    (("kms", "get-key-rotation-status"), {"KeyRotationEnabled": False}, "aws_kms_rotation"),
    (("ec2", "describe-security-groups"), {"SecurityGroups": [{"GroupName": "open-ssh", "IpPermissions": [
        {"IpProtocol": "tcp", "FromPort": 22, "ToPort": 22, "Ipv6Ranges": [{"CidrIpv6": "::/0"}]}]}]},
     "aws_open_security_groups"),
    (("accessanalyzer", "list-findings-v2"), {"findings": [{"id": "f1"}]}, "aws_access_analyzer"),
    (("rds", "describe-db-instances"), {"DBInstances": [{"DBInstanceIdentifier": "demo-db",
                                                          "StorageEncrypted": True, "BackupRetentionPeriod": 0}]},
     "aws_rds_protection"),
    (("ecr", "describe-repositories"), {"repositories": [{"repositoryName": "demo-api",
                                                          "imageTagMutability": "MUTABLE"}]},
     "aws_ecr_immutable_scan"),
    (("wafv2", "get-web-acl"), {"WebACL": {"Rules": [{"Statement": {"ManagedRuleGroupStatement": {}}}]}},
     "aws_waf_rate_rule"),
    (("cloudwatch", "describe-alarms"), {"MetricAlarms": [{"AlarmName": "demo-5xx", "ActionsEnabled": False,
                                                           "AlarmActions": ["x:aa-cis-dev-acp-alerts"]}]},
     "aws_alerts_topic_alarms"),
    (("auditmanager", "get-account-status"), {"status": "ACTIVE"}, "aws_audit_manager_off"),
])
def test_each_check_fails_on_a_bad_answer(key, answer, check_id):
    answers = dict(GOOD)
    answers[key] = answer
    assert _rows(answers)[check_id]["status"] == "fail"


def test_iam_mfa_fails_on_a_console_user_without_mfa_and_a_root_key():
    report = REPORT.replace("jane-console,true,true", "jane-console,true,false") \
        .replace("<root_account>,not_supported,true,false", "<root_account>,not_supported,true,true")
    answers = dict(GOOD)
    answers[("iam", "get-credential-report")] = {"Content": base64.b64encode(report.encode()).decode()}
    row = _rows(answers)["aws_iam_mfa"]
    assert row["status"] == "fail"
    assert row["summary"] == "root access key active; 1 console user(s) without MFA"


def test_iam_mfa_waits_for_the_report_then_errors_when_it_never_completes():
    class Slow(FakeAws):
        def __init__(self, ready_after: int):
            super().__init__(GOOD)
            self.ready_after = ready_after

        def __call__(self, args):
            if args[:2] == ["iam", "generate-credential-report"]:
                self.calls.append(args)
                n = sum(1 for c in self.calls if c[:2] == ["iam", "generate-credential-report"])
                return {"State": "COMPLETE" if n >= self.ready_after else "STARTED"}
            return super().__call__(args)

    pauses: list = []
    assert ac.iam_mfa(Slow(3), CFG, sleep=pauses.append)["status"] == "pass"
    assert len(pauses) == 2
    with pytest.raises(ac.AwsError):
        ac.iam_mfa(Slow(99), dict(CFG, credential_report_polls=2), sleep=lambda _s: None)


def test_failed_read_is_an_error_row_with_the_code_only():
    row = _rows(GOOD, errors=(("rds", "describe-db-instances"),))["aws_rds_protection"]
    assert row["status"] == "error"
    assert row["summary"] == "read failed: rds describe-db-instances: AccessDenied"


def test_unexpected_answer_shape_is_an_error_row():
    answers = dict(GOOD)
    answers[("wafv2", "list-web-acls")] = {"WebACLs": [{"Name": "no-id"}]}
    assert _rows(answers)["aws_waf_rate_rule"]["status"] == "error"


def test_names_and_counts_only_in_the_detail():
    answers = dict(GOOD)
    answers[("ec2", "describe-security-groups")] = {"SecurityGroups": [{"GroupName": "open-all", "IpPermissions": [
        {"IpProtocol": "-1", "IpRanges": [{"CidrIp": "0.0.0.0/0"}]}]}]}
    row = _rows(answers)["aws_open_security_groups"]
    assert row["detail"]["names"] == ["open-all"]
    assert ac.assert_publishable(json.dumps(row)) == []


def test_main_writes_the_bundle_and_prints_counts_only(tmp_path, capsys):
    out = tmp_path / "bundle.json"
    assert ac.main(["--out", str(out)], run=FakeAws(GOOD)) == 0
    text = out.read_text(encoding="utf-8")
    assert ac.assert_publishable(text) == []
    bundle = json.loads(text)
    assert (bundle["format"], bundle["source"]) == (1, "aws_nightly")
    printed = capsys.readouterr().out
    assert json.loads(printed) == {"checks": len(ac.CHECKS), "by_status": {"pass": len(ac.CHECKS)}}
    assert ACCOUNT not in printed


def test_main_refuses_a_bundle_with_an_account_id(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(ac.aws_mask, "mask_text", lambda text, aliases=None: text)
    answers = dict(GOOD)
    answers[("cloudtrail", "get-trail-status")] = {"IsLogging": False}
    answers[("cloudtrail", "describe-trails")] = {"trailList": []}
    answers[("rds", "describe-db-instances")] = {"DBInstances": [{"DBInstanceIdentifier": f"db-{ACCOUNT}"}]}
    out = tmp_path / "bundle.json"
    assert ac.main(["--out", str(out)], run=FakeAws(answers)) == 2
    assert not out.exists()
    err = capsys.readouterr().err
    assert "an account ID" in err and ACCOUNT not in err


@pytest.mark.parametrize("text,what", [
    ("arn:aws:iam::x:role/y", "an ARN"), ("s3://bucket/key", "an S3 URI"), ("sg-0123456789abcdef0", "a security "
                                                                              "group id"),
    ("someone@example.org", "an e-mail address"), ("id 000000000000 here", "an account ID"),
])
def test_assert_publishable_names_each_forbidden_kind(text, what):
    assert ac.assert_publishable(text) == [what]


def test_config_has_no_threshold_and_names_the_alerts_topic():
    assert set(CFG) == {"region", "web_ports", "alerts_topic_suffix", "credential_report_polls",
                        "credential_report_pause_seconds"}
    assert CFG["web_ports"] == [80, 443]
