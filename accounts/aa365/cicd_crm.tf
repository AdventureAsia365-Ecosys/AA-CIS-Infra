# =============================================================================
# AA-931 (CRM-03) — apply-role grants for the AA-Partner (CRM) stack. BOOTSTRAP OBJECT.
#
# Design: root docs/audits/2026-10-21-S246-crm-design-v3/design-v3.md §4.1 (keys, buckets), §6.3 card
# CRM-03 and §6.5 ("through the GitHub OIDC apply role after CRM-03"). These grants let the later CRM
# cards (CRM-04 infra + keys, CRM-12 audit buckets, CRM-17 SES, CRM-P2 host flip) go through the CI
# apply role aa-cis-infra-tf-apply instead of a local MFA apply each.
#
# Why a customer managed policy and not more inline statements: every inline policy of a role shares one
# 10,240-character limit, which AA-846 already had to trim. The role had the default quota of 10 managed
# policies, so cicd.tf drops AWSStepFunctionsFullAccess in the same apply (no Step Functions resource
# exists since AA-750). The apply role has no iam:CreatePolicy / CreatePolicyVersion, and the apply
# boundary denies version edits on this policy (DenyBoundaryPolicyEdits): CI cannot widen it. Applied
# locally with the MFA admin profile, like cicd_split.tf.
#
# Naming contract the CRM cards must follow (the grants and the boundary denies key on it):
#   - every CRM resource carries the tag App = "crm" (cost allocation, DM-10.1, and the KMS conditions);
#   - ECR repositories aa-crm-<env>-*; IAM roles aa-crm-<env>-* (inside tf_managed_role_arns, workload
#     boundary required); EventBridge rules aa-crm-*;
#   - KMS keys tagged App = "crm" with aliases alias/crm-<env>/{data,ingest,seal};
#   - audit buckets aa-crm-<env>-audit-<mode>-<account> (cicd_split.tf boundary statement
#     DenyCrmAuditObjectTampering); every CRM bucket is aa-crm-<env>-* (the data / ingest key policies allow SSE-KMS
#     only for that prefix, with or without S3 Bucket Keys: aws:s3:arn may be the object or the bucket ARN);
#   - break-glass role aa-crm-<env>-breakglass (CRM-13b): trust only the MFA admin role, with
#     aws:MultiFactorAuthPresent, MaxSessionDuration 3600 and a required session tag tenant_id (sts:TagSession). The
#     data key policy (crm_data.tf CrmBreakGlassOneAgency) lets it Decrypt only that agency's envelope keys.
#
# What CI may NOT do on CRM keys (boundary DenyCrmKeyUseAndPolicyEdits): any crypto use (Decrypt,
# Encrypt, GenerateDataKey*, ReEncrypt*, Sign), CreateGrant, PutKeyPolicy, ScheduleKeyDeletion,
# DisableKey. CRM-04 puts the 3-statement key policy inside aws_kms_key (CreateKey), so creating the keys
# can go through CI; any later key-policy change is a local MFA apply. The design's alarms on
# PutKeyPolicy / CreateGrant / ScheduleKeyDeletion / DisableKey (CRM-04) then only ever fire for a human.
#
# Already granted elsewhere, nothing added here: S3 incl. Object Lock (AmazonS3FullAccess), Cognito
# pools / clients / resource servers / domains / branding (CognitoUserPoolManage), SES identities,
# configuration sets and receipt rules (SESIdentityManage, SESReceiptRuleManage), ACM, Route 53,
# CloudFront distributions + cache / headers policies (PhotosCdnCloudFront), budgets, ELB target groups
# and listener rules on the CIS ALB, ECS (AmazonECS_FullAccess), logs (CloudWatchFullAccess).
# =============================================================================

locals {
  crm_name_prefix = "aa-crm-${var.environment}"

  crm_tags = {
    Project     = "AA-Partner"
    Environment = var.environment
    ManagedBy   = "terraform"
    App         = "crm" # DM-10.1 cost allocation; the KMS grants and boundary denies key on it
  }

  crm_kms_key_arns   = "arn:aws:kms:${var.aws_region}:${var.account_id}:key/*"
  crm_kms_alias_arns = "arn:aws:kms:${var.aws_region}:${var.account_id}:alias/crm-*"

  # cicd_split.tf boundary: object-level tamper deny on the audit buckets (CRM-04 / CRM-12).
  crm_audit_object_arns = "arn:aws:s3:::${local.crm_name_prefix}-audit-*/*"
}

data "aws_iam_policy_document" "tf_apply_crm" {
  # CloudFront VPC origins (this card), origin request policies (managed AllViewer* lookups and own
  # policies) and CloudFront Functions (CRM-P2b may 301 /trip/* at the edge). Global service; the
  # VPC-origin and policy actions take no ARN of ours at create time. Distributions are in
  # PhotosCdnCloudFront (cicd_split.tf). No invalidation, key group or field-level-encryption verbs.
  statement {
    sid = "CrmCloudFrontEdge"
    actions = [
      "cloudfront:*VpcOrigin*", "cloudfront:*OriginRequestPolicy*", "cloudfront:*Function*",
    ]
    resources = ["*"]
  }

  # Read-only lookups the edge's data sources (crm_edge.tf) need at plan time (S247: the first CI apply failed on all
  # three). The wildcards above do not cover them: "*OriginRequestPolicy*" / "*CachePolicy*" never match the
  # plural List*Policies verbs. The prefix list is CloudFront's origin-facing list for the NLB security group.
  statement {
    sid = "CrmEdgeReadLookups"
    actions = [
      "cloudfront:ListCachePolicies", "cloudfront:GetCachePolicy",
      "cloudfront:ListOriginRequestPolicies", "cloudfront:GetOriginRequestPolicy",
      "ec2:DescribeManagedPrefixLists", "ec2:GetManagedPrefixListEntries",
    ]
    resources = ["*"]
  }

  # The first CreateVpcOrigin in the account creates AWSServiceRoleForCloudFrontVPCOrigin. Only that
  # one service-linked role.
  statement {
    sid       = "CloudFrontVpcOriginServiceLinkedRole"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:aws:iam::${var.account_id}:role/aws-service-role/vpcorigin.cloudfront.amazonaws.com/*"]
    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["vpcorigin.cloudfront.amazonaws.com"]
    }
  }

  # modules/alb attaches a second group to the CIS ALB (CloudFront path). ELBManageVpcLinkNLB has no
  # SetSecurityGroups. Only the shared ALB and NLB.
  statement {
    sid     = "SharedLbSetSecurityGroups"
    actions = ["elasticloadbalancing:SetSecurityGroups"]
    resources = [
      "arn:aws:elasticloadbalancing:${var.aws_region}:${var.account_id}:loadbalancer/app/${local.name_prefix}-alb/*",
      "arn:aws:elasticloadbalancing:${var.aws_region}:${var.account_id}:loadbalancer/net/${local.name_prefix}-nlb/*",
    ]
  }

  # CRM-04: ECR x2 (api, web). Same verbs as BookingEcrRepoManage, scoped to aa-crm-<env>-*.
  statement {
    sid = "CrmEcrRepoManage"
    actions = [
      "ecr:CreateRepository", "ecr:DeleteRepository", "ecr:BatchDeleteImage", "ecr:PutLifecyclePolicy",
      "ecr:DeleteLifecyclePolicy", "ecr:PutImageScanningConfiguration", "ecr:PutImageTagMutability",
      "ecr:TagResource", "ecr:UntagResource",
    ]
    resources = ["arn:aws:ecr:${var.aws_region}:${var.account_id}:repository/${local.crm_name_prefix}-*"]
  }

  # CRM-04 keys: create only with the App = crm tag (CreateKey with Tags also needs TagResource).
  statement {
    sid       = "CrmKmsCreateTagged"
    actions   = ["kms:CreateKey", "kms:TagResource"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/App"
      values   = ["crm"]
    }
  }

  # Refresh and the non-destructive admin verbs, on CRM keys only. CancelKeyDeletion only undoes a
  # human's ScheduleKeyDeletion.
  statement {
    sid = "CrmKmsManageTagged"
    actions = [
      "kms:DescribeKey", "kms:GetKeyPolicy", "kms:ListKeyPolicies", "kms:GetKeyRotationStatus",
      "kms:EnableKeyRotation", "kms:UpdateKeyDescription", "kms:ListResourceTags", "kms:GetPublicKey",
      "kms:CancelKeyDeletion",
    ]
    resources = [local.crm_kms_key_arns]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/App"
      values   = ["crm"]
    }
  }

  # Untag anything on a CRM key except the App key itself (removing it would lift the boundary deny).
  statement {
    sid       = "CrmKmsUntagExceptApp"
    actions   = ["kms:UntagResource"]
    resources = [local.crm_kms_key_arns]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/App"
      values   = ["crm"]
    }
    condition {
      test     = "ForAllValues:StringNotEquals"
      variable = "aws:TagKeys"
      values   = ["App"]
    }
  }

  statement {
    sid       = "KmsList"
    actions   = ["kms:ListKeys", "kms:ListAliases"]
    resources = ["*"]
  }

  # Alias verbs are checked on the alias AND on the key, so two statements (an alias has no tags).
  statement {
    sid       = "CrmKmsAliasOnAlias"
    actions   = ["kms:CreateAlias", "kms:DeleteAlias", "kms:UpdateAlias"]
    resources = [local.crm_kms_alias_arns]
  }

  statement {
    sid       = "CrmKmsAliasOnKey"
    actions   = ["kms:CreateAlias", "kms:DeleteAlias", "kms:UpdateAlias"]
    resources = [local.crm_kms_key_arns]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/App"
      values   = ["crm"]
    }
  }

  # CRM-04 key alarms (PutKeyPolicy, CreateGrant, ScheduleKeyDeletion, DisableKey, foreign Decrypt) and
  # CRM-17 SES bounce events: EventBridge rules on the default bus named aa-crm-*.
  statement {
    sid = "CrmEventRuleManage"
    actions = [
      "events:PutRule", "events:DeleteRule", "events:DescribeRule", "events:EnableRule",
      "events:DisableRule", "events:PutTargets", "events:RemoveTargets", "events:ListTargetsByRule",
      "events:TagResource", "events:UntagResource", "events:ListTagsForResource",
    ]
    resources = ["arn:aws:events:${var.aws_region}:${var.account_id}:rule/aa-crm-*"]
  }

  # design §5.6: crm-marketing one-click unsubscribe uses an SES contact list. Control plane only
  # (no contact writes: those are the app's).
  statement {
    sid = "CrmSesContactListManage"
    actions = [
      "ses:CreateContactList", "ses:DeleteContactList", "ses:GetContactList", "ses:UpdateContactList",
      "ses:ListContactLists", "ses:TagResource", "ses:UntagResource", "ses:ListTagsForResource",
    ]
    resources = ["arn:aws:ses:${var.aws_region}:${var.account_id}:contact-list/*"]
  }
}

resource "aws_iam_policy" "tf_apply_crm" {
  name        = "aa-cis-infra-tf-apply-crm"
  description = "AA-931: aa-cis-infra-tf-apply grants for the AA-Partner (CRM) stack (bootstrap, MFA apply)"
  policy      = data.aws_iam_policy_document.tf_apply_crm.json
}

# Takes the slot freed by AWSStepFunctionsFullAccess (cicd.tf), so the role stays at 10 managed policies.
resource "aws_iam_role_policy_attachment" "tf_apply_crm" {
  role       = aws_iam_role.tf_apply.name
  policy_arn = aws_iam_policy.tf_apply_crm.arn
}
