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
# AA-825 adds a SECOND schedule on the same Lambda (retention_daily, 20:30 UTC) whose
# event names one path, /admin/job-runner/retention/schedule (enqueue the CIS
# retention kinds, idempotent per UTC day). Its own hour keeps the retention jobs off
# the 06:00 ACP ingest / 06:15 probes and out of VN working hours (Deploy Dev guard).
# AA-832 added a third schedule (rds_role_connections, every 5 minutes) that POSTed
# /admin/job-runner/rds-role-connections/schedule so the CIS worker published AA/RDS. AA-751 (S240)
# removed it: the CIS api publishes AA/RDS (and AA/Jobs/CIS) itself from an in-process sampler
# (api/core/ops_metrics_sampler.py), so the Lambda, API Gateway, WAF and shared.job are no longer
# in the metrics path; the path is gone from the handler allowlist too.
# All schedules pass secret_id in the event, so the handler reads X-Admin-Secret from
# Secrets Manager at run time (the role already has GetSecretValue on it); the
# deploy-time env value stays as the fallback.
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

locals {
  dfs_balance_fn_name = "${local.name_prefix}-dfs-balance-check"
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

# ── Read the admin secret value to inject as the Lambda env (authorizer pattern) ─
data "aws_secretsmanager_secret_version" "dfs_balance_admin" {
  secret_id = var.secret_admin_arn
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
  retention_in_days = 14
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

  # In-VPC (private subnets + app SG) for parity with the other app Lambdas and
  # to sit on the trusted egress path fronting the WAF-protected API.
  vpc_config {
    subnet_ids         = module.vpc.private_subnet_ids
    security_group_ids = [module.vpc.sg_app_id]
  }

  environment {
    variables = {
      API_BASE_URL = var.dfs_balance_api_base_url
      ADMIN_SECRET = data.aws_secretsmanager_secret_version.dfs_balance_admin.secret_string
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

    # AA-825: no "paths" -> the handler's default probe set; secret_id -> read the
    # admin secret at run time (env value is the fallback).
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
