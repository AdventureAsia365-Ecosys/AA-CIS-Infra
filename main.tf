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
