"""Tests for tools/finops/untagged_report.py (S271, tagging standard FIN-03). Offline: a stub Tagging API client and an
invented CIS bundle (bundle_cis_sample.txt); no AWS, no boto3 needed.

    python3 -m pytest -p no:cacheprovider -q tools/finops/tests
"""
from __future__ import annotations

import json
import os
import sys

import pytest

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))

import untagged_report as ur  # noqa: E402

BUNDLE = os.path.join(HERE, "bundle_cis_sample.txt")
ACCT = "1" * 12  # invented account id: must never reach the report
GOOD = {"Environment": "dev", "Project": "aa-ecosys", "App": "cis", "Component": "api", "Owner": "tech-lead",
        "ManagedBy": "terraform", "CostCenter": "technology", "DataClassification": "internal"}


def _tags(d: dict) -> list[dict]:
    return [{"Key": k, "Value": v} for k, v in d.items()]


class StubTagging:
    """Two pages in us-west-1, one resource in us-east-1."""

    def __init__(self, region: str):
        self.region = region
        self.calls: list[dict] = []

    def get_resources(self, **kw):
        self.calls.append(kw)
        if self.region == "us-east-1":
            return {"ResourceTagMappingList": [
                {"ResourceARN": f"arn:aws:cloudfront::{ACCT}:distribution/EXAMPLE1", "Tags": _tags(GOOD)}]}
        if not kw.get("PaginationToken"):
            return {"PaginationToken": "p2", "ResourceTagMappingList": [
                {"ResourceARN": f"arn:aws:lambda:us-west-1:{ACCT}:function:example-fn", "Tags": _tags(GOOD)},
                {"ResourceARN": f"arn:aws:ec2:us-west-1:{ACCT}:security-group/sg-0example",
                 "Tags": _tags({"App": "shared", "Name": "example"})},
            ]}
        manual = dict(GOOD, ManagedBy="manual", App="booking")
        return {"PaginationToken": "", "ResourceTagMappingList": [
            {"ResourceARN": f"arn:aws:s3:::example-bucket-{ACCT}", "Tags": _tags(manual)},
            {"ResourceARN": f"arn:aws:rds:us-west-1:{ACCT}:snapshot:example-snap",
             "Tags": _tags({"Env": "dev", "aa:retain": "keep"})},
            {"ResourceARN": f"arn:aws:ssm:us-west-1:{ACCT}:session/someone-0example", "Tags": _tags({"x": "y"})},
        ]}


def _client_for():
    made = {}

    def f(region):
        made[region] = StubTagging(region)
        return made[region]
    f.made = made
    return f


def test_fetch_paginates_every_region():
    cf = _client_for()
    res = ur.fetch_resources(cf, ["us-west-1", "us-east-1"])
    assert len(res) == 6
    assert [c.get("PaginationToken") for c in cf.made["us-west-1"].calls] == [None, "p2"]


@pytest.mark.parametrize("arn,kind", [
    ("arn:aws:s3:::example-bucket", "s3:bucket"),
    ("arn:aws:ec2:us-west-1:x:security-group/sg-1", "ec2:security-group"),
    ("arn:aws:lambda:us-west-1:x:function:fn", "lambda:function"),
    ("arn:aws:rds:us-west-1:x:snapshot:s", "rds:snapshot"),
    ("arn:aws:sns:us-west-1:x:topic-name", "sns:topic"),
    ("arn:aws:secretsmanager:us-west-1:x:secret:aa-cis/dev/rds-AbC123", "secretsmanager:secret"),
    ("arn:aws:logs:us-west-1:x:log-group:/ecs/aa-cis-dev:*", "logs:log-group"),
    ("arn:aws:apigateway:us-west-1::/restapis/abc", "apigateway:restapis"),
    ("not-an-arn", "unknown"),
])
def test_resource_kind(arn, kind):
    assert ur.resource_kind(arn) == kind


def test_evaluate_counts_and_allows_manual_outside_terraform():
    res = ur.evaluate(ur.fetch_resources(_client_for(), ["us-west-1", "us-east-1"]), ur.report_policy())
    assert res["total"] == 5 and res["compliant"] == 3  # the manual S3 bucket is compliant here
    assert res["ignored"] == {"ssm:session": 1}
    assert res["by_kind"]["ec2:security-group"]["missing:Component"] == 1
    assert res["by_kind"]["rds:snapshot"]["no_app"] == 1
    snap = next(p for p in res["problems"] if p["kind"] == "rds:snapshot")
    assert any(p.startswith("forbidden Env") for p in snap["problems"])


def test_untagged_spend_reads_the_latest_month_and_explains_untaggable_lines():
    spend = ur.untagged_spend(ur.load_bundle(BUNDLE), None)
    assert spend["month"] == "2099-01" and spend["untagged_usd"] == 50.0 and spend["share"] == 0.25
    assert [s["service"] for s in spend["services"]] == ["Amazon Example Queue", "AWS Data Transfer"]
    assert spend["services"][1]["why"] and spend["services"][0]["why"] == ""


def test_untagged_spend_errors(tmp_path):
    with pytest.raises(ur.InputError):
        ur.untagged_spend(ur.load_bundle(BUNDLE), "2000-01")
    bad = tmp_path / "b.txt"
    bad.write_text("FINOPS_BUNDLE " + json.dumps({"kind": "finops_bundle", "part": "booking", "months": {"x": {}}}))
    with pytest.raises(ur.InputError):
        ur.load_bundle(str(bad))
    with pytest.raises(ur.InputError):
        ur.load_bundle(str(tmp_path / "missing.txt"))


def test_main_writes_a_masked_report_and_json(tmp_path):
    out, js = tmp_path / "r.md", tmp_path / "r.json"
    code = ur.main(["--bundle", BUNDLE, "--out", str(out), "--json", str(js)], client_for=_client_for())
    assert code == 0
    text = out.read_text()
    assert "Spend without an `App` tag, 2099-01" in text and "25.0 %" in text
    assert "| ec2:security-group | 1 | 0 | 0 |" in text
    assert ACCT not in text and ACCT not in js.read_text()  # aws_mask: the review goes into the public root repo
    assert json.loads(js.read_text())["spend"]["untagged_usd"] == 50.0


def test_max_share_exit_code_and_spend_only(tmp_path):
    assert ur.main(["--bundle", BUNDLE, "--no-resources", "--max-share", "0.2", "--out", str(tmp_path / "a")]) == 1
    assert ur.main(["--bundle", BUNDLE, "--no-resources", "--max-share", "0.3", "--out", str(tmp_path / "b")]) == 0


def test_aws_error_exits_2_without_traceback(capsys):
    def broken(region):
        raise RuntimeError("ExpiredToken: the MFA session ended")
    assert ur.main(["--no-resources"], client_for=broken) == 0  # nothing to call
    assert ur.main([], client_for=broken) == 2
    assert "AWS call failed" in capsys.readouterr().err
