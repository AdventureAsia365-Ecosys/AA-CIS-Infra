# -----------------------------------------------------------------------------
# AA-874 — tenant-pool (RLS) alarms on the CIS api logs.
#
# Tenant routes read a per-route flag from Redis and FAIL CLOSED (S241 D-12, AA-CIS-App
# api/core/aa544_tenant_pool.py): a failed or odd read keeps the route on the tenant pool (RLS), and only an
# explicit "false" moves it to the admin pool (BYPASSRLS). These alarms make each of those states visible:
#
#   tenant_flag_read_failed      "aa817_tenant_flag_read_failed"  ERROR: Redis error / timeout / no client
#   tenant_flag_unrecognized     "aa817_tenant_flag_unrecognized" ERROR: a flag value that is neither ON nor
#                                OFF (most likely a hand-typed rollback that did not take)
#   tenant_pool_unavailable      "aa817_tenant_pool_unavailable"  ERROR: no tenant connection (the route
#                                answers 503 when fail_closed)
#   tenant_guc_not_applied       "aa817_tenant_guc_not_applied"   ERROR: app.tenant_id did not take on the
#                                tenant connection (503); the most direct RLS-context failure
#   tenant_route_admin_pool      JSON { $.used_tenant_pool IS FALSE }: a tenant route ran on the admin pool.
#                                Every line with used_tenant_pool comes from a route behind a tenant-pool
#                                flag, so this fires only on a rollback (deliberate or not). CloudWatch
#                                e-mails only on a state change, so a route rolled back on purpose would hold
#                                the alarm in ALARM and hide a second, unintended rollback: deliberate
#                                rollbacks are listed in local.tenant_pool_known_rollback_events instead.
#
# The api logs JSON lines (AA-CIS-App shared/log_config.py), so the event names match as quoted terms and
# the boolean needs a JSON pattern. api and worker both log to /ecs/<prefix> (modules/ecs). Same shape as
# log_write_failed (observability.tf): Sum > 0 over 5 min, missing data = OK, e-mail on ALARM and on OK.
# Renaming any of these events in the app silently disables its alarm: keep the names in sync.
# Cost: 5 alarms x $0.10 = $0.50/month; the custom metrics exist only while lines match.
# -----------------------------------------------------------------------------

locals {
  # Log events (the JSON `event` field) of routes rolled back ON PURPOSE, left out of the admin-pool alarm so it
  # keeps watching every other route. Keep this list short and dated; remove an entry the moment its flag is
  # back ON (a deliberate rollback that is not listed here simply holds the alarm in ALARM, which is the safe
  # side).
  #   publish_log_listed: GET /v1/publish-log, flag aa544:publish_log_list_pool pinned to "false" in Redis
  #   before the S241 D-12 merge (AA-CIS-App #792) and never switched back (Logs Insights 22-24/10/2026, AA-874).
  #   Remove when the flag is ON again (SET aa544:publish_log_list_pool true, or DEL) and Logs Insights shows
  #   publish_log_listed with used_tenant_pool=true.
  tenant_pool_known_rollback_events = ["publish_log_listed"]

  tenant_route_admin_pool_pattern = length(local.tenant_pool_known_rollback_events) == 0 ? "{ $.used_tenant_pool IS FALSE }" : format(
    "{ ($.used_tenant_pool IS FALSE) && %s }",
    join(" && ", [for e in local.tenant_pool_known_rollback_events : format("($.event != \"%s\")", e)]),
  )

  tenant_pool_alarm_filters = {
    tenant_flag_read_failed = {
      pattern     = "\"aa817_tenant_flag_read_failed\""
      description = "A tenant-pool route flag could not be read from Redis (error, timeout or no client); the route stayed on the tenant pool (RLS, fail closed). Check Redis and the line's reason=."
    }
    tenant_flag_unrecognized = {
      pattern     = "\"aa817_tenant_flag_unrecognized\""
      description = "A tenant-pool route flag holds a value that is neither ON nor OFF; treated as ON (tenant pool). Most likely a hand-typed rollback that did not take: fix the Redis value."
    }
    tenant_pool_unavailable = {
      pattern     = "\"aa817_tenant_pool_unavailable\""
      description = "A tenant route got no tenant-pool connection (fail-closed routes answer 503). Check the line's reason= and the aa_app_user pool / RDS connections."
    }
    tenant_guc_not_applied = {
      pattern     = "\"aa817_tenant_guc_not_applied\""
      description = "app.tenant_id did not take on a tenant-pool connection; the route answered 503 instead of running without RLS context. Check the line's flag_key and the aa_app_user role / pool setup."
    }
    tenant_route_admin_pool = {
      pattern     = local.tenant_route_admin_pool_pattern
      description = "A tenant route ran on the admin pool (BYPASSRLS, used_tenant_pool=false): a route flag is rolled back. Routes rolled back on purpose are excluded (tenant_pool_known_rollback_events in tenant_pool_alarms.tf); otherwise find who set the flag to false."
    }
  }
}

resource "aws_cloudwatch_log_metric_filter" "tenant_pool" {
  for_each = local.tenant_pool_alarm_filters

  name           = "${local.name_prefix}-${replace(each.key, "_", "-")}"
  log_group_name = module.ecs.log_group_name
  pattern        = each.value.pattern

  metric_transformation {
    name      = each.key
    namespace = "aa-cis/ops"
    value     = "1"
    unit      = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "tenant_pool" {
  for_each = local.tenant_pool_alarm_filters

  alarm_name          = "${local.name_prefix}-${replace(each.key, "_", "-")}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = aws_cloudwatch_log_metric_filter.tenant_pool[each.key].metric_transformation[0].name
  namespace           = "aa-cis/ops"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "${each.value.description}${local.runbook_suffix.incident}"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = merge(local.common_tags, { Issue = "AA-874" })
}
