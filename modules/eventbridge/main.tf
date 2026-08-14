# ============================================================
# EventBridge Module — AA-CIS ACP Pipeline
# Custom event bus + Scheduler for ACP content pipeline
# AA-40
# ============================================================

locals {
  bus_name   = "${var.project}-${var.environment}-acp-events"
  name_prefix = "${var.project}-${var.environment}"
}

# ── Custom Event Bus ─────────────────────────────────────────

resource "aws_cloudwatch_event_bus" "acp_events" {
  name = local.bus_name

  tags = merge(var.tags, {
    Name    = local.bus_name
    Module  = "eventbridge"
    Feature = "acp-pipeline"
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
  name               = "${local.name_prefix}-acp-scheduler-role"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
  tags               = var.tags
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

  tags = merge(var.tags, {
    Module  = "eventbridge"
    Feature = "acp-pipeline"
  })
}

# ── Schedule: Daily ACP Ingest — 06:00 UTC ───────────────────
# Puts ACP.DailyIngest event on the bus; EventBridge rules
# (added when ingest Lambda is provisioned) route it downstream.

resource "aws_scheduler_schedule" "acp_daily_ingest" {
  name       = "${local.name_prefix}-acp-daily-ingest"
  group_name = aws_scheduler_schedule_group.acp.name

  schedule_expression          = "cron(0 6 * * ? *)"
  schedule_expression_timezone = "UTC"

  flexible_time_window {
    mode                      = "FLEXIBLE"
    maximum_window_in_minutes = 30
  }

  target {
    arn      = aws_cloudwatch_event_bus.acp_events.arn
    role_arn = aws_iam_role.scheduler.arn

    eventbridge_parameters {
      detail_type = "ACP.DailyIngest"
      source      = "acp.scheduler"
    }

    retry_policy {
      maximum_retry_attempts       = 3
      maximum_event_age_in_seconds = 3600
    }
  }

  state = "ENABLED"
}

# ── Schedule: Weekly Content Export — Sun 23:00 UTC ──────────

resource "aws_scheduler_schedule" "acp_weekly_export" {
  name       = "${local.name_prefix}-acp-weekly-export"
  group_name = aws_scheduler_schedule_group.acp.name

  schedule_expression          = "cron(0 23 ? * SUN *)"
  schedule_expression_timezone = "UTC"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_cloudwatch_event_bus.acp_events.arn
    role_arn = aws_iam_role.scheduler.arn

    eventbridge_parameters {
      detail_type = "ACP.WeeklyExport"
      source      = "acp.scheduler"
    }

    retry_policy {
      maximum_retry_attempts       = 2
      maximum_event_age_in_seconds = 1800
    }
  }

  state = "ENABLED"
}

# ── Schedule: Veto Window Close — Wed 18:00 UTC ──────────────
# AA-365 [N8-5]: puts ACP.VetoWindowClose event on the bus. Mirrors
# acp_daily_ingest/acp_weekly_export exactly -- no aws_cloudwatch_event_rule
# consumes this event yet (same as those two schedules today; a rule gets
# added when the veto-window-close handler is provisioned), so this
# resource alone has no runtime effect on its own until that follow-up.

resource "aws_scheduler_schedule" "acp_veto_window_close" {
  name       = "${local.name_prefix}-acp-veto-window-close"
  group_name = aws_scheduler_schedule_group.acp.name

  schedule_expression          = "cron(0 18 ? * WED *)"
  schedule_expression_timezone = "UTC"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_cloudwatch_event_bus.acp_events.arn
    role_arn = aws_iam_role.scheduler.arn

    eventbridge_parameters {
      detail_type = "ACP.VetoWindowClose"
      source      = "acp.scheduler"
    }

    retry_policy {
      maximum_retry_attempts       = 2
      maximum_event_age_in_seconds = 1800
    }
  }

  state = "ENABLED"
}

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

# ── SNS Alert Topic ───────────────────────────────────────────

resource "aws_sns_topic" "acp_alerts" {
  name = "${local.name_prefix}-acp-alerts"

  tags = merge(var.tags, {
    Name    = "${local.name_prefix}-acp-alerts"
    Module  = "eventbridge"
    Feature = "acp-pipeline-monitoring"
  })
}

# ── CloudWatch Alarm: DLQ Depth ───────────────────────────────

resource "aws_cloudwatch_metric_alarm" "acp_dlq_depth" {
  alarm_name          = "${local.name_prefix}-acp-dlq-depth"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "ACP Events DLQ has messages — investigate failed EventBridge deliveries"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.acp_events_dlq.name
  }

  alarm_actions = [aws_sns_topic.acp_alerts.arn]
  ok_actions    = [aws_sns_topic.acp_alerts.arn]

  tags = merge(var.tags, {
    Name    = "${local.name_prefix}-acp-dlq-depth"
    Module  = "eventbridge"
    Feature = "acp-pipeline-monitoring"
  })
}
