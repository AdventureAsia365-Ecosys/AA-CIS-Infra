"""AA-1183 part 1 (S296): offline guards for the ACM certificate expiry alert (security_baseline.tf section 5).

1. A rule aa-sec-<env>-acm-expiry in the root region notifies the alerts topic (runbook certificate-expiry, severity
   ticket); a rule aa-sec-<env>-acm-expiry-forward in us-east-1 forwards to the root region's default bus through the
   existing forwarder role. Both use one pattern (local.acm_expiry_pattern).
2. The aa-sec-* prefix is what the CI apply grant (every region) and the alerts topic policy admit: no IAM change.
3. The pattern, evaluated offline: approaching-expiration events alert only on var.acm_expiry_alert_days, renewal
   action required and expired always, nothing else; the live check tool's acm cases agree with it.
4. The alert days are a validated Terraform variable whose default the live check tool mirrors.

Run: python3 -m pytest -q tools/terraform/tests/test_aa1183_acm_expiry.py
"""

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "terraform"))

import sec_alert_check as chk  # noqa: E402

AA365 = ROOT / "accounts" / "aa365"
BASELINE = (AA365 / "security_baseline.tf").read_text(encoding="utf-8")
SECTION = BASELINE.split("# ── 5. ACM certificate expiry", 1)[1]
VARS = (AA365 / "variables.tf").read_text(encoding="utf-8")
RUNBOOKS = (AA365 / "alarm_runbooks.tf").read_text(encoding="utf-8")
SEC = (AA365 / "cicd_sec.tf").read_text(encoding="utf-8")
ALERTS = (AA365 / "identity_alerts.tf").read_text(encoding="utf-8")


def _block(opener: str) -> str:
    m = re.search(rf"^{re.escape(opener)} \{{", SECTION, re.M)
    assert m, f"{opener} not found"
    body = SECTION[m.end():]
    return body[: re.search(r"^\}", body, re.M).start()]


def _default_days() -> list[int]:
    block = VARS.split('variable "acm_expiry_alert_days" {', 1)[1].split("\n}\n", 1)[0]
    return [int(x) for x in re.search(r"default\s*=\s*\[([^\]]*)\]", block).group(1).split(",")]


def _pattern() -> dict:
    """local.acm_expiry_pattern as EventBridge sees it, rebuilt from the HCL (detail-types) and the default days."""
    local = SECTION.split("acm_expiry_pattern = jsonencode({", 1)[1].split("\n  })", 1)[0]
    approaching, others = re.findall(r'"detail-type" = \[([^\]]*)\]', local)
    names = lambda s: re.findall(r'"([^"]+)"', s)  # noqa: E731
    assert 'source = ["aws.acm"]' in local
    assert "{ numeric = [\"=\", d] }" in local and "var.acm_expiry_alert_days" in local
    return {
        "source": ["aws.acm"],
        "$or": [
            {"detail-type": names(approaching),
             "detail": {"DaysToExpiry": [{"numeric": ["=", d]} for d in _default_days()]}},
            {"detail-type": names(others)},
        ],
    }


def _leaf(rules, value) -> bool:
    for r in rules:
        if isinstance(r, dict) and "numeric" in r:
            op, n = r["numeric"]
            assert op == "="
            if isinstance(value, (int, float)) and value == n:
                return True
        elif r == value:
            return True
    return False


def matches(pattern: dict, event: dict) -> bool:
    """Enough of the EventBridge matcher for this pattern: exact strings, numeric '=', '$or', nested objects."""
    for k, rule in pattern.items():
        if k == "$or":
            if not any(matches(alt, event) for alt in rule):
                return False
        elif isinstance(rule, dict):
            if not isinstance(event.get(k), dict) or not matches(rule, event[k]):
                return False
        elif k not in event or not _leaf(rule, event[k]):
            return False
    return True


class RulesTest(unittest.TestCase):
    def test_local_rule_alerts_the_topic_with_a_runbook(self):
        rule = _block('resource "aws_cloudwatch_event_rule" "sec_acm_expiry"')
        self.assertIn('name          = "${local.sec_prefix}-acm-expiry"', rule)
        self.assertIn("event_pattern = local.acm_expiry_pattern", rule)
        self.assertIn("${local.runbook_suffix.cert_expiry}", rule)
        self.assertIn("local.alert_tags.ticket", rule)
        self.assertNotIn("provider", rule)
        target = _block('resource "aws_cloudwatch_event_target" "sec_acm_expiry"')
        self.assertIn("rule      = aws_cloudwatch_event_rule.sec_acm_expiry.name", target)
        self.assertIn("arn       = aws_sns_topic.alerts.arn", target)
        self.assertIn("${local.runbook_suffix.cert_expiry}", target)
        self.assertIn('"\\"[aa-sec] acm_expiry: ', target)
        for path in ('"$.detail.CommonName"', '"$.detail.DaysToExpiry"', '"$.resources[0]"', '"$.region"'):
            self.assertIn(path, target)

    def test_forward_rule_in_us_east_1_to_the_default_bus(self):
        rule = _block('resource "aws_cloudwatch_event_rule" "sec_acm_expiry_forward"')
        self.assertIn("provider      = aws.us_east_1", rule)
        self.assertIn('name          = "${local.sec_prefix}-acm-expiry-forward"', rule)
        self.assertIn("event_pattern = local.acm_expiry_pattern", rule)
        target = _block('resource "aws_cloudwatch_event_target" "sec_acm_expiry_forward"')
        self.assertIn("provider  = aws.us_east_1", target)
        self.assertIn('arn       = "arn:aws:events:${var.aws_region}:${var.account_id}:event-bus/default"', target)
        self.assertIn("role_arn  = aws_iam_role.sec_forwarder.arn", target)

    def test_runbook_key(self):
        self.assertIn('cert_expiry    = "${local.runbook_base_url}/runbooks/certificate-expiry.md"', RUNBOOKS)

    def test_existing_grants_admit_the_rules(self):
        # The CI apply role may manage aa-sec-* rules in every region; the alerts topic admits aa-sec-* rules.
        self.assertIn('resources = ["arn:aws:events:*:${var.account_id}:rule/aa-sec-*"]', SEC)
        self.assertIn('"arn:aws:events:${var.aws_region}:${var.account_id}:rule/${local.sec_prefix}-*"', ALERTS)
        forwarder = BASELINE.split('resource "aws_iam_role_policy" "sec_forwarder"', 1)[1].split("\nresource ", 1)[0]
        self.assertIn('"arn:aws:events:${var.aws_region}:${var.account_id}:event-bus/default"', forwarder)

    def test_cost_is_stated(self):
        self.assertIn("Cost: 0 USD/month", SECTION)


class PatternTest(unittest.TestCase):
    def test_variable_default_and_validation(self):
        self.assertEqual(_default_days(), [30, 14, 7, 3, 1])
        self.assertEqual(tuple(_default_days()), chk.ACM_ALERT_DAYS)
        block = VARS.split('variable "acm_expiry_alert_days" {', 1)[1].split("\n}\n", 1)[0]
        self.assertIn("type        = list(number)", block)
        self.assertIn("d >= 1 && d <= 30", block)

    def test_live_check_cases_match_the_pattern(self):
        pattern = _pattern()
        cases = chk.acm_cases("000000000000", "us-west-1", "dev")
        self.assertEqual({c[1] for c in cases}, {"aa-sec-dev-acm-expiry", "aa-sec-dev-acm-expiry-forward"})
        self.assertEqual({c[4] for c in cases}, {True, False})
        for cid, _rule, _region, event, expected in cases:
            with self.subTest(case=cid):
                self.assertIs(matches(pattern, event), expected)

    def test_other_sources_never_match(self):
        ev = chk.acm_event("000000000000", "us-west-1", "ACM Certificate Approaching Expiration", 30)
        ev["source"] = "aws.health"
        self.assertFalse(matches(_pattern(), ev))

    def test_cases_are_in_the_live_check_run(self):
        ids = {c[0] for c in chk.cases("000000000000", "us-west-1", "dev")}
        self.assertIn("acm.approaching.30", ids)
        self.assertIn("acm-forward.expired", ids)


if __name__ == "__main__":
    unittest.main()
