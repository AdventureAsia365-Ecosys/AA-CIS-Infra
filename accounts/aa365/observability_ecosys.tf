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
#   2. Alarms -> the existing SNS topic aws_sns_topic.alerts (aa-cis-dev-acp-alerts), e-mailed to the topic's
#      recipients (bootstrap + CIS admin page, AA-913).
#      AA-832 completes the RDS rows of data standard C4.1 (latency, disk queue, XID wraparound,
#      per-role connections); AA-751 added the job backlog alarms per owner. S263 (AA-1025) moved the
#      custom-metric ones into the apps (in-app checks, end of file) and removed the rest of the noise.
#
# NOTIFICATIONS (S263 alert diet, AA-1025, reversing S241 D-20 for event alarms): STATE alarms (a service has no
# healthy target, RDS health, NAT recover, SES rates, backup copy age, TripPlanner jobs not run) e-mail on ALARM and
# on OK; EVENT alarms (Lambda errors / throttles, the break-glass token, the KMS decrypt anomaly) e-mail on ALARM only,
# one e-mail per incident. A new alarm states which kind it is; the list of what stays in CloudWatch and why is root
# docs/audits/2026-11-01-S263-alerting-cost/diet.md. A flapping alarm: fix the threshold/evaluation (AA-833).
# The per-role connection limits that used to be listed here are read live by the CIS check (pg_roles); the
# limits themselves live in the AA-CIS-Infra roles/ files and data standard C2.2.
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

# S263 (AA-1025): /aws/apigateway/welcome is created by API Gateway itself (account-level setup event, 0 bytes on
# 01/11/2026) and was the one log group in the account with no retention. Adopted with an import block (like the S235
# groups above); delete the import block once the apply has run (it is then a no-op).
import {
  to = aws_cloudwatch_log_group.apigw_welcome
  id = "/aws/apigateway/welcome"
}

resource "aws_cloudwatch_log_group" "apigw_welcome" {
  name              = "/aws/apigateway/welcome"
  retention_in_days = 30

  tags = merge(local.ecosys_tags, { App = "shared" })
}

# -----------------------------------------------------------------------------
# 2. Alarms
# -----------------------------------------------------------------------------

# AA-1022 (S261 architecture review item d): EC2 recover action on the NAT instance. A failed SYSTEM status check
# means the host hardware or AWS network under the instance failed; "recover" moves the instance to healthy hardware
# and keeps its instance id, private IP, Elastic IP and network interface, so the private route table (default route
# to that interface) works again without any Terraform change. An INSTANCE status check failure (the guest OS) is
# not something recover fixes: nat_instance_check_failed below e-mails for it (S263, AA-1025: that alarm reads
# StatusCheckFailed_Instance instead of the combined StatusCheckFailed, so a system failure mails once, here).
# AWS's recommended shape for recover alarms: Minimum over 60 s (a whole minute failed), 2 periods. t4g instances
# also get AWS "simplified automatic recovery" by default; this alarm makes the action explicit and e-mails when it
# fires. Recover needs the service-linked role AWSServiceRoleForCloudWatchEvents, which PutMetricAlarm creates on
# first use (iam:CreateServiceLinkedRole for that service is in CloudWatchFullAccess, cicd.tf).
# Cost: one standard-resolution alarm, 0.10 USD/month (this account is past the 10-alarm CloudWatch free tier).
resource "aws_cloudwatch_metric_alarm" "nat_system_check_recover" {
  alarm_name          = "aa-ecosys-${var.environment}-nat-system-check-recover"
  alarm_description   = "NAT instance ${module.vpc.nat_instance_id} failed the EC2 SYSTEM status check for 2 minutes: CloudWatch recovers it onto healthy hardware (same instance id, IPs and network interface). Check egress after the OK e-mail.${local.runbook_suffix.incident}"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  dimensions          = { InstanceId = module.vpc.nat_instance_id }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = ["arn:aws:automate:${var.aws_region}:ec2:recover", aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = merge(local.ecosys_tags, { App = "shared" })
}

# NAT guest OS failure (hung kernel, broken iptables / forwarding): recover does not fix it and nothing else sees it.
# The ALB health checks stay inside the VPC, so no-healthy-task never fires; the VPC has only the S3 gateway endpoint,
# so the apps' in-app checks (sns:Publish), Sentry and every LLM call need this NAT and go silent with it. This alarm
# is evaluated and delivered by CloudWatch/SNS outside the VPC. StatusCheckFailed_Instance only (S263 review, AA-1025;
# the pre-S263 alarm read the combined StatusCheckFailed and doubled the recover alarm's e-mails on a system failure).
# A state alarm: e-mails on ALARM and OK. Missing data (instance stopped on purpose) does not alarm. 0.10 USD/month.
resource "aws_cloudwatch_metric_alarm" "nat_instance_check_failed" {
  alarm_name          = "aa-ecosys-${var.environment}-nat-instance-check-failed"
  alarm_description   = "NAT instance ${module.vpc.nat_instance_id} failed the EC2 INSTANCE status check (guest OS) for 3 minutes. All private-subnet egress (LLM calls, SNS from the in-app checks, Sentry, vendor APIs) goes through it; recover does not fix this: reboot the instance.${local.runbook_suffix.incident}"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_Instance"
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
  alarm_description   = "AA-Booking target group ${module.environment.booking_target_group_name} has no healthy target for 5 minutes (service down or failing /booking/health).${local.runbook_suffix.api_5xx}"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  dimensions          = { TargetGroup = module.environment.booking_target_group_arn_suffix, LoadBalancer = module.alb.alb_arn_suffix }
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

# S263 (AA-1025): the CIS api had no service-down alarm. aa-cis-dev-ecs-running-tasks-low read
# ECS/ContainerInsights RunningTaskCount, which does not exist while Container Insights is off (it stayed OK for 112
# days with or without tasks). Same shape as Booking's: no healthy target behind the ALB for 5 minutes. Missing data
# does not alarm (desired 0 on purpose stays quiet once the target group stops publishing).
resource "aws_cloudwatch_metric_alarm" "cis_api_no_healthy_task" {
  alarm_name          = "${local.name_prefix}-api-no-healthy-task"
  alarm_description   = "AA-CIS api target group has no healthy target for 5 minutes (service down or failing its health check). The CIS in-app checks (job queue, connections) run in this process, so they are silent too.${local.runbook_suffix.api_5xx}"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  dimensions          = { TargetGroup = module.alb.target_group_arn_suffix, LoadBalancer = module.alb.alb_arn_suffix }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 5
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = merge(local.ecosys_tags, { App = "cis" })
}

# TripPlanner Lambdas — errors (3+ in 5 minutes) and sustained throttling on browse (see below). Event alarms: no OK
# e-mail since S263 (AA-1025), one e-mail per incident.
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

  tags = merge(local.ecosys_tags, { App = "tripplanner" })
}

# AA-833: was "Sum > 0 in one 5-minute period". A single burst (a page prefetch fan-out after a deploy or ISR expiry)
# flipped browse OK -> ALARM -> OK 7 times in two days. It now pages only on sustained throttling: more than 5
# throttles in at least 2 of 3 consecutive 5-minute periods. S263 (AA-1025): browse only (it fired 8 times in the 30
# days before the diet, a real signal); assembly never fired and its errors alarm stays. No OK e-mail.
resource "aws_cloudwatch_metric_alarm" "tripplanner_lambda_throttles" {
  alarm_name          = "${local.tp_functions.browse}-throttles"
  alarm_description   = "TripPlanner Lambda ${local.tp_functions.browse}: more than 5 throttles (account or reserved concurrency limit) in at least 2 of 3 consecutive 5-minute periods. No OK notification.${local.runbook_suffix.api_5xx}"
  namespace           = "AWS/Lambda"
  metric_name         = "Throttles"
  dimensions          = { FunctionName = local.tp_functions.browse }
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
# 60 % of max_connections for 5 minutes = floor(0.6 * 181) = 108. The CIS in-app check rds_role_connections
# (S263) catches a single app exhausting its own CONNECTION LIMIT long before the instance total gets here.
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

# RDS down, stopped, failed or out of storage (S263 alert diet review, AA-1025). The removed "sampling stopped"
# heartbeats treated missing data as breaching, so a database the samplers could not read used to e-mail. Nothing
# kept does: the RDS alarms above treat missing data as not breaching (and connections fall to 0), the ALB health
# checks (/health, /booking/health) do not touch the database, and every in-app check needs the database before it
# publishes. RDS sends its instance events to the default EventBridge bus for free (no event subscription needed):
#   availability  shutdown / restart (RDS-EVENT-0004, 0006, 0022)     failure  the instance failed (0031, 0034, ...)
#   low storage   storage full or nearly (0007, 0089, 0221, 0222)     recovery recovery started / finished
#   RDS-EVENT-0087 / 0088 / 0154  stopped / started / started again after 7 days stopped (category notification,
#                                 the rest of which is maintenance noise, so only these three ids)
# Prefix aa-sec-<env>-: the topic policy statement AllowSecurityEventBridgeRules (identity_alerts.tf) and the apply
# role's SecEventRuleManage (cicd_sec.tf) already cover rule/aa-sec-*, so CI applies it with no new grant and no MFA
# bootstrap. An event rule mails once per event (no OK mail). Not covered: a database AWS reports healthy that the
# apps cannot log in to (password or role change); their requests fail, which reaches Sentry. Cost: $0/month.
resource "aws_cloudwatch_event_rule" "rds_instance_event" {
  name        = "${local.sec_prefix}-rds-instance-event"
  description = "RDS ${module.rds.db_identifier} shut down, restarted, stopped, failed, recovering or low on storage (RDS event). S263 alert diet, AA-1025.${local.runbook_suffix.database}"
  event_pattern = jsonencode({
    source        = ["aws.rds"]
    "detail-type" = ["RDS DB Instance Event"]
    detail = {
      SourceIdentifier = [module.rds.db_identifier]
      "$or" = [
        { EventCategories = ["availability", "failure", "low storage", "recovery"] },
        { EventID = ["RDS-EVENT-0087", "RDS-EVENT-0088", "RDS-EVENT-0154"] },
      ]
    }
  })
  tags = merge(local.ecosys_tags, { App = "shared", Issue = "AA-1025" })
}

resource "aws_cloudwatch_event_target" "rds_instance_event" {
  rule      = aws_cloudwatch_event_rule.rds_instance_event.name
  target_id = "alerts-sns"
  arn       = aws_sns_topic.alerts.arn

  input_transformer {
    input_paths = {
      id    = "$.detail.SourceIdentifier"
      event = "$.detail.EventID"
      msg   = "$.detail.Message"
      time  = "$.time"
    }
    input_template = "\"[aa-rds] <id>: <event> at <time>: <msg>. The database is shared by CIS, TripPlanner, Booking and AA-Partner; while it is down every in-app check is silent too. A stop on Dev is either by hand or AWS restarting it after 7 days stopped.${local.runbook_suffix.database}\""
  }
}

# -----------------------------------------------------------------------------
# S263 alert diet (AA-1025, root docs/audits/2026-11-01-S263-alerting-cost/diet.md): what left CloudWatch.
#
# Removed here: RDS FreeableMemory, CPUSurplusCreditsCharged, Read/WriteLatency, DiskQueueDepth (never fired; C4.3
# weekly review), the NAT combined StatusCheckFailed alarm (now Instance-only, above), the Booking unhealthy-hosts / CPU / API 5XX and
# the CIS API 5XX / latency alarms (an outage is the no-healthy-task alarm of each service, an app error is a Sentry
# event), the assembly throttles alarm, and the AA-832 / AA-751 custom-metric alarms below, which became IN-APP checks
# that read the same database state and mail the same alerts topic (sns:Publish, granted below and in
# alert_recipients.tf):
#   per-role CONNECTION LIMIT > 80 %, XID age > 1e9, cis_app "too many connections"   CIS api ops sampler
#   job queue starved > 15 min / running past 2 x expected                            CIS, Booking, AA-Partner samplers
#   CRM audit export lag / partitions / verify lag, bulk reveal                       AA-Partner sampler
# The "sampling stopped" heartbeats are gone with them: each check runs in its app's API process, and the API being
# down is that service's no-healthy-task alarm. No custom metric is published for any of them any more (the
# PutMetricData grants for AA/RDS, AA/Jobs/CIS, AA/Jobs/Booking, AA/Jobs/Crm and acp are removed).
# local.rds_max_connections stays: rds-connections-high above is derived from it (C4.1b).
# -----------------------------------------------------------------------------

# Booking task role: publish the in-app check alerts (AA-Booking app/jobs/ops_checks.py) to the alerts topic, the
# topic the removed job alarms used, so the recipients are the same (bootstrap + Platform > Alert recipients). The
# topic's default statement admits this account's principals; this grant is the IAM side. ALERTS_TOPIC_ARN reaches
# the task through booking.tf.
resource "aws_iam_role_policy" "booking_ecs_task_publish_alerts" {
  name = "${local.bk_name_prefix}-ecs-publish-alerts"
  role = module.environment.booking_ecs_task_role_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "PublishOpsCheckAlerts"
      Effect   = "Allow"
      Action   = "sns:Publish"
      Resource = aws_sns_topic.alerts.arn
    }]
  })
}

# S263: the throttles alarm kept only its browse instance; keep that alarm (no destroy / create).
moved {
  from = aws_cloudwatch_metric_alarm.tripplanner_lambda_throttles["browse"]
  to   = aws_cloudwatch_metric_alarm.tripplanner_lambda_throttles
}
