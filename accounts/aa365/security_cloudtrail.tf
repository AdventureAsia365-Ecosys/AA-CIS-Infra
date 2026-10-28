# =============================================================================
# AA-873 PR 2 of 3 (S255) — CloudTrail hardening: KMS key, multi-region trail, versioned + Object Lock bucket.
#
# Live state read 28/10/2026 (root audit docs/audits/2026-10-28-S255-finops-security/ §7): trail aa-cis-dev-trail is
# single-region, global service events on, log file validation on, SSE-S3 only (no KMS), no CloudWatch Logs,
# management events read + write. Its bucket has versioning OFF and Object Lock OFF.
#
# This file (+ the two edits marked "AA-873 PR 2" in observability.tf: aws_cloudtrail.main and the bucket lifecycle):
#   1. aws_kms_key.cloudtrail + alias: symmetric, rotation on, App = shared (the apply-role grants in cicd_sec.tf key
#      on that tag). Key policy: account root (IAM decides: the MFA admin role reads logs, the CI apply role only
#      administers) + CloudTrail GenerateDataKey for THIS trail only (aws:SourceArn + encryption context) +
#      CloudTrail DescribeKey. No "any principal in the account may decrypt" statement (the AWS console default):
#      decrypt needs an IAM grant.
#   2. aws_s3_bucket_versioning: Enabled (prerequisite of Object Lock).
#   3. aws_s3_bucket_object_lock_configuration: Object Lock on the EXISTING bucket, default retention GOVERNANCE
#      365 days (root data standards D-09 security/audit class). Enabling Object Lock can never be undone.
#
# Object Lock on an existing bucket — verified, no replacement:
#   - S3 accepts PutObjectLockConfiguration with ObjectLockEnabled = Enabled on an existing bucket once versioning
#     is Enabled (no AWS Support token since 2023). aws_s3_bucket_object_lock_configuration does exactly that call.
#   - aws_s3_bucket.cloudtrail_logs keeps object_lock_enabled UNSET. In provider hashicorp/aws 6.69.1 (the lock file
#     version) the attribute is Optional + Computed: a probe plan (-refresh=false, crafted state, 28/10/2026) showed
#     "No changes" for state false or true with the attribute unset, and an in-place update (not a replacement) for
#     false -> true when set. Setting it on the bucket is still avoided: the bucket update would run before the
#     versioning resource that depends on it and fail; the configuration resource below depends on versioning.
#   - tools/terraform/plan_guard.py lets a GOVERNANCE create of an object lock configuration through and refuses any
#     later update/delete/replace of it, and any delete of a bucket that has Object Lock.
#
# Cost: ~1.25 USD/month. KMS key 1 USD/month + ~10-20k GenerateDataKey/month at 0.03 USD/10k (one per log file;
# multi-region adds a few small files per region per day) ~0.05; multi-region management events are free (first
# copy); versioned storage ~6.7 GB/year in Standard ~0.15-0.2 USD/month.
#
# Apply: the KMS grants are in cicd_sec.tf (bootstrap, AA-873 PR 1): PR 1's local MFA apply must be done first.
# Then CI apply. Expected plan: 4 add (key, alias, versioning, object lock config), 2 change in place (trail:
# multi-region + kms_key_id; lifecycle rule). The trail-tamper rule of PR 1 e-mails "[aa-sec] trail_tamper:
# UpdateTrail by aa-cis-infra-tf-apply" once: expected.
# Check after apply: aws cloudtrail get-trail-status shows LatestDeliveryError empty and new objects under
# AWSLogs/<account>/CloudTrail/us-east-1/ with SSE-KMS; aws s3api get-object-lock-configuration shows GOVERNANCE 365.
# =============================================================================

data "aws_iam_policy_document" "cloudtrail_kms" {
  statement {
    sid       = "AccountAdministration"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.account_id}:root"]
    }
  }

  statement {
    sid       = "CloudTrailEncrypt"
    actions   = ["kms:GenerateDataKey*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:aws:cloudtrail:arn"
      values   = ["arn:aws:cloudtrail:*:${var.account_id}:trail/*"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.cloudtrail_trail_arn]
    }
  }

  statement {
    sid       = "CloudTrailDescribe"
    actions   = ["kms:DescribeKey"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.cloudtrail_trail_arn]
    }
  }
}

resource "aws_kms_key" "cloudtrail" {
  description             = "AA-873: CloudTrail log files of ${local.cloudtrail_trail_name}"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.cloudtrail_kms.json
  tags                    = local.sec_tags # App = shared: cicd_sec.tf grants key on it
}

resource "aws_kms_alias" "cloudtrail" {
  name          = "alias/${local.name_prefix}-cloudtrail"
  target_key_id = aws_kms_key.cloudtrail.key_id
}

resource "aws_s3_bucket_versioning" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_object_lock_configuration" "cloudtrail_logs" {
  bucket              = aws_s3_bucket.cloudtrail_logs.id
  object_lock_enabled = "Enabled"

  rule {
    default_retention {
      mode = "GOVERNANCE" # never COMPLIANCE on Dev (plan_guard refuses it)
      days = 365
    }
  }

  depends_on = [aws_s3_bucket_versioning.cloudtrail_logs]
}
