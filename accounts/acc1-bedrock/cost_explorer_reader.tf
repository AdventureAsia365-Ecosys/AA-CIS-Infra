
# =============================================================================
# AA-623 — new AA-CostExplorer-Reader role on account 1 (867490540162).
# NOT an import — this role does not exist yet on acc1. Mirrors the
# satellite-invoker pattern used for Bedrock (bedrock_invoker_import.tf /
# accounts/acc3-bedrock/main.tf) so acc2's ECS task role can pull acc1's own
# Cost Explorer data (each account's CE only sees its own costs — acc2 is a
# member account, not the AWS Organizations payer, so org-level consolidated
# CE from acc2 is not possible; see AA-623 Linear comment for the
# `organizations:DescribeOrganization` finding that ruled that path out).
#
# ExternalId "aa623-satellite-cost-explorer" — distinct from the Bedrock
# ExternalIds ("aa296-satellite-bedrock" / "-acc3") so this grant cannot be
# reused to assume the Bedrock role or vice versa.
# =============================================================================

resource "aws_iam_role" "cost_explorer_reader" {
  name = "AA-CostExplorer-Reader"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAcc2ECSTaskRoleAssume"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::005097885195:role/aa-cis-dev-ecs-task-role"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = { "sts:ExternalId" = "aa623-satellite-cost-explorer" }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "cost_explorer_reader_policy" {
  name = "CostExplorerReadOnly"
  role = aws_iam_role.cost_explorer_reader.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Cost Explorer does not support resource-level ARN scoping — same
        # Resource="*" shape as the acc2 ecs_task_infra_status_readonly grant
        # (modules/ecs/main.tf, AA-623 PR #68).
        Sid    = "AllowCostExplorerRead"
        Effect = "Allow"
        Action = [
          "ce:GetCostAndUsage"
        ]
        Resource = "*"
      }
    ]
  })
}
