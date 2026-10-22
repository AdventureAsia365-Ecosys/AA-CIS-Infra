# =============================================================================
# AA-627 + AA-720 — daily ops-probe trigger (one Lambda, several admin POSTs)
# EventBridge Scheduler (once/day) -> Lambda -> secret-gated admin POSTs
# (X-Admin-Secret). The Lambda is a thin trigger only (no vendor creds, no DB);
# each backend endpoint does its own work and raises its own throttled bell.
# Paths (see lambda_src/dfs_balance_check/handler.py _PATHS):
#   AA-627  /admin/dfs-balance/check — FREE DFS balance snapshot + low-balance bell.
#   AA-720  /admin/jev-canary/check  — one real Jev probe; 402 -> credit bell + breaker.
#   AA-720  /admin/jev/402-sweep     — count decision_log 402s in 24h; bell if any.
#   AA-727  /admin/waves/check       — open rerun waves; bell on a stuck tour.
#   AA-816  /admin/job-runner/staff-reconcile/schedule — enqueue the daily staff directory
#           reconcile (WORKFORCE pool vs shared.admin_users, report only; idempotent per UTC day).
#           S243: one more _PATHS entry, no new schedule, role or variable.
# AA-825 adds a SECOND schedule on the same Lambda (retention_daily, 20:30 UTC) whose
# event names one path, /admin/job-runner/retention/schedule (enqueue the CIS
# retention kinds, idempotent per UTC day). Its own hour keeps the retention jobs off
# the 06:00 ACP ingest / 06:15 probes and out of VN working hours (Deploy Dev guard).
# AA-844 adds a THIRD schedule on the same Lambda (photo_sync_daily, 21:00 UTC = 04:00 ICT, after
# retention) whose event names /admin/photos/sync/schedule: one incremental photo_sync job per
# country, idempotent per UTC day. No new role, variable for the secret, or group.
# AA-871 adds a FOURTH schedule on the same Lambda (booking_uptime, every 5 minutes) whose event is
# {"health": "booking"}: a plain GET of the public Booking health URL (var.booking_health_url, Lambda env
# BOOKING_HEALTH_URL), no secret read, no admin POST; an unhealthy answer RAISES, so it shows in the
# function's AWS/Lambda Errors metric and alarm aa-booking-dev-uptime below e-mails the alerts topic.
# Cost (us-west-1, 22/10/2026): ~8.7k invocations/month at 128 MB (Lambda + Scheduler both inside free
# tier / ~0.02 USD), one standard alarm 0.10 USD, logs a few MB: ~0.15 USD/month. No new role or group.
# AA-832 once added a schedule (rds_role_connections, every 5 minutes) that POSTed
# /admin/job-runner/rds-role-connections/schedule so the CIS worker published AA/RDS. AA-751 (S240)
# removed it: the CIS api publishes AA/RDS (and AA/Jobs/CIS) itself from an in-process sampler
# (api/core/ops_metrics_sampler.py), so the Lambda, API Gateway, WAF and shared.job are no longer
# in the metrics path; the path is gone from the handler allowlist too.
# All schedules pass secret_id in the event, so the handler reads X-Admin-Secret from
# Secrets Manager at run time by ARN (the role has GetSecretValue on exactly that ARN).
# AA-878 (S243): that is the ONLY source. The ADMIN_SECRET env and the secret-version data
# source are gone, so the plaintext is neither in the Lambda configuration nor in Terraform
# state, and terraform plan no longer reads the value (tf_plan_secret_arns in cicd_split.tf
# shrank with it). No secret_id or a failed read -> the handler fails closed, no API call.
# Kept as ONE function (name unchanged: renaming the IAM role would destroy+create
# it, a permission gap — S200). AA-720 only widened the handler's _PATHS; no new
# AWS resource, role or schedule — the archive_file re-zips on the handler change
# and updates the existing Lambda in place.
#
# Self-contained feature file (same pattern as tripplanner.tf). Zero-dependency
# handler (stdlib urllib + the runtime's bundled boto3) packaged inline via archive_file — no dist zip to
# pre-build, no CI change.
# =============================================================================

# The API base URL the Lambda POSTs to. Defaults to the live Dev domain that
# actually resolves (var.domain_name is the account's own hostname, which may
# differ); overridable per-env. The endpoint is public HTTPS (WAF-fronted).
variable "dfs_balance_api_base_url" {
  description = "AA-627 — base URL the balance-check Lambda POSTs to (no trailing slash)"
  type        = string
  default     = "https://api-cis.lumiguides.it.com"
}

# Cron: once a day at 06:15 UTC (offset from the 06:00 ACP ingest to avoid a
# thundering herd). DFS balance changes slowly; daily is plenty.
variable "dfs_balance_schedule_expression" {
  description = "AA-627 — schedule for the daily DFS balance check"
  type        = string
  default     = "cron(15 6 * * ? *)"
}

# AA-825 — the daily retention enqueue. 20:30 UTC = 03:30 ICT: nobody deploys, no ACP
# schedule near it (06:00 ingest, 06:15 probes, Wed 18:00 veto, Sun 23:00 export), and
# the 30 min flexible window still ends before 00:00 UTC, so the UTC day the API keys
# its idempotency on is the day the schedule meant.
variable "retention_schedule_expression" {
  description = "AA-825 — schedule for POST /admin/job-runner/retention/schedule"
  type        = string
  default     = "cron(30 20 * * ? *)"
}

# AA-844 — the daily photo_sync enqueue. 21:00 UTC = 04:00 ICT, after retention (20:30) so the two
# sets of jobs do not start together, and the 30 min flexible window still ends before 00:00 UTC,
# so the UTC day the API keys its idempotency on is the day the schedule meant.
variable "photo_sync_schedule_expression" {
  description = "AA-844 — schedule for POST /admin/photos/sync/schedule"
  type        = string
  default     = "cron(0 21 * * ? *)"
}

# AA-871 — Booking uptime probe (public path). Empty URL = no schedule and no alarm.
variable "booking_health_url" {
  description = "AA-871 — Booking public health URL the ops-probe Lambda GETs every 5 minutes (https://, empty = probe off)"
  type        = string
  default     = "https://api-booking.lumiguides.it.com/booking/health"

  validation {
    condition     = var.booking_health_url == "" || startswith(var.booking_health_url, "https://")
    error_message = "booking_health_url must be empty or an https:// URL."
  }
}

variable "booking_uptime_schedule_expression" {
  description = "AA-871 — schedule for the Booking uptime probe"
  type        = string
  default     = "rate(5 minutes)"
}

locals {
  dfs_balance_fn_name    = "${local.name_prefix}-dfs-balance-check"
  booking_uptime_enabled = var.booking_health_url != ""
}

# ── Package the zero-dependency handler ──────────────────────────────────────
data "archive_file" "dfs_balance" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_src/dfs_balance_check"
  output_path = "${path.module}/lambda_src/dfs_balance_check.zip"

  # S240 lesson: a test that imports handler.py writes __pycache__/ next to it, and archive_file
  # zips the whole directory, so a local plan/apply showed a source_code_hash drift. Never package
  # bytecode.
  excludes = ["__pycache__", "__pycache__/**", "**/*.pyc"]

  # AA-806: the zip stores the source file's mode, and the CI checkout writes handler.py as 0600
  # while a local checkout has 0644, so CI and local applies kept re-uploading the same code
  # (hash oTsj... in CI vs Qekb... locally). A fixed mode makes the hash the same everywhere.
  output_file_mode = "0666"
}

# ── Lambda execution role ────────────────────────────────────────────────────
data "aws_iam_policy_document" "dfs_balance_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dfs_balance_exec" {
  name                 = "${local.dfs_balance_fn_name}-exec"
  permissions_boundary = aws_iam_policy.workload_boundary.arn
  assume_role_policy   = data.aws_iam_policy_document.dfs_balance_assume.json
  tags                 = local.common_tags
}

# VPC ENI management for a Lambda placed in the VPC (parity with the other app Lambdas).
resource "aws_iam_role_policy_attachment" "dfs_balance_vpc" {
  role       = aws_iam_role.dfs_balance_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "dfs_balance_perms" {
  name = "${local.dfs_balance_fn_name}-perms"
  role = aws_iam_role.dfs_balance_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.aws_region}:${var.account_id}:*"
      },
      {
        Sid      = "ReadAdminSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [var.secret_admin_arn]
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "dfs_balance" {
  name              = "/aws/lambda/${local.dfs_balance_fn_name}"
  retention_in_days = 30 # AA-872 (S241 D-09): app logs 30 days
  tags              = local.common_tags
}

# ── Lambda function ──────────────────────────────────────────────────────────
resource "aws_lambda_function" "dfs_balance_check" {
  function_name = local.dfs_balance_fn_name
  role          = aws_iam_role.dfs_balance_exec.arn
  handler       = "handler.handler"
  runtime       = "python3.12"
  timeout       = 30
  memory_size   = 128

  filename         = data.archive_file.dfs_balance.output_path
  source_code_hash = data.archive_file.dfs_balance.output_base64sha256

  # In-VPC (private subnets + ops-lambda SG) for parity with the other app Lambdas and
  # to sit on the trusted egress path fronting the WAF-protected API.
  vpc_config {
    subnet_ids         = module.vpc.private_subnet_ids
    security_group_ids = [aws_security_group.ops_lambda.id] # ADR 0004b (X1 S13b): NAT egress only, no data store
  }

  environment {
    # AA-878: no ADMIN_SECRET here; the handler reads it by ARN (event secret_id) at run time.
    variables = {
      API_BASE_URL       = var.dfs_balance_api_base_url
      BOOKING_HEALTH_URL = var.booking_health_url # AA-871 uptime target "booking" (public URL, no secret)
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.dfs_balance,
    aws_iam_role_policy_attachment.dfs_balance_vpc,
  ]

  tags = merge(local.common_tags, { Function = "dfs-balance-check", Issue = "AA-627" })
}

# ── EventBridge Scheduler → Lambda (dedicated invoke role) ───────────────────
# The shared module.eventbridge scheduler role only has events:PutEvents (cannot
# invoke a Lambda), so this feature gets its own minimal invoke role.
data "aws_iam_policy_document" "dfs_balance_scheduler_assume" {
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

resource "aws_iam_role" "dfs_balance_scheduler" {
  name                 = "${local.dfs_balance_fn_name}-scheduler"
  permissions_boundary = aws_iam_policy.workload_boundary.arn
  assume_role_policy   = data.aws_iam_policy_document.dfs_balance_scheduler_assume.json
  tags                 = local.common_tags
}

resource "aws_iam_role_policy" "dfs_balance_scheduler_invoke" {
  name = "invoke-dfs-balance-lambda"
  role = aws_iam_role.dfs_balance_scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.dfs_balance_check.arn
    }]
  })
}

resource "aws_scheduler_schedule" "dfs_balance_daily" {
  name = "${local.dfs_balance_fn_name}-daily"
  # Use the module.eventbridge schedule group (aa-cis-dev-acp) rather than "default":
  # the CI role's IAM policy scopes scheduler:GetSchedule/CreateSchedule/etc to
  # schedule/aa-cis-dev-acp/* (accounts/aa365/cicd.tf "EventBridgeSchedulerScheduleManage"),
  # so a schedule in "default" makes every CI terraform plan fail on GetSchedule (403).
  group_name = module.eventbridge.schedule_group_name

  schedule_expression          = var.dfs_balance_schedule_expression
  schedule_expression_timezone = "UTC"

  flexible_time_window {
    mode                      = "FLEXIBLE"
    maximum_window_in_minutes = 30
  }

  target {
    arn      = aws_lambda_function.dfs_balance_check.arn
    role_arn = aws_iam_role.dfs_balance_scheduler.arn

    # AA-825: no "paths" -> the handler's default probe set (incl. the AA-816 staff
    # reconcile); secret_id -> read the admin secret at run time (AA-878: required, no
    # fallback; removing it makes every run fail closed).
    input = jsonencode({ secret_id = var.secret_admin_arn })

    retry_policy {
      maximum_retry_attempts       = 2
      maximum_event_age_in_seconds = 3600
    }
  }
}

# ── AA-825 — daily retention enqueue (same Lambda, invoke role and group) ────
# POST /admin/job-runner/retention/schedule enqueues one shared.job per CIS retention
# kind with idempotency_key retention:<kind>:<UTC day>, so a Scheduler retry or a
# second call the same day creates nothing new. Whether each kind runs as a DRY RUN,
# live or held is decided by the kind (DM-7.2), not here.
resource "aws_scheduler_schedule" "retention_daily" {
  name        = "${local.name_prefix}-retention-daily"
  description = "AA-825 — daily POST /admin/job-runner/retention/schedule via the ops-probe Lambda"
  # Same group as dfs_balance_daily: the CI role's scheduler grants are scoped to it.
  group_name = module.eventbridge.schedule_group_name

  schedule_expression          = var.retention_schedule_expression
  schedule_expression_timezone = "UTC"

  flexible_time_window {
    mode                      = "FLEXIBLE"
    maximum_window_in_minutes = 30
  }

  target {
    arn      = aws_lambda_function.dfs_balance_check.arn
    role_arn = aws_iam_role.dfs_balance_scheduler.arn

    input = jsonencode({
      paths     = ["/admin/job-runner/retention/schedule"]
      secret_id = var.secret_admin_arn
    })

    retry_policy {
      maximum_retry_attempts       = 2
      maximum_event_age_in_seconds = 3600
    }
  }
}

# ── AA-844 — daily photo_sync enqueue (same Lambda, invoke role and group) ───
# POST /admin/photos/sync/schedule enqueues one incremental photo_sync job per country folder with
# idempotency_key photo_sync:schedule:<country>:<UTC day> (all or none, one transaction), so a
# Scheduler retry or a second call the same day creates nothing new. It skips while another
# photo_sync job (a manual run, or yesterday's still running) is queued or running. If this fires
# before the CIS endpoint is deployed, the Lambda logs the 404 and returns; nothing retries.
resource "aws_scheduler_schedule" "photo_sync_daily" {
  name        = "${local.name_prefix}-photo-sync-daily"
  description = "AA-844 — daily POST /admin/photos/sync/schedule via the ops-probe Lambda"
  # Same group as dfs_balance_daily: the CI role's scheduler grants are scoped to it.
  group_name = module.eventbridge.schedule_group_name

  schedule_expression          = var.photo_sync_schedule_expression
  schedule_expression_timezone = "UTC"

  flexible_time_window {
    mode                      = "FLEXIBLE"
    maximum_window_in_minutes = 30
  }

  target {
    arn      = aws_lambda_function.dfs_balance_check.arn
    role_arn = aws_iam_role.dfs_balance_scheduler.arn

    input = jsonencode({
      paths     = ["/admin/photos/sync/schedule"]
      secret_id = var.secret_admin_arn
    })

    retry_policy {
      maximum_retry_attempts       = 2
      maximum_event_age_in_seconds = 3600
    }
  }
}

# ── AA-871 — Booking uptime probe (same Lambda, invoke role and group) ───────
# Every 5 minutes, no flexible window: GET var.booking_health_url (DNS -> custom domain -> REST API ->
# VPC link -> NLB -> ALB rule -> task) and expect 200 + {"status": "ok"}. Complements the target-group
# alarms in observability_ecosys.tf (they see the task, not the public edge). Scheduler invokes the
# Lambda asynchronously, so a failed probe is retried by Lambda (up to 2 more GETs within ~3 minutes);
# retry_policy here only covers delivery failures and is off so one tick is one probe.
resource "aws_scheduler_schedule" "booking_uptime" {
  count = local.booking_uptime_enabled ? 1 : 0

  name        = "${local.name_prefix}-booking-uptime"
  description = "AA-871 — GET ${var.booking_health_url} every 5 minutes via the ops-probe Lambda"
  # Same group as dfs_balance_daily: the CI role's scheduler grants are scoped to it.
  group_name = module.eventbridge.schedule_group_name

  schedule_expression          = var.booking_uptime_schedule_expression
  schedule_expression_timezone = "UTC"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.dfs_balance_check.arn
    role_arn = aws_iam_role.dfs_balance_scheduler.arn

    input = jsonencode({ health = "booking" })

    retry_policy {
      maximum_retry_attempts       = 0
      maximum_event_age_in_seconds = 300
    }
  }
}

# Errors of the ops-probe function in 2 consecutive 5-minute periods (~10 minutes of failed probes).
# The other schedules on this function never raise (they return a status body), so in practice this
# counts failed uptime probes plus any crash of the function, both worth an e-mail. It also fires while
# Booking is scaled to 0 on purpose (same as aa-booking-dev-jobs-sampling-stopped).
resource "aws_cloudwatch_metric_alarm" "booking_uptime" {
  count = local.booking_uptime_enabled ? 1 : 0

  alarm_name          = "${local.bk_name_prefix}-uptime"
  alarm_description   = "AA-Booking public health ${var.booking_health_url} failed the ops-probe GET (not 200 + status ok) in 2 consecutive 5-minute periods, or the ops-probe Lambda ${local.dfs_balance_fn_name} crashed.${local.runbook_suffix.api_5xx}"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.dfs_balance_check.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn] # S241 D-20: recovery e-mail too

  tags = merge(local.ecosys_tags, { App = "booking", Issue = "AA-871" })
}
