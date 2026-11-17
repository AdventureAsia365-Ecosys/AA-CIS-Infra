# =============================================================================
# AA-397 — account 3 (acc3), us-west-1
# Minimal root, separate state, scoped ONLY to the satellite-invoker IAM role
# (same structure/scope as the former acc1 root, removed in AA-998). Does NOT
# touch accounts/aa365 or the repo root.
#
# AA-1111 (S283): the accounts/acc1-bedrock pattern. No account ID and no profile name in the backend or the provider:
#   - the state bucket and the profile come through -backend-config at init;
#   - account_id and aws_profile come from an untracked accounts/acc3-bedrock/terraform.tfvars (*.tfvars is ignored).
# allowed_account_ids (var.account_id) refuses a plan or apply whose credentials resolve to any other account (the
# AA-517 wrong-account writes). The state bucket keeps its name (aa-cis-tfstate-acc3-bedrock-<acc3 ID>): only where
# the name comes from changes, so nothing moves. Applied locally by a human (one-line commands, WSL2; P = the acc3
# profile of the root repo account map, A = the 12-digit ID it returns):
#   A=$(aws sts get-caller-identity --profile $P --query Account --output text)
#   printf 'account_id  = "%s"\naws_profile = "%s"\n' "$A" "$P" > accounts/acc3-bedrock/terraform.tfvars
#   terraform -chdir=accounts/acc3-bedrock init -reconfigure -backend-config="bucket=aa-cis-tfstate-acc3-bedrock-$A" -backend-config="profile=$P"
#   terraform -chdir=accounts/acc3-bedrock plan -out=acc3-bedrock.tfplan
# (-reconfigure once, on a checkout initialised before AA-1111: the bucket is the same, so there is no state to migrate.)
# =============================================================================

terraform {
  required_version = ">= 1.7.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69"
    }
  }

  # bucket and profile: -backend-config at init (header), never committed.
  backend "s3" {
    key    = "acc3-bedrock/terraform.tfstate"
    region = "us-west-1"
  }
}

variable "account_id" {
  description = "AA-1111: acc3's 12-digit ID, the only account this root may plan or apply against (provider allowed_account_ids). From the untracked terraform.tfvars; never committed."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be acc3's 12-digit account ID (root repo account map)."
  }
}

variable "aws_profile" {
  description = "AA-1111: the acc3 profile (root repo account map). From the untracked terraform.tfvars; never committed."
  type        = string
}

provider "aws" {
  region              = "us-west-1"
  profile             = var.aws_profile
  allowed_account_ids = [var.account_id]

  # Tagging standard (root docs/architecture/tagging-standard.md, FIN-03; S271). A single-purpose root (the LLM
  # account), so App and Component default here; the budget, anomaly and cost-reader resources say billing. Bedrock
  # model usage itself carries no resource tag: per-app LLM spend comes from the gateway ledger (DM-10.4), not tags.
  # Environment = dev: every role here serves Dev today; a prod invoker role sets Environment = prod on itself.
  default_tags {
    tags = {
      Project            = "aa-ecosys"
      Environment        = "dev"
      App                = "shared"
      Component          = "llm"
      Owner              = "tech-lead"
      ManagedBy          = "terraform"
      CostCenter         = "technology"
      DataClassification = "internal"
      Issue              = "AA-397"
    }
  }
}
