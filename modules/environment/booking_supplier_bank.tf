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
# repo).
#
# Alarms (S294, the part 2 follow-up; same pattern as the CRM keys, crm_data.tf aa-crm-<env>-kms-*): two CloudTrail
# EventBridge rules at page severity, locked (AA-1171 D5), each with a target on the alerts topic and one on the page
# topic carrying the same e-mail text:
#   aa-booking-<env>-kms-key-admin    key policy, grant, deletion, disable, rotation-off, alias, tag or key material
#                                     change on this key or its alias. Only a planned local MFA apply may do that.
#   aa-booking-<env>-kms-foreign-use  a crypto call on this key (allowed or denied) by any principal other than the
#                                     Booking task role or an AWS service (DenyCryptoOutsideBookingRuntime refuses
#                                     it; the alarm says someone tried).
# The page topic policy admits rule/aa-booking-* (accounts/aa365 alert_severity.tf AllowPageEventBridgeRules). The
# apply order and the topic and CI grants these rules rely on are tracked in AA-1158.
#
# Cost (us-west-1, est.): 1 customer managed key = 1 USD/month; automatic rotation adds 1 USD/month for each of its
# first two rotations (from month 13); requests (a few per bank account entry or read) stay inside the 20,000/month
# free tier. About 1 USD/month now, 2-3 USD/month from the second year. The two alarm rules cost nothing: AWS service
# events on the default bus are free, and the SNS e-mails stay inside the 1,000/month free notifications.
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

# -----------------------------------------------------------------------------
# Alarms on the key (S294; the CRM pattern of crm_data.tf crm_kms_key_admin / crm_kms_foreign_use)
# -----------------------------------------------------------------------------

locals {
  # CloudTrail logs requestParameters.keyId as the caller passed it (key id, key ARN, alias name or alias ARN);
  # resources[].ARN is the key ARN. Match all four.
  bk_supplier_bank_key_match = [
    aws_kms_key.booking_supplier_bank.key_id,
    aws_kms_key.booking_supplier_bank.arn,
    local.bk_supplier_bank_alias,
    "arn:aws:kms:${var.aws_region}:${var.account_id}:${local.bk_supplier_bank_alias}",
  ]
  bk_kms_alert_input_paths = {
    event     = "$.detail.eventName"
    principal = "$.detail.userIdentity.arn"
    key       = "$.detail.resources[0].ARN"
    ip        = "$.detail.sourceIPAddress"
    time      = "$.detail.eventTime"
    error     = "$.detail.errorCode"
  }
}

resource "aws_cloudwatch_event_rule" "booking_kms_key_admin" {
  name        = "${local.bk_name_prefix}-kms-key-admin"
  description = "Booking supplier bank account KMS key: key policy, grant, deletion, disable, rotation-off, alias, tag or key-material change (CloudTrail). AA-1158.${var.runbook_suffix.incident}"
  state       = "ENABLED"

  event_pattern = jsonencode({
    source        = ["aws.kms"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["kms.amazonaws.com"]
      eventName = [
        "PutKeyPolicy", "CreateGrant", "ScheduleKeyDeletion", "DisableKey", "DisableKeyRotation",
        "UpdateAlias", "DeleteAlias", "ImportKeyMaterial", "DeleteImportedKeyMaterial", "ReplicateKey",
        "UpdatePrimaryRegion", "CancelKeyDeletion", "EnableKey", "TagResource", "UntagResource",
      ]
      "$or" = [
        { resources = { ARN = [aws_kms_key.booking_supplier_bank.arn] } },
        { requestParameters = { keyId = local.bk_supplier_bank_key_match } },
        { requestParameters = { aliasName = [local.bk_supplier_bank_alias] } },
      ]
    }
  })

  tags = merge(local.bk_tags, { Issue = "AA-1158", Component = "security" }, var.alert_tags.page_locked) # page, security: Booking supplier bank key administration
}

resource "aws_cloudwatch_event_target" "booking_kms_key_admin" {
  rule      = aws_cloudwatch_event_rule.booking_kms_key_admin.name
  target_id = "alerts-sns"
  arn       = var.alerts_topic_arn

  input_transformer {
    input_paths    = local.bk_kms_alert_input_paths
    input_template = "\"[aa-booking] Supplier bank KMS key change: <event> on <key> by <principal> from <ip> at <time> (errorCode: <error>). Only a planned local MFA apply may change this key; otherwise treat it as an incident.${var.runbook_suffix.incident}\""
  }
}

resource "aws_cloudwatch_event_rule" "booking_kms_foreign_use" {
  name        = "${local.bk_name_prefix}-kms-foreign-use"
  description = "Booking supplier bank account KMS key: a crypto call (allowed or denied) by a principal other than the Booking task role or an AWS service. AA-1158.${var.runbook_suffix.incident}"
  state       = "ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS"

  event_pattern = jsonencode({
    source        = ["aws.kms"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["kms.amazonaws.com"]
      eventName = [
        "Decrypt", "Encrypt", "GenerateDataKey", "GenerateDataKeyWithoutPlaintext", "GenerateDataKeyPair",
        "GenerateDataKeyPairWithoutPlaintext", "ReEncrypt", "Sign",
      ]
      resources = { ARN = [aws_kms_key.booking_supplier_bank.arn] }
      "$or" = [
        { userIdentity = { type = [{ "anything-but" = ["AssumedRole", "AWSService"] }] } },
        { userIdentity = { type = ["AssumedRole"], sessionContext = { sessionIssuer = { arn = [{ "anything-but" = [aws_iam_role.booking_ecs_task.arn] }] } } } },
      ]
    }
  })

  tags = merge(local.bk_tags, { Issue = "AA-1158", Component = "security" }, var.alert_tags.page_locked) # page, security: Booking supplier bank key used by another principal
}

resource "aws_cloudwatch_event_target" "booking_kms_foreign_use" {
  rule      = aws_cloudwatch_event_rule.booking_kms_foreign_use.name
  target_id = "alerts-sns"
  arn       = var.alerts_topic_arn

  input_transformer {
    input_paths    = local.bk_kms_alert_input_paths
    input_template = "\"[aa-booking] Supplier bank KMS key used by a foreign principal: <event> on <key> by <principal> from <ip> at <time> (errorCode: <error>). Only the Booking task role uses this key; anything else is an incident.${var.runbook_suffix.incident}\""
  }
}

# Page severity (AA-1171 D5): each rule gets a second target on the page topic with the same e-mail text (the page
# topic policy admits rule/aa-booking-*, accounts/aa365 alert_severity.tf).
resource "aws_cloudwatch_event_target" "booking_kms_page" {
  for_each = {
    key_admin   = aws_cloudwatch_event_target.booking_kms_key_admin
    foreign_use = aws_cloudwatch_event_target.booking_kms_foreign_use
  }

  rule      = each.value.rule
  target_id = "page-sns"
  arn       = var.page_topic_arn

  input_transformer {
    input_paths    = each.value.input_transformer[0].input_paths
    input_template = each.value.input_transformer[0].input_template
  }
}

output "booking_supplier_bank_kms_alias" {
  description = "AA-1158: the alias of the supplier bank account key (Booking env SUPPLIER_BANK_KMS_KEY_ID)."
  value       = aws_kms_alias.booking_supplier_bank.name
}
