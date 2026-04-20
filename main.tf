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
  secret_langfuse_arn = var.secret_langfuse_arn

  depends_on = [module.vpc, module.alb]
}
