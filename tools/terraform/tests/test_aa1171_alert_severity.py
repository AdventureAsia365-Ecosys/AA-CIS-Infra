"""AA-1171 (S287 alerts catalogue P0): offline guards for severity, the page topic and the coverage alarms.

1. alert_severity.tf: the page topic exists with a policy that admits the page-severity EventBridge rules; every
   page-severity rule of this root that notifies the alerts topic also has a page target (local.page_event_targets);
   the module's two CRM KMS rules have theirs (crm_kms_page).
2. The new alarms exist with their thresholds as variables: the alerts topic delivery-failure watchdog (page, locked),
   the CIS worker liveness (missing data breaches), the CIS and Booking API 5xx rate, the Booking worker liveness (a log
   metric filter on the job checks sampler line).
3. The CIS task role reads tags and rules (tag:GetResources, events:ListRules, ListTagsForResource, ListTargetsByRule)
   and never gets a write on alarms or tags (no PutMetricAlarm, no TagResource: the Mutable tag must stay out of the
   app's reach).
4. The alert recipients grant covers both topics; Publish stays on the alerts topic.
5. The CIS api/worker get PAGE_TOPIC_ARN and AWS_MGMT_ACCOUNT_ID (no account ID committed).

Run: python3 -m pytest -q tools/terraform/tests/test_aa1171_alert_severity.py
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
AA365 = ROOT / "accounts" / "aa365"
MOD = ROOT / "modules" / "environment"
SEV = (AA365 / "alert_severity.tf").read_text(encoding="utf-8")
RECIPIENTS = (AA365 / "alert_recipients.tf").read_text(encoding="utf-8")
ECS = (ROOT / "modules" / "ecs" / "main.tf").read_text(encoding="utf-8")
MAIN = (AA365 / "main.tf").read_text(encoding="utf-8")
BK = (MOD / "booking_alarms.tf").read_text(encoding="utf-8")
CRM_DATA = (MOD / "crm_data.tf").read_text(encoding="utf-8")
BK_BANK = (MOD / "booking_supplier_bank.tf").read_text(encoding="utf-8")


def _block(text: str, opener: str) -> str:
    m = re.search(rf"^{re.escape(opener)} \{{", text, re.M)
    assert m, f"{opener} not found"
    body = text[m.end():]
    end = re.search(r"^\}", body, re.M)
    return body[: end.start()]


def _all_root_tf() -> str:
    return "\n".join(p.read_text(encoding="utf-8") for p in sorted(AA365.glob("*.tf")))


class PageTopicTest(unittest.TestCase):
    def test_topic_and_policy(self):
        topic = _block(SEV, 'resource "aws_sns_topic" "page"')
        self.assertIn('name = "aa-ecosys-${var.environment}-page-alerts"', topic)
        self.assertIn('Component = "observability"', topic)
        policy = _block(SEV, 'data "aws_iam_policy_document" "page_topic"')
        self.assertIn('identifiers = ["events.amazonaws.com"]', policy)
        for prefix in ("local.id_prefix", "local.crm_name_prefix", "local.sec_prefix"):
            self.assertIn(prefix, policy)
        self.assertNotIn("budgets.amazonaws.com", policy)  # budgets stay ticket severity

    def test_page_actions_notify_both_topics(self):
        self.assertRegex(SEV, r"page\s*=\s*\[aws_sns_topic\.alerts\.arn, aws_sns_topic\.page\.arn\]")
        self.assertRegex(SEV, r"ticket\s*=\s*\[aws_sns_topic\.alerts\.arn\]")

    def test_every_page_rule_with_an_alerts_target_gets_a_page_target(self):
        text = _all_root_tf()
        rule_sev = {}
        for m in re.finditer(r'^resource "aws_cloudwatch_event_rule" "([^"]+)" \{', text, re.M):
            block = _block(text[m.start():], f'resource "aws_cloudwatch_event_rule" "{m.group(1)}"')
            tags = re.search(r"^\s*tags\s*=\s*(.*)$", block, re.M)
            rule_sev[m.group(1)] = bool(tags and "alert_tags.page" in tags.group(1))
        targets = {}
        for m in re.finditer(r'^resource "aws_cloudwatch_event_target" "([^"]+)" \{', text, re.M):
            block = _block(text[m.start():], f'resource "aws_cloudwatch_event_target" "{m.group(1)}"')
            rule = re.search(r"aws_cloudwatch_event_rule\.([a-z0-9_]+)", block)
            if rule and "aws_sns_topic.alerts.arn" in block:
                targets[m.group(1)] = rule.group(1)
        page_map = _block(SEV, "locals")
        missing = [t for t, r in targets.items() if rule_sev.get(r) and f"aws_cloudwatch_event_target.{t}" not in page_map]
        self.assertEqual(missing, [], "page-severity rules without a page target in local.page_event_targets")
        page_target = _block(SEV, 'resource "aws_cloudwatch_event_target" "page"')
        self.assertIn("arn       = aws_sns_topic.page.arn", page_target)
        self.assertIn("each.value.input_transformer[0].input_template", page_target)

    def test_crm_kms_rules_page_target(self):
        target = _block(CRM_DATA, 'resource "aws_cloudwatch_event_target" "crm_kms_page"')
        self.assertIn("aws_cloudwatch_event_target.crm_kms_key_admin", target)
        self.assertIn("aws_cloudwatch_event_target.crm_kms_foreign_use", target)
        self.assertIn("arn       = var.page_topic_arn", target)

    def test_booking_kms_rules_page_target(self):
        # AA-1158 (S294): the Booking supplier bank key rules, same shape as the CRM ones (named aa-sec-<env>-booking-*,
        # so the page policy's rule/${local.sec_prefix}-* admits them).
        target = _block(BK_BANK, 'resource "aws_cloudwatch_event_target" "booking_kms_page"')
        self.assertIn("aws_cloudwatch_event_target.booking_kms_key_admin", target)
        self.assertIn("aws_cloudwatch_event_target.booking_kms_foreign_use", target)
        self.assertIn("arn       = var.page_topic_arn", target)


class CoverageAlarmsTest(unittest.TestCase):
    def test_delivery_failed_watchdog(self):
        a = _block(SEV, 'resource "aws_cloudwatch_metric_alarm" "alerts_notifications_failed"')
        self.assertIn('metric_name         = "NumberOfNotificationsFailed"', a)
        self.assertIn("TopicName = aws_sns_topic.alerts.name", a)
        self.assertIn("threshold           = var.alerts_delivery_failed_threshold", a)
        self.assertIn("local.alert_tags.page_locked", a)
        self.assertIn("alarm_actions       = local.alert_actions.page", a)

    def test_cis_worker_liveness_breaches_on_missing_data(self):
        a = _block(SEV, 'resource "aws_cloudwatch_metric_alarm" "cis_worker_no_running_task"')
        self.assertIn('namespace           = "AWS/ECS"', a)
        self.assertIn("ServiceName = module.ecs.worker_service_name", a)
        self.assertIn('treat_missing_data  = "breaching"', a)
        self.assertIn("var.cis_worker_liveness.periods", a)

    def test_api_5xx_rate_alarms_use_the_variable(self):
        for text, name in ((SEV, "cis_api_5xx_rate"), (BK, "booking_api_5xx_rate")):
            a = _block(text, f'resource "aws_cloudwatch_metric_alarm" "{name}"')
            self.assertIn("threshold           = var.api_5xx_rate.five_xx_percent", a)
            self.assertIn("var.api_5xx_rate.min_requests", a)
            self.assertIn('metric_name = "HTTPCode_Target_5XX_Count"', a)
            self.assertIn("alert_tags.ticket", a)

    def test_booking_worker_liveness_counts_the_sampler_line(self):
        f = _block(BK, 'resource "aws_cloudwatch_log_metric_filter" "booking_job_checks_sampled"')
        self.assertIn('pattern        = "\\"ops_metrics_sampled\\""', f)
        self.assertIn("aws_cloudwatch_log_group.booking.name", f)
        a = _block(BK, 'resource "aws_cloudwatch_metric_alarm" "booking_worker_silent"')
        self.assertIn('treat_missing_data  = "breaching"', a)
        self.assertIn("var.booking_worker_liveness.periods", a)

    def test_costs_are_stated(self):
        self.assertIn("Total 0.70 USD/month", SEV)


class CisReadGrantTest(unittest.TestCase):
    def test_read_only_catalogue_grants(self):
        self.assertIn('Action   = ["tag:GetResources", "events:ListRules"]', ECS)
        self.assertIn('"cloudwatch:ListTagsForResource", "events:ListTargetsByRule", "events:ListTagsForResource"', ECS)

    def test_no_alarm_or_tag_write_for_the_task_role(self):
        for verb in ("cloudwatch:PutMetricAlarm", "cloudwatch:TagResource", "cloudwatch:DeleteAlarms",
                     "cloudwatch:DisableAlarmActions", "tag:TagResources", "events:PutRule"):
            self.assertNotIn(f'"{verb}"', ECS)

    def test_env(self):
        self.assertIn('{ name = "PAGE_TOPIC_ARN", value = var.page_topic_arn }', ECS)
        self.assertIn('{ name = "AWS_MGMT_ACCOUNT_ID", value = var.mgmt_account_id }', ECS)
        self.assertIn("page_topic_arn = aws_sns_topic.page.arn", MAIN)
        self.assertNotRegex(MAIN, r"mgmt_account_id\s*=\s*\"[0-9]{12}\"")


class RecipientsGrantTest(unittest.TestCase):
    def test_both_topics(self):
        self.assertIn("recipient_topic_arns = [aws_sns_topic.alerts.arn, aws_sns_topic.page.arn]", RECIPIENTS)
        sub = re.search(r'sid\s*=\s*"AlertsTopicSubscribeEmail".*?resources\s*=\s*(\S+)', RECIPIENTS, re.S).group(1)
        self.assertEqual(sub, "local.recipient_topic_arns")
        pub = re.search(r'sid\s*=\s*"AlertsTopicPublishOpsChecks".*?resources\s*=\s*(\[[^\]]*\])', RECIPIENTS, re.S)
        self.assertEqual(pub.group(1), "[aws_sns_topic.alerts.arn]")


if __name__ == "__main__":
    unittest.main()
