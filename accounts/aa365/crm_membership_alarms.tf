# -----------------------------------------------------------------------------
# AA-978 follow-up — alarms on the CRM's CIS membership feed (job crm_membership_pull, AA-Partner
# api/app/cis/membership_feed.py), from the CRM log group (api + crm.job worker, JSON lines, AA-871).
#
# The feed carries CIS removals and agency lock / unlock / delete into the CRM within a minute (root contract
# tenant.membership.v1). It never fails the job or /crm/health/ready on purpose (a CIS outage must not fill crm.job
# with failed rows or roll a deploy back), so these log lines are the only signal that revocations stopped:
#
#   membership_feed_stuck      "crm_membership_feed_stuck"           ERROR: 10+ consecutive failed pulls (CIS 401 / 403 /
#                              5xx, transport, malformed page or a systemic database error); the line names the
#                              error class. Repeats on every pull while it lasts (backoff caps at 5 minutes).
#   membership_apply_refused   "crm_membership_event_apply_refused"  ERROR: one CIS event refused by a CRM guard
#                              (SQLSTATE class CR) or an integrity rule (23); recorded rejected / apply_refused in
#                              crm.membership_inbox and skipped, so the feed goes on. One line is worth a look.
#
# Same shape as tenant_pool_alarms.tf: Sum > 0 over 5 min, missing data = OK, e-mail on ALARM and on OK (SNS alerts).
# Renaming either line in AA-Partner silently disables its alarm: keep the names in sync (AA-Partner CONTEXT.md).
# Cost: 2 alarms x $0.10 = $0.20/month; the metric filters are free and the custom metrics exist (and bill) only in
# hours where a line matched.
# -----------------------------------------------------------------------------

locals {
  crm_membership_alarm_filters = {
    membership_feed_stuck = {
      pattern     = "\"crm_membership_feed_stuck\""
      description = "The CRM has not pulled the CIS membership feed for 10+ runs in a row: CIS removals and agency locks no longer reach the CRM. Read error= on the line (CIS auth / outage / database) and /crm/health/ready membership_feed."
    }
    membership_apply_refused = {
      pattern     = "\"crm_membership_event_apply_refused\""
      description = "The CRM refused one CIS membership event (a CRM guard or integrity rule) and skipped it; the CRM may still list a member CIS removed. Find the event_id / sqlstate on the line and its crm.membership_inbox row."
    }
  }
}

resource "aws_cloudwatch_log_metric_filter" "crm_membership" {
  for_each = local.crm_membership_alarm_filters

  name           = "${local.crm_name_prefix}-${replace(each.key, "_", "-")}"
  log_group_name = aws_cloudwatch_log_group.crm_api.name
  pattern        = each.value.pattern

  metric_transformation {
    name      = each.key
    namespace = "AA/Crm/Membership"
    value     = "1"
    unit      = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "crm_membership" {
  for_each = local.crm_membership_alarm_filters

  alarm_name          = "${local.crm_name_prefix}-${replace(each.key, "_", "-")}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = aws_cloudwatch_log_metric_filter.crm_membership[each.key].metric_transformation[0].name
  namespace           = aws_cloudwatch_log_metric_filter.crm_membership[each.key].metric_transformation[0].namespace
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "${each.value.description}${each.key == "membership_feed_stuck" ? local.runbook_suffix.queue_stuck : local.runbook_suffix.incident}"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = merge(local.ecosys_tags, { App = "crm", Issue = "AA-978" })
}
