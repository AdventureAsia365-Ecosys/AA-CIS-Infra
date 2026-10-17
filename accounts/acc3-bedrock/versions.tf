# =============================================================================
# AA-397 — account 3 (786888028788), us-west-1
# Minimal root, separate state, scoped ONLY to the satellite-invoker IAM role
# (mirrors accounts/acc1-bedrock/ structure/scope). Does NOT touch acc1-bedrock,
# accounts/aa365, or repo root.
# =============================================================================

terraform {
  required_version = ">= 1.7.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.68"
    }
  }

  backend "s3" {
    bucket  = "aa-cis-tfstate-acc3-bedrock-786888028788"
    key     = "acc3-bedrock/terraform.tfstate"
    region  = "us-west-1"
    profile = "nghiep_aa365"
  }
}

provider "aws" {
  region  = "us-west-1"
  profile = "nghiep_aa365"

  default_tags {
    tags = {
      Project     = "AA-CIS"
      Environment = "dev"
      ManagedBy   = "Terraform"
      Account     = "acc3-bedrock"
      Issue       = "AA-397"
    }
  }
}
