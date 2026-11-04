# =============================================================================
# AA-969 (CRM-37a): the AA-Partner SLO alarms and saved Logs Insights queries.
#
# The SLOs are written in AA-Partner docs/operations/slo.md. Only what AWS already measures for free becomes a
# CloudWatch alarm here: the CRM API target group's RequestCount, HTTPCode_Target_5XX_Count and TargetResponseTime
# (ALB metrics, no custom metric, no metric filter). Per-route-group latency and the crm.job lag are read from the
# logs the API already writes (request_completed, ops_metrics_sampled) with the saved queries below, which cost
# nothing until someone runs one (Logs Insights bills per GB scanned). The crm.job lag alarm itself stays the in-app
# check jobs_stuck (AA-Partner app/observability/ops_alerts.py, > 900 s), per the S263 alert diet (no custom
# metrics, observability_ecosys.tf).
#
# Cost: three alarm metrics (5xx rate = 2 metrics in one metric-math alarm, p95 latency = 1) at the standard
# resolution price, 0.10 USD per alarm metric per month = 0.30 USD per month while crm_edge_on = 1. No new log data,
# no custom metric, no dashboard. Missing data never alarms (desired 0 is the normal Dev state).
# =============================================================================

locals {
  # The SLO thresholds of AA-Partner docs/operations/slo.md (keep both in step).
  crm_slo_5xx_percent     = 2   # 5-minute window, at least crm_slo_min_requests requests
  crm_slo_min_requests    = 20  # below this a window is too small to judge (a single 500 would be 5 %)
  crm_slo_p95_latency_s   = 1.5 # target group p95 over 5 minutes, all routes
  crm_slo_alarm_periods   = 3   # three 5-minute windows ...
  crm_slo_alarm_breaching = 2   # ... of which two breach (a single slow deploy window stays quiet)
}

resource "aws_cloudwatch_metric_alarm" "crm_api_5xx_rate" {
  count = var.crm_edge_on

  alarm_name          = "${local.crm_name_prefix}-api-5xx-rate"
  alarm_description   = "AA-Partner API: more than ${local.crm_slo_5xx_percent} % of requests answered 5xx in 2 of 3 five-minute windows (error-rate SLO, AA-969).${var.runbook_suffix.api_5xx}"
  comparison_operator = "GreaterThanThreshold"
  threshold           = local.crm_slo_5xx_percent
  evaluation_periods  = local.crm_slo_alarm_periods
  datapoints_to_alarm = local.crm_slo_alarm_breaching
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alerts_topic_arn]
  ok_actions          = [var.alerts_topic_arn]

  metric_query {
    id          = "rate"
    expression  = "IF(requests >= ${local.crm_slo_min_requests}, 100 * errors / requests, 0)"
    label       = "5xx percent"
    return_data = true
  }

  metric_query {
    id = "errors"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      dimensions  = { TargetGroup = aws_lb_target_group.crm_api.arn_suffix, LoadBalancer = var.alb_arn_suffix }
      stat        = "Sum"
      period      = 300
    }
  }

  metric_query {
    id = "requests"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      dimensions  = { TargetGroup = aws_lb_target_group.crm_api.arn_suffix, LoadBalancer = var.alb_arn_suffix }
      stat        = "Sum"
      period      = 300
    }
  }

  tags = merge(var.ecosys_tags, { App = "crm", Issue = "AA-969" })
}

resource "aws_cloudwatch_metric_alarm" "crm_api_p95_latency" {
  count = var.crm_edge_on

  alarm_name          = "${local.crm_name_prefix}-api-p95-latency"
  alarm_description   = "AA-Partner API: target group p95 response time above ${local.crm_slo_p95_latency_s} s in 2 of 3 five-minute windows (latency SLO, AA-969).${var.runbook_suffix.incident}"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  dimensions          = { TargetGroup = aws_lb_target_group.crm_api.arn_suffix, LoadBalancer = var.alb_arn_suffix }
  extended_statistic  = "p95"
  period              = 300
  evaluation_periods  = local.crm_slo_alarm_periods
  datapoints_to_alarm = local.crm_slo_alarm_breaching
  comparison_operator = "GreaterThanThreshold"
  threshold           = local.crm_slo_p95_latency_s
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alerts_topic_arn]
  ok_actions          = [var.alerts_topic_arn]

  tags = merge(var.ecosys_tags, { App = "crm", Issue = "AA-969" })
}

# -----------------------------------------------------------------------------
# Saved Logs Insights queries (free to keep; a run bills the GB it scans). Route groups as in AA-Partner
# docs/operations/slo.md; `route` is the template (no ids, no query string), written by request_completed.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_query_definition" "crm_slo_latency_by_group" {
  name            = "${local.crm_name_prefix}/slo/p95-by-route-group"
  log_group_names = [aws_cloudwatch_log_group.crm_api.name]

  query_string = <<-EOT
    fields route, method, duration_ms
    | filter event = "request_completed" and ispresent(route)
    | parse route /^\/crm\/(?<route_class>v1|public\/v1|ops\/v1|staff\/v1)\/(?<area>[a-z0-9-]+)/
    | stats count(*) as requests, pct(duration_ms, 95) as p95_ms, pct(duration_ms, 99) as p99_ms
            by route_class, area, method
    | sort requests desc
  EOT
}

resource "aws_cloudwatch_query_definition" "crm_slo_status_classes" {
  name            = "${local.crm_name_prefix}/slo/status-classes"
  log_group_names = [aws_cloudwatch_log_group.crm_api.name]

  query_string = <<-EOT
    fields floor(status / 100) as status_class
    | filter event = "request_completed"
    | stats count(*) as requests by status_class, bin(5m)
    | sort @timestamp desc
  EOT
}

resource "aws_cloudwatch_query_definition" "crm_slo_job_lag" {
  name            = "${local.crm_name_prefix}/slo/crm-job-lag"
  log_group_names = [aws_cloudwatch_log_group.crm_api.name]

  query_string = <<-EOT
    fields @timestamp, event
    | filter event like /^ops_metrics_sampled /
    | parse event /oldest_queued_age_s=(?<lag_s>[0-9.]+)/
    | parse event /overdue_running_jobs=(?<overdue>[0-9]+)/
    | stats max(lag_s) as max_lag_s, pct(lag_s, 99) as p99_lag_s, max(overdue) as max_overdue by bin(1h)
    | sort @timestamp desc
  EOT
}

resource "aws_cloudwatch_query_definition" "crm_slo_fair_share_refusals" {
  name            = "${local.crm_name_prefix}/slo/fair-share-refusals"
  log_group_names = [aws_cloudwatch_log_group.crm_api.name]

  query_string = <<-EOT
    fields @timestamp, route, status
    | filter event = "request_completed" and (status = 429 or status = 503 or status = 413)
    | stats count(*) as refusals by route, status, bin(15m)
    | sort @timestamp desc
  EOT
}
