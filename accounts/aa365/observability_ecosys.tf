# =============================================================================
# S235 Phase 0 (AA-678, ecosystem blueprint) — observability for the parts of acc2 that had none:
# TripPlanner (2 Lambdas), AA-Booking (ECS service + REST API), the shared NAT instance and the
# shared RDS. Before this file all 16 alarms were CIS-only and these log groups had no retention.
#
#   1. Log retention 14 days on groups that AWS created implicitly (so Terraform never managed
#      them): the 2 TripPlanner Lambda groups and the CIS REST API execution-log group. They are
#      brought under Terraform with `import` blocks (Terraform >= 1.5; CI pins 1.7.5): the plan
#      showed "will be imported" + an in-place update (retention + tags), never a create/replace.
#      Once applied the import blocks were no-ops; they were deleted in S243.
#   2. Alarms -> the existing SNS topic aws_sns_topic.alerts (aa-cis-dev-acp-alerts, email).
#      AA-832 completes the RDS rows of data standard C4.1 (latency, disk queue, XID wraparound,
#      per-role connections) and grants the CIS task role PutMetricData on namespace AA/RDS.
#      AA-751 adds the job backlog alarms per owner (AA/Jobs/CIS, AA/Jobs/Booking, end of file).
#
# NOTIFICATIONS: ALARM and OK (S241 D-20, AA-872; AA-751 had made them alarm-only). Every alarm in
# this file, observability.tf, ses.tf, identity.tf and modules/eventbridge has alarm_actions AND
# ok_actions on the shared topic: Nghiệp wants the recovery e-mail too. A flapping alarm therefore
# costs two e-mails per flip (the AA-833 lesson) — fix the threshold/evaluation, not the actions.
# A new alarm without ok_actions is a review finding.
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
  # CIS api sampler (api/core/ops_metrics_sampler.py, AA-751) discovers the roles itself, so a new
  # limited role only needs a row here to get an alarm. aa_cis_admin has no limit (-1) and
  # publishes nothing.
  rds_role_connection_limits = {
    tripplanner = 30
    booking     = 15
    aa_app_user = 15
    # X1 S11 (AA-852): cis_app (rl-001, no LOGIN use until S18). 90 = the XD6 floor; S15 measures the
    # real peak and the limit (max(90, 2 x peak + one deploy set)) is restated here in the same PR.
    # No sessions until S18, so the alarm stays OK (treat_missing_data = notBreaching).
    cis_app = 90
  }
}

# -----------------------------------------------------------------------------
# 1. Log retention (groups that existed unmanaged; adopted by import blocks in S235, which
#    were removed in S243 once the addresses were in state)
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "tripplanner_lambda" {
  for_each = local.tp_functions

  name              = "/aws/lambda/${each.value}"
  retention_in_days = 30 # AA-872 (S241 D-09): app logs 30 days

  tags = merge(local.ecosys_tags, { App = "tripplanner" })
}

resource "aws_cloudwatch_log_group" "cis_apigw_execution" {
  name              = local.cis_apigw_exec_log_group
  retention_in_days = 30 # AA-872 (S241 D-09): app logs 30 days

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
  alarm_description   = "NAT instance ${module.vpc.nat_instance_id} failed an EC2 status check for 3 minutes. All private-subnet egress (CIS, Booking, TripPlanner, LLM calls) goes through it.${local.runbook_suffix.incident}"
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
  alarm_description   = "AA-Booking target group ${aws_lb_target_group.booking.name} has no healthy target for 5 minutes (service down or failing /booking/health).${local.runbook_suffix.api_5xx}"
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
  alarm_description   = "AA-Booking target group ${aws_lb_target_group.booking.name} has an unhealthy target for 5 minutes in a row.${local.runbook_suffix.api_5xx}"
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
  alarm_description   = "AA-Booking ECS service ${local.bk_service} CPU above 85% for 15 minutes.${local.runbook_suffix.api_5xx}"
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
  alarm_description   = "AA-Booking REST API ${aws_api_gateway_rest_api.booking.name} stage ${aws_api_gateway_stage.booking.stage_name}: 5 or more 5XX responses in 5 minutes.${local.runbook_suffix.api_5xx}"
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

# CIS REST API (4ylo382khg) — AA-870. 5XX by count, like Booking above: at Dev traffic (3,641 requests
# and 3 5XX in the week to 17/10/2026) a rate alarm would fire on 1 error in 2 requests. Latency: the p95
# of IntegrationLatency per 15-minute window had a median of 290 ms and a max of 6.9 s that week, so the
# alarm wants p95 above 5 s for 3 consecutive 5-minute periods (sustained, not one slow pipeline call).
# 2 standard alarms, about 0.20 USD/month (D-19).
resource "aws_cloudwatch_metric_alarm" "cis_api_5xx" {
  alarm_name          = "${local.name_prefix}-api-5xx"
  alarm_description   = "AA-CIS REST API ${module.api_gateway.api_name} stage ${module.api_gateway.stage_name}: 5 or more 5XX responses in 5 minutes.${local.runbook_suffix.api_5xx}"
  namespace           = "AWS/ApiGateway"
  metric_name         = "5XXError"
  dimensions          = { ApiName = module.api_gateway.api_name, Stage = module.api_gateway.stage_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 5
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = merge(local.ecosys_tags, { App = "cis" })
}

resource "aws_cloudwatch_metric_alarm" "cis_api_latency_p95" {
  alarm_name          = "${local.name_prefix}-api-latency-p95"
  alarm_description   = "AA-CIS REST API ${module.api_gateway.api_name}: IntegrationLatency p95 above 5 s for 15 minutes.${local.runbook_suffix.api_5xx}"
  namespace           = "AWS/ApiGateway"
  metric_name         = "IntegrationLatency"
  dimensions          = { ApiName = module.api_gateway.api_name, Stage = module.api_gateway.stage_name }
  extended_statistic  = "p95"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = 5000
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = merge(local.ecosys_tags, { App = "cis" })
}

# TripPlanner Lambdas — errors (3+ in 5 minutes) and sustained throttling (see below).
resource "aws_cloudwatch_metric_alarm" "tripplanner_lambda_errors" {
  for_each = local.tp_functions

  alarm_name          = "${each.value}-errors"
  alarm_description   = "TripPlanner Lambda ${each.value}: 3 or more invocation errors in 5 minutes.${local.runbook_suffix.api_5xx}"
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
# ok_actions since AA-872 (S241 D-20): a flip costs 2 e-mails, which is why the evaluation above is
# strict (2 of 3 periods) rather than the actions being cut.
resource "aws_cloudwatch_metric_alarm" "tripplanner_lambda_throttles" {
  for_each = local.tp_functions

  alarm_name          = "${each.value}-throttles"
  alarm_description   = "TripPlanner Lambda ${each.value}: more than 5 throttles (account or reserved concurrency limit) in at least 2 of 3 consecutive 5-minute periods. No OK notification.${local.runbook_suffix.api_5xx}"
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
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = merge(local.ecosys_tags, { App = "tripplanner" })
}

# Shared RDS (aa-cis-dev-db: CIS + TripPlanner + Booking). AA-824: storage autoscaling to 100 GB
# (modules/rds), so the alarm is an early warning at 50% of the configured base size (10 GiB free
# of 20 GB), well before autoscaling kicks in at 10% free. The threshold follows the configured
# base size, not the autoscaled size.
resource "aws_cloudwatch_metric_alarm" "rds_free_storage_low" {
  alarm_name          = "${local.name_prefix}-rds-free-storage-low"
  alarm_description   = "RDS ${module.rds.db_identifier} free storage below 50% of the ${module.rds.allocated_storage} GB base allocation (shared by CIS, TripPlanner, Booking; autoscaling up to 100 GB).${local.runbook_suffix.database}"
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
  alarm_description   = "RDS ${module.rds.db_identifier} peak connections above ${floor(local.rds_max_connections * 0.6)} (60% of max_connections ${local.rds_max_connections}) within a 5-minute period (shared by CIS, TripPlanner, Booking).${local.runbook_suffix.database}"
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
  alarm_description   = "RDS ${module.rds.db_identifier} freeable memory below 200 MB for 10 minutes (too many connections or work_mem pressure).${local.runbook_suffix.database}"
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
  alarm_description   = "RDS ${module.rds.db_identifier} is being charged for CPU surplus credits (T-class Unlimited mode: sustained CPU above baseline).${local.runbook_suffix.database}"
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
# Cost (us-west-1 list prices; re-counted in S240 for AA-751, which replaced the sampling chain):
#   Custom metrics: the first 10 per account are free. acc2 publishes AA/RDS 6 (RoleConnections +
#   RoleConnectionLimitPct x 3 roles) + AA-751's 4 (AA/Jobs/CIS + AA/Jobs/Booking, 2 metrics each, no
#   dimensions) = 10. The old console-made log metric filter ACP/Pipeline T3FallbackUsedCount (AA-296,
#   never fired, alarm with no actions) was deleted on 16/10/2026, so those 10 were free: $0. A metric is
#   billed only while it receives data; the aa-cis/ops log-write-failure filters have no default value,
#   so they cost nothing until a write actually fails.
#   X1 rl-001 (AA-852) created cis_app LOGIN CONNECTION LIMIT 90; the sampler discovers it by itself
#   (rolcanlogin AND rolconnlimit > 0), so AA/RDS grows to 8 (4 roles x 2) and acc2 to 12 metrics:
#   2 above the free tier at ~$0.30 each = ~$0.60/month (caused by rl-001, counted here since S11).
#   Alarms: acc2 already has more than the 10 free (42 on 16/10/2026), so every one is $0.10:
#   AA-832 9 (4 below + 4 per-role + "sampling stopped")         9 x $0.10 = $0.90
#   AA-751 6 (3 job backlog alarms x 2 owners, end of file)      6 x $0.10 = $0.60
#   PutMetricData: CIS 2 calls per 5 min (AA/RDS + AA/Jobs/CIS) + Booking 1 = ~25,900/month,
#   inside the 1M free API requests: $0.
#   Sampling runs in process (CIS api ops_metrics_sampler, Booking JobMetricsSampler), so there is
#   no Scheduler -> Lambda -> API Gateway / WAF / Secrets Manager traffic for it any more (the
#   AA-832 every-5-minutes schedule is gone from dfs_balance.tf).
#   Total about $1.50/month for the AA-832 + AA-751 alarms, plus ~$0.60/month for the 2 metrics
#   over the free tier since cis_app (rl-001) = about $2.10/month.
# -----------------------------------------------------------------------------

# ReadLatency / WriteLatency are published in SECONDS: 0.020 = 20 ms, averaged over 15 minutes.
resource "aws_cloudwatch_metric_alarm" "rds_read_latency_high" {
  alarm_name          = "${local.name_prefix}-rds-read-latency-high"
  alarm_description   = "RDS ${module.rds.db_identifier} average read latency above 20 ms for 15 minutes (storage I/O saturated; shared by CIS, TripPlanner, Booking).${local.runbook_suffix.database}"
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
  alarm_description   = "RDS ${module.rds.db_identifier} average write latency above 20 ms for 15 minutes (storage I/O saturated; shared by CIS, TripPlanner, Booking).${local.runbook_suffix.database}"
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
  alarm_description   = "RDS ${module.rds.db_identifier} average disk queue depth above 10 for 15 minutes (I/O requests waiting on gp storage).${local.runbook_suffix.database}"
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
  alarm_description   = "RDS ${module.rds.db_identifier} MaximumUsedTransactionIDs above 1,000,000,000 (wraparound guard: check autovacuum / age(datfrozenxid)).${local.runbook_suffix.database}"
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
# RoleConnectionLimitPct{Role}, published by the CIS api process every 5 minutes (AA-751:
# api/core/ops_metrics_sampler.py, an asyncio loop started in the api lifespan; it replaced the
# AA-832 chain Scheduler -> ops-probe Lambda -> admin POST -> shared.job -> worker). One sample per
# period, so one datapoint above 80 % alarms (1 of 2 periods); the 2-period window means one late
# or missing sample does not flip an ALARM back to OK. Missing data does not alarm: if the sampler
# stops (api down, IAM, CloudWatch errors), these stay OK and the "sampling stopped" alarm below
# fires. The sampler does not depend on the worker or on shared.job, so a wave that fills every
# worker slot no longer delays a sample.
resource "aws_cloudwatch_metric_alarm" "rds_role_connections_high" {
  for_each = local.rds_role_connection_limits

  alarm_name          = "${local.name_prefix}-rds-role-connections-${each.key}"
  alarm_description   = "RDS ${module.rds.db_identifier} role ${each.key} above 80% of its CONNECTION LIMIT ${each.value} (more than ${floor(each.value * 0.8)} sessions) in a 5-minute sample. New connections for this role fail at ${each.value}.${local.runbook_suffix.database}"
  namespace           = "AA/RDS"
  metric_name         = "RoleConnectionLimitPct"
  dimensions          = { Role = each.key }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = merge(local.ecosys_tags, { App = "shared" })
}

# X1 S18 (AA-860, plan XD6): a connection refused for the CIS runtime role. cis_app has CONNECTION LIMIT 90
# (rl-001); the master it replaces had none, so SQLSTATE 53300 "too many connections for role "cis_app""
# is a new failure mode. The 5-minute RoleConnectionLimitPct sample above can miss a burst between two
# samples; the api and worker log every refused connect (asyncpg TooManyConnectionsError) to the one ECS log
# group (/ecs/aa-cis-dev, streams api/ and worker/), so a log metric filter counts them. No default value:
# the metric only exists while it matches (≈ $0 custom-metric cost when quiet), and missing data is OK.
resource "aws_cloudwatch_log_metric_filter" "cis_app_too_many_connections" {
  name           = "${local.name_prefix}-cis-app-too-many-connections"
  log_group_name = module.ecs.log_group_name
  pattern        = "\"too many connections for role\" \"cis_app\""

  metric_transformation {
    name      = "CisAppTooManyConnections"
    namespace = "AA/RDS"
    value     = "1"
    unit      = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "cis_app_too_many_connections" {
  alarm_name          = "${local.name_prefix}-rds-cis-app-too-many-connections"
  alarm_description   = "CIS api/worker logged 'too many connections for role \"cis_app\"' (SQLSTATE 53300, CONNECTION LIMIT ${local.rds_role_connection_limits["cis_app"]}) in the last 5 minutes: requests or jobs failed to get a DB connection. Check pool sizes (AA-CIS-App docs/implementation-notes/AA-860-S15.md) before raising the limit (Infra roles/ file)."
  namespace           = "AA/RDS"
  metric_name         = "CisAppTooManyConnections"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = merge(local.ecosys_tags, { App = "cis" })
}

# The sampler above runs in the CIS api. The api and worker task definitions share one task role
# (modules/ecs aws_iam_role.ecs_task, aa-cis-dev-ecs-task-role), so the grant goes on that role.
# PutMetricData has no resource ARN; the namespace condition limits it to AA/RDS and AA/Jobs/CIS
# (AA-751; the module's own statement covers the older "acp" namespace). The resource and policy
# names keep their AA-832 "aa-rds" form so the change is an in-place update, not a replace.
resource "aws_iam_role_policy" "cis_ecs_task_put_metric_aa_rds" {
  name = "aa-cis-${var.environment}-ecs-put-metric-aa-rds"
  role = module.ecs.task_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PutMetricDataAaRdsAndCisJobs"
      Effect    = "Allow"
      Action    = "cloudwatch:PutMetricData"
      Resource  = "*"
      Condition = { StringEquals = { "cloudwatch:namespace" = ["AA/RDS", "AA/Jobs/CIS"] } }
    }]
  })
}

# The per-role alarms treat missing data as OK, so a stopped sampler (api down or crash-looping,
# IAM, CloudWatch errors) would leave them silently green. This alarm makes that gap visible: no
# RoleConnections sample for the always-present aa_app_user role in 3 x 15 minutes = ALARM (missing
# data = breaching). The sampler publishes every limited role in one call, so one role stands for
# all of them. It also fires while the CIS api is scaled to 0 on purpose. +$0.10/month (see the
# cost block above).
resource "aws_cloudwatch_metric_alarm" "rds_role_connections_sampling_stopped" {
  alarm_name          = "${local.name_prefix}-rds-role-connections-sampling-stopped"
  alarm_description   = "No AA/RDS RoleConnections sample for 45 minutes: the CIS api sampler (api/core/ops_metrics_sampler.py) is not publishing, so the per-role connection alarms are blind. Check the api is running and its ops_metrics_sampled log lines (and sampler errors) in /ecs/${local.name_prefix}.${local.runbook_suffix.database}"
  namespace           = "AA/RDS"
  metric_name         = "RoleConnections"
  dimensions          = { Role = "aa_app_user" }
  statistic           = "SampleCount"
  period              = 900
  evaluation_periods  = 3
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = merge(local.ecosys_tags, { App = "shared" })
}

# -----------------------------------------------------------------------------
# AA-751 (S240) — job backlog per owner (data standard C4.1, plan aa751_plan.md §5).
#
# Each owner publishes two metrics, no dimensions, every 5 minutes, from a loop that does NOT run
# through the queue it measures:
#   CIS      AA/Jobs/CIS      api process, api/core/ops_metrics_sampler.py (not the worker)
#   Booking  AA/Jobs/Booking  backend/app/jobs/metrics.py JobMetricsSampler, started next to the
#                             worker when the worker is enabled and the DB is configured
#
#   OldestQueuedAgeSeconds  age in seconds of the oldest due queued row that is STARVED, else 0.
#                           Capacity-aware (plan F13), so a normal wave or a long serial job does
#                           not page: CIS counts a row only when no live worker exists, its kind is
#                           unregistered, or a live worker could claim it right now (same claim-caps
#                           rule as the worker) and the kind is below its concurrency; Booking (a
#                           serial worker) reports 0 while a non-overdue job is running.
#   OverdueRunningJobs      running rows older than 2 x the kind's expected seconds, timed from
#                           progress.attempt_started_at (written at each claim, plan F18) or
#                           started_at (CIS registry expected_seconds, default 600; Booking
#                           app/jobs/kinds.py EXPECTED_SECONDS, default 300).
#
# Alarms per owner (SNS on ALARM and OK, see the header):
#   <prefix>-jobs-queue-age          Maximum > 900 s in 1 of 2 5-minute periods, missing = OK.
#   <prefix>-jobs-overdue-running    Maximum > 0 in 1 of 2 5-minute periods, missing = OK.
#   <prefix>-jobs-sampling-stopped   SampleCount of OldestQueuedAgeSeconds < 1 for 3 x 15 minutes,
#                                    missing = BREACHING (the documented exception, like AA-832's):
#                                    without it a dead sampler would leave the two alarms above
#                                    silently green.
# The Booking sampling-stopped alarm ALSO fires whenever Booking is scaled to 0 (its normal Dev
# state, booking.tf desired_count 0) or its worker is off (WORKER_ENABLED false): that is expected,
# not an incident. The CIS one fires while the CIS api is scaled to 0.
# Cost: in the AA-832 cost block above (6 alarms x $0.10; the 4 metrics are inside the free 10).
# IAM: CIS via cis_ecs_task_put_metric_aa_rds above (namespace AA/Jobs/CIS); Booking via
# booking_ecs_task_put_metric_jobs below (namespace AA/Jobs/Booking only).
# Rollout (split apply, docs/implementation-notes/AA-751.md): IAM first, then the CIS and Booking
# deploys, then the rest, and the two jobs_sampling_stopped alarms last, once samples exist.
# -----------------------------------------------------------------------------

locals {
  job_backlog_owners = {
    cis = {
      namespace = "AA/Jobs/CIS"
      prefix    = local.name_prefix
      app       = "cis"
      sampler   = "the CIS api sampler (api/core/ops_metrics_sampler.py)"
      log_group = "/ecs/${local.name_prefix}"
      queue     = "shared.job"
    }
    booking = {
      namespace = "AA/Jobs/Booking"
      prefix    = local.bk_name_prefix
      app       = "booking"
      sampler   = "the Booking JobMetricsSampler (backend/app/jobs/metrics.py)"
      log_group = "/ecs/${local.bk_name_prefix}"
      queue     = "booking.job"
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "jobs_queue_age" {
  for_each = local.job_backlog_owners

  alarm_name          = "${each.value.prefix}-jobs-queue-age"
  alarm_description   = "${each.value.queue}: a due queued job has been starved for more than 15 minutes (${each.value.namespace} OldestQueuedAgeSeconds, capacity-aware: no live worker, an unregistered kind, or a free slot that is not claiming it). Check the queue and the worker logs in ${each.value.log_group}.${local.runbook_suffix.queue_stuck}"
  namespace           = each.value.namespace
  metric_name         = "OldestQueuedAgeSeconds"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 900 # seconds
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = merge(local.ecosys_tags, { App = each.value.app })
}

resource "aws_cloudwatch_metric_alarm" "jobs_overdue_running" {
  for_each = local.job_backlog_owners

  alarm_name          = "${each.value.prefix}-jobs-overdue-running"
  alarm_description   = "${each.value.queue}: at least one running job has run longer than 2 x its kind's expected seconds in the current attempt (${each.value.namespace} OverdueRunningJobs). It may be stuck holding a worker slot. Check the running rows and ${each.value.log_group}.${local.runbook_suffix.queue_stuck}"
  namespace           = each.value.namespace
  metric_name         = "OverdueRunningJobs"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = merge(local.ecosys_tags, { App = each.value.app })
}

resource "aws_cloudwatch_metric_alarm" "jobs_sampling_stopped" {
  for_each = local.job_backlog_owners

  alarm_name          = "${each.value.prefix}-jobs-sampling-stopped"
  alarm_description   = "No ${each.value.namespace} OldestQueuedAgeSeconds sample for 45 minutes: ${each.value.sampler} is not publishing, so the queue-age and overdue-running alarms are blind. Expected while the service is scaled to 0${each.value.app == "booking" ? " or the Booking worker is off (WORKER_ENABLED false)" : ""}. Check ${each.value.log_group}.${local.runbook_suffix.queue_stuck}"
  namespace           = each.value.namespace
  metric_name         = "OldestQueuedAgeSeconds"
  statistic           = "SampleCount"
  period              = 900
  evaluation_periods  = 3
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = merge(local.ecosys_tags, { App = each.value.app })
}

# Booking publishes only into its own namespace (one namespace per owner, so IAM keeps each app to
# its own metrics). PutMetricData has no resource ARN. Pattern of ses.tf booking_ecs_task_ses_send.
resource "aws_iam_role_policy" "booking_ecs_task_put_metric_jobs" {
  name = "${local.bk_name_prefix}-ecs-put-metric-jobs"
  role = aws_iam_role.booking_ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PutMetricDataBookingJobs"
      Effect    = "Allow"
      Action    = "cloudwatch:PutMetricData"
      Resource  = "*"
      Condition = { StringEquals = { "cloudwatch:namespace" = "AA/Jobs/Booking" } }
    }]
  })
}
