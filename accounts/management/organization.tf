# =============================================================================
# AA-1004 — the organization, its OUs and its member accounts.
#
# The organization is CREATED by this root (apply 1, from the AA-Bootstrap role; README §4). The management account
# is brand new, so there is nothing to import, and creating it here is simpler than a CLI create-organization
# followed by an import. Identity Center is enabled by the tech lead in the console only after that (README §2).
#
# Member accounts:
#   - nonprod and ai are INVITED (README §6). Once an account has accepted, set member_accounts.<key>.account_id
#     and the import block brings it under Terraform; plan then moves it to its OU (first Transitional, S273).
#   - prod is CREATED by this root at go-live (account_id = null, a fresh root e-mail).
# Every account carries prevent_destroy: removing an entry from member_accounts must fail the plan, because a
# destroy of aws_organizations_account removes the account from the organization (or closes it).
# =============================================================================

resource "aws_organizations_organization" "this" {
  feature_set = "ALL"

  # Trusted access. Free; each line is a service that acts across the organization from this account.
  # This argument REPLACES the whole list: a principal another service switched on by itself (for example when the
  # tech lead enables Identity Center) must be added through var.extra_service_access_principals, or the next apply
  # turns it off. README §4 says how to check before each apply.
  # sso.amazonaws.com is left to the Identity Center console click (AWS asks to enable a service's trusted access
  # from that service), and only declared once var.identity_center_enabled says the click happened.
  aws_service_access_principals = distinct(concat(
    [
      "cloudtrail.amazonaws.com", # organization trail (cloudtrail.tf)
      "account.amazonaws.com",    # alternate contacts of member accounts, set from here (local only, README §11)
      "iam.amazonaws.com",        # centralized root access (aws_iam_organizations_features below)
    ],
    var.identity_center_enabled ? ["sso.amazonaws.com"] : [],
    var.extra_service_access_principals,
  ))

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

# S273 (Billing Transfer of 01/12/2026): where an invited account lands first, with a running workload. Only the
# guardrail that no workload ever calls (SCP 1, deny leave / close) applies here; SCPs 2 and 3 wait for the move to
# the account's own OU (scp.tf says why for each). The account can still be removed from this management account
# (remove-account-from-organization is not subject to SCPs), which is the rollback (README §9).
resource "aws_organizations_organizational_unit" "transitional" {
  name      = "Transitional"
  parent_id = local.root_id
}

# Accounts waiting to be closed. Same 3 SCPs as the others (scp.tf); nothing runs there.
resource "aws_organizations_organizational_unit" "suspended" {
  name      = "Suspended"
  parent_id = local.root_id
}

locals {
  # S271: Environment tag of each member account (tagging standard FIN-03). The nonprod account holds Dev (and staging
  # on demand); the AI account serves every environment.
  member_account_environment = { nonprod = "dev", ai = "shared", prod = "prod" }

  ou_parent_ids = {
    root         = local.root_id
    transitional = aws_organizations_organizational_unit.transitional.id
    nonprod      = aws_organizations_organizational_unit.nonprod.id
    prod         = aws_organizations_organizational_unit.prod.id
    suspended    = aws_organizations_organizational_unit.suspended.id
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

  # S271 (tagging standard FIN-03): the account's own environment; the provider default says shared.
  tags = { Environment = local.member_account_environment[each.key] }
}

# Centralized root access: root credentials of member accounts can be removed and root-only tasks run from here
# (sts:AssumeRoot). Accounts created by this organization then start without root credentials. Free. Enabling it
# deletes nothing; removing the root credentials of an invited account is a separate, deliberate step (README §6).
resource "aws_iam_organizations_features" "this" {
  enabled_features = ["RootCredentialsManagement", "RootSessions"]

  depends_on = [aws_organizations_organization.this]
}
