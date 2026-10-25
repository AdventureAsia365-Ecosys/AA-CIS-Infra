# =============================================================================
# AA-932 (CRM-04) — data-side resources of the partner CRM (AA-Partner, ADR 0010 decisions 2–3, design v3 §3.1 and
# §4.1): the runtime DSN secret shell, the three KMS keys with their key policies, and the key alarms.
#
# Naming contract (cicd_crm.tf): every resource carries App = "crm" (local.crm_tags); aliases alias/crm-<env>/{data,
# ingest,seal}; EventBridge rules aa-crm-*; the CRM ECS task role will be aa-crm-<env>-ecs-task-role (AA-933 creates
# it with the service; the key policies below already name it, so creating the role later needs no key-policy change).
#
# Key policy model (design §4.1 "use by the CRM task role with an encryption-context condition; administration by the
# apply role (no Decrypt); deny everyone else"), one policy per key, four kinds of statement:
#   1. IamAdministration — the account root (= IAM decides) for the ADMINISTRATIVE verbs only, never a crypto verb or
#      CreateGrant. Who may run them is set by IAM: the CI apply role through aa-cis-infra-tf-apply-crm (create, tag,
#      alias, rotation, describe; its boundary DenyCrmKeyUseAndPolicyEdits forbids PutKeyPolicy / ScheduleKeyDeletion /
#      DisableKey / CreateGrant / any crypto use), the plan role through ReadOnlyAccess (Describe / Get / List for
#      refresh), the MFA admin role for policy edits (a local MFA apply, alarmed below). It also keeps the key
#      manageable if a role is renamed, and satisfies the CreateKey lockout safety check (root may PutKeyPolicy).
#   2. CrmRuntime* — crypto use only by the CRM task role (aws:PrincipalArn condition, so the role may be created
#      after the key): data = envelope keys with the context {tenant_id, purpose} (KeyProvider, CRM-06) and S3 SSE-KMS
#      on aa-crm-<env>-* buckets (documents, second layer); ingest = S3 SSE-KMS on aa-crm-<env>-* buckets (audit
#      export, ingest) and the SES receipt context (raw mail); seal = Sign / Verify / GetPublicKey (PAdES seal).
#   3. DenyCryptoOutsideCrmRuntime — explicit deny of every crypto verb to every principal that is not the task role
#      or the CRM break-glass role (aa-crm-<env>-breakglass, CRM-13b), AWS services excepted (SES encrypts raw mail as
#      ses.amazonaws.com; S3 SSE-KMS calls carry the caller's principal). The admin roles cannot decrypt either.
#      Not being denied is not an allow: break-glass gets exactly one Allow, CrmBreakGlassOneAgency on the data key
#      (Decrypt of the envelope keys whose context tenant_id equals its session tag; design v3 §5.5 L3). On ingest
#      and seal it has no Allow, so it is refused there (implicit deny; the root statement delegates no crypto verb).
#   4. DenyGrantsExceptAwsResources — kms:CreateGrant only for an AWS-integrated resource (none today).
# Any later change of a key policy is a local MFA apply (the CI apply role cannot PutKeyPolicy) and fires the
# key-admin alarm below by design.
#
# Alarms (design §4.1), EventBridge on CloudTrail management events -> SNS alerts topic (e-mail):
#   aa-crm-<env>-kms-key-admin   PutKeyPolicy, CreateGrant, ScheduleKeyDeletion, DisableKey and the other verbs that
#                                weaken a key (rotation off, alias move, key material) on any of the three keys, and
#                                TagResource / UntagResource: the CI boundary deny on CRM keys keys on App = crm
#                                (cicd_crm.tf), so removing or overwriting that tag must never be silent;
#   aa-crm-<env>-kms-foreign-use a crypto call (incl. denied attempts) on any of the three keys by a principal that is
#                                not the CRM task role or an AWS service. Read-only events, so the rule is in state
#                                ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS (as identity_alerts.tf). Break-glass use
#                                alerts too, on purpose.
# Not here (other cards): the nightly GetKeyPolicy diff and the Decrypt-rate anomaly alarm (CRM-04 rest), the buckets
# (CRM-04 rest / CRM-12), the ECS service, task role and ECR (AA-933).
#
# Cost (us-west-1, est.): 3 customer managed keys x $1/month = $3; automatic rotation of data + ingest adds $1/month per
# key for each of its first two rotations (from month 13); requests on Dev stay in the 20,000/month free tier
# (RSA Sign $0.15 per 10,000 is not in it; Dev signs a handful). Secret shell $0.40/month. EventBridge rules on AWS
# service events and the SNS e-mails: $0. Total ≈ $3.40/month now, ≈ $5.40/month from the second year.
# =============================================================================

locals {
  crm_task_role_name      = "${local.crm_name_prefix}-ecs-task-role" # AA-933 creates it (workload boundary)
  crm_task_role_arn       = "arn:aws:iam::${var.account_id}:role/${local.crm_task_role_name}"
  crm_breakglass_role_arn = "arn:aws:iam::${var.account_id}:role/${local.crm_name_prefix}-breakglass"
  # S3 SSE-KMS encryption context aws:s3:arn: the object ARN, or the BUCKET ARN when the bucket uses S3 Bucket Keys
  # (BucketKeyEnabled, the usual cost setting). Both forms are allowed so CRM-12 / AA-933 may pick either.
  crm_bucket_s3_arns     = ["arn:aws:s3:::${local.crm_name_prefix}-*", "arn:aws:s3:::${local.crm_name_prefix}-*/*"]
  crm_dek_purposes       = ["vault", "docs", "integration", "scrub", "ops_release", "export", "mail"] # design §4.1
  crm_kms_crypto_actions = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey*", "kms:ReEncrypt*", "kms:Sign"]
  crm_kms_admin_actions = [
    "kms:DescribeKey", "kms:GetKeyPolicy", "kms:GetKeyRotationStatus", "kms:GetPublicKey", "kms:ListKeyPolicies",
    "kms:ListResourceTags", "kms:ListGrants", "kms:ListKeyRotations",
    "kms:EnableKeyRotation", "kms:DisableKeyRotation", "kms:RotateKeyOnDemand", "kms:UpdateKeyDescription",
    "kms:TagResource", "kms:UntagResource", "kms:CreateAlias", "kms:DeleteAlias", "kms:UpdateAlias",
    "kms:PutKeyPolicy", "kms:ScheduleKeyDeletion", "kms:CancelKeyDeletion", "kms:EnableKey", "kms:DisableKey",
    "kms:RevokeGrant", "kms:RetireGrant",
  ]
  crm_kms_keys = {
    data   = aws_kms_key.crm_data
    ingest = aws_kms_key.crm_ingest
    seal   = aws_kms_key.crm_seal
  }
  crm_s3_via_service = "s3.${var.aws_region}.amazonaws.com"
}

# ── Runtime DSN secret (shell only) ──────────────────────────────────────────────────────────────
# Same rule as booking_db: no secret_version, Terraform never holds the DSN. Nghiệp writes the crm_app DSN in the
# Console (password >= 32 printable ASCII), then DB Migrate mode=set-password role=crm_app (db/owners.yaml
# password_roles) sets the role's password from it. Readers: the migrator task role (set-password, isolation probe
# login, db_migrator.tf) and, from AA-933, the CRM execution role only. The CIS task role is denied crm/*
# (modules/ecs DenyMasterAndOtherAppSecrets).
resource "aws_secretsmanager_secret" "crm_db" {
  name                    = "crm/${var.environment}/database-url"
  description             = "AA-Partner (CRM) DB connection string (role crm_app, schema crm, shared RDS). Value set out-of-band (AA-932)."
  recovery_window_in_days = var.environment == "dev" ? 0 : 30
  tags                    = merge(local.crm_tags, { Issue = "AA-932" })
}

# ── Key policies ─────────────────────────────────────────────────────────────────────────────────
data "aws_iam_policy_document" "crm_kms_common" {
  statement {
    sid       = "IamAdministration"
    actions   = local.crm_kms_admin_actions
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.account_id}:root"]
    }
  }

  statement {
    sid       = "DenyCryptoOutsideCrmRuntime"
    effect    = "Deny"
    actions   = local.crm_kms_crypto_actions
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "ArnNotEquals"
      variable = "aws:PrincipalArn"
      values   = [local.crm_task_role_arn, local.crm_breakglass_role_arn]
    }
    condition {
      test     = "Bool"
      variable = "aws:PrincipalIsAWSService"
      values   = ["false"]
    }
  }

  statement {
    sid       = "DenyGrantsExceptAwsResources"
    effect    = "Deny"
    actions   = ["kms:CreateGrant"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["false"]
    }
  }
}

# data: per-tenant data keys (KeyProvider, CRM-06) + documents SSE-KMS (second layer, CRM-09).
data "aws_iam_policy_document" "crm_kms_data" {
  source_policy_documents = [data.aws_iam_policy_document.crm_kms_common.json]

  statement {
    sid       = "CrmRuntimeEnvelopeKeys"
    actions   = ["kms:GenerateDataKey", "kms:GenerateDataKeyWithoutPlaintext", "kms:Decrypt", "kms:Encrypt", "kms:ReEncrypt*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.account_id}:root"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:PrincipalArn"
      values   = [local.crm_task_role_arn]
    }
    # Exactly the KeyProvider context {tenant_id, purpose}: no other key, both present, a known purpose.
    condition {
      test     = "ForAllValues:StringEquals"
      variable = "kms:EncryptionContextKeys"
      values   = ["tenant_id", "purpose"]
    }
    condition {
      test     = "Null"
      variable = "kms:EncryptionContext:tenant_id"
      values   = ["false"]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:purpose"
      values   = local.crm_dek_purposes
    }
  }

  statement {
    sid       = "CrmRuntimeS3Objects"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.account_id}:root"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:PrincipalArn"
      values   = [local.crm_task_role_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = [local.crm_s3_via_service]
    }
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:s3:arn"
      values   = local.crm_bucket_s3_arns
    }
  }

  # L3 break-glass (design v3 §5.5, CRM-13b): Decrypt of ONE agency's envelope keys per session. The role carries the
  # session tag tenant_id (its trust policy requires sts:TagSession, MFA admin role only, <= 1 hour); the context
  # tenant_id must equal it. MFA: BoolIfExists, so a session that reports no MFA is refused while a chained session
  # (assumed from the MFA admin role) still works; the trust policy is where MFA is enforced. Every use fires the
  # foreign-use alarm (not the task role). No Encrypt / GenerateDataKey: break-glass reads, it never writes.
  statement {
    sid       = "CrmBreakGlassOneAgency"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.account_id}:root"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:PrincipalArn"
      values   = [local.crm_breakglass_role_arn]
    }
    condition {
      test     = "BoolIfExists"
      variable = "aws:MultiFactorAuthPresent"
      values   = ["true"]
    }
    condition {
      test     = "Null"
      variable = "aws:PrincipalTag/tenant_id"
      values   = ["false"]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:tenant_id"
      values   = ["$${aws:PrincipalTag/tenant_id}"]
    }
    condition {
      test     = "ForAllValues:StringEquals"
      variable = "kms:EncryptionContextKeys"
      values   = ["tenant_id", "purpose"]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:purpose"
      values   = local.crm_dek_purposes
    }
  }
}

# ingest: raw inbound mail (SES receipt rule -> S3 under the bucket default SSE-KMS, ≤ 1 day; AA-945 crm_mail.tf) and
# the audit export (Object Lock buckets, SSE-KMS).
data "aws_iam_policy_document" "crm_kms_ingest" {
  source_policy_documents = [data.aws_iam_policy_document.crm_kms_common.json]

  statement {
    sid       = "CrmRuntimeS3Objects"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.account_id}:root"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:PrincipalArn"
      values   = [local.crm_task_role_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = [local.crm_s3_via_service]
    }
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:s3:arn"
      values   = local.crm_bucket_s3_arns
    }
  }

  # The CRM reads the raw mail SES stored (S3 client-side encryption context of an SES receipt in this account). Unused
  # since AA-945 chose the bucket default SSE-KMS (crm_mail.tf, no kms_key_arn on the S3 action); harmless, kept.
  statement {
    sid       = "CrmRuntimeReadSesMail"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.account_id}:root"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:PrincipalArn"
      values   = [local.crm_task_role_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:aws:ses:source-account"
      values   = [var.account_id]
    }
  }

  # SES writes the raw mail of the CRM receipt rules (aa-crm-<env>-*, any rule set of this account: the region has
  # one active set, aa-cis-dev-e2e) into the ingest bucket, whose default encryption is SSE-KMS under this key. Statement
  # from the SES developer guide ("Give permission to Amazon SES to use your AWS KMS key"); AA-945 adds kms:Decrypt,
  # which the guide requires for "an S3 bucket with server-side encryption enabled".
  statement {
    sid       = "SesReceiptEncrypt"
    actions   = ["kms:Encrypt", "kms:GenerateDataKey*", "kms:Decrypt"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["ses.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:ses:${var.aws_region}:${var.account_id}:receipt-rule-set/*:receipt-rule/${local.crm_name_prefix}-*"]
    }
  }
}

# seal: asymmetric signing key for the platform PAdES seal on signed agreements (e-sign, CRM-26).
data "aws_iam_policy_document" "crm_kms_seal" {
  source_policy_documents = [data.aws_iam_policy_document.crm_kms_common.json]

  statement {
    sid       = "CrmRuntimeSign"
    actions   = ["kms:Sign", "kms:Verify", "kms:GetPublicKey", "kms:DescribeKey"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.account_id}:root"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:PrincipalArn"
      values   = [local.crm_task_role_arn]
    }
  }
}

# ── Keys + aliases ───────────────────────────────────────────────────────────────────────────────
resource "aws_kms_key" "crm_data" {
  description              = "AA-Partner (CRM) ${var.environment} data key: wraps the per-tenant data keys {tenant_id, purpose} and documents SSE-KMS (AA-932, design v3 §4.1)"
  key_usage                = "ENCRYPT_DECRYPT"
  customer_master_key_spec = "SYMMETRIC_DEFAULT"
  enable_key_rotation      = true
  deletion_window_in_days  = 30
  policy                   = data.aws_iam_policy_document.crm_kms_data.json
  tags                     = merge(local.crm_tags, { Name = "crm-${var.environment}-data", Issue = "AA-932" })
}

resource "aws_kms_key" "crm_ingest" {
  description              = "AA-Partner (CRM) ${var.environment} ingest key: raw inbound mail (<= 1 day) and the audit export (AA-932, design v3 §4.1)"
  key_usage                = "ENCRYPT_DECRYPT"
  customer_master_key_spec = "SYMMETRIC_DEFAULT"
  enable_key_rotation      = true
  deletion_window_in_days  = 30
  policy                   = data.aws_iam_policy_document.crm_kms_ingest.json
  tags                     = merge(local.crm_tags, { Name = "crm-${var.environment}-ingest", Issue = "AA-932" })
}

# Asymmetric keys cannot rotate automatically; a new seal key is a new key + alias move (UpdateAlias alarms).
resource "aws_kms_key" "crm_seal" {
  description              = "AA-Partner (CRM) ${var.environment} seal key: platform PAdES seal on signed agreements (AA-932, design v3 §4.1)"
  key_usage                = "SIGN_VERIFY"
  customer_master_key_spec = "RSA_3072"
  deletion_window_in_days  = 30
  policy                   = data.aws_iam_policy_document.crm_kms_seal.json
  tags                     = merge(local.crm_tags, { Name = "crm-${var.environment}-seal", Issue = "AA-932" })
}

resource "aws_kms_alias" "crm" {
  for_each      = local.crm_kms_keys
  name          = "alias/crm-${var.environment}/${each.key}"
  target_key_id = each.value.key_id
}

# ── Alarms ───────────────────────────────────────────────────────────────────────────────────────
locals {
  crm_kms_key_arns_list = [for k in local.crm_kms_keys : k.arn]
  # CloudTrail logs requestParameters.keyId as the caller passed it (key id, key ARN or alias); resources[].ARN is the
  # key ARN. Match both.
  crm_kms_key_match = concat(
    [for k in local.crm_kms_keys : { prefix = k.key_id }],
    [for k in local.crm_kms_keys : { prefix = k.arn }],
    [{ prefix = "alias/crm-${var.environment}/" }],
    [{ prefix = "arn:aws:kms:${var.aws_region}:${var.account_id}:alias/crm-${var.environment}/" }],
  )
  crm_kms_alert_input_paths = {
    event     = "$.detail.eventName"
    principal = "$.detail.userIdentity.arn"
    key       = "$.detail.resources[0].ARN"
    ip        = "$.detail.sourceIPAddress"
    time      = "$.detail.eventTime"
    error     = "$.detail.errorCode"
  }
}

resource "aws_cloudwatch_event_rule" "crm_kms_key_admin" {
  name        = "${local.crm_name_prefix}-kms-key-admin"
  description = "CRM KMS keys (data, ingest, seal): key policy, grant, deletion, disable, rotation-off, alias or key-material change (CloudTrail). AA-932, design v3 §4.1.${local.runbook_suffix.crm_keys}"
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
        { resources = { ARN = local.crm_kms_key_arns_list } },
        { requestParameters = { keyId = local.crm_kms_key_match } },
        { requestParameters = { aliasName = [{ prefix = "alias/crm-${var.environment}/" }] } },
      ]
    }
  })

  tags = merge(local.crm_tags, { Issue = "AA-932" })
}

resource "aws_cloudwatch_event_target" "crm_kms_key_admin" {
  rule      = aws_cloudwatch_event_rule.crm_kms_key_admin.name
  target_id = "alerts-sns"
  arn       = aws_sns_topic.alerts.arn

  input_transformer {
    input_paths    = local.crm_kms_alert_input_paths
    input_template = "\"[aa-crm] CRM KMS key change: <event> on <key> by <principal> from <ip> at <time> (errorCode: <error>). Only a planned local MFA apply may change a CRM key; otherwise treat it as an incident (design v3 §4.1).${local.runbook_suffix.crm_keys}\""
  }
}

resource "aws_cloudwatch_event_rule" "crm_kms_foreign_use" {
  name        = "${local.crm_name_prefix}-kms-foreign-use"
  description = "CRM KMS keys: a crypto call (allowed or denied) by a principal other than the CRM task role or an AWS service. AA-932, design v3 §4.1.${local.runbook_suffix.crm_keys}"
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
      resources = { ARN = local.crm_kms_key_arns_list }
      "$or" = [
        { userIdentity = { type = [{ "anything-but" = ["AssumedRole", "AWSService"] }] } },
        { userIdentity = { type = ["AssumedRole"], sessionContext = { sessionIssuer = { arn = [{ "anything-but" = [local.crm_task_role_arn] }] } } } },
      ]
    }
  })

  tags = merge(local.crm_tags, { Issue = "AA-932" })
}

resource "aws_cloudwatch_event_target" "crm_kms_foreign_use" {
  rule      = aws_cloudwatch_event_rule.crm_kms_foreign_use.name
  target_id = "alerts-sns"
  arn       = aws_sns_topic.alerts.arn

  input_transformer {
    input_paths    = local.crm_kms_alert_input_paths
    input_template = "\"[aa-crm] CRM KMS key used by a foreign principal: <event> on <key> by <principal> from <ip> at <time> (errorCode: <error>). Only the CRM task role uses these keys; a break-glass use must have a ticket, anything else is an incident (design v3 §4.1).${local.runbook_suffix.crm_keys}\""
  }
}

output "crm_kms_aliases" {
  description = "AA-932: aliases of the CRM KMS keys (KeyProvider config of AA-Partner, AA-934)."
  value       = { for k, a in aws_kms_alias.crm : k => a.name }
}

output "crm_db_secret_name" {
  description = "AA-932: the crm_app DSN secret (shell; Nghiệp writes the value, then DB Migrate set-password)."
  value       = aws_secretsmanager_secret.crm_db.name
}
