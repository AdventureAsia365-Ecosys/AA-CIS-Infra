# =============================================================================
# AA-CIS Lambda Module — S11 Phase 4
# Functions: Ingestion, SEO Intelligence, Validation, Export
# S3 trigger: Bronze bucket raw-inbox/ → Ingestion Lambda
# =============================================================================

locals {
  name_prefix = "${var.project}-${var.environment}"

  common_tags = merge(var.tags, {
    Module = "lambda"
    Layer  = "compute"
  })

  # Environment variables shared across all Lambdas
  common_env = {
    ENVIRONMENT    = var.environment
    DATABASE_URL   = var.database_url
    REDIS_URL      = var.redis_url
    AWS_ACCOUNT_ID = var.account_id
  }
}

# =============================================================================
# IAM — Lambda Execution Role (shared)
# =============================================================================

resource "aws_iam_role" "lambda_exec" {
  name = "${local.name_prefix}-lambda-exec"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "lambda_permissions" {
  name = "${local.name_prefix}-lambda-permissions"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # S3 — Bronze read + Gold write
      {
        Sid    = "S3BronzeRead"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket", "s3:DeleteObject"]
        Resource = [
          var.bronze_bucket_arn,
          "${var.bronze_bucket_arn}/*"
        ]
      },
      {
        Sid    = "S3GoldWrite"
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
        Resource = [
          var.gold_bucket_arn,
          "${var.gold_bucket_arn}/*"
        ]
      },
      # Secrets Manager
      {
        Sid    = "SecretsRead"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = [
          var.secret_rds_arn,
          var.secret_openai_arn,
          var.secret_langfuse_arn
        ]
      },
      # Step Functions — Ingestion triggers SF execution
      {
        Sid      = "StepFunctionsStart"
        Effect   = "Allow"
        Action   = ["states:StartExecution"]
        Resource = ["*"]
      },
      # ECS — Step Functions calls RunTask via Lambda (or direct SF integration)
      {
        Sid    = "ECSRunTask"
        Effect = "Allow"
        Action = [
          "ecs:RunTask",
          "ecs:DescribeTasks",
          "ecs:StopTask"
        ]
        Resource = ["*"]
      },
      {
        Sid      = "PassRoleECS"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = ["*"]
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ecs-tasks.amazonaws.com"
          }
        }
      },
      # CloudWatch Logs
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${var.account_id}:*"
      },
      # SQS (for future DLQ)
      {
        Sid    = "SQSAccess"
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = "arn:aws:sqs:${var.aws_region}:${var.account_id}:*"
      }
    ]
  })
}

# =============================================================================
# CloudWatch Log Groups
# =============================================================================

resource "aws_cloudwatch_log_group" "ingestion" {
  name              = "/aws/lambda/${local.name_prefix}-ingestion"
  retention_in_days = 14
  tags              = local.common_tags
}

resource "aws_cloudwatch_log_group" "seo" {
  name              = "/aws/lambda/${local.name_prefix}-seo"
  retention_in_days = 14
  tags              = local.common_tags
}

resource "aws_cloudwatch_log_group" "validation" {
  name              = "/aws/lambda/${local.name_prefix}-validation"
  retention_in_days = 14
  tags              = local.common_tags
}

resource "aws_cloudwatch_log_group" "export" {
  name              = "/aws/lambda/${local.name_prefix}-export"
  retention_in_days = 14
  tags              = local.common_tags
}

# =============================================================================
# LAMBDA 1 — Ingestion
# Trigger: S3 PutObject raw-inbox/
# Output:  INSERT raw_tours → StartExecution StepFunctions
# =============================================================================

resource "aws_lambda_function" "ingestion" {
  function_name = "${local.name_prefix}-ingestion"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "services.ingestion.handler.lambda_handler"
  runtime       = "python3.12"
  timeout       = 300  # 5 min — Excel parse can be slow for large files
  memory_size   = 512

  filename         = "${var.lambda_zip_dir}/ingestion.zip"
  source_code_hash = filebase64sha256("${var.lambda_zip_dir}/ingestion.zip")

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [var.sg_app_id]
  }

  environment {
    variables = merge(local.common_env, {
      STEP_FUNCTIONS_ARN = var.step_functions_arn
      BRONZE_BUCKET      = var.bronze_bucket_name
    })
  }

  depends_on = [
    aws_cloudwatch_log_group.ingestion,
    aws_iam_role_policy_attachment.lambda_vpc,
  ]

  tags = merge(local.common_tags, { Function = "ingestion" })
}

# S3 → Lambda trigger
resource "aws_lambda_permission" "s3_invoke_ingestion" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ingestion.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = var.bronze_bucket_arn
}

resource "aws_s3_bucket_notification" "bronze_trigger" {
  bucket = var.bronze_bucket_name

  lambda_function {
    lambda_function_arn = aws_lambda_function.ingestion.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "raw-inbox/"
    filter_suffix       = ".xlsx"
  }

  depends_on = [aws_lambda_permission.s3_invoke_ingestion]
}

# =============================================================================
# LAMBDA 2 — SEO Intelligence
# Trigger: Step Functions Task (direct invoke)
# Input:   {destination, activity, tenant_id}
# Output:  upsert seo_context → return seo_data
# =============================================================================

resource "aws_lambda_function" "seo" {
  function_name = "${local.name_prefix}-seo"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "services.seo_intelligence.handler.lambda_handler"
  runtime       = "python3.12"
  timeout       = 180  # 3 min
  memory_size   = 256

  filename         = "${var.lambda_zip_dir}/seo.zip"
  source_code_hash = filebase64sha256("${var.lambda_zip_dir}/seo.zip")

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [var.sg_app_id]
  }

  environment {
    variables = merge(local.common_env, {
      DATAFORSEO_LOGIN    = var.dataforseo_login
      DATAFORSEO_PASSWORD = var.dataforseo_password
    })
  }

  depends_on = [
    aws_cloudwatch_log_group.seo,
    aws_iam_role_policy_attachment.lambda_vpc,
  ]

  tags = merge(local.common_tags, { Function = "seo" })
}

# =============================================================================
# LAMBDA 3 — Validation
# Trigger: Step Functions Task (direct invoke, after ECS content gen)
# Input:   {tour_id, generated_content_id, tenant_id}
# Output:  quality_scores record → pass/hitl/fail routing
# =============================================================================

resource "aws_lambda_function" "validation" {
  function_name = "${local.name_prefix}-validation"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "services.validation.handler.lambda_handler"
  runtime       = "python3.12"
  timeout       = 180  # 3 min
  memory_size   = 256

  filename         = "${var.lambda_zip_dir}/validation.zip"
  source_code_hash = filebase64sha256("${var.lambda_zip_dir}/validation.zip")

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [var.sg_app_id]
  }

  environment {
    variables = local.common_env
  }

  depends_on = [
    aws_cloudwatch_log_group.validation,
    aws_iam_role_policy_attachment.lambda_vpc,
  ]

  tags = merge(local.common_tags, { Function = "validation" })
}

# =============================================================================
# LAMBDA 4 — Export
# Trigger: Step Functions Task (after validation pass or HITL approve)
# Input:   {tour_id, generated_content_id, tenant_id}
# Output:  published_tours record + S3 Gold file + webhook delivery
# =============================================================================

resource "aws_lambda_function" "export" {
  function_name = "${local.name_prefix}-export"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "services.export.handler.lambda_handler"
  runtime       = "python3.12"
  timeout       = 120  # 2 min
  memory_size   = 256

  filename         = "${var.lambda_zip_dir}/export.zip"
  source_code_hash = filebase64sha256("${var.lambda_zip_dir}/export.zip")

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [var.sg_app_id]
  }

  environment {
    variables = merge(local.common_env, {
      GOLD_BUCKET = var.gold_bucket_name
    })
  }

  depends_on = [
    aws_cloudwatch_log_group.export,
    aws_iam_role_policy_attachment.lambda_vpc,
  ]

  tags = merge(local.common_tags, { Function = "export" })
}
