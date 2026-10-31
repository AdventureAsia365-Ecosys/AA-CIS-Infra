# -----------------------------------------------------------------------------
# AA-971 (card CRM-13b, design v3 §4.8 L3) — alarms on AA break-glass access to an agency's data in AA-Partner
# (api/app/support/sessions.py), from the CRM log group (api + crm.job worker, JSON lines, AA-871).
#
# Break-glass is AA staff (WORKFORCE group crm-ops, crm-staff client) opening emergency read access to one agency
# without the owner's grant: a reason code, a ticket, at most one hour, every read in the agency's audit. The design
# asks for AA ops to be alerted every time, and for the agency owners to be told (the API mails them right away):
#
#   breakglass_opened          "crm_breakglass_opened"           WARNING: a break-glass session was opened. One line per
#                              session (tenant_id, session_id, reason_code, staff_ref, expires_at; no name or ticket).
#                              Every alarm is expected to have a ticket; one without is an incident.
#   breakglass_owner_not_mailed "crm_breakglass_owner_not_mailed" WARNING: no owner of that agency could be mailed
#                              (no active owner in the partner pool, SES refused or not configured). Someone must tell
#                              the owner within 24 hours (design §4.8 L3).
#
# Same shape as crm_membership_alarms.tf: Sum > 0 over 5 min, missing data = OK, e-mail on ALARM and on OK (SNS alerts).
# Renaming either line in AA-Partner silently disables its alarm: keep the names in sync (AA-Partner CONTEXT.md,
# section "AA support access L2 + break-glass L3").
# The AWS-level break-glass role (aa-crm-<env>-breakglass, crm_data.tf CrmBreakGlassOneAgency) is not created here: it
# needs a local MFA apply and stays a follow-up of AA-971.
# Cost: 2 alarms x $0.10 = $0.20/month; the metric filters are free and the custom metrics exist (and bill) only in
# hours where a line matched.
# -----------------------------------------------------------------------------

locals {
  crm_support_alarm_filters = {
    breakglass_opened = {
      pattern     = "\"crm_breakglass_opened\""
      description = "AA break-glass: emergency read access to one agency's CRM data was opened (no owner grant). Check the tenant_id / reason_code on the log line has an incident ticket; the agency sees every read in its access log."
    }
    breakglass_owner_not_mailed = {
      pattern     = "\"crm_breakglass_owner_not_mailed\""
      description = "AA break-glass was opened but no agency owner could be e-mailed. Tell the owner within 24 hours (design v3 L3) and check SES / the partner pool."
    }
  }
}

resource "aws_cloudwatch_log_metric_filter" "crm_support" {
  for_each = local.crm_support_alarm_filters

  name           = "${local.crm_name_prefix}-${replace(each.key, "_", "-")}"
  log_group_name = aws_cloudwatch_log_group.crm_api.name
  pattern        = each.value.pattern

  metric_transformation {
    name      = each.key
    namespace = "AA/Crm/Support"
    value     = "1"
    unit      = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "crm_support" {
  for_each = local.crm_support_alarm_filters

  alarm_name          = "${local.crm_name_prefix}-${replace(each.key, "_", "-")}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = aws_cloudwatch_log_metric_filter.crm_support[each.key].metric_transformation[0].name
  namespace           = aws_cloudwatch_log_metric_filter.crm_support[each.key].metric_transformation[0].namespace
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "${each.value.description}${local.runbook_suffix.incident}"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = merge(local.ecosys_tags, { App = "crm", Issue = "AA-971" })
}
