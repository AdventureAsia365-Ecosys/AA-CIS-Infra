# =============================================================================
# AA-1022 / AA-873 N17 (S263) — e-mail on every IAM Identity Center ADMINISTRATOR session in this account.
#
# Who signs in through Identity Center: an Identity Center permission set appears in a member account as an IAM role
# aws-reserved/sso.amazonaws.com/[<region>/]AWSReservedSSO_<PermissionSet>_<hash>, trusted through the
# AWSSSO_..._DO_NOT_DELETE SAML provider. Every session on such a role, console or CLI, starts with one STS
# AssumeRoleWithSAML call recorded in this account. The permission sets alerted on are local.sec_sso_admin_permission_sets:
#   - AdministratorAccess: the permission set of the organization this account belongs to today (seen in CloudTrail
#     and in the Access Analyzer triage, security_access_analyzer_archive.tf);
#   - AA-Admin: the administrator permission set of the AA organization (accounts/management/identity_center.tf), for
#     when this account joins it (root ADR 0018).
# Other permission sets (AA-Developer, AA-ReadOnly) are not alerted on.
#
# Which event, and where it lands (CloudTrail lookup-events on this account, 90 days, read 01/11/2026):
#   - AssumeRoleWithSAML for the AdministratorAccess role: 10 events, all in us-east-1 (Identity Center calls the
#     global STS endpoint). 8 of them were followed one second later by a ConsoleLogin event (console sessions); 2
#     had no ConsoleLogin (CLI / SDK sessions). AssumeRoleWithSAML is therefore the one event that covers both
#     paths, once per session; alerting on ConsoleLogin as well would send two e-mails per console sign-in.
#   - AssumeRoleWithSAML is a READ-ONLY management event (readOnly = true), so both rules below use the state
#     ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS: a rule in the default ENABLED state never sees read-only events.
#   - EventBridge rules are regional and a CloudTrail event reaches only the bus of the region it was recorded in.
#     The us-west-1 rules below match local events (an Identity Center instance that calls the regional STS endpoint
#     of this region) and the events the existing us-east-1 forwarder sends here (security_baseline.tf,
#     aws_cloudwatch_event_rule.sec_global_forward, whose pattern gains the same SAML branch). Console sign-in events
#     (ConsoleLogin) of this account landed in us-east-1, us-east-2 and us-west-2 in the same 90 days; they are not
#     used here.
#
# The e-mail: the input transformer passes only the session name (the Identity Center user name), the region, the
# time and the error code. No role ARN, SAML provider ARN or account id: those fields are never read, so they cannot
# reach the mail body. The permission set is named in the template (one rule per permission set).
#
# Cost: 0 USD/month. Rules on AWS service events are free; the forward from us-east-1 is billed as custom events
# (1 USD per million; a handful of sessions a month); SNS e-mail stays in the free tier.
# Apply: CI (rules aa-sec-* in both regions: cicd_sec.tf SecEventRuleManage; topic policy AllowSecurityEventBridgeRules
# in identity_alerts.tf already admits rules named local.sec_prefix-*).
# =============================================================================

locals {
  # Key = rule-name suffix, value = permission set name as it appears in the role name AWSReservedSSO_<name>_<hash>.
  sec_sso_admin_permission_sets = {
    administratoraccess = "AdministratorAccess"
    aa-admin            = "AA-Admin"
  }

  # Matches the role in the default path and in the regional path (aws-reserved/sso.amazonaws.com/<region>/...).
  sec_sso_admin_role_arn_patterns = {
    for k, ps in local.sec_sso_admin_permission_sets :
    k => "arn:aws:iam::*:role/aws-reserved/sso.amazonaws.com/*AWSReservedSSO_${ps}_*"
  }

  sec_sso_signin_footer = "Expected only when the tech lead signs in; otherwise treat it as an incident and check the Identity Center sign-in history (AA-1022)."
}

resource "aws_cloudwatch_event_rule" "sec_sso_admin_signin" {
  for_each = local.sec_sso_admin_permission_sets

  name        = "${local.sec_prefix}-sso-admin-signin-${each.key}"
  description = "Identity Center session on the ${each.value} permission set (AssumeRoleWithSAML; local or forwarded from us-east-1). AA-1022.${local.runbook_suffix.incident}"
  state       = "ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS"
  event_pattern = jsonencode({
    source        = ["aws.sts"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource       = ["sts.amazonaws.com"]
      eventName         = ["AssumeRoleWithSAML"]
      requestParameters = { roleArn = [{ wildcard = local.sec_sso_admin_role_arn_patterns[each.key] }] }
    }
  })
  tags = merge(local.sec_tags, { Issue = "AA-1022" })
}

resource "aws_cloudwatch_event_target" "sec_sso_admin_signin" {
  for_each = local.sec_sso_admin_permission_sets

  rule      = aws_cloudwatch_event_rule.sec_sso_admin_signin[each.key].name
  target_id = "alerts-sns"
  arn       = aws_sns_topic.alerts.arn

  # Scalar fields only, and none that holds an ARN or an account id (see the header).
  input_transformer {
    input_paths = {
      session = "$.detail.requestParameters.roleSessionName"
      region  = "$.detail.awsRegion"
      time    = "$.detail.eventTime"
      error   = "$.detail.errorCode"
    }
    input_template = "\"[aa-sec] sso_admin_signin: Identity Center session '<session>' on the ${each.value} permission set started in <region> at <time> (errorCode: <error>). ${local.sec_sso_signin_footer}${local.runbook_suffix.incident}\""
  }
}
