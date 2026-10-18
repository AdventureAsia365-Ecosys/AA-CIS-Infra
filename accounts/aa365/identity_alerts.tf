# =============================================================================
# AA-854 Phase 1 prerequisites (S242, plan step I1) — break-glass secret guard + alert.
# ADR 0006 decision 11: the break-glass password + TOTP seed in aa-identity/<env>/breakglass are
# "readable only by the admin role, retrieval alerted (CloudTrail -> email)".
#
#   1. aws_secretsmanager_secret_policy: explicit Deny of GetSecretValue / PutSecretValue for every
#      principal except the MFA admin role (aws:PrincipalArn). Nothing else is denied: Terraform
#      refresh needs DescribeSecret + GetResourcePolicy, and the CI apply role needs
#      PutResourcePolicy / UpdateSecret (tags, description) — it never reads or writes the value
#      (the value is set out-of-band; there is no aws_secretsmanager_secret_version for it).
#   2. EventBridge rule on the default bus: CloudTrail management events for the secret
#      (GetSecretValue / PutSecretValue, plus the calls that could bypass or weaken the guard) ->
#      SNS aws_sns_topic.alerts (e-mail). GetSecretValue is a READ-ONLY management event, which a
#      rule only receives in state ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS. Source: the
#      existing trail (observability.tf aws_cloudtrail.main, management events read + write).
#      CloudTrail -> EventBridge adds a few minutes of delay.
#   3. aws_sns_topic_policy for aws_sns_topic.alerts: the topic had only the AWS default policy
#      (read live 18/10/2026: one __default_statement_ID, no KMS). That statement is reproduced
#      verbatim so every CloudWatch alarm keeps publishing, plus one statement letting
#      events.amazonaws.com publish from the identity rules only.
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
  description = "Break-glass secret ${aws_secretsmanager_secret.identity_breakglass.name}: value read/written or guard changed (CloudTrail). ADR 0006 decision 11, AA-854."
  state       = "ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS"

  event_pattern = jsonencode({
    source        = ["aws.secretsmanager"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["secretsmanager.amazonaws.com"]
      "$or" = [
        {
          # Value access (the plan's two calls), a value write through UpdateSecret, and removal or
          # replacement of the Deny policy above. Denied attempts are logged too (errorCode set).
          eventName = [
            "GetSecretValue", "PutSecretValue", "UpdateSecret",
            "PutResourcePolicy", "DeleteResourcePolicy", "DeleteSecret", "RestoreSecret",
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
    input_template = "\"[aa-identity] Break-glass secret ${aws_secretsmanager_secret.identity_breakglass.name}: <event> by <principal> from <ip> at <time> (errorCode: <error>). If this was not a planned break-glass use or bootstrap, treat it as an incident (ADR 0006 decision 11).\""
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
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts_topic.json
}
