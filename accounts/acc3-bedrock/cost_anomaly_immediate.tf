# =============================================================================
# AA-896 (S255) — IMMEDIATE cost anomaly alerts on account 3 (LLM satellite, main).
#
# Why: acc3 carries the LLM bill. October 01-27/2026 = 242.13 USD (budget aa3-llm-monthly-total 250, AWS forecast
# 310.41). Single wave days reach 29-36 USD (08/10 Haiku 4.5 judge wave 34.27; 24/10 Sonnet 5.5 S1 writer wave
# 36.09), yet the only anomaly path was the DAILY e-mail of cost_guard.tf (aa3-cost-anomaly-daily, >= 10 USD), up to
# ~24 h late. IMMEDIATE accepts only an SNS subscriber in the SAME account, so this file adds a small topic on acc3
# with the same bootstrap recipient as the acc2 alerts topic (var.acc3_cost_alert_email, cost_guard.tf). The DAILY
# subscription stays as the summary; the budget keeps its direct e-mail (pointing it at the topic too would send
# two mails per notification).
#
# Root audit: docs/audits/2026-10-28-S255-finops-security/ (decision D2).
#
# Cost: SNS topic 0 USD; e-mail deliveries stay inside the 1,000/month free tier; Cost Anomaly Detection is free
# -> 0 USD/month.
# Apply: this root is applied locally with the MFA profile nghiep_aa365 (not by CI). After apply the recipient
# must click the SNS confirmation e-mail once; Terraform cannot confirm an e-mail subscription.
# =============================================================================

variable "acc3_anomaly_immediate_usd" {
  description = "AA-896 (S255): minimum total impact (USD) of an acc3 cost anomaly that is sent at once through SNS"
  type        = number
  default     = 15
}

resource "aws_sns_topic" "acc3_cost_alerts" {
  name = "aa3-cost-alerts"
  tags = { Issue = "AA-896" }
}

resource "aws_sns_topic_subscription" "acc3_cost_alerts_email" {
  topic_arn = aws_sns_topic.acc3_cost_alerts.arn
  protocol  = "email"
  endpoint  = var.acc3_cost_alert_email
}

# The AWS default topic policy (same-account publishers) plus Cost Anomaly Detection, limited to this account.
# Statement from the AWS guide "Creating an Amazon SNS topic for anomaly notifications" (as acc2 identity_alerts.tf).
data "aws_iam_policy_document" "acc3_cost_alerts" {
  policy_id = "__default_policy_ID"

  statement {
    sid    = "__default_statement_ID"
    effect = "Allow"
    actions = [
      "SNS:GetTopicAttributes", "SNS:SetTopicAttributes", "SNS:AddPermission",
      "SNS:RemovePermission", "SNS:DeleteTopic", "SNS:Subscribe",
      "SNS:ListSubscriptionsByTopic", "SNS:Publish",
    ]
    resources = [aws_sns_topic.acc3_cost_alerts.arn]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceOwner"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid       = "AllowCostAnomalyDetection"
    effect    = "Allow"
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.acc3_cost_alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["costalerts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "acc3_cost_alerts" {
  arn    = aws_sns_topic.acc3_cost_alerts.arn
  policy = data.aws_iam_policy_document.acc3_cost_alerts.json
}

resource "aws_ce_anomaly_subscription" "acc3_immediate" {
  name             = "aa3-cost-anomaly-immediate"
  frequency        = "IMMEDIATE"
  monitor_arn_list = ["arn:aws:ce::${data.aws_caller_identity.current.account_id}:anomalymonitor/${var.acc3_services_monitor_id}"]

  subscriber {
    type    = "SNS"
    address = aws_sns_topic.acc3_cost_alerts.arn
  }

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = [tostring(var.acc3_anomaly_immediate_usd)]
    }
  }

  tags = { Issue = "AA-896" }

  # Cost Anomaly Detection checks its publish right on the topic when the subscription is created.
  depends_on = [aws_sns_topic_policy.acc3_cost_alerts]
}

output "acc3_cost_alerts_topic_arn" {
  description = "AA-896 (S255): SNS topic of the acc3 IMMEDIATE cost anomaly alerts"
  value       = aws_sns_topic.acc3_cost_alerts.arn
}
