# =============================================================================
# AA-1110 (S297) — a chat alert channel: Amazon Q Developer in chat applications (the service formerly named AWS
# Chatbot, API prefix `chatbot`) posts the alarms of one alerts topic into one Slack channel. OFF by default.
#
# Why: alarms reach e-mail only (the bootstrap recipient, the recipients of the CIS admin page and, when set, the
# second Terraform recipient var.alert_email_secondary of observability.tf). A chat channel is read on a phone within
# minutes by the tech lead and the business owner (the second on-call person, root sec-Q16), so it is the second
# channel of the continuity pack; the second e-mail recipient stays the fallback.
#
# GATE: var.chat_alerts_enabled (default false) creates nothing at all (count = 0: no role, no configuration, no SNS
# subscription). Turning it on needs, in this order (root docs/ops/runbooks/chat-alert-channel.md):
#   1. once, by hand: authorise the Slack workspace in the Amazon Q Developer in chat applications console (an OAuth
#      consent in the browser, which Terraform cannot do), invite the app into the channel;
#   2. the repo secrets CHAT_ALERTS_SLACK_TEAM_ID and CHAT_ALERTS_SLACK_CHANNEL_ID (TF_VAR_chat_alerts_slack_team_id /
#      _channel_id in terraform-plan, -apply and -drift; never terraform.tfvars: this repo is public);
#   3. the local MFA apply of cicd_sec.tf (the apply role's chatbot grants are a bootstrap object);
#   4. a PR that sets chat_alerts_enabled = true in terraform.tfvars, then Terraform Apply Dev.
# The validations below refuse step 4 without step 2, so a half-configured plan fails instead of creating a broken
# configuration.
#
# WHAT REACHES THE CHANNEL: Q Developer renders AWS service notifications it supports (CloudWatch alarms, AWS Budgets,
# Cost Anomaly Detection, raw EventBridge events) and drops any other text with "Event Received is not supported" in
# its log. The alerts topic also carries plain-text messages (the CIS in-app checks of shared/ops_checks.py and the
# EventBridge rules whose input transformer writes an e-mail sentence), which therefore reach e-mail only. The chat
# channel is a faster second path for the alarms, not a replacement for e-mail.
#
# TOPIC: var.chat_alerts_topic picks "all" (the alerts topic, every alarm; the default) or "page" (the page topic of
# alert_severity.tf, urgent ones only). The SNS subscription is created by the service (HTTPS endpoint
# global.sns-api.chatbot.amazonaws.com) and is not in Terraform state; the CIS admin page lists and reconciles e-mail
# subscriptions only (AA-CIS-App shared/alert_recipients.py filters Protocol == "email"), so it never removes it.
#
# PERMISSIONS: the channel role is notification-only (the console's "Notification permissions" template: CloudWatch
# Describe / Get / List, for the alarm graph in the message), with the workload boundary like every role the apply role
# creates (cicd_split.tf DenyCreateRoleWithoutWorkloadBoundary). The channel guardrail is the AWS managed
# CloudWatchReadOnlyAccess, so nobody in the channel can run a write command or an Amazon Q chat through it even if the
# role were widened; without an explicit guardrail the service applies none. User roles are off (one channel role).
# Logging NONE: no log group in us-east-1 without retention; set "ERROR" in a PR while troubleshooting, then back.
#
# REGION: the chatbot API runs in us-east-2, us-west-2, ap-southeast-1 and eu-west-1 only (AWS CLI reference
# "chatbot"); not us-west-1. The configuration uses the existing us-west-2 provider; the topics stay in us-west-1.
#
# COST (AWS docs read 28/11/2026, "Amazon Q Developer in chat applications rename - Summary of changes", Pricing):
# notifications and CLI commands are at no additional cost; Amazon Q answers in chat are limited to the Q Developer
# Free tier and are not enabled here (no AmazonQDeveloperAccess guardrail). SNS HTTPS deliveries to the service: inside
# the 100,000 free HTTP/S notifications a month. IAM: free. Slack: a free workspace is enough. Total 0 USD.
# =============================================================================

locals {
  chat_alerts_name = "aa-ecosys-${var.environment}-chat-alerts"

  # The topics the channel subscribes to (var.chat_alerts_topic): "all" = the alerts topic, "page" = the page topic.
  chat_alerts_topic_arns = {
    all  = [aws_sns_topic.alerts.arn]
    page = [aws_sns_topic.page.arn]
  }
}

data "aws_iam_policy_document" "chat_alerts_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["chatbot.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "chat_alerts" {
  count = var.chat_alerts_enabled ? 1 : 0

  name                 = local.chat_alerts_name
  description          = "AA-1110: Amazon Q Developer in chat applications channel role (notifications only)"
  assume_role_policy   = data.aws_iam_policy_document.chat_alerts_trust.json
  permissions_boundary = aws_iam_policy.workload_boundary.arn

  tags = merge(local.shared_tags, { Issue = "AA-1110", Component = "observability" })
}

# The console template "Notification permissions": read CloudWatch so the message can show the alarm graph.
resource "aws_iam_role_policy" "chat_alerts" {
  count = var.chat_alerts_enabled ? 1 : 0

  name = "notifications-read-cloudwatch"
  role = aws_iam_role.chat_alerts[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "NotificationGraphs"
      Effect   = "Allow"
      Action   = ["cloudwatch:Describe*", "cloudwatch:Get*", "cloudwatch:List*"]
      Resource = "*"
    }]
  })
}

resource "aws_chatbot_slack_channel_configuration" "alerts" {
  count    = var.chat_alerts_enabled ? 1 : 0
  provider = aws.us_west_2

  configuration_name          = local.chat_alerts_name
  iam_role_arn                = aws_iam_role.chat_alerts[0].arn
  slack_team_id               = var.chat_alerts_slack_team_id
  slack_channel_id            = var.chat_alerts_slack_channel_id
  sns_topic_arns              = local.chat_alerts_topic_arns[var.chat_alerts_topic]
  guardrail_policy_arns       = ["arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"]
  user_authorization_required = false
  logging_level               = "NONE"

  tags = merge(local.shared_tags, { Issue = "AA-1110", Component = "observability" })

  # The role policy must exist before the first notification renders a graph.
  depends_on = [aws_iam_role_policy.chat_alerts]
}
