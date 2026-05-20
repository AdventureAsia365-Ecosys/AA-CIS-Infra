
# ============================================================
# AA-CIS Root Module — updated with ALB + ECS Service
# ============================================================

locals {
  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

module "vpc" {
  source      = "./modules/vpc"
  project     = var.project
  environment = var.environment
}

module "rds" {
  source      = "./modules/rds"
  project     = var.project
  environment = var.environment
  db_username          = var.db_username
  db_password          = var.db_password
  db_subnet_group_name = module.vpc.db_subnet_group_name
  sg_rds_id            = module.vpc.sg_rds_id
  depends_on = [module.vpc]
}

module "s3" {
  source            = "./modules/s3"
  project           = var.project
  environment       = var.environment
  allowed_role_arns = var.s3_allowed_role_arns
  tags              = local.common_tags
}

module "sqs" {
  source      = "./modules/sqs_sns"
  project     = var.project
  environment = var.environment
}

module "secrets" {
  source      = "./modules/secrets"
  project     = var.project
  environment = var.environment
}

module "elasticache" {
  source             = "./modules/elasticache"
  project            = var.project
  environment        = var.environment
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  sg_app_id          = module.vpc.sg_app_id
  depends_on = [module.vpc]
}

module "efs" {
  source             = "./modules/efs"
  project            = var.project
  environment        = var.environment
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  sg_app_id          = module.vpc.sg_app_id
  depends_on = [module.vpc]
}

# ── NEW: ALB ──────────────────────────────────────────────────
module "alb" {
  source              = "./modules/alb"
  project             = var.project
  environment         = var.environment
  vpc_id              = module.vpc.vpc_id
  public_subnet_ids   = module.vpc.public_subnet_ids
  sg_alb_id           = module.vpc.sg_alb_id
  acm_certificate_arn = var.acm_certificate_arn
  depends_on          = [module.vpc]
}

# ── NEW: ECS Service ─────────────────────────────────────────
module "ecs" {
  source      = "./modules/ecs"
  project     = var.project
  environment = var.environment
  aws_region  = var.aws_region

  # Networking
  private_subnet_ids = module.vpc.private_subnet_ids
  sg_app_id          = module.vpc.sg_app_id

  # ALB integration
  target_group_arn = module.alb.target_group_arn

  # Task sizing
  task_cpu              = var.task_cpu
  task_memory           = var.task_memory
  service_desired_count = var.service_desired_count

  # Secrets
  secret_rds_arn      = var.secret_rds_arn
  secret_openai_arn   = var.secret_openai_arn
  # secret_langfuse_arn            = var.secret_langfuse_arn            # AA-23: removed
  secret_admin_arn               = var.secret_admin_arn
  # secret_langfuse_public_key_arn = var.secret_langfuse_public_key_arn  # AA-23: removed
  # secret_langfuse_host_arn       = var.secret_langfuse_host_arn        # AA-23: removed
  secret_anthropic_arn           = var.secret_anthropic_arn
  secret_dataforseo_arn          = "arn:aws:secretsmanager:us-west-1:867490540162:secret:aa-cis/dev/dataforseo-lECabM"

  step_functions_arn = local.step_functions_arn
  sf_batch_threshold = 15

  depends_on = [module.vpc, module.alb]
}

# =============================================================================
# S11 Phase 4 — Lambda + Step Functions
# =============================================================================




module "step_functions" {
  source = "./modules/step_functions"

  project     = var.project
  environment = var.environment
  aws_region  = var.aws_region
  account_id  = var.account_id

  seo_lambda_arn        = module.lambda.seo_lambda_arn
  validation_lambda_arn = module.lambda.validation_lambda_arn
  export_lambda_arn     = module.lambda.export_lambda_arn
  content_lambda_arn    = module.lambda.content_lambda_arn

  ecs_cluster_arn         = module.ecs.cluster_arn
  ecs_task_definition_arn = local.api_task_def_arn
  ecs_container_name      = "api"
  private_subnet_ids      = module.vpc.private_subnet_ids
  sg_app_id               = module.vpc.sg_app_id

  tags = local.common_tags
}

module "lambda" {
  source = "./modules/lambda"

  project     = var.project
  environment = var.environment
  aws_region  = var.aws_region
  account_id  = var.account_id

  private_subnet_ids = module.vpc.private_subnet_ids
  sg_app_id          = module.vpc.sg_app_id

  bronze_bucket_arn  = local.bronze_bucket_arn
  bronze_bucket_name = local.bronze_bucket_name
  gold_bucket_arn    = local.gold_bucket_arn
  gold_bucket_name   = local.gold_bucket_name

  secret_rds_arn      = var.secret_rds_arn
  secret_openai_arn   = var.secret_openai_arn
  # secret_langfuse_arn = var.secret_langfuse_arn  # AA-23: removed

  step_functions_arn      = module.step_functions.state_machine_arn
  ecs_cluster_arn         = module.ecs.cluster_arn
  ecs_task_definition_arn = local.api_task_def_arn
  ecs_container_name      = "api"

  database_url        = var.database_url
  redis_url           = var.redis_url
  dataforseo_login    = var.dataforseo_login
  dataforseo_password = var.dataforseo_password
  anthropic_api_key   = var.anthropic_api_key

  lambda_zip_dir         = "${path.module}/dist/lambdas"
  api_base_url           = "https://api-cis.lumiguides.it.com"
  brand_brief_parser_zip = "${path.module}/dist/lambdas/brand_brief_parser.zip"

  tags = local.common_tags
}

# Phase 4 hardcoded locals (replace data sources để tránh hang khi plan)
locals {
  bronze_bucket_arn  = "arn:aws:s3:::aa-cis-bronze-867490540162"
  bronze_bucket_name = "aa-cis-bronze-867490540162"
  gold_bucket_arn    = "arn:aws:s3:::aa-cis-gold-867490540162"
  gold_bucket_name   = "aa-cis-gold-867490540162"
  api_task_def_arn   = "arn:aws:ecs:us-west-1:867490540162:task-definition/aa-cis-dev-api"
  step_functions_arn = "arn:aws:states:us-west-1:867490540162:stateMachine:aa-cis-dev-pipeline"
}

module "monitoring" {
  source      = "./modules/monitoring"
  project     = var.project
  environment = var.environment
  aws_region  = var.aws_region
  account_id  = var.account_id
  tags        = local.common_tags
}

# =============================================================================
# AA-59 — WAF (imported from manually-created aa-cis-dev-waf)
# =============================================================================

module "waf" {
  source      = "./modules/waf"
  project     = var.project
  environment = var.environment
  alb_arn     = "arn:aws:elasticloadbalancing:us-west-1:867490540162:loadbalancer/app/aa-cis-dev-alb/a45250d62d507ec2"
  rate_limit  = 1000
  tags        = local.common_tags
}

# =============================================================================
# AA-40 — ACP Pipeline Core Infrastructure
# EventBridge bus + Scheduler rules for Adventure Asia Content Pipeline
# =============================================================================

module "eventbridge" {
  source      = "./modules/eventbridge"
  project     = var.project
  environment = var.environment
  aws_region  = var.aws_region
  account_id  = var.account_id
  tags        = local.common_tags
}

# =============================================================================
# AA-13 — API Gateway REST + usage plans + tenant key authorizer
# =============================================================================

module "api_gateway" {
  source      = "./modules/api_gateway"
  project     = var.project
  environment = var.environment
  aws_region  = var.aws_region
  account_id  = var.account_id
  tags        = local.common_tags

  authorizer_lambda_invoke_arn = module.lambda.authorizer_lambda_invoke_arn
  authorizer_lambda_name       = module.lambda.authorizer_lambda_name
  alb_dns_name                 = "aa-cis-dev-alb-1114303360.us-west-1.elb.amazonaws.com"
  acm_cert_arn_us_east1        = "arn:aws:acm:us-west-1:867490540162:certificate/260ab2f0-06f6-456b-b5d7-a4d0af96d405"

  depends_on = [module.lambda]
}

# =============================================================================
# AA-13 — GitHub Actions role: API Gateway permissions
# aa-cis-dev-role exists in AWS (created manually, not TF-managed).
# Adding a separate inline policy so Terraform can own just this statement.
# =============================================================================

resource "aws_iam_role_policy" "github_actions_apigateway" {
  name = "APIGatewayPolicy"
  role = "aa-cis-dev-role"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "apigateway:GET",
          "apigateway:POST",
          "apigateway:PUT",
          "apigateway:DELETE",
          "apigateway:PATCH",
          "apigateway:HEAD",
          "apigateway:OPTIONS",
        ]
        Resource = [
          "arn:aws:apigateway:${var.aws_region}::/restapis",
          "arn:aws:apigateway:${var.aws_region}::/restapis/*",
          "arn:aws:apigateway:${var.aws_region}::/domainnames",
          "arn:aws:apigateway:${var.aws_region}::/domainnames/*",
          "arn:aws:apigateway:${var.aws_region}::/usageplans",
          "arn:aws:apigateway:${var.aws_region}::/usageplans/*",
        ]
      }
    ]
  })
}

# =============================================================================
# AA-59 — GitHub Actions role: WAF read permissions
# Required for Terraform plan to refresh wafv2_web_acl state.
# Pattern: same as github_actions_apigateway above.
# =============================================================================

resource "aws_iam_role_policy" "github_actions_waf" {
  name = "WAFReadPolicy"
  role = "aa-cis-dev-role"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "WAFReadAccess"
        Effect = "Allow"
        Action = [
          "wafv2:GetWebACL",
          "wafv2:ListWebACLs",
          "wafv2:GetWebACLForResource",
          "wafv2:ListTagsForResource",
          "wafv2:GetLoggingConfiguration",
        ]
        Resource = [
          "arn:aws:wafv2:us-west-1:867490540162:regional/webacl/*",
        ]
      }
    ]
  })
}
