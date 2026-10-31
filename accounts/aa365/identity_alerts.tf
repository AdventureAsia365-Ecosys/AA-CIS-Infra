# =============================================================================
# AA-854 Phase 1 prerequisites (S242, plan step I1) — break-glass secret guard + alert.
# ADR 0006 decision 11: the break-glass password + TOTP seed in aa-identity/<env>/breakglass are
# "readable only by the admin role, retrieval alerted (CloudTrail -> email)".
#
#   1. aws_secretsmanager_secret_policy: explicit Deny of GetSecretValue / PutSecretValue for every
#      principal except the MFA admin role (aws:PrincipalArn). Nothing else is denied: Terraform
#      refresh needs DescribeSecret + GetResourcePolicy, and the CI apply role needs
#      UpdateSecret (tags, description) — it never reads or writes the value
#      (the value is set out-of-band; there is no aws_secretsmanager_secret_version for it).
#      AA-873 (S261 review fix): the apply boundary now denies PutResourcePolicy / DeleteResourcePolicy /
#      ReplicateSecretToRegions on aa-identity/* (DenyEcosystemGuardedSecretPolicyEdits, cicd_split.tf), so a
#      change to this resource policy is LOCAL-APPLY ONLY (MFA admin profile); the workload boundary denies
#      GetSecretValue on aa-identity/* to every bounded role (DenyEcosystemGuardedSecretValues).
#   2. EventBridge rule on the default bus: CloudTrail management events for the secret
#      (GetSecretValue / PutSecretValue, plus the calls that could bypass or weaken the guard) ->
#      SNS aws_sns_topic.alerts (e-mail). GetSecretValue is a READ-ONLY management event, which a
#      rule only receives in state ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS. Source: the
#      existing trail (observability.tf aws_cloudtrail.main, management events read + write).
#      CloudTrail -> EventBridge adds a few minutes of delay.
#   3. aws_sns_topic_policy for aws_sns_topic.alerts: the topic had only the AWS default policy
#      (read live 18/10/2026: one __default_statement_ID, no KMS). That statement is reproduced
#      verbatim so every CloudWatch alarm keeps publishing, plus one statement letting
#      events.amazonaws.com publish from the identity rules only. (AA-896, S243: plus one statement
#      letting costalerts.amazonaws.com publish Cost Anomaly Detection alerts, cost_anomaly.tf.)
#      (AA-913, S245: plus one statement letting budgets.amazonaws.com publish the AWS Budgets
#      notifications of this account, observability.tf. The default statement is left untouched:
#      CloudWatch alarms rely on it. It also lets any same-account principal Subscribe /
#      ListSubscriptionsByTopic; tightening that is a separate change.)
#   4. (AA-816, S243) Root ADR 0006a A8: EventBridge rule on CloudTrail AdminCreateUser on the
#      WORKFORCE pool with a temporary password, RESEND or no SUPPRESS -> the same SNS topic.
#
# Cost: rule + SNS e-mail + secret policy = $0/month (a handful of events).
# CI: the apply role needs events:* on rule/aa-identity-* (cicd_split.tf, Sid
# EventBridgeIdentityRuleManage) — a bootstrap grant applied locally with MFA first (AA-854 notes).
# =============================================================================

locals {
  # The role the aa365-admin / default CLI profiles assume (~/.aws/config role_arn, MFA). An
  # assumed-role session's aws:PrincipalArn is the role ARN, so this matches every session.
  id_breakglass_admin_role_arn = "arn:aws:iam::${var.account_id}:role/${var.identity_breakglass_admin_role_name}"

  # CloudTrail logs requestParameters.secretId exactly as the caller passed it: the name, the full
  # ARN (name + 6-char suffix) or a partial ARN. A prefix on the name and on the ARN covers all three.
  id_breakglass_secret_id_match = [
    { prefix = aws_secretsmanager_secret.identity_breakglass.name },
    { prefix = "arn:aws:secretsmanager:${var.aws_region}:${var.account_id}:secret:${aws_secretsmanager_secret.identity_breakglass.name}" },
  ]
}

# ── 1. Secret resource policy ────────────────────────────────────────────────
data "aws_iam_policy_document" "identity_breakglass_secret" {
  statement {
    sid       = "DenyValueAccessExceptAdminRole"
    effect    = "Deny"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:PutSecretValue"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "StringNotEquals"
      variable = "aws:PrincipalArn"
      values   = [local.id_breakglass_admin_role_arn]
    }
  }
}

resource "aws_secretsmanager_secret_policy" "identity_breakglass" {
  secret_arn          = aws_secretsmanager_secret.identity_breakglass.arn
  policy              = data.aws_iam_policy_document.identity_breakglass_secret.json
  block_public_policy = true
}

# ── 2. EventBridge rule -> SNS ───────────────────────────────────────────────
resource "aws_cloudwatch_event_rule" "identity_breakglass_secret" {
  name        = "${local.id_prefix}-breakglass-secret-access"
  description = "Break-glass secret ${aws_secretsmanager_secret.identity_breakglass.name}: value read/written or guard changed (CloudTrail). ADR 0006 decision 11, AA-854.${local.runbook_suffix.break_glass}"
  state       = "ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS"

  event_pattern = jsonencode({
    source        = ["aws.secretsmanager"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["secretsmanager.amazonaws.com"]
      "$or" = [
        {
          # Value access (the plan's two calls), a value write through UpdateSecret, removal or
          # replacement of the Deny policy above, and copying the value out of reach of this
          # us-west-1 rule/trail (ReplicateSecretToRegions) or into a rotation Lambda (RotateSecret).
          # Denied attempts match here too when CloudTrail logs requestParameters (errorCode set).
          eventName = [
            "GetSecretValue", "PutSecretValue", "UpdateSecret",
            "PutResourcePolicy", "DeleteResourcePolicy", "DeleteSecret", "RestoreSecret",
            "ReplicateSecretToRegions", "RotateSecret",
          ]
          requestParameters = { secretId = local.id_breakglass_secret_id_match }
        },
        {
          # BatchGetSecretValue by explicit id list (a filter-based batch is covered by the
          # per-secret GetSecretValue event CloudTrail also writes).
          eventName         = ["BatchGetSecretValue"]
          requestParameters = { secretIdList = local.id_breakglass_secret_id_match }
        },
      ]
    }
  })

  tags = local.id_tags
}

resource "aws_cloudwatch_event_target" "identity_breakglass_secret" {
  rule      = aws_cloudwatch_event_rule.identity_breakglass_secret.name
  target_id = "alerts-sns"
  arn       = aws_sns_topic.alerts.arn

  input_transformer {
    input_paths = {
      event     = "$.detail.eventName"
      principal = "$.detail.userIdentity.arn"
      ip        = "$.detail.sourceIPAddress"
      time      = "$.detail.eventTime"
      error     = "$.detail.errorCode"
    }
    input_template = "\"[aa-identity] Break-glass secret ${aws_secretsmanager_secret.identity_breakglass.name}: <event> by <principal> from <ip> at <time> (errorCode: <error>). If this was not a planned break-glass use or bootstrap, treat it as an incident (ADR 0006 decision 11).${local.runbook_suffix.break_glass}\""
  }
}

# ── 2b. Denied secret read whose secret CloudTrail does not name ─────────────
# S243 (AA-816 / AA-860 S19): CloudTrail logs an AccessDenied GetSecretValue/PutSecretValue WITHOUT
# requestParameters (verified live 19/10/2026: the X1 S19 checks from the CIS task role, denied by its
# identity policy, carry no secretId). Such a call cannot be tied to one secret, so it used to sit as a
# "safety net" branch of the break-glass rule above and every denied read of ANY secret was reported as
# "Break-glass secret aa-identity/dev/breakglass" — wrong. It is now its own rule with its own wording.
# Still alert on every one: after X1 S19 the CIS runtime has no reason to touch the master, db-migrator,
# booking/* or tripplanner/* secrets, so a denied read is either a planned test or worth a look.
# Cost: EventBridge rules on AWS service (CloudTrail) events are free; SNS email stays in the free tier.
resource "aws_cloudwatch_event_rule" "identity_denied_secret_read" {
  name        = "${local.id_prefix}-denied-secret-read"
  description = "A Secrets Manager value read/write was DENIED and CloudTrail did not log which secret (may include the break-glass secret). S243, ADR 0006 decision 11.${local.runbook_suffix.incident}"
  state       = "ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS"

  event_pattern = jsonencode({
    source        = ["aws.secretsmanager"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource       = ["secretsmanager.amazonaws.com"]
      eventName         = ["GetSecretValue", "PutSecretValue"]
      errorCode         = [{ prefix = "AccessDenied" }]
      requestParameters = { secretId = [{ exists = false }] }
    }
  })

  tags = local.id_tags
}

resource "aws_cloudwatch_event_target" "identity_denied_secret_read" {
  rule      = aws_cloudwatch_event_rule.identity_denied_secret_read.name
  target_id = "alerts-sns"
  arn       = aws_sns_topic.alerts.arn

  input_transformer {
    input_paths = {
      event     = "$.detail.eventName"
      principal = "$.detail.userIdentity.arn"
      ip        = "$.detail.sourceIPAddress"
      time      = "$.detail.eventTime"
      error     = "$.detail.errorCode"
    }
    input_template = "\"[aa-identity] Denied secret access: <event> by <principal> from <ip> at <time> (errorCode: <error>). CloudTrail does not log which secret a denied call asked for, so it may be any protected secret, including the break-glass one. Planned test (e.g. an X1 S19 deny check)? Nothing to do. Otherwise check who made the call (CloudTrail, same time) and treat an unknown principal as an incident (ADR 0006 decision 11).${local.runbook_suffix.incident}\""
  }
}

# ── 3. Alerts topic policy (default statement + EventBridge) ─────────────────
data "aws_iam_policy_document" "alerts_topic" {
  policy_id = "__default_policy_ID"

  # The AWS default topic policy, unchanged (CloudWatch alarms and same-account publishers).
  statement {
    sid    = "__default_statement_ID"
    effect = "Allow"
    actions = [
      "SNS:GetTopicAttributes", "SNS:SetTopicAttributes", "SNS:AddPermission",
      "SNS:RemovePermission", "SNS:DeleteTopic", "SNS:Subscribe",
      "SNS:ListSubscriptionsByTopic", "SNS:Publish",
    ]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceOwner"
      values   = [var.account_id]
    }
  }

  statement {
    sid       = "AllowIdentityEventBridgeRules"
    effect    = "Allow"
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:events:${var.aws_region}:${var.account_id}:rule/${local.id_prefix}-*"]
    }
  }

  # AA-932: the CRM KMS key alarms (crm_data.tf, rules aa-crm-<env>-kms-*).
  statement {
    sid       = "AllowCrmEventBridgeRules"
    effect    = "Allow"
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:events:${var.aws_region}:${var.account_id}:rule/${local.crm_name_prefix}-*"]
    }
  }

  # AA-873 (S255): the account security baseline rules (security_baseline.tf, rules aa-sec-<env>-*; the GuardDuty
  # finding rule of security_guardduty.tf uses the same prefix).
  statement {
    sid       = "AllowSecurityEventBridgeRules"
    effect    = "Allow"
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:events:${var.aws_region}:${var.account_id}:rule/${local.sec_prefix}-*"]
    }
  }

  # AA-896 (S243): AWS Cost Anomaly Detection publishes IMMEDIATE alerts here (cost_anomaly.tf).
  # Statement from the AWS guide "Creating an Amazon SNS topic for anomaly notifications", limited to
  # subscriptions owned by this account.
  statement {
    sid       = "AllowCostAnomalyDetection"
    effect    = "Allow"
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["costalerts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }

  # AA-913: AWS Budgets publish their notifications here (observability.tf), limited to this account's budgets.
  # Statement from the AWS guide "Creating an Amazon SNS topic for budget notifications".
  statement {
    sid       = "AllowBudgets"
    effect    = "Allow"
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:budgets::${var.account_id}:*"]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts_topic.json
}

# ── 4. A8 detective alarm: AdminCreateUser with a caller-set password ────────
# Root ADR 0006a A8 (AA-816, S243): IAM cannot constrain the AdminCreateUser parameters, so this
# rule e-mails on any WORKFORCE AdminCreateUser that does not look like a legitimate create
# (legitimate creates send MessageAction=SUPPRESS and no TemporaryPassword). Residual risk: Linear AA-873.
#
# CloudTrail shape (read live 19/10/2026, 3 AdminCreateUser events of 18/10): requestParameters
# carries userPoolId and messageAction in clear; username / userAttributes (and, by the same rule,
# temporaryPassword) are "HIDDEN_DUE_TO_SECURITY_REASONS". A hidden value still has its key, so
# `exists: true` matches it. Branches:
#   a. temporaryPassword present (any value);
#   b. messageAction is anything but SUPPRESS (RESEND, or any future value);
#   c. messageAction absent: Cognito then mails its own invite with a generated temporary password,
#      which bypasses the SUPPRESS rule (identity.tf header) even though it needs the mailbox.
# Denied attempts match too (no errorCode filter): an AccessDenied AdminCreateUser on this pool is
# itself worth an e-mail.
#
# AdminCreateUser is a WRITE management event, so the default state ENABLED receives it (the
# read-only-events state above is only needed for GetSecretValue). Same trail (aws_cloudtrail.main,
# us-west-1, the pool's region), same SNS topic; the topic policy statement
# AllowIdentityEventBridgeRules already allows rule/aa-identity-dev-*, and the CI apply role's
# EventBridgeIdentityRuleManage already covers rule/aa-identity-* (no new grant, no MFA apply).
# Cost: $0/month (no events expected).
resource "aws_cloudwatch_event_rule" "identity_workforce_admincreateuser_password" {
  name        = "${local.id_prefix}-workforce-admincreateuser-password"
  description = "WORKFORCE AdminCreateUser with a temporary password, RESEND or no SUPPRESS (CloudTrail). Root ADR 0006a A8, AA-816.${local.runbook_suffix.incident}"
  state       = "ENABLED"

  event_pattern = jsonencode({
    source        = ["aws.cognito-idp"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["cognito-idp.amazonaws.com"]
      eventName   = ["AdminCreateUser"]
      requestParameters = {
        userPoolId = [aws_cognito_user_pool.workforce.id]
        "$or" = [
          { temporaryPassword = [{ exists = true }] },
          { messageAction = [{ "anything-but" = "SUPPRESS" }] },
          { messageAction = [{ exists = false }] },
        ]
      }
    }
  })

  tags = local.id_tags
}

resource "aws_cloudwatch_event_target" "identity_workforce_admincreateuser_password" {
  rule      = aws_cloudwatch_event_rule.identity_workforce_admincreateuser_password.name
  target_id = "alerts-sns"
  arn       = aws_sns_topic.alerts.arn

  input_transformer {
    # temporaryPassword prints as HIDDEN_DUE_TO_SECURITY_REASONS when set (CloudTrail masks it) and
    # empty when absent; the username is masked by CloudTrail, so look the user up by event time.
    input_paths = {
      principal = "$.detail.userIdentity.arn"
      ip        = "$.detail.sourceIPAddress"
      time      = "$.detail.eventTime"
      action    = "$.detail.requestParameters.messageAction"
      temp      = "$.detail.requestParameters.temporaryPassword"
      error     = "$.detail.errorCode"
    }
    input_template = "\"[aa-identity] WORKFORCE pool ${aws_cognito_user_pool.workforce.id}: AdminCreateUser by <principal> from <ip> at <time> with messageAction=<action> temporaryPassword=<temp> (errorCode: <error>). Staff users are always created with SUPPRESS and no password, so unless this was a planned admin action, treat it as an incident: find the user created at that time (ListUsers, UserCreateDate), disable it and sign it out everywhere (root ADR 0006a A8).${local.runbook_suffix.incident}\""
  }
}
