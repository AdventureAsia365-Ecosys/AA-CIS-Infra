terraform {
  required_version = ">= 1.7.0"

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
    profile = "pqnghiep-admin"
  }
}

provider "aws" {
  region  = var.aws_region
  profile = "pqnghiep-admin"

  default_tags {
    tags = {
      Project     = "AA-CIS"
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}
