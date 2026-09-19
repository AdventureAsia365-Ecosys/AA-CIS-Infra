# =============================================================================
# AA-627 — DataForSEO balance daily-check trigger
# EventBridge Scheduler (once/day) -> Lambda -> POST /admin/dfs-balance/check
# (X-Admin-Secret). The backend reads the FREE DFS balance, stores a snapshot,
# and raises a low-balance notification below the threshold. This Lambda is a
# thin trigger: no DFS creds, no DB — only ADMIN_SECRET + the API URL.
#
# Self-contained feature file (same pattern as tripplanner.tf). Zero-dependency
# handler (stdlib urllib only) packaged inline via archive_file — no dist zip to
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

locals {
  dfs_balance_fn_name = "${local.name_prefix}-dfs-balance-check"
}

# ── Package the zero-dependency handler ──────────────────────────────────────
data "archive_file" "dfs_balance" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_src/dfs_balance_check"
  output_path = "${path.module}/lambda_src/dfs_balance_check.zip"
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
  name               = "${local.dfs_balance_fn_name}-exec"
  assume_role_policy = data.aws_iam_policy_document.dfs_balance_assume.json
  tags               = local.common_tags
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
  name               = "${local.dfs_balance_fn_name}-scheduler"
  assume_role_policy = data.aws_iam_policy_document.dfs_balance_scheduler_assume.json
  tags               = local.common_tags
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

    retry_policy {
      maximum_retry_attempts       = 2
      maximum_event_age_in_seconds = 3600
    }
  }
}
