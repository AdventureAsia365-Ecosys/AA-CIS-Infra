# =============================================================================
# AA-1171 (S287, alerts catalogue P0; tech lead decisions D5, D9, D2 of the S287 alerting decision page, root
# docs/audits/2026-11-21-S287-alerting-inventory/README.md section 8) — severity, the page topic and the coverage
# alarms the S287 inventory found missing.
#
# SEVERITY (D5): two levels, set as the tag `Severity` on every CloudWatch alarm and every EventBridge rule that
# notifies an SNS topic (tools/docs/gen_docs.py check-source fails a PR that adds one without local.alert_tags /
# var.alert_tags):
#   page    a person must act now. Rule: security, identity, the NAT instance (all private egress) and the database
#           being down (the RDS instance event rule), plus the alert path itself (failed SNS deliveries).
#   ticket  handled in working hours. Everything else: service down / no healthy task on Dev (no real users yet,
#           tech lead rule S287; re-rate to page when the first prod service goes live), error and latency rates,
#           RDS capacity early warnings (CPU, storage at 50 % of base, connections at 60 %), backups, SES rates,
#           budgets, TripPlanner Lambda and job alarms, the WAF rate alarm.
# Each alarm's block states its severity and why next to its tags. The CIS admin page Platform > Alerts > Catalogue
# reads the tag live (tag:GetResources), so a re-rating is a one-line Terraform change.
#
# PAGE TOPIC (D5): a second SNS topic for page severity, created now at 0 USD so prod only adds recipients or
# channels (a pager, a phone) and no alarm changes. Page alarms and page rules notify BOTH topics: the alerts topic
# keeps receiving everything (its recipients see every alert), the page topic only the urgent ones. Recipients of the
# page topic are managed on the same CIS admin page as the alerts topic (Platform > Alerts > Recipients, AA-913,
# extended: each recipient chooses "All alerts" or "Page alerts only"); Terraform keeps no subscription on it (D6: no
# paging tool on Dev). The CIS task role grant of alert_recipients.tf covers both topics.
#
# MUTABLE: whether a future time-boxed mute from the admin (phase P1, with AA-1141; CloudWatch alarm mute rules, IAM
# conditioned on this tag) may silence the alarm. "false" for security / identity / break-glass / KMS anomaly alarms,
# the NAT recover alarm (a mute would also stop its EC2 recover action), the alert-path watchdog and every EventBridge
# rule (rules cannot be muted). The CIS task role never gets cloudwatch:TagResource, so the app cannot flip it.
#
# COMPONENT: the existing mandatory tag (tagging standard FIN-03), set on each alarm to the component it watches (api,
# worker, web, admin, db, network, mail, auth, security, encryption, edge, jobs, observability).
#
# COST (CloudWatch pricing read 21/11/2026; this account is past the 10 free alarms): standard alarms 0.10 USD per
# alarm metric per month. New here: the SNS delivery-failure alarm 0.10, the CIS worker liveness alarm 0.10, the CIS
# API 5xx rate alarm 0.20 (metric math over 2 metrics); in modules/environment/booking_alarms.tf the Booking worker
# liveness alarm 0.10 (its log metric filter metric is inside the 10 free custom metrics; 0.30 USD/month beyond) and
# the Booking API 5xx rate alarm 0.20. Total 0.70 USD/month. The page topic, its policy, the extra event targets and
# the tags cost nothing (SNS e-mail: first 1,000 notifications/month free).
# =============================================================================

locals {
  # The tag sets of the two severities (merge them after the resource's own tags; Component follows them).
  alert_tags = {
    page          = { Severity = "page", Mutable = "true" }
    page_locked   = { Severity = "page", Mutable = "false" }
    ticket        = { Severity = "ticket", Mutable = "true" }
    ticket_locked = { Severity = "ticket", Mutable = "false" }
  }

  # alarm_actions / ok_actions per severity: page alarms notify both topics.
  alert_actions = {
    page   = [aws_sns_topic.alerts.arn, aws_sns_topic.page.arn]
    ticket = [aws_sns_topic.alerts.arn]
  }

  # The SNS targets of the page-severity EventBridge rules of this root (the module's CRM and Booking KMS rules add
  # their own page target, modules/environment/crm_data.tf and booking_supplier_bank.tf). Each gets a second target on the page topic with the same e-mail text.
  page_event_targets = merge(
    {
      identity_breakglass_secret                  = aws_cloudwatch_event_target.identity_breakglass_secret
      identity_denied_secret_read                 = aws_cloudwatch_event_target.identity_denied_secret_read
      identity_workforce_admincreateuser_password = aws_cloudwatch_event_target.identity_workforce_admincreateuser_password
      identity_partner_pool_config                = aws_cloudwatch_event_target.identity_partner_pool_config
      identity_partner_admin_bypass               = aws_cloudwatch_event_target.identity_partner_admin_bypass
      sec_access_analyzer_finding                 = aws_cloudwatch_event_target.sec_access_analyzer_finding
      rds_instance_event                          = aws_cloudwatch_event_target.rds_instance_event
    },
    { for k, t in aws_cloudwatch_event_target.sec_cloudtrail_rules : "sec_cloudtrail_rules.${k}" => t },
    { for k, t in aws_cloudwatch_event_target.sec_sso_admin_signin : "sec_sso_admin_signin.${k}" => t },
    { for i, t in aws_cloudwatch_event_target.sec_guardduty_finding : "sec_guardduty_finding.${i}" => t },
  )
}

# -----------------------------------------------------------------------------
# The page topic
# -----------------------------------------------------------------------------

resource "aws_sns_topic" "page" {
  name = "aa-ecosys-${var.environment}-page-alerts"

  tags = merge(local.shared_tags, { Issue = "AA-1171", Component = "observability" })
}

# The same publishers as the alerts topic (identity_alerts.tf data.aws_iam_policy_document.alerts_topic) except
# Budgets and Cost Anomaly Detection, which stay ticket severity and publish to the alerts topic only.
data "aws_iam_policy_document" "page_topic" {
  policy_id = "__default_policy_ID"

  # The AWS default topic policy, unchanged (CloudWatch alarms and same-account publishers).
  statement {
    sid    = "__default_statement_ID"
    effect = "Allow"
    actions = [
      "SNS:GetTopicAttributes", "SNS:SetTopicAttributes", "SNS:AddPermission",
      "SNS:RemovePermission", "SNS:DeleteTopic", "SNS:Subscribe",
      "SNS:ListSubscriptionsByTopic", "SNS:Publish",
    ]
    resources = [aws_sns_topic.page.arn]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceOwner"
      values   = [var.account_id]
    }
  }

  # The page-severity EventBridge rules: identity (aa-identity-*), CRM KMS (aa-crm-*), Booking supplier bank KMS
  # (aa-booking-*, AA-1158) and security / RDS (aa-sec-*).
  statement {
    sid       = "AllowPageEventBridgeRules"
    effect    = "Allow"
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.page.arn]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values = [
        "arn:aws:events:${var.aws_region}:${var.account_id}:rule/${local.id_prefix}-*",
        "arn:aws:events:${var.aws_region}:${var.account_id}:rule/${local.crm_name_prefix}-*",
        "arn:aws:events:${var.aws_region}:${var.account_id}:rule/${local.bk_name_prefix}-*",
        "arn:aws:events:${var.aws_region}:${var.account_id}:rule/${local.sec_prefix}-*",
      ]
    }
  }
}

resource "aws_sns_topic_policy" "page" {
  arn    = aws_sns_topic.page.arn
  policy = data.aws_iam_policy_document.page_topic.json
}

# Page-severity rules: a second target on the page topic with the same input transformer (the e-mail text) as the
# rule's alerts-topic target, so both topics carry the same message.
resource "aws_cloudwatch_event_target" "page" {
  for_each = local.page_event_targets

  rule      = each.value.rule
  target_id = "page-sns"
  arn       = aws_sns_topic.page.arn

  input_transformer {
    input_paths    = each.value.input_transformer[0].input_paths
    input_template = each.value.input_transformer[0].input_template
  }

  depends_on = [aws_sns_topic_policy.page]
}

# -----------------------------------------------------------------------------
# D9: failed deliveries of the alerts topic
# -----------------------------------------------------------------------------

variable "alerts_delivery_failed_threshold" {
  description = "AA-1171 D9: the alerts topic alarm fires when at least this many notifications failed to deliver in one 5-minute period (an address that bounces, an endpoint gone)."
  type        = number
  default     = 1

  validation {
    condition     = var.alerts_delivery_failed_threshold >= 1
    error_message = "alerts_delivery_failed_threshold must be at least 1."
  }
}

# Severity page, Mutable false: when the alerts topic cannot deliver, every other alarm may be going nowhere. The
# alarm notifies both topics (a recipient whose address still works and the page topic). The second channel of the
# alerts topic itself follows AA-1110. Event alarm: ALARM only. Cost 0.10 USD/month.
resource "aws_cloudwatch_metric_alarm" "alerts_notifications_failed" {
  alarm_name          = "aa-ecosys-${var.environment}-alerts-delivery-failed"
  alarm_description   = "The alerts SNS topic failed to deliver ${var.alerts_delivery_failed_threshold} or more notifications in 5 minutes: a recipient address bounces or is gone, so alarms may reach nobody. Check the recipients on Platform > Alerts > Recipients and the SNS delivery status.${local.runbook_suffix.incident}"
  namespace           = "AWS/SNS"
  metric_name         = "NumberOfNotificationsFailed"
  dimensions          = { TopicName = aws_sns_topic.alerts.name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = var.alerts_delivery_failed_threshold
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alert_actions.page

  tags = merge(local.shared_tags, { Issue = "AA-1171" }, local.alert_tags.page_locked, { Component = "observability" })
}

# -----------------------------------------------------------------------------
# Coverage gaps of the S287 inventory (section 2.2): CIS worker liveness and the CIS API 5xx rate. The Booking pair is
# in modules/environment/booking_alarms.tf (its log group and target group live there).
# -----------------------------------------------------------------------------

variable "cis_worker_liveness" {
  description = "AA-1171: the CIS worker liveness alarm. period_s = window of the ECS service CPUUtilization sample count, periods = windows with no sample before the alarm (no running worker task for periods x period_s)."
  type = object({
    period_s = number
    periods  = number
  })
  default = {
    period_s = 300
    periods  = 2
  }

  validation {
    condition     = contains([60, 300, 900], var.cis_worker_liveness.period_s) && var.cis_worker_liveness.periods >= 1 && var.cis_worker_liveness.periods <= 12
    error_message = "cis_worker_liveness: period_s one of 60, 300, 900; periods 1-12."
  }
}

variable "booking_worker_liveness" {
  description = "AA-1171: the Booking job worker liveness alarm (modules/environment/booking_alarms.tf). period_s = window of the count of job checks sampler log lines (one per 5 minutes), periods = consecutive windows with none before the alarm."
  type = object({
    period_s = number
    periods  = number
  })
  default = {
    period_s = 300
    periods  = 3
  }

  validation {
    condition     = contains([300, 600, 900], var.booking_worker_liveness.period_s) && var.booking_worker_liveness.periods >= 2 && var.booking_worker_liveness.periods <= 12
    error_message = "booking_worker_liveness: period_s one of 300, 600, 900 (the sampler logs every 300 s); periods 2-12."
  }
}

variable "api_5xx_rate" {
  description = "AA-1171: the CIS and Booking API 5xx rate alarms (the shape of the AA-Partner SLO alarm, modules/environment/crm_slo.tf). five_xx_percent = 5xx share of the requests reaching the target group in a 5-minute window, min_requests = smallest window judged (below it the rate is 0), alarm_periods / alarm_breaching = windows evaluated / breaching to alarm."
  type = object({
    five_xx_percent = number
    min_requests    = number
    alarm_periods   = number
    alarm_breaching = number
  })
  default = {
    five_xx_percent = 5
    min_requests    = 20
    alarm_periods   = 3
    alarm_breaching = 2
  }

  validation {
    condition     = var.api_5xx_rate.five_xx_percent > 0 && var.api_5xx_rate.five_xx_percent <= 100 && var.api_5xx_rate.min_requests >= 1 && var.api_5xx_rate.alarm_breaching >= 1 && var.api_5xx_rate.alarm_breaching <= var.api_5xx_rate.alarm_periods
    error_message = "api_5xx_rate: five_xx_percent in (0, 100], min_requests >= 1, 1 <= alarm_breaching <= alarm_periods."
  }
}

# CIS worker (ECS service aa-cis-<env>-worker, no load balancer, so no target group health): ECS publishes the
# service's CPUUtilization every minute while at least one task runs, free and without Container Insights. No sample
# in two 5-minute windows = no running worker task for 10 minutes (crashed, failing to start, or scaled to 0).
# Missing data breaches on purpose: a dead service publishes nothing. A desired count of 0 on purpose alarms too
# (expected; say so in the deploy note). A hung loop inside a running task is the CIS in-app check jobs_starved (api
# ops sampler), not this alarm. Severity ticket (Dev rule above). State alarm: ALARM and OK. Cost 0.10 USD/month.
resource "aws_cloudwatch_metric_alarm" "cis_worker_no_running_task" {
  alarm_name          = "${local.name_prefix}-worker-no-running-task"
  alarm_description   = "AA-CIS worker service has had no running task for ${var.cis_worker_liveness.periods * var.cis_worker_liveness.period_s / 60} minutes (no ECS CPUUtilization sample): no job of the CIS job runner (shared.job) is claimed. Check the service events and the worker logs.${local.runbook_suffix.queue_stuck}"
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  dimensions          = { ClusterName = module.ecs.cluster_name, ServiceName = module.ecs.worker_service_name }
  statistic           = "SampleCount"
  period              = var.cis_worker_liveness.period_s
  evaluation_periods  = var.cis_worker_liveness.periods
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_actions       = local.alert_actions.ticket
  ok_actions          = local.alert_actions.ticket

  tags = merge(local.ecosys_tags, { App = "cis", Issue = "AA-1171" }, local.alert_tags.ticket, { Component = "worker" })
}

# CIS API 5xx rate (the S263 diet removed the API Gateway 5XXError alarm; only the AA-Partner API had a rate alarm).
# ALB target group metrics of the api target group: HTTPCode_Target_5XX_Count / RequestCount, judged only in windows
# with at least min_requests requests. Severity ticket. State alarm: ALARM and OK. Cost 0.20 USD/month (2 metrics).
resource "aws_cloudwatch_metric_alarm" "cis_api_5xx_rate" {
  alarm_name          = "${local.name_prefix}-api-5xx-rate"
  alarm_description   = "AA-CIS api: more than ${var.api_5xx_rate.five_xx_percent} % of requests answered 5xx in ${var.api_5xx_rate.alarm_breaching} of ${var.api_5xx_rate.alarm_periods} five-minute windows (windows under ${var.api_5xx_rate.min_requests} requests are not judged). Check Sentry and the api logs.${local.runbook_suffix.api_5xx}"
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.api_5xx_rate.five_xx_percent
  evaluation_periods  = var.api_5xx_rate.alarm_periods
  datapoints_to_alarm = var.api_5xx_rate.alarm_breaching
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alert_actions.ticket
  ok_actions          = local.alert_actions.ticket

  metric_query {
    id          = "rate"
    expression  = "IF(requests >= ${var.api_5xx_rate.min_requests}, 100 * errors / requests, 0)"
    label       = "5xx percent"
    return_data = true
  }

  metric_query {
    id = "errors"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      dimensions  = { TargetGroup = module.alb.target_group_arn_suffix, LoadBalancer = module.alb.alb_arn_suffix }
      stat        = "Sum"
      period      = 300
    }
  }

  metric_query {
    id = "requests"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      dimensions  = { TargetGroup = module.alb.target_group_arn_suffix, LoadBalancer = module.alb.alb_arn_suffix }
      stat        = "Sum"
      period      = 300
    }
  }

  tags = merge(local.ecosys_tags, { App = "cis", Issue = "AA-1171" }, local.alert_tags.ticket, { Component = "api" })
}
