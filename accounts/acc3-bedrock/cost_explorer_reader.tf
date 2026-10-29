
# =============================================================================
# AA-623 — new AA3-CostExplorer-Reader role on account 3 (786888028788).
# NOT an import — copied from the former acc1 Cost Explorer reader (root
# removed with acc1, AA-998) except account ID/role name/ExternalId.
# Rationale: acc2 is not the Organizations payer, so each satellite account
# needs its own CE-read grant.
# =============================================================================

resource "aws_iam_role" "cost_explorer_reader" {
  name = "AA3-CostExplorer-Reader"

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
          StringEquals = { "sts:ExternalId" = "aa623-satellite-cost-explorer-acc3" }
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
