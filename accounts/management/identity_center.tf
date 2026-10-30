# =============================================================================
# AA-1004 — IAM Identity Center: 3 groups, 4 permission sets, the group x account matrix.
#
# The Identity Center instance is enabled by hand in the console (README step 2): Terraform cannot create an
# organization instance. Its ARN and identity store ID come from the data source below. Users and group
# membership are NOT managed here (people's e-mails stay out of this public repo): the tech lead adds users in
# the console and puts them in a group (README step 5).
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
  lifecycle {
    postcondition {
      condition     = length(self.arns) == 1
      error_message = "IAM Identity Center is not enabled in this region of the management account: do README step 2 first."
    }
  }
}

locals {
  sso_instance_arn  = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  identity_store_id = tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]

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
  sso_assignments = merge([
    for acct, groups in local.access_matrix : merge([
      for group, sets in groups : {
        for ps in sets : "${acct}/${group}/${ps}" => { account = acct, group = group, permission_set = ps }
      }
    ]...)
    if acct == "management" || contains(keys(var.member_accounts), acct)
  ]...)
}

resource "aws_identitystore_group" "this" {
  for_each = local.sso_groups

  identity_store_id = local.identity_store_id
  display_name      = each.value.name
  description       = each.value.description
}

resource "aws_ssoadmin_permission_set" "this" {
  for_each = local.permission_sets

  instance_arn     = local.sso_instance_arn
  name             = each.key
  description      = each.value.description
  session_duration = each.value.session
}

resource "aws_ssoadmin_managed_policy_attachment" "this" {
  for_each = local.permission_sets

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
