# ============================================================
# EventBridge Module — AA-CIS ACP Pipeline
# Custom event bus + Scheduler for ACP content pipeline
# AA-40
# ============================================================

locals {
  bus_name    = "${var.project}-${var.environment}-acp-events"
  name_prefix = "${var.project}-${var.environment}"
}

# ── Custom Event Bus ─────────────────────────────────────────

resource "aws_cloudwatch_event_bus" "acp_events" {
  name = local.bus_name

  # _iam_gate is a no-op tag whose only purpose is to force this resource to
  # wait on var.iam_propagation_gate's upstream time_sleep — see variables.tf.
  tags = merge(var.tags, {
    Name      = local.bus_name
    Module    = "eventbridge"
    Feature   = "acp-pipeline"
    _iam_gate = var.iam_propagation_gate
  })
}

# ── IAM Role for EventBridge Scheduler ───────────────────────

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name                 = "${local.name_prefix}-acp-scheduler-role"
  assume_role_policy   = data.aws_iam_policy_document.scheduler_assume.json
  permissions_boundary = var.permissions_boundary_arn

  # _iam_gate is a no-op tag whose only purpose is to force this resource to
  # wait on var.iam_propagation_gate's upstream time_sleep — see variables.tf.
  tags = merge(var.tags, {
    _iam_gate = var.iam_propagation_gate
  })
}

data "aws_iam_policy_document" "scheduler_permissions" {
  statement {
    sid       = "PutEventsOnAcpBus"
    actions   = ["events:PutEvents"]
    resources = [aws_cloudwatch_event_bus.acp_events.arn]
  }
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "${local.name_prefix}-acp-scheduler-policy"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler_permissions.json
}

# ── Scheduler Group ───────────────────────────────────────────

resource "aws_scheduler_schedule_group" "acp" {
  name = "${local.name_prefix}-acp"

  # _iam_gate is a no-op tag whose only purpose is to force this resource to
  # wait on var.iam_propagation_gate's upstream time_sleep — see variables.tf.
  tags = merge(var.tags, {
    Module    = "eventbridge"
    Feature   = "acp-pipeline"
    _iam_gate = var.iam_propagation_gate
  })
}

# ── ACP schedules removed (AA-989, audit S252 §5.5 / §6 item 15) ──
# aws_scheduler_schedule.acp_daily_ingest (ACP.DailyIngest, daily 06:00 UTC), acp_weekly_export (ACP.WeeklyExport,
# Sun 23:00 UTC) and acp_veto_window_close (ACP.VetoWindowClose, Wed 18:00 UTC, AA-365) put events on the ACP bus
# with no aws_cloudwatch_event_rule matching them anywhere (this module had none; every rule in accounts/aa365 is a
# CloudTrail/default-bus alert), and AA-CIS-App has no handler for those detail types (AA-492 traced 0 rules /
# 0 targets on this bus). They fired into nothing and suggested a daily ingest/export that does not exist; the
# CIS pipeline is job-driven (shared.job on the worker). The bus, the scheduler role, the schedule group (used
# by the dfs_balance / retention / photo_sync / booking_uptime / rds_snapshot_expiry schedules in accounts/aa365)
# and the DLQ stay.

# ============================================================
# AA-61 — ACP Events FIFO DLQ + Monitoring
# FIFO queue captures failed EventBridge rule deliveries.
# Note: EventBridge Scheduler DLQ requires standard SQS (not FIFO).
# Attach this queue via dead_letter_config when rule targets are provisioned.
# ============================================================

resource "aws_sqs_queue" "acp_events_dlq" {
  name                        = "${local.bus_name}-dlq.fifo"
  fifo_queue                  = true
  content_based_deduplication = true
  message_retention_seconds   = 1209600 # 14 days

  tags = merge(var.tags, {
    Name    = "${local.bus_name}-dlq"
    Module  = "eventbridge"
    Feature = "acp-pipeline-dlq"
  })
}

data "aws_iam_policy_document" "acp_dlq_policy" {
  statement {
    sid    = "AllowEventBridgeSend"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "scheduler.amazonaws.com"]
    }

    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.acp_events_dlq.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }
}

resource "aws_sqs_queue_policy" "acp_events_dlq" {
  queue_url = aws_sqs_queue.acp_events_dlq.id
  policy    = data.aws_iam_policy_document.acp_dlq_policy.json
}

# ── CloudWatch Alarm: DLQ Depth ───────────────────────────────
# Alerts route to var.alerts_topic_arn (the existing AA-284 alerts topic,
# accounts/aa365/observability.tf) — this module does not create its own SNS
# topic. It originally did, but that duplicated AA-284's aa-cis-dev-acp-alerts
# topic (identical computed name, same account/region) and collided at apply
# time; reusing the existing topic avoids the duplicate and keeps the one
# already-confirmed email subscription as the single source of alerting.
# ALARM and OK notifications (AA-872, S241 D-20), like every alarm on the topic.

resource "aws_cloudwatch_metric_alarm" "acp_dlq_depth" {
  alarm_name          = "${local.name_prefix}-acp-dlq-depth"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "ACP Events DLQ has messages — investigate failed EventBridge deliveries.${var.alarm_runbook_url == "" ? "" : " Runbook: ${var.alarm_runbook_url}"}"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.acp_events_dlq.name
  }

  alarm_actions = [var.alerts_topic_arn]
  ok_actions    = [var.alerts_topic_arn]

  tags = merge(var.tags, {
    Name    = "${local.name_prefix}-acp-dlq-depth"
    Module  = "eventbridge"
    Feature = "acp-pipeline-monitoring"
  })
}
