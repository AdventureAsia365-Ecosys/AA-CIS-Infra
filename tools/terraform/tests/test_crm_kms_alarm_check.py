"""AA-932: the CRM KMS alarm patterns in accounts/aa365/crm_data.tf against the live-check events, offline.

EventBridge matching is evaluated here by a small matcher that covers exactly the operators the two rules use (exact
values, prefix, anything-but list, nested objects, arrays of objects, $or). The live check
(tools/terraform/crm_kms_alarm_check.py) asks EventBridge itself after the apply; this test keeps the Terraform
pattern and the expected outcomes from drifting before that.

Run: python3 -m unittest discover -s tools/terraform/tests -v
"""
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "terraform"))

import crm_kms_alarm_check as chk  # noqa: E402

TF = (ROOT / "accounts" / "aa365" / "crm_data.tf").read_text(encoding="utf-8")
ACCOUNT, REGION, ENV = "005097885195", "us-west-1", "dev"
KEYS = {n: (f"{n}-0000-1111", f"arn:aws:kms:{REGION}:{ACCOUNT}:key/{n}-0000-1111") for n in ("data", "ingest", "seal")}


def _rule_event_names(rule: str) -> list:
    block = TF.split(f'resource "aws_cloudwatch_event_rule" "{rule}"', 1)[1].split("\nresource ", 1)[0]
    names = re.search(r"eventName = \[(.*?)\]", block, re.S).group(1)
    return re.findall(r'"([A-Za-z]+)"', names)


def patterns():
    arns = [a for _, a in KEYS.values()]
    match = ([{"prefix": i} for i, _ in KEYS.values()] + [{"prefix": a} for a in arns]
             + [{"prefix": f"alias/crm-{ENV}/"}, {"prefix": f"arn:aws:kms:{REGION}:{ACCOUNT}:alias/crm-{ENV}/"}])
    task = f"arn:aws:iam::{ACCOUNT}:role/aa-crm-{ENV}-ecs-task-role"
    admin = {"source": ["aws.kms"], "detail-type": ["AWS API Call via CloudTrail"], "detail": {
        "eventSource": ["kms.amazonaws.com"], "eventName": _rule_event_names("crm_kms_key_admin"),
        "$or": [{"resources": {"ARN": arns}}, {"requestParameters": {"keyId": match}},
                {"requestParameters": {"aliasName": [{"prefix": f"alias/crm-{ENV}/"}]}}]}}
    foreign = {"source": ["aws.kms"], "detail-type": ["AWS API Call via CloudTrail"], "detail": {
        "eventSource": ["kms.amazonaws.com"], "eventName": _rule_event_names("crm_kms_foreign_use"),
        "resources": {"ARN": arns},
        "$or": [{"userIdentity": {"type": [{"anything-but": ["AssumedRole", "AWSService"]}]}},
                {"userIdentity": {"type": ["AssumedRole"],
                                  "sessionContext": {"sessionIssuer": {"arn": [{"anything-but": [task]}]}}}}]}}
    return {f"aa-crm-{ENV}-kms-key-admin": admin, f"aa-crm-{ENV}-kms-foreign-use": foreign}


def _values(event, path):
    """Every leaf value at `path` in `event`, descending into arrays."""
    nodes = [event]
    for k in path:
        nxt = []
        for n in nodes:
            for m in (n if isinstance(n, list) else [n]):
                if isinstance(m, dict) and k in m:
                    nxt.append(m[k])
        nodes = nxt
    out = []
    for n in nodes:
        out.extend(n if isinstance(n, list) else [n])
    return out


def _leaf_ok(rules, values):
    for r in rules:
        for v in values:
            if isinstance(r, dict):
                if "prefix" in r and isinstance(v, str) and v.startswith(r["prefix"]):
                    return True
                if "anything-but" in r and v not in r["anything-but"]:
                    return True
            elif r == v:
                return True
    return False


def matches(pattern, event, path=()):
    for k, rule in pattern.items():
        if k == "$or":
            if not any(matches(alt, event, path) for alt in rule):
                return False
        elif isinstance(rule, dict):
            if not matches(rule, event, path + (k,)):
                return False
        elif not _leaf_ok(rule, _values(event, path + (k,))):
            return False
    return True


class AlarmPatternTest(unittest.TestCase):
    def test_every_case_has_the_expected_outcome(self):
        pats = patterns()
        for cid, rule, event, expected in chk.cases(ACCOUNT, REGION, ENV, KEYS):
            with self.subTest(case=cid):
                self.assertIs(matches(pats[rule], event), expected)

    def test_design_events_are_alarmed(self):
        # design v3 §4.1: PutKeyPolicy, CreateGrant, ScheduleKeyDeletion, DisableKey on all three keys; Decrypt by
        # any other principal.
        self.assertLessEqual(set(chk.ADMIN_EVENTS), set(_rule_event_names("crm_kms_key_admin")))
        self.assertIn("Decrypt", _rule_event_names("crm_kms_foreign_use"))
        self.assertIn('state       = "ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS"',
                      TF.split('resource "aws_cloudwatch_event_rule" "crm_kms_foreign_use"', 1)[1])

    def test_every_rule_has_a_runbook_and_crm_tags(self):
        for rule in ("crm_kms_key_admin", "crm_kms_foreign_use"):
            block = TF.split(f'resource "aws_cloudwatch_event_rule" "{rule}"', 1)[1].split("\nresource ", 1)[0]
            self.assertIn("${local.runbook_suffix.crm_keys}", block)
            self.assertIn("local.crm_tags", block)

    def test_key_policies_never_give_crypto_to_root(self):
        # The account-root statement is administrative only: no crypto verb, no CreateGrant (design §4.1).
        admin = re.search(r"crm_kms_admin_actions = \[(.*?)\]", TF, re.S).group(1)
        for verb in ("Decrypt", "Encrypt", "GenerateDataKey", "ReEncrypt", "Sign\"", "CreateGrant"):
            self.assertNotIn(verb, admin)


if __name__ == "__main__":
    unittest.main()
