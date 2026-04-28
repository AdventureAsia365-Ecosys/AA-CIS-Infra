locals {
  name_prefix = "${var.project}-${var.environment}"
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${local.name_prefix}-pipeline"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 8
        height = 6
        properties = {
          title   = "Lambda Invocations"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 300
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", "${local.name_prefix}-ingestion"],
            ["AWS/Lambda", "Invocations", "FunctionName", "${local.name_prefix}-seo"],
            ["AWS/Lambda", "Invocations", "FunctionName", "${local.name_prefix}-content"],
            ["AWS/Lambda", "Invocations", "FunctionName", "${local.name_prefix}-validation"],
            ["AWS/Lambda", "Invocations", "FunctionName", "${local.name_prefix}-export"],
          ]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 0
        width  = 8
        height = 6
        properties = {
          title   = "Lambda Errors"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 300
          metrics = [
            ["AWS/Lambda", "Errors", "FunctionName", "${local.name_prefix}-ingestion"],
            ["AWS/Lambda", "Errors", "FunctionName", "${local.name_prefix}-seo"],
            ["AWS/Lambda", "Errors", "FunctionName", "${local.name_prefix}-content"],
            ["AWS/Lambda", "Errors", "FunctionName", "${local.name_prefix}-validation"],
            ["AWS/Lambda", "Errors", "FunctionName", "${local.name_prefix}-export"],
          ]
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 0
        width  = 8
        height = 6
        properties = {
          title   = "Lambda Duration avg ms"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 300
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", "${local.name_prefix}-content",    { stat = "Average" }],
            ["AWS/Lambda", "Duration", "FunctionName", "${local.name_prefix}-validation", { stat = "Average" }],
            ["AWS/Lambda", "Duration", "FunctionName", "${local.name_prefix}-export",     { stat = "Average" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 8
        height = 6
        properties = {
          title   = "SF Executions"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 300
          metrics = [
            ["AWS/States", "ExecutionsStarted",   "StateMachineArn", "arn:aws:states:${var.aws_region}:${var.account_id}:stateMachine:${local.name_prefix}-pipeline"],
            ["AWS/States", "ExecutionsSucceeded", "StateMachineArn", "arn:aws:states:${var.aws_region}:${var.account_id}:stateMachine:${local.name_prefix}-pipeline"],
            ["AWS/States", "ExecutionsFailed",    "StateMachineArn", "arn:aws:states:${var.aws_region}:${var.account_id}:stateMachine:${local.name_prefix}-pipeline"],
          ]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 6
        width  = 8
        height = 6
        properties = {
          title   = "SF Execution Duration avg"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 300
          metrics = [
            ["AWS/States", "ExecutionTime", "StateMachineArn", "arn:aws:states:${var.aws_region}:${var.account_id}:stateMachine:${local.name_prefix}-pipeline", { stat = "Average" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 6
        width  = 8
        height = 6
        properties = {
          title   = "ECS CPU and Memory"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 300
          metrics = [
            ["AWS/ECS", "CPUUtilization",    "ClusterName", "${local.name_prefix}-cluster", "ServiceName", "${local.name_prefix}-api", { stat = "Average" }],
            ["AWS/ECS", "MemoryUtilization", "ClusterName", "${local.name_prefix}-cluster", "ServiceName", "${local.name_prefix}-api", { stat = "Average" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 8
        height = 6
        properties = {
          title   = "RDS Connections"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 300
          metrics = [
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", "${local.name_prefix}-db"],
          ]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 12
        width  = 8
        height = 6
        properties = {
          title   = "RDS CPU and Latency"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 300
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", "${local.name_prefix}-db", { stat = "Average" }],
            ["AWS/RDS", "WriteLatency",   "DBInstanceIdentifier", "${local.name_prefix}-db", { stat = "Average" }],
            ["AWS/RDS", "ReadLatency",    "DBInstanceIdentifier", "${local.name_prefix}-db", { stat = "Average" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 12
        width  = 8
        height = 6
        properties = {
          title   = "ALB Requests and 5xx"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 300
          metrics = [
            ["AWS/ApplicationELB", "RequestCount",           "LoadBalancer", "app/${local.name_prefix}-alb"],
            ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", "app/${local.name_prefix}-alb"],
          ]
        }
      },
    ]
  })
}
