# =============================================================================
# AA-1096 L6 (S279 thresholds audit, section 4) — the edge, budget and alarm values that stay in Terraform, published
# read-only.
#
# The audit keeps these in Terraform on purpose: WAF rules and API Gateway throttles are AWS edge resources the app
# roles may never write (no wafv2:UpdateWebACL, no apigateway write), Lambda reserved concurrency is the RDS
# connection budget, AWS Budgets and alarms are monitoring defined with what they watch. The admin-editable layer sits
# above them (each app's settings registry, the CIS spend budgets). This output lets an administrator read the
# Terraform layer without the console: tools/docs/gen_docs.py renders it as the section "Edge, budget and alarm
# limits" of the generated alarms page (root docs/generated/alarms.md, OPS-07), which Docs sync publishes to the CIS
# admin docs reader (/admin/docs, staff tier).
#
# Rules: values only (numbers, country codes, booleans, budget names); never an ID, ARN, host name or secret (the
# root repo and the docs reader are read by more people than the state). Values are read from the same variables and
# resources the edge uses, so the output cannot drift from what is applied. Output only: no resource, no cost.
# Other accounts (acc1, acc3, management) have their own roots and budgets; they are not in this output.
# =============================================================================

locals {
  # One budget's alert lines as "ACTUAL > 80 %", sorted (the notification blocks are a set).
  platform_limits_budget_alerts = sort([
    for n in aws_budgets_budget.total_monthly.notification : "${n.notification_type} > ${n.threshold} %"
  ])
}

output "platform_limits" {
  description = "AA-1096 L6: edge, budget and alarm values of accounts/aa365 (acc2), read-only. Rates are requests per second (API Gateway) or per 5 minutes per client IP (WAF); money in USD per month."
  value = {
    waf = {
      alb_acl_rate_limit_per_5min_per_ip         = var.waf_rate_limit
      staff_web_rate_limit_per_5min_per_ip       = var.staff_web_rate_limit
      tripplanner_web_rate_limit_per_5min        = var.tripplanner_web_rate_limit
      tripplanner_web_model_rate_limit_per_5min  = var.tripplanner_web_model_rate_limit
      tripplanner_web_challenge_immunity_s       = var.tripplanner_web_challenge_immunity_s
      geo_allowed_countries                      = module.waf.geo_allowed_countries
      common_rules_count_only                    = var.waf_common_rules_count_only
      protects_rest_api_stages                   = var.waf_protect_rest_api_stages
      identity_pools_acl_enabled                 = var.identity_waf_enabled
      identity_signup_rate_limit_per_5min_per_ip = var.identity_waf_signup_rate_limit
      identity_global_rate_limit_per_5min_per_ip = var.identity_waf_global_rate_limit
    }
    api_gateway_throttles = {
      cis_stage_rps             = var.cis_api_stage_throttle_rate_limit
      cis_stage_burst           = var.cis_api_stage_throttle_burst_limit
      cis_login_rps             = var.cis_api_login_throttle_rate_limit
      cis_login_burst           = var.cis_api_login_throttle_burst_limit
      cis_content_rps           = var.cis_api_content_throttle_rate_limit
      cis_content_burst         = var.cis_api_content_throttle_burst_limit
      booking_stage_rps         = var.booking_throttle_rate_limit
      booking_stage_burst       = var.booking_throttle_burst_limit
      tripplanner_default_rps   = var.tripplanner_throttle_rate_limit
      tripplanner_default_burst = var.tripplanner_throttle_burst_limit
      tripplanner_narrate_rps   = var.tripplanner_narrate_throttle_rate_limit
      tripplanner_narrate_burst = var.tripplanner_narrate_throttle_burst_limit
      tripplanner_search_rps    = var.tripplanner_search_throttle_rate_limit
      tripplanner_search_burst  = var.tripplanner_search_throttle_burst_limit
    }
    lambda_reserved_concurrency = {
      tripplanner_browse   = var.tripplanner_browse_reserved_concurrency
      tripplanner_assembly = var.tripplanner_lambda_reserved_concurrency
      tripplanner_jobs     = var.tripplanner_jobs_reserved_concurrency
    }
    budgets = {
      acc2_total_monthly_usd      = var.total_monthly_budget_usd
      acc2_total_alerts           = local.platform_limits_budget_alerts
      acc2_per_app_monthly_usd    = var.per_app_monthly_budgets
      acc2_cost_anomaly_alert_usd = var.cost_anomaly_alert_usd
    }
    alarms = {
      rds_cpu_percent_above           = aws_cloudwatch_metric_alarm.rds_cpu_high.threshold
      rds_connections_above           = aws_cloudwatch_metric_alarm.rds_connections_high.threshold
      rds_free_storage_bytes_below    = aws_cloudwatch_metric_alarm.rds_free_storage_low.threshold
      crm_slo_5xx_percent             = var.crm_slo.five_xx_percent
      crm_slo_min_requests_per_window = var.crm_slo.min_requests
      crm_slo_p95_latency_s           = var.crm_slo.p95_latency_s
      crm_slo_breaching_of_periods    = "${var.crm_slo.alarm_breaching} of ${var.crm_slo.alarm_periods}"
    }
  }
}
