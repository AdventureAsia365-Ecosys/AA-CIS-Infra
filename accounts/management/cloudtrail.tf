# =============================================================================
# AA-1004 — organization CloudTrail, delivered to a bucket in the management account.
#
# Lean model: no separate log-archive account yet (blueprint §0 "Khi nào mới mở rộng"), so the trail bucket lives
# here. Multi-region, management events only (read + write), global service events, log file validation, SSE-KMS
# with a key of this account, Object Lock GOVERNANCE for the retention period, then expiry.
# Same hardening as the nonprod account's own trail (accounts/aa365/security_cloudtrail.tf, AA-873).
#
# Cost: about 1-2 USD/month. KMS key 1 USD; management events of the first trail per account are free, but a
# member account that keeps its own trail (the nonprod account's aa-cis-dev-trail) pays the org copy at
# 2 USD per 100k events until that trail is removed (README §8, after 7 days of org-trail delivery); S3 storage
# of a few GB a year. No data events, no CloudTrail Lake, no CloudWatch Logs delivery.
# =============================================================================

locals {
  trail_name       = "aa-org-trail"
  trail_arn        = "arn:aws:cloudtrail:${var.region}:${var.management_account_id}:trail/${local.trail_name}"
  trail_bucket     = "aa-org-cloudtrail-${var.management_account_id}"
  trail_bucket_arn = "arn:aws:s3:::${local.trail_bucket}"
}

data "aws_iam_policy_document" "trail_kms" {
  statement {
    sid       = "AccountAdministration"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.management_account_id}:root"]
    }
  }

  # CloudTrail encrypts the log files of THIS trail only (it writes them for every member account too).
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
      values   = ["arn:aws:cloudtrail:*:${var.management_account_id}:trail/*"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
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
      values   = [local.trail_arn]
    }
  }
}

resource "aws_kms_key" "trail" {
  description             = "AA-1004: log files of the organization trail ${local.trail_name}"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.trail_kms.json
}

resource "aws_kms_alias" "trail" {
  name          = "alias/aa-org-cloudtrail"
  target_key_id = aws_kms_key.trail.key_id
}

resource "aws_s3_bucket" "trail" {
  bucket = local.trail_bucket

  # Object Lock can only be switched on, never off; a new bucket gets it at creation.
  object_lock_enabled = true

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "trail" {
  bucket                  = aws_s3_bucket.trail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ACLs off. CloudTrail still sends x-amz-acl=bucket-owner-full-control, which BucketOwnerEnforced accepts.
resource "aws_s3_bucket_ownership_controls" "trail" {
  bucket = aws_s3_bucket.trail.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "trail" {
  bucket = aws_s3_bucket.trail.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "trail" {
  bucket = aws_s3_bucket.trail.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.trail.arn
    }
    bucket_key_enabled = true
  }
}

# GOVERNANCE, never COMPLIANCE: a COMPLIANCE lock cannot be lifted even by the root user (plan_guard.py refuses it
# on the CI apply path as well). Security/audit class retention: 365 days (data standards D-09).
resource "aws_s3_bucket_object_lock_configuration" "trail" {
  bucket = aws_s3_bucket.trail.id

  rule {
    default_retention {
      mode = "GOVERNANCE"
      days = var.cloudtrail_retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.trail]
}

# 90 days in Standard, then Glacier Instant Retrieval, expired after the retention period (blueprint §4).
resource "aws_s3_bucket_lifecycle_configuration" "trail" {
  bucket = aws_s3_bucket.trail.id

  rule {
    id     = "trail-retention"
    status = "Enabled"
    filter {}

    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }

    expiration {
      days = var.cloudtrail_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.trail]
}

# Bucket policy of an organization trail (CloudTrail user guide, "Amazon S3 bucket policy for CloudTrail",
# organization trail form): ACL check + writes under AWSLogs/<management account>/ and AWSLogs/<organization id>/,
# both bound to this trail by aws:SourceArn; plus TLS only.
data "aws_iam_policy_document" "trail_bucket" {
  statement {
    sid       = "AWSCloudTrailAclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = [local.trail_bucket_arn]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }

  statement {
    sid     = "AWSCloudTrailWrite"
    actions = ["s3:PutObject"]
    resources = [
      "${local.trail_bucket_arn}/AWSLogs/${var.management_account_id}/*",
      "${local.trail_bucket_arn}/AWSLogs/${aws_organizations_organization.this.id}/*",
    ]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [local.trail_bucket_arn, "${local.trail_bucket_arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "trail" {
  bucket = aws_s3_bucket.trail.id
  policy = data.aws_iam_policy_document.trail_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.trail]
}

resource "aws_cloudtrail" "organization" {
  name                          = local.trail_name
  s3_bucket_name                = aws_s3_bucket.trail.id
  kms_key_id                    = aws_kms_key.trail.arn
  is_organization_trail         = true
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true

  # Needs trusted access for cloudtrail.amazonaws.com (organization.tf) and the bucket/key policies in place.
  depends_on = [
    aws_organizations_organization.this,
    aws_s3_bucket_policy.trail,
    aws_s3_bucket_server_side_encryption_configuration.trail,
  ]
}
