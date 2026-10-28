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
# =============================================================================

resource "aws_iam_role_policy" "ecs_assume_bedrock_invoker" {
  name = "aa-cis-dev-ecs-assume-bedrock-invoker"
  role = module.ecs.task_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # AA-398: acc3's satellite invoker role, the only one since AA-998.
      {
        Sid      = "AssumeSatelliteBedrockInvokerAcc3"
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = "arn:aws:iam::786888028788:role/AA3-Bedrock-Invoker"
      }
    ]
  })
}

# AA-902 (S244): the satellite account ID in ONE place. The public app repos no longer carry it; the
# CIS api/worker task definitions and both TripPlanner Lambdas get it as env BEDROCK_ACCT_PRIMARY (acc3).
# AA-998: the acc1 fallback (BEDROCK_ACCT_FALLBACK) is gone.
locals {
  bedrock_acct_primary = "786888028788" # acc3
}
