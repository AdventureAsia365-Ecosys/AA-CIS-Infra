# =============================================================================
# AA-246 Track B — AA-CIS root module for account 005097885195 (aa365)
# Mirrors the architecture of the account-1 root module (../../main.tf) but
# wires ARNs through module outputs instead of literal account-1 ARNs.
# Scope (confirmed): VPC, RDS, ECS, ALB, S3, Secrets, API Gateway, Step
# Functions, WAF, Lambda (5 CIS + 3 ACP), EventBridge (AA-402, 2026-08-14).
# AA-180 (ACPv1 orchestration epic) stays separate and deferred/dead — the
# eventbridge module below is ACPv2's own schedules (daily ingest, weekly
# export, Gate C veto window), not an AA-180 revival.
# =============================================================================

locals {
  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  # Breaks the ECS <-> Step Functions mutual module dependency (ECS task def
  # embeds STEP_FUNCTIONS_ARN as an env var; the state machine definition
  # embeds the ECS cluster + task-definition ARNs). Both ARNs are fully
  # deterministic from name + account + region, so build them from vars
  # instead of module outputs — avoids a real dependency cycle without
  # hardcoding an account-specific literal (unlike the account-1 root, which
  # hardcodes the account-1 ARNs directly).
  name_prefix          = "${var.project}-${var.environment}"
  ecs_cluster_arn      = "arn:aws:ecs:${var.aws_region}:${var.account_id}:cluster/${local.name_prefix}-cluster"
  ecs_api_task_def_arn = "arn:aws:ecs:${var.aws_region}:${var.account_id}:task-definition/${local.name_prefix}-api"
  sfn_pipeline_arn     = "arn:aws:states:${var.aws_region}:${var.account_id}:stateMachine:${local.name_prefix}-pipeline"
}

module "vpc" {
  source = "../../modules/vpc"

  project              = var.project
  environment          = var.environment
  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  db_subnet_cidrs      = var.db_subnet_cidrs
}

module "rds" {
  source = "../../modules/rds"

  project              = var.project
  environment          = var.environment
  db_username          = var.db_username
  db_password          = var.db_password
  db_subnet_group_name = module.vpc.db_subnet_group_name
  sg_rds_id            = module.vpc.sg_rds_id

  depends_on = [module.vpc]
}

module "s3" {
  source = "../../modules/s3"

  project           = var.project
  environment       = var.environment
  allowed_role_arns = var.s3_allowed_role_arns
  tags              = local.common_tags
}

module "sqs" {
  source = "../../modules/sqs_sns"

  project     = var.project
  environment = var.environment
}

module "secrets" {
  source = "../../modules/secrets"

  project     = var.project
  environment = var.environment
}

module "elasticache" {
  source = "../../modules/elasticache"

  project            = var.project
  environment        = var.environment
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  sg_app_id          = module.vpc.sg_app_id

  depends_on = [module.vpc]
}

module "efs" {
  source = "../../modules/efs"

  project            = var.project
  environment        = var.environment
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  sg_app_id          = module.vpc.sg_app_id

  depends_on = [module.vpc]
}

module "alb" {
  source = "../../modules/alb"

  project             = var.project
  environment         = var.environment
  vpc_id              = module.vpc.vpc_id
  public_subnet_ids   = module.vpc.public_subnet_ids
  sg_alb_id           = module.vpc.sg_alb_id
  acm_certificate_arn = var.acm_certificate_arn
  private_subnet_ids  = module.vpc.private_subnet_ids
  vpc_cidr_block      = var.vpc_cidr
  access_logs_bucket  = aws_s3_bucket.diag_alb_logs.id # AA-272 diagnostic only

  depends_on = [module.vpc, aws_s3_bucket_policy.diag_alb_logs]
}

module "ecs" {
  source = "../../modules/ecs"

  project     = var.project
  environment = var.environment
  aws_region  = var.aws_region

  private_subnet_ids = module.vpc.private_subnet_ids
  sg_app_id          = module.vpc.sg_app_id

  target_group_arn = module.alb.target_group_arn

  redis_host = module.elasticache.redis_endpoint

  task_cpu              = var.task_cpu
  task_memory           = var.task_memory
  service_desired_count = var.service_desired_count

  # Wired via module outputs (no hardcoded account-1 ARNs) — the two
  # exceptions are ecs_cluster/task_def <-> step_functions, see locals above.
  secret_rds_arn        = module.secrets.rds_secret_arn
  secret_openai_arn     = var.secret_openai_arn
  secret_admin_arn      = var.secret_admin_arn
  secret_anthropic_arn  = var.secret_anthropic_arn
  secret_dataforseo_arn = module.secrets.dataforseo_secret_arn
  bronze_bucket_name    = module.s3.bronze_bucket_name

  step_functions_arn = local.sfn_pipeline_arn
  sf_batch_threshold = 15

  # AmazonECSTaskExecutionRolePolicy alone doesn't grant secretsmanager:GetSecretValue —
  # account 1's execution role has this attached out-of-band; account 2 needs it explicit.
  execution_role_secrets_arn_pattern = "arn:aws:secretsmanager:${var.aws_region}:${var.account_id}:secret:${var.project}/${var.environment}/*"

  depends_on = [module.vpc, module.alb]
}

module "lambda" {
  source = "../../modules/lambda"

  project     = var.project
  environment = var.environment
  aws_region  = var.aws_region
  account_id  = var.account_id

  private_subnet_ids = module.vpc.private_subnet_ids
  sg_app_id          = module.vpc.sg_app_id

  bronze_bucket_arn  = module.s3.bronze_bucket_arn
  bronze_bucket_name = module.s3.bronze_bucket_name
  gold_bucket_arn    = module.s3.gold_bucket_arn
  gold_bucket_name   = module.s3.gold_bucket_name

  secret_rds_arn    = module.secrets.rds_secret_arn
  secret_openai_arn = var.secret_openai_arn

  step_functions_arn      = local.sfn_pipeline_arn
  ecs_cluster_arn         = local.ecs_cluster_arn
  ecs_task_definition_arn = local.ecs_api_task_def_arn
  ecs_container_name      = "api"

  database_url        = var.database_url
  redis_url           = var.redis_url
  dataforseo_login    = var.dataforseo_login
  dataforseo_password = var.dataforseo_password
  anthropic_api_key   = var.anthropic_api_key

  lambda_zip_dir              = "${path.module}/../../dist/lambdas"
  api_base_url                = "https://${var.domain_name}"
  brand_brief_parser_zip      = "${path.module}/../../dist/lambdas/brand_brief_parser.zip"
  acp_s3_campaign_planner_zip = "${path.module}/../../dist/lambdas/acp_s3_campaign_planner.zip"
  acp_s4_evaluate_zip         = "${path.module}/../../dist/lambdas/acp-s4-evaluate.zip"

  tags = local.common_tags
}

module "step_functions" {
  source = "../../modules/step_functions"

  project     = var.project
  environment = var.environment
  aws_region  = var.aws_region
  account_id  = var.account_id

  seo_lambda_arn        = module.lambda.seo_lambda_arn
  validation_lambda_arn = module.lambda.validation_lambda_arn
  export_lambda_arn     = module.lambda.export_lambda_arn
  content_lambda_arn    = module.lambda.content_lambda_arn

  ecs_cluster_arn         = local.ecs_cluster_arn
  ecs_task_definition_arn = local.ecs_api_task_def_arn
  ecs_container_name      = "api"
  private_subnet_ids      = module.vpc.private_subnet_ids
  sg_app_id               = module.vpc.sg_app_id

  tags = local.common_tags
}

module "eventbridge" {
  source = "../../modules/eventbridge"

  project          = var.project
  environment      = var.environment
  aws_region       = var.aws_region
  account_id       = var.account_id
  tags             = local.common_tags
  alerts_topic_arn = aws_sns_topic.alerts.arn
}

module "monitoring" {
  source = "../../modules/monitoring"

  project     = var.project
  environment = var.environment
  aws_region  = var.aws_region
  account_id  = var.account_id
  tags        = local.common_tags
}

module "waf" {
  source = "../../modules/waf"

  project        = var.project
  environment    = var.environment
  alb_arn        = module.alb.alb_arn
  rate_limit     = 1000
  vpc_allow_cidr = var.vpc_cidr
  tags           = local.common_tags

  depends_on = [module.alb]
}

module "api_gateway" {
  source = "../../modules/api_gateway"

  project     = var.project
  environment = var.environment
  aws_region  = var.aws_region
  account_id  = var.account_id
  tags        = local.common_tags

  authorizer_lambda_invoke_arn = module.lambda.authorizer_lambda_invoke_arn
  authorizer_lambda_name       = module.lambda.authorizer_lambda_name
  alb_dns_name                 = module.alb.alb_dns_name
  nlb_dns_name                 = module.alb.nlb_dns_name
  vpc_link_id                  = module.alb.vpc_link_id
  acm_cert_arn_us_east1        = var.acm_certificate_arn
  domain_name                  = var.domain_name
  enable_execution_logging     = true # AA-272 diagnostic only

  depends_on = [module.lambda, module.alb, aws_api_gateway_account.this]
}
