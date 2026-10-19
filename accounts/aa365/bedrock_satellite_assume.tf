# =============================================================================
# AA-398 (child of AA-397) — the existing aa-cis-dev-ecs-assume-bedrock-invoker
# inline policy (hand-created for AA-296, never Terraform-tracked — confirmed by
# repo-wide grep before writing this file) was imported into state (the import
# block was removed in S243 once the address was in state), then a second
# statement grants AssumeRole into acc3's AA3-Bedrock-Invoker (786888028788) —
# parallel to the existing acc1 grant, not a replacement.
#
# Statement "AssumeSatelliteBedrockInvoker" (acc1) copied byte-for-byte from a
# live read (`aws iam get-role-policy --role-name aa-cis-dev-ecs-task-role
# --policy-name aa-cis-dev-ecs-assume-bedrock-invoker --profile aa365-admin`,
# 2026-08-12) — do NOT edit that statement without re-verifying against live
# state first.
# =============================================================================

resource "aws_iam_role_policy" "ecs_assume_bedrock_invoker" {
  name = "aa-cis-dev-ecs-assume-bedrock-invoker"
  role = module.ecs.task_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Unchanged — existing live statement, copied verbatim (AA-296).
      {
        Sid      = "AssumeSatelliteBedrockInvoker"
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = "arn:aws:iam::867490540162:role/AA-Bedrock-Invoker"
      },
      # New — AA-398: parallel grant into acc3's satellite invoker role. Does
      # NOT modify or remove the acc1 statement above.
      {
        Sid      = "AssumeSatelliteBedrockInvokerAcc3"
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = "arn:aws:iam::786888028788:role/AA3-Bedrock-Invoker"
      }
    ]
  })
}

# AA-902 (S244): the satellite account IDs in ONE place. The public app repos no longer carry them; the
# CIS api/worker task definitions and both TripPlanner Lambdas get them as env (BEDROCK_ACCT_PRIMARY =
# acc3, BEDROCK_ACCT_FALLBACK = acc1).
locals {
  bedrock_acct_primary  = "786888028788" # acc3
  bedrock_acct_fallback = "867490540162" # acc1
}
