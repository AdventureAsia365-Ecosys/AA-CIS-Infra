"""Static tests of the per-App Cost Anomaly Detection monitors of the management root (AA-896, S262).

Offline: reads accounts/management/*.tf; no Terraform, no AWS. Run from the repo root:
python3 -m pytest -p no:cacheprovider -q tools/terraform/tests
"""
from __future__ import annotations

import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
MGMT = os.path.abspath(os.path.join(HERE, "..", "..", "..", "accounts", "management"))


def _read(name: str) -> str:
    with open(os.path.join(MGMT, name), encoding="utf-8") as fh:
        return fh.read()


def _block(text: str, kind: str, *names: str) -> str:
    head = f'{kind} ' + " ".join(f'"{n}"' for n in names) + " {"
    start = text.index(head)
    m = re.compile(r"\n(?:resource|data|output|variable|locals) ").search(text, start + 1)
    return text[start:] if m is None else text[start:m.start()]


def test_off_by_default():
    var = _block(_read("variables.tf"), "variable", "app_tag_anomaly_monitors_enabled")
    assert "default     = false" in var


def test_one_monitor_per_app_value_on_the_app_tag():
    mon = _block(_read("cost_anomaly_app_tag.tf"), "resource", "aws_ce_anomaly_monitor", "app_tag")
    assert "var.app_tag_anomaly_monitors_enabled ? toset(var.app_tag_values) : toset([])" in mon
    assert 'monitor_type = "CUSTOM"' in mon
    assert re.search(r'Key\s+=\s+"App"', mon)
    assert re.search(r"Values\s+=\s+\[each\.value\]", mon)
    # Every expression key spelled out, as budgets.tf does (a shorter document shows a permanent diff).
    for key in ("And", "CostCategories", "Dimensions", "Not", "Or", "ProductAttributes", "Tags"):
        assert re.search(rf"\n\s+{key}\s+=", mon), key


def test_default_values_are_the_app_tags_of_dm_10_1():
    var = _block(_read("variables.tf"), "variable", "app_tag_values")
    assert '["cis", "booking", "tripplanner", "crm", "identity", "shared"]' in var


def test_one_daily_email_subscription_same_recipients_and_threshold_as_budgets():
    sub = _block(_read("cost_anomaly_app_tag.tf"), "resource", "aws_ce_anomaly_subscription", "app_tag")
    assert "count = var.app_tag_anomaly_monitors_enabled ? 1 : 0" in sub
    assert 'frequency        = "DAILY"' in sub
    assert "toset(var.budget_alert_emails)" in sub
    assert 'type    = "EMAIL"' in sub
    assert "tostring(var.anomaly_threshold_usd)" in sub
    assert "aws_sns_topic" not in sub


def test_names_do_not_collide_with_the_per_account_monitors():
    budgets = _read("budgets.tf")
    assert '"${each.value.name}-spend"' in budgets
    assert '"aa-app-${each.value}-spend"' in _read("cost_anomaly_app_tag.tf")
