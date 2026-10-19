# =============================================================================
# AA-896 (S243) — AWS Cost Anomaly Detection -> the alerts SNS topic (FinOps, data standard DM-10).
#
# What exists (read live 19/10/2026, `aws ce get-anomaly-monitors` / `get-anomaly-subscriptions`):
#   - "Default-Services-Monitor": the AWS services monitor AWS created automatically on 20/04/2026
#     (DIMENSIONAL / SERVICE, AWS managed, tracks every service this account uses).
#   - "Default-Services-Subscription": DAILY e-mail summary to the account e-mail, threshold
#     impact >= $100 AND >= 40%. It is NOT managed here and stays as it is.
#
# What this file adds:
#   1. Imports the default monitor (an account can hold one AWS services monitor; creating a second
#      one would fail), so Terraform owns it and tags it. Name and type are unchanged: the import is
#      an in-place tag update, no replacement.
#   2. One IMMEDIATE subscription to aws_sns_topic.alerts (the topic every alarm already uses, e-mailed
#      to var.alert_email) for any anomaly whose total cost impact is >= var.cost_anomaly_alert_usd.
#      IMMEDIATE is the only frequency that accepts an SNS subscriber.
#   3. The topic policy statement that lets costalerts.amazonaws.com publish (identity_alerts.tf,
#      Sid AllowCostAnomalyDetection, limited to this account with aws:SourceAccount).
#
# NOT possible here: a monitor on the `App` cost allocation tag. acc2 is a member account of the
# payer's organisation, and "cost monitors for linked accounts, cost allocation tags and cost
# categories can only be created in the management account" (AWS Cost Anomaly Detection guide,
# getting started). Per-App spend is watched by the AA-828 budgets (observability.tf,
# aws_budgets_budget.per_app_monthly) and the cost-per-app page (AA-884).
#
# Cost: Cost Anomaly Detection is free; SNS e-mail delivery is inside the free tier (1,000/month).
# $0/month.
#
# CI permissions: the apply role had no ce:* grant. cicd_split.tf adds the bootstrap statements
# CostAnomalyCreate / CostAnomalyManage to aws_iam_role_policy.tf_apply. The apply role cannot
# rewrite its own policy, so that one resource is applied first, locally, with the MFA admin
# profile (targeted apply), then this PR merges and CI applies the rest (AA-896 notes).
# The plan role reads ce:Get*/List* through ReadOnlyAccess.
# =============================================================================

import {
  to = aws_ce_anomaly_monitor.services
  id = "arn:aws:ce::${var.account_id}:anomalymonitor/75e833c3-f6b9-48c0-8ea8-104ca4b603fc"
}

resource "aws_ce_anomaly_monitor" "services" {
  name              = "Default-Services-Monitor"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"

  tags = merge(local.shared_tags, { Issue = "AA-896" })
}

resource "aws_ce_anomaly_subscription" "alerts_sns" {
  name             = "${local.name_prefix}-cost-anomaly-to-alerts"
  frequency        = "IMMEDIATE"
  monitor_arn_list = [aws_ce_anomaly_monitor.services.arn]

  subscriber {
    type    = "SNS"
    address = aws_sns_topic.alerts.arn
  }

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = [tostring(var.cost_anomaly_alert_usd)]
    }
  }

  tags = merge(local.shared_tags, { Issue = "AA-896" })

  # The service checks that it may publish when the subscription is created.
  depends_on = [aws_sns_topic_policy.alerts]
}
