"""AA-1025 (S263 alert diet): offline guards for the alarms the diet must keep.

1. NAT guest OS failure (observability_ecosys.tf): an alarm on StatusCheckFailed_Instance of the NAT instance, ALARM
   and OK e-mails, no EC2 action (recover does not fix a guest OS failure). Nothing else sees it: the ALB health
   checks stay inside the VPC and the in-app checks publish to SNS through that NAT.
2. Identity trigger unexpected errors (identity.tf): one log metric filter per trigger and one alarm at threshold 1,
   ALARM only. The Errors alarm has a burst threshold a low-traffic Dev never reaches.
3. Event metric filters in AA/Identity have no default_value (billed only in hours with an event).

Run: python3 -m pytest -q tools/terraform/tests/test_aa1025_alert_diet.py
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
AA365 = ROOT / "accounts" / "aa365"
OBS = (AA365 / "observability_ecosys.tf").read_text(encoding="utf-8")
IDENTITY = (AA365 / "identity.tf").read_text(encoding="utf-8")


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


if __name__ == "__main__":
    unittest.main()
