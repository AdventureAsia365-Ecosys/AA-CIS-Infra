"""AA-1022 (S263): offline guards for the free hardening slice.

1. S3 gateway endpoint (modules/vpc): a Gateway endpoint for the regional S3 service on the private route table, and
   never on the db route table (the data tier has no way out of the VPC).
2. NAT recover alarm (observability_ecosys.tf): StatusCheckFailed_System on the NAT instance, EC2 recover action in
   this region plus the alerts topic, OK e-mail too.
3. GitHub OIDC trusts (accounts/aa365): every role whose subject names a GitHub environment also pins the `ref` claim
   to the default branch, so "main only" never rests on the environment's branch policy alone.
4. Identity Center administrator sessions (security_sso_signin.tf): AssumeRoleWithSAML, read-only events included,
   the us-east-1 forwarder carries the same events, and the e-mail never reads a field that holds an ARN or an
   account id.
5. The live check tool (sec_alert_check.py) names only rules that exist.

Run: python3 -m pytest -q tools/terraform/tests/test_aa1022_hardening.py
"""
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
AA365 = ROOT / "accounts" / "aa365"
sys.path.insert(0, str(ROOT / "tools" / "terraform"))

import sec_alert_check as chk  # noqa: E402

VPC = (ROOT / "modules" / "vpc" / "main.tf").read_text(encoding="utf-8")
OBS = (AA365 / "observability_ecosys.tf").read_text(encoding="utf-8")
BASELINE = (AA365 / "security_baseline.tf").read_text(encoding="utf-8")
SSO = (AA365 / "security_sso_signin.tf").read_text(encoding="utf-8")
OIDC_REF = "aws_iam_openid_connect_provider.github_actions.arn"
# AA-1004 P0: modules/environment (the environment stack, instantiated by accounts/aa365) holds app roles too; there
# the OIDC provider arrives as an input.
ENV_MODULE = ROOT / "modules" / "environment"
TF_DIRS = (AA365, ENV_MODULE)
OIDC_REFS = (OIDC_REF, "var.github_oidc_provider_arn")


def _resource(text: str, kind: str, name: str) -> str:
    m = re.search(rf'^resource "{kind}" "{name}" \{{', text, re.M)
    assert m, f"{kind}.{name} not found"
    body = text[m.end():]
    end = re.search(r"^\}", body, re.M)
    return body[: end.start()]


def _blocks(kind: str):
    for f in [f for d in TF_DIRS for f in sorted(d.glob("*.tf"))]:
        text = f.read_text(encoding="utf-8")
        for m in re.finditer(rf'^resource "{kind}" "([a-z0-9_]+)" \{{', text, re.M):
            body = text[m.end():]
            end = re.search(r"^\}", body, re.M)
            yield m.group(1), f.name, body[: end.start() if end else len(body)]


def _local(name: str) -> str:
    for f in [f for d in TF_DIRS for f in sorted(d.glob("*.tf"))]:
        m = re.search(rf"^\s*{name}\s*=\s*(.+?)(?=^\s*[a-z_0-9]+\s*=|\Z)", f.read_text(encoding="utf-8"), re.M | re.S)
        if m:
            return m.group(1)
    raise AssertionError(f"local {name} not found")


def _balanced(text: str, key: str) -> str:
    """The brace-balanced object after the first ``key = {`` (``${...}`` interpolations are balanced too)."""
    i = text.index("{", text.index(key))
    depth = 0
    for j in range(i, len(text)):
        depth += {"{": 1, "}": -1}.get(text[j], 0)
        if depth == 0:
            return text[i: j + 1]
    raise AssertionError("unbalanced block")


def _subject_text(block: str) -> str:
    """The subject expression of a trust, with the locals it is built from expanded (any depth)."""
    m = re.search(r'"token\.actions\.githubusercontent\.com:sub"\s*=\s*(\[.*?\]|.+)', block, re.S)
    assert m, "no sub condition"
    sub = m.group(1)
    seen, todo = set(), set(re.findall(r"local\.([a-z0-9_]+)", sub))
    while todo:
        loc = todo.pop()
        seen.add(loc)
        text = _local(loc)
        sub += "\n" + text
        todo |= set(re.findall(r"local\.([a-z0-9_]+)", text)) - seen
    return sub


class S3GatewayEndpointTest(unittest.TestCase):
    def setUp(self):
        self.ep = _resource(VPC, "aws_vpc_endpoint", "s3")

    def test_gateway_for_regional_s3(self):
        self.assertRegex(self.ep, r'vpc_endpoint_type\s*=\s*"Gateway"')
        self.assertRegex(self.ep, r'service_name\s*=\s*"com\.amazonaws\.\$\{data\.aws_region\.current\.region\}\.s3"')
        self.assertIn("vpc_id            = aws_vpc.main.id", self.ep)

    def test_private_route_table_only(self):
        tables = re.search(r"route_table_ids\s*=\s*\[(.*?)\]", self.ep, re.S).group(1)
        self.assertIn("aws_route_table.private.id", tables)
        self.assertNotIn("aws_route_table.db", tables)
        self.assertNotIn("aws_route_table.public", tables)

    def test_no_endpoint_policy(self):
        # Default policy (full access through the endpoint): bucket policies keep deciding access, as before.
        self.assertNotIn("policy", self.ep.split("tags")[0])


class NatRecoverAlarmTest(unittest.TestCase):
    def setUp(self):
        self.alarm = _resource(OBS, "aws_cloudwatch_metric_alarm", "nat_system_check_recover")

    def test_system_check_on_the_nat_instance(self):
        self.assertIn('metric_name         = "StatusCheckFailed_System"', self.alarm)
        self.assertIn("InstanceId = module.vpc.nat_instance_id", self.alarm)
        self.assertIn('namespace           = "AWS/EC2"', self.alarm)

    def test_recover_action_and_mail(self):
        actions = re.search(r"alarm_actions\s*=\s*\[(.*?)\]", self.alarm).group(1)
        self.assertIn('"arn:aws:automate:${var.aws_region}:ec2:recover"', actions)
        self.assertIn("aws_sns_topic.alerts.arn", actions)
        # observability_ecosys.tf header: every alarm also e-mails on OK.
        self.assertRegex(self.alarm, r"ok_actions\s*=\s*\[aws_sns_topic\.alerts\.arn\]")

    def test_never_reboot_or_stop(self):
        self.assertNotRegex(self.alarm, r"ec2:(reboot|stop|terminate)")


class OidcRefPinTest(unittest.TestCase):
    def oidc_roles(self):
        return [(n, f, b) for n, f, b in _blocks("aws_iam_role") if any(r in b for r in OIDC_REFS)]

    def test_environment_subjects_also_pin_the_ref(self):
        roles = self.oidc_roles()
        self.assertGreaterEqual(len(roles), 9)
        pinned = []
        for name, f, block in roles:
            sub = _subject_text(block)
            # Either spelled out (":environment:dev") or a context list ("environment:dev") joined in a for.
            if not re.search(r'[:"]environment:', sub):
                continue
            pinned.append(name)
            with self.subTest(role=name, file=f):
                ref = re.search(r'"token\.actions\.githubusercontent\.com:ref"\s*=\s*"([^"]+)"', block)
                self.assertIsNotNone(ref, "an environment subject needs the ref claim pinned too (AA-1022)")
                self.assertIn(ref.group(1), ("refs/heads/main", "refs/heads/master"))
                # The ref key must sit in StringEquals (exact), never StringLike.
                self.assertIn('"token.actions.githubusercontent.com:ref"', _balanced(block, "StringEquals"))
        # The environment-scoped roles of today (a rename or a regex miss would otherwise pass silently).
        self.assertTrue({"cis_app_deploy", "tf_apply", "db_auto_apply", "e2e_mail_reader", "booking_app_deploy",
                         "crm_app_deploy", "crm_scrub_corpus"} <= set(pinned), pinned)

    def test_booking_has_no_unused_ref_context(self):
        # AA-1022: every Booking job on the role runs in the dev environment; the old ref:refs/heads/main context
        # (a job without an environment) had no user. AA-1004 P0: the context is built from the module's environment
        # name, and accounts/aa365 instantiates the module with var.environment (= dev, terraform.tfvars).
        self.assertEqual(_local("bk_oidc_contexts").strip().splitlines()[0], '["environment:${var.environment}"]')
        env_call = (AA365 / "environment.tf").read_text(encoding="utf-8")
        self.assertRegex(env_call, r'(?m)^\s*environment\s*=\s*var\.environment\s*$')
        self.assertRegex((AA365 / "terraform.tfvars").read_text(encoding="utf-8"), r'(?m)^environment\s*=\s*"dev"')


class SsoAdminSigninTest(unittest.TestCase):
    def setUp(self):
        self.rule = _resource(SSO, "aws_cloudwatch_event_rule", "sec_sso_admin_signin")
        self.target = _resource(SSO, "aws_cloudwatch_event_target", "sec_sso_admin_signin")

    def test_permission_sets(self):
        sets = re.findall(r'^\s*[a-z-]+\s*=\s*"([A-Za-z-]+)"\s*$',
                          SSO.split("sec_sso_admin_permission_sets = {", 1)[1].split("}", 1)[0], re.M)
        self.assertEqual(sorted(sets), ["AA-Admin", "AdministratorAccess"])

    def test_rule_matches_saml_sessions_including_read_only(self):
        self.assertIn('state       = "ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS"', self.rule)
        self.assertIn('eventName         = ["AssumeRoleWithSAML"]', self.rule)
        self.assertIn('source        = ["aws.sts"]', self.rule)
        self.assertIn('name        = "${local.sec_prefix}-sso-admin-signin-${each.key}"', self.rule)
        self.assertIn("wildcard = local.sec_sso_admin_role_arn_patterns[each.key]", self.rule)

    def test_role_pattern_covers_both_role_paths(self):
        pat = SSO.split("sec_sso_admin_role_arn_patterns = {", 1)[1].split("\n  }", 1)[0]
        self.assertIn('"arn:aws:iam::*:role/aws-reserved/sso.amazonaws.com/*AWSReservedSSO_${ps}_*"', pat)

    def test_forwarder_carries_saml_sessions(self):
        fwd = _resource(BASELINE, "aws_cloudwatch_event_rule", "sec_global_forward")
        self.assertIn("provider    = aws.us_east_1", fwd)
        self.assertIn('state       = "ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS"', fwd)
        self.assertIn('eventName         = ["AssumeRoleWithSAML"]', fwd)
        self.assertIn("values(local.sec_sso_admin_role_arn_patterns)", fwd)

    def test_mail_reads_no_arn_or_account_field(self):
        paths = re.findall(r'=\s*"(\$\.[^"]+)"', self.target.split("input_paths", 1)[1].split("}", 1)[0])
        self.assertTrue(paths)
        for p in paths:
            with self.subTest(path=p):
                self.assertNotRegex(p.lower(), r"arn|account|principal|useridentity|resources|identityprovider")
        self.assertEqual(sorted(paths), sorted([
            "$.detail.requestParameters.roleSessionName", "$.detail.awsRegion", "$.detail.eventTime",
            "$.detail.errorCode",
        ]))
        template = self.target.split("input_template", 1)[1]
        self.assertNotIn("<principal>", template)
        self.assertTrue(template.strip().startswith('= "\\"[aa-sec] sso_admin_signin:'))

    def test_topic_policy_admits_the_rule_prefix(self):
        alerts = (AA365 / "identity_alerts.tf").read_text(encoding="utf-8")
        self.assertIn('rule/${local.sec_prefix}-*', alerts)


class LiveCheckToolTest(unittest.TestCase):
    def test_sso_cases_name_existing_rules(self):
        keys = re.findall(r'^\s*([a-z-]+)\s*=\s*"[A-Za-z-]+"\s*$',
                          SSO.split("sec_sso_admin_permission_sets = {", 1)[1].split("}", 1)[0], re.M)
        names = {f"aa-sec-dev-sso-admin-signin-{k}" for k in keys}
        sso_cases = [c for c in chk.cases("000000000000", "us-west-1", "dev") if c[0].startswith("sso.")]
        self.assertGreaterEqual(len(sso_cases), 4)
        for cid, rule, *_ in sso_cases:
            with self.subTest(case=cid):
                self.assertIn(rule, names)

    def test_saml_event_shape(self):
        ev = chk.saml_event("000000000000", "us-west-1", "AWSReservedSSO_AA-Admin_x", regional_path=True)
        self.assertEqual(ev["source"], "aws.sts")
        self.assertTrue(ev["detail"]["readOnly"])
        self.assertTrue(ev["detail"]["requestParameters"]["roleArn"].endswith(
            ":role/aws-reserved/sso.amazonaws.com/us-west-1/AWSReservedSSO_AA-Admin_x"))

    def test_every_sso_case_has_both_outcomes(self):
        cases = [c for c in chk.cases("000000000000", "us-west-1", "dev") if "sso" in c[0]]
        self.assertEqual({c[4] for c in cases}, {True, False})


if __name__ == "__main__":
    unittest.main()
