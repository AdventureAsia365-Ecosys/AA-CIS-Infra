terraform {
  required_version = ">= 1.7.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }

  backend "s3" {
    bucket  = "aa-cis-tfstate-867490540162"
    key     = "dev/terraform.tfstate"
    region  = "us-west-1"
    # profile không dùng trong CI/CD - dùng OIDC credentials
  }
}

provider "aws" {
  region = var.aws_region
  # profile không set - dùng environment credentials (OIDC trong CI, SSO local)

  default_tags {
    tags = {
      Project     = "AA-CIS"
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}
