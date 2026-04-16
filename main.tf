# ============================================================
# AA-CIS Root Module
# ============================================================

module "vpc" {
  source      = "./modules/vpc"
  project     = var.project
  environment = var.environment
}
