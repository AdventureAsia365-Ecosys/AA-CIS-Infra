# =============================================================================
# AA-1182 (S296) — the Terraform state bucket of this root (backend "s3" in versions.tf) is locked to the Terraform roles.
#
# The bucket itself was created by hand on 09/07/2026 (AA-246) and stays outside Terraform: the backend cannot manage the
# bucket that holds its own state. This file manages what sits on it:
#   - versioning (Enabled, already on) and the bucket Block Public Access (all four flags, already on), taken under
#     Terraform with import blocks, so the plan is an import with no change and the nightly drift run sees any edit;
#   - a bucket policy (the bucket had none):
#       DenyInsecureTransport               every request without TLS, from anyone;
#       DenyStateAccessOutsideTerraform     every S3 action but the bucket configuration reads, unless the caller is
#                                           the CI plan role, the CI apply role or the MFA admin role (or the
#                                           Identity Center permission sets in var.tfstate_admin_sso_permission_sets,
#                                           or the organization break-glass role once org_access.tf is on);
#                                           S3 native locking (use_lockfile) writes <key>.tflock in this bucket, so the
#                                           lock is covered by the same statement;
#       DenyPlanRoleWritesExceptLockfile    the plan role (assumed from any PR branch) writes and deletes only *.tflock;
#       DenyHistoryAndConfigChangesOutsideAdmin
#                                           only the MFA admin (or the listed permission sets, or the organization
#                                           break-glass role) deletes an object
#                                           version or changes the bucket's policy, versioning, public access,
#                                           encryption, lifecycle or replication. The CI apply role can therefore
#                                           create this policy (first apply) but not change it afterwards: a later
#                                           edit of this file is a local MFA admin apply, like the other bootstrap
#                                           objects (CONTEXT.md, "How a change gets applied").
#
# Lock-out: the account root user can always read, replace and delete a bucket policy whatever it says (S3 rule), and
# after acc2 joins the company organization the management account can do the same through centralized root access
# (task policy S3UnlockBucketPolicy). The MFA admin role stays the day-to-day way in. Runbook: PR body of AA-1182.
#
# Encryption stays SSE-S3 (bucket default, live 27/11/2026; the backend sends no encryption header). A customer
# managed KMS key is a paid change (about 1 USD per month) that also needs kms:Decrypt for both CI roles: AA-1182
# follow-up, not part of this file.
#
# Cost: 0 USD (bucket policies, versioning configuration and Block Public Access are free).
# Guard: tools/terraform/tests/test_aa1182_tfstate_protection.py.
# =============================================================================

variable "tfstate_admin_sso_permission_sets" {
  description = "AA-1182: IAM Identity Center permission sets of the company organization whose roles in this account count as the MFA admin for the Terraform state bucket (AWSReservedSSO_<name>_<suffix>). A reseller's permission set never goes here."
  type        = list(string)
  default     = ["AA-Admin"]

  validation {
    condition     = alltrue([for p in var.tfstate_admin_sso_permission_sets : can(regex("^[A-Za-z0-9+=,.@-]+$", p))])
    error_message = "tfstate_admin_sso_permission_sets are permission set names (letters, digits, + = , . @ -)."
  }
}

locals {
  tfstate_bucket     = "aa-cis-tfstate-${var.account_id}"
  tfstate_bucket_arn = "arn:aws:s3:::${local.tfstate_bucket}"

  # Who counts as the MFA admin here: the tech lead's MFA role (admin_role.tf), the company Identity Center
  # permission sets (the path of an Identity Center role is aws-reserved/sso.amazonaws.com/[<region>/]) and, once
  # org_access.tf is on, the organization's break-glass role (OrganizationAccountAccessRole): after the move the
  # company admin reaches this account through that role (Identity Center AA-Admin in the management account ->
  # aa-org-member-access -> this role), not through an AWSReservedSSO role here. Gated on org_access_role_enabled so
  # a role a reseller may own under that name today is never trusted. The ARN is built from the name (no graph edge
  # to the role). Enabling it changes this bucket policy, which only an admin may write: the management README §6
  # step 2 local MFA apply targets aws_s3_bucket_policy.tfstate together with the role.
  tfstate_admin_principal_arns = concat(
    [aws_iam_role.admin.arn],
    [for p in var.tfstate_admin_sso_permission_sets : "arn:aws:iam::${var.account_id}:role/aws-reserved/sso.amazonaws.com/*AWSReservedSSO_${p}_*"],
    var.org_access_role_enabled ? ["arn:aws:iam::${var.account_id}:role/${var.org_access_role_name}"] : [],
  )

  # Terraform itself: the CI plan role (PR plans, drift, docs-gen, CRM key policy diff) and the CI apply role.
  tfstate_terraform_principal_arns = concat(
    [aws_iam_role.tf_plan.arn, aws_iam_role.tf_apply.arn],
    local.tfstate_admin_principal_arns,
  )

  # Bucket configuration reads stay open to every principal of the account (Access Analyzer, the compliance collector,
  # inventories): they return settings, never state.
  tfstate_config_read_actions = [
    "s3:GetBucket*", "s3:GetEncryptionConfiguration", "s3:GetLifecycleConfiguration",
    "s3:GetReplicationConfiguration", "s3:GetAccelerateConfiguration", "s3:GetInventoryConfiguration",
    "s3:GetMetricsConfiguration", "s3:GetAnalyticsConfiguration", "s3:GetIntelligentTieringConfiguration",
  ]
}

import {
  to = aws_s3_bucket_versioning.tfstate
  id = "aa-cis-tfstate-${var.account_id}"
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = local.tfstate_bucket
  versioning_configuration {
    status = "Enabled"
  }

  lifecycle {
    prevent_destroy = true
  }
}

import {
  to = aws_s3_bucket_public_access_block.tfstate
  id = "aa-cis-tfstate-${var.account_id}"
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = local.tfstate_bucket
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  lifecycle {
    prevent_destroy = true
  }
}

data "aws_iam_policy_document" "tfstate" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [local.tfstate_bucket_arn, "${local.tfstate_bucket_arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid         = "DenyStateAccessOutsideTerraform"
    effect      = "Deny"
    not_actions = local.tfstate_config_read_actions
    resources   = [local.tfstate_bucket_arn, "${local.tfstate_bucket_arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "ArnNotLike"
      variable = "aws:PrincipalArn"
      values   = local.tfstate_terraform_principal_arns
    }
  }

  statement {
    sid           = "DenyPlanRoleWritesExceptLockfile"
    effect        = "Deny"
    actions       = ["s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion", "s3:PutObjectAcl", "s3:RestoreObject"]
    not_resources = ["${local.tfstate_bucket_arn}/*.tflock"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:PrincipalArn"
      values   = [aws_iam_role.tf_plan.arn]
    }
  }

  statement {
    sid    = "DenyHistoryAndConfigChangesOutsideAdmin"
    effect = "Deny"
    actions = [
      "s3:DeleteObjectVersion", "s3:PutBucket*", "s3:DeleteBucket*", "s3:PutEncryptionConfiguration",
      "s3:PutLifecycleConfiguration", "s3:PutReplicationConfiguration", "s3:PutAccelerateConfiguration",
      "s3:PutInventoryConfiguration", "s3:PutMetricsConfiguration", "s3:PutAnalyticsConfiguration",
      "s3:PutIntelligentTieringConfiguration", "s3:PutObjectRetention", "s3:PutObjectLegalHold",
      "s3:BypassGovernanceRetention",
    ]
    resources = [local.tfstate_bucket_arn, "${local.tfstate_bucket_arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "ArnNotLike"
      variable = "aws:PrincipalArn"
      values   = local.tfstate_admin_principal_arns
    }
  }
}

resource "aws_s3_bucket_policy" "tfstate" {
  bucket = local.tfstate_bucket
  policy = data.aws_iam_policy_document.tfstate.json

  # Block Public Access first, so the policy is never evaluated on a bucket without it (it is on already; order only).
  depends_on = [aws_s3_bucket_public_access_block.tfstate]

  lifecycle {
    prevent_destroy = true
  }
}
