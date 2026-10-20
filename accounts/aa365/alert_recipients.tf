# =============================================================================
# AA-913 (S245) — alert recipients managed from the CIS admin page (Platform > Alert recipients).
#
# The CIS api (and worker: one shared task role, modules/ecs aws_iam_role.ecs_task) manages the
# e-mail subscriptions of the alerts topic aws_sns_topic.alerts (observability.tf). Every platform
# alert path publishes to that topic: CloudWatch alarms of CIS, Booking, TripPlanner and shared,
# the identity EventBridge rules, Cost Anomaly Detection and (since AA-913) AWS Budgets.
#
#   - Terraform keeps exactly one subscription, the bootstrap aws_sns_topic_subscription.alerts_email
#     (var.alert_email). The app shows it locked and never touches it.
#   - Subscriptions the app creates are NOT in Terraform state, by design: Terraform does not track
#     them, so there is no drift and no fight between a plan and the admin page.
#   - The topic ARN and the bootstrap address reach the app as env ALERTS_TOPIC_ARN and
#     ALERT_BOOTSTRAP_EMAIL (modules/ecs local.ops_alert_mail_env, set from main.tf module "ecs").
#     The public CIS repo carries neither.
#
# Grant: the four SNS actions of the Linear scope, on this one topic only. No sns:Publish, no
# sns:SetSubscriptionAttributes, no account-wide sns:ListSubscriptions.
# Resource types (Service Authorization Reference, Amazon SNS, read S245): Subscribe and
# ListSubscriptionsByTopic require the topic; Unsubscribe and GetSubscriptionAttributes list the
# topic as OPTIONAL and the API takes a subscription ARN (<topic ARN>:<uuid>), so both the topic ARN
# and "<topic ARN>:*" are listed. Topic names cannot contain ":", so the wildcard names only
# subscriptions of this topic.
#
# Cost: IAM inline policy, $0. SNS e-mail is free up to 1,000 notifications/month.
# CI apply: aa-cis-infra-tf-apply may iam:PutRolePolicy on aa-*-dev-* roles (cicd_split.tf
# IAMRoleManageStack), so no bootstrap/MFA apply is needed.
# =============================================================================

data "aws_iam_policy_document" "cis_alert_recipients" {
  # Subscribe: e-mail protocol only (no http/sqs/lambda endpoints from the app).
  statement {
    sid       = "AlertsTopicSubscribeEmail"
    effect    = "Allow"
    actions   = ["sns:Subscribe"]
    resources = [aws_sns_topic.alerts.arn]

    condition {
      test     = "StringEquals"
      variable = "sns:Protocol"
      values   = ["email"]
    }
  }

  statement {
    sid       = "AlertsTopicListSubscriptions"
    effect    = "Allow"
    actions   = ["sns:ListSubscriptionsByTopic"]
    resources = [aws_sns_topic.alerts.arn]
  }

  # Unsubscribe / GetSubscriptionAttributes are called with the SUBSCRIPTION ARN (<topic ARN>:<uuid>).
  # The topic ARN is listed too because the reference names the topic as the (optional) resource type;
  # both forms name only this topic.
  statement {
    sid       = "AlertsTopicSubscriptionManage"
    effect    = "Allow"
    actions   = ["sns:Unsubscribe", "sns:GetSubscriptionAttributes"]
    resources = [aws_sns_topic.alerts.arn, "${aws_sns_topic.alerts.arn}:*"]
  }
}

resource "aws_iam_role_policy" "cis_ecs_task_alert_recipients" {
  name   = "aa-cis-${var.environment}-ecs-alert-recipients"
  role   = module.ecs.task_role_name
  policy = data.aws_iam_policy_document.cis_alert_recipients.json
}
