# =============================================================================
# AA-1004 — IAM Identity Center: 3 groups, 4 permission sets, the group x account matrix.
#
# The Identity Center instance is enabled by the tech lead with one console click (README §2 step 4): Terraform
# cannot create an organization instance. Everything here is gated on var.identity_center_enabled (false for
# apply 1, before the organization exists). The instance ARN and identity store ID come from the data source.
# Users and their group membership come from var.sso_users, set only in the git-ignored terraform.tfvars, so no
# name or e-mail lands in this public repo; the first user is the tech lead, who replaces the AA-Bootstrap role.
#
# Groups (lean blueprint): Admin = tech lead, Developer = 2-3 engineers, Billing = business owner.
# Permission sets: 4, not 3, because a session duration belongs to the permission set, not to the assignment:
# "Admin, 1 hour in prod" and "full rights for a working day in nonprod" cannot be one set. Names cannot be
# changed after creation (a rename is a destroy + create that drops every assignment), so they are final here.
#
#   permission set | policy                          | session | used in
#   AA-Admin       | AdministratorAccess             | 1 h     | every account (admins only)
#   AA-Developer   | AdministratorAccess             | 8 h     | nonprod, ai (daily work; prod never)
#   AA-ReadOnly    | ViewOnlyAccess (no data reads)  | 8 h     | prod
#   AA-Billing     | AWSBillingReadOnlyAccess        | 4 h     | management (costs, invoices; no change)
# =============================================================================

data "aws_ssoadmin_instances" "this" {
  count = var.identity_center_enabled ? 1 : 0

  lifecycle {
    postcondition {
      condition     = length(self.arns) == 1
      error_message = "IAM Identity Center is not enabled in this region of the management account: do README §2 step 4 first, or set identity_center_enabled = false."
    }
  }
}

locals {
  sso_instance_arn  = try(tolist(data.aws_ssoadmin_instances.this[0].arns)[0], null)
  identity_store_id = try(tolist(data.aws_ssoadmin_instances.this[0].identity_store_ids)[0], null)

  sso_groups = {
    admins     = { name = "aa-admins", description = "Tech lead: administers the organization and every account." }
    developers = { name = "aa-developers", description = "Engineers: full rights in nonprod and ai, read-only in prod." }
    billing    = { name = "aa-billing", description = "Business owner: costs, budgets and invoices, read-only." }
  }

  permission_sets = {
    "AA-Admin" = {
      description = "Administrator, 1-hour sessions (prod and management included)."
      session     = "PT1H"
      policy_arn  = "arn:aws:iam::aws:policy/AdministratorAccess"
    }
    "AA-Developer" = {
      description = "Full rights for daily work in nonprod and ai; never assigned in prod or management."
      session     = "PT8H"
      policy_arn  = "arn:aws:iam::aws:policy/AdministratorAccess"
    }
    "AA-ReadOnly" = {
      description = "View configuration and metadata only: no object, secret or table reads."
      session     = "PT8H"
      policy_arn  = "arn:aws:iam::aws:policy/job-function/ViewOnlyAccess"
    }
    "AA-Billing" = {
      description = "Costs, budgets, Cost Explorer and invoices, read-only."
      session     = "PT4H"
      policy_arn  = "arn:aws:iam::aws:policy/AWSBillingReadOnlyAccess"
    }
  }

  # Group x account matrix (lean blueprint "Quản trị tối thiểu"). Keys: management + member_accounts keys.
  access_matrix = {
    management = { admins = ["AA-Admin"], billing = ["AA-Billing"] }
    nonprod    = { admins = ["AA-Admin", "AA-Developer"], developers = ["AA-Developer"] }
    ai         = { admins = ["AA-Admin", "AA-Developer"], developers = ["AA-Developer"] }
    prod       = { admins = ["AA-Admin", "AA-ReadOnly"], developers = ["AA-ReadOnly"] }
  }

  # Account IDs: the management one from the variable, members from the organization (created or imported).
  account_ids = merge(
    { management = var.management_account_id },
    { for k, a in aws_organizations_account.member : k => a.id },
  )

  # Static keys (account key / group / permission set) so for_each never depends on an unknown ID.
  sso_assignments_all = merge([
    for acct, groups in local.access_matrix : merge([
      for group, sets in groups : {
        for ps in sets : "${acct}/${group}/${ps}" => { account = acct, group = group, permission_set = ps }
      }
    ]...)
    if acct == "management" || contains(keys(var.member_accounts), acct)
  ]...)

  # Nothing of Identity Center exists before the console click.
  sso_groups_on      = var.identity_center_enabled ? local.sso_groups : {}
  permission_sets_on = var.identity_center_enabled ? local.permission_sets : {}
  sso_assignments    = var.identity_center_enabled ? local.sso_assignments_all : {}
  sso_users_on       = var.identity_center_enabled ? var.sso_users : {}
}

resource "aws_identitystore_group" "this" {
  for_each = local.sso_groups_on

  identity_store_id = local.identity_store_id
  display_name      = each.value.name
  description       = each.value.description
}

resource "aws_ssoadmin_permission_set" "this" {
  for_each = local.permission_sets_on

  instance_arn     = local.sso_instance_arn
  name             = each.key
  description      = each.value.description
  session_duration = each.value.session
}

resource "aws_ssoadmin_managed_policy_attachment" "this" {
  for_each = local.permission_sets_on

  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.this[each.key].arn
  managed_policy_arn = each.value.policy_arn
}

resource "aws_ssoadmin_account_assignment" "this" {
  for_each = local.sso_assignments

  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.this[each.value.permission_set].arn
  principal_type     = "GROUP"
  principal_id       = aws_identitystore_group.this[each.value.group].group_id
  target_type        = "AWS_ACCOUNT"
  target_id          = local.account_ids[each.value.account]

  # Provision only once the policy is on the permission set, so a first sign-in never lands in an empty role.
  depends_on = [aws_ssoadmin_managed_policy_attachment.this]
}

# Users (MFA is enforced by the Identity Center authentication settings, README §2 step 4) and their one group.
resource "aws_identitystore_user" "this" {
  for_each = local.sso_users_on

  identity_store_id = local.identity_store_id
  user_name         = each.value.email
  display_name      = "${each.value.given_name} ${each.value.family_name}"

  name {
    given_name  = each.value.given_name
    family_name = each.value.family_name
  }

  emails {
    value   = each.value.email
    primary = true
  }
}

resource "aws_identitystore_group_membership" "this" {
  for_each = local.sso_users_on

  identity_store_id = local.identity_store_id
  group_id          = aws_identitystore_group.this[each.value.group].group_id
  member_id         = aws_identitystore_user.this[each.key].user_id
}

# AA-1004 review (S259): sso_users keys became non-identifying handles (u1, u2, ...). The first local tfvars used the key
# "techlead"; these blocks rename its two instances in place, so the user keeps its identity-store ID, password and MFA
# (no destroy/create). No-op when "techlead" is not in the state. Remove once every state has moved.
moved {
  from = aws_identitystore_user.this["techlead"]
  to   = aws_identitystore_user.this["u1"]
}

moved {
  from = aws_identitystore_group_membership.this["techlead"]
  to   = aws_identitystore_group_membership.this["u1"]
}
