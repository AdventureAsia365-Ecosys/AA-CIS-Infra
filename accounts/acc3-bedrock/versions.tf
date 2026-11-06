# =============================================================================
# AA-397 — account 3 (786888028788), us-west-1
# Minimal root, separate state, scoped ONLY to the satellite-invoker IAM role
# (same structure/scope as the former acc1 root, removed in AA-998). Does NOT
# touch accounts/aa365 or the repo root.
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
    bucket  = "aa-cis-tfstate-acc3-bedrock-786888028788"
    key     = "acc3-bedrock/terraform.tfstate"
    region  = "us-west-1"
    profile = "nghiep_aa365"
  }
}

provider "aws" {
  region  = "us-west-1"
  profile = "nghiep_aa365"

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
