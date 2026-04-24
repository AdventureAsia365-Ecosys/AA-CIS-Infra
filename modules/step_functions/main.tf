# =============================================================================
# AA-CIS Step Functions Module — S11 Phase 4
# State Machine definition loaded from pipeline.asl.json (templatefile)
# =============================================================================

locals {
  name_prefix = "${var.project}-${var.environment}"
  common_tags = merge(var.tags, {
    Module = "step_functions"
    Layer  = "orchestration"
  })
}

resource "aws_iam_role" "sfn_exec" {
  name = "${local.name_prefix}-sfn-exec"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = local.common_tags
}

resource "aws_iam_role_policy" "sfn_permissions" {
  name = "${local.name_prefix}-sfn-permissions"
  role = aws_iam_role.sfn_exec.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InvokeLambda"
        Effect = "Allow"
        Action = ["lambda:InvokeFunction"]
        Resource = [
          var.seo_lambda_arn, "${var.seo_lambda_arn}:*",
          var.validation_lambda_arn, "${var.validation_lambda_arn}:*",
          var.export_lambda_arn, "${var.export_lambda_arn}:*"
        ]
      },
      {
        Sid      = "ECSRunTask"
        Effect   = "Allow"
        Action   = ["ecs:RunTask", "ecs:StopTask", "ecs:DescribeTasks"]
        Resource = ["*"]
      },
      {
        Sid      = "PassRoleECS"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = ["*"]
        Condition = { StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" } }
      },
      {
        Sid      = "EventBridge"
        Effect   = "Allow"
        Action   = ["events:PutTargets", "events:PutRule", "events:DescribeRule"]
        Resource = "arn:aws:events:${var.aws_region}:${var.account_id}:rule/StepFunctions*"
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogDelivery", "logs:GetLogDelivery", "logs:UpdateLogDelivery",
          "logs:DeleteLogDelivery", "logs:ListLogDeliveries", "logs:PutResourcePolicy",
          "logs:DescribeResourcePolicies", "logs:DescribeLogGroups"
        ]
        Resource = "*"
      },
      {
        Sid      = "XRay"
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetSamplingRules", "xray:GetSamplingTargets"]
        Resource = ["*"]
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/aws/states/${local.name_prefix}-pipeline"
  retention_in_days = 14
  tags              = local.common_tags
}

resource "aws_sfn_state_machine" "pipeline" {
  name     = "${local.name_prefix}-pipeline"
  role_arn = aws_iam_role.sfn_exec.arn

  definition = templatefile("${path.module}/pipeline.asl.json", {
    seo_lambda_arn          = var.seo_lambda_arn
    validation_lambda_arn   = var.validation_lambda_arn
    export_lambda_arn       = var.export_lambda_arn
    ecs_cluster_arn         = var.ecs_cluster_arn
    ecs_task_definition_arn = var.ecs_task_definition_arn
    ecs_container_name      = var.ecs_container_name
    sg_app_id               = var.sg_app_id
    subnets_json            = jsonencode(var.private_subnet_ids)
  })

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
    include_execution_data = true
    level                  = "ERROR"
  }

  tracing_configuration {
    enabled = true
  }

  tags = local.common_tags
}
