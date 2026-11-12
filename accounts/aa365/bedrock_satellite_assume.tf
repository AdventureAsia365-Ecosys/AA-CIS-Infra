# =============================================================================
# AA-398 (child of AA-397) — the existing aa-cis-dev-ecs-assume-bedrock-invoker
# inline policy (hand-created for AA-296, never Terraform-tracked — confirmed by
# repo-wide grep before writing this file) was imported into state (the import
# block was removed in S243 once the address was in state), then a second
# statement granted AssumeRole into acc3's AA3-Bedrock-Invoker (786888028788).
#
# AA-998 (S255): acc1 left the ecosystem. Its statement
# "AssumeSatelliteBedrockInvoker" (acc1 AA-Bedrock-Invoker) is removed; acc3 is
# the only LLM satellite. The policy name and resource address do not change
# (in-place update).
#
# AA-1095 (S278): AWS refuses 7 chat models on acc3 at account level, so the gateway serves Bedrock from acc1 again
# (root ADR 0001a, Note S278: the Bedrock invoker role only, nothing else on acc1). Statement
# "AssumeSatelliteBedrockInvokerAcc1" grants AssumeRole into acc1's AA1-Bedrock-Invoker (accounts/acc1-bedrock);
# acc3's statement stays (acc3 is kept behind acc1 until its AWS case is solved). In-place update again.
# =============================================================================

resource "aws_iam_role_policy" "ecs_assume_bedrock_invoker" {
  name = "aa-cis-dev-ecs-assume-bedrock-invoker"
  role = module.ecs.task_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      # AA-398: acc3's satellite invoker role, the only one since AA-998.
      {
        Sid      = "AssumeSatelliteBedrockInvokerAcc3"
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = "arn:aws:iam::786888028788:role/AA3-Bedrock-Invoker"
      }
      ],
      # AA-1095: acc1's invoker role (Bedrock chat models only; trust pinned to this task role + ExternalId). Only
      # when the account ID secret is set: an unset secret leaves the policy exactly as before.
      local.bedrock_acct_payer == "" ? [] : [
        {
          Sid      = "AssumeSatelliteBedrockInvokerAcc1"
          Effect   = "Allow"
          Action   = "sts:AssumeRole"
          Resource = "arn:aws:iam::${local.bedrock_acct_payer}:role/AA1-Bedrock-Invoker"
        }
    ])
  })
}

# AA-902 (S244): the satellite account ID in ONE place. The public app repos no longer carry it; the
# CIS api/worker task definitions and both TripPlanner Lambdas get it as env BEDROCK_ACCT_PRIMARY (acc3).
# AA-998: the acc1 fallback (BEDROCK_ACCT_FALLBACK) is gone.
# AA-1095 (S278): acc1, the payer of acc3's organization, serves Bedrock chat models while acc3 is blocked. The CIS
# api/worker task definitions get it as env BEDROCK_ACCT_PAYER (the CIS connection row `acc1` names that env var;
# the public app repo carries no account ID). TripPlanner does not get it (its gateway calls acc3 only).
# acc1 is a personal account: its ID is never committed here (CONTEXT.md "No new account ID goes into this repo"; root
# docs/security/baseline.md keeps it in the public-repo pattern). It comes from the repo secret BEDROCK_ACCT_PAYER_ID
# as TF_VAR_bedrock_acct_payer_id (terraform-plan.yml, terraform-apply.yml, terraform-drift.yml), like
# MGMT_ACCOUNT_ID (org_access.tf); locally from the account map / `aws sts get-caller-identity` of the acc1 profile.
variable "bedrock_acct_payer_id" {
  description = "AA-1095: 12-digit ID of acc1 (Bedrock chat serving while acc3 is blocked). From the repo secret BEDROCK_ACCT_PAYER_ID in CI; never in a committed file. Unset: no assume grant, empty task env."
  type        = string
  default     = null

  validation {
    # GitHub passes a missing secret as "", not null: both mean "not set".
    condition     = var.bedrock_acct_payer_id == null || var.bedrock_acct_payer_id == "" || can(regex("^[0-9]{12}$", var.bedrock_acct_payer_id))
    error_message = "TF_VAR_bedrock_acct_payer_id must be a 12-digit account ID (repo secret BEDROCK_ACCT_PAYER_ID) or unset."
  }
}

locals {
  bedrock_acct_primary = "786888028788" # acc3
  bedrock_acct_payer   = var.bedrock_acct_payer_id == null ? "" : var.bedrock_acct_payer_id
}
