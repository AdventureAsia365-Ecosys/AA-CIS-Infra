"""AA-1025 (S263 alert diet): offline guards for the alarms the diet must keep.

1. NAT guest OS failure (observability_ecosys.tf): an alarm on StatusCheckFailed_Instance of the NAT instance, ALARM
   and OK e-mails, no EC2 action (recover does not fix a guest OS failure). Nothing else sees it: the ALB health
   checks stay inside the VPC and the in-app checks publish to SNS through that NAT.
2. Identity trigger unexpected errors (identity.tf): one log metric filter per trigger and one alarm at threshold 1,
   ALARM only. The Errors alarm has a burst threshold a low-traffic Dev never reaches.
3. Event metric filters in AA/Identity have no default_value (billed only in hours with an event).
4. RDS down, stopped, failed or low on storage (observability_ecosys.tf, review pass): an EventBridge rule on the RDS
   instance events of the shared database mails the alerts topic. The kept RDS alarms treat missing data as not
   breaching and every in-app check needs the database, so nothing else e-mails when it is down. The rule name must
   stay under rule/aa-sec-*, the prefix the topic policy and the CI apply role already allow.

Run: python3 -m pytest -q tools/terraform/tests/test_aa1025_alert_diet.py
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
AA365 = ROOT / "accounts" / "aa365"
OBS = (AA365 / "observability_ecosys.tf").read_text(encoding="utf-8")
IDENTITY = (AA365 / "identity.tf").read_text(encoding="utf-8")
ALERTS_POLICY = (AA365 / "identity_alerts.tf").read_text(encoding="utf-8")
CICD_SEC = (AA365 / "cicd_sec.tf").read_text(encoding="utf-8")


def _resource(text: str, kind: str, name: str) -> str:
    m = re.search(rf'^resource "{kind}" "{name}" \{{', text, re.M)
    assert m, f"{kind}.{name} not found"
    body = text[m.end():]
    end = re.search(r"^\}", body, re.M)
    return body[: end.start()]


class NatInstanceCheckAlarmTest(unittest.TestCase):
    def setUp(self):
        self.alarm = _resource(OBS, "aws_cloudwatch_metric_alarm", "nat_instance_check_failed")

    def test_instance_check_on_the_nat(self):
        self.assertIn('namespace           = "AWS/EC2"', self.alarm)
        # The Instance metric, not the combined StatusCheckFailed: a system failure mails once (recover alarm).
        self.assertIn('metric_name         = "StatusCheckFailed_Instance"', self.alarm)
        self.assertIn("InstanceId = module.vpc.nat_instance_id", self.alarm)
        self.assertIn('treat_missing_data  = "notBreaching"', self.alarm)

    def test_state_alarm_mails_alarm_and_ok_without_ec2_action(self):
        self.assertRegex(self.alarm, r"alarm_actions\s*=\s*\[aws_sns_topic\.alerts\.arn\]")
        self.assertRegex(self.alarm, r"ok_actions\s*=\s*\[aws_sns_topic\.alerts\.arn\]")
        self.assertNotIn("arn:aws:automate", self.alarm)


class IdentityUnexpectedErrorAlarmTest(unittest.TestCase):
    def setUp(self):
        self.filter = _resource(IDENTITY, "aws_cloudwatch_log_metric_filter", "identity_trigger_unexpected")
        self.alarm = _resource(IDENTITY, "aws_cloudwatch_metric_alarm", "identity_trigger_unexpected")

    def test_filter_per_trigger(self):
        self.assertIn("for_each       = local.id_triggers", self.filter)
        self.assertIn('pattern        = "{ $.event = \\"*_error\\" }"', self.filter)
        self.assertIn('name      = "TriggerUnexpectedError"', self.filter)

    def test_one_error_is_enough_and_mails_on_alarm_only(self):
        self.assertIn('metric_name         = "TriggerUnexpectedError"', self.alarm)
        self.assertIn("threshold           = 1", self.alarm)
        self.assertRegex(self.alarm, r"alarm_actions\s*=\s*\[aws_sns_topic\.alerts\.arn\]")
        self.assertNotIn("ok_actions", self.alarm)

    def test_identity_event_metrics_have_no_default_value(self):
        for name in ("identity_trigger_unexpected", "identity_breakglass"):
            with self.subTest(filter=name):
                body = _resource(IDENTITY, "aws_cloudwatch_log_metric_filter", name)
                self.assertNotIn("default_value", body)


class RdsInstanceEventRuleTest(unittest.TestCase):
    def setUp(self):
        self.rule = _resource(OBS, "aws_cloudwatch_event_rule", "rds_instance_event")
        self.target = _resource(OBS, "aws_cloudwatch_event_target", "rds_instance_event")

    def test_rds_instance_events_of_the_shared_database(self):
        self.assertIn('source        = ["aws.rds"]', self.rule)
        self.assertIn('"detail-type" = ["RDS DB Instance Event"]', self.rule)
        self.assertIn("SourceIdentifier = [module.rds.db_identifier]", self.rule)
        for category in ("availability", "failure", "low storage", "recovery"):
            with self.subTest(category=category):
                self.assertIn(f'"{category}"', self.rule)
        for event_id in ("RDS-EVENT-0087", "RDS-EVENT-0088", "RDS-EVENT-0154"):  # stopped, started, auto-started
            with self.subTest(event_id=event_id):
                self.assertIn(f'"{event_id}"', self.rule)
        self.assertIn("local.runbook_suffix.database", self.rule)

    def test_name_stays_inside_the_granted_prefix(self):
        self.assertIn('name        = "${local.sec_prefix}-rds-instance-event"', self.rule)
        self.assertIn("rule/${local.sec_prefix}-*", ALERTS_POLICY)  # topic policy AllowSecurityEventBridgeRules
        self.assertIn("rule/aa-sec-*", CICD_SEC)  # apply role SecEventRuleManage

    def test_target_is_the_alerts_topic(self):
        self.assertIn("rule      = aws_cloudwatch_event_rule.rds_instance_event.name", self.target)
        self.assertIn("arn       = aws_sns_topic.alerts.arn", self.target)
        self.assertIn('event = "$.detail.EventID"', self.target)


if __name__ == "__main__":
    unittest.main()
