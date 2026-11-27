"""AA-1185 (S295 audit SA-53): offline guards for the WORKFORCE admin-group and enable-user alerts.

Page severity means a person must act now (alert_severity.tf). CloudTrail records AdminEnableUser even on an enabled
user, and the CIS Staff page sends it on every Reset and Sync, so AdminEnableUser is a ticket-severity record in its own
rule; only AdminAddUserToGroup into an administrator group pages.

Run: python3 -m pytest -q tools/terraform/tests/test_aa1185_identity_alerts.py
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
AA365 = ROOT / "accounts" / "aa365"
ALERTS = (AA365 / "identity_alerts.tf").read_text(encoding="utf-8")
SEVERITY = (AA365 / "alert_severity.tf").read_text(encoding="utf-8")


def _resource(text: str, kind: str, name: str) -> str:
    m = re.search(rf'^resource "{kind}" "{name}" \{{', text, re.M)
    assert m, f"{kind}.{name} not found"
    body = text[m.end():]
    end = re.search(r"^\}", body, re.M)
    return body[: end.start()]


def _page_targets() -> str:
    start = SEVERITY.index("page_event_targets = merge(")
    return SEVERITY[start : SEVERITY.index("\n  )\n", start)]


def test_admin_group_rule_pages_only_on_admin_group_adds():
    rule = _resource(ALERTS, "aws_cloudwatch_event_rule", "identity_workforce_admin_membership")
    assert 'eventName         = ["AdminAddUserToGroup"]' in rule
    assert "groupName = local.id_admin_groups" in rule
    assert "AdminEnableUser" not in rule
    assert "$or" not in rule
    assert "local.alert_tags.page_locked" in rule
    assert "identity_workforce_admin_membership " in _page_targets()


def test_admin_groups_are_looked_up_from_the_pool_groups():
    groups = re.search(r"id_admin_groups = \[for g in \[(.*?)\]", ALERTS).group(1)
    assert set(re.findall(r'"([^"]+)"', groups)) == {"cis-admin", "booking-admin", "crm-platform-admin"}
    assert "aws_cognito_user_group.workforce[g].name" in ALERTS


def test_enable_user_is_a_ticket_record_never_a_page():
    rule = _resource(ALERTS, "aws_cloudwatch_event_rule", "identity_workforce_enable_user")
    assert 'eventName         = ["AdminEnableUser"]' in rule
    assert "userPoolId = [aws_cognito_user_pool.workforce.id]" in rule
    assert "local.alert_tags.ticket_locked" in rule
    # Rule name inside rule/aa-identity-* (alerts topic policy statement AllowIdentityEventBridgeRules).
    assert 'name        = "${local.id_prefix}-workforce-enable-user"' in rule
    assert "identity_workforce_enable_user" not in _page_targets()
    target = _resource(ALERTS, "aws_cloudwatch_event_target", "identity_workforce_enable_user")
    assert "arn       = aws_sns_topic.alerts.arn" in target
    assert "local.runbook_suffix.incident" in rule
