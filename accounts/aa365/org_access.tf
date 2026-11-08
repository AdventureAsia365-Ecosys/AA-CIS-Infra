# =============================================================================
# AA-1004 (S273, Billing Transfer of 01/12/2026) — the organization's admin path into this account.
#
# This account joins the AA organization by INVITATION, and an invited account does not get the
# OrganizationAccountAccessRole that AWS creates in accounts the organization creates itself. This file creates the
# equivalent role here, with the AWS name (the management root's SCP 2 already exempts that name, and the prod account
# will get the same name from AWS), so the management account can administer this account the day it joins.
#
# Who can assume it (least privilege, root ADR 0018; accounts/management/org_member_access.tf):
#   - only the role aa-org-member-access in the management account, named exactly (not the account root, so no other
#     principal of the management account, CI roles included, can use this trust; tools/terraform/iam_trust_inventory.py
#     never accepts an account root);
#   - only when the caller's organization is ours (aws:PrincipalOrgID), the organization condition AWS recommends for
#     cross-account trusts inside one organization. No external ID: AWS uses it against the confused-deputy problem of
#     third parties, and both sides here are our own accounts;
#   - aa-org-member-access itself trusts only an Identity Center AA-Admin session of the management account. Identity
#     Center asks for MFA at every sign-in (management README §2 step 4). aws:MultiFactorAuthPresent cannot be a
#     condition here: Identity Center (SAML) sessions and chained role sessions never carry it.
#
# Permissions: AdministratorAccess, as the AWS convention (this is the organization's break-glass and bootstrap path,
# e.g. deleting the old reseller's Identity Center role after the move), minus long-lived IAM credentials (no IAM user,
# access key or console password, the same rule as the management account). One-hour sessions.
#
# Bootstrap object: the name is outside aa-*-dev-* and the role carries no workload boundary, so the CI apply role is
# denied every write to it (tf_apply_boundary DenyRoleWritesOutsideStack). No aa-workload-boundary either, the one
# deliberate exception to "every new role carries it": that boundary denies IAM and organization writes, which is the
# work this role exists for. The tech lead applies this file locally with
# the MFA admin profile from an up-to-date main checkout (targets in the management README §6), like
# cicd_db_auto_apply.tf. CI plans and drift read it and must show no change.
#
# Inputs (public repo: no account or organization ID is written here): CI passes the repo secrets MGMT_ACCOUNT_ID and
# MGMT_ORG_ID as TF_VAR_org_management_account_id / TF_VAR_org_management_org_id (terraform-plan.yml,
# terraform-apply.yml, terraform-drift.yml); a local plan sets the same two TF_VAR_ values from the aa-mgmt profile.
# With org_access_role_enabled = true a plan without them (null, or "" for a missing GitHub secret) fails on the
# variable validation instead of planning a destroy, and prevent_destroy refuses a destroy in any case (rollback:
# management README §9).
#
# Order (management README §6 step 2): terraform.tfvars keeps org_access_role_enabled = false until the tech lead's
# local targeted apply has created the role (run with -var org_access_role_enabled=true); a one-line PR flips it to
# true right after. Committing true first would make every CI apply of this root plan the role, which the apply role
# may not write (AccessDenied), for as long as the local apply waits (weeks if the reseller's SCPs hold it until the
# move). Between the local apply and the flip merge, CI plans want to destroy the role and prevent_destroy fails them:
# keep that window to minutes and dispatch no aa365 apply in it (the cicd_db_auto_apply.tf precedent).
#
# Cost: 0 USD (IAM).
# =============================================================================

variable "org_access_role_enabled" {
  description = "AA-1004: create the organization admin role (OrganizationAccountAccessRole) that trusts the management account's aa-org-member-access role."
  type        = bool
  default     = false
}

variable "org_access_adopt_existing_role" {
  description = <<-EOT
    AA-1004: true only when a role with the name org_access_role_name already exists in this account (management
    README §6 step 0 check). Terraform then imports it, rewrites its trust and replaces its whole policy set (the
    exclusive resources below detach every other policy). False (default) = Terraform creates the role.
  EOT
  type        = bool
  default     = false
}

variable "org_access_role_name" {
  description = "AA-1004: name of the organization admin role. AWS convention; the management root's SCP 2 exempts exactly this name."
  type        = string
  default     = "OrganizationAccountAccessRole"
}

variable "org_management_account_id" {
  description = "AA-1004: 12-digit ID of the AA management account. From the repo secret MGMT_ACCOUNT_ID in CI, from the aa-mgmt profile locally; never in a committed file."
  type        = string
  default     = null

  validation {
    # GitHub passes a missing secret as "", not null: both mean "not set" (allowed only while the role is disabled).
    condition     = var.org_management_account_id == null || var.org_management_account_id == "" ? !var.org_access_role_enabled : can(regex("^[0-9]{12}$", var.org_management_account_id))
    error_message = "org_access_role_enabled = true needs TF_VAR_org_management_account_id (12 digits). An empty value in CI means the repo secret MGMT_ACCOUNT_ID is missing; locally take it from the aa-mgmt profile (management README section 6)."
  }
}

variable "org_management_org_id" {
  description = "AA-1004: ID (o-...) of the AA organization, for the aws:PrincipalOrgID condition. From the repo secret MGMT_ORG_ID in CI, from the aa-mgmt profile locally."
  type        = string
  default     = null

  validation {
    # GitHub passes a missing secret as "", not null: both mean "not set" (allowed only while the role is disabled).
    condition     = var.org_management_org_id == null || var.org_management_org_id == "" ? !var.org_access_role_enabled : can(regex("^o-[a-z0-9]{10,32}$", var.org_management_org_id))
    error_message = "org_access_role_enabled = true needs TF_VAR_org_management_org_id (o-...). An empty value in CI means the repo secret MGMT_ORG_ID is missing (set it before the role is enabled); locally take it from the aa-mgmt profile (management README section 6)."
  }
}

locals {
  org_access_count = var.org_access_role_enabled ? 1 : 0

  # Long-lived IAM credentials stay forbidden even for the organization's admin path.
  org_access_denied_actions = [
    "iam:CreateUser",
    "iam:CreateAccessKey",
    "iam:CreateLoginProfile",
    "iam:UpdateLoginProfile",
    "iam:CreateServiceSpecificCredential",
  ]
}

data "aws_iam_policy_document" "org_access_trust" {
  count = local.org_access_count

  statement {
    sid     = "ManagementAccountMemberAccessRole"
    actions = ["sts:AssumeRole"]

    # The one role of the management account allowed in (accounts/management/org_member_access.tf). The name is a
    # literal on purpose: the static trust inventory reviews it by name (iam_trust_allowlist.json), and
    # tools/terraform/tests/test_aa1004_org_access.py keeps it equal to the management side.
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.org_management_account_id}:role/aa-org-member-access"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalOrgID"
      values   = [var.org_management_org_id]
    }
  }
}

import {
  for_each = var.org_access_role_enabled && var.org_access_adopt_existing_role ? toset([var.org_access_role_name]) : toset([])
  to       = aws_iam_role.org_access[0]
  id       = each.value
}

resource "aws_iam_role" "org_access" {
  count = local.org_access_count

  name                 = var.org_access_role_name
  description          = "AA-1004: AA organization admin path, assumed only from the management account role aa-org-member-access"
  assume_role_policy   = data.aws_iam_policy_document.org_access_trust[0].json
  max_session_duration = 3600

  lifecycle {
    # Removing this role cuts the organization off this account; a destroy needs a deliberate PR (management README §9).
    prevent_destroy = true
  }

  tags = { App = "ecosystem", Component = "governance", Issue = "AA-1004" }
}

resource "aws_iam_role_policy_attachments_exclusive" "org_access" {
  count = local.org_access_count

  role_name   = aws_iam_role.org_access[0].name
  policy_arns = ["arn:aws:iam::aws:policy/AdministratorAccess"]
}

data "aws_iam_policy_document" "org_access_guard" {
  statement {
    sid       = "NoLongLivedIamCredentials"
    effect    = "Deny"
    actions   = local.org_access_denied_actions
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "org_access_guard" {
  count = local.org_access_count

  name   = "aa-org-access-guard"
  role   = aws_iam_role.org_access[0].id
  policy = data.aws_iam_policy_document.org_access_guard.json
}

resource "aws_iam_role_policies_exclusive" "org_access" {
  count = local.org_access_count

  role_name    = aws_iam_role.org_access[0].name
  policy_names = [aws_iam_role_policy.org_access_guard[0].name]
}

output "org_access_role_name" {
  description = "AA-1004: name of the organization admin role in this account (null until org_access_role_enabled)."
  value       = var.org_access_role_enabled ? aws_iam_role.org_access[0].name : null
}
