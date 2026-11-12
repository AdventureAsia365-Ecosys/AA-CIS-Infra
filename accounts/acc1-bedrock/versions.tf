# =============================================================================
# AA-1095 (S278) — account 1 (acc1, a personal account), us-west-1
# Minimal root, separate state, scoped ONLY to the Bedrock invoker IAM role (main.tf). Nothing else of the ecosystem
# runs on acc1: no data, no secret, no compute, no Batch, no Cost Explorer reader (root ADR 0001a, Note S278).
# Does NOT touch accounts/aa365, accounts/acc3-bedrock or accounts/management.
#
# Why acc1 again. AWS refuses 7 of the gateway's chat models on acc3 at account level (open AWS cases); acc1
# answered a real Converse call on every chat model the gateway uses (12/11/2026, tech lead's SSO profile). Tech lead
# decision S278: serve Bedrock from acc1 while acc3 is blocked; acc3 stays configured behind it.
#
# No account ID and no profile name in this public repo (CONTEXT.md: roots take IDs as variables or secrets, like
# MGMT_ACCOUNT_ID; root docs/security/baseline.md keeps acc1's ID in the public-repo pattern). Both come from the
# root repo's account map (onboarding) at apply time:
#   - the state bucket and the profile through -backend-config at init;
#   - account_id and aws_profile through an untracked accounts/acc1-bedrock/terraform.tfvars (*.tfvars is ignored).
#
# State. One root and one state bucket per account, nothing crossing accounts on the state path (root ADR 0018
# decision 5), the acc3-bedrock pattern: bucket aa-cis-tfstate-acc1-bedrock-<acc1 ID> on acc1 (versioned, public
# access blocked, default SSE-S3 encryption; S3 native lock). The bucket is the only other object this root needs on
# acc1 and is not managed here (a state bucket cannot hold its own state). Cost: a few KB of state, well under
# 0.01 USD a month. Applied locally by a human with the acc1 SSO session (one-line commands, WSL2; P = the acc1 SSO
# profile of the account map, A = the 12-digit acc1 ID it returns):
#   aws sso login --profile $P
#   A=$(aws sts get-caller-identity --profile $P --query Account --output text)
#   aws s3api create-bucket --bucket aa-cis-tfstate-acc1-bedrock-$A --region us-west-1 --create-bucket-configuration LocationConstraint=us-west-1 --profile $P
#   aws s3api put-bucket-versioning --bucket aa-cis-tfstate-acc1-bedrock-$A --versioning-configuration Status=Enabled --profile $P
#   aws s3api put-public-access-block --bucket aa-cis-tfstate-acc1-bedrock-$A --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true --profile $P
#   printf 'account_id  = "%s"\naws_profile = "%s"\n' "$A" "$P" > accounts/acc1-bedrock/terraform.tfvars
#   terraform -chdir=accounts/acc1-bedrock init -backend-config="bucket=aa-cis-tfstate-acc1-bedrock-$A" -backend-config="profile=$P"
#   terraform -chdir=accounts/acc1-bedrock plan -out=acc1-bedrock.tfplan
#   terraform -chdir=accounts/acc1-bedrock apply acc1-bedrock.tfplan
# allowed_account_ids (var.account_id) refuses a plan against any other account (the AA-517 wrong-account writes).
# =============================================================================

terraform {
  required_version = ">= 1.10.0, < 2.0.0" # use_lockfile (S3 native lock) needs 1.10+

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69"
    }
  }

  # bucket and profile: -backend-config at init (header), never committed.
  backend "s3" {
    key          = "acc1-bedrock/terraform.tfstate"
    region       = "us-west-1"
    use_lockfile = true
  }
}

variable "account_id" {
  description = "AA-1095: acc1's 12-digit ID, the only account this root may plan or apply against (provider allowed_account_ids). From the untracked terraform.tfvars; never committed."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be acc1's 12-digit account ID (root repo account map)."
  }
}

variable "aws_profile" {
  description = "AA-1095: the acc1 SSO profile (root repo account map). From the untracked terraform.tfvars; never committed."
  type        = string
}

provider "aws" {
  region              = "us-west-1"
  profile             = var.aws_profile
  allowed_account_ids = [var.account_id]

  # Tagging standard (root docs/architecture/tagging-standard.md, FIN-03). A single-purpose root (Bedrock serving),
  # so App and Component default here, as in accounts/acc3-bedrock. Bedrock model usage carries no resource tag:
  # per-app LLM spend comes from the gateway ledger (DM-10.4), not tags.
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
      Issue              = "AA-1095"
    }
  }
}
