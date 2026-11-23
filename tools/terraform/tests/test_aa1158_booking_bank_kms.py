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

Run: python3 -m pytest -q tools/terraform/tests/test_aa1158_booking_bank_kms.py
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
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


if __name__ == "__main__":
    unittest.main()
