# =============================================================================
# AA-835 (root ADR 0004a decision 2) — the Booking supply-media bucket: supplier photos of hotels and services.
#
# Booking staff (contracting) upload supplier photos through the Booking API (AA-835 S4: POST
# /booking/{hotels|services}/{id}/media, size / type / magic-byte checks, server-side sha256). The API writes the
# object to this bucket under supply-media/<entity_type>/<entity_id>/<media_id>.<ext> (the key is fixed by a CHECK on
# booking.entity_media, migration bk-023) and records the row. CIS reads the object (booking.v_supply_media names
# bucket + key) only to copy a rights-cleared photo into its own published photo path (bronze photos/, img. CDN):
# nothing here is ever served to a browser, so there is no CORS, no website hosting and no CloudFront origin.
#
# Bucket aa-booking-<env>-supply-media-<account> (the bk-023 CHECK expects that shape):
#   - Block Public Access (all four), BucketOwnerEnforced (no ACLs), TLS only (bucket policy).
#   - SSE-S3 (AES256) by default; a PutObject that names another algorithm is denied. No KMS key: supplier photos
#     are business data (not personal data, not commercial secrets), and SSE-S3 has no request or key cost.
#   - Versioning on: an overwritten or deleted object can be recovered for 30 days (noncurrent versions expire after
#     30 days; incomplete multipart uploads after 1 day). Photos are never deleted by the app: a removal is a status
#     on the row, the object stays.
#   - Writers: the Booking task role only (identity policy below: PutObject / GetObject on supply-media/*). The CIS
#     task role reads through its existing broad grant (modules/ecs ecs_task_policy: s3:GetObject on *); the bucket
#     policy repeats that read for the record and DENIES the CIS task role every write and delete here, since that
#     same broad grant also carries s3:PutObject on *: the facts and photos are Booking's (ADR 0004a decision 1).
#   - Booking task definition env SUPPLY_MEDIA_BUCKET (booking.tf). A task definition change registers a revision
#     the service ignores; the next AA-Booking deploy copies the family's latest revision onto the task.
#
# Cost (us-west-1, est.): S3 Standard $0.023/GB-month; Dev holds a few MB of photos (< $0.01), PUT $0.005/1,000 and
# GET $0.0004/1,000 requests (a handful a day), noncurrent versions only after an overwrite. Under $0.05/month. No
# KMS, no CloudFront, no new compute.
# =============================================================================

locals {
  bk_supply_media_bucket = "${local.bk_name_prefix}-supply-media-${var.account_id}"
  bk_supply_media_prefix = "supply-media/"
}

resource "aws_s3_bucket" "booking_supply_media" {
  bucket = local.bk_supply_media_bucket
  # Never force_destroy: supplier photos are referenced by booking.entity_media rows and by CIS content.
  force_destroy = false

  tags = merge(local.bk_tags, { Name = local.bk_supply_media_bucket, Issue = "AA-835" })
}

resource "aws_s3_bucket_public_access_block" "booking_supply_media" {
  bucket                  = aws_s3_bucket.booking_supply_media.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "booking_supply_media" {
  bucket = aws_s3_bucket.booking_supply_media.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "booking_supply_media" {
  bucket = aws_s3_bucket.booking_supply_media.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "booking_supply_media" {
  bucket = aws_s3_bucket.booking_supply_media.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "booking_supply_media" {
  bucket = aws_s3_bucket.booking_supply_media.id

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

  depends_on = [aws_s3_bucket_versioning.booking_supply_media]
}

data "aws_iam_policy_document" "booking_supply_media" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.booking_supply_media.arn, "${aws_s3_bucket.booking_supply_media.arn}/*"]
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
    resources = ["${aws_s3_bucket.booking_supply_media.arn}/*"]
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

  # For the record: the CIS task role already reads every bucket (modules/ecs ecs_task_policy); this is the read the
  # supply content flow uses (booking.v_supply_media -> copy of a rights-cleared photo).
  statement {
    sid       = "AllowCisTaskReadSupplyMedia"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.booking_supply_media.arn}/${local.bk_supply_media_prefix}*"]
    principals {
      type        = "AWS"
      identifiers = [module.ecs.task_role_arn]
    }
  }

  # The same CIS grant carries s3:PutObject on *: CIS never writes or deletes Booking's supplier photos.
  statement {
    sid    = "DenyCisTaskWrites"
    effect = "Deny"
    actions = [
      "s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion", "s3:PutObjectTagging",
      "s3:RestoreObject",
    ]
    resources = ["${aws_s3_bucket.booking_supply_media.arn}/*"]
    principals {
      type        = "AWS"
      identifiers = [module.ecs.task_role_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "booking_supply_media" {
  bucket = aws_s3_bucket.booking_supply_media.id
  policy = data.aws_iam_policy_document.booking_supply_media.json

  # The public access block first, so the policy is never evaluated against an open bucket.
  depends_on = [aws_s3_bucket_public_access_block.booking_supply_media]
}

# The Booking API writes and reads supplier photos under supply-media/ only (AA-835 S4 upload + its own reads).
# No ListBucket, no delete: a removal is a row status (booking.entity_media), the object stays.
resource "aws_iam_role_policy" "booking_ecs_task_supply_media" {
  name = "${local.bk_name_prefix}-ecs-task-supply-media"
  role = aws_iam_role.booking_ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "SupplyMediaObjects"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "${aws_s3_bucket.booking_supply_media.arn}/${local.bk_supply_media_prefix}*"
      },
    ]
  })
}

output "booking_supply_media_bucket" {
  description = "AA-835: the Booking supply-media bucket (Booking env SUPPLY_MEDIA_BUCKET; booking.v_supply_media names it)."
  value       = aws_s3_bucket.booking_supply_media.bucket
}
