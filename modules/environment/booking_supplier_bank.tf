# =============================================================================
# AA-1158 part 2 (S289; tech lead decision A1, S285: one customer managed key, about 1 USD/month) — the KMS key that
# protects supplier bank accounts in AA-Booking (table booking.supplier_bank_account, migration bk-067).
#
# Why: a supplier's bank account is where AA sends money; changing it is the main payout fraud path. Booking stores
# the account number, holder and bank codes as ciphertext (envelope encryption): per row, the app asks KMS for a data
# key (GenerateDataKey, AES-256), encrypts the details with AES-GCM in the process, stores the ciphertext, the wrapped
# data key and the key id, and forgets the plaintext key. Reading the details back is a Decrypt of the wrapped key.
# Only the Booking task role can do either, so a database dump, a read-only role or another app's task never sees an
# account number (AA-Booking backend/app/suppliers/bank_crypto.py).
#
# Key policy (same model as the CRM keys, crm_data.tf; no wildcard principal anywhere):
#   1. IamAdministration — the account root (= IAM decides) for the administrative verbs only, never a crypto verb or
#      CreateGrant. Who may run them is IAM's: the CI apply role through aa-cis-infra-tf-apply-sec (create with the
#      App = booking tag, describe, rotation, aliases: accounts/aa365/cicd_sec.tf; its boundary
#      DenyCrmKeyUseAndPolicyEdits (App = crm or booking) forbids any crypto use, PutKeyPolicy, ScheduleKeyDeletion, DisableKey and
#      CreateGrant), the plan role through ReadOnlyAccess, the MFA admin role for a policy edit (a local MFA apply).
#      It also satisfies the CreateKey lockout safety check (root may PutKeyPolicy).
#   2. BookingRuntimeEnvelope — GenerateDataKey / Decrypt only (the app never calls Encrypt: least privilege) for
#      the Booking task role (aws:PrincipalArn),
#      only with the encryption context {purpose = supplier_bank_account, supplier_id = <uuid>} the app sends: a
#      wrapped key of one supplier never unwraps under another supplier's context. The statement delegates to IAM
#      (principal = the account), so the task role's identity policy below must allow the same.
#   3. DenyCryptoOutsideBookingRuntime — explicit deny of every crypto verb to every principal of the account that is
#      not the Booking task role (the admin and read-only roles included). The principal is the account, not "*":
#      no other account has any allow on this key, so nothing outside the account reaches it anyway.
#   4. DenyGrants — kms:CreateGrant for everyone (no AWS service needs a grant on this key).
# Rotation: automatic, yearly (enable_key_rotation); old key material stays for Decrypt, so rows written before a
# rotation keep opening. Deletion window 30 days (a scheduled deletion is a local MFA apply, never CI).
#
# Booking task definition env SUPPLIER_BANK_KMS_KEY_ID = the alias name (booking.tf; no account id reaches the app
# repo). Not here (follow-up): an EventBridge alarm on key administration and on a crypto call by another principal,
# like the CRM keys (crm_data.tf aa-crm-<env>-kms-*), wired to the alert severity map.
#
# Cost (us-west-1, est.): 1 customer managed key = 1 USD/month; automatic rotation adds 1 USD/month for each of its
# first two rotations (from month 13); requests (a few per bank account entry or read) stay inside the 20,000/month
# free tier. About 1 USD/month now, 2-3 USD/month from the second year.
# =============================================================================

locals {
  bk_supplier_bank_alias   = "alias/${local.bk_name_prefix}-supplier-bank"
  bk_supplier_bank_purpose = "supplier_bank_account"
  bk_kms_crypto_actions    = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey*", "kms:ReEncrypt*", "kms:Sign"]
  bk_kms_admin_actions = [
    "kms:DescribeKey", "kms:GetKeyPolicy", "kms:GetKeyRotationStatus", "kms:ListKeyPolicies",
    "kms:ListResourceTags", "kms:ListGrants", "kms:ListKeyRotations",
    "kms:EnableKeyRotation", "kms:DisableKeyRotation", "kms:RotateKeyOnDemand", "kms:UpdateKeyDescription",
    "kms:TagResource", "kms:UntagResource", "kms:CreateAlias", "kms:DeleteAlias", "kms:UpdateAlias",
    "kms:PutKeyPolicy", "kms:ScheduleKeyDeletion", "kms:CancelKeyDeletion", "kms:EnableKey", "kms:DisableKey",
    "kms:RevokeGrant", "kms:RetireGrant",
  ]
}

data "aws_iam_policy_document" "booking_supplier_bank_kms" {
  statement {
    sid       = "IamAdministration"
    actions   = local.bk_kms_admin_actions
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.account_id}:root"]
    }
  }

  statement {
    sid       = "BookingRuntimeEnvelope"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.account_id}:root"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:PrincipalArn"
      values   = [aws_iam_role.booking_ecs_task.arn]
    }
    # Exactly the app's context {purpose, supplier_id}: no other key, both present, the one purpose.
    condition {
      test     = "ForAllValues:StringEquals"
      variable = "kms:EncryptionContextKeys"
      values   = ["purpose", "supplier_id"]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:purpose"
      values   = [local.bk_supplier_bank_purpose]
    }
    condition {
      test     = "Null"
      variable = "kms:EncryptionContext:supplier_id"
      values   = ["false"]
    }
  }

  statement {
    sid       = "DenyCryptoOutsideBookingRuntime"
    effect    = "Deny"
    actions   = local.bk_kms_crypto_actions
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.account_id}:root"]
    }
    condition {
      test     = "ArnNotEquals"
      variable = "aws:PrincipalArn"
      values   = [aws_iam_role.booking_ecs_task.arn]
    }
  }

  statement {
    sid       = "DenyGrants"
    effect    = "Deny"
    actions   = ["kms:CreateGrant"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.account_id}:root"]
    }
  }
}

resource "aws_kms_key" "booking_supplier_bank" {
  description              = "AA-Booking ${var.environment} supplier bank accounts: wraps the per-row data keys of booking.supplier_bank_account (AA-1158 part 2, bk-067)"
  key_usage                = "ENCRYPT_DECRYPT"
  customer_master_key_spec = "SYMMETRIC_DEFAULT"
  enable_key_rotation      = true
  deletion_window_in_days  = 30
  policy                   = data.aws_iam_policy_document.booking_supplier_bank_kms.json
  tags                     = merge(local.bk_tags, { Name = "${local.bk_name_prefix}-supplier-bank", Issue = "AA-1158", Component = "encryption", DataClassification = "restricted" })
}

resource "aws_kms_alias" "booking_supplier_bank" {
  name          = local.bk_supplier_bank_alias
  target_key_id = aws_kms_key.booking_supplier_bank.key_id
}

# The identity side of BookingRuntimeEnvelope (the key policy delegates to IAM, so both must allow), with the same
# context conditions. Only the two verbs the app calls (bank_crypto.py: GenerateDataKey on entry, Decrypt on read);
# no Encrypt, no ReEncrypt (a future re-wrap adds the verb it needs then).
resource "aws_iam_role_policy" "booking_ecs_task_supplier_bank" {
  name = "${local.bk_name_prefix}-ecs-task-supplier-bank"
  role = aws_iam_role.booking_ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "SupplierBankEnvelope"
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = aws_kms_key.booking_supplier_bank.arn
        Condition = {
          "ForAllValues:StringEquals" = { "kms:EncryptionContextKeys" = ["purpose", "supplier_id"] }
          "StringEquals"              = { "kms:EncryptionContext:purpose" = local.bk_supplier_bank_purpose }
          "Null"                      = { "kms:EncryptionContext:supplier_id" = "false" }
        }
      },
    ]
  })
}

output "booking_supplier_bank_kms_alias" {
  description = "AA-1158: the alias of the supplier bank account key (Booking env SUPPLIER_BANK_KMS_KEY_ID)."
  value       = aws_kms_alias.booking_supplier_bank.name
}
