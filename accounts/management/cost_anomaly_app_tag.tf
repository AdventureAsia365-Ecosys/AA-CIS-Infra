# =============================================================================
# AA-896 (S262) — Cost Anomaly Detection per `App` cost allocation tag, run from the management (payer) account.
#
# Why here: AWS creates cost-allocation-tag (and linked-account, cost category) monitors only in the management
# account (AWS Cost Anomaly Detection guide, getting started). The member-side guards stay as they are:
# accounts/aa365/cost_anomaly.tf (AWS services monitor -> IMMEDIATE SNS alerts topic, >= 5 USD), the per-App budgets in
# accounts/aa365/observability.tf, and budgets.tf in this root (one LINKED_ACCOUNT monitor per account).
#
# OFF by default (var.app_tag_anomaly_monitors_enabled = false; the plan is empty). A tag monitor in this account sees
# only spend billed through this organization, and today the nonprod (infrastructure) account is billed by the
# reseller's organization. Switch it on when BOTH hold:
#   1. the nonprod account is a member of this organization (member_accounts.nonprod, README §6), and
#   2. `App` is an ACTIVE cost allocation tag in this account (Billing and Cost Management, Cost allocation tags;
#      activation is not retroactive and takes up to 24 hours to show). A monitor on an inactive tag sees nothing.
# Then set the variable to true in terraform.tfvars / MGMT_TFVARS and apply this root.
#
# One CUSTOM monitor per App value, so an anomaly names the app; one DAILY e-mail subscription for all of them
# (e-mail subscribers allow DAILY or WEEKLY; IMMEDIATE needs an SNS topic in this account, and the alerts topic lives in
# the nonprod account). Same recipients and threshold as the per-account monitors of budgets.tf.
#
# Cost: 0 USD. Cost Anomaly Detection is free. The CI apply role already holds ce:CreateAnomalyMonitor /
# CreateAnomalySubscription and the manage verbs on this account's monitors and subscriptions (cicd.tf
# CostAnomalyCreate / CostAnomalyManage), so no IAM change.
# =============================================================================

resource "aws_ce_anomaly_monitor" "app_tag" {
  for_each = var.app_tag_anomaly_monitors_enabled ? toset(var.app_tag_values) : toset([])

  name         = "aa-app-${each.value}-spend"
  monitor_type = "CUSTOM"

  # Every key spelled out (null where unused), as budgets.tf does: the API echoes them back, and a shorter document
  # shows a permanent diff.
  monitor_specification = jsonencode({
    And               = null
    CostCategories    = null
    Dimensions        = null
    Not               = null
    Or                = null
    ProductAttributes = null
    Tags = {
      Key          = "App"
      MatchOptions = null
      Values       = [each.value]
    }
  })
}

resource "aws_ce_anomaly_subscription" "app_tag" {
  count = var.app_tag_anomaly_monitors_enabled ? 1 : 0

  name             = "aa-app-tag-anomaly-daily"
  frequency        = "DAILY"
  monitor_arn_list = [for k in sort(keys(aws_ce_anomaly_monitor.app_tag)) : aws_ce_anomaly_monitor.app_tag[k].arn]

  dynamic "subscriber" {
    for_each = toset(var.budget_alert_emails)
    content {
      type    = "EMAIL"
      address = subscriber.value
    }
  }

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = [tostring(var.anomaly_threshold_usd)]
    }
  }
}
