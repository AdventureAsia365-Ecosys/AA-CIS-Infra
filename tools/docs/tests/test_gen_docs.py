"""Tests for tools/docs/gen_docs.py (AA-893). Run from the repo root:

    python3 -m unittest discover -s tools/docs/tests -v

Offline: a synthetic Terraform JSON document built below (fake IDs, fake account), no Terraform, no AWS.
The last test runs the source guard over this repo's real accounts/ and modules/ .tf files.
"""
from __future__ import annotations

import copy
import datetime as dt
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import gen_docs as gd  # noqa: E402

REPO_ROOT = HERE.parents[2]
ACCT = "111122223333"  # fake
TOPIC = f"arn:aws:sns:us-west-1:{ACCT}:aa-test-alerts"
BLOB = gd.ROOT_REPO_BLOB_PREFIX
PLANTED = "planted-value-never-rendered"


def _res(address: str, rtype: str, values: dict) -> dict:
    return {"address": address, "mode": "managed", "type": rtype, "name": address.split(".")[-1], "values": values}


def _alarm(name: str, app: str, runbook: str | None, **extra) -> dict:
    desc = f"{name} fired." + (f" Runbook: {runbook}" if runbook else "")
    v = {
        "alarm_name": name,
        "alarm_description": desc,
        "namespace": "AWS/ApiGateway",
        "metric_name": "5XXError",
        "statistic": "Sum",
        "extended_statistic": "",
        "comparison_operator": "GreaterThanOrEqualToThreshold",
        "threshold": 5.0,
        "evaluation_periods": 1,
        "datapoints_to_alarm": 0,
        "period": 300,
        "dimensions": {"Stage": "dev", "ApiName": "api"},
        "treat_missing_data": "notBreaching",
        "alarm_actions": [TOPIC],
        "ok_actions": [TOPIC],
        "actions_enabled": True,
        "metric_query": [],
        "tags": {"App": app},
    }
    v.update(extra)
    return _res(f"aws_cloudwatch_metric_alarm.{name.replace('-', '_')}", "aws_cloudwatch_metric_alarm", v)


def state_doc() -> dict:
    resources = [
        _alarm("aa-cis-dev-api-5xx", "cis", BLOB + "docs/ops/playbooks/5xx-spike.md"),
        _alarm("aa-booking-dev-api-5xx", "booking", BLOB + "docs/ops/playbooks/5xx-spike.md"),
        _alarm(
            "aa-cis-dev-held-rate",
            "cis",
            BLOB + "docs/ops/incident-response.md",
            namespace="",
            metric_name="",
            statistic="",
            metric_query=[
                {"id": "a", "expression": "", "return_data": False, "label": "", "metric": [{"namespace": "acp", "metric_name": "held", "stat": "Sum", "period": 3600, "dimensions": {}}]},
                {"id": "rate", "expression": "a * 100", "return_data": True, "label": "held rate", "metric": []},
            ],
        ),
        _res(
            "aws_cloudwatch_event_rule.breakglass",
            "aws_cloudwatch_event_rule",
            {
                "name": "aa-identity-dev-breakglass",
                "description": f"Break-glass secret read. Runbook: {BLOB}docs/ops/runbooks/break-glass.md",
                "event_pattern": json.dumps({"source": ["aws.secretsmanager"], "detail-type": ["AWS API Call via CloudTrail"], "detail": {"$or": [{"eventName": ["GetSecretValue"]}, {"eventName": ["BatchGetSecretValue"]}]}}),
                "tags": {"App": "identity"},
            },
        ),
        _res("aws_cloudwatch_event_target.breakglass", "aws_cloudwatch_event_target", {"rule": "aa-identity-dev-breakglass", "arn": TOPIC}),
        # A rule that targets a Lambda is not an alarm and must not be listed.
        _res("aws_cloudwatch_event_rule.ingest", "aws_cloudwatch_event_rule", {"name": "aa-cis-dev-ingest", "description": "daily", "schedule_expression": "rate(1 day)", "tags": {"App": "cis"}}),
        _res("aws_cloudwatch_event_target.ingest", "aws_cloudwatch_event_target", {"rule": "aa-cis-dev-ingest", "arn": f"arn:aws:lambda:us-west-1:{ACCT}:function:x"}),
        # Values that must never reach a page.
        _res("aws_secretsmanager_secret_version.db", "aws_secretsmanager_secret_version", {"id": "arn|v1", "secret_string": PLANTED}),
        _res("random_password.db", "random_password", {"id": "none", "result": PLANTED}),
        # Network
        _res("module.vpc.aws_vpc.main", "aws_vpc", {"id": "vpc-0fake", "cidr_block": "10.9.0.0/16", "tags": {"Name": "aa-test-vpc", "App": "shared"}}),
        _res("module.vpc.aws_subnet.private[0]", "aws_subnet", {"id": "subnet-0a", "availability_zone": "us-west-1a", "cidr_block": "10.9.10.0/24", "map_public_ip_on_launch": False, "tags": {"Name": "aa-test-private-1", "App": "shared"}}),
        _res("module.vpc.aws_route_table.private", "aws_route_table", {"id": "rtb-0p", "route": [{"cidr_block": "0.0.0.0/0", "network_interface_id": "eni-0nat"}], "tags": {"Name": "aa-test-rt-private"}}),
        _res("module.vpc.aws_route_table_association.private[0]", "aws_route_table_association", {"subnet_id": "subnet-0a", "route_table_id": "rtb-0p"}),
        _res("module.vpc.aws_instance.nat", "aws_instance", {"id": "i-0nat", "instance_type": "t4g.nano", "subnet_id": "subnet-0a", "private_ip": "10.9.1.5", "primary_network_interface_id": "eni-0nat", "tags": {"Name": "aa-test-nat"}}),
        _res("module.vpc.aws_security_group.rds", "aws_security_group", {"id": "sg-0rds", "name": "aa-test-sg-rds", "description": "RDS", "ingress": [{"protocol": "tcp", "from_port": 5432, "to_port": 5432, "security_groups": ["sg-0b", "sg-0a"], "cidr_blocks": [], "self": False, "description": ""}], "egress": [], "tags": {"App": "shared"}}),
        _res("aws_security_group.a", "aws_security_group", {"id": "sg-0a", "name": "aa-test-sg-a", "description": "a", "ingress": [], "egress": [{"protocol": "-1", "from_port": 0, "to_port": 0, "cidr_blocks": ["0.0.0.0/0"]}], "tags": {"App": "cis"}}),
        _res("aws_security_group.b", "aws_security_group", {"id": "sg-0b", "name": "aa-test-sg-b", "description": "b", "ingress": [], "egress": [], "tags": {"App": "booking"}}),
        # IAM
        _res(
            "aws_iam_role.plan",
            "aws_iam_role",
            {
                "name": "aa-test-tf-plan",
                "description": "plan",
                "permissions_boundary": "",
                "assume_role_policy": json.dumps({"Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Principal": {"Federated": f"arn:aws:iam::{ACCT}:oidc-provider/token.actions.githubusercontent.com"}, "Action": "sts:AssumeRoleWithWebIdentity", "Condition": {"StringEquals": {"token.actions.githubusercontent.com:aud": "sts.amazonaws.com", "token.actions.githubusercontent.com:sub": ["repo:Org@1/AA-CIS-Infra@2:pull_request"]}}}]}),
                "tags": {},
            },
        ),
        _res("aws_iam_role_policy.plan", "aws_iam_role_policy", {"role": "aa-test-tf-plan", "name": "aa-test-tf-plan-policy", "policy": json.dumps({"Statement": [{"Effect": "Allow", "Action": ["s3:PutObject"], "Resource": "*"}, {"Effect": "Deny", "Action": "iam:*", "Resource": "*"}]})}),
        _res("aws_iam_role_policy_attachment.plan_ro", "aws_iam_role_policy_attachment", {"role": "aa-test-tf-plan", "policy_arn": "arn:aws:iam::aws:policy/ReadOnlyAccess"}),
    ]
    return {
        "format_version": "1.0",
        "terraform_version": "1.15.5",
        "values": {
            "outputs": {
                "network_vpc_id": {"sensitive": False, "value": "vpc-0fake", "type": "string"},
                "db_password_echo": {"sensitive": True, "value": PLANTED, "type": "string"},
            },
            "root_module": {"resources": resources[:9], "child_modules": [{"address": "module.vpc", "resources": resources[9:]}]},
        },
    }


def plan_doc() -> dict:
    s = state_doc()
    return {"format_version": "1.2", "planned_values": s["values"], "resource_changes": []}


def write_json(tmp: Path, name: str, data: dict) -> Path:
    p = tmp / name
    p.write_text(json.dumps(data), encoding="utf-8")
    return p


def fake_root(tmp: Path, files=("docs/ops/playbooks/5xx-spike.md", "docs/ops/incident-response.md", "docs/ops/runbooks/break-glass.md")) -> Path:
    root = tmp / "root"
    for f in files:
        (root / f).parent.mkdir(parents=True, exist_ok=True)
        (root / f).write_text("# x\n", encoding="utf-8")
    return root


class LoadTests(unittest.TestCase):
    def test_state_and_plan_are_both_read(self):
        with tempfile.TemporaryDirectory() as t:
            tmp = Path(t)
            s = gd.load_tf_json(write_json(tmp, "s.json", state_doc()))
            p = gd.load_tf_json(write_json(tmp, "p.json", plan_doc()))
        self.assertEqual((s.kind, p.kind), ("state", "plan"))
        self.assertEqual(len(s.resources), len(p.resources))
        self.assertIn("module.vpc.aws_vpc.main", {r.address for r in s.resources})

    def test_bad_input_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            tmp = Path(t)
            (tmp / "x.json").write_text("not json", encoding="utf-8")
            with self.assertRaises(gd.InputError):
                gd.load_tf_json(tmp / "x.json")
            with self.assertRaises(gd.InputError):
                gd.load_tf_json(write_json(tmp, "y.json", {"hello": 1}))
            rc = gd.main(["render", "--tf-json", str(tmp / "x.json"), "--out-dir", str(tmp / "out")])
        self.assertEqual(rc, 2)


class AlarmTests(unittest.TestCase):
    def render(self, doc: dict, root: Path | None):
        with tempfile.TemporaryDirectory() as t:
            tf = gd.load_tf_json(write_json(Path(t), "s.json", doc))
        problems = gd.Problems()
        return gd.render_alarms(tf, root, problems), problems.items

    def test_rows_link_runbooks_relative_to_docs_generated(self):
        with tempfile.TemporaryDirectory() as t:
            body, problems = self.render(state_doc(), fake_root(Path(t)))
        self.assertEqual(problems, [])
        self.assertIn("[ops/playbooks/5xx-spike.md](../ops/playbooks/5xx-spike.md)", body)
        self.assertIn("[ops/runbooks/break-glass.md](../ops/runbooks/break-glass.md)", body)
        self.assertIn("**Totals:** 3 metric alarms, 1 EventBridge alarm rules.", body)
        self.assertIn("### booking", body)
        self.assertIn("aa-test-alerts (ALARM + OK)", body)
        self.assertIn("AWS/ApiGateway/5XXError Sum [ApiName=api, Stage=dev] >= 5 per 5 min", body)
        self.assertIn("held rate = a * 100 >= 5, 1 period(s), missing data: notBreaching (a = acp/held Sum per 1 h)", body)
        self.assertIn("aws.secretsmanager / AWS API Call via CloudTrail: BatchGetSecretValue, GetSecretValue", body)
        self.assertNotIn("aa-cis-dev-ingest", body)  # Lambda target: not an alarm
        self.assertNotIn("Runbook: https", body)  # the suffix is moved into its own column

    def test_missing_runbook_is_a_problem(self):
        doc = state_doc()
        doc["values"]["root_module"]["resources"][0] = _alarm("aa-cis-dev-api-5xx", "cis", None)
        body, problems = self.render(doc, None)
        self.assertIn("**MISSING**", body)
        self.assertEqual(len(problems), 1)
        self.assertIn("aa-cis-dev-api-5xx", problems[0])

    def test_link_outside_root_docs_is_a_problem(self):
        doc = state_doc()
        rs = doc["values"]["root_module"]["resources"]
        rs[0] = _alarm("a1", "cis", "https://example.com/runbook.md")
        rs[1] = _alarm("a2", "cis", BLOB + "README.md")
        _, problems = self.render(doc, None)
        self.assertEqual(len(problems), 2)

    def test_link_to_a_missing_file_is_a_problem_with_root_dir(self):
        with tempfile.TemporaryDirectory() as t:
            root = fake_root(Path(t), files=("docs/ops/incident-response.md",))
            body, problems = self.render(state_doc(), root)
        self.assertIn("**BROKEN** `docs/ops/playbooks/5xx-spike.md`", body)
        self.assertEqual(sum("does not exist" in p for p in problems), 3)  # two 5xx alarms + break-glass rule

    def test_strict_render_exits_1_on_problems(self):
        doc = state_doc()
        doc["values"]["root_module"]["resources"][0] = _alarm("x", "cis", None)
        with tempfile.TemporaryDirectory() as t:
            tmp = Path(t)
            src = write_json(tmp, "s.json", doc)
            rc_soft = gd.main(["render", "--tf-json", str(src), "--out-dir", str(tmp / "o"), "--problems-file", str(tmp / "p.txt")])
            rc_strict = gd.main(["render", "--tf-json", str(src), "--out-dir", str(tmp / "o"), "--strict"])
            problems = (tmp / "p.txt").read_text(encoding="utf-8")
        self.assertEqual((rc_soft, rc_strict), (0, 1))
        self.assertIn("x: no ' Runbook: <url>' suffix", problems)


class PageTests(unittest.TestCase):
    def render_dir(self, doc: dict, tmp: Path, out: str, **kw) -> Path:
        src = write_json(tmp, f"{out}.json", doc)
        args = ["render", "--tf-json", str(src), "--out-dir", str(tmp / out), "--root-dir", str(fake_root(tmp))]
        for k, v in kw.items():
            args += [f"--{k}", v]
        self.assertEqual(gd.main(args), 0)
        return tmp / out

    def test_no_secret_value_reaches_any_page(self):
        with tempfile.TemporaryDirectory() as t:
            out = self.render_dir(state_doc(), Path(t), "o")
            text = "".join((out / p).read_text(encoding="utf-8") for p in gd.PAGES)
        self.assertNotIn(PLANTED, text)
        self.assertIn("(sensitive, not shown)", text)

    def test_front_matter_and_generated_marker(self):
        with tempfile.TemporaryDirectory() as t:
            out = self.render_dir(state_doc(), Path(t), "o", date="2026-10-20", sha="abc123")
            text = (out / "alarms.md").read_text(encoding="utf-8")
        self.assertTrue(text.startswith("---\nid: OPS-07\n"))
        self.assertIn("\nlast_reviewed: 2026-10-20\n", text)
        self.assertIn("\ngenerated: true\n", text)
        self.assertIn("<!-- GENERATED by AA-CIS-Infra .github/workflows/docs-gen.yml from AA-CIS-Infra@abc123 - do not edit -->", text)
        self.assertRegex(text, r"<!-- docs-fingerprint: [0-9a-f]{64} -->")
        # The blockquote ends before the body (blank line), so the body is not quoted.
        self.assertIn("change the Terraform in AA-CIS-Infra.\n\nEvery CloudWatch", text)

    def test_network_and_iam_tables(self):
        with tempfile.TemporaryDirectory() as t:
            out = self.render_dir(state_doc(), Path(t), "o")
            net = (out / "network.md").read_text(encoding="utf-8")
            iam = (out / "iam-roles.md").read_text(encoding="utf-8")
            inv = (out / "inventory.md").read_text(encoding="utf-8")
        self.assertIn("tcp 5432 aa-test-sg-a, aa-test-sg-b", net)  # peers by name, sorted
        self.assertIn("0.0.0.0/0 -> network_interface aa-test-nat (eni-0nat)", net)
        self.assertIn("GitHub OIDC (sub AA-CIS-Infra:pull_request)", iam)
        self.assertIn("ReadOnlyAccess", iam)
        self.assertIn("`Deny iam:*`", iam)
        self.assertIn("| `network_vpc_id` | `vpc-0fake` |", inv)

    def test_output_is_deterministic_and_fingerprint_ignores_date_and_sha(self):
        doc2 = state_doc()
        doc2["values"]["root_module"]["resources"].reverse()
        rs = doc2["values"]["root_module"]["child_modules"][0]["resources"]
        rs.reverse()
        sg = next(r for r in rs if r["address"] == "module.vpc.aws_security_group.rds")
        sg["values"]["ingress"][0]["security_groups"].reverse()
        with tempfile.TemporaryDirectory() as t:
            tmp = Path(t)
            a = self.render_dir(state_doc(), tmp, "a", date="2026-10-01", sha="one")
            b = self.render_dir(doc2, tmp, "b", date="2026-10-20", sha="two")
            for p in gd.PAGES:
                self.assertEqual(gd.read_meta(a / p)[0], gd.read_meta(b / p)[0], p)
            self.assertEqual(gd.changed_pages(b, a, 30, dt.date(2026, 10, 20)), [])

    def test_changed_pages(self):
        changed = state_doc()
        changed["values"]["root_module"]["resources"][0]["values"]["threshold"] = 9.0
        with tempfile.TemporaryDirectory() as t:
            tmp = Path(t)
            old = self.render_dir(state_doc(), tmp, "old", date="2026-10-01")
            new = self.render_dir(changed, tmp, "new", date="2026-10-20")
            self.assertEqual(gd.changed_pages(new, old, 30, dt.date(2026, 10, 20)), ["alarms.md"])
            # Unchanged but older than the window: republished to refresh last_reviewed.
            self.assertEqual(gd.changed_pages(new, old, 10, dt.date(2026, 10, 20)), list(gd.PAGES))
            # Missing on master: published.
            (old / "network.md").unlink()
            self.assertIn("network.md", gd.changed_pages(new, old, 30, dt.date(2026, 10, 20)))


class SourceGuardTests(unittest.TestCase):
    def check(self, text: str) -> list[str]:
        with tempfile.TemporaryDirectory() as t:
            (Path(t) / "x.tf").write_text(text, encoding="utf-8")
            return gd.check_source([Path(t)])

    def test_alarm_without_suffix_fails(self):
        problems = self.check(
            'resource "aws_cloudwatch_metric_alarm" "a" {\n  alarm_name = "a"\n  alarm_description = "no link"\n  tags = { App = "cis" }\n}\n'
            'resource "aws_cloudwatch_metric_alarm" "b" {\n  alarm_description = "ok.${local.runbook_suffix.database}"\n}\n'
        )
        self.assertEqual(len(problems), 1)
        self.assertIn("aws_cloudwatch_metric_alarm.a", problems[0])

    def test_sns_rule_needs_suffix_in_description_and_template(self):
        tf = (
            'resource "aws_cloudwatch_event_rule" "r" {\n  description = "no link"\n  event_pattern = jsonencode({ a = { b = 1 } })\n}\n'
            'resource "aws_cloudwatch_event_target" "t" {\n  rule = aws_cloudwatch_event_rule.r.name\n  arn  = aws_sns_topic.alerts.arn\n'
            '  input_transformer {\n    input_template = "\\"text\\""\n  }\n}\n'
            'resource "aws_cloudwatch_event_rule" "l" {\n  description = "lambda, fine"\n}\n'
            'resource "aws_cloudwatch_event_target" "lt" {\n  rule = aws_cloudwatch_event_rule.l.name\n  arn  = aws_lambda_function.x.arn\n}\n'
        )
        problems = self.check(tf)
        self.assertEqual(len(problems), 2)
        fixed = tf.replace('description = "no link"', 'description = "x.${local.runbook_suffix.incident}"').replace('\\"text\\"', '\\"text${local.runbook_suffix.incident}\\"')
        self.assertEqual(self.check(fixed), [])

    def test_this_repo_has_a_runbook_on_every_alarm(self):
        problems = gd.check_source([REPO_ROOT / "accounts", REPO_ROOT / "modules"])
        self.assertEqual(problems, [])


if __name__ == "__main__":
    unittest.main()
