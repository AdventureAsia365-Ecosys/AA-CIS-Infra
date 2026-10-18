# =============================================================================
# AA-302 — account 1 (867490540162), us-west-1
# Minimal root, separate state, scoped ONLY to Bedrock Batch inference IAM
# (role + policies). Does NOT touch the old (broken, abandoned) root main.tf
# at repo root, and does NOT touch account 2 (accounts/aa365).
# =============================================================================

terraform {
  required_version = ">= 1.7.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69"
    }
  }

  backend "s3" {
    bucket  = "aa-cis-tfstate-acc1-bedrock-867490540162"
    key     = "acc1-bedrock/terraform.tfstate"
    region  = "us-west-1"
    profile = "pqnghiep-admin"
  }
}

provider "aws" {
  region  = "us-west-1"
  profile = "pqnghiep-admin"

  default_tags {
    tags = {
      Project     = "AA-CIS"
      Environment = "dev"
      ManagedBy   = "Terraform"
      Account     = "acc1-bedrock"
      Issue       = "AA-302"
    }
  }
}
