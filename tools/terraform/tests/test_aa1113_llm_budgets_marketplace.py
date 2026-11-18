"""Static tests: the two LLM-account budgets count AWS Marketplace spend (AA-1113, S284; root ADR 0009 decision 6).

Claude models on Amazon Bedrock are billed through AWS Marketplace (billing entity "AWS Marketplace", the "Amazon
Bedrock Edition" service lines). An AWS cost budget counts every billing entity unless a cost filter narrows it (the
Billing entity, Service or Legal entity dimensions of AWS Budgets), so the guard is what the budgets must NOT carry:

  - acc3 ``aa3-llm-monthly-total`` (accounts/acc3-bedrock/cost_guard.tf): no cost filter at all (the whole account);
  - acc1 ``aa1-llm-monthly-total`` (accounts/acc1-bedrock/cost_guard.tf): exactly one filter, LinkedAccount = acc1
    itself (acc1 is the payer of acc3's organization), which keeps every billing entity of acc1's own usage;
  - neither excludes a cost type that Marketplace usage is billed as (no include_subscription / include_other_subscription
    / include_tax / include_support / include_upfront / include_recurring set to false; credits and refunds stay out
    so the budget follows real usage, AA-896);
  - acc3's limit stays equal to the gateway's acc3 connection cap (100 USD since S283, Infra #895).

Offline: reads the .tf files; no Terraform, no AWS. Run from the repo root:
python3 -m pytest -p no:cacheprovider -q tools/terraform/tests/test_aa1113_llm_budgets_marketplace.py
"""
from __future__ import annotations

import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
ACC3 = os.path.join(REPO_ROOT, "accounts", "acc3-bedrock", "cost_guard.tf")
ACC1 = os.path.join(REPO_ROOT, "accounts", "acc1-bedrock", "cost_guard.tf")

# Cost types a Marketplace or usage line can be billed as; setting any of them to false would drop spend.
KEPT_COST_TYPES = ("include_subscription", "include_other_subscription", "include_tax", "include_support",
                   "include_upfront", "include_recurring", "include_discount")
# The budget filter dimensions that could leave Marketplace lines out.
NARROWING = ("BillingEntity", "Service", "LegalEntityName", "InvoicingEntity", "RecordType", "UsageType")


def _read(path: str) -> str:
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def _code(text: str) -> str:
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))


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


def _budget(path: str, name: str) -> str:
    return _block(_code(_read(path)), f'resource "aws_budgets_budget" "{name}" {{')


def _no_dropped_cost_type(budget: str) -> None:
    types = _block(budget, "cost_types {")
    for key in KEPT_COST_TYPES:
        assert not re.search(rf"\b{key}\s*=\s*false\b", types), key
    assert "include_credit = false" in types and "include_refund = false" in types


def test_the_acc3_budget_has_no_filter_so_marketplace_counts():
    budget = _budget(ACC3, "acc3_monthly")
    assert 'budget_type  = "COST"' in budget
    assert "cost_filter" not in budget and "cost_filters" not in budget
    _no_dropped_cost_type(budget)


def test_the_acc1_budget_filters_its_own_account_only():
    budget = _budget(ACC1, "acc1_monthly")
    filters = re.findall(r"cost_filter\s*\{", budget)
    assert len(filters) == 1
    filt = _block(budget, "cost_filter {")
    assert 'name   = "LinkedAccount"' in filt
    for dim in NARROWING:
        assert dim not in budget, dim
    _no_dropped_cost_type(budget)


def test_the_acc3_limit_matches_the_gateway_cap():
    var = _block(_code(_read(ACC3)), 'variable "acc3_budget_monthly_usd" {')
    assert re.search(r"default\s*=\s*100\b", var)
