# =============================================================================
# S102 Phase 3a — Observability/governance gaps found in the Phase 1 audit on
# account 005097885195: 0 SNS topics, 0 AWS Budgets, 0 CloudTrail trails.
# AA-284 (alerting) + AA-287 (budgets) + AA-286 (CloudTrail).
#
# AA-61 originally created aa-cis-dev-acp-alerts + a DLQ-depth alarm on
# account 1 (867490540162, decommissioned). That resource is gone with the
# account — this is a fresh build on account 2, not an import/fix.
# =============================================================================

# -----------------------------------------------------------------------------
# AA-284 — SNS alert topic + CloudWatch alarms
# -----------------------------------------------------------------------------

resource "aws_sns_topic" "alerts" {
  name = "${local.name_prefix}-acp-alerts"

  tags = merge(local.common_tags, { Issue = "AA-284" })
}

# Subscription is created PendingConfirmation — Nghiep must click the
# confirmation link AWS emails to var.alert_email. Terraform cannot complete
# this step.
resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# DLQ depth — one alarm per queue (module.sqs manages 6 queues; AA-61's
# original scope only covered one, but the account-1 definition is gone, so
# re-created for all 6 rather than guess which one mattered).
resource "aws_cloudwatch_metric_alarm" "dlq_depth" {
  for_each = module.sqs.dlq_names

  alarm_name          = "${each.value}-depth"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "DLQ ${each.value} has received a failed message — pipeline is dropping work"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    QueueName = each.value
  }

  tags = merge(local.common_tags, { Issue = "AA-284" })
}

# Proposed addition (per S102 task) — RDS CPU sustained high. Kept in this PR
# but flagged for Nghiep to confirm/drop; not part of the original AA-61 scope.
resource "aws_cloudwatch_metric_alarm" "rds_cpu_high" {
  alarm_name          = "${local.name_prefix}-rds-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "RDS ${local.name_prefix}-db CPU above 80% for 10 minutes"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    DBInstanceIdentifier = "${local.name_prefix}-db"
  }

  tags = merge(local.common_tags, { Issue = "AA-284" })
}

# Proposed addition (per S102 task) — ECS running task count below desired.
# CAVEAT: ECS/ContainerInsights RunningTaskCount is only emitted when
# Container Insights is enabled on the cluster. Enabling Container Insights is
# NOT part of this PR (would touch modules/ecs, out of the stated scope) — if
# it isn't already enabled, this alarm will sit in INSUFFICIENT_DATA and never
# fire. Flagged for Nghiep to confirm/drop or follow up separately.
resource "aws_cloudwatch_metric_alarm" "ecs_task_count_low" {
  alarm_name          = "${local.name_prefix}-ecs-running-tasks-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "RunningTaskCount"
  namespace           = "ECS/ContainerInsights"
  period              = 300
  statistic           = "Average"
  threshold           = var.service_desired_count
  alarm_description   = "ECS ${local.name_prefix}-api running task count below desired (requires Container Insights)"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    ClusterName = "${local.name_prefix}-cluster"
    ServiceName = "${local.name_prefix}-api"
  }

  tags = merge(local.common_tags, { Issue = "AA-284" })
}

# -----------------------------------------------------------------------------
# AA-287 — AWS Budgets
# Single $250/mo total-account budget (Execute Plan program-level number,
# locked already — not re-litigated here). A tag-based split into ACP $180 +
# total $250 is possible but this account has no cost-allocation tags applied
# per project yet, so a per-project budget would silently cover $0 today —
# noted here rather than built, since it'd just be misleading.
# Email notification chosen over SNS: AWS Budgets → SNS requires a topic
# resource policy granting budgets.amazonaws.com publish rights, which is
# extra surface area for no real benefit here — direct email is simpler and
# was explicitly allowed as the fallback.
# -----------------------------------------------------------------------------

resource "aws_budgets_budget" "total_monthly" {
  name         = "${local.name_prefix}-monthly-total"
  budget_type  = "COST"
  limit_amount = "250"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }
}

# -----------------------------------------------------------------------------
# AA-286 — CloudTrail
# Single-region (us-west-1) trail — assumption, not a locked decision, called
# out in the PR for review. Bucket policy built via aws_iam_policy_document
# (no hardcoded ARNs — the trail ARN is built from vars, same deterministic-
# ARN pattern the root module already uses in `locals` to break the
# ECS <-> Step Functions cycle).
# -----------------------------------------------------------------------------

locals {
  cloudtrail_trail_name = "${local.name_prefix}-trail"
  cloudtrail_trail_arn  = "arn:aws:cloudtrail:${var.aws_region}:${var.account_id}:trail/${local.cloudtrail_trail_name}"
}

resource "aws_s3_bucket" "cloudtrail_logs" {
  bucket = "${local.name_prefix}-cloudtrail-logs-${var.account_id}"

  tags = merge(local.common_tags, { Issue = "AA-286" })
}

resource "aws_s3_bucket_public_access_block" "cloudtrail_logs" {
  bucket                  = aws_s3_bucket.cloudtrail_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Standard 30 days → Glacier Deep Archive, no expiration (audit log retained
# indefinitely per AA-286 spec).
resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id

  rule {
    id     = "archive-to-deep-archive"
    status = "Enabled"

    filter {}

    transition {
      days          = 30
      storage_class = "DEEP_ARCHIVE"
    }
  }
}

data "aws_iam_policy_document" "cloudtrail_logs" {
  statement {
    sid     = "AWSCloudTrailAclCheck"
    effect  = "Allow"
    actions = ["s3:GetBucketAcl"]

    resources = [aws_s3_bucket.cloudtrail_logs.arn]

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

  statement {
    sid     = "AWSCloudTrailWrite"
    effect  = "Allow"
    actions = ["s3:PutObject"]

    resources = ["${aws_s3_bucket.cloudtrail_logs.arn}/AWSLogs/${var.account_id}/*"]

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
      values   = [local.cloudtrail_trail_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id
  policy = data.aws_iam_policy_document.cloudtrail_logs.json
}

resource "aws_cloudtrail" "main" {
  name           = local.cloudtrail_trail_name
  s3_bucket_name = aws_s3_bucket.cloudtrail_logs.id

  is_multi_region_trail         = false
  include_global_service_events = true
  enable_log_file_validation    = true

  tags = merge(local.common_tags, { Issue = "AA-286" })

  depends_on = [aws_s3_bucket_policy.cloudtrail_logs]
}
