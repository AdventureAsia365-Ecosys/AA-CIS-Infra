# =============================================================================
# AA-1004 — the organization, its OUs and its member accounts.
#
# The organization already exists when this root first runs: enabling IAM Identity Center in the console (README
# step 2) creates it with all features. It is imported here (import block below), never created by Terraform.
#
# Member accounts:
#   - nonprod and ai are INVITED (README §6). Once an account has accepted, set member_accounts.<key>.account_id
#     and the import block brings it under Terraform; plan then moves it to its OU.
#   - prod is CREATED by this root at go-live (account_id = null, a fresh root e-mail).
# Every account carries prevent_destroy: removing an entry from member_accounts must fail the plan, because a
# destroy of aws_organizations_account removes the account from the organization (or closes it).
# =============================================================================

import {
  to = aws_organizations_organization.this
  id = var.organization_id
}

resource "aws_organizations_organization" "this" {
  feature_set = "ALL"

  # Trusted access. Free; each line is a service that acts across the organization from this account.
  aws_service_access_principals = [
    "sso.amazonaws.com",        # IAM Identity Center (already on: the console enabled it with the org)
    "cloudtrail.amazonaws.com", # organization trail (cloudtrail.tf)
    "account.amazonaws.com",    # alternate contacts of member accounts, set from here
    "iam.amazonaws.com",        # centralized root access (aws_iam_organizations_features below)
  ]

  enabled_policy_types = ["SERVICE_CONTROL_POLICY"]

  lifecycle {
    prevent_destroy = true
  }
}

locals {
  root_id = aws_organizations_organization.this.roots[0].id
}

resource "aws_organizations_organizational_unit" "nonprod" {
  name      = "NonProd"
  parent_id = local.root_id
}

resource "aws_organizations_organizational_unit" "prod" {
  name      = "Prod"
  parent_id = local.root_id
}

# Accounts waiting to be closed. Same 3 SCPs as the others (scp.tf); nothing runs there.
resource "aws_organizations_organizational_unit" "suspended" {
  name      = "Suspended"
  parent_id = local.root_id
}

locals {
  ou_parent_ids = {
    root      = local.root_id
    nonprod   = aws_organizations_organizational_unit.nonprod.id
    prod      = aws_organizations_organizational_unit.prod.id
    suspended = aws_organizations_organizational_unit.suspended.id
  }
}

import {
  for_each = { for k, a in var.member_accounts : k => a if a.account_id != null }
  to       = aws_organizations_account.member[each.key]
  id       = each.value.account_id
}

resource "aws_organizations_account" "member" {
  for_each = var.member_accounts

  name      = each.value.name
  email     = each.value.email
  parent_id = local.ou_parent_ids[each.value.ou]

  # Applies to a created account (prod) only: the cross-account admin role AWS provisions in it, and no billing
  # console access for IAM users there (billing is read in this account through AA-Billing).
  role_name                  = "OrganizationAccountAccessRole"
  iam_user_access_to_billing = "DENY"
  close_on_deletion          = false

  lifecycle {
    prevent_destroy = true
    # An invited account keeps its own name, root e-mail and settings; the API cannot read role_name or
    # iam_user_access_to_billing back, so without this every plan after an import would want to replace it.
    ignore_changes = [name, email, role_name, iam_user_access_to_billing]
  }
}

# Centralized root access: root credentials of member accounts can be removed and root-only tasks run from here
# (sts:AssumeRoot). Accounts created by this organization then start without root credentials. Free. Enabling it
# deletes nothing; removing the root credentials of an invited account is a separate, deliberate step (README §6).
resource "aws_iam_organizations_features" "this" {
  enabled_features = ["RootCredentialsManagement", "RootSessions"]

  depends_on = [aws_organizations_organization.this]
}
