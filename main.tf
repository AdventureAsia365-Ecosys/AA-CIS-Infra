# ============================================================
# AA-CIS Root Module
# ============================================================

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

module "ecs" {
  source      = "./modules/ecs"
  project     = var.project
  environment = var.environment
}

module "s3" {
  source      = "./modules/s3"
  project     = var.project
  environment = var.environment
  account_id  = var.account_id
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
