
# =============================================================================
# AA-623 — grant acc2's ECS task role permission to assume the new
# AA-CostExplorer-Reader (acc1) and AA3-CostExplorer-Reader (acc3) roles, so
# the CE reconcile job can read each satellite account's own Cost Explorer
# data. Mirrors bedrock_satellite_assume.tf's shape (separate resource, does
# NOT touch that file or the Bedrock statements in it).
#
# acc2 itself already has direct `ce:GetCostAndUsage` on its own task role
# (modules/ecs/main.tf ecs_task_infra_status_readonly, AA-623 PR #68) — no
# AssumeRole needed for acc2's own costs, only for reaching acc1/acc3.
# =============================================================================

resource "aws_iam_role_policy" "ecs_assume_cost_explorer_reader" {
  name = "aa-cis-dev-ecs-assume-cost-explorer-reader"
  role = module.ecs.task_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AssumeSatelliteCostExplorerReaderAcc1"
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = "arn:aws:iam::867490540162:role/AA-CostExplorer-Reader"
      },
      {
        Sid      = "AssumeSatelliteCostExplorerReaderAcc3"
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = "arn:aws:iam::786888028788:role/AA3-CostExplorer-Reader"
      }
    ]
  })
}
