# =============================================================================
# AA-896 (S248) — spend guards on account 3 (LLM satellite, main).
#
# Why: acc3 carries almost all LLM spend (Bedrock Claude / GPT through the satellite roles, AA-296/AA-397),
# 51 USD in September and about 139 USD from 01/10 to 22/10/2026 (Cost Explorer, read 23/10/2026), but it had
# NO budget and only the AWS-created anomaly subscription (DAILY e-mail when an anomaly is >= 100 USD AND >= 40 %),
# which is too coarse for a bill of this size. acc2 is guarded by accounts/aa365/observability.tf (budgets) and
# accounts/aa365/cost_anomaly.tf (IMMEDIATE >= 5 USD to the alerts topic); this file gives acc3 the equivalent.
#
# What this file adds (all in acc3, applied locally with the MFA profile like the rest of this root):
#   1. aws_budgets_budget.acc3_monthly: monthly COST budget on the whole account, e-mail at 80 % and 100 % of
#      actual spend and at 100 % of forecast. Credits are EXCLUDED (include_credit = false) so the budget follows
#      real usage: the AWS Lift promotional credit hides spend and runs out.
#   2. aws_ce_anomaly_subscription.acc3_daily: a DAILY e-mail subscription on the existing AWS services monitor
#      (Default-Services-Monitor, created by AWS; one per account, so it is referenced, not created or imported)
#      for any anomaly whose total impact is >= var.acc3_anomaly_alert_usd.
#
# E-mail, not the acc2 alerts SNS topic: a cross-account SNS subscriber needs a topic policy on acc2 for
# budgets.amazonaws.com / costalerts.amazonaws.com with aws:SourceAccount = acc3, which is a second PR on the
# aa365 root for little gain. The address is the same bootstrap recipient as acc2 (var.alert_email there).
# IMMEDIATE frequency accepts only an SNS subscriber, so the e-mail subscription is DAILY.
#
# Cost: 0 USD/month. Budgets without actions are free; Cost Anomaly Detection is free; e-mail is sent by AWS.
# =============================================================================

variable "acc3_budget_monthly_usd" {
  description = "AA-896: monthly cost budget for acc3 (USD, gross of credits). 250 = the AWS Lift tier 1 credit; October 2026 runs at about 190 USD/month"
  type        = number
  default     = 250
}

variable "acc3_anomaly_alert_usd" {
  description = "AA-896: minimum total impact (USD) of a cost anomaly that is e-mailed in the daily summary"
  type        = number
  default     = 10
}

variable "acc3_cost_alert_email" {
  description = "AA-896: recipient of acc3 budget and anomaly e-mails (same bootstrap inbox as the acc2 alerts topic)"
  type        = string
  default     = "nghieppham@adventure.asia"
}

variable "acc3_services_monitor_id" {
  description = "AA-896: id (UUID) of the AWS-created Default-Services-Monitor on acc3 (aws ce get-anomaly-monitors)"
  type        = string
  default     = "bb9d753d-fb4a-4c9d-8504-46b1fc51dca9"
}

data "aws_caller_identity" "current" {}

resource "aws_budgets_budget" "acc3_monthly" {
  name         = "aa3-llm-monthly-total"
  budget_type  = "COST"
  limit_amount = tostring(var.acc3_budget_monthly_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_types {
    include_credit = false
    include_refund = false
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.acc3_cost_alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.acc3_cost_alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.acc3_cost_alert_email]
  }

  tags = { Issue = "AA-896" }
}

resource "aws_ce_anomaly_subscription" "acc3_daily" {
  name             = "aa3-cost-anomaly-daily"
  frequency        = "DAILY"
  monitor_arn_list = ["arn:aws:ce::${data.aws_caller_identity.current.account_id}:anomalymonitor/${var.acc3_services_monitor_id}"]

  subscriber {
    type    = "EMAIL"
    address = var.acc3_cost_alert_email
  }

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = [tostring(var.acc3_anomaly_alert_usd)]
    }
  }

  tags = { Issue = "AA-896" }
}
