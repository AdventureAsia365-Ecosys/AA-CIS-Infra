# =============================================================================
# AA-246 Track B — account acc2 (aa365-admin), us-west-1
# Separate root config + separate state, does NOT touch account acc1.
# =============================================================================

terraform {
  # AA-846: exact pin, the same version as both CI workflows (terraform-plan.yml and
  # terraform-apply.yml, setup-terraform `terraform_version`). Bump all three in one PR.
  required_version = "1.15.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69"
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
    bucket = "aa-cis-tfstate-005097885195"
    key    = "dev/terraform.tfstate"
    region = "us-west-1"
    # S3 native state locking (<key>.tflock) only. S244 turned it on next to the DynamoDB lock;
    # AA-846 (S245) dropped `dynamodb_table` after CI plan and apply had run green with the
    # lockfile. The old lock table and its IAM grants are removed in separate steps.
    use_lockfile = true
    # Không hardcode profile — CI (GitHub Actions OIDC) dùng ambient credentials
    # qua env var, không có ~/.aws/config. Local: export AWS_PROFILE=aa365-admin
    # trước khi chạy terraform.
  }
}

# Tagging standard (root docs/architecture/tagging-standard.md, FIN-03; S271): the mandatory keys every resource of
# this root shares. App and Component are set per resource or module (main.tf, local.common_tags), never here. The values
# are checked on every plan by tools/terraform/tag_guard.py against tools/terraform/tag_policy.json. Changing one
# re-tags every resource of the root: a tag-only plan, applied locally with the MFA admin profile (bootstrap IAM
# objects included), not by the CI apply role.
locals {
  tag_defaults = {
    Project            = "aa-ecosys"
    Environment        = var.environment
    Owner              = "tech-lead"
    ManagedBy          = "terraform"
    CostCenter         = "technology"
    DataClassification = "internal"
  }
}

# AA-1111 (S283): allowed_account_ids on every provider of this root refuses a plan or apply whose credentials resolve
# to any other account (the AA-517 wrong-account writes: a `default` profile that pointed at acc1). The value is
# var.account_id, the same variable every ARN of this root is built from, so the guard adds no account ID to this
# public repo and needs no new CI input (the plan, apply and drift workflows already read it from terraform.tfvars).
# ADR 0018 decision 5; tools/terraform/tests/test_aa1111_account_guards.py holds every provider block of accounts/ to it.
provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = local.tag_defaults
  }
}

# AA-818: us-east-1 is needed only for the ACM certificate of the Cognito custom domains
# (auth. / staff-auth.), which Cognito serves through CloudFront (custom_domains.tf). Same account,
# same credentials, same default tags; every other resource stays on the default us-west-1 provider.
provider "aws" {
  alias               = "us_east_1"
  region              = "us-east-1"
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = local.tag_defaults
  }
}

# S274 (AA-873): CloudTrail records a root console sign-in in us-east-1, us-east-2 OR us-west-2 (AWS docs; acc2 in the
# last 90 days: 55 / 3 / 3). Only the EventBridge forward rules of security_baseline.tf use these two providers.
provider "aws" {
  alias               = "us_east_2"
  region              = "us-east-2"
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = local.tag_defaults
  }
}

provider "aws" {
  alias               = "us_west_2"
  region              = "us-west-2"
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = local.tag_defaults
  }
}
