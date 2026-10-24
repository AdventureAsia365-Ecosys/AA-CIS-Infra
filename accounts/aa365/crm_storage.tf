# =============================================================================
# AA-932 (CRM-04, rest of the card) — the four AA-Partner (CRM) buckets and the KMS Decrypt-rate anomaly alarm.
#
# Design: root docs/audits/2026-10-21-S246-crm-design-v3/design-v3.md §3.6 (retention), §4.1 ("two Object Lock audit
# buckets (compliance + governance; governance only on Dev), a documents bucket and an ingest bucket (1-day
# lifecycle)"; "a KMS Decrypt-rate anomaly alarm"), §4.9 (hourly audit export to both buckets); data standards
# 02-data-management.md DM-7 rows `crm.audit_event` (archive: compliance 12 months + governance to 7 years in total,
# Dev governance only until go-live), raw inbound mail (<= 1 day under the ingest key), export files (7 days).
#
# Buckets (naming contract in cicd_crm.tf: aa-crm-<env>-*, audit buckets aa-crm-<env>-audit-<tier>-<account>):
#   audit-c   the 12-month tier. Object Lock default retention 365 days. GOVERNANCE on Dev; COMPLIANCE only with
#             var.crm_audit_compliance_enabled, which a precondition refuses on Dev (compliance cannot be lifted or
#             shortened by anyone, root included, and the bucket cannot be deleted while a version is locked).
#   audit-g   the 7-year tier. Object Lock GOVERNANCE, default retention 7 years.
#   documents agency documents: client-side encrypted by the app with the tenant `docs` DEK, then SSE-KMS with the data
#             key (second layer, design §4.1). Versioned; a replaced or deleted version is gone after 7 days (erased
#             data <= 30 days, DM-7). Export zips go under exports/ and expire after 7 days (DM-7 "export files"):
#             day 7 adds a delete marker and the then-noncurrent zip goes 1 day later (rule exports-7d; S3 applies
#             the shorter of the overlapping noncurrent expirations), so an export is gone by day 8, not day 14.
#   ingest    raw inbound mail from the CRM SES receipt rules (aa-crm-<env>-*, CRM-17): SSE-KMS with the ingest key,
#             not versioned, every object expires after 1 day (DM-7 "raw inbound mail <= 1 day").
# Both audit buckets use the ingest key (design §4.1: "ingest for raw mail and the audit export"); every bucket uses
# S3 Bucket Keys (the key policies accept the bucket ARN as aws:s3:arn, crm_data.tf) so KMS sees about one request per
# bucket key period, not one per object.
#
# Every bucket: block public access (all four), BucketOwnerEnforced (no ACLs), TLS only, and a PutObject that names
# another KMS key or another SSE algorithm is denied (no header = the bucket default, the normal path).
# Object access for the CRM task role is NOT granted here: the cards that write each bucket add their own grant
# (CRM-09 documents: crm_app.tf CrmDocumentsObjects / CrmDocumentsSseKms, AA-937; CRM-12 audit export:
# crm_ecs_task_audit_export below, AA-940; CRM-17 SES ingest; the key policies already allow the role). The SES write
# statement on the ingest bucket is here because it is a bucket-policy statement of this bucket.
# Object Lock tamper guards that already exist: the CI apply boundary denies BypassGovernanceRetention,
# PutObjectRetention, PutObjectLegalHold, DeleteObject(Version) on aa-crm-<env>-audit-*/* (cicd_split.tf
# DenyCrmAuditObjectTampering); tools/terraform/plan_guard.py refuses a CI apply that would create a COMPLIANCE lock or
# change / delete any Object Lock configuration without allow_guarded.
#
# Decrypt-rate anomaly alarm (design §4.1): an EventBridge rule on CloudTrail Decrypt calls on the three CRM keys (any
# principal; read-only management events, so state ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS) writes each event to
# the log group /aws/events/aa-crm-<env>-kms-decrypt (365 days, security/audit class, DM-7); a metric filter counts
# them (AA/Crm/Kms DecryptCalls); a CloudWatch anomaly-detection alarm e-mails the alerts topic when the 5-minute sum
# leaves the upper band in 2 of 3 periods. The model needs about two weeks of data before it judges anything (state
# INSUFFICIENT_DATA until then); periods with no Decrypt are missing data = not breaching. Field reveals are local AES
# under a cached DEK (design §4.4), so a Decrypt spike means a cache miss storm, a bulk export or someone else
# decrypting: the runbook (crm-keys.md) says how to tell them apart.
#
# Cost (us-west-1, est.): four empty buckets ≈ $0 (Object Lock has no fee; hourly manifests are a few KB; S3 Standard
# $0.023/GB-month). Bucket Keys keep KMS requests in the free tier. Alarm: an anomaly-detection alarm is billed as
# 3 standard metrics = $0.30/month; the metric-filter metric $0.30/month; log ingestion $0.50/GB (a Decrypt event is
# ~2 KB, Dev makes a handful) ≈ $0; EventBridge rule on AWS service events $0. Total ≈ $0.60/month.
# =============================================================================

variable "crm_audit_compliance_enabled" {
  description = "AA-932: put the 12-month audit bucket (aa-crm-<env>-audit-c-*) in COMPLIANCE mode. Irreversible for every locked version (nobody, root included, can shorten or lift it). Go-real only (CRM-38); a precondition refuses it on Dev (design v3 §3.6: Dev governance only)."
  type        = bool
  default     = false
}

locals {
  crm_bucket_names = {
    audit-c   = "${local.crm_name_prefix}-audit-c-${var.account_id}"
    audit-g   = "${local.crm_name_prefix}-audit-g-${var.account_id}"
    documents = "${local.crm_name_prefix}-documents-${var.account_id}"
    ingest    = "${local.crm_name_prefix}-ingest-${var.account_id}"
  }

  # Which CRM key encrypts each bucket by default (design §4.1).
  crm_bucket_key_arn = {
    audit-c   = aws_kms_key.crm_ingest.arn
    audit-g   = aws_kms_key.crm_ingest.arn
    documents = aws_kms_key.crm_data.arn
    ingest    = aws_kms_key.crm_ingest.arn
  }

  crm_versioned_buckets = toset(["audit-c", "audit-g", "documents"])

  # Object Lock default retention per audit tier. audit-c is the only bucket that may ever be COMPLIANCE.
  crm_audit_lock = {
    audit-c = { mode = var.crm_audit_compliance_enabled ? "COMPLIANCE" : "GOVERNANCE", days = 365, years = null }
    audit-g = { mode = "GOVERNANCE", days = null, years = 7 }
  }
  # Current versions expire one day after their retention ends (365 days; 7 x 365 + 2 leap days = 2557 days).
  # Lifecycle never removes a version that is still locked.
  crm_audit_expire_days = {
    audit-c = 366
    audit-g = 2558
  }

  # SES receipt rules of the CRM (CRM-17), any rule set of this account (same pattern as the ingest key policy).
  crm_ses_rule_arns = "arn:aws:ses:${var.aws_region}:${var.account_id}:receipt-rule-set/*:receipt-rule/${local.crm_name_prefix}-*"

  crm_decrypt_log_group = "/aws/events/${local.crm_name_prefix}-kms-decrypt"
}

# ── Buckets: common settings ─────────────────────────────────────────────────────────────────────
resource "aws_s3_bucket" "crm" {
  for_each = local.crm_bucket_names

  bucket = each.value
  # An Object Lock bucket must be created with it (a later switch needs a support-style flow); only the audit tiers.
  object_lock_enabled = contains(keys(local.crm_audit_lock), each.key)
  # Never force_destroy: audit versions are locked anyway, and documents are agency data.
  force_destroy = false

  tags = merge(local.crm_tags, { Name = each.value, Issue = "AA-932" })
}

resource "aws_s3_bucket_public_access_block" "crm" {
  for_each = aws_s3_bucket.crm

  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "crm" {
  for_each = aws_s3_bucket.crm

  bucket = each.value.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "crm" {
  for_each = aws_s3_bucket.crm

  bucket = each.value.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = local.crm_bucket_key_arn[each.key]
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "crm" {
  for_each = local.crm_versioned_buckets

  bucket = aws_s3_bucket.crm[each.key].id
  versioning_configuration {
    status = "Enabled" # Object Lock requires it; documents keep 7 days of replaced versions
  }
}

# ── Audit tiers: Object Lock ─────────────────────────────────────────────────────────────────────
resource "aws_s3_bucket_object_lock_configuration" "crm_audit" {
  for_each = local.crm_audit_lock

  bucket = aws_s3_bucket.crm[each.key].id

  rule {
    default_retention {
      mode  = each.value.mode
      days  = each.value.days
      years = each.value.years
    }
  }

  lifecycle {
    precondition {
      condition     = each.value.mode == "GOVERNANCE" || (each.key == "audit-c" && var.environment != "dev")
      error_message = "Only the 12-month audit bucket may use COMPLIANCE, and never on Dev (design v3 §3.6: Dev governance only until go-live)."
    }
  }

  depends_on = [aws_s3_bucket_versioning.crm]
}

# ── Lifecycle ────────────────────────────────────────────────────────────────────────────────────
resource "aws_s3_bucket_lifecycle_configuration" "crm_audit" {
  for_each = local.crm_audit_expire_days

  bucket = aws_s3_bucket.crm[each.key].id

  rule {
    id     = "expire-after-retention"
    status = "Enabled"
    filter {}

    expiration {
      days = each.value
    }
    noncurrent_version_expiration {
      noncurrent_days = 1
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  rule {
    id     = "remove-expired-delete-markers"
    status = "Enabled"
    filter {}

    expiration {
      expired_object_delete_marker = true
    }
  }

  depends_on = [aws_s3_bucket_versioning.crm]
}

resource "aws_s3_bucket_lifecycle_configuration" "crm_documents" {
  bucket = aws_s3_bucket.crm["documents"].id

  rule {
    id     = "replaced-versions-7d"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 7
    }
    expiration {
      expired_object_delete_marker = true
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  # DM-7 "export files: 7 days" (owner-only download, 7-day link, design §4.10). The bucket is versioned, so the
  # day-7 expiration only adds a delete marker; noncurrent_version_expiration removes the zip itself 1 day later
  # (without it, replaced-versions-7d would keep it to about day 14).
  rule {
    id     = "exports-7d"
    status = "Enabled"
    filter {
      prefix = "exports/"
    }

    expiration {
      days = 7
    }
    noncurrent_version_expiration {
      noncurrent_days = 1
    }
  }

  depends_on = [aws_s3_bucket_versioning.crm]
}

resource "aws_s3_bucket_lifecycle_configuration" "crm_ingest" {
  bucket = aws_s3_bucket.crm["ingest"].id

  rule {
    id     = "raw-mail-1d"
    status = "Enabled"
    filter {}

    expiration {
      days = 1
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# ── Bucket policies ──────────────────────────────────────────────────────────────────────────────
data "aws_iam_policy_document" "crm_bucket" {
  for_each = aws_s3_bucket.crm

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [each.value.arn, "${each.value.arn}/*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # A PutObject that names an SSE algorithm other than SSE-KMS (no header = bucket default = fine).
  statement {
    sid       = "DenyOtherSseAlgorithm"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${each.value.arn}/*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "Null"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["false"]
    }
    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
  }

  # A PutObject that names another KMS key than this bucket's CRM key.
  statement {
    sid       = "DenyOtherKmsKey"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${each.value.arn}/*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "Null"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = ["false"]
    }
    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = [local.crm_bucket_key_arn[each.key]]
    }
  }

  # SES writes raw mail of the CRM receipt rules only (confused-deputy guard, as e2e_mailbox.tf).
  dynamic "statement" {
    for_each = each.key == "ingest" ? [1] : []
    content {
      sid       = "AllowSesPutFromCrmRules"
      actions   = ["s3:PutObject"]
      resources = ["${each.value.arn}/*"]
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
        values   = [local.crm_ses_rule_arns]
      }
    }
  }
}

resource "aws_s3_bucket_policy" "crm" {
  for_each = aws_s3_bucket.crm

  bucket = each.value.id
  policy = data.aws_iam_policy_document.crm_bucket[each.key].json

  depends_on = [aws_s3_bucket_public_access_block.crm]
}

# ── KMS Decrypt-rate anomaly alarm ───────────────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "crm_kms_decrypt" {
  name              = local.crm_decrypt_log_group
  retention_in_days = 365 # security/audit class (CloudTrail-derived KMS events), DM-7 / S241 D-09
  tags              = merge(local.crm_tags, { Issue = "AA-932" })
}

# EventBridge needs a CloudWatch Logs resource policy to deliver to a log group (one account-wide policy per name).
data "aws_iam_policy_document" "crm_kms_decrypt_logs" {
  statement {
    sid       = "EventBridgeToCrmKmsDecryptLog"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.crm_kms_decrypt.arn}:*"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "delivery.logs.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.crm_kms_decrypt.arn]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "crm_kms_decrypt" {
  policy_name     = "${local.crm_name_prefix}-kms-decrypt-events"
  policy_document = data.aws_iam_policy_document.crm_kms_decrypt_logs.json
}

resource "aws_cloudwatch_event_rule" "crm_kms_decrypt" {
  name        = "${local.crm_name_prefix}-kms-decrypt-log"
  description = "CRM KMS keys: every Decrypt (any principal) to ${local.crm_decrypt_log_group}; the metric filter feeds the Decrypt-rate anomaly alarm. AA-932, design v3 §4.1."
  state       = "ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS"

  event_pattern = jsonencode({
    source        = ["aws.kms"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["kms.amazonaws.com"]
      eventName   = ["Decrypt"]
      resources   = { ARN = local.crm_kms_key_arns_list }
    }
  })

  tags = merge(local.crm_tags, { Issue = "AA-932" })
}

resource "aws_cloudwatch_event_target" "crm_kms_decrypt" {
  rule      = aws_cloudwatch_event_rule.crm_kms_decrypt.name
  target_id = "decrypt-log"
  arn       = aws_cloudwatch_log_group.crm_kms_decrypt.arn

  depends_on = [aws_cloudwatch_log_resource_policy.crm_kms_decrypt]
}

resource "aws_cloudwatch_log_metric_filter" "crm_kms_decrypt" {
  name           = "${local.crm_name_prefix}-kms-decrypt-calls"
  log_group_name = aws_cloudwatch_log_group.crm_kms_decrypt.name
  pattern        = "{ $.detail.eventName = \"Decrypt\" }"

  metric_transformation {
    name      = "DecryptCalls"
    namespace = "AA/Crm/Kms"
    value     = "1"
    unit      = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "crm_kms_decrypt_anomaly" {
  alarm_name          = "${local.crm_name_prefix}-kms-decrypt-anomaly"
  alarm_description   = "CRM KMS Decrypt calls (data, ingest, seal) above the anomaly band in 2 of 3 five-minute periods: a DEK cache miss storm, a bulk export, or someone decrypting. Read the events in ${local.crm_decrypt_log_group}. AA-932, design v3 §4.1.${local.runbook_suffix.crm_keys}"
  comparison_operator = "GreaterThanUpperThreshold"
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  threshold_metric_id = "band"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  metric_query {
    id          = "band"
    expression  = "ANOMALY_DETECTION_BAND(decrypts, 3)"
    label       = "DecryptCalls (expected)"
    return_data = true
  }

  metric_query {
    id          = "decrypts"
    return_data = true
    metric {
      namespace   = aws_cloudwatch_log_metric_filter.crm_kms_decrypt.metric_transformation[0].namespace
      metric_name = aws_cloudwatch_log_metric_filter.crm_kms_decrypt.metric_transformation[0].name
      period      = 300
      stat        = "Sum"
    }
  }

  tags = merge(local.crm_tags, { Issue = "AA-932" })
}

output "crm_bucket_names" {
  description = "AA-932: the AA-Partner buckets (audit-c, audit-g, documents, ingest)."
  value       = { for k, b in aws_s3_bucket.crm : k => b.bucket }
}

# =============================================================================
# AA-940 (CRM-12) — the audit export: the CRM task role writes and reads the hourly objects, and two alarms.
#
# Design v3 §4.9 ("hourly to both Object Lock buckets, with a chained SHA-256 manifest"); AA-Partner
# api/app/audit_export (export.py writes audit/v1/tenants/<tenant>/<yyyy>/<mm>/<dd>/<hh>00Z-<seq>.jsonl to both tiers,
# verify.py reads them back; the daily retention verifies before any partition drop).
#
# Grant: PutObject + GetObject under audit/v1/tenants/* in each audit bucket, nothing else: no List (a missing key
# then answers 403, the app treats it as missing), no DeleteObject / DeleteObjectVersion, no PutObjectRetention /
# PutObjectLegalHold / BypassGovernanceRetention, no bucket-level action. Every version the app writes is locked by the
# bucket default retention (GOVERNANCE 365 days on audit-c on Dev, 7 years on audit-g). SSE-KMS under the ingest key
# through S3 only and bound to the two audit buckets (the key policy's CrmRuntimeS3Objects allows the same for this
# role; both must allow). A separate policy resource, so the AA-937 documents grant in crm_app.tf does not collide.
#
# Alarms (namespace AA/Jobs/Crm, published by the API's job metrics sampler every 5 minutes, no IAM change):
#   audit-export-lag     AuditExportLagMinutes >= 180 (healthy is under ~75: the hour, the 15-minute lag, the hourly
#                        schedule). Missing data = not breaching (worker off / scaled to 0; jobs-sampling-stopped
#                        covers a dead sampler).
#   audit-partitions     AuditPartitionMonthsAhead < 1: next month has no audit partition, so every request that
#                        writes an audit event would fail from the 1st. The hourly export keeps three months ahead.
#
# Cost (us-west-1, est.): PUTs 24 x 2 per agency per day = ~1,440 per agency per month x $0.005 / 1,000 = ~$0.007 per
# agency (3 synthetic agencies ~ $0.02); GETs of the daily verification about the same at $0.0004 / 1,000 ~ $0;
# storage a few KB per object, ~$0 (S3 Standard $0.023/GB-month); KMS requests stay in the free tier (S3 Bucket Keys);
# 2 alarms x $0.10 + 2 custom metrics x $0.30 = $0.80/month. Total ~ $0.85/month on Dev (100 agencies at prod:
# ~$0.75 of PUTs more).
# =============================================================================
resource "aws_iam_role_policy" "crm_ecs_task_audit_export" {
  name = "${local.crm_service}-audit-export"
  role = aws_iam_role.crm_ecs_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CrmAuditExportObjects"
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:GetObject"]
        Resource = [
          "${aws_s3_bucket.crm["audit-c"].arn}/audit/v1/tenants/*",
          "${aws_s3_bucket.crm["audit-g"].arn}/audit/v1/tenants/*",
        ]
      },
      {
        Sid      = "CrmAuditExportSseKms"
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = aws_kms_key.crm_ingest.arn
        Condition = {
          "StringEquals" = { "kms:ViaService" = local.crm_s3_via_service }
          "ArnLike" = {
            "kms:EncryptionContext:aws:s3:arn" = [
              aws_s3_bucket.crm["audit-c"].arn,
              "${aws_s3_bucket.crm["audit-c"].arn}/*",
              aws_s3_bucket.crm["audit-g"].arn,
              "${aws_s3_bucket.crm["audit-g"].arn}/*",
            ]
          }
        }
      },
    ]
  })
}

resource "aws_cloudwatch_metric_alarm" "crm_audit_export_lag" {
  alarm_name          = "${local.crm_name_prefix}-audit-export-lag"
  alarm_description   = "AA-Partner: the hourly agency audit export is 3 hours or more behind (AA/Jobs/Crm AuditExportLagMinutes, design v3 §4.9). Check the crm_audit_export job rows (failed_count, error class) and the audit_export_failed log lines in /ecs/${local.crm_name_prefix}; a partition cannot be dropped while an agency is behind.${local.runbook_suffix.incident}"
  namespace           = "AA/Jobs/Crm"
  metric_name         = "AuditExportLagMinutes"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 180
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = merge(local.crm_tags, { Issue = "AA-940" })
}

resource "aws_cloudwatch_metric_alarm" "crm_audit_partitions" {
  alarm_name          = "${local.crm_name_prefix}-audit-partitions"
  alarm_description   = "AA-Partner: next month has no crm.audit_event partition (AA/Jobs/Crm AuditPartitionMonthsAhead < 1). From the 1st every audit write, and so the request that writes it, fails. Run SELECT crm.audit_ensure_partitions() as crm_app (ECS exec) or let the hourly crm_audit_export job run, then check the job rows.${local.runbook_suffix.incident}"
  namespace           = "AA/Jobs/Crm"
  metric_name         = "AuditPartitionMonthsAhead"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = merge(local.crm_tags, { Issue = "AA-940" })
}
