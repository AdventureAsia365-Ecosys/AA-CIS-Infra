# =============================================================================
# AA-246 Track B — account 005097885195 (aa365-admin), us-west-1
# Separate root config + separate state, does NOT touch account 867490540162.
# =============================================================================

terraform {
  required_version = ">= 1.7.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }

  backend "s3" {
    bucket  = "aa-cis-tfstate-005097885195"
    key     = "dev/terraform.tfstate"
    region  = "us-west-1"
    profile = "aa365-admin"
  }
}

provider "aws" {
  region  = var.aws_region
  profile = "aa365-admin"

  default_tags {
    tags = {
      Project     = "AA-CIS"
      Environment = var.environment
      ManagedBy   = "Terraform"
      Account     = "aa365"
    }
  }
}
