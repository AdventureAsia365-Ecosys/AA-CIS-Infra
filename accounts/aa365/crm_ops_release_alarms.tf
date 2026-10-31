# -----------------------------------------------------------------------------
# AA-956 (card CRM-26, design v3 F8.3 / Fix B2, C12 step 6) — alarms that tell AA ground operations about Module 8 ops
# releases in AA-Partner (api/app/ops_release/service.py), from the CRM log group (api + crm.job worker, JSON lines).
#
# A release is the traveller details AA ops need to run a confirmed AA departure, kept in the CRM under the agency's
# ops_release key and read by AA ops on S-02 (/crm/staff/v1, WORKFORCE group crm-ops). Two moments need AA ops' eyes:
#
#   ops_release_incomplete_t21  "crm_ops_release_incomplete_t21"  WARNING: a release is still incomplete 21 days before
#                               departure (Stage 3, waiver or flights missing). Once per release; the trip owner also
#                               gets an urgent task. The line holds ids and counts only (tenant_id, ops_release_id,
#                               days_left, travellers, complete).
#   ops_release_withdrawn       "crm_ops_release_withdrawn"       NOTICE: a release was withdrawn (the trip was
#                               cancelled, its AA lines were cancelled, or the agency withdrew it). AA ops lose the
#                               details at once; the S-02 board shows the withdrawal for 14 days.
#
# Same shape as crm_support_alarms.tf: Sum > 0 over 5 min, missing data = OK, e-mail on ALARM and on OK (SNS alerts).
# Renaming either line in AA-Partner silently disables its alarm: keep the names in sync (AA-Partner CONTEXT.md,
# section "Module 8 ops release").
# Cost: 2 alarms x $0.10 = $0.20/month; the metric filters are free and the custom metrics exist (and bill) only in
# hours where a line matched. No paid paging (SMS / WhatsApp): e-mail through the existing alerts topic only.
# -----------------------------------------------------------------------------

locals {
  crm_ops_release_alarm_filters = {
    ops_release_incomplete_t21 = {
      pattern     = "\"crm_ops_release_incomplete_t21\""
      description = "AA ops release: a confirmed AA departure is 21 days away and the agency's traveller details are still incomplete. Open S-02 (AA-Partner /crm/staff/v1/ops-releases) and follow up with the agency; the trip owner has an urgent task."
    }
    ops_release_withdrawn = {
      pattern     = "\"crm_ops_release_withdrawn\""
      description = "AA ops release withdrawn: a trip with an AA line was cancelled (or the agency withdrew its release). AA ops no longer hold the traveller details; check the departure in the Booking staff admin."
    }
  }
}

resource "aws_cloudwatch_log_metric_filter" "crm_ops_release" {
  for_each = local.crm_ops_release_alarm_filters

  name           = "${local.crm_name_prefix}-${replace(each.key, "_", "-")}"
  log_group_name = aws_cloudwatch_log_group.crm_api.name
  pattern        = each.value.pattern

  metric_transformation {
    name      = each.key
    namespace = "AA/Crm/OpsRelease"
    value     = "1"
    unit      = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "crm_ops_release" {
  for_each = local.crm_ops_release_alarm_filters

  alarm_name          = "${local.crm_name_prefix}-${replace(each.key, "_", "-")}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = aws_cloudwatch_log_metric_filter.crm_ops_release[each.key].metric_transformation[0].name
  namespace           = aws_cloudwatch_log_metric_filter.crm_ops_release[each.key].metric_transformation[0].namespace
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "${each.value.description}${local.runbook_suffix.incident}"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = merge(local.ecosys_tags, { App = "crm", Issue = "AA-956" })
}
