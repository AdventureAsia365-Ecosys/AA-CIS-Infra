# =============================================================================
# AA-873 (S255) — apply-role grants for the account security baseline. BOOTSTRAP OBJECT.
#
# Covers the three AA-873 PRs in one local MFA apply: security_baseline.tf (PR 1: account BPA, IAM Access Analyzer,
# EventBridge alert rules + us-east-1 forwarder), security_cloudtrail.tf (PR 2: CloudTrail KMS key, multi-region
# trail, trail bucket versioning / Object Lock) and security_guardduty.tf (PR 3: GuardDuty behind
# var.guardduty_enabled), plus the public AMI parameter read of the NAT AMI fix (modules/vpc).
#
# Why a customer managed policy and not more inline statements: the apply role's inline policy renders to 8,963 of
# the 10,240 characters every inline policy of a role shares (terraform console on main 82400b9, 28/10/2026); these
# grants would take it to ~10,150, leaving no room for the next change. The role already has the default quota of 10
# managed policies, so AmazonSQSFullAccess (sqs:* on *, needed only for the ACP bus DLQ of modules/eventbridge) moves
# into this policy unchanged (Sid SqsManage) and frees its slot, like AWSStepFunctionsFullAccess did for
# aa-cis-infra-tf-apply-crm (cicd_crm.tf). The apply role has no iam:CreatePolicy / CreatePolicyVersion and the
# apply boundary denies version edits on this policy (DenyBoundaryPolicyEdits, cicd_split.tf): CI cannot widen it.
#
# Already granted elsewhere, nothing added here: S3 account BPA, bucket versioning, Object Lock and lifecycle
# (AmazonS3FullAccess); CloudTrail UpdateTrail (cicd.tf CloudTrailManage); the forwarder role aa-sec-<env>-* (inside
# tf_managed_role_arns, IAMRoleManageStack, workload boundary required); kms:ListKeys / ListAliases (cicd_crm.tf
# KmsList). The plan role reads everything through ReadOnlyAccess.
#
# What CI may NOT do on the CloudTrail key (no grant here): PutKeyPolicy, ScheduleKeyDeletion, DisableKey,
# CreateGrant or any crypto use. CreateKey carries the key policy, so creating the key goes through CI; a later key
# policy change or a key deletion is a local MFA apply.
#
# Apply (orchestrator, local, MFA admin profile, from main after merge):
#   1. terraform plan, then apply, with -target=aws_iam_policy.tf_apply_sec
#        -target=aws_iam_role_policy_attachment.tf_apply_managed -target=aws_iam_role_policy_attachment.tf_apply_sec
#        -target=aws_iam_policy.tf_apply_boundary
#      Expect: 1 policy + 1 attachment to add, 1 attachment (AmazonSQSFullAccess) to destroy, the boundary in place.
#   2. If the attach fails with LimitExceeded (11 attachments for a moment: create and destroy run in parallel),
#      run the same targeted apply again: the detach has finished by then. Then the same targeted plan: No changes.
# Cost: 0 USD (IAM).
# =============================================================================

locals {
  # Services whose service-linked role the apply role may create on first use.
  sec_slr_services = ["access-analyzer.amazonaws.com", "guardduty.amazonaws.com"]
}

data "aws_iam_policy_document" "tf_apply_sec" {
  # Moved unchanged from the AWS managed AmazonSQSFullAccess (its whole policy: sqs:* on *).
  statement {
    sid       = "SqsManage"
    actions   = ["sqs:*"]
    resources = ["*"]
  }

  # PR 1: IAM Access Analyzer (Create/Get/Update/DeleteAnalyzer, Tag/Untag/ListTagsForResource).
  statement {
    sid       = "AccessAnalyzerManage"
    actions   = ["access-analyzer:*Analyzer", "access-analyzer:*Resource"]
    resources = ["arn:aws:access-analyzer:${var.aws_region}:${var.account_id}:analyzer/*"]
  }

  # PR 1 + PR 3: EventBridge rules aa-sec-* on the default bus, in us-west-1 and (forwarder) us-east-1.
  statement {
    sid = "SecEventRuleManage"
    actions = [
      "events:PutRule", "events:DeleteRule", "events:DescribeRule", "events:EnableRule",
      "events:DisableRule", "events:PutTargets", "events:RemoveTargets", "events:ListTargetsByRule",
      "events:TagResource", "events:UntagResource", "events:ListTagsForResource",
    ]
    resources = ["arn:aws:events:*:${var.account_id}:rule/aa-sec-*"]
  }

  # PR 1 + PR 3: the Access Analyzer and GuardDuty service-linked roles, created on the first CreateAnalyzer /
  # CreateDetector. Only those two services.
  statement {
    sid       = "SecServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = [for s in local.sec_slr_services : "arn:aws:iam::${var.account_id}:role/aws-service-role/${s}/*"]
    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = local.sec_slr_services
    }
  }

  # NAT AMI fix (modules/vpc, S255 finding F-4): data.aws_ssm_parameter.nat_al2023_arm64 reads the public AL2023 AMI
  # parameter on refresh. AmazonECS_FullAccess only covers /aws/service/ecs*. Public AWS parameters live in an AWS
  # account, so the ARN has no account id.
  statement {
    sid       = "PublicAmiParameterRead"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["arn:aws:ssm:${var.aws_region}::parameter/aws/service/ami-amazon-linux-latest/*"]
  }

  # PR 3: GuardDuty detector, its features (UpdateDetector) and tags. CreateDetector takes no resource ARN.
  statement {
    sid       = "GuardDutyDetectorManage"
    actions   = ["guardduty:*Detector*", "guardduty:*Resource"]
    resources = ["*"]
  }

  # PR 2: the CloudTrail key, created only with the App = shared tag (CreateKey with Tags also needs TagResource).
  statement {
    sid       = "SharedKmsCreateTagged"
    actions   = ["kms:CreateKey", "kms:TagResource"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/App"
      values   = ["shared"]
    }
  }

  # PR 2: refresh and the non-destructive admin verbs on App = shared keys (see the header for what is left out).
  statement {
    sid = "SharedKmsManageTagged"
    actions = [
      "kms:DescribeKey", "kms:GetKeyPolicy", "kms:GetKeyRotationStatus", "kms:ListKeyPolicies",
      "kms:ListResourceTags", "kms:EnableKeyRotation", "kms:UpdateKeyDescription", "kms:CancelKeyDeletion",
      "kms:CreateAlias", "kms:DeleteAlias", "kms:UpdateAlias",
    ]
    resources = ["arn:aws:kms:${var.aws_region}:${var.account_id}:key/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/App"
      values   = ["shared"]
    }
  }

  # Untag anything on a shared key except the App key itself (removing it would take the key out of scope above).
  statement {
    sid       = "SharedKmsUntagExceptApp"
    actions   = ["kms:UntagResource"]
    resources = ["arn:aws:kms:${var.aws_region}:${var.account_id}:key/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/App"
      values   = ["shared"]
    }
    condition {
      test     = "ForAllValues:StringNotEquals"
      variable = "aws:TagKeys"
      values   = ["App"]
    }
  }

  # PR 2: alias verbs are checked on the alias too (an alias has no tags): only aliases of this stack.
  statement {
    sid       = "SharedKmsAlias"
    actions   = ["kms:CreateAlias", "kms:DeleteAlias", "kms:UpdateAlias"]
    resources = ["arn:aws:kms:${var.aws_region}:${var.account_id}:alias/${local.name_prefix}-*"]
  }
}

resource "aws_iam_policy" "tf_apply_sec" {
  name        = "aa-cis-infra-tf-apply-sec"
  description = "AA-873: aa-cis-infra-tf-apply grants for the account security baseline + SQS (bootstrap, MFA apply)"
  policy      = data.aws_iam_policy_document.tf_apply_sec.json
}

# Takes the slot freed by AmazonSQSFullAccess (cicd.tf), so the role stays at 10 managed policies.
resource "aws_iam_role_policy_attachment" "tf_apply_sec" {
  role       = aws_iam_role.tf_apply.name
  policy_arn = aws_iam_policy.tf_apply_sec.arn
}
