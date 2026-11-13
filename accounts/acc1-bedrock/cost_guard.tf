# =============================================================================
# AA-1096 (S279) — billing-only spend ALERTS on account 1 (acc1), the Bedrock chat account since S278.
#
# Why: acc1 serves the gateway's Bedrock chat models (root ADR 0001a, Note S278) and had no spend guard. Tech lead
# decision S279 (13/11/2026): acc1 Bedrock spend is ALERT ONLY, never stopped. The CIS gateway connection `acc1` warns
# (monthly budget, alert at 80 %, no hard stop); this file adds the free AWS side. Root ADR 0001a, Note S279, records
# this billing-only exception to "nothing else on acc1".
#
# What this file adds (3 resources, all free):
#   1. aws_budgets_budget.acc1_monthly: monthly COST budget, e-mail at var.budget_alert_actual_percents of ACTUAL
#      spend (50 / 80 / 100 %) and at var.budget_alert_forecast_percent of FORECASTED spend (100 %). NO budget action
#      and no IAM for one: the budget only mails, it never stops or limits anything.
#   2. aws_ce_anomaly_monitor.acc1_spend: a CUSTOM Cost Anomaly Detection monitor on acc1's own spend.
#   3. aws_ce_anomaly_subscription.acc1_daily: a DAILY e-mail for any anomaly whose total impact is
#      >= var.anomaly_alert_usd.
#
# Scoped to acc1's own usage (LinkedAccount = var.account_id), not the whole bill. Since S277 acc1 is the payer of
# acc3's organization, so an unfiltered budget or an AWS services monitor on acc1 would count acc3's Bedrock spend too
# (acc3 has its own guards, accounts/acc3-bedrock/cost_guard.tf) and fire on the first day of a month. Same reason,
# and the AWS limit of one services (DIMENSIONAL SERVICE) monitor per account, as the management root: the monitor is
# CUSTOM on LINKED_ACCOUNT (accounts/management/budgets.tf). A LINKED_ACCOUNT monitor needs acc1 to stay a management
# account; if acc1's organization is closed (acc3 moving to the AA organization), switch it to DIMENSIONAL SERVICE
# (or reference the AWS-created services monitor, as acc3 does) in the same change.
#
# Gross cost: credits and refunds are excluded (include_credit = false), as on acc3 and the management root, so the
# pooled AWS Lift credit cannot hide real usage (it does not cover Claude on Bedrock anyway).
#
# E-mail straight from Budgets and Cost Anomaly Detection, no SNS topic: IMMEDIATE anomaly alerts would need an SNS
# topic (and its policy) on acc1; DAILY is enough for an alert-only guard and keeps acc1 to the fewest resources. The
# recipient comes from the untracked terraform.tfvars (var.cost_alert_email, no default), like account_id. AWS sends
# no confirmation mail for direct Budgets or Cost Anomaly e-mail subscribers.
#
# Thresholds are Terraform variables, not admin settings: AWS Budgets is one of the exceptions that stay in Terraform
# (AA-1096 scope, S279 thresholds audit section 4). output.cost_guard publishes the values for the read-only Infra view.
#
# Cost: 0 USD/month. Budgets without actions are free (the first two action-enabled budgets too); Cost Anomaly
# Detection is free; e-mail is sent by AWS.
# =============================================================================

variable "budget_monthly_usd" {
  description = "AA-1096: monthly cost budget of acc1's own usage (USD, gross of credits). Alert only, never a stop. Same value as the CIS gateway connection acc1 monthly budget (S279)."
  type        = number
  default     = 100

  validation {
    condition     = var.budget_monthly_usd > 0
    error_message = "budget_monthly_usd must be a positive amount in USD."
  }
}

variable "budget_alert_actual_percents" {
  description = "AA-1096: percentages of budget_monthly_usd at which ACTUAL spend sends an e-mail."
  type        = list(number)
  default     = [50, 80, 100]

  validation {
    condition     = length(var.budget_alert_actual_percents) > 0 && alltrue([for p in var.budget_alert_actual_percents : p > 0 && p <= 1000])
    error_message = "Give at least one percentage, each above 0 and at most 1000."
  }
}

variable "budget_alert_forecast_percent" {
  description = "AA-1096: percentage of budget_monthly_usd at which the FORECASTED month-end spend sends an e-mail."
  type        = number
  default     = 100

  validation {
    condition     = var.budget_alert_forecast_percent > 0 && var.budget_alert_forecast_percent <= 1000
    error_message = "budget_alert_forecast_percent must be above 0 and at most 1000."
  }
}

variable "anomaly_alert_usd" {
  description = "AA-1096: minimum total impact (USD) of an acc1 cost anomaly that is e-mailed in the daily summary."
  type        = number
  default     = 10

  validation {
    condition     = var.anomaly_alert_usd > 0
    error_message = "anomaly_alert_usd must be a positive amount in USD."
  }
}

variable "cost_alert_email" {
  description = "AA-1096: recipient of the acc1 budget and anomaly e-mails (the tech lead's alert inbox). From the untracked terraform.tfvars; never committed."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.cost_alert_email))
    error_message = "cost_alert_email must be one e-mail address."
  }
}

locals {
  budget_notifications = concat(
    [for p in var.budget_alert_actual_percents : { type = "ACTUAL", threshold = p }],
    [{ type = "FORECASTED", threshold = var.budget_alert_forecast_percent }],
  )
}

resource "aws_budgets_budget" "acc1_monthly" {
  name         = "aa1-llm-monthly-total"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_monthly_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # acc1's own usage only: acc1 is the payer of acc3's organization (see header).
  cost_filter {
    name   = "LinkedAccount"
    values = [var.account_id]
  }

  cost_types {
    include_credit = false
    include_refund = false
  }

  dynamic "notification" {
    for_each = local.budget_notifications
    content {
      comparison_operator        = "GREATER_THAN"
      notification_type          = notification.value.type
      threshold                  = notification.value.threshold
      threshold_type             = "PERCENTAGE"
      subscriber_email_addresses = [var.cost_alert_email]
    }
  }

  tags = { Component = "billing", Issue = "AA-1096" }
}

resource "aws_ce_anomaly_monitor" "acc1_spend" {
  name         = "aa1-spend"
  monitor_type = "CUSTOM"

  # Every key spelled out (null where unused): the API echoes them back, and a shorter document shows a permanent
  # diff (accounts/management/budgets.tf, provider documentation example).
  monitor_specification = jsonencode({
    And            = null
    CostCategories = null
    Dimensions = {
      Key          = "LINKED_ACCOUNT"
      MatchOptions = null
      Values       = [var.account_id]
    }
    Not               = null
    Or                = null
    ProductAttributes = null # AWS returns this key; without it every plan replaces the monitor
    Tags              = null
  })

  tags = { Component = "billing", Issue = "AA-1096" }
}

resource "aws_ce_anomaly_subscription" "acc1_daily" {
  name             = "aa1-cost-anomaly-daily"
  frequency        = "DAILY" # e-mail subscribers allow DAILY or WEEKLY; IMMEDIATE would need an SNS topic
  monitor_arn_list = [aws_ce_anomaly_monitor.acc1_spend.arn]

  subscriber {
    type    = "EMAIL"
    address = var.cost_alert_email
  }

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = [tostring(var.anomaly_alert_usd)]
    }
  }

  tags = { Component = "billing", Issue = "AA-1096" }
}

output "cost_guard" {
  description = "AA-1096: acc1 spend alert values (alert only, no stop), for the read-only Infra view of budget values."
  value = {
    budget_name             = aws_budgets_budget.acc1_monthly.name
    budget_monthly_usd      = var.budget_monthly_usd
    alert_actual_percents   = var.budget_alert_actual_percents
    alert_forecast_percent  = var.budget_alert_forecast_percent
    anomaly_monitor_arn     = aws_ce_anomaly_monitor.acc1_spend.arn
    anomaly_alert_usd       = var.anomaly_alert_usd
    anomaly_alert_frequency = aws_ce_anomaly_subscription.acc1_daily.frequency
    hard_stop               = false
  }
}
