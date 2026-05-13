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
