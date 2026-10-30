# =============================================================================
# AA-1004 — budgets and Cost Anomaly Detection, run from the management (payer) account.
#
# One monthly budget for the whole organization, one per account (management + every member, filtered on
# LinkedAccount), and one Cost Anomaly Detection monitor + daily e-mail subscription per account.
# Budgets count GROSS cost: credits and refunds are excluded, so a promotional credit (the ai account's AWS Lift
# credit) cannot hide real spend.
#
# Cost: 0 USD. Budgets without actions and Cost Anomaly Detection are free; the monitors are CUSTOM
# (LINKED_ACCOUNT), so they do not collide with the one AWS-managed services monitor an account may already have.
# Existing guards inside the member accounts (accounts/aa365 observability.tf + cost_anomaly.tf,
# accounts/acc3-bedrock cost_guard.tf) keep running; these add the payer's view.
# Pre-condition: Cost Explorer opened once in this account (README step 4); a monitor cannot be created before.
# =============================================================================

locals {
  budget_accounts = merge(
    { management = { name = "aa-management", budget_usd = var.management_budget_usd } },
    { for k, a in var.member_accounts : k => { name = a.name, budget_usd = a.budget_usd } },
  )

  # ACTUAL 80 % and 100 %, FORECASTED 100 % (as the nonprod account budget does today).
  budget_notifications = [
    { type = "ACTUAL", threshold = 80 },
    { type = "ACTUAL", threshold = 100 },
    { type = "FORECASTED", threshold = 100 },
  ]
}

resource "aws_budgets_budget" "organization" {
  name         = "aa-org-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.org_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_types {
    include_credit = false
    include_refund = false
  }

  # The whole organization also warns at 50 % (blueprint §4 "Budget").
  dynamic "notification" {
    for_each = concat([{ type = "ACTUAL", threshold = 50 }], local.budget_notifications)
    content {
      comparison_operator        = "GREATER_THAN"
      notification_type          = notification.value.type
      threshold                  = notification.value.threshold
      threshold_type             = "PERCENTAGE"
      subscriber_email_addresses = var.budget_alert_emails
    }
  }
}

resource "aws_budgets_budget" "account" {
  for_each = local.budget_accounts

  name         = "${each.value.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(each.value.budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "LinkedAccount"
    values = [local.account_ids[each.key]]
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
      subscriber_email_addresses = var.budget_alert_emails
    }
  }
}

resource "aws_ce_anomaly_monitor" "account" {
  for_each = local.budget_accounts

  name         = "${each.value.name}-spend"
  monitor_type = "CUSTOM"

  # Every key spelled out (null where unused): the API echoes them back, and a shorter document shows a
  # permanent diff (provider documentation example).
  monitor_specification = jsonencode({
    And            = null
    CostCategories = null
    Dimensions = {
      Key          = "LINKED_ACCOUNT"
      MatchOptions = null
      Values       = [local.account_ids[each.key]]
    }
    Not  = null
    Or   = null
    Tags = null
  })
}

resource "aws_ce_anomaly_subscription" "account" {
  for_each = local.budget_accounts

  name             = "${each.value.name}-anomaly-daily"
  frequency        = "DAILY" # e-mail subscribers allow DAILY or WEEKLY; IMMEDIATE would need an SNS topic
  monitor_arn_list = [aws_ce_anomaly_monitor.account[each.key].arn]

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
