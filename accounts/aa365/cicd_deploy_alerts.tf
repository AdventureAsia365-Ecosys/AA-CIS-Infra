# =============================================================================
# AA-1193 (S297; S295 Well-Architected review OPS06) — the API deploy workflows alert the ops topic after a red
# post-deploy verify.
#
# deploy-dev.yml of AA-CIS-App (api + worker), AA-Booking (api) and AA-Partner (CRM api) now roll the service back to
# the revision it ran before the deploy when the post-deploy verify is red, then publish ONE message on the alerts
# topic (aws_sns_topic.alerts, observability.tf: the topic of every alarm and in-app check, same recipients): the app,
# the commit, the failing checks, the rollback outcome and the run link (.github/scripts/ecs_api_rollback.py alert).
# The rollback itself needs no new grant: each deploy role already describes, lists, updates its own services and
# reads its own ECR repository (the AA-1119 web rollback uses the same calls).
#
# The workflow reads the topic ARN from the ALERTS_TOPIC_ARN environment entry of the task definition the service
# runs, so no GitHub setting holds it. The topic's default statement admits this account's principals
# (identity_alerts.tf data.aws_iam_policy_document.alerts_topic); these policies are the IAM side, sns:Publish on that
# one topic only (not the page topic: a red Dev deploy is ticket severity, alert_severity.tf rule D5).
#
# APPLY ORDER: aa-cis-dev-app-deploy is a bootstrap role, denied to the CI apply role (cicd_split.tf
# tf_apply_protected_role_arns), so `aws_iam_role_policy.cis_app_deploy_publish_alerts` is applied locally with the MFA
# admin profile (-target, like cicd_split.tf cis_app_deploy_staff_web). The Booking and CRM deploy roles are ordinary
# module roles: Terraform Apply in CI applies those two. Until applied, the workflows log "alert not sent" as a warning
# and still open their deploy-smoke-red issue.
#
# COST: 0 USD (SNS: the first 1,000 e-mail notifications a month are free; one message per red deploy).
# =============================================================================

data "aws_iam_policy_document" "deploy_publish_alerts" {
  statement {
    sid       = "PublishDeployRollbackAlerts"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
  }
}

# BOOTSTRAP (local MFA apply, see APPLY ORDER above).
resource "aws_iam_role_policy" "cis_app_deploy_publish_alerts" {
  name   = "${local.app_deploy_role_name}-publish-alerts"
  role   = aws_iam_role.cis_app_deploy.id
  policy = data.aws_iam_policy_document.deploy_publish_alerts.json
}

resource "aws_iam_role_policy" "booking_app_deploy_publish_alerts" {
  name   = "${local.bk_name_prefix}-app-deploy-publish-alerts"
  role   = element(split("/", module.environment.booking_app_deploy_role_arn), 1)
  policy = data.aws_iam_policy_document.deploy_publish_alerts.json
}

resource "aws_iam_role_policy" "crm_app_deploy_publish_alerts" {
  name   = "${local.crm_name_prefix}-app-deploy-publish-alerts"
  role   = element(split("/", module.environment.crm_app_deploy_role_arn), 1)
  policy = data.aws_iam_policy_document.deploy_publish_alerts.json
}
