# =============================================================================
# AA-272 — TEMPORARY diagnostic logging for the VPC Link cutover hang
# investigation. Not part of the normal stack. Remove this file once the
# root-cause investigation is done — see docs/implementation-notes/AA-272.md.
# =============================================================================

# ---------------------------------------------------------------------------
# 1. VPC Flow Logs — NLB subnets + ALB subnets (4 total), CloudWatch Logs,
#    7-day retention.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "diag_flow_logs" {
  name              = "/aa-cis-dev/diagnostic/vpc-flow-logs"
  retention_in_days = 7

  tags = merge(local.common_tags, {
    Purpose = "AA-272-diagnostic-only"
  })
}

resource "aws_iam_role" "diag_flow_logs" {
  name                 = "${local.name_prefix}-diag-flow-logs-role"
  permissions_boundary = aws_iam_policy.workload_boundary.arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, {
    Purpose = "AA-272-diagnostic-only"
  })
}

resource "aws_iam_role_policy" "diag_flow_logs" {
  name = "diag-flow-logs-delivery"
  role = aws_iam_role.diag_flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
      ]
      Resource = "${aws_cloudwatch_log_group.diag_flow_logs.arn}:*"
    }]
  })
}

# NLB subnets (module.vpc.private_subnet_ids — same 2 subnets aws_lb.vpc_link_nlb uses)
resource "aws_flow_log" "diag_nlb" {
  for_each = toset(module.vpc.private_subnet_ids)

  subnet_id            = each.value
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.diag_flow_logs.arn
  iam_role_arn         = aws_iam_role.diag_flow_logs.arn

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-diag-flowlog-nlb-${each.value}"
    Purpose = "AA-272-diagnostic-only"
  })
}

# ALB subnets
resource "aws_flow_log" "diag_alb" {
  for_each = toset(module.alb.alb_subnet_ids)

  subnet_id            = each.value
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.diag_flow_logs.arn
  iam_role_arn         = aws_iam_role.diag_flow_logs.arn

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-diag-flowlog-alb-${each.value}"
    Purpose = "AA-272-diagnostic-only"
  })
}

# ---------------------------------------------------------------------------
# 2. ALB access logs — new S3 bucket, bucket policy via aws_elb_service_account
#    (region-correct ELB log-delivery account, not hardcoded/guessed).
# ---------------------------------------------------------------------------

data "aws_elb_service_account" "current" {}

resource "aws_s3_bucket" "diag_alb_logs" {
  bucket        = "${local.name_prefix}-diag-alb-logs-${var.account_id}"
  force_destroy = true

  tags = merge(local.common_tags, {
    Purpose = "AA-272-diagnostic-only"
  })
}

resource "aws_s3_bucket_public_access_block" "diag_alb_logs" {
  bucket                  = aws_s3_bucket.diag_alb_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "diag_alb_logs" {
  bucket = aws_s3_bucket.diag_alb_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Diagnostic only — expire objects after 7 days so this doesn't linger as cost/PII
resource "aws_s3_bucket_lifecycle_configuration" "diag_alb_logs" {
  bucket = aws_s3_bucket.diag_alb_logs.id

  rule {
    id     = "expire-diagnostic-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = 7
    }
  }
}

resource "aws_s3_bucket_policy" "diag_alb_logs" {
  bucket = aws_s3_bucket.diag_alb_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowELBAccessLogDelivery"
      Effect = "Allow"
      Principal = {
        AWS = data.aws_elb_service_account.current.arn
      }
      Action   = "s3:PutObject"
      Resource = "${aws_s3_bucket.diag_alb_logs.arn}/alb-access-logs/*"
    }]
  })
}

# ---------------------------------------------------------------------------
# 3. API Gateway execution logging — account-level CloudWatch role (confirmed
#    missing via `aws apigateway get-account`, confirmed to create — this is
#    an ACCOUNT-WIDE singleton, affects every REST API in this account/
#    region, not just aa-cis-dev-api) + INFO-level method settings on stage
#    "dev" (see modules/api_gateway var.enable_execution_logging).
# ---------------------------------------------------------------------------

resource "aws_iam_role" "diag_apigw_cloudwatch" {
  name                 = "${local.name_prefix}-diag-apigw-cloudwatch-role"
  permissions_boundary = aws_iam_policy.workload_boundary.arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "apigateway.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, {
    Purpose = "AA-272-diagnostic-only"
  })
}

resource "aws_iam_role_policy_attachment" "diag_apigw_cloudwatch" {
  role       = aws_iam_role.diag_apigw_cloudwatch.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

# Account-wide singleton (one per AWS account/region) — currently unset
# (confirmed via `aws apigateway get-account`), so this creates it. Only
# sets cloudwatch_role_arn; does not touch any REST API resource.
resource "aws_api_gateway_account" "this" {
  cloudwatch_role_arn = aws_iam_role.diag_apigw_cloudwatch.arn
}
