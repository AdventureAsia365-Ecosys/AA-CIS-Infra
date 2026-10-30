# =============================================================================
# AA-1004 — management account root of the lean AWS model (root ADR 0018, Proposed).
#
# The company's own AWS Organization: organization + OUs, 3 SCPs, IAM Identity Center groups and permission
# sets, budgets + Cost Anomaly Detection per account, and the organization CloudTrail. Nothing in this root runs
# a workload (SCPs do not apply to the management account, so workloads never live here).
#
# Separate root, separate state, separate account: it does NOT touch accounts/aa365 or accounts/acc3-bedrock.
# Applied by a human (tech lead, IAM Identity Center session with MFA) until the CI wiring listed in README.md
# §"CI wiring" exists. Day-1 order, manual console steps and SCP tests: README.md.
#
# No AWS account ID is written in this root (the repo is public): every ID is a variable, set in a local
# terraform.tfvars (git-ignored, see terraform.tfvars.example) or, later, a GitHub environment variable.
# =============================================================================

terraform {
  # Same exact pin as accounts/aa365 and the CI workflows (AA-846), so this root can join the CI plan/apply
  # matrix later without a version bump.
  required_version = "1.15.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69"
    }
  }

  # Partial backend: the bucket name carries the management account ID, which this public repo does not hold.
  # Init (README §3): terraform init -backend-config="bucket=<state-bucket>" -backend-config="profile=aa-mgmt"
  # The provider's profile does not apply to backend init (CONTEXT.md "State backend"), so pass it here too
  # when running locally; CI passes no profile (OIDC credentials in the environment).
  backend "s3" {
    key          = "management/terraform.tfstate"
    region       = "us-west-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile

  # A plan or apply with credentials of any other account fails before it reads anything (AA-517: two real
  # wrong-account writes came from a default profile pointing at the wrong account).
  allowed_account_ids = [var.management_account_id]

  default_tags {
    tags = {
      Project     = "AA-CIS"
      Environment = "shared"
      App         = "shared"
      ManagedBy   = "Terraform"
      Account     = "aa-management"
      Issue       = "AA-1004"
    }
  }
}
