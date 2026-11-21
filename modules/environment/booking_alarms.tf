# =============================================================================
# AA-1171 (S287 alerting inventory, section 2.2): the two AA-Booking coverage alarms. Severity and cost rules:
# accounts/aa365/alert_severity.tf (header). Thresholds: var.booking_worker_liveness and var.api_5xx_rate (declared
# in accounts/aa365, passed through crm_inputs.tf).
# =============================================================================

# Booking job worker liveness. The Booking worker has no ECS service of its own: it runs in the API task
# (WORKER_ENABLED), so the task's health is booking_no_healthy_task (accounts/aa365 observability_ecosys.tf). What no
# alarm saw is the worker side switched off or dead while the API still answers. The API lifespan starts the job
# checks sampler (AA-Booking backend/app/jobs/metrics.py) together with the worker; it logs one ops_metrics_sampled
# line every 5 minutes and runs the in-app check jobs_stuck, which catches a hung worker loop. This metric filter
# counts those lines; no line in `periods` consecutive windows = the worker and its checks are off or dead.
# Missing data breaches on purpose (a dead sampler writes nothing). The metric is a log metric filter metric, not an
# app PutMetricData (the S263 diet removed those grants): one custom metric, inside the account's 10 free custom
# metrics (0.30 USD/month beyond). Alarm 0.10 USD/month. Severity ticket. State alarm: ALARM and OK.
resource "aws_cloudwatch_log_metric_filter" "booking_job_checks_sampled" {
  name           = "${local.bk_name_prefix}-job-checks-sampled"
  log_group_name = aws_cloudwatch_log_group.booking.name
  pattern        = "\"ops_metrics_sampled\""

  metric_transformation {
    name      = "JobChecksSampled"
    namespace = "AA/Booking"
    value     = "1"
    unit      = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "booking_worker_silent" {
  alarm_name          = "${local.bk_name_prefix}-worker-silent"
  alarm_description   = "AA-Booking job worker: no job checks sample logged for ${var.booking_worker_liveness.periods * var.booking_worker_liveness.period_s / 60} minutes. The worker and its sampler start together (WORKER_ENABLED); the API may still answer. Check the Booking service log and the booking.job rows.${var.runbook_suffix.queue_stuck}"
  namespace           = "AA/Booking"
  metric_name         = aws_cloudwatch_log_metric_filter.booking_job_checks_sampled.metric_transformation[0].name
  statistic           = "Sum"
  period              = var.booking_worker_liveness.period_s
  evaluation_periods  = var.booking_worker_liveness.periods
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_actions       = local.alert_actions.ticket
  ok_actions          = local.alert_actions.ticket

  tags = merge(local.bk_tags, { Issue = "AA-1171" }, var.alert_tags.ticket, { Component = "worker" }) # AA-1171: ticket, worker down on Dev (no real users yet)
}

# Booking API 5xx rate (the S263 diet removed the Booking API Gateway 5XX alarm; an app error reached only Sentry). The
# shape of the AA-Partner SLO alarm (crm_slo.tf): ALB target group metrics, windows under min_requests not judged.
# Severity ticket. State alarm: ALARM and OK. Cost 0.20 USD/month (2 metrics).
resource "aws_cloudwatch_metric_alarm" "booking_api_5xx_rate" {
  alarm_name          = "${local.bk_name_prefix}-api-5xx-rate"
  alarm_description   = "AA-Booking API: more than ${var.api_5xx_rate.five_xx_percent} % of requests answered 5xx in ${var.api_5xx_rate.alarm_breaching} of ${var.api_5xx_rate.alarm_periods} five-minute windows (windows under ${var.api_5xx_rate.min_requests} requests are not judged). Check Sentry and the Booking log.${var.runbook_suffix.api_5xx}"
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
      dimensions  = { TargetGroup = aws_lb_target_group.booking.arn_suffix, LoadBalancer = var.alb_arn_suffix }
      stat        = "Sum"
      period      = 300
    }
  }

  metric_query {
    id = "requests"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      dimensions  = { TargetGroup = aws_lb_target_group.booking.arn_suffix, LoadBalancer = var.alb_arn_suffix }
      stat        = "Sum"
      period      = 300
    }
  }

  tags = merge(local.bk_tags, { Issue = "AA-1171" }, var.alert_tags.ticket, { Component = "api" }) # AA-1171: ticket, error rate on Dev
}
