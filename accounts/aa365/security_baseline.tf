# =============================================================================
# AA-873 PR 1 of 3 (S255) — account security baseline, the free items.
#
# Live state read 28/10/2026 (acc2, us-west-1, read-only; root audit docs/audits/2026-10-28-S255-finops-security/ §7):
#   S3 account BPA: NoSuchPublicAccessBlockConfiguration. All 16 buckets already have bucket-level BPA 4/4 and no
#   public bucket policy, so the account switch breaks nothing.
#   IAM Access Analyzer: 0 analyzers. GuardDuty: 0 detectors (PR 3). CloudTrail: single region, no KMS (PR 2).
#   Alerts on root use, IAM changes, security-group changes or trail tampering: none.
#
# What this file adds:
#   1. aws_s3_account_public_access_block: all four flags on (account level).
#   2. IAM Access Analyzer, external access, zone of trust = this account, + an EventBridge rule on new ACTIVE
#      findings. The "unused access" analyzer (0.20 USD per role/user per month) is NOT created.
#   3. EventBridge rules on CloudTrail events -> the alerts SNS topic (same pattern as identity_alerts.tf):
#      trail tamper, security-group change, IAM change, root activity. Changes made by the Terraform apply role are
#      not alerted for SG and IAM (they are the expected path); trail tampering and root use always alert.
#   4. IAM and root sign-in are global-service events that reach EventBridge only in us-east-1. A us-east-1 rule
#      forwards them (write calls only, plus every root event) to the us-west-1 default bus through a small role;
#      the rules of item 3 then match them like local events. Until the trail is multi-region (AA-873 PR 2,
#      security_cloudtrail.tf) CloudTrail may not deliver us-east-1 events to EventBridge there, so the IAM/root
#      alerts are proven only after PR 2 (Done-when test below).
#
# Cost: 0 USD/month. BPA and the external-access analyzer are free; EventBridge rules on AWS service events are
# free; the cross-region forward is billed as custom events (1 USD per million; a few hundred IAM writes a month);
# SNS e-mail stays in the free tier.
#
# Apply: the apply role needs the AA-873 bootstrap grants in cicd_sec.tf (Access Analyzer, the events rule
# pattern aa-sec-*, the service-linked roles). They are a bootstrap object: apply them locally with the MFA admin
# profile first (targeted aws_iam_role_policy.tf_apply), then let CI apply the rest. The alerts topic policy gains
# the statement AllowSecurityEventBridgeRules (identity_alerts.tf), applied by CI with this file.
#
# Done-when test (orchestrator, after PR 2 is applied too): create and delete a throwaway IAM policy with the MFA
# admin session -> one "[aa-sec] iam_change" e-mail per call within a few minutes; run
# `aws ec2 describe-security-groups` (no alert: read-only) and add + revoke a rule on a throwaway SG -> "sg_change".
# =============================================================================

locals {
  sec_prefix = "aa-sec-${var.environment}"
  sec_tags   = merge(local.shared_tags, { Issue = "AA-873" })

  # Principals whose IAM / security-group changes are expected (Terraform CI apply). Every other assumed role (the
  # MFA admin role included: a local bootstrap apply also alerts, which is fine) and every IAM user alerts.
  sec_expected_change_roles = [local.tf_apply_role_name]

  # Not alerted when the change comes from one of the roles above. An assumed role carries
  # userIdentity.sessionContext.sessionIssuer.userName; an IAM user has none, so it needs its own branch
  # (anything-but alone never matches a missing field).
  sec_unexpected_principal = [
    { userIdentity = { sessionContext = { sessionIssuer = { userName = [{ "anything-but" = local.sec_expected_change_roles }] } } } },
    { userIdentity = { type = ["IAMUser"] } },
  ]

  sec_alert_footer = "Expected only from Terraform or a planned change; otherwise treat it as an incident (AA-873)."
}

# ── 1. S3 Block Public Access, account level ────────────────────────────────
resource "aws_s3_account_public_access_block" "this" {
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# ── 2. IAM Access Analyzer (external access) ────────────────────────────────
resource "aws_accessanalyzer_analyzer" "external" {
  analyzer_name = "${local.sec_prefix}-external-access"
  type          = "ACCOUNT"
  tags          = local.sec_tags
}

resource "aws_cloudwatch_event_rule" "sec_access_analyzer_finding" {
  name        = "${local.sec_prefix}-access-analyzer-finding"
  description = "IAM Access Analyzer: a new ACTIVE external-access finding. AA-873.${local.runbook_suffix.incident}"
  event_pattern = jsonencode({
    source        = ["aws.access-analyzer"]
    "detail-type" = ["Access Analyzer Finding"]
    detail        = { status = ["ACTIVE"] }
  })
  tags = local.sec_tags
}

resource "aws_cloudwatch_event_target" "sec_access_analyzer_finding" {
  rule      = aws_cloudwatch_event_rule.sec_access_analyzer_finding.name
  target_id = "alerts-sns"
  arn       = aws_sns_topic.alerts.arn

  # Only scalar fields: an object inserted into a quoted template would break the JSON string.
  input_transformer {
    input_paths = {
      id       = "$.detail.id"
      resource = "$.detail.resource"
      type     = "$.detail.resourceType"
      public   = "$.detail.isPublic"
    }
    input_template = "\"[aa-sec] access_analyzer: <type> <resource> is reachable from outside the account (public: <public>, finding <id>). Archive the finding if intended, else fix the policy (AA-873).${local.runbook_suffix.incident}\""
  }
}

# ── 3. Alerts on CloudTrail management events ───────────────────────────────
resource "aws_cloudwatch_event_rule" "sec_trail_tamper" {
  name        = "${local.sec_prefix}-cloudtrail-tamper"
  description = "CloudTrail stopped, deleted or reconfigured (any principal). AA-873.${local.runbook_suffix.incident}"
  event_pattern = jsonencode({
    source        = ["aws.cloudtrail"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventName = ["StopLogging", "DeleteTrail", "UpdateTrail", "PutEventSelectors", "PutInsightSelectors", "DeleteEventDataStore"]
    }
  })
  tags = local.sec_tags
}

resource "aws_cloudwatch_event_rule" "sec_sg_change" {
  name        = "${local.sec_prefix}-security-group-change"
  description = "Security group created, deleted or changed outside the Terraform apply role. AA-873.${local.runbook_suffix.incident}"
  event_pattern = jsonencode({
    source        = ["aws.ec2"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventName = [
        "AuthorizeSecurityGroupIngress", "AuthorizeSecurityGroupEgress", "RevokeSecurityGroupIngress",
        "RevokeSecurityGroupEgress", "CreateSecurityGroup", "DeleteSecurityGroup", "ModifySecurityGroupRules",
      ]
      "$or" = local.sec_unexpected_principal
    }
  })
  tags = local.sec_tags
}

resource "aws_cloudwatch_event_rule" "sec_iam_change" {
  name        = "${local.sec_prefix}-iam-change"
  description = "IAM user/role/policy/key change outside the Terraform apply role (forwarded from us-east-1). AA-873.${local.runbook_suffix.incident}"
  event_pattern = jsonencode({
    source        = ["aws.iam"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventName = [
        { prefix = "Create" }, { prefix = "Delete" }, { prefix = "Attach" }, { prefix = "Detach" },
        { prefix = "Put" }, { prefix = "Update" }, { prefix = "Add" }, { prefix = "Remove" },
        "DeactivateMFADevice", "EnableMFADevice", "ResyncMFADevice", "SetDefaultPolicyVersion",
      ]
      "$or" = local.sec_unexpected_principal
    }
  })
  tags = local.sec_tags
}

# Root: any API call (read-only ones too) or console sign-in. Root has no sessionIssuer, so it is its own rule.
resource "aws_cloudwatch_event_rule" "sec_root_activity" {
  name        = "${local.sec_prefix}-root-activity"
  description = "Any root user activity, console sign-in included (local or forwarded from us-east-1). AA-873.${local.runbook_suffix.incident}"
  state       = "ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS"
  event_pattern = jsonencode({
    "detail-type" = ["AWS API Call via CloudTrail", "AWS Console Sign In via CloudTrail"]
    detail        = { userIdentity = { type = ["Root"] } }
  })
  tags = local.sec_tags
}

locals {
  sec_cloudtrail_rules = {
    trail_tamper = aws_cloudwatch_event_rule.sec_trail_tamper.name
    sg_change    = aws_cloudwatch_event_rule.sec_sg_change.name
    iam_change   = aws_cloudwatch_event_rule.sec_iam_change.name
    root         = aws_cloudwatch_event_rule.sec_root_activity.name
  }
}

resource "aws_cloudwatch_event_target" "sec_cloudtrail_rules" {
  for_each  = local.sec_cloudtrail_rules
  rule      = each.value
  target_id = "alerts-sns"
  arn       = aws_sns_topic.alerts.arn

  input_transformer {
    input_paths = {
      event     = "$.detail.eventName"
      principal = "$.detail.userIdentity.arn"
      ip        = "$.detail.sourceIPAddress"
      region    = "$.detail.awsRegion"
      time      = "$.detail.eventTime"
      error     = "$.detail.errorCode"
    }
    input_template = "\"[aa-sec] ${each.key}: <event> by <principal> from <ip> in <region> at <time> (errorCode: <error>). ${local.sec_alert_footer}${local.runbook_suffix.incident}\""
  }
}

# ── 4. us-east-1 forwarder for global-service events ────────────────────────
data "aws_iam_policy_document" "sec_forwarder_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }
}

resource "aws_iam_role" "sec_forwarder" {
  name                 = "${local.sec_prefix}-events-forwarder"
  description          = "AA-873: EventBridge us-east-1 -> ${var.aws_region} default bus (IAM and root events)"
  assume_role_policy   = data.aws_iam_policy_document.sec_forwarder_trust.json
  permissions_boundary = aws_iam_policy.workload_boundary.arn
  tags                 = local.sec_tags
}

resource "aws_iam_role_policy" "sec_forwarder" {
  name = "put-events-${var.aws_region}-default-bus"
  role = aws_iam_role.sec_forwarder.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "events:PutEvents"
      Resource = "arn:aws:events:${var.aws_region}:${var.account_id}:event-bus/default"
    }]
  })
}

# Write calls of IAM (readOnly = false keeps the thousands of daily Get/List reads of Terraform plan out of the
# forward) and every root event. The state with all management events is needed for root read-only calls.
resource "aws_cloudwatch_event_rule" "sec_global_forward" {
  provider    = aws.us_east_1
  name        = "${local.sec_prefix}-global-forward"
  description = "Forward IAM write calls and root activity (global services, us-east-1 only) to ${var.aws_region}. AA-873."
  state       = "ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS"
  event_pattern = jsonencode({
    "$or" = [
      { source = ["aws.iam"], "detail-type" = ["AWS API Call via CloudTrail"], detail = { readOnly = [false] } },
      { "detail-type" = ["AWS API Call via CloudTrail", "AWS Console Sign In via CloudTrail"], detail = { userIdentity = { type = ["Root"] } } },
    ]
  })
  tags = local.sec_tags
}

resource "aws_cloudwatch_event_target" "sec_global_forward" {
  provider  = aws.us_east_1
  rule      = aws_cloudwatch_event_rule.sec_global_forward.name
  target_id = "${replace(var.aws_region, "-", "")}-default-bus"
  arn       = "arn:aws:events:${var.aws_region}:${var.account_id}:event-bus/default"
  role_arn  = aws_iam_role.sec_forwarder.arn
}
