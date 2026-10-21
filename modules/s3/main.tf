# =============================================================================
# AA-CIS S3 Module — Medallion Architecture
# PRD v4.0 §2.3: Bronze / Silver / Gold layers
# Updated: 20/04/2026 — replace aa-cis-uploads/outputs with Medallion naming
# =============================================================================

locals {
  account_id = data.aws_caller_identity.current.account_id

  # S3 bucket names — globally unique, include account_id suffix
  bronze_bucket = "${var.project}-bronze-${local.account_id}"
  silver_bucket = "${var.project}-silver-${local.account_id}"
  gold_bucket   = "${var.project}-gold-${local.account_id}"

  common_tags = merge(var.tags, {
    Layer  = "storage"
    Module = "s3"
    PRD    = "v4.0"
  })
}

data "aws_caller_identity" "current" {}

# =============================================================================
# BRONZE BUCKET — Immutable raw intake
# Paths: raw-inbox/{tenant}/{batch}/{file}.xlsx
#        raw-archive/{tenant}/{date}/tours.jsonl
# =============================================================================

resource "aws_s3_bucket" "bronze" {
  bucket        = local.bronze_bucket
  force_destroy = var.environment == "dev" ? true : false

  tags = merge(local.common_tags, {
    Name  = local.bronze_bucket
    Layer = "bronze"
    Notes = "Immutable raw files - never delete in prod"
  })
}

resource "aws_s3_bucket_versioning" "bronze" {
  bucket = aws_s3_bucket.bronze.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Block all public access — Bronze is internal only
resource "aws_s3_bucket_public_access_block" "bronze" {
  bucket                  = aws_s3_bucket.bronze.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle: raw-archive → Glacier after 90 days (cost saving)
resource "aws_s3_bucket_lifecycle_configuration" "bronze" {
  bucket = aws_s3_bucket.bronze.id

  rule {
    id     = "archive-to-glacier"
    status = "Enabled"

    filter {
      prefix = "raw-archive/"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    # PRD: "lifecycle policy 7 years"
    expiration {
      days = 2555 # 7 years
    }
  }

  # AA-825 (DM-7.3, data-management.md "S3 archive objects"): the retention jobs write
  # Parquet to archive/<table>/yyyy/mm/ (archive-before-delete). They are read only for a
  # restore or a later Athena query (L6), so after 90 days they move to Standard-IA.
  # No expiration: the per-table expiry is still to be set (N4), and the archive is the
  # only copy of the deleted rows. ("archive/" does not match "raw-archive/": S3 prefixes
  # match from the start of the key.) Objects under 128 KB stay in Standard, the AWS
  # default transition minimum size, since IA would bill them as 128 KB anyway.
  rule {
    id     = "retention-archive-to-ia"
    status = "Enabled"

    filter {
      prefix = "archive/"
    }

    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }
  }
}

# Encryption at rest
resource "aws_s3_bucket_server_side_encryption_configuration" "bronze" {
  bucket = aws_s3_bucket.bronze.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Deny cross-tenant access via bucket policy
# Enforced by prefix: each service must pass tenant slug in path
#
# AA-844: the statements below are unchanged; concat() appends one statement only when the photos
# CDN is on (var.bronze_cloudfront_read), so the plan shows an in-place update of this policy.
resource "aws_s3_bucket_policy" "bronze" {
  bucket = aws_s3_bucket.bronze.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid       = "DenyUnencryptedTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.bronze.arn,
          "${aws_s3_bucket.bronze.arn}/*"
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
      # AA-302 — cross-account access for the Bedrock Batch inference service
      # role (account 1, accounts/acc1-bedrock). Scoped to the two batch
      # prefixes only, not the whole bucket.
      {
        Sid       = "AllowBedrockBatchCrossAccountAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::867490540162:role/aa-bedrock-batch-inference-role" }
        Action    = ["s3:GetObject", "s3:PutObject"]
        Resource = [
          "${aws_s3_bucket.bronze.arn}/batch-input/atom-decompose/*",
          "${aws_s3_bucket.bronze.arn}/batch-output/atom-decompose/*",
          # AA-606 — S1-rewrite writer batch prefixes, alongside the atom-decompose ones.
          "${aws_s3_bucket.bronze.arn}/batch-input/s1-rewrite/*",
          "${aws_s3_bucket.bronze.arn}/batch-output/s1-rewrite/*"
        ]
      },
      {
        Sid       = "AllowBedrockBatchListBucket"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::867490540162:role/aa-bedrock-batch-inference-role" }
        Action    = ["s3:ListBucket"]
        Resource  = aws_s3_bucket.bronze.arn
        Condition = {
          StringLike = { "s3:prefix" = [
            "batch-input/atom-decompose/*", "batch-output/atom-decompose/*",
            "batch-input/s1-rewrite/*", "batch-output/s1-rewrite/*"
          ] }
        }
      },
      # AA-399 — same grant, parallel, for the acc3 Batch inference service
      # role (account 786888028788, accounts/acc3-bedrock/batch.tf). acc1's
      # statements above are UNCHANGED — acc3 is added alongside, not instead.
      {
        Sid       = "AllowBedrockBatchCrossAccountAccessAcc3"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::786888028788:role/aa3-bedrock-batch-inference-role" }
        Action    = ["s3:GetObject", "s3:PutObject"]
        Resource = [
          "${aws_s3_bucket.bronze.arn}/batch-input/atom-decompose/*",
          "${aws_s3_bucket.bronze.arn}/batch-output/atom-decompose/*",
          # AA-606 — S1-rewrite writer batch prefixes (acc3 is the primary Batch account).
          "${aws_s3_bucket.bronze.arn}/batch-input/s1-rewrite/*",
          "${aws_s3_bucket.bronze.arn}/batch-output/s1-rewrite/*"
        ]
      },
      {
        Sid       = "AllowBedrockBatchListBucketAcc3"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::786888028788:role/aa3-bedrock-batch-inference-role" }
        Action    = ["s3:ListBucket"]
        Resource  = aws_s3_bucket.bronze.arn
        Condition = {
          StringLike = { "s3:prefix" = [
            "batch-input/atom-decompose/*", "batch-output/atom-decompose/*",
            "batch-input/s1-rewrite/*", "batch-output/s1-rewrite/*"
          ] }
        }
      }
      ],
      # AA-844: the photos CDN (accounts/aa365/photos_cdn.tf) reads photos/* through its origin
      # access control. GetObject only, no ListBucket, so a missing key is a 403, not a listing;
      # scoped by AWS:SourceArn to that one distribution. A service principal with a SourceArn
      # condition is not "public" for Block Public Access, which stays fully on.
      var.bronze_cloudfront_read == null ? [] : [
        {
          Sid       = "AllowPhotosCdnRead"
          Effect    = "Allow"
          Principal = { Service = "cloudfront.amazonaws.com" }
          Action    = "s3:GetObject"
          Resource  = "${aws_s3_bucket.bronze.arn}/${var.bronze_cloudfront_read.prefix}/*"
          Condition = {
            StringEquals = { "AWS:SourceArn" = var.bronze_cloudfront_read.distribution_arn }
          }
        }
    ])
  })
}

# =============================================================================
# SILVER BUCKET — Validated & enriched intermediate data
# Paths: processed/{tenant}/{batch}/tours.jsonl
#        seo-cache/{tenant}/{key}.json
# =============================================================================

resource "aws_s3_bucket" "silver" {
  bucket        = local.silver_bucket
  force_destroy = var.environment == "dev" ? true : false

  tags = merge(local.common_tags, {
    Name  = local.silver_bucket
    Layer = "silver"
    Notes = "Validated JSONL and SEO cache backup - ETL output"
  })
}

resource "aws_s3_bucket_versioning" "silver" {
  bucket = aws_s3_bucket.silver.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "silver" {
  bucket                  = aws_s3_bucket.silver.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# SEO cache backup expires after 7 days (Redis TTL 24h, S3 fallback not needed longer)
resource "aws_s3_bucket_lifecycle_configuration" "silver" {
  bucket = aws_s3_bucket.silver.id

  rule {
    id     = "seo-cache-expire"
    status = "Enabled"

    filter {
      prefix = "seo-cache/"
    }

    expiration {
      days = 7
    }
  }

  rule {
    id     = "processed-jsonl-glacier"
    status = "Enabled"

    filter {
      prefix = "processed/"
    }

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    expiration {
      days = 365
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "silver" {
  bucket = aws_s3_bucket.silver.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "silver" {
  bucket = aws_s3_bucket.silver.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyUnencryptedTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.silver.arn,
          "${aws_s3_bucket.silver.arn}/*"
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      }
    ]
  })
}

# =============================================================================
# GOLD BUCKET — Business-ready published content
# Paths: published/{tenant}/{tour_id}.json    ← Immutable after write
#        exports/{tenant}/{export_id}.{json|csv|xml}  ← Signed URL 7 days
#        webhooks/{tenant}/payload_{ts}.json  ← Delivery archive
# =============================================================================

resource "aws_s3_bucket" "gold" {
  bucket        = local.gold_bucket
  force_destroy = var.environment == "dev" ? true : false

  tags = merge(local.common_tags, {
    Name  = local.gold_bucket
    Layer = "gold"
    Notes = "Published tours - export files - webhook payloads"
  })
}

resource "aws_s3_bucket_versioning" "gold" {
  bucket = aws_s3_bucket.gold.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "gold" {
  bucket                  = aws_s3_bucket.gold.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Export files expire after 7 days (PRD §5.3: signed URL 7 days)
# Webhook payloads expire after 30 days
resource "aws_s3_bucket_lifecycle_configuration" "gold" {
  bucket = aws_s3_bucket.gold.id

  rule {
    id     = "exports-expire"
    status = "Enabled"

    filter {
      prefix = "exports/"
    }

    expiration {
      days = 7
    }
  }

  rule {
    id     = "webhooks-expire"
    status = "Enabled"

    filter {
      prefix = "webhooks/"
    }

    expiration {
      days = 30
    }
  }

  # Published tours: Intelligent Tiering after 30 days (accessed infrequently)
  rule {
    id     = "published-intelligent-tiering"
    status = "Enabled"

    filter {
      prefix = "published/"
    }

    transition {
      days          = 30
      storage_class = "INTELLIGENT_TIERING"
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "gold" {
  bucket = aws_s3_bucket.gold.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "gold" {
  bucket = aws_s3_bucket.gold.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyUnencryptedTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.gold.arn,
          "${aws_s3_bucket.gold.arn}/*"
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      }
    ]
  })
}

# =============================================================================
# ACP BUCKETS — Adventure Asia Content Pipeline medallion layers
# Separate from CIS buckets; prefixed with -acp-
# AA-40
# =============================================================================

locals {
  acp_bronze_bucket = "${var.project}-acp-bronze-${local.account_id}"
  acp_silver_bucket = "${var.project}-acp-silver-${local.account_id}"
  acp_gold_bucket   = "${var.project}-acp-gold-${local.account_id}"
}

resource "aws_s3_bucket" "acp_bronze" {
  bucket        = local.acp_bronze_bucket
  force_destroy = var.environment == "dev" ? true : false

  tags = merge(local.common_tags, {
    Name     = local.acp_bronze_bucket
    Layer    = "bronze"
    Pipeline = "acp"
    Notes    = "ACP raw content intake - immutable"
  })
}

resource "aws_s3_bucket_versioning" "acp_bronze" {
  bucket = aws_s3_bucket.acp_bronze.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "acp_bronze" {
  bucket                  = aws_s3_bucket.acp_bronze.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "acp_bronze" {
  bucket = aws_s3_bucket.acp_bronze.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "acp_bronze" {
  bucket = aws_s3_bucket.acp_bronze.id

  rule {
    id     = "acp-raw-archive-glacier"
    status = "Enabled"
    filter { prefix = "raw-archive/" }
    transition {
      days          = 90
      storage_class = "GLACIER"
    }
    expiration { days = 2555 }
  }
}

resource "aws_s3_bucket_policy" "acp_bronze" {
  bucket = aws_s3_bucket.acp_bronze.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyUnencryptedTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.acp_bronze.arn, "${aws_s3_bucket.acp_bronze.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

resource "aws_s3_bucket" "acp_silver" {
  bucket        = local.acp_silver_bucket
  force_destroy = var.environment == "dev" ? true : false

  tags = merge(local.common_tags, {
    Name     = local.acp_silver_bucket
    Layer    = "silver"
    Pipeline = "acp"
    Notes    = "ACP validated and enriched content"
  })
}

resource "aws_s3_bucket_versioning" "acp_silver" {
  bucket = aws_s3_bucket.acp_silver.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "acp_silver" {
  bucket                  = aws_s3_bucket.acp_silver.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "acp_silver" {
  bucket = aws_s3_bucket.acp_silver.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "acp_silver" {
  bucket = aws_s3_bucket.acp_silver.id

  rule {
    id     = "acp-processed-tiering"
    status = "Enabled"
    filter { prefix = "processed/" }
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
    transition {
      days          = 90
      storage_class = "GLACIER"
    }
    expiration { days = 365 }
  }
}

resource "aws_s3_bucket_policy" "acp_silver" {
  bucket = aws_s3_bucket.acp_silver.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyUnencryptedTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.acp_silver.arn, "${aws_s3_bucket.acp_silver.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

resource "aws_s3_bucket" "acp_gold" {
  bucket        = local.acp_gold_bucket
  force_destroy = var.environment == "dev" ? true : false

  tags = merge(local.common_tags, {
    Name     = local.acp_gold_bucket
    Layer    = "gold"
    Pipeline = "acp"
    Notes    = "ACP published content ready for delivery"
  })
}

resource "aws_s3_bucket_versioning" "acp_gold" {
  bucket = aws_s3_bucket.acp_gold.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "acp_gold" {
  bucket                  = aws_s3_bucket.acp_gold.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "acp_gold" {
  bucket = aws_s3_bucket.acp_gold.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "acp_gold" {
  bucket = aws_s3_bucket.acp_gold.id

  rule {
    id     = "acp-exports-expire"
    status = "Enabled"
    filter { prefix = "exports/" }
    expiration { days = 7 }
  }

  rule {
    id     = "acp-published-tiering"
    status = "Enabled"
    filter { prefix = "published/" }
    transition {
      days          = 30
      storage_class = "INTELLIGENT_TIERING"
    }
  }
}

resource "aws_s3_bucket_policy" "acp_gold" {
  bucket = aws_s3_bucket.acp_gold.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyUnencryptedTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.acp_gold.arn, "${aws_s3_bucket.acp_gold.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

# =============================================================================
# TFSTATE BUCKET — unchanged, managed separately
# aa-cis-tfstate-{account_id} — already exists, do not recreate
# =============================================================================

# =============================================================================
# S3 CORS — Bronze bucket (added TD-1 sync 29/04/2026)
# =============================================================================
resource "aws_s3_bucket_cors_configuration" "bronze" {
  bucket = aws_s3_bucket.bronze.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "PUT", "POST", "DELETE", "HEAD"]
    allowed_origins = [
      "https://aa-cis.lumiguides.it.com",
      "http://localhost:3000",
    ]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}
