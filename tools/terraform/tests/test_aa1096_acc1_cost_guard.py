"""Static tests: the acc1 spend guard is billing-only and ALERT ONLY (AA-1096, S279; root ADR 0001a, Note S279).

acc1 serves the gateway's Bedrock chat models (AA-1095) and may hold nothing else of the ecosystem. The tech lead's
S279 exception: a free AWS Budget and a Cost Anomaly Detection monitor that only send e-mails, never a stop.

What they hold:
  - accounts/acc1-bedrock holds exactly the invoker role, its inline policy and the three billing resources; no
    budget action, no SNS topic, no IAM for an action.
  - the budget counts acc1's own usage only (LinkedAccount = var.account_id: acc1 is the payer of acc3's
    organization), gross of credits, monthly COST; its amount and percentages are variables (50/80/100 % ACTUAL,
    100 % FORECASTED by default).
  - the anomaly monitor is CUSTOM on LINKED_ACCOUNT (no collision with the one AWS services monitor an account may
    have, and acc3's spend stays out); the subscription is DAILY e-mail on the absolute total impact.
  - the recipient is a required variable (the untracked terraform.tfvars), never a committed address.

Offline: reads the .tf files; no Terraform, no AWS. Run from the repo root:
python3 -m pytest -p no:cacheprovider -q tools/terraform/tests/test_aa1096_acc1_cost_guard.py
"""
from __future__ import annotations

import glob
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
ACC1 = os.path.join(REPO_ROOT, "accounts", "acc1-bedrock")
GUARD = os.path.join(ACC1, "cost_guard.tf")

RESOURCE = re.compile(r'^resource\s+"([a-z0-9_]+)"\s+"([a-z0-9_]+)"', re.M)


def _read(path: str) -> str:
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def _block(text: str, opener: str) -> str:
    start = text.index(opener)
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    raise AssertionError(f"unclosed block: {opener}")


def _code(text: str) -> str:
    """The text without full-line comments (the header explains what is NOT there)."""
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))


def test_the_acc1_root_holds_the_invoker_role_and_three_billing_resources_only():
    found = set()
    for path in glob.glob(os.path.join(ACC1, "*.tf")):
        found |= set(RESOURCE.findall(_read(path)))
    assert found == {
        ("aws_iam_role", "bedrock_invoker"),
        ("aws_iam_role_policy", "bedrock_invoker_policy"),
        ("aws_budgets_budget", "acc1_monthly"),
        ("aws_ce_anomaly_monitor", "acc1_spend"),
        ("aws_ce_anomaly_subscription", "acc1_daily"),
    }


def test_alert_only_no_action_no_topic_no_iam():
    code = _code(_read(GUARD))
    for forbidden in ("aws_budgets_budget_action", "aws_sns_topic", "aws_iam_", "aws_ssm_", "aws_lambda"):
        assert forbidden not in code, forbidden
    out = _block(code, 'output "cost_guard" {')
    assert "hard_stop               = false" in out


def test_budget_counts_acc1_own_gross_monthly_cost():
    budget = _block(_read(GUARD), 'resource "aws_budgets_budget" "acc1_monthly" {')
    assert 'budget_type  = "COST"' in budget
    assert 'time_unit    = "MONTHLY"' in budget
    assert "limit_amount = tostring(var.budget_monthly_usd)" in budget
    filt = _block(budget, "cost_filter {")
    assert 'name   = "LinkedAccount"' in filt and "values = [var.account_id]" in filt
    types = _block(budget, "cost_types {")
    assert "include_credit = false" in types and "include_refund = false" in types
    note = _block(budget, 'dynamic "notification" {')
    assert "for_each = local.budget_notifications" in note
    assert 'threshold_type             = "PERCENTAGE"' in note
    assert "subscriber_email_addresses = [var.cost_alert_email]" in note
    assert "subscriber_sns_topic_arns" not in budget


def test_budget_values_are_variables_with_the_s279_defaults():
    text = _read(GUARD)
    assert "default     = 100\n" in _block(text, 'variable "budget_monthly_usd" {')
    assert "default     = [50, 80, 100]" in _block(text, 'variable "budget_alert_actual_percents" {')
    assert "default     = 100\n" in _block(text, 'variable "budget_alert_forecast_percent" {')
    assert "default     = 10\n" in _block(text, 'variable "anomaly_alert_usd" {')
    loc = _block(text, "locals {")
    assert '{ type = "ACTUAL", threshold = p }' in loc
    assert '{ type = "FORECASTED", threshold = var.budget_alert_forecast_percent }' in loc


def test_recipient_is_a_required_variable_never_committed():
    text = _read(GUARD)
    var = _block(text, 'variable "cost_alert_email" {')
    assert "default" not in var
    assert not re.search(r'"[^"\s@]+@[^"\s@]+\.[a-z]{2,}"', _code(text)), "a literal e-mail address"


def test_anomaly_monitor_is_custom_on_acc1_linked_account():
    mon = _block(_read(GUARD), 'resource "aws_ce_anomaly_monitor" "acc1_spend" {')
    assert 'monitor_type = "CUSTOM"' in mon
    assert "monitor_dimension" not in mon
    assert re.search(r'Key\s+=\s+"LINKED_ACCOUNT"', mon)
    assert re.search(r"Values\s+=\s+\[var\.account_id\]", mon)
    # Every expression key spelled out, as accounts/management/budgets.tf does (a shorter document shows a diff).
    for key in ("And", "CostCategories", "Dimensions", "Not", "Or", "ProductAttributes", "Tags"):
        assert re.search(rf"\n\s+{key}\s+=", mon), key


def test_anomaly_subscription_is_daily_email_on_absolute_impact():
    sub = _block(_read(GUARD), 'resource "aws_ce_anomaly_subscription" "acc1_daily" {')
    assert 'frequency        = "DAILY"' in sub
    assert "monitor_arn_list = [aws_ce_anomaly_monitor.acc1_spend.arn]" in sub
    assert 'type    = "EMAIL"' in sub and "address = var.cost_alert_email" in sub
    assert 'key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"' in sub
    assert 'match_options = ["GREATER_THAN_OR_EQUAL"]' in sub
    assert "values        = [tostring(var.anomaly_alert_usd)]" in sub


def test_every_billing_resource_is_tagged_billing():
    text = _read(GUARD)
    for opener in ('resource "aws_budgets_budget" "acc1_monthly" {',
                   'resource "aws_ce_anomaly_monitor" "acc1_spend" {',
                   'resource "aws_ce_anomaly_subscription" "acc1_daily" {'):
        assert 'tags = { Component = "billing", Issue = "AA-1096" }' in _block(text, opener), opener
