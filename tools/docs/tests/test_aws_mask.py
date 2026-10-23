"""Tests for tools/docs/aws_mask.py and the no-leak guard on every generated page (AA-981).

    python3 -m unittest discover -s tools/docs/tests -v

Offline. Every identifier below (account ids, EC2/VPC ids, ALB ids, secret suffixes, domain ids) is a fake in
AWS documentation style, never a real resource of the program: this repo is public.
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))

import aws_mask as am  # noqa: E402
import gen_docs as gd  # noqa: E402
import gen_env_config as ec  # noqa: E402
import test_gen_docs as tgd  # noqa: E402
import test_gen_env_config as tec  # noqa: E402

A2 = "111122223333"  # fake "acc2"
A3 = "444455556666"  # fake "acc3"
ALIASES = {A2: "acc2", A3: "acc3"}
ENV = {am.ENV_VAR: f"acc2={A2},acc3={A3}"}
UUID_TENANT = "00000000-0000-0000-0000-000000000001"


class ParseAliases(unittest.TestCase):
    def test_parse(self):
        self.assertEqual(am.parse_aliases(f"acc2={A2}, acc3={A3}\n"), ALIASES)
        self.assertEqual(am.parse_aliases(""), {})
        self.assertEqual(am.parse_aliases(None), {})

    def test_malformed_fails_closed_without_echoing_the_id(self):
        for bad in (f"acc2:{A2}", "acc2=1234", f"Acc2={A2}", f"={A2}"):
            with self.assertRaises(am.AliasError) as cm:
                am.parse_aliases(bad)
            self.assertNotIn(A2, str(cm.exception))


class MaskText(unittest.TestCase):
    def m(self, s: str) -> str:
        return am.mask_text(s, ALIASES)

    def test_arns_keep_service_region_and_resource(self):
        self.assertEqual(self.m(f"arn:aws:iam::{A2}:role/aa-cis-dev-agent-session"), "arn:{partition}:iam::{acc2}:role/aa-cis-dev-agent-session")
        self.assertEqual(
            self.m(f"arn:aws:elasticloadbalancing:us-west-1:{A2}:listener/app/aa-cis-dev-alb/0123456789abcdef/fedcba9876543210"),
            "arn:{partition}:elasticloadbalancing:us-west-1:{acc2}:listener/app/aa-cis-dev-alb/0123456789abcdef/fedcba9876543210",
        )
        self.assertEqual(self.m(f"arn:aws:ecs:us-west-1:{A2}:task-definition/aa-cis-dev-db-migrate:76"), "arn:{partition}:ecs:us-west-1:{acc2}:task-definition/aa-cis-dev-db-migrate:76")
        self.assertEqual(self.m("arn:aws:iam::aws:policy/ReadOnlyAccess"), "arn:{partition}:iam::aws:policy/ReadOnlyAccess")
        self.assertEqual(self.m("arn:aws:s3:::aa-cis-bronze-bucket/x"), "arn:{partition}:s3:::aa-cis-bronze-bucket/x")

    def test_secret_arn_loses_its_random_suffix(self):
        self.assertEqual(
            self.m(f"`arn:aws:secretsmanager:us-west-1:{A2}:secret:booking/dev/database-url-AbC123`"),
            "`arn:{partition}:secretsmanager:us-west-1:{acc2}:secret:booking/dev/database-url`",
        )

    def test_unknown_account_and_embedded_ids(self):
        self.assertEqual(self.m("arn:aws:iam::999988887777:root"), "arn:{partition}:iam::{aws-account}:root")
        self.assertEqual(self.m(f"aa-cis-bronze-{A2}"), "aa-cis-bronze-{acc2}")
        self.assertEqual(self.m(f"{A2}.dkr.ecr.us-west-1.amazonaws.com/aa-booking-dev-api"), "{acc2}.dkr.ecr.us-west-1.amazonaws.com/aa-booking-dev-api")
        self.assertEqual(self.m(f"{A3}:root (MultiFactorAuthPresent)"), "{acc3}:root (MultiFactorAuthPresent)")
        self.assertEqual(am.mask_text(f"x {A2} y", {}), "x {aws-account} y")

    def test_arns_inside_json_and_tables(self):
        js = json.dumps({"alb_arn": f"arn:aws:elasticloadbalancing:us-west-1:{A2}:loadbalancer/app/a/1", "n": 1})
        out = self.m(f"| `load_balancers` | `{js}` |")
        self.assertIn('"alb_arn": "arn:{partition}:elasticloadbalancing:us-west-1:{acc2}:loadbalancer/app/a/1"', out)
        self.assertEqual(am.find_leaks(out), [])

    def test_ec2_ids(self):
        out = self.m("vpc-0123456789abcdef0 subnet-0abc1234def567890 sg-0123abcd i-0abcdef1234567890 eni-0fedcba9876543210 igw-0a1b2c3d4e5f60718 rtb-0b1c2d3e4f5a60718")
        self.assertEqual(out, "vpc-{masked} subnet-{masked} sg-{masked} i-{masked} eni-{masked} igw-{masked} rtb-{masked}")
        # Names that only look alike stay.
        self.assertEqual(self.m("aa-cis-dev-sg-alb aa-cis-dev-api-5xx d-abcde12345"), "aa-cis-dev-sg-alb aa-cis-dev-api-5xx d-abcde12345")

    def test_uuids_and_other_numbers_stay(self):
        s = f"USING (tenant_id = '{UUID_TENANT}'::uuid) 1234567890123 12345678901 PostgreSQL 15.17"
        self.assertEqual(self.m(s), s)
        self.assertEqual(am.find_leaks(s), [])

    def test_idempotent(self):
        s = f"arn:aws:secretsmanager:us-west-1:{A2}:secret:a/b-AbC123 {A2} sg-0123abcd"
        once = self.m(s)
        self.assertEqual(self.m(once), once)

    def test_find_leaks_never_returns_the_value(self):
        leaks = am.find_leaks(f"x {A2} arn:aws:iam::{A2}:role/r sg-0123abcd")
        self.assertEqual(len(leaks), 3)
        self.assertNotIn(A2, " ".join(leaks))


class RewritePage(unittest.TestCase):
    def test_rewrite_recomputes_the_gen_docs_fingerprint(self):
        body = f"| `aws_s3_bucket` | aa-cis-bronze-{A2} | `module.s3.aws_s3_bucket.bronze` |\n"
        spec = gd.SPECS["inventory.md"]
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop(am.ENV_VAR, None)
            # What a pre-AA-981 generator wrote: unmasked body, fingerprint of the unmasked body.
            old = gd.page(spec, "PLACEHOLDER\n", date="2026-10-22", sha="abc", source="s").replace("PLACEHOLDER\n", body)
        old = old.replace(gd.FINGERPRINT_RE.search(old).group(1), gd.fingerprint(body))
        new = am.rewrite_page(old, ALIASES)
        self.assertEqual(am.find_leaks(new), [])
        expected = gd.page(spec, body, date="2026-10-22", sha="abc", source="s", aliases=ALIASES)
        self.assertEqual(new, expected)

    def test_cli_rewrite_and_check(self):
        with tempfile.TemporaryDirectory() as t:
            p = Path(t) / "x.md"
            p.write_text(f"**Verified:** acc2 `{A2}`, tenant {UUID_TENANT}\n", encoding="utf-8")
            with mock.patch.dict(os.environ, ENV):
                self.assertEqual(am.main(["check", str(p)]), 1)
                self.assertEqual(am.main(["rewrite", str(p)]), 0)
                self.assertEqual(am.main(["check", str(p)]), 0)
            self.assertEqual(p.read_text(encoding="utf-8"), f"**Verified:** acc2 `{{acc2}}`, tenant {UUID_TENANT}\n")


def leaky_state_doc() -> dict:
    """The gen_docs fixture plus realistic account ids, ARNs and EC2 ids in every place a page shows them."""
    doc = tgd.state_doc()
    acct = tgd.ACCT
    res = doc["values"]["root_module"]["resources"]
    res += [
        tgd._res("aws_s3_bucket.bronze", "aws_s3_bucket", {"bucket": f"aa-cis-bronze-{acct}", "tags": {"App": "cis"}}),
        tgd._res("aws_lb_listener.https", "aws_lb_listener", {"arn": f"arn:aws:elasticloadbalancing:us-west-1:{acct}:listener/app/a/1/2", "load_balancer_arn": f"arn:aws:elasticloadbalancing:us-west-1:{acct}:loadbalancer/app/a/1", "protocol": "HTTPS", "port": 443, "default_action": [{"type": "forward"}], "tags": {"App": "shared"}}),
        tgd._res("aws_iam_openid_connect_provider.gh", "aws_iam_openid_connect_provider", {"arn": f"arn:aws:iam::{acct}:oidc-provider/token.actions.githubusercontent.com", "url": "https://token.actions.githubusercontent.com", "client_id_list": ["sts.amazonaws.com"]}),
        tgd._res("aws_iam_role.agent", "aws_iam_role", {"name": "aa-test-agent", "assume_role_policy": json.dumps({"Statement": [{"Effect": "Allow", "Principal": {"AWS": f"arn:aws:iam::{acct}:root"}, "Condition": {"Bool": {"aws:MultiFactorAuthPresent": "true"}}}]}), "tags": {}}),
        tgd._res("aws_cloudwatch_metric_alarm.nat", "aws_cloudwatch_metric_alarm", {"alarm_name": "aa-test-nat-cpu", "alarm_description": f"NAT. Runbook: {tgd.BLOB}docs/ops/incident-response.md", "namespace": "AWS/EC2", "metric_name": "CPUUtilization", "statistic": "Average", "dimensions": {"InstanceId": "i-0abcdef1234567890"}, "comparison_operator": "GreaterThanThreshold", "threshold": 80, "period": 300, "evaluation_periods": 1, "alarm_actions": [tgd.TOPIC], "ok_actions": [tgd.TOPIC], "tags": {"App": "shared"}}),
        tgd._res("aws_vpc.real", "aws_vpc", {"id": "vpc-0123456789abcdef0", "cidr_block": "10.2.0.0/16", "tags": {"Name": "aa-real-vpc", "App": "shared"}}),
        tgd._res("aws_security_group.real", "aws_security_group", {"id": "sg-0a1b2c3d4e5f60718", "name": "aa-real-sg", "description": "real", "ingress": [{"protocol": "tcp", "from_port": 443, "to_port": 443, "security_groups": ["sg-0fedcba987654321a"], "cidr_blocks": []}], "egress": [], "tags": {"App": "shared"}}),
    ]
    doc["values"]["outputs"].update(
        {
            "agent_session_role_arn": {"sensitive": False, "value": f"arn:aws:iam::{acct}:role/aa-test-agent"},
            "db_secret_arn": {"sensitive": False, "value": f"arn:aws:secretsmanager:us-west-1:{acct}:secret:booking/dev/database-url-AbC123"},
            "ecr_url": {"sensitive": False, "value": f"{acct}.dkr.ecr.us-west-1.amazonaws.com/aa-booking-dev-api"},
            "load_balancers": {"sensitive": False, "value": {"alb_arn": f"arn:aws:elasticloadbalancing:us-west-1:{acct}:loadbalancer/app/a/1"}},
            "tenant": {"sensitive": False, "value": UUID_TENANT},
        }
    )
    return doc


class NoLeakGuard(unittest.TestCase):
    """CI guard: no generated page carries a 12-digit number (outside a UUID), `arn:aws:` or an EC2 id."""

    def render(self, tmp: Path, env: dict) -> Path:
        src = tgd.write_json(tmp, "state.json", leaky_state_doc())
        with mock.patch.dict(os.environ, env, clear=False):
            if am.ENV_VAR not in env:
                os.environ.pop(am.ENV_VAR, None)
            self.assertEqual(gd.main(["render", "--tf-json", str(src), "--out-dir", str(tmp / "o")]), 0)
        return tmp / "o"

    def test_gen_docs_pages_have_no_leak_with_and_without_aliases(self):
        for env in ({am.ENV_VAR: f"acc2={tgd.ACCT}"}, {}):
            with tempfile.TemporaryDirectory() as t:
                out = self.render(Path(t), env)
                pages = {p: (out / p).read_text(encoding="utf-8") for p in gd.PAGES}
            for name, text in pages.items():
                self.assertEqual(am.find_leaks(text), [], f"{name} with {list(env)}")
                self.assertNotRegex(am.UUID_RE.sub("", text), r"\b\d{12}\b", name)
                self.assertNotIn("arn:aws:", text, name)
            inv = pages["inventory.md"]
            label = "{acc2}" if env else "{aws-account}"
            self.assertIn(f"aa-cis-bronze-{label}", inv)
            self.assertIn(f"`arn:{{partition}}:secretsmanager:us-west-1:{label}:secret:booking/dev/database-url`", inv)
            self.assertIn(f"`{label}.dkr.ecr.us-west-1.amazonaws.com/aa-booking-dev-api`", inv)
            self.assertIn(f"`{UUID_TENANT}`", inv)  # a UUID is not an account id
            self.assertIn(f"{label}:root (MultiFactorAuthPresent)", pages["iam-roles.md"])
            self.assertIn("vpc-{masked}", pages["network.md"])
            self.assertIn("InstanceId=i-{masked}", pages["alarms.md"])

    def test_page_masks_raw_ids_and_assert_clean_catches_leaks(self):
        # page() masks whatever the renderer left raw; assert_clean is the backstop it runs on the result.
        text = gd.page(gd.SPECS["alarms.md"], f"x {tgd.ACCT} arn:aws:sns:us-west-1:{tgd.ACCT}:t\n", date="2026-10-23", sha="s", source="s", aliases={})
        self.assertEqual(am.find_leaks(text), [])
        with self.assertRaises(AssertionError):
            am.assert_clean(f"x {tgd.ACCT}", "x")

    def test_malformed_alias_table_exits_2(self):
        with tempfile.TemporaryDirectory() as t:
            src = tgd.write_json(Path(t), "state.json", leaky_state_doc())
            with mock.patch.dict(os.environ, {am.ENV_VAR: "acc2=oops"}):
                self.assertEqual(gd.main(["render", "--tf-json", str(src), "--out-dir", str(Path(t) / "o")]), 2)

    def test_env_config_page_has_no_leak(self):
        page = ec.render_page(tec._aws_model(), tec._vercel_model(), date="2026-10-23", sha="s", source="s")
        self.assertEqual(am.find_leaks(page), [])


if __name__ == "__main__":
    unittest.main()
