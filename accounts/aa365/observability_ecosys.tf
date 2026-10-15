# =============================================================================
# S235 Phase 0 (AA-678, ecosystem blueprint) — observability for the parts of acc2 that had none:
# TripPlanner (2 Lambdas), AA-Booking (ECS service + REST API), the shared NAT instance and the
# shared RDS. Before this file all 16 alarms were CIS-only and these log groups had no retention.
#
#   1. Log retention 14 days on groups that AWS created implicitly (so Terraform never managed
#      them): the 2 TripPlanner Lambda groups and the CIS REST API execution-log group. They are
#      brought under Terraform with `import` blocks (Terraform >= 1.5; CI pins 1.7.5): the plan
#      shows "will be imported" + an in-place update (retention + tags), never a create/replace.
#      Once applied, the import blocks are no-ops and can be deleted in a later PR.
#   2. Alarms -> the existing SNS topic aws_sns_topic.alerts (aa-cis-dev-acp-alerts, email).
#
# TAGS: every resource here carries the blueprint tag set (Project = AA-Ecosys, App, Environment,
# ManagedBy = terraform). These resource-level tags override the provider default_tags keys of the
# same name (versions.tf); `Account = aa365` still comes from default_tags. The provider
# default_tags themselves are NOT changed in this PR: changing a value there re-tags every resource
# in the root, and the CI role (cicd.tf) can only iam:TagRole a few role-name patterns, so a CI
# apply would fail with AccessDenied part-way through. Flip default_tags in the follow-up that
# reworks the CI role.
# =============================================================================

locals {
  ecosys_tags = {
    Project     = "AA-Ecosys"
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  # TripPlanner functions, keyed by short name (aws_lambda_function.tripplanner_* in tripplanner.tf).
  tp_functions = {
    browse   = aws_lambda_function.tripplanner_browse.function_name
    assembly = aws_lambda_function.tripplanner_assembly.function_name
  }

  # Execution-log group API Gateway creates for the CIS REST API stage (modules/api_gateway,
  # enable_execution_logging = true). ~157 MB stored with no expiry on 14/10/2026.
  cis_apigw_exec_log_group = "API-Gateway-Execution-Logs_${module.api_gateway.api_gateway_id}/${var.environment}"
}

# -----------------------------------------------------------------------------
# 1. Log retention (import existing, unmanaged groups)
# -----------------------------------------------------------------------------

import {
  to = aws_cloudwatch_log_group.tripplanner_lambda["browse"]
  id = "/aws/lambda/${local.tp_name_prefix}-browse"
}

import {
  to = aws_cloudwatch_log_group.tripplanner_lambda["assembly"]
  id = "/aws/lambda/${local.tp_name_prefix}-assembly"
}

resource "aws_cloudwatch_log_group" "tripplanner_lambda" {
  for_each = local.tp_functions

  name              = "/aws/lambda/${each.value}"
  retention_in_days = 14

  tags = merge(local.ecosys_tags, { App = "tripplanner" })
}

import {
  to = aws_cloudwatch_log_group.cis_apigw_execution
  id = local.cis_apigw_exec_log_group
}

resource "aws_cloudwatch_log_group" "cis_apigw_execution" {
  name              = local.cis_apigw_exec_log_group
  retention_in_days = 14

  tags = merge(local.ecosys_tags, { App = "cis" })
}

# -----------------------------------------------------------------------------
# 2. Alarms
# -----------------------------------------------------------------------------

# Shared NAT instance (t4g.nano, modules/vpc) — single egress path for every private-subnet
# workload (CIS api/worker, Booking, TripPlanner Lambdas in the VPC, LLM calls). Status checks are
# published every minute. Missing data (instance stopped on purpose) does not alarm.
resource "aws_cloudwatch_metric_alarm" "nat_status_check_failed" {
  alarm_name          = "aa-ecosys-${var.environment}-nat-status-check-failed"
  alarm_description   = "NAT instance ${module.vpc.nat_instance_id} failed an EC2 status check for 3 minutes. All private-subnet egress (CIS, Booking, TripPlanner, LLM calls) goes through it."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  dimensions          = { InstanceId = module.vpc.nat_instance_id }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = merge(local.ecosys_tags, { App = "shared" })
}

# AA-Booking service health, through its ALB target group (Container Insights is disabled on the
# cluster, so ECS/ContainerInsights RunningTaskCount does not exist). HealthyHostCount < 1 means
# no task is serving. Missing data does not alarm, so a deliberate desired_count = 0 stays quiet
# only while the target group publishes nothing; if it alarms after a scale-to-0, that is expected.
resource "aws_cloudwatch_metric_alarm" "booking_no_healthy_task" {
  alarm_name          = "${local.bk_name_prefix}-no-healthy-task"
  alarm_description   = "AA-Booking target group ${aws_lb_target_group.booking.name} has no healthy target for 5 minutes (service down or failing /booking/health)."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  dimensions          = { TargetGroup = aws_lb_target_group.booking.arn_suffix, LoadBalancer = module.alb.alb_arn_suffix }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 5
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = merge(local.ecosys_tags, { App = "booking" })
}

resource "aws_cloudwatch_metric_alarm" "booking_unhealthy_hosts" {
  alarm_name          = "${local.bk_name_prefix}-unhealthy-hosts"
  alarm_description   = "AA-Booking target group ${aws_lb_target_group.booking.name} has an unhealthy target for 5 minutes in a row."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  dimensions          = { TargetGroup = aws_lb_target_group.booking.arn_suffix, LoadBalancer = module.alb.alb_arn_suffix }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = merge(local.ecosys_tags, { App = "booking" })
}

resource "aws_cloudwatch_metric_alarm" "booking_cpu_high" {
  alarm_name          = "${local.bk_name_prefix}-cpu-high"
  alarm_description   = "AA-Booking ECS service ${local.bk_service} CPU above 85% for 15 minutes."
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  dimensions          = { ClusterName = module.ecs.cluster_name, ServiceName = local.bk_service }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = 85
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = merge(local.ecosys_tags, { App = "booking" })
}

# Booking REST API (9z3xnalp59) 5XX — API-level metrics (ApiName + Stage) are published without
# detailed metrics. 5 or more 5XX in 5 minutes on Dev traffic is a real failure, not noise.
resource "aws_cloudwatch_metric_alarm" "booking_api_5xx" {
  alarm_name          = "${local.bk_name_prefix}-api-5xx"
  alarm_description   = "AA-Booking REST API ${aws_api_gateway_rest_api.booking.name} stage ${aws_api_gateway_stage.booking.stage_name}: 5 or more 5XX responses in 5 minutes."
  namespace           = "AWS/ApiGateway"
  metric_name         = "5XXError"
  dimensions          = { ApiName = aws_api_gateway_rest_api.booking.name, Stage = aws_api_gateway_stage.booking.stage_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 5
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = merge(local.ecosys_tags, { App = "booking" })
}

# TripPlanner Lambdas — errors (3+ in 5 minutes) and sustained throttling (see below).
resource "aws_cloudwatch_metric_alarm" "tripplanner_lambda_errors" {
  for_each = local.tp_functions

  alarm_name          = "${each.value}-errors"
  alarm_description   = "TripPlanner Lambda ${each.value}: 3 or more invocation errors in 5 minutes."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = each.value }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 3
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = merge(local.ecosys_tags, { App = "tripplanner" })
}

# AA-833: was "Sum > 0 in one 5-minute period" with alarm + OK actions. A single burst (a page
# prefetch fan-out after a deploy or ISR expiry) flipped browse OK -> ALARM -> OK 7 times in two
# days, 14 emails on the topic that also carries the RDS, NAT and Booking alarms. It now pages only
# on sustained throttling: more than 5 throttles in at least 2 of 3 consecutive 5-minute periods.
# No ok_actions here (unlike the other alarms in this file): each flip would still cost 2 emails,
# and the recovery is visible in the console / describe-alarm-history.
resource "aws_cloudwatch_metric_alarm" "tripplanner_lambda_throttles" {
  for_each = local.tp_functions

  alarm_name          = "${each.value}-throttles"
  alarm_description   = "TripPlanner Lambda ${each.value}: more than 5 throttles (account or reserved concurrency limit) in at least 2 of 3 consecutive 5-minute periods. No OK notification."
  namespace           = "AWS/Lambda"
  metric_name         = "Throttles"
  dimensions          = { FunctionName = each.value }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = 5
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  tags = merge(local.ecosys_tags, { App = "tripplanner" })
}

# Shared RDS (aa-cis-dev-db: CIS + TripPlanner + Booking). AA-824: storage autoscaling to 100 GB
# (modules/rds), so the alarm is an early warning at 50% of the configured base size (10 GiB free
# of 20 GB), well before autoscaling kicks in at 10% free. The threshold follows the configured
# base size, not the autoscaled size.
resource "aws_cloudwatch_metric_alarm" "rds_free_storage_low" {
  alarm_name          = "${local.name_prefix}-rds-free-storage-low"
  alarm_description   = "RDS ${module.rds.db_identifier} free storage below 50% of the ${module.rds.allocated_storage} GB base allocation (shared by CIS, TripPlanner, Booking; autoscaling up to 100 GB)."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  dimensions          = { DBInstanceIdentifier = module.rds.db_identifier }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "LessThanThreshold"
  threshold           = module.rds.allocated_storage * 1073741824 * 0.5 # 50% of base GB, in bytes
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = merge(local.ecosys_tags, { App = "shared" })
}

# max_connections = LEAST(DBInstanceClassMemory/9531392, 5000): roughly 80-110 on db.t3.micro,
# roughly 190-200 on db.t4g.small (AA-824). 3-day peak on 14/10/2026 was 25. AA-824 tightens the
# alarm to > 60 for 5 minutes (was > 70 for 10) so a TripPlanner burst shows up before the
# connection budget (per-role CONNECTION LIMIT, Lambda reserved concurrency) is exhausted.
resource "aws_cloudwatch_metric_alarm" "rds_connections_high" {
  alarm_name          = "${local.name_prefix}-rds-connections-high"
  alarm_description   = "RDS ${module.rds.db_identifier} peak connections above 60 within a 5-minute period (shared by CIS, TripPlanner, Booking)."
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  dimensions          = { DBInstanceIdentifier = module.rds.db_identifier }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 60
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = merge(local.ecosys_tags, { App = "shared" })
}

# AA-824: db.t4g.small has 2 GB. Below 100 MB the instance starts swapping.
resource "aws_cloudwatch_metric_alarm" "rds_freeable_memory_low" {
  alarm_name          = "${local.name_prefix}-rds-freeable-memory-low"
  alarm_description   = "RDS ${module.rds.db_identifier} freeable memory below 100 MB for 10 minutes (too many connections or work_mem pressure)."
  namespace           = "AWS/RDS"
  metric_name         = "FreeableMemory"
  dimensions          = { DBInstanceIdentifier = module.rds.db_identifier }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "LessThanThreshold"
  threshold           = 104857600 # 100 MiB in bytes
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = merge(local.ecosys_tags, { App = "shared" })
}

# AA-824: RDS T-class instances run in Unlimited mode, so CPU credit exhaustion shows up as cost
# (surplus credits charged), not as throttling. Any charged credit means the instance is too small
# for its sustained load.
resource "aws_cloudwatch_metric_alarm" "rds_cpu_surplus_credits_charged" {
  alarm_name          = "${local.name_prefix}-rds-cpu-surplus-credits-charged"
  alarm_description   = "RDS ${module.rds.db_identifier} is being charged for CPU surplus credits (T-class Unlimited mode: sustained CPU above baseline)."
  namespace           = "AWS/RDS"
  metric_name         = "CPUSurplusCreditsCharged"
  dimensions          = { DBInstanceIdentifier = module.rds.db_identifier }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = merge(local.ecosys_tags, { App = "shared" })
}
