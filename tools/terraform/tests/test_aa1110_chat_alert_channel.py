"""AA-1110 (S297): offline guards for the Slack chat alert channel (accounts/aa365/chat_alerts.tf).

1. Off by default: var.chat_alerts_enabled defaults to false and every resource of the file has count on it, so the
   default plan creates nothing (no role, no configuration, no SNS subscription, nothing to pay or confirm).
2. The Slack IDs never enter a committed file (public repo): both variables are sensitive, default "", are not set
   in any tracked tfvars, and the three Terraform workflows pass them to every aa365 plan from repo secrets only.
3. The switch cannot be half on: the ID variables refuse "" while the switch is true.
4. Least privilege: the channel role trusts chatbot.amazonaws.com only, carries the workload boundary, reads
   CloudWatch only; the guardrail is CloudWatchReadOnlyAccess (never AdministratorAccess, never Amazon Q access);
   user roles are off; the topic is one of the two alert topics.
5. Region: the configuration uses the us-west-2 provider (the chatbot API does not run in us-west-1).
6. The apply role's chatbot grants live in the customer managed tf_apply_sec policy (bootstrap), writes scoped to
   this stack's configuration names, and no Slack workspace authorisation verb.
7. The trust inventory knows the chatbot service principal.

Run: python3 -m pytest -q tools/terraform/tests/test_aa1110_chat_alert_channel.py
"""
import json
import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[3]
AA365 = ROOT / "accounts" / "aa365"
CHAT = (AA365 / "chat_alerts.tf").read_text(encoding="utf-8")
VARS = (AA365 / "variables.tf").read_text(encoding="utf-8")
SEC = (AA365 / "cicd_sec.tf").read_text(encoding="utf-8")
WORKFLOWS = ROOT / ".github" / "workflows"
ALLOWLIST = ROOT / "tools" / "terraform" / "iam_trust_allowlist.json"


def _block(text: str, opener: str) -> str:
    m = re.search(rf"^{re.escape(opener)} \{{", text, re.M)
    assert m, f"{opener} not found"
    body = text[m.end():]
    end = re.search(r"^\}", body, re.M)
    return body[: end.start()]


def _statement(text: str, sid: str) -> str:
    m = re.search(rf'sid\s*=\s*"{sid}"(.*?)\n  \}}', text, re.S)
    assert m, f"statement {sid} not found"
    return m.group(1)


class OffByDefaultTest(unittest.TestCase):
    def test_switch_defaults_to_false(self):
        var = _block(VARS, 'variable "chat_alerts_enabled"')
        self.assertRegex(var, r"type\s*=\s*bool")
        self.assertRegex(var, r"default\s*=\s*false")

    def test_every_resource_counts_on_the_switch(self):
        resources = re.findall(r'^resource "([a-z0-9_]+)" "([a-z0-9_]+)" \{', CHAT, re.M)
        self.assertEqual(
            sorted(resources),
            sorted([
                ("aws_iam_role", "chat_alerts"),
                ("aws_iam_role_policy", "chat_alerts"),
                ("aws_chatbot_slack_channel_configuration", "alerts"),
            ]),
        )
        for rtype, name in resources:
            body = _block(CHAT, f'resource "{rtype}" "{name}"')
            self.assertRegex(body, r"count\s*=\s*var\.chat_alerts_enabled \? 1 : 0", f"{rtype}.{name}")

    def test_not_switched_on_in_tfvars_by_this_change(self):
        # Turning it on is a separate, reviewed PR after the hand steps (root runbook chat-alert-channel.md).
        text = (AA365 / "terraform.tfvars").read_text(encoding="utf-8")
        self.assertIsNone(re.search(r"^\s*chat_alerts_enabled\s*=\s*true", text, re.M))


class SlackIdsTest(unittest.TestCase):
    NAMES = ("chat_alerts_slack_team_id", "chat_alerts_slack_channel_id")

    def test_sensitive_empty_default_and_refused_empty_when_on(self):
        for name in self.NAMES:
            var = _block(VARS, f'variable "{name}"')
            self.assertRegex(var, r'default\s*=\s*""', name)
            self.assertRegex(var, r"sensitive\s*=\s*true", name)
            self.assertIn(f"!var.chat_alerts_enabled || can(regex(", var, name)
            self.assertIn(f"var.{name}))", var, name)

    def test_never_in_a_tracked_tfvars(self):
        for path in AA365.glob("*.tfvars"):
            text = path.read_text(encoding="utf-8")
            for name in self.NAMES:
                self.assertIsNone(re.search(rf"^\s*{name}\s*=", text, re.M), f"{path.name}: {name}")

    def test_every_aa365_plan_gets_them_from_repo_secrets(self):
        secrets = {
            "TF_VAR_chat_alerts_slack_team_id": "secrets.CHAT_ALERTS_SLACK_TEAM_ID",
            "TF_VAR_chat_alerts_slack_channel_id": "secrets.CHAT_ALERTS_SLACK_CHANNEL_ID",
        }
        for name in ("terraform-plan.yml", "terraform-apply.yml", "terraform-drift.yml"):
            envs = _env_values(yaml.safe_load((WORKFLOWS / name).read_text(encoding="utf-8")))
            with_db = [e for e in envs if "TF_VAR_db_password" in e]
            self.assertTrue(with_db, name)
            for env in with_db:
                for key, secret in secrets.items():
                    value = str(env.get(key, ""))
                    self.assertIn(secret, value, f"{name}: {key}")
                    self.assertNotIn("vars.", value, f"{name}: {key}")

    def test_topic_choice_is_closed(self):
        var = _block(VARS, 'variable "chat_alerts_topic"')
        self.assertRegex(var, r'default\s*=\s*"all"')
        self.assertIn('contains(["all", "page"], var.chat_alerts_topic)', var)


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


class LeastPrivilegeTest(unittest.TestCase):
    def test_trust_is_the_chatbot_service_only(self):
        trust = _block(CHAT, 'data "aws_iam_policy_document" "chat_alerts_trust"')
        self.assertEqual(re.findall(r'identifiers\s*=\s*\[([^\]]*)\]', trust), ['"chatbot.amazonaws.com"'])
        self.assertRegex(trust, r'type\s*=\s*"Service"')

    def test_role_has_the_workload_boundary(self):
        role = _block(CHAT, 'resource "aws_iam_role" "chat_alerts"')
        self.assertRegex(role, r"permissions_boundary\s*=\s*aws_iam_policy\.workload_boundary\.arn")
        self.assertIn("local.chat_alerts_name", role)
        self.assertRegex(CHAT, r'chat_alerts_name\s*=\s*"aa-ecosys-\$\{var\.environment\}-chat-alerts"')

    def test_role_policy_reads_cloudwatch_only(self):
        policy = _block(CHAT, 'resource "aws_iam_role_policy" "chat_alerts"')
        actions = re.findall(r'"([a-z0-9-]+:[A-Za-z*]+)"', policy)
        self.assertTrue(actions)
        for action in actions:
            self.assertTrue(action.startswith("cloudwatch:"), action)
            self.assertRegex(action, r":(Describe|Get|List)\*$")

    def test_configuration_guardrail_topics_and_region(self):
        cfg = _block(CHAT, 'resource "aws_chatbot_slack_channel_configuration" "alerts"')
        self.assertRegex(cfg, r"provider\s*=\s*aws\.us_west_2")
        self.assertIn('guardrail_policy_arns       = ["arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"]', cfg)
        self.assertNotIn("AdministratorAccess", CHAT.split("# ====", 2)[-1])
        self.assertNotIn("AmazonQDeveloperAccess", cfg)
        self.assertRegex(cfg, r"user_authorization_required\s*=\s*false")
        self.assertRegex(cfg, r"sns_topic_arns\s*=\s*local\.chat_alerts_topic_arns\[var\.chat_alerts_topic\]")
        self.assertRegex(cfg, r"slack_team_id\s*=\s*var\.chat_alerts_slack_team_id")
        self.assertRegex(cfg, r"slack_channel_id\s*=\s*var\.chat_alerts_slack_channel_id")
        topics = _block(CHAT, "locals")
        self.assertIn("all  = [aws_sns_topic.alerts.arn]", topics)
        self.assertIn("page = [aws_sns_topic.page.arn]", topics)

    def test_tagged_per_the_tagging_standard(self):
        for rtype, name in (("aws_iam_role", "chat_alerts"), ("aws_chatbot_slack_channel_configuration", "alerts")):
            body = _block(CHAT, f'resource "{rtype}" "{name}"')
            self.assertIn('merge(local.shared_tags, { Issue = "AA-1110", Component = "observability" })', body)


class ApplyRoleGrantTest(unittest.TestCase):
    def test_create_and_reads(self):
        stmt = _statement(SEC, "ChatAlertsConfigCreate")
        for action in ("CreateSlackChannelConfiguration", "DescribeSlackChannelConfigurations", "ListTagsForResource"):
            self.assertIn(f'"chatbot:{action}"', stmt)

    def test_writes_scoped_to_this_stack(self):
        stmt = _statement(SEC, "ChatAlertsConfigManage")
        self.assertIn(
            'resources = ["arn:aws:chatbot::${var.account_id}:chat-configuration/slack-channel/aa-ecosys-*"]', stmt
        )
        self.assertNotIn('"*"', stmt)

    def test_service_linked_role_for_chatbot_only(self):
        # The first CreateSlackChannelConfiguration creates AWSServiceRoleForAWSChatbot with the caller's rights.
        stmt = _statement(SEC, "ChatAlertsServiceLinkedRole")
        self.assertIn('actions   = ["iam:CreateServiceLinkedRole"]', stmt)
        self.assertIn(
            'resources = ["arn:aws:iam::${var.account_id}:role/aws-service-role/management.chatbot.amazonaws.com/*"]',
            stmt,
        )
        self.assertIn('variable = "iam:AWSServiceName"', stmt)
        self.assertIn('values   = ["management.chatbot.amazonaws.com"]', stmt)
        self.assertNotIn('"*"', stmt)

    def test_no_workspace_authorisation_verbs(self):
        for verb in ("RedeemSlackOauthCode", "GetSlackOauthParameters", "DeleteSlackWorkspaceAuthorization", "chatbot:*"):
            self.assertNotIn(verb, SEC)


class TrustInventoryTest(unittest.TestCase):
    def test_chatbot_service_is_known(self):
        data = json.loads(ALLOWLIST.read_text(encoding="utf-8"))
        self.assertIn("chatbot.amazonaws.com", data["services"])


if __name__ == "__main__":
    unittest.main()
