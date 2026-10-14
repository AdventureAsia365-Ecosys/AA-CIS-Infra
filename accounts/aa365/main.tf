# =============================================================================
# AA-246 Track B — AA-CIS root module for account 005097885195 (aa365)
# Mirrors the architecture of the account-1 root module (../../main.tf) but
# wires ARNs through module outputs instead of literal account-1 ARNs.
# Scope (confirmed): VPC, RDS, ECS, ALB, S3, Secrets, API Gateway, WAF,
# EventBridge (AA-402, 2026-08-14). The CIS Lambdas, the Step Functions pipeline
# and its SQS queues were retired in AA-750 (#88); the STEP_FUNCTIONS_ARN env var
# still passed to the ECS task def below is kept on purpose (unused computed
# string; dropping it would change the task definitions, see AA-750 notes).
# AA-180 (ACPv1 orchestration epic) stays separate and deferred/dead — the
# eventbridge module below is ACPv2's own schedules (daily ingest, weekly
# export, Gate C veto window), not an AA-180 revival.
# AA-477 (2026-08-27): removed the other 2 ACP Lambdas (acp-s3-campaign-planner,
# acp-s4-evaluate) — 0 EventBridge rule, 0 resource policy, 0 invocation ever
# recorded, dead ACPv1 stage-chain source (services/acp_s3/, services/
# acp_s4_evaluate/ in AA-CIS-App). brand_brief_parser, the last "1 ACP" Lambda,
# was retired with the rest in AA-750.
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
  secret_jwt_arn        = var.secret_jwt_arn
  secret_dataforseo_arn = module.secrets.dataforseo_secret_arn
  bronze_bucket_name    = module.s3.bronze_bucket_name

  step_functions_arn = local.sfn_pipeline_arn
  sf_batch_threshold = 15

  # AmazonECSTaskExecutionRolePolicy alone doesn't grant secretsmanager:GetSecretValue —
  # account 1's execution role has this attached out-of-band; account 2 needs it explicit.
  execution_role_secrets_arn_pattern = "arn:aws:secretsmanager:${var.aws_region}:${var.account_id}:secret:${var.project}/${var.environment}/*"

  depends_on = [module.vpc, module.alb]
}

module "eventbridge" {
  source = "../../modules/eventbridge"

  project          = var.project
  environment      = var.environment
  aws_region       = var.aws_region
  account_id       = var.account_id
  tags             = local.common_tags
  alerts_topic_arn = aws_sns_topic.alerts.arn

  # AA-402: same IAM propagation race as AA-287 — this module's event bus,
  # scheduler role, and schedule group need aa-cis-dev-role's newly-added
  # events:*/scheduler:*/iam:TagRole statements to actually be authorized
  # before they're created. A module-level depends_on was tried first but
  # cascaded to every resource/data-source inside the module (including the
  # DLQ policy, unrelated to these statements), producing a false diff on
  # an already-applied resource — this narrower, variable-gated dependency
  # only touches the 3 resources that actually need it (see
  # modules/eventbridge/variables.tf's iam_propagation_gate).
  iam_propagation_gate = time_sleep.wait_for_iam_propagation.id
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

  # S235 Phase 0: CommonRuleSet starts in observe mode (whole group COUNT). Flip
  # var.waf_common_rules_count_only to false after reviewing 1-2 days of counted matches.
  common_rules_count_only = var.waf_common_rules_count_only

  # S235 Phase 0: same web ACL on the CIS and Booking REST API stages (real client IP -> rate + geo
  # actually apply). Gated OFF by default: associating a web ACL with an API Gateway stage needs
  # apigateway:SetWebACL, which the CI role (cicd.tf APIGatewayManage) does not have yet. Turn on
  # after that grant is applied (separate cicd.tf PR), see var.waf_protect_rest_api_stages.
  rest_api_stage_arns = var.waf_protect_rest_api_stages ? {
    cis     = module.api_gateway.stage_arn
    booking = aws_api_gateway_stage.booking.arn
  } : {}

  depends_on = [module.alb]
}

module "api_gateway" {
  source = "../../modules/api_gateway"

  project     = var.project
  environment = var.environment
  aws_region  = var.aws_region
  account_id  = var.account_id
  tags        = local.common_tags

  alb_dns_name             = module.alb.alb_dns_name
  nlb_dns_name             = module.alb.nlb_dns_name
  vpc_link_id              = module.alb.vpc_link_id
  acm_cert_arn_us_east1    = var.acm_certificate_arn
  domain_name              = var.domain_name
  enable_execution_logging = true # AA-272 diagnostic only

  depends_on = [module.alb, aws_api_gateway_account.this]
}
