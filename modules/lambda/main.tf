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
          # var.secret_langfuse_arn  # AA-23: removed
        ]
      },
      # Step Functions — Ingestion triggers SF execution + HITL callback
      {
        Sid    = "StepFunctionsStart"
        Effect = "Allow"
        Action = [
          "states:StartExecution",
          "states:SendTaskSuccess",
          "states:SendTaskFailure",
        ]
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

# =============================================================================
# LAMBDA 5 — Content Generation
# Trigger: Step Functions Task (per-tour)
# Input:   {tour_id, batch_id, tenant_id, retry_count, validation_feedback}
# Output:  {tour_id, batch_id, version_id, status, quality_score}
# =============================================================================
resource "aws_cloudwatch_log_group" "content" {
  name              = "/aws/lambda/${local.name_prefix}-content"
  retention_in_days = 14
  tags              = local.common_tags
}

resource "aws_lambda_function" "content" {
  function_name = "${local.name_prefix}-content"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "services.content_generation.handler.lambda_handler"
  runtime       = "python3.12"
  timeout       = 840
  memory_size   = 256
  filename         = "${var.lambda_zip_dir}/content.zip"
  source_code_hash = filebase64sha256("${var.lambda_zip_dir}/content.zip")
  environment {
    variables = merge(local.common_env, {
      API_BASE_URL = var.api_base_url
    })
  }
  depends_on = [
    aws_cloudwatch_log_group.content,
    aws_iam_role_policy_attachment.lambda_vpc,
  ]
  tags = merge(local.common_tags, { Function = "content" })
}

# =============================================================================
# LAMBDA 6 — API Gateway Tenant Key Authorizer
# Trigger: API Gateway TOKEN authorizer
# Input:   X-API-Key header → sha256 hash → shared.tenants lookup
# Output:  Allow/Deny policy + tenant context
# =============================================================================

resource "aws_cloudwatch_log_group" "authorizer" {
  name              = "/aws/lambda/${local.name_prefix}-authorizer"
  retention_in_days = 14
  tags              = local.common_tags
}

resource "aws_lambda_function" "authorizer" {
  function_name = "${local.name_prefix}-authorizer"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "handler.lambda_handler"
  runtime       = "python3.12"
  timeout       = 10
  memory_size   = 128

  filename         = "${var.lambda_zip_dir}/authorizer.zip"
  source_code_hash = filebase64sha256("${var.lambda_zip_dir}/authorizer.zip")

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [var.sg_app_id]
  }

  environment {
    variables = {
      DATABASE_URL = var.database_url
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.authorizer,
    aws_iam_role_policy_attachment.lambda_vpc,
  ]

  tags = merge(local.common_tags, { Function = "authorizer" })
}

# =============================================================================
# AA-78 — Brand Brief Parser Lambda
# Parses .docx brand brief → UPSERT shared.tenant_brand_rules
# Triggered by: ECS API (boto3 invoke, RequestResponse)
# =============================================================================
resource "aws_lambda_function" "brand_brief_parser" {
  function_name = "${local.name_prefix}-brand-brief-parser"
  description   = "AA-78: Parse DOCX brand brief → tenant_brand_rules"

  filename         = var.brand_brief_parser_zip
  source_code_hash = filebase64sha256(var.brand_brief_parser_zip)
  handler          = "handler.handler"
  runtime          = "python3.12"
  memory_size      = 512
  timeout          = 30

  role = aws_iam_role.lambda_exec.arn

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [var.sg_app_id]
  }

  environment {
    variables = merge(local.common_env, {
      S3_BRONZE_BUCKET = var.bronze_bucket_name
    })
  }

  tags = merge(local.common_tags, {
    Function = "brand-brief-parser"
    Issue    = "AA-78"
  })
}

# IAM — InvokeFunction permission for ECS task role
# ECS API container calls brand-brief-parser via boto3
resource "aws_iam_role_policy" "ecs_invoke_brand_brief_parser" {
  name = "${local.name_prefix}-ecs-invoke-brand-brief-parser"
  role = "${local.name_prefix}-ecs-task-role"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "InvokeBrandBriefParser"
      Effect = "Allow"
      Action = ["lambda:InvokeFunction"]
      Resource = [aws_lambda_function.brand_brief_parser.arn]
    }]
  })
}

resource "aws_cloudwatch_log_group" "brand_brief_parser" {
  name              = "/aws/lambda/${aws_lambda_function.brand_brief_parser.function_name}"
  retention_in_days = 14
  tags              = local.common_tags
}

# =============================================================================
# AA-45 — ACP S3 Campaign Planner Lambda
# Trigger: ECS API (boto3 invoke, RequestResponse)
# Input:   {run_id, tenant_id}
# Output:  content_calendars + ads_plan + Gate 2 HITL request
# =============================================================================

resource "aws_cloudwatch_log_group" "acp_s3_campaign_planner" {
  name              = "/aws/lambda/${local.name_prefix}-acp-s3-campaign-planner"
  retention_in_days = 14
  tags              = local.common_tags
}

resource "aws_lambda_function" "acp_s3_campaign_planner" {
  function_name = "${local.name_prefix}-acp-s3-campaign-planner"
  description   = "AA-45: S3 Campaign Planner — content_calendars + ads_plan + Gate 2 HITL"

  filename         = var.acp_s3_campaign_planner_zip
  source_code_hash = filebase64sha256(var.acp_s3_campaign_planner_zip)
  handler          = "handler.handler"
  runtime          = "python3.12"
  memory_size      = 1024
  timeout          = 600  # 10 min — Sonnet skeleton + expand + Haiku ads

  role = aws_iam_role.lambda_exec.arn

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [var.sg_app_id]
  }

  environment {
    variables = merge(local.common_env, {
      S3_BRONZE_BUCKET = var.bronze_bucket_name
    })
  }

  depends_on = [
    aws_cloudwatch_log_group.acp_s3_campaign_planner,
    aws_iam_role_policy_attachment.lambda_vpc,
  ]

  tags = merge(local.common_tags, {
    Function = "acp-s3-campaign-planner"
    Issue    = "AA-45"
  })
}

# Bedrock InvokeModel permission for campaign planner (Sonnet + Haiku)
resource "aws_iam_role_policy" "lambda_bedrock_acp_s3" {
  name = "${local.name_prefix}-lambda-bedrock-acp-s3"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "BedrockInvokeAcpS3"
      Effect = "Allow"
      Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
      Resource = [
        "arn:aws:bedrock:us-west-1::foundation-model/anthropic.claude-haiku-4-5*",
        "arn:aws:bedrock:us-west-1::foundation-model/anthropic.claude-sonnet-4-5*",
        "arn:aws:bedrock:us-west-1:${var.account_id}:inference-profile/us.anthropic.claude-haiku-4-5*",
        "arn:aws:bedrock:us-west-1:${var.account_id}:inference-profile/us.anthropic.claude-sonnet-4-5*",
      ]
    }]
  })
}

# IAM — ECS task role can invoke campaign planner
resource "aws_iam_role_policy" "ecs_invoke_acp_s3_campaign_planner" {
  name = "${local.name_prefix}-ecs-invoke-acp-s3-campaign-planner"
  role = "${local.name_prefix}-ecs-task-role"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "InvokeAcpS3CampaignPlanner"
      Effect = "Allow"
      Action = ["lambda:InvokeFunction"]
      Resource = [aws_lambda_function.acp_s3_campaign_planner.arn]
    }]
  })
}

# =============================================================================
# AA-49 H-1 — ACP S4 Isolated Evaluator Lambda
# Trigger: ECS API (boto3 invoke, RequestResponse)
# Input:   {text: str}  — ONLY blog content, no brand context, no DB
# Output:  {evaluator_score, dimension_scores, issues, evaluator_input_hash}
# No VPC: Lambda only calls Bedrock (public endpoint) — avoids cold start penalty
# =============================================================================

resource "aws_cloudwatch_log_group" "acp_s4_evaluate" {
  name              = "/aws/lambda/${local.name_prefix}-acp-s4-evaluate"
  retention_in_days = 14
  tags              = local.common_tags
}

resource "aws_lambda_function" "acp_s4_evaluate" {
  function_name = "${local.name_prefix}-acp-s4-evaluate"
  description   = "AA-49 H-1: Isolated S4 blog draft evaluator — Bedrock only, no DB access"

  filename         = var.acp_s4_evaluate_zip
  source_code_hash = filebase64sha256(var.acp_s4_evaluate_zip)
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  memory_size      = 1024
  timeout          = 60

  role = aws_iam_role.lambda_exec.arn

  # No VPC config — this Lambda only calls Bedrock (public endpoint)
  # Adding VPC would add ~500ms cold start with no benefit
  # Note: AWS_REGION is provided automatically by the Lambda runtime

  depends_on = [aws_cloudwatch_log_group.acp_s4_evaluate]

  tags = merge(local.common_tags, {
    Function = "acp-s4-evaluate"
    Issue    = "AA-49"
  })
}

# Bedrock InvokeModel permission for S4 evaluator (Haiku only)
resource "aws_iam_role_policy" "lambda_bedrock_acp_s4_evaluate" {
  name = "${local.name_prefix}-lambda-bedrock-acp-s4-evaluate"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "BedrockInvokeAcpS4Evaluate"
      Effect = "Allow"
      Action = ["bedrock:InvokeModel"]
      # Cross-region inference profile (us.*) routes via us-east-1 for IAM auth
      Resource = [
        "arn:aws:bedrock:*::foundation-model/anthropic.claude-haiku-4-5*",
        "arn:aws:bedrock:*:${var.account_id}:inference-profile/us.anthropic.claude-haiku-4-5*",
      ]
    }]
  })
}

# IAM — ECS task role can invoke S4 evaluator
resource "aws_iam_role_policy" "ecs_invoke_acp_s4_evaluate" {
  name = "${local.name_prefix}-ecs-invoke-acp-s4-evaluate"
  role = "${local.name_prefix}-ecs-task-role"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "InvokeAcpS4Evaluate"
      Effect = "Allow"
      Action = ["lambda:InvokeFunction"]
      Resource = [aws_lambda_function.acp_s4_evaluate.arn]
    }]
  })
}
