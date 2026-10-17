# =============================================================================
# AA-246 Track B — account 005097885195 (aa365-admin), us-west-1
# Separate root config + separate state, does NOT touch account 867490540162.
# =============================================================================

terraform {
  required_version = ">= 1.7.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.68"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  backend "s3" {
    bucket         = "aa-cis-tfstate-005097885195"
    key            = "dev/terraform.tfstate"
    region         = "us-west-1"
    dynamodb_table = "aa-cis-tfstate-lock-005097885195"
    # Không hardcode profile — CI (GitHub Actions OIDC) dùng ambient credentials
    # qua env var, không có ~/.aws/config. Local: export AWS_PROFILE=aa365-admin
    # trước khi chạy terraform.
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "AA-CIS"
      Environment = var.environment
      ManagedBy   = "Terraform"
      Account     = "aa365"
    }
  }
}

# AA-818: us-east-1 is needed only for the ACM certificate of the Cognito custom domains
# (auth. / staff-auth.), which Cognito serves through CloudFront (custom_domains.tf). Same account,
# same credentials, same default tags; every other resource stays on the default us-west-1 provider.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project     = "AA-CIS"
      Environment = var.environment
      ManagedBy   = "Terraform"
      Account     = "aa365"
    }
  }
}
