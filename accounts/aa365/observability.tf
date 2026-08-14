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
# AA-287 — IAM propagation race (run #61). aa-cis-dev-role's inline policy
# (accounts/aa365/cicd.tf, aws_iam_role_policy.cicd_inline) picked up the
# Budgets/CloudTrail Sids correctly, but Terraform started creating
# aws_budgets_budget.total_monthly ~130ms after the policy update API call
# returned success — before AWS's IAM/STS authorization propagation caught
# up for the already-active assumed-role session. Result: AccessDenied on an
# action that WAS present in the (by-then-correct) policy. Standard,
# documented mitigation for AWS IAM's eventual consistency — not a
# permissions bug, a sequencing one.
#
# AA-402 (2026-08-15): same race recurred for cicd_inline's new EventBridge/
# Scheduler statements (run #70/#71) — module.eventbridge's resources started
# before the policy update had propagated. Added `triggers` keyed to the
# policy's own content hash (not aws_iam_role_policy.cicd_inline.id, which is
# just "role_name:policy_name" and never changes on a content-only update) so
# this resource re-creates — and re-sleeps — on every future policy change,
# not just its original creation. Makes this a general fix for any consumer
# that depends_on it, not a one-off tied to AA-287's original resources.
# -----------------------------------------------------------------------------

resource "time_sleep" "wait_for_iam_propagation" {
  depends_on      = [aws_iam_role_policy.cicd_inline]
  create_duration = "15s"

  triggers = {
    policy_hash = md5(aws_iam_role_policy.cicd_inline.policy)
  }
}

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
# AA-362 [N8-2] — N7 Produce piece alarms (held_rate, grounding_score floor,
# repair_count). STEP 0 (05/08/2026) confirmed 5/6 alarms the issue wants were
# missing; this covers 3 of the 5 gap. Metrics emitted by
# AA-CIS-App:services/acp_produce/metrics.py::emit_piece_metrics() —
# namespace "acp" (the one real custom-metric convention already in the repo,
# api/routers/acp_health.py/AA-141 — no "ACP/Pipeline"/"ACP/Produce"
# namespace exists anywhere, confirmed by grep before choosing this).
#
# NOT included here (see AA-362 chat report / PR for full reasoning):
#   - Bedrock daily cost — blocked by 2 live-verified findings: (a) AWS/Billing
#     CloudWatch metrics require a manual, non-Terraform-able account setting
#     ("Receive Billing Alerts") that is NOT enabled on this account (verified
#     `aws cloudwatch list-metrics --namespace AWS/Billing --region us-east-1`
#     → empty), and (b) Cost Explorer shows Bedrock spend split across 4
#     separate SERVICE line items (`Amazon Bedrock`, `Cohere Embed 4 Model
#     (Amazon Bedrock Edition)`, `Palmyra X4 (Amazon Bedrock Edition)`,
#     `Palmyra X5 (Amazon Bedrock Edition)` — verified via
#     `aws ce get-dimension-values --dimension SERVICE`), so a correct alarm
#     needs a new Cost-Explorer-rollup Lambda, not just an alarm resource —
#     real new cost-measurement infrastructure that overlaps AA-360's
#     explicitly-reserved "unified cost tracking (infra + LLM)" scope
#     (AA-360 confirmed still Backlog/undesigned, but building this now risks
#     throwaway work AA-360 would replace). Left for Nghiep to decide: build
#     as a one-off now, or fold into AA-360.
#   - week_run Tuesday deadline — BLOCKED on AA-364 (Weekly Packet). No
#     "week_run" runtime concept exists anywhere in either repo yet (grepped
#     both, 0 hits) — there is nothing to alarm on. See TODO placeholder below.
# -----------------------------------------------------------------------------

# held_rate — computed via CloudWatch metric math (ratio), not in Python:
# emit_piece_metrics() only emits raw per-piece counts (piece_held/
# piece_passed); this alarm sums each over a 1h window and divides.
# Threshold (20%) is an UNVERIFIED PLACEHOLDER — no real N7 traffic exists yet
# to tune against (same acknowledged gap as AA-298's SWEEPER_SLA_HOURS
# placeholder). Tune once real held/passed volume exists.
resource "aws_cloudwatch_metric_alarm" "acp_piece_held_rate_high" {
  alarm_name          = "${local.name_prefix}-acp-piece-held-rate-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 20
  alarm_description   = "N7 piece held-rate above 20% over 1h (UNVERIFIED placeholder threshold) — possible prompt/gate drift or brief quality regression"
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "held_rate"
    expression  = "(held_sum / (held_sum + passed_sum)) * 100"
    label       = "N7 piece held rate (%)"
    return_data = true
  }

  metric_query {
    id = "held_sum"
    metric {
      metric_name = "piece_held"
      namespace   = "acp"
      period      = 3600
      stat        = "Sum"
    }
  }

  metric_query {
    id = "passed_sum"
    metric {
      metric_name = "piece_passed"
      namespace   = "acp"
      period      = 3600
      stat        = "Sum"
    }
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = merge(local.common_tags, { Issue = "AA-362" })
}

# grounding_score HARD FLOOR = 1.0 — not a soft/tunable threshold per issue
# spec. gate_grounding() (F1) is binary pass/fail in the real code (no
# numeric score exists — see AA-362 implementation notes), mapped by
# emit_piece_metrics() to 1.0 (passed) / 0.0 (failed). Minimum statistic over
# a 5-minute period + 1 evaluation period means ANY single F1 failure drags
# the period's Minimum to 0.0 and fires within one period — "floor" is
# enforced as "alarm the instant it happens," not averaged/smoothed away.
resource "aws_cloudwatch_metric_alarm" "acp_grounding_score_floor" {
  alarm_name          = "${local.name_prefix}-acp-grounding-score-floor"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "grounding_score"
  namespace           = "acp"
  period              = 300
  statistic           = "Minimum"
  threshold           = 1.0
  alarm_description   = "N7 F1 grounding gate failed on at least 1 piece (HARD FLOOR = 1.0) — fabrication risk, investigate immediately"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = merge(local.common_tags, { Issue = "AA-362" })
}

# repair_count — average per piece rising is the prompt/gate-drift signal the
# issue names. Threshold (1.0) and evaluation window (3x 1h) are UNVERIFIED
# PLACEHOLDERS, same caveat as held_rate above — no real repair_count
# distribution exists yet to set a real number against.
resource "aws_cloudwatch_metric_alarm" "acp_repair_count_high" {
  alarm_name          = "${local.name_prefix}-acp-repair-count-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "repair_count"
  namespace           = "acp"
  period              = 3600
  statistic           = "Average"
  threshold           = 1.0
  alarm_description   = "N7 average repair_count per piece above 1.0 for 3 consecutive hours (UNVERIFIED placeholder threshold) — possible prompt/gate drift"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = merge(local.common_tags, { Issue = "AA-362" })
}

# TODO(AA-364): week_run Tuesday-deadline alarm. Do not build ahead of AA-364
# (Weekly Packet) — no "week_run" runtime concept exists yet anywhere in
# either repo (grep confirmed 0 hits), so there is nothing real to alarm on.
# Add here once AA-364 emits a real completion timestamp/metric to check
# against a Tuesday deadline.

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

  depends_on = [time_sleep.wait_for_iam_propagation]
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

  depends_on = [aws_s3_bucket_policy.cloudtrail_logs, time_sleep.wait_for_iam_propagation]
}
