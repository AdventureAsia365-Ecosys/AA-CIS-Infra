# =============================================================================
# AA-861 — the TripPlanner jobs Lambda: the worker of tripplanner.job (root ADR 0003a decision 4).
#
# TripPlanner has no ECS worker. Its job table (tp-021, AA-TripPlanner-Web migrations/021_job_table_outbox_redaction.sql)
# is claimed by this Lambda, woken once a day by EventBridge Scheduler (the rule only wakes; the Lambda queues the day's
# scheduled runs itself with an idempotency key per kind and day, then claims and runs due jobs). The first kind is
# tp_retention_outbox_redact: tripplanner.outbox payload PII is redacted after 90 days (data standards DM-6.6 / DM-7.2),
# DRY RUN until a live run of the same window was approved (destructive-ops.md).
#
# Same code split as browse / assembly (tripplanner.tf): Terraform owns the function, a placeholder zip and the role;
# the AA-TripPlanner-Web deploy workflow ships the real code (jobs.zip, the same package with handler
# backend.jobs.handler.handler) through the app deploy role, which gets this function in tripplanner.tf.
#
# Least privilege: its OWN role, not the browse / assembly one: the DB DSN secret and the Sentry DSN secret by ARN, VPC
# ENIs (AWS managed policy, as the other TripPlanner Lambdas), logs. No Bedrock, no satellite assume, no edge key.
# AA-1093 (tenant offboarding): + s3:PutObject / GetObject on the CIS gold bucket's exports/tenants/*/tripplanner/*
# (tp_tenant_backup, tp_tenant_restore_drill) and the TENANT_ERASE_APPLY_ENABLED switch of tp_tenant_erase (off).
# AA-1038 R5 slice 3 (tp_lead_deliver retries undelivered webhook / e-mail leads): + the lead webhook master key by ARN
# (ReadLeadWebhookKeySecret), SES send as var.ses_from_address only (accounts/aa365 ses.tf tripplanner_jobs_ses_send,
# the same grant as the assembly role) and TP_LEAD_EMAIL_FROM. Both Lambdas get these in the same apply: a retry
# without them stops at the channel breaker and the 7-day hold then ends the lead (loudly). Same security group as browse / assembly (no ingress; the RDS security group already admits it). No API Gateway
# route or Function URL: only the scheduler (its own invoke role) and an operator's `aws lambda invoke` reach it.
#
# Connection budget (data standards C2.2): reserved concurrency 1 x pool 1 = 1 connection of role tripplanner
# (db/connection_budget.json pool tp-jobs; tripplanner 21 / 30, total 121 / 135).
#
# Cost (us-west-1, Dev): one ~5 s run a day at 256 MB ~ 0 USD (free tier); log group 30 days, a few KB a day; two
# alarms 0.20 USD/month; the schedule is free at this volume. About 0.20 USD/month in all.
#
# AA-1093 follow-up (S279, DRILL-01): a second schedule wakes the same function every 5 minutes with
# {"op": "erasure_feed"} only: it reads the CIS erasure request feed (catalog.v_tenant_erasure_v1), queues
# tp_tenant_erase for the new requests and runs due tp_tenant_erase jobs only (AA-TripPlanner-Web
# backend/jobs/handler.py; every other kind keeps the daily tick). Before it, TripPlanner answered a CIS request up to a
# day late while CIS and Booking answered within minutes. Cost: ~8,640 invocations a month of ~1 s at 256 MB (~2,200
# GB-s) and 8,640 scheduler invocations, both far inside the free tiers (1 M requests / 400,000 GB-s; 14 M scheduler
# invocations); a few MB of logs a month; the tick metric filter below emits one data point a day (one metric-hour a
# day, about 0.01 USD/month). About 0 USD/month added. Reserved concurrency 1 is unchanged: the scheduler invokes
# asynchronously, so a run that finds the function busy waits in Lambda's async queue (maximum_event_age 1 h below).
#
# CI apply role (aa-cis-infra-tf-apply) can create everything here: role names aa-tripplanner-dev-* with the workload
# boundary (TripPlannerRoleTagging in cicd.tf), Lambda via AWSLambda_FullAccess, log group / alarms via
# CloudWatchFullAccess, and the schedule sits in the module.eventbridge group (EventBridgeSchedulerScheduleManage,
# same as rds_snapshot_expiry.tf).
# =============================================================================

variable "tripplanner_jobs_schedule_expression" {
  description = "AA-861 — when the TripPlanner jobs Lambda wakes (queues the daily runs, then runs due jobs)"
  type        = string
  # 19:30 UTC = 02:30 ICT: outside VN working hours, after Booking's 19:00 retention runs, before the 20:30 CIS
  # retention enqueue and the 22:00 snapshot expiry, away from the RDS backup window (03:00-04:00 UTC).
  default = "cron(30 19 * * ? *)"
}

variable "tripplanner_jobs_erasure_feed_schedule_expression" {
  description = "AA-1093 — how often the TripPlanner jobs Lambda reads the CIS erasure request feed (op erasure_feed: queues and runs tp_tenant_erase only)"
  type        = string
  # Booking reads the same feed every 300 s (EraseSchedule); CIS shows each app's report on the saga page.
  default = "rate(5 minutes)"
}

variable "tripplanner_jobs_retention_override_enabled" {
  description = "AA-861 — \"true\" (exact string) opens the LIVE manual_override of tp_retention_outbox_redact on this deployment (Dev proof runs before rows reach 90 days); a DRY RUN override never needs it"
  type        = string
  # Closed by default: a live override redacts Dev outbox rows younger than 90 days. Open it only for an approved
  # proof run (destructive-ops.md), then close it again.
  default = "false"

  validation {
    condition     = contains(["true", "false"], var.tripplanner_jobs_retention_override_enabled)
    error_message = "tripplanner_jobs_retention_override_enabled must be \"true\" or \"false\"."
  }
}

variable "tripplanner_jobs_tenant_erase_apply_enabled" {
  description = "AA-1093 — \"true\" (exact string) lets tp_tenant_erase APPLY an approved erasure plan on this deployment (TENANT_ERASE_APPLY_ENABLED); a DRY RUN, a verify, a backup and a restore drill never need it"
  type        = string
  # Closed by default: an apply deletes every TripPlanner row of a tenant. Open it only for an approved erasure (on Dev:
  # a synthetic tenant, the end-to-end offboarding drill), then close it again.
  default = "false"

  validation {
    condition     = contains(["true", "false"], var.tripplanner_jobs_tenant_erase_apply_enabled)
    error_message = "tripplanner_jobs_tenant_erase_apply_enabled must be \"true\" or \"false\"."
  }
}

locals {
  tp_jobs_fn_name = "${local.tp_name_prefix}-jobs"
  tp_jobs_tags    = merge(local.tp_tags, { Component = "jobs", Issue = "AA-861" })
}

# ── Placeholder artifact (the app deploy replaces it; see tripplanner_browse_zip) ──
resource "aws_s3_object" "tripplanner_jobs_zip" {
  bucket = aws_s3_bucket.tripplanner_artifacts.id
  key    = "jobs.zip"
  source = local.tp_placeholder_zip
  etag   = filemd5(local.tp_placeholder_zip)

  lifecycle {
    # metadata: deploy-lambdas.yml writes git-sha / app-version / code-sha256 on upload (AA-993 V4 verify).
    ignore_changes = [etag, source, metadata]
  }

  # AA-846: no object tags (`aws s3 cp` in the deploy drops them), so the plan stays "No changes".
  override_provider {
    default_tags {
      tags = {}
    }
  }
}

# ── Execution role ───────────────────────────────────────────────────────────
resource "aws_iam_role" "tripplanner_jobs_exec" {
  name                 = "${local.tp_jobs_fn_name}-exec"
  permissions_boundary = var.permissions_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.tp_jobs_tags
}

# ENI-in-VPC (reach RDS) — AWS-managed policy, same as the browse / assembly role.
resource "aws_iam_role_policy_attachment" "tripplanner_jobs_vpc" {
  role       = aws_iam_role.tripplanner_jobs_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "tripplanner_jobs_permissions" {
  name = "${local.tp_jobs_fn_name}-permissions"
  role = aws_iam_role.tripplanner_jobs_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadDbSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.tripplanner_db.arn]
      },
      {
        # AA-871: the Sentry DSN, read by name at cold start (backend/shared/observability.py).
        Sid      = "ReadSentryDsnSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.tripplanner_sentry_dsn.arn]
      },
      {
        # AA-1038: the lead webhook master key (tripplanner.tf), read by name for the tp_lead_deliver retries.
        Sid      = "ReadLeadWebhookKeySecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.tripplanner_lead_webhook_key.arn]
      },
      {
        # AA-1093 part 3: tp_tenant_backup writes and tp_tenant_restore_drill reads one tenant's TripPlanner backup in
        # the CIS gold bucket, its own prefix only (the bucket rule exports-expire deletes exports/ after 7 days). No
        # ListBucket: every object name is fixed and the backup job names its prefix. SSE-S3 is the bucket default.
        Sid      = "TenantExportObjects"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = ["${var.gold_bucket_arn}/exports/tenants/*/tripplanner/*"]
      },
      {
        Sid      = "WriteOwnLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.tripplanner_jobs.arn}:log-stream:*"
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "tripplanner_jobs" {
  name              = "/aws/lambda/${local.tp_jobs_fn_name}"
  retention_in_days = 30 # AA-872 (S241 D-09): app logs 30 days
  tags              = local.tp_jobs_tags
}

# ── The function ─────────────────────────────────────────────────────────────
resource "aws_lambda_function" "tripplanner_jobs" {
  function_name = local.tp_jobs_fn_name
  description   = "AA-861: tripplanner.job worker (daily tick, outbox PII redaction after 90 days)"
  role          = aws_iam_role.tripplanner_jobs_exec.arn
  runtime       = "python3.12"
  handler       = "backend.jobs.handler.handler"
  # A run stops claiming with 45 s left (backend/jobs/runner.py MIN_TIME_LEFT_S); a claimed job's lease is the time
  # left + 60 s, so a killed run's job is reaped by the next one.
  timeout     = 300
  memory_size = 256

  # One runner at a time, one DB connection (connection budget C2.2, pool tp-jobs).
  reserved_concurrent_executions = var.tripplanner_jobs_reserved_concurrency

  s3_bucket = aws_s3_bucket.tripplanner_artifacts.id
  s3_key    = "jobs.zip"

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [var.tripplanner_lambda_security_group_id] # ADR 0004b: same no-ingress SG as browse / assembly
  }

  environment {
    variables = {
      # ENVIRONMENT also names the Sentry DSN secret (tripplanner/<ENVIRONMENT>/sentry-dsn) and is half of the
      # live-override gate (backend/jobs/outbox_redact.py override_gate).
      ENVIRONMENT                  = var.environment
      TRIPPLANNER_DATABASE_URL_ARN = aws_secretsmanager_secret.tripplanner_db.arn
      # backend/config.py reads the AWS region of its Secrets Manager client from this name (no Bedrock call here).
      BEDROCK_REGION             = var.aws_region
      RETENTION_OVERRIDE_ENABLED = var.tripplanner_jobs_retention_override_enabled
      # AA-1038: the From of the lead e-mail retries (same value and grant as the assembly Lambda, tripplanner.tf).
      TP_LEAD_EMAIL_FROM = var.ses_from_address
      # AA-1093: the bucket of the per-tenant backups (backend/jobs/tenant_store.py) and the apply switch of
      # tp_tenant_erase (backend/jobs/tenant_erase.py; default off, an apply also needs an approved plan hash).
      TENANT_EXPORT_BUCKET       = var.gold_bucket_name
      TENANT_ERASE_APPLY_ENABLED = var.tripplanner_jobs_tenant_erase_apply_enabled
    }
  }

  tags = merge(local.tp_jobs_tags, { Function = "tripplanner-jobs" })

  depends_on = [
    aws_s3_object.tripplanner_jobs_zip,
    aws_cloudwatch_log_group.tripplanner_jobs,
    aws_iam_role_policy.tripplanner_jobs_permissions,
    aws_iam_role_policy_attachment.tripplanner_jobs_vpc,
  ]

  lifecycle {
    ignore_changes = [s3_object_version, source_code_hash, s3_key]
  }
}

# Scheduler invokes asynchronously: no Lambda retry. A tick that redacted rows and then failed must not run again the
# same day (the job is not retried either: max_attempts 1); the Errors alarm reports it.
resource "aws_lambda_function_event_invoke_config" "tripplanner_jobs" {
  function_name                = aws_lambda_function.tripplanner_jobs.function_name
  maximum_retry_attempts       = 0
  maximum_event_age_in_seconds = 3600
}

# ── Alarms ───────────────────────────────────────────────────────────────────
# A tick raises (invocation error) when a job failed or a retention run was HELD (more than 2x the last live run):
# both need a person. One error is enough for a daily function. Event alarm: ALARM e-mail only (S263, AA-1025).
resource "aws_cloudwatch_metric_alarm" "tripplanner_jobs_errors" {
  alarm_name          = "${local.tp_jobs_fn_name}-errors"
  alarm_description   = "AA-861: the TripPlanner jobs Lambda failed or reported a job that needs attention (failed job, or tp_retention_outbox_redact HELD over 2x the last live run). Read its log group (job_finished / jobs_run lines) and the job: aws lambda invoke --function-name ${local.tp_jobs_fn_name} with {\"op\":\"status\"}.${var.runbook_suffix.queue_stuck}"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.tripplanner_jobs.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alerts_topic_arn]
  tags                = local.tp_jobs_tags
}

# The daily tick stopped (rule disabled or deleted, invoke role broken): no tick for two whole days. Since the 5-minute
# erasure feed (AA-1093) invokes the function all day, Invocations no longer proves the tick runs: the alarm counts the
# tick's own log line ({"evt": "jobs_run", "op": "tick"}, written by every tick that reached the database, also one that
# then raises for attention). Event metric, no default_value (billed only in hours with a tick). Missing data is
# breaching, so two days without the line alarm, and it is in ALARM from its creation until the first tick: after the
# first apply, once the app deploy has shipped the real code, invoke {"op":"tick"} once (AA-TripPlanner-Web
# docs/jobs-runbook.md "Alarms"; never before the code deploy, the placeholder fails).
resource "aws_cloudwatch_log_metric_filter" "tripplanner_jobs_tick" {
  name           = "${local.tp_jobs_fn_name}-tick-runs"
  log_group_name = aws_cloudwatch_log_group.tripplanner_jobs.name
  pattern        = "{ ($.evt = \"jobs_run\") && ($.op = \"tick\") }"

  metric_transformation {
    name      = "JobsTickRuns"
    namespace = "AA/TripPlanner"
    value     = "1"
    unit      = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "tripplanner_jobs_not_run" {
  alarm_name          = "${local.tp_jobs_fn_name}-not-run"
  alarm_description   = "AA-861: the TripPlanner jobs Lambda ran no daily tick for 2 days (its daily EventBridge schedule ${local.tp_jobs_fn_name}-daily stopped, or every tick failed before the database). Outbox PII redaction (DM-6.6), the lead retries and the tenant backups are not running.${var.runbook_suffix.queue_stuck}"
  namespace           = aws_cloudwatch_log_metric_filter.tripplanner_jobs_tick.metric_transformation[0].namespace
  metric_name         = aws_cloudwatch_log_metric_filter.tripplanner_jobs_tick.metric_transformation[0].name
  statistic           = "Sum"
  period              = 86400
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [var.alerts_topic_arn]
  ok_actions          = [var.alerts_topic_arn]
  tags                = local.tp_jobs_tags
}

# ── EventBridge Scheduler → Lambda (dedicated invoke role) ───────────────────
# First rollout: apply this file and deploy the app code on the same day, between two ticks (19:30 UTC). A tick that
# reaches the placeholder zip fails with an import error (writes nothing) and fires the errors alarm; tp-021 must be
# applied by DB Migrate before this apply (AA-861 implementation notes, "Order").
resource "aws_iam_role" "tripplanner_jobs_scheduler" {
  name                 = "${local.tp_jobs_fn_name}-scheduler"
  permissions_boundary = var.permissions_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = var.account_id } }
    }]
  })

  tags = local.tp_jobs_tags
}

resource "aws_iam_role_policy" "tripplanner_jobs_scheduler_invoke" {
  name = "invoke-tripplanner-jobs-lambda"
  role = aws_iam_role.tripplanner_jobs_scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.tripplanner_jobs.arn
    }]
  })
}

resource "aws_scheduler_schedule" "tripplanner_jobs_daily" {
  name        = "${local.tp_jobs_fn_name}-daily"
  description = "AA-861 — daily tick of the TripPlanner jobs Lambda (tripplanner.job; outbox PII redaction, DM-6.6)"
  # The CI role's scheduler grants are scoped to the module.eventbridge group (see dfs_balance.tf).
  group_name = var.eventbridge_schedule_group_name

  schedule_expression          = var.tripplanner_jobs_schedule_expression
  schedule_expression_timezone = "UTC"

  flexible_time_window {
    mode                      = "FLEXIBLE"
    maximum_window_in_minutes = 30
  }

  target {
    arn      = aws_lambda_function.tripplanner_jobs.arn
    role_arn = aws_iam_role.tripplanner_jobs_scheduler.arn
    input    = jsonencode({ op = "tick", source = "aa-861-daily" })

    # Delivery retries only (throttled / failed Invoke). A function error is not retried (event invoke config).
    retry_policy {
      maximum_retry_attempts       = 2
      maximum_event_age_in_seconds = 3600
    }
  }
}

# AA-1093 follow-up (S279): the 5-minute read of the CIS erasure request feed. Same invoke role as the daily tick (it
# may invoke this function only). No flexible window: a drill expects the report within one period. No delivery
# retry and a short event age: a missed run is replaced by the next one 5 minutes later (the idempotency key per
# request, round and phase makes a late or doubled run queue nothing twice).
resource "aws_scheduler_schedule" "tripplanner_jobs_erasure_feed" {
  name        = "${local.tp_jobs_fn_name}-erasure-feed"
  description = "AA-1093 — the TripPlanner jobs Lambda reads the CIS erasure request feed (op erasure_feed; tp_tenant_erase only)"
  group_name  = var.eventbridge_schedule_group_name

  schedule_expression          = var.tripplanner_jobs_erasure_feed_schedule_expression
  schedule_expression_timezone = "UTC"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.tripplanner_jobs.arn
    role_arn = aws_iam_role.tripplanner_jobs_scheduler.arn
    input    = jsonencode({ op = "erasure_feed", source = "aa-1093-erasure-feed" })

    retry_policy {
      maximum_retry_attempts       = 0
      maximum_event_age_in_seconds = 300
    }
  }
}

output "tripplanner_jobs_function_name" {
  value = aws_lambda_function.tripplanner_jobs.function_name
}
