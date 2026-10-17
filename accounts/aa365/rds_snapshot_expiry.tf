# =============================================================================
# AA-869 (S241, item 5) — expire manual RDS snapshots of the Dev instance (data standard DM-7.5).
# EventBridge Scheduler (once a day) -> Lambda -> rds:DescribeDBSnapshots / DeleteDBSnapshot,
# with a short SNS message on the shared alert topic when something is (or would be) deleted.
#
# Rule (lambda_src/rds_snapshot_expiry/handler.py has the full text; tests next to it in
# lambda_src/rds_snapshot_expiry_tests/):
#   - candidates: SnapshotType "manual", Status "available", instance in the allowlist below.
#     Automated ("rds:...") and AWS Backup snapshots, shared/public and cluster snapshots never.
#     Automated backups (retention 7 d) are RDS-managed and untouched.
#   - keep: identifier "keep-...", tag aa:retain=keep, tag aa:retain-until=YYYY-MM-DD (today or
#     later, UTC), or a malformed aa:retain-until (fail safe, reported).
#   - expire: older than retain_days, or aa:retain-until in the past.
#   - orphan guard: a snapshot whose source instance is gone or was re-created (InstanceCreateTime
#     differs) is kept and reported instead of expiring, e.g. the final snapshot "aa-cis-dev-db-final"
#     RDS writes when the instance is deleted (modules/rds). Tag it aa:retain=keep to silence it.
#   - DRY_RUN: only the exact string "false" deletes. Default "true": report only.
#   - at most max_deletes_per_run deletions per run, oldest first; the rest wait for the next run.
# DB Migrate (.github/workflows/db-migrate.yml) tags its pre-destructive snapshot
# aa:retain-until = today + 30 days, so those follow the tag, not the age.
#
# Outside the VPC on purpose (like the identity triggers): the function only calls the RDS and SNS
# control-plane APIs, so it needs neither the NAT path nor a security group.
# Cost: one ~1 s invocation a day, ~0 USD/month. Savings = storage of expired snapshots
# (RDS ChargedBackupUsage 0.095 USD/GB-month).
#
# CI apply role (aa-cis-infra-tf-apply) can create everything here: role names match aa-*-dev-*
# with the workload boundary (IAMRoleManageStack), Lambda via AWSLambda_FullAccess, log group /
# alarm via CloudWatchFullAccess, and the schedule sits in the module.eventbridge group, the only
# group EventBridgeSchedulerScheduleManage allows (same reason as dfs_balance.tf).
# =============================================================================

variable "rds_snapshot_expiry_dry_run" {
  description = "AA-869 — \"false\" (exact string) lets the expiry Lambda delete; anything else only reports"
  type        = string
  default     = "true"

  validation {
    condition     = contains(["true", "false"], var.rds_snapshot_expiry_dry_run)
    error_message = "rds_snapshot_expiry_dry_run must be \"true\" or \"false\"."
  }
}

variable "rds_snapshot_expiry_retain_days" {
  description = "AA-869 — manual snapshots older than this many days expire (DM-7.5)"
  type        = number
  default     = 30

  validation {
    # db-migrate.yml asks to keep a pre-destructive snapshot >= 14 days.
    condition     = var.rds_snapshot_expiry_retain_days >= 14
    error_message = "rds_snapshot_expiry_retain_days must be at least 14."
  }
}

variable "rds_snapshot_expiry_max_deletes_per_run" {
  description = "AA-869 — at most this many snapshot deletions per run"
  type        = number
  default     = 3

  validation {
    condition     = var.rds_snapshot_expiry_max_deletes_per_run >= 1 && var.rds_snapshot_expiry_max_deletes_per_run <= 10
    error_message = "rds_snapshot_expiry_max_deletes_per_run must be between 1 and 10."
  }
}

variable "rds_snapshot_expiry_instances" {
  description = "AA-869 — DB instance identifiers whose manual snapshots may expire"
  type        = list(string)
  default     = ["aa-cis-dev-db"]
}

# 22:00 UTC = 05:00 ICT: outside VN working hours, away from the RDS backup window (03:00-04:00
# UTC), the 06:00 ACP ingest / 06:15 probes and the 20:30 retention enqueue.
variable "rds_snapshot_expiry_schedule_expression" {
  description = "AA-869 — schedule of the daily manual-snapshot expiry run"
  type        = string
  default     = "cron(0 22 * * ? *)"
}

locals {
  rds_snapshot_expiry_fn_name = "${local.name_prefix}-rds-snapshot-expiry"
  rds_snapshot_expiry_tags    = merge(local.shared_tags, { Issue = "AA-869" })
  rds_snapshot_arn_prefix     = "arn:aws:rds:${var.aws_region}:${var.account_id}:snapshot:"
}

# ── Package the zero-dependency handler ──────────────────────────────────────
data "archive_file" "rds_snapshot_expiry" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_src/rds_snapshot_expiry"
  output_path = "${path.module}/lambda_src/rds_snapshot_expiry.zip"
  # Same two guards as dfs_balance.tf (S240 bytecode drift, AA-806 file-mode drift).
  excludes         = ["__pycache__", "__pycache__/**", "**/*.pyc"]
  output_file_mode = "0666"
}

# ── Lambda execution role ────────────────────────────────────────────────────
data "aws_iam_policy_document" "rds_snapshot_expiry_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "rds_snapshot_expiry_exec" {
  name                 = "${local.rds_snapshot_expiry_fn_name}-exec"
  permissions_boundary = aws_iam_policy.workload_boundary.arn
  assume_role_policy   = data.aws_iam_policy_document.rds_snapshot_expiry_assume.json
  tags                 = local.rds_snapshot_expiry_tags
}

resource "aws_iam_role_policy" "rds_snapshot_expiry_perms" {
  name = "${local.rds_snapshot_expiry_fn_name}-perms"
  role = aws_iam_role.rds_snapshot_expiry_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "WriteOwnLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.rds_snapshot_expiry.arn}:log-stream:*"
      },
      {
        # Listing every manual snapshot of the account needs "*" (no instance filter in the call;
        # the handler filters by the allowlist).
        Sid      = "DescribeSnapshots"
        Effect   = "Allow"
        Action   = ["rds:DescribeDBSnapshots"]
        Resource = "*"
      },
      {
        # Orphan guard: is the snapshot's source instance still the live one? (The final snapshot
        # of a deleted instance must never expire by age alone.)
        Sid      = "DescribeAllowlistedInstances"
        Effect   = "Allow"
        Action   = ["rds:DescribeDBInstances"]
        Resource = [for i in var.rds_snapshot_expiry_instances : "arn:aws:rds:${var.aws_region}:${var.account_id}:db:${i}"]
      },
      {
        Sid      = "ReadSnapshotTags"
        Effect   = "Allow"
        Action   = ["rds:ListTagsForResource"]
        Resource = "${local.rds_snapshot_arn_prefix}*"
      },
      {
        Sid      = "DeleteDbSnapshots"
        Effect   = "Allow"
        Action   = ["rds:DeleteDBSnapshot"]
        Resource = "${local.rds_snapshot_arn_prefix}*"
      },
      {
        # Defence in depth behind the handler's own rule: never automated / AWS Backup snapshots,
        # never a keep-* name.
        Sid    = "DenyDeleteProtectedNames"
        Effect = "Deny"
        Action = ["rds:DeleteDBSnapshot"]
        Resource = [
          "${local.rds_snapshot_arn_prefix}rds:*",
          "${local.rds_snapshot_arn_prefix}awsbackup:*",
          "${local.rds_snapshot_arn_prefix}keep-*",
        ]
      },
      {
        # ... and never a snapshot tagged aa:retain=keep.
        Sid      = "DenyDeleteRetainTagged"
        Effect   = "Deny"
        Action   = ["rds:DeleteDBSnapshot"]
        Resource = "*"
        Condition = {
          StringEqualsIgnoreCase = { "aws:ResourceTag/aa:retain" = "keep" }
        }
      },
      {
        Sid      = "PublishAlert"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.alerts.arn
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "rds_snapshot_expiry" {
  name              = "/aws/lambda/${local.rds_snapshot_expiry_fn_name}"
  retention_in_days = 30 # AA-872 (S241 D-09): app logs 30 days
  tags              = local.rds_snapshot_expiry_tags
}

# ── Lambda function ──────────────────────────────────────────────────────────
resource "aws_lambda_function" "rds_snapshot_expiry" {
  function_name = local.rds_snapshot_expiry_fn_name
  description   = "AA-869: expire manual RDS snapshots after ${var.rds_snapshot_expiry_retain_days} days (DM-7.5)"
  role          = aws_iam_role.rds_snapshot_expiry_exec.arn
  handler       = "handler.handler"
  runtime       = "python3.12"
  architectures = ["arm64"]
  timeout       = 60
  memory_size   = 128

  filename         = data.archive_file.rds_snapshot_expiry.output_path
  source_code_hash = data.archive_file.rds_snapshot_expiry.output_base64sha256

  environment {
    variables = {
      DRY_RUN             = var.rds_snapshot_expiry_dry_run
      RETAIN_DAYS         = tostring(var.rds_snapshot_expiry_retain_days)
      MAX_DELETES_PER_RUN = tostring(var.rds_snapshot_expiry_max_deletes_per_run)
      INSTANCE_ALLOWLIST  = join(",", var.rds_snapshot_expiry_instances)
      ALERT_TOPIC_ARN     = aws_sns_topic.alerts.arn
      ENV_NAME            = var.environment
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.rds_snapshot_expiry,
    aws_iam_role_policy.rds_snapshot_expiry_perms,
  ]

  tags = merge(local.rds_snapshot_expiry_tags, { Function = "rds-snapshot-expiry" })
}

# Scheduler invokes asynchronously, so a failed run would be retried twice by Lambda by default.
# A run that deleted some snapshots and then failed must not run again the same day (each retry
# could delete up to the cap again): no retries, the Errors alarm below reports the failure.
resource "aws_lambda_function_event_invoke_config" "rds_snapshot_expiry" {
  function_name                = aws_lambda_function.rds_snapshot_expiry.function_name
  maximum_retry_attempts       = 0
  maximum_event_age_in_seconds = 3600
}

# Any failed run (delete error, bad config, SNS publish failure). ALARM + OK like every alarm on
# the topic (AA-872); for a daily job the OK mail only means "no new error in the last 5 minutes".
resource "aws_cloudwatch_metric_alarm" "rds_snapshot_expiry_errors" {
  alarm_name          = "${local.rds_snapshot_expiry_fn_name}-errors"
  alarm_description   = "AA-869: the RDS manual-snapshot expiry Lambda failed. Check its log group (one JSON line per snapshot)."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.rds_snapshot_expiry.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  tags                = local.rds_snapshot_expiry_tags
}

# ── EventBridge Scheduler → Lambda (dedicated invoke role) ───────────────────
data "aws_iam_policy_document" "rds_snapshot_expiry_scheduler_assume" {
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

resource "aws_iam_role" "rds_snapshot_expiry_scheduler" {
  name                 = "${local.rds_snapshot_expiry_fn_name}-scheduler"
  permissions_boundary = aws_iam_policy.workload_boundary.arn
  assume_role_policy   = data.aws_iam_policy_document.rds_snapshot_expiry_scheduler_assume.json
  tags                 = local.rds_snapshot_expiry_tags
}

resource "aws_iam_role_policy" "rds_snapshot_expiry_scheduler_invoke" {
  name = "invoke-rds-snapshot-expiry-lambda"
  role = aws_iam_role.rds_snapshot_expiry_scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.rds_snapshot_expiry.arn
    }]
  })
}

resource "aws_scheduler_schedule" "rds_snapshot_expiry_daily" {
  name        = "${local.rds_snapshot_expiry_fn_name}-daily"
  description = "AA-869 — daily manual RDS snapshot expiry (DM-7.5)"
  # The CI role's scheduler grants are scoped to the module.eventbridge group (see dfs_balance.tf).
  group_name = module.eventbridge.schedule_group_name

  schedule_expression          = var.rds_snapshot_expiry_schedule_expression
  schedule_expression_timezone = "UTC"

  flexible_time_window {
    mode                      = "FLEXIBLE"
    maximum_window_in_minutes = 30
  }

  target {
    arn      = aws_lambda_function.rds_snapshot_expiry.arn
    role_arn = aws_iam_role.rds_snapshot_expiry_scheduler.arn
    input    = jsonencode({ source = "aa-869-daily" })

    # Delivery retries only (throttled / failed Invoke). A function error is not retried
    # (event invoke config above).
    retry_policy {
      maximum_retry_attempts       = 2
      maximum_event_age_in_seconds = 3600
    }
  }
}
