# =============================================================================
# AA-873 (S255) — apply-role grants for the account security baseline. BOOTSTRAP OBJECT.
#
# Covers the three AA-873 PRs in one local MFA apply: security_baseline.tf (PR 1: account BPA, IAM Access Analyzer,
# EventBridge alert rules + us-east-1 forwarder), security_cloudtrail.tf (PR 2: CloudTrail KMS key, multi-region
# trail, trail bucket versioning / Object Lock) and security_guardduty.tf (PR 3: GuardDuty behind
# var.guardduty_enabled), plus the public AMI parameter read of the NAT AMI fix (modules/vpc).
# S256: the Access Analyzer archive rules of security_access_analyzer_archive.tf (same bootstrap steps below).
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
# AA-1158 part 2 (S289): the same create / manage grants for the Booking supplier bank account key (App = booking tag,
# alias aa-booking-*), with the same limits (boundary DenyCrmKeyUseAndPolicyEdits, now also on App = booking,
# cicd_split.tf). Bootstrap again: apply this policy and the boundary locally with the MFA admin profile BEFORE the
# CI apply that creates the key (otherwise CreateKey is AccessDenied, and every later CI apply fails to refresh it):
#   terraform plan / apply -target=aws_iam_policy.tf_apply_sec -target=aws_iam_policy.tf_apply_boundary
#
# Apply (orchestrator, local, MFA admin profile, from main after merge):
#   1. terraform plan, then apply, with -target=aws_iam_policy.tf_apply_sec
#        -target=aws_iam_role_policy_attachment.tf_apply_managed -target=aws_iam_role_policy_attachment.tf_apply_sec
#        -target=aws_iam_policy.tf_apply_boundary
#      Expect: 1 policy + 1 attachment to add, 1 attachment (AmazonSQSFullAccess) to destroy, the boundary in place.
#   2. If the attach fails with LimitExceeded (11 attachments for a moment: create and destroy run in parallel),
#      run the same targeted apply again: the detach has finished by then. Then the same targeted plan: No changes.
# AA-1185 (S296): the EBS account defaults and the NAT patch association (security_account_defaults.tf). Same bootstrap:
#   terraform plan / apply -target=aws_iam_policy.tf_apply_sec   (local, MFA admin profile, before the CI apply)
# AA-1185 (S297): the NAT swap document and association (NatSwapDocument, aa-ecosys-* documents). Same bootstrap again.
# AA-1110 (S297): the chatbot grants of the Slack chat alert channel (chat_alerts.tf). Same bootstrap, any time before
# the PR that sets chat_alerts_enabled = true (while it is false nothing calls chatbot):
#   terraform plan / apply -target=aws_iam_policy.tf_apply_sec   (local, MFA admin profile)
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

  # S274: admin_role.tf brought the tech lead's inline user policy AssumeAdminSessionRole under Terraform (S273,
  # imported). Every CI apply since then failed at refresh (iam:GetUserPolicy AccessDenied, run 42599949632): read
  # only, on that one user. Writes stay a local MFA apply (the boundary denies iam:PutUserPolicy).
  statement {
    sid       = "AdminUserPolicyRead"
    actions   = ["iam:GetUser", "iam:GetUserPolicy", "iam:ListUserPolicies"]
    resources = ["arn:aws:iam::${var.account_id}:user/${var.identity_admin_user_name}"]
  }
  # PR 1: IAM Access Analyzer (Create/Get/Update/DeleteAnalyzer, Tag/Untag/ListTagsForResource).
  # S256 triage: its archive rules (security_access_analyzer_archive.tf; Create/Get/Update/Delete/ApplyArchiveRule,
  # ListArchiveRules). An archive-rule ARN is analyzer/<name>/archive-rule/<rule>, inside analyzer/*.
  statement {
    sid = "AccessAnalyzerManage"
    actions = [
      "access-analyzer:*Analyzer", "access-analyzer:*Resource", "access-analyzer:*ArchiveRule",
      "access-analyzer:ListArchiveRules",
    ]
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

  # AA-1158 part 2 (S289): the Booking supplier bank account key (modules/environment/booking_supplier_bank.tf), created
  # only with the App = booking tag, then the same non-destructive verbs as the shared keys above. The boundary
  # (cicd_split.tf DenyCrmKeyUseAndPolicyEdits, App = crm or booking) keeps CI off its crypto use, policy, deletion and state.
  statement {
    sid       = "BookingKmsCreateTagged"
    actions   = ["kms:CreateKey", "kms:TagResource"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/App"
      values   = ["booking"]
    }
  }

  statement {
    sid = "BookingKmsManageTagged"
    actions = [
      "kms:DescribeKey", "kms:GetKeyPolicy", "kms:GetKeyRotationStatus", "kms:ListKeyPolicies",
      "kms:ListResourceTags", "kms:EnableKeyRotation", "kms:UpdateKeyDescription", "kms:CancelKeyDeletion",
      "kms:CreateAlias", "kms:DeleteAlias", "kms:UpdateAlias",
    ]
    resources = ["arn:aws:kms:${var.aws_region}:${var.account_id}:key/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/App"
      values   = ["booking"]
    }
  }

  statement {
    sid       = "BookingKmsUntagExceptApp"
    actions   = ["kms:UntagResource"]
    resources = ["arn:aws:kms:${var.aws_region}:${var.account_id}:key/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/App"
      values   = ["booking"]
    }
    condition {
      test     = "ForAllValues:StringNotEquals"
      variable = "aws:TagKeys"
      values   = ["App"]
    }
  }

  statement {
    sid       = "BookingKmsAlias"
    actions   = ["kms:CreateAlias", "kms:DeleteAlias", "kms:UpdateAlias"]
    resources = ["arn:aws:kms:${var.aws_region}:${var.account_id}:alias/aa-booking-*"]
  }

  # AA-1185 (S296): the EBS account defaults of security_account_defaults.tf (encryption by default, snapshot Block
  # Public Access). Account settings, no resource ARN. The Disable verbs are what Terraform calls on destroy.
  statement {
    sid = "EbsAccountDefaults"
    actions = [
      "ec2:GetEbsEncryptionByDefault", "ec2:GetEbsDefaultKmsKeyId", "ec2:EnableEbsEncryptionByDefault",
      "ec2:DisableEbsEncryptionByDefault", "ec2:GetSnapshotBlockPublicAccessState",
      "ec2:EnableSnapshotBlockPublicAccess", "ec2:DisableSnapshotBlockPublicAccess",
    ]
    resources = ["*"]
  }

  # AA-1185: the NAT patch and swap associations (security_account_defaults.tf). Only the AWS-RunPatchBaseline
  # document and this account's aa-ecosys-* documents, on instances of this account; ListAssociations takes no resource.
  statement {
    sid = "NatPatchAssociation"
    actions = [
      "ssm:CreateAssociation", "ssm:UpdateAssociation", "ssm:DeleteAssociation", "ssm:DescribeAssociation",
      "ssm:AddTagsToResource", "ssm:RemoveTagsFromResource", "ssm:ListTagsForResource",
    ]
    resources = [
      "arn:aws:ssm:${var.aws_region}::document/AWS-RunPatchBaseline",
      "arn:aws:ssm:${var.aws_region}:${var.account_id}:document/aa-ecosys-*",
      "arn:aws:ssm:${var.aws_region}:${var.account_id}:association/*",
      "arn:aws:ec2:${var.aws_region}:${var.account_id}:instance/*",
    ]
  }

  # AA-1185 (S297): the NAT swap Command document (security_account_defaults.tf section 5). Manage documents named
  # aa-ecosys-* only; no ssm:SendCommand (a document runs only through the association, on the NAT instance).
  statement {
    sid = "NatSwapDocument"
    actions = [
      "ssm:CreateDocument", "ssm:UpdateDocument", "ssm:UpdateDocumentDefaultVersion", "ssm:DeleteDocument",
      "ssm:DescribeDocument", "ssm:GetDocument", "ssm:DescribeDocumentPermission", "ssm:ListDocumentVersions",
    ]
    resources = ["arn:aws:ssm:${var.aws_region}:${var.account_id}:document/aa-ecosys-*"]
  }

  statement {
    sid       = "SsmAssociationList"
    actions   = ["ssm:ListAssociations"]
    resources = ["*"]
  }

  # AA-1110 (S297): the Slack chat alert channel of chat_alerts.tf (Amazon Q Developer in chat applications, API prefix
  # chatbot). Create, Describe and ListTagsForResource take no resource ARN (Service Authorization Reference, AWS
  # Chatbot); update, delete and tags only on this stack's configurations. iam:PassRole of the channel role (an
  # aa-*-dev-* name) is already in IAMRoleManageStack (cicd_split.tf). No workspace authorisation verbs: authorising
  # or removing a Slack workspace stays a console step of a person.
  statement {
    sid = "ChatAlertsConfigCreate"
    actions = [
      "chatbot:CreateSlackChannelConfiguration", "chatbot:DescribeSlackChannelConfigurations",
      "chatbot:ListTagsForResource",
    ]
    resources = ["*"]
  }

  statement {
    sid = "ChatAlertsConfigManage"
    actions = [
      "chatbot:UpdateSlackChannelConfiguration", "chatbot:DeleteSlackChannelConfiguration", "chatbot:TagResource",
      "chatbot:UntagResource",
    ]
    resources = ["arn:aws:chatbot::${var.account_id}:chat-configuration/slack-channel/aa-ecosys-*"]
  }

  # AA-1110 (S297 review): the first channel configuration in the account creates the service-linked role
  # AWSServiceRoleForAWSChatbot, and the caller (this apply role) must be allowed to create it (Amazon Q Developer in
  # chat applications admin guide, "Using service-linked roles"). Only that one service; the tf_apply boundary does not
  # cover iam:CreateServiceLinkedRole. No-op when the role already exists.
  statement {
    sid       = "ChatAlertsServiceLinkedRole"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:aws:iam::${var.account_id}:role/aws-service-role/management.chatbot.amazonaws.com/*"]
    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["management.chatbot.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "tf_apply_sec" {
  name        = "aa-cis-infra-tf-apply-sec"
  description = "AA-873: aa-cis-infra-tf-apply grants for the account security baseline + SQS (bootstrap, MFA apply)"
  policy      = data.aws_iam_policy_document.tf_apply_sec.json

  tags = merge(local.shared_tags, { Component = "cicd" }) # S271: tagging standard (FIN-03)
}

# Takes the slot freed by AmazonSQSFullAccess (cicd.tf), so the role stays at 10 managed policies.
resource "aws_iam_role_policy_attachment" "tf_apply_sec" {
  role       = aws_iam_role.tf_apply.name
  policy_arn = aws_iam_policy.tf_apply_sec.arn
}
