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
#      AA-832 completes the RDS rows of data standard C4.1 (latency, disk queue, XID wraparound,
#      per-role connections) and grants the CIS task role PutMetricData on namespace AA/RDS.
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

  # AA-832: `SHOW max_connections` on aa-cis-dev-db (db.t4g.small) measured 16/10/2026 = 181
  # (LEAST(DBInstanceClassMemory/9531392, 5000); 3 of them are superuser_reserved_connections).
  # Data standard C4.1b: an instance resize MUST update this value in the same PR; the
  # rds-connections-high threshold below is derived from it.
  rds_max_connections = 181

  # AA-832: LOGIN roles with a CONNECTION LIMIT (`ALTER ROLE ... CONNECTION LIMIT n` in the app
  # migrations, measured from pg_roles 16/10/2026). One RoleConnectionLimitPct alarm per key; the
  # CIS job ops_rds_role_connections discovers the roles itself, so a new limited role only needs a
  # row here to get an alarm. aa_cis_admin has no limit (-1) and publishes nothing.
  rds_role_connection_limits = {
    tripplanner = 30
    booking     = 15
    aa_app_user = 15
  }
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

# max_connections = LEAST(DBInstanceClassMemory/9531392, 5000) = 181 on db.t4g.small (measured
# 16/10/2026, local.rds_max_connections). 3-day peak on 14/10/2026 was 25. AA-824 set > 60 for 5
# minutes, the data standard's t3.micro value (C4.1); AA-832 moves it to the post-resize rule,
# 60 % of max_connections for 5 minutes = floor(0.6 * 181) = 108. The per-role alarms below catch
# a single app exhausting its own CONNECTION LIMIT long before the instance total gets here.
resource "aws_cloudwatch_metric_alarm" "rds_connections_high" {
  alarm_name          = "${local.name_prefix}-rds-connections-high"
  alarm_description   = "RDS ${module.rds.db_identifier} peak connections above ${floor(local.rds_max_connections * 0.6)} (60% of max_connections ${local.rds_max_connections}) within a 5-minute period (shared by CIS, TripPlanner, Booking)."
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  dimensions          = { DBInstanceIdentifier = module.rds.db_identifier }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = floor(local.rds_max_connections * 0.6)
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = merge(local.ecosys_tags, { App = "shared" })
}

# AA-824: db.t4g.small has 2 GB. AA-832 aligns the threshold with data standard C4.1 (< 100 MB was
# the t3.micro row; t4g.small is < 200 MB), so the alarm fires before the instance starts swapping.
resource "aws_cloudwatch_metric_alarm" "rds_freeable_memory_low" {
  alarm_name          = "${local.name_prefix}-rds-freeable-memory-low"
  alarm_description   = "RDS ${module.rds.db_identifier} freeable memory below 200 MB for 10 minutes (too many connections or work_mem pressure)."
  namespace           = "AWS/RDS"
  metric_name         = "FreeableMemory"
  dimensions          = { DBInstanceIdentifier = module.rds.db_identifier }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "LessThanThreshold"
  threshold           = 209715200 # 200 MiB in bytes
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

# -----------------------------------------------------------------------------
# AA-832 — the remaining RDS rows of data standard C4.1 (03-scaling.md), and per-role connections.
#
# Cost (us-west-1 list prices, no free tier assumed: the account already has more than 10 alarms):
#   7 new standard alarms (4 below + 3 per-role)                 7 x $0.10 = $0.70
#   6 custom metrics (RoleConnections + RoleConnectionLimitPct x 3 roles) 6 x $0.30 = $1.80
#   ~8,640 PutMetricData calls/month (one per 5 min)            x $0.01/1k = $0.09
#   ~8,640 Scheduler -> Lambda invocations (dfs_balance.tf): Scheduler $0 (14M free), Lambda ~$0.02,
#   Secrets Manager read ~$0.04, API GW + WAF requests ~$0.04
#   Total about $2.70/month.
# -----------------------------------------------------------------------------

# ReadLatency / WriteLatency are published in SECONDS: 0.020 = 20 ms, averaged over 15 minutes.
resource "aws_cloudwatch_metric_alarm" "rds_read_latency_high" {
  alarm_name          = "${local.name_prefix}-rds-read-latency-high"
  alarm_description   = "RDS ${module.rds.db_identifier} average read latency above 20 ms for 15 minutes (storage I/O saturated; shared by CIS, TripPlanner, Booking)."
  namespace           = "AWS/RDS"
  metric_name         = "ReadLatency"
  dimensions          = { DBInstanceIdentifier = module.rds.db_identifier }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0.020 # seconds
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = merge(local.ecosys_tags, { App = "shared" })
}

resource "aws_cloudwatch_metric_alarm" "rds_write_latency_high" {
  alarm_name          = "${local.name_prefix}-rds-write-latency-high"
  alarm_description   = "RDS ${module.rds.db_identifier} average write latency above 20 ms for 15 minutes (storage I/O saturated; shared by CIS, TripPlanner, Booking)."
  namespace           = "AWS/RDS"
  metric_name         = "WriteLatency"
  dimensions          = { DBInstanceIdentifier = module.rds.db_identifier }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0.020 # seconds
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = merge(local.ecosys_tags, { App = "shared" })
}

resource "aws_cloudwatch_metric_alarm" "rds_disk_queue_depth_high" {
  alarm_name          = "${local.name_prefix}-rds-disk-queue-depth-high"
  alarm_description   = "RDS ${module.rds.db_identifier} average disk queue depth above 10 for 15 minutes (I/O requests waiting on gp storage)."
  namespace           = "AWS/RDS"
  metric_name         = "DiskQueueDepth"
  dimensions          = { DBInstanceIdentifier = module.rds.db_identifier }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = 10
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = merge(local.ecosys_tags, { App = "shared" })
}

# Transaction ID wraparound guard. PostgreSQL forces a shutdown near 2^31 (~2.1 billion) used XIDs;
# 1 billion means autovacuum is not freezing some table and leaves weeks of headroom to find it.
resource "aws_cloudwatch_metric_alarm" "rds_max_used_xid_high" {
  alarm_name          = "${local.name_prefix}-rds-max-used-xid-high"
  alarm_description   = "RDS ${module.rds.db_identifier} MaximumUsedTransactionIDs above 1,000,000,000 (wraparound guard: check autovacuum / age(datfrozenxid))."
  namespace           = "AWS/RDS"
  metric_name         = "MaximumUsedTransactionIDs"
  dimensions          = { DBInstanceIdentifier = module.rds.db_identifier }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 1000000000
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = merge(local.ecosys_tags, { App = "shared" })
}

# Per-role connections against each role's CONNECTION LIMIT. Custom metric AA/RDS
# RoleConnectionLimitPct{Role}, published by the CIS job ops_rds_role_connections (one sample per
# role every 5 minutes, enqueued by aws_scheduler_schedule.rds_role_connections in dfs_balance.tf).
# One sample per period, so one datapoint above 80 % alarms. Missing data does not alarm: if the
# schedule or the job stops, these stay OK (check GET /admin/job-runner/summary for the kind).
resource "aws_cloudwatch_metric_alarm" "rds_role_connections_high" {
  for_each = local.rds_role_connection_limits

  alarm_name          = "${local.name_prefix}-rds-role-connections-${each.key}"
  alarm_description   = "RDS ${module.rds.db_identifier} role ${each.key} above 80% of its CONNECTION LIMIT ${each.value} (more than ${floor(each.value * 0.8)} sessions) in a 5-minute sample. New connections for this role fail at ${each.value}."
  namespace           = "AA/RDS"
  metric_name         = "RoleConnectionLimitPct"
  dimensions          = { Role = each.key }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = merge(local.ecosys_tags, { App = "shared" })
}

# The job above runs on the CIS worker. The api and worker task definitions share one task role
# (modules/ecs aws_iam_role.ecs_task, aa-cis-dev-ecs-task-role), so the grant goes on that role.
# PutMetricData has no resource ARN; the namespace condition limits it to AA/RDS (the module's own
# statement covers the older "acp" namespace).
resource "aws_iam_role_policy" "cis_ecs_task_put_metric_aa_rds" {
  name = "aa-cis-${var.environment}-ecs-put-metric-aa-rds"
  role = module.ecs.task_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PutMetricDataAaRds"
      Effect    = "Allow"
      Action    = "cloudwatch:PutMetricData"
      Resource  = "*"
      Condition = { StringEquals = { "cloudwatch:namespace" = "AA/RDS" } }
    }]
  })
}
