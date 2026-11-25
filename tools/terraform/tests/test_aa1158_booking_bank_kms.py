"""AA-1158 part 2 (S289): offline guards for the Booking supplier bank account KMS key.

1. One customer managed symmetric key with automatic rotation, the App = booking tag (the CI grants and the boundary
   deny key on it) and the alias aa-booking-<env>-supplier-bank.
2. Key policy: no wildcard principal anywhere; the only crypto Allow is GenerateDataKey / Decrypt (never Encrypt) for the
   Booking task role with the {purpose, supplier_id} context; every other principal of the account is denied every
   crypto verb; CreateGrant is denied; the administration statement carries no crypto verb.
3. The task role's identity policy allows exactly the same two verbs on this key with the same context.
4. The Booking task definition gets SUPPLIER_BANK_KMS_KEY_ID from the alias (a name, no account id).
5. CI: the apply role may create (App = booking) and describe the key and manage aliases aa-booking-*, never use it,
   change its policy, delete or disable it (the boundary deny covers App = booking).
6. Alarms (S294): rules aa-booking-<env>-kms-key-admin and -kms-foreign-use, page severity (locked), each with an
   alerts-topic and a page-topic target; their event patterns, evaluated offline with the matcher of
   test_crm_kms_alarm_check.py, catch key administration and any crypto call but the task role's or an AWS service's.

Run: python3 -m pytest -q tools/terraform/tests/test_aa1158_booking_bank_kms.py
"""

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "terraform"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import crm_kms_alarm_check as chk  # noqa: E402  the CloudTrail sample events
from test_crm_kms_alarm_check import matches  # noqa: E402  the offline EventBridge matcher

MOD = ROOT / "modules" / "environment"
AA365 = ROOT / "accounts" / "aa365"
KMS = (MOD / "booking_supplier_bank.tf").read_text(encoding="utf-8")
BOOKING = (MOD / "booking.tf").read_text(encoding="utf-8")
SEC = (AA365 / "cicd_sec.tf").read_text(encoding="utf-8")
SPLIT = (AA365 / "cicd_split.tf").read_text(encoding="utf-8")

CRYPTO = ("kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey", "kms:ReEncrypt", "kms:Sign")


def _block(text: str, opener: str) -> str:
    m = re.search(rf"^{re.escape(opener)} \{{", text, re.M)
    assert m, f"{opener} not found"
    body = text[m.end():]
    end = re.search(r"^\}", body, re.M)
    return body[: end.start()]


def _statements(doc: str) -> dict[str, str]:
    """Each `statement { sid = "X" ... }` of a policy document block, by sid."""
    out: dict[str, str] = {}
    for part in re.split(r"^  statement \{", doc, flags=re.M)[1:]:
        sid = re.search(r'sid\s*=\s*"([^"]+)"', part)
        assert sid, "every statement names a sid"
        out[sid.group(1)] = part
    return out


class KeyTest(unittest.TestCase):
    def test_symmetric_rotating_tagged_key(self):
        key = _block(KMS, 'resource "aws_kms_key" "booking_supplier_bank"')
        self.assertIn('key_usage                = "ENCRYPT_DECRYPT"', key)
        self.assertIn('customer_master_key_spec = "SYMMETRIC_DEFAULT"', key)
        self.assertIn("enable_key_rotation      = true", key)
        self.assertIn("deletion_window_in_days  = 30", key)
        self.assertIn("merge(local.bk_tags", key)  # App = booking
        self.assertIn('Component = "encryption"', key)
        self.assertRegex(BOOKING, r'App\s*=\s*"booking"')

    def test_alias(self):
        self.assertIn('bk_supplier_bank_alias   = "alias/${local.bk_name_prefix}-supplier-bank"', KMS)
        alias = _block(KMS, 'resource "aws_kms_alias" "booking_supplier_bank"')
        self.assertIn("target_key_id = aws_kms_key.booking_supplier_bank.key_id", alias)


class KeyPolicyTest(unittest.TestCase):
    doc = _block(KMS, 'data "aws_iam_policy_document" "booking_supplier_bank_kms"')
    stmts = _statements(doc)

    def test_no_wildcard_principal(self):
        self.assertNotIn('identifiers = ["*"]', self.doc)
        for sid, body in self.stmts.items():
            self.assertIn('identifiers = ["arn:aws:iam::${var.account_id}:root"]', body, sid)

    def test_the_expected_statements(self):
        self.assertEqual(
            set(self.stmts),
            {"IamAdministration", "BookingRuntimeEnvelope", "DenyCryptoOutsideBookingRuntime", "DenyGrants"},
        )

    def test_administration_has_no_crypto_verb(self):
        self.assertIn("actions   = local.bk_kms_admin_actions", self.stmts["IamAdministration"])
        admin = KMS.split("bk_kms_admin_actions = [")[1].split("]")[0]
        for verb in (*CRYPTO, "kms:CreateGrant"):
            self.assertNotIn(verb, admin)

    def test_runtime_is_the_task_role_with_the_context(self):
        body = self.stmts["BookingRuntimeEnvelope"]
        self.assertIn('actions   = ["kms:GenerateDataKey", "kms:Decrypt"]', body)
        self.assertNotIn("kms:Encrypt", body.replace("kms:EncryptionContext", ""))  # least privilege: wrap + unwrap only
        self.assertNotIn("effect", body)  # an Allow
        self.assertIn("values   = [aws_iam_role.booking_ecs_task.arn]", body)
        self.assertIn('variable = "aws:PrincipalArn"', body)
        self.assertIn('values   = ["purpose", "supplier_id"]', body)
        self.assertIn('variable = "kms:EncryptionContext:purpose"', body)
        self.assertIn('bk_supplier_bank_purpose = "supplier_bank_account"', KMS)
        self.assertIn('variable = "kms:EncryptionContext:supplier_id"', body)

    def test_everyone_else_is_denied_crypto_and_grants(self):
        deny = self.stmts["DenyCryptoOutsideBookingRuntime"]
        self.assertIn('effect    = "Deny"', deny)
        self.assertIn("actions   = local.bk_kms_crypto_actions", deny)
        self.assertIn('test     = "ArnNotEquals"', deny)
        self.assertIn("values   = [aws_iam_role.booking_ecs_task.arn]", deny)
        crypto = KMS.split("bk_kms_crypto_actions    = [")[1].split("]")[0]
        for verb in ("kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey*", "kms:ReEncrypt*"):
            self.assertIn(f'"{verb}"', crypto)
        grants = self.stmts["DenyGrants"]
        self.assertIn('effect    = "Deny"', grants)
        self.assertIn('actions   = ["kms:CreateGrant"]', grants)

    def test_only_one_allow_carries_a_crypto_verb(self):
        for sid, body in self.stmts.items():
            if "Deny" in body or sid == "IamAdministration":
                continue
            self.assertEqual(sid, "BookingRuntimeEnvelope")


class TaskRoleTest(unittest.TestCase):
    def test_identity_policy_matches_the_key_policy(self):
        pol = _block(KMS, 'resource "aws_iam_role_policy" "booking_ecs_task_supplier_bank"')
        self.assertIn("role = aws_iam_role.booking_ecs_task.id", pol)
        self.assertIn('Action   = ["kms:GenerateDataKey", "kms:Decrypt"]', pol)
        self.assertNotIn("kms:Encrypt", pol.replace("kms:EncryptionContext", ""))
        self.assertIn("Resource = aws_kms_key.booking_supplier_bank.arn", pol)
        self.assertIn('"kms:EncryptionContextKeys" = ["purpose", "supplier_id"]', pol)
        self.assertIn('"kms:EncryptionContext:purpose" = local.bk_supplier_bank_purpose', pol)
        self.assertIn('"kms:EncryptionContext:supplier_id" = "false"', pol)

    def test_task_definition_env(self):
        task = _block(BOOKING, 'resource "aws_ecs_task_definition" "booking"')
        self.assertIn(
            '{ name = "SUPPLIER_BANK_KMS_KEY_ID", value = aws_kms_alias.booking_supplier_bank.name }', task
        )
        self.assertNotRegex(KMS, r"\b\d{12}\b")  # no account id committed


class CiTest(unittest.TestCase):
    def test_apply_role_creates_and_describes_booking_keys_only(self):
        doc = _block(SEC, 'data "aws_iam_policy_document" "tf_apply_sec"')
        stmts = _statements(doc)
        create = stmts["BookingKmsCreateTagged"]
        self.assertIn('actions   = ["kms:CreateKey", "kms:TagResource"]', create)
        self.assertIn('variable = "aws:RequestTag/App"', create)
        self.assertIn('values   = ["booking"]', create)
        manage = stmts["BookingKmsManageTagged"]
        self.assertIn('variable = "aws:ResourceTag/App"', manage)
        for verb in (*CRYPTO, "kms:PutKeyPolicy", "kms:ScheduleKeyDeletion", "kms:DisableKey", "kms:CreateGrant"):
            for sid in ("BookingKmsCreateTagged", "BookingKmsManageTagged", "BookingKmsAlias"):
                self.assertNotIn(verb, stmts[sid], f"{sid} must not grant {verb}")
        self.assertIn(":alias/aa-booking-*", stmts["BookingKmsAlias"])
        self.assertIn('values   = ["App"]', stmts["BookingKmsUntagExceptApp"])

    def test_boundary_denies_use_and_policy_edits_on_booking_keys(self):
        doc = _block(SPLIT, 'data "aws_iam_policy_document" "tf_apply_boundary"')
        deny = _statements(doc)["DenyCrmKeyUseAndPolicyEdits"]
        self.assertIn('effect = "Deny"', deny)
        self.assertIn('values   = ["crm", "booking"]', deny)
        for verb in ("kms:Decrypt", "kms:PutKeyPolicy", "kms:ScheduleKeyDeletion", "kms:DisableKey", "kms:CreateGrant"):
            self.assertIn(f'"{verb}"', deny)


ACCOUNT, REGION, ENV = "000000000000", "us-west-1", "dev"
KEY_ID = "bank-0000-1111"
KEY_ARN = f"arn:aws:kms:{REGION}:{ACCOUNT}:key/{KEY_ID}"
ALIAS = f"alias/aa-booking-{ENV}-supplier-bank"
TASK_ROLE = f"aa-booking-{ENV}-ecs-task-role"


def _rule(name: str) -> str:
    return _block(KMS, f'resource "aws_cloudwatch_event_rule" "{name}"')


def _event_names(name: str) -> list:
    return re.findall(r'"([A-Za-z]+)"', re.search(r"eventName = \[(.*?)\]", _rule(name), re.S).group(1))


def _patterns() -> dict:
    """The two rule patterns as Terraform renders them, with sample key values (the same shape as the HCL)."""
    match = [KEY_ID, KEY_ARN, ALIAS, f"arn:aws:kms:{REGION}:{ACCOUNT}:{ALIAS}"]
    task = f"arn:aws:iam::{ACCOUNT}:role/{TASK_ROLE}"
    admin = {"source": ["aws.kms"], "detail-type": ["AWS API Call via CloudTrail"], "detail": {
        "eventSource": ["kms.amazonaws.com"], "eventName": _event_names("booking_kms_key_admin"),
        "$or": [{"resources": {"ARN": [KEY_ARN]}}, {"requestParameters": {"keyId": match}},
                {"requestParameters": {"aliasName": [ALIAS]}}]}}
    foreign = {"source": ["aws.kms"], "detail-type": ["AWS API Call via CloudTrail"], "detail": {
        "eventSource": ["kms.amazonaws.com"], "eventName": _event_names("booking_kms_foreign_use"),
        "resources": {"ARN": [KEY_ARN]},
        "$or": [{"userIdentity": {"type": [{"anything-but": ["AssumedRole", "AWSService"]}]}},
                {"userIdentity": {"type": ["AssumedRole"],
                                  "sessionContext": {"sessionIssuer": {"arn": [{"anything-but": [task]}]}}}}]}}
    return {"admin": admin, "foreign": foreign}


class AlarmTest(unittest.TestCase):
    def test_rules_are_named_for_booking_and_page_locked(self):
        for name, suffix in (("booking_kms_key_admin", "kms-key-admin"), ("booking_kms_foreign_use", "kms-foreign-use")):
            rule = _rule(name)
            self.assertIn(f'name        = "${{local.bk_name_prefix}}-{suffix}"', rule)
            self.assertRegex(rule, r"tags\s*=\s*merge\(local\.bk_tags, .*var\.alert_tags\.page_locked\)")
            self.assertIn('Component = "security"', rule)
            self.assertIn("${var.runbook_suffix.incident}", rule)
        self.assertIn('state       = "ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS"', _rule("booking_kms_foreign_use"))

    def test_patterns_reference_this_key_and_the_task_role(self):
        admin, foreign = _rule("booking_kms_key_admin"), _rule("booking_kms_foreign_use")
        self.assertIn("{ resources = { ARN = [aws_kms_key.booking_supplier_bank.arn] } }", admin)
        self.assertIn("{ requestParameters = { keyId = local.bk_supplier_bank_key_match } }", admin)
        self.assertIn("{ requestParameters = { aliasName = [local.bk_supplier_bank_alias] } }", admin)
        self.assertIn("resources = { ARN = [aws_kms_key.booking_supplier_bank.arn] }", foreign)
        self.assertIn('"anything-but" = [aws_iam_role.booking_ecs_task.arn]', foreign)
        match = KMS.split("bk_supplier_bank_key_match = [", 1)[1].split("]", 1)[0]
        for ref in ("aws_kms_key.booking_supplier_bank.key_id", "aws_kms_key.booking_supplier_bank.arn",
                    "local.bk_supplier_bank_alias", ":${local.bk_supplier_bank_alias}"):
            self.assertIn(ref, match)

    def test_each_rule_notifies_both_topics_with_the_same_text(self):
        for name in ("booking_kms_key_admin", "booking_kms_foreign_use"):
            target = _block(KMS, f'resource "aws_cloudwatch_event_target" "{name}"')
            self.assertIn(f"rule      = aws_cloudwatch_event_rule.{name}.name", target)
            self.assertIn("arn       = var.alerts_topic_arn", target)
            self.assertIn("input_paths    = local.bk_kms_alert_input_paths", target)
            self.assertIn("[aa-booking]", target)
        page = _block(KMS, 'resource "aws_cloudwatch_event_target" "booking_kms_page"')
        self.assertIn("arn       = var.page_topic_arn", page)
        self.assertIn('target_id = "page-sns"', page)
        self.assertIn("each.value.input_transformer[0].input_template", page)

    def test_admin_events_cover_the_ci_boundary_verbs(self):
        # Everything the CI boundary keeps for a local MFA apply, plus tag changes (the boundary keys on App = booking).
        self.assertLessEqual(set(chk.ADMIN_EVENTS) | {"DisableKeyRotation", "UpdateAlias", "DeleteAlias"},
                             set(_event_names("booking_kms_key_admin")))
        self.assertLessEqual({"Decrypt", "GenerateDataKey", "Encrypt", "ReEncrypt"},
                             set(_event_names("booking_kms_foreign_use")))

    def test_sample_events(self):
        pats = _patterns()
        admin_role = chk.role_identity(ACCOUNT, chk.ADMIN_ROLE)
        task = chk.role_identity(ACCOUNT, TASK_ROLE)
        other = chk.role_identity(ACCOUNT, "aa-cis-dev-ecs-task-role")
        ev = lambda name, ident, key_id=KEY_ID, arn=KEY_ARN: chk.cloudtrail_event(  # noqa: E731
            ACCOUNT, REGION, name, arn, key_id, ident)
        cases = [
            ("admin PutKeyPolicy", "admin", ev("PutKeyPolicy", admin_role), True),
            ("admin ScheduleKeyDeletion", "admin", ev("ScheduleKeyDeletion", admin_role), True),
            ("admin by alias name", "admin", ev("DisableKey", admin_role, key_id=ALIAS), True),
            ("admin on another key", "admin",
             ev("PutKeyPolicy", admin_role, key_id="other-key", arn=KEY_ARN.replace(KEY_ID, "other-key")), False),
            ("Decrypt by the task role", "foreign", ev("Decrypt", task), False),
            ("GenerateDataKey by the task role", "foreign", ev("GenerateDataKey", task), False),
            ("Decrypt by the admin role", "foreign", ev("Decrypt", admin_role), True),
            ("Decrypt by another app task role", "foreign", ev("Decrypt", other), True),
            ("Decrypt by an IAM user", "foreign", ev("Decrypt", {"type": "IAMUser", "arn": "arn:x"}), True),
            ("Decrypt by an AWS service", "foreign", ev("Decrypt", chk.SERVICE_IDENTITY), False),
            ("Decrypt on another key", "foreign",
             ev("Decrypt", admin_role, key_id="other-key", arn=KEY_ARN.replace(KEY_ID, "other-key")), False),
        ]
        for cid, rule, event, expected in cases:
            with self.subTest(case=cid):
                self.assertIs(matches(pats[rule], event), expected)


if __name__ == "__main__":
    unittest.main()
