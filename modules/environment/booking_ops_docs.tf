# =============================================================================
# AA-682 (S1 follow-up, found by the AA-697 drift check) — the Booking ops-docs bucket: supplier vouchers and
# confirmations (bk-026), payment evidence (bk-028), supplier bill documents and payout evidence (bk-030).
#
# Booking staff upload these through the Booking API (POST /booking/ops-files, base64 JSON, type sniffed from the
# bytes, server-side sha256; AA-Booking backend/app/ops/files.py). The API writes the object under
# ops-docs/<kind>/<file id>.<ext> (the key is fixed by a CHECK on booking.ops_files, migration bk-026) and staff read
# it back only through a 300 s presigned GET signed by the Booking task role (Content-Disposition: attachment, every
# download audited). Nothing here is served to a browser directly: no CORS, no website hosting, no CloudFront.
# Until this file was applied OPS_DOCS_BUCKET was unset and every upload / download answered 503
# ops_storage_unavailable.
#
# Bucket aa-booking-<env>-ops-docs-<account> (the bk-026 CHECK and the app's settings check expect that shape):
#   - Block Public Access (all four), BucketOwnerEnforced (no ACLs), TLS only (bucket policy).
#   - SSE-S3 (AES256) by default; a PutObject that names another algorithm is denied. The S252 design (D10) asked for
#     a customer managed KMS key; a new CMK is a new paid resource (~$1/month) that needs its own approval, and the
#     existing CMKs belong to the CRM (the workload boundary denies their use outside the CRM, cicd_split.tf
#     DenyCrmKeyUseAndPolicyEdits) or to CloudTrail. The confidentiality the CMK was for (no other role of the account
#     can read these PII objects) is enforced here by the bucket policy instead: DenyObjectAccessOutsideBookingTask
#     refuses every object read / write / delete to any principal that is not the Booking task role (the CIS task
#     role holds s3:GetObject / s3:PutObject on "*", modules/ecs, and the read-only roles s3:Get* on "*"). Moving to
#     SSE-KMS later = a CMK + key grants + bucket default, plus the app header (files.py) in the same release.
#   - Versioning on: an object that is deleted (removal job, erasure; not built yet) or overwritten is recoverable for
#     30 days and then gone for good (noncurrent versions expire after 30 days, the DM-6.7 erasure bound; incomplete
#     multipart uploads after 1 day; expired delete markers are cleaned). Current objects never expire by lifecycle:
#     retention is decided per row (root data standards DM-7, AA-682 rows): money documents fall under the accounting
#     exception (proposed 10 years), vouchers / confirmations stay with the trip case, and a removed file outside the
#     accounting exception goes 30 days after its removal (row + object, a Booking job, later slice). Until those
#     windows are approved nothing is deleted.
#   - Object access: the Booking task role only, PutObject / GetObject on ops-docs/* (identity policy below). No
#     ListBucket, no delete: a removal is a status on the row (booking.ops_files), the object stays.
#   - Booking task definition env OPS_DOCS_BUCKET (booking.tf). A task definition change registers a revision the
#     service ignores; the next AA-Booking deploy copies the family's latest revision onto the task.
#
# Cost (us-west-1, est.): S3 Standard $0.023/GB-month; Dev holds a few MB of PDFs and photos (< $0.01), PUT
# $0.005/1,000 and GET $0.0004/1,000 requests (a handful a day), noncurrent versions only after a delete. Under
# $0.05/month. No KMS, no CloudFront, no new compute.
# =============================================================================

locals {
  bk_ops_docs_bucket = "${local.bk_name_prefix}-ops-docs-${var.account_id}"
  bk_ops_docs_prefix = "ops-docs/"
}

resource "aws_s3_bucket" "booking_ops_docs" {
  bucket = local.bk_ops_docs_bucket
  # Never force_destroy: the objects are referenced by booking.ops_files rows, some under the accounting exception.
  force_destroy = false

  tags = merge(local.bk_tags, { Name = local.bk_ops_docs_bucket, Issue = "AA-682" })
}

resource "aws_s3_bucket_public_access_block" "booking_ops_docs" {
  bucket                  = aws_s3_bucket.booking_ops_docs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "booking_ops_docs" {
  bucket = aws_s3_bucket.booking_ops_docs.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "booking_ops_docs" {
  bucket = aws_s3_bucket.booking_ops_docs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "booking_ops_docs" {
  bucket = aws_s3_bucket.booking_ops_docs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "booking_ops_docs" {
  bucket = aws_s3_bucket.booking_ops_docs.id

  rule {
    id     = "noncurrent-30d"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    expiration {
      expired_object_delete_marker = true
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  depends_on = [aws_s3_bucket_versioning.booking_ops_docs]
}

data "aws_iam_policy_document" "booking_ops_docs" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.booking_ops_docs.arn, "${aws_s3_bucket.booking_ops_docs.arn}/*"]
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

  # A PutObject that names an SSE algorithm other than SSE-S3 (no header = bucket default = fine).
  statement {
    sid       = "DenyOtherSseAlgorithm"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.booking_ops_docs.arn}/*"]
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
      values   = ["AES256"]
    }
  }

  # The objects hold traveller names and bank references (pii:payment, pii:name). Every object verb is refused to
  # every principal but the Booking task role: the CIS task role (s3:GetObject / s3:PutObject on "*"), the read-only
  # and plan roles (s3:Get* on "*") and the admin roles included. Bucket-level verbs (configuration, ListBucket) are
  # not in the list, so Terraform keeps managing the bucket. A staff download is a presigned GET signed by the
  # Booking task role, so it passes. Break-glass (erasure by hand, incident) = a reviewed edit of this statement.
  statement {
    sid    = "DenyObjectAccessOutsideBookingTask"
    effect = "Deny"
    actions = [
      "s3:GetObject*", "s3:PutObject*", "s3:DeleteObject*", "s3:RestoreObject", "s3:ReplicateObject",
    ]
    resources = ["${aws_s3_bucket.booking_ops_docs.arn}/*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "ArnNotEquals"
      variable = "aws:PrincipalArn"
      values   = [aws_iam_role.booking_ecs_task.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "booking_ops_docs" {
  bucket = aws_s3_bucket.booking_ops_docs.id
  policy = data.aws_iam_policy_document.booking_ops_docs.json

  # The public access block first, so the policy is never evaluated against an open bucket.
  depends_on = [aws_s3_bucket_public_access_block.booking_ops_docs]
}

# The Booking API writes and reads operations documents under ops-docs/ only (upload + the presigned download it
# signs). No ListBucket, no delete: a removal is a row status (booking.ops_files), the object stays.
resource "aws_iam_role_policy" "booking_ecs_task_ops_docs" {
  name = "${local.bk_name_prefix}-ecs-task-ops-docs"
  role = aws_iam_role.booking_ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "OpsDocsObjects"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "${aws_s3_bucket.booking_ops_docs.arn}/${local.bk_ops_docs_prefix}*"
      },
    ]
  })
}

output "booking_ops_docs_bucket" {
  description = "AA-682: the Booking ops-docs bucket (Booking env OPS_DOCS_BUCKET; booking.ops_files.s3_bucket names it)."
  value       = aws_s3_bucket.booking_ops_docs.bucket
}
