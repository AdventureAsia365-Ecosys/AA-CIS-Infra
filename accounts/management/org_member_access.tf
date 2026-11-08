# =============================================================================
# AA-1004 (S273, Billing Transfer of 01/12/2026) — aa-org-member-access: the one role of this account that may enter
# a member account through its OrganizationAccountAccessRole.
#
#   Identity Center AA-Admin session (MFA at every sign-in)
#     -> aa-org-member-access (this file, management account)
#       -> OrganizationAccountAccessRole (member account; for the nonprod account: accounts/aa365/org_access.tf)
#
# Why a named role here and not "the management account": the member-side trust then names one role, so no other
# principal of this account (the CI roles, a future permission set) can enter a member, and the static trust inventory
# (tools/terraform/iam_trust_inventory.py, which never accepts an account root) reviews it by name. The member side
# also checks aws:PrincipalOrgID.
#
# Trust: this account, only from an Identity Center AA-Admin role session (aws:PrincipalArn). MFA is enforced by
# Identity Center at sign-in; aws:MultiFactorAuthPresent is never set on Identity Center sessions, so it is not a
# condition here. Permissions: sts:AssumeRole on OrganizationAccountAccessRole of the member accounts in this root's
# state, plus var.org_access_pending_account_ids (an account about to join, so the path is tested before it joins),
# and nothing else. One-hour sessions (role chaining caps them at one hour anyway).
#
# Bootstrap object: the CI apply role's boundary denies every IAM role write (cicd.tf), so the tech lead applies this
# file locally with the aa-mgmt session (README §4 wrapper, targets in README §6). CI plan and drift read it.
# The prod account, created by this organization, gets a role of the same name from AWS (README §4 apply 5), so the
# same path reaches it.
#
# Cost: 0 USD (IAM).
# =============================================================================

variable "org_access_pending_account_ids" {
  description = <<-EOT
    Accounts not yet in member_accounts whose OrganizationAccountAccessRole aa-org-member-access may assume, so the
    path can be tested before the account joins (S273: the nonprod account before 01/12/2026). Only in the git-ignored
    terraform.tfvars / MGMT_TFVARS (public repo). Empty once the account is in member_accounts.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.org_access_pending_account_ids : can(regex("^[0-9]{12}$", a))])
    error_message = "org_access_pending_account_ids must be 12-digit AWS account IDs."
  }
}

locals {
  # Same name on both sides: accounts/aa365/org_access.tf trusts exactly this role (test_aa1004_org_access.py).
  org_member_access_role_name = "aa-org-member-access"
  org_member_role_name        = "OrganizationAccountAccessRole"

  org_member_access_accounts = sort(distinct(concat(
    [for k, a in aws_organizations_account.member : a.id],
    var.org_access_pending_account_ids,
  )))
}

resource "aws_iam_role" "org_member_access" {
  name                 = local.org_member_access_role_name
  description          = "AA-1004: from an Identity Center AA-Admin session into OrganizationAccountAccessRole of the member accounts"
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "IdentityCenterAdminOnly"
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${var.management_account_id}:root" }
      Action    = "sts:AssumeRole"
      Condition = {
        ArnLike = {
          "aws:PrincipalArn" = "arn:aws:iam::${var.management_account_id}:role/aws-reserved/sso.amazonaws.com/*/AWSReservedSSO_AA-Admin_*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "org_member_access" {
  count = length(local.org_member_access_accounts) > 0 ? 1 : 0

  name = "aa-org-member-access"
  role = aws_iam_role.org_member_access.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "AssumeMemberOrganizationAccessRole"
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = [for a in local.org_member_access_accounts : "arn:aws:iam::${a}:role/${local.org_member_role_name}"]
    }]
  })
}

output "org_member_access_role_arn" {
  description = "AA-1004: the role a member account's OrganizationAccountAccessRole trusts (README §6)."
  value       = aws_iam_role.org_member_access.arn
}
