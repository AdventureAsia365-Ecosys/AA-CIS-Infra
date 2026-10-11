locals {
  name_prefix = "${var.project}-${var.environment}"
}

# AA-750: the Lambda and Step Functions widgets were removed with those resources.
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
        x      = 8
        y      = 0
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
        x      = 16
        y      = 0
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
        x      = 0
        y      = 6
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
