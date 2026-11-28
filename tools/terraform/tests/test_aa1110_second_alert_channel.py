"""AA-1110 (S283): offline guards for the second alert channel of the alerts topic.

1. observability.tf: aws_sns_topic_subscription.alerts_email_secondary is an e-mail subscription to the alerts topic,
   created only when var.alert_email_secondary is set (count 0 by default: no resource, no cost, nothing to confirm).
2. variables.tf: the variable defaults to "" and refuses a value that is not one address or that repeats the
   bootstrap recipient (var.alert_email).
3. alert_recipients.tf: the CIS task role's DenyUnsubscribeBootstrap statement names the second subscription too, so
   the app (or a compromised task) cannot silence it; while it is unset the statement still names the bootstrap only.
4. The bootstrap subscription itself is untouched.
5. The recipient never enters a committed file (this repo is public; the inbox gets every alarm): it is not set in
   accounts/aa365/terraform.tfvars, the variable is sensitive, and the three Terraform workflows pass
   TF_VAR_alert_email_secondary to every aa365 plan from the repo secret ALERT_EMAIL_SECONDARY (an environment secret
   would not reach the drift and PR plan jobs, which run without an environment; a missing mapping makes those plans
   show the subscription being destroyed).

Run: python3 -m pytest -q tools/terraform/tests/test_aa1110_second_alert_channel.py
"""
import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[3]
AA365 = ROOT / "accounts" / "aa365"
OBS = (AA365 / "observability.tf").read_text(encoding="utf-8")
VARS = (AA365 / "variables.tf").read_text(encoding="utf-8")
RECIPIENTS = (AA365 / "alert_recipients.tf").read_text(encoding="utf-8")
WORKFLOWS = ROOT / ".github" / "workflows"


def _block(text: str, opener: str) -> str:
    m = re.search(rf"^{re.escape(opener)} \{{", text, re.M)
    assert m, f"{opener} not found"
    body = text[m.end():]
    end = re.search(r"^\}", body, re.M)
    return body[: end.start()]


class SecondSubscriptionTest(unittest.TestCase):
    def setUp(self):
        self.sub = _block(OBS, 'resource "aws_sns_topic_subscription" "alerts_email_secondary"')

    def test_off_until_a_recipient_is_set(self):
        self.assertRegex(self.sub, r'count\s*=\s*nonsensitive\(var\.alert_email_secondary == ""\) \? 0 : 1')

    def test_email_to_the_alerts_topic(self):
        self.assertRegex(self.sub, r"topic_arn\s*=\s*aws_sns_topic\.alerts\.arn")
        self.assertRegex(self.sub, r'protocol\s*=\s*"email"')
        self.assertRegex(self.sub, r"endpoint\s*=\s*var\.alert_email_secondary")

    def test_bootstrap_unchanged(self):
        boot = _block(OBS, 'resource "aws_sns_topic_subscription" "alerts_email"')
        self.assertRegex(boot, r"endpoint\s*=\s*var\.alert_email\n")
        self.assertNotIn("count", boot)


class SecondRecipientVariableTest(unittest.TestCase):
    def setUp(self):
        self.var = _block(VARS, 'variable "alert_email_secondary"')

    def test_default_is_off(self):
        self.assertRegex(self.var, r'default\s*=\s*""')

    def test_validations(self):
        self.assertEqual(self.var.count("validation {"), 2)
        self.assertIn("lower(var.alert_email_secondary) != lower(var.alert_email)", self.var)
        self.assertIn('can(regex("^[^@[:space:]]+@', self.var)

    def test_sensitive(self):
        self.assertRegex(self.var, r"sensitive\s*=\s*true")

    def test_not_set_in_any_tracked_tfvars(self):
        # The recipient comes from the repo secret only; a committed value would publish the inbox.
        for path in AA365.glob("*.tfvars"):
            text = path.read_text(encoding="utf-8")
            self.assertIsNone(re.search(r"^\s*alert_email_secondary\s*=", text, re.M), path.name)


def _env_values(node) -> list:
    out = []
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "env" and isinstance(v, dict):
                out.append(v)
            out.extend(_env_values(v))
    elif isinstance(node, list):
        for v in node:
            out.extend(_env_values(v))
    return out


# AA-1182: TF_VAR_db_password is gone (RDS manages the master password). An aa365 plan env is any env block that sets
# one of the aa365-only variables; every such block must carry each of them (asserted per variable below).
AA365_PLAN_VARS = {"TF_VAR_org_management_account_id", "TF_VAR_bedrock_acct_payer_id", "TF_VAR_alert_email_secondary"}


class WorkflowWiringTest(unittest.TestCase):
    def test_every_aa365_plan_gets_the_recipient_from_the_repo_secret(self):
        for name in ("terraform-plan.yml", "terraform-apply.yml", "terraform-drift.yml"):
            envs = _env_values(yaml.safe_load((WORKFLOWS / name).read_text(encoding="utf-8")))
            aa365_envs = [e for e in envs if AA365_PLAN_VARS & set(e)]
            self.assertTrue(aa365_envs, name)
            for env in aa365_envs:
                value = str(env.get("TF_VAR_alert_email_secondary", ""))
                self.assertIn("secrets.ALERT_EMAIL_SECONDARY", value, name)
                self.assertNotIn("vars.", value, name)


class DenyUnsubscribeTest(unittest.TestCase):
    def test_deny_names_both_terraform_subscriptions(self):
        m = re.search(r'sid\s*=\s*"DenyUnsubscribeBootstrap"(.*?)\n  \}', RECIPIENTS, re.S)
        self.assertIsNotNone(m)
        stmt = m.group(1)
        self.assertRegex(stmt, r'effect\s*=\s*"Deny"')
        self.assertIn(
            "concat([aws_sns_topic_subscription.alerts_email.arn], "
            "aws_sns_topic_subscription.alerts_email_secondary[*].arn)",
            stmt,
        )


if __name__ == "__main__":
    unittest.main()
