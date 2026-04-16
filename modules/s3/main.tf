# ============================================================
# S3 Module — AA-CIS
# ============================================================

locals {
  name_prefix = "${var.project}-${var.environment}"
}

# Upload bucket (Excel input)
resource "aws_s3_bucket" "uploads" {
  bucket = "${local.name_prefix}-uploads-${var.account_id}"
  tags   = { Name = "${local.name_prefix}-uploads" }
}

resource "aws_s3_bucket_versioning" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "uploads" {
  bucket                  = aws_s3_bucket.uploads.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# Output bucket (processed content)
resource "aws_s3_bucket" "outputs" {
  bucket = "${local.name_prefix}-outputs-${var.account_id}"
  tags   = { Name = "${local.name_prefix}-outputs" }
}

resource "aws_s3_bucket_versioning" "outputs" {
  bucket = aws_s3_bucket.outputs.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "outputs" {
  bucket                  = aws_s3_bucket.outputs.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# S3 folder structure — raw-inbox/ và pipeline/
resource "aws_s3_object" "raw_inbox" {
  bucket = aws_s3_bucket.uploads.id
  key    = "raw-inbox/"
}

resource "aws_s3_object" "pipeline" {
  bucket = aws_s3_bucket.uploads.id
  key    = "pipeline/"
}
