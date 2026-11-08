# =============================================================================
# AA-1004 (S273) — the MFA admin role of this account, now in Terraform.
#
# The tech lead's CLI profiles aa365-admin and default assume this role from the IAM user
# var.identity_admin_user_name with an MFA code (~/.aws/config role_arn + mfa_serial). It replaces the role
# 'nghiep-admin-8h-session', made by hand on 09/07/2026 and never in Terraform: same trust (that one user,
# MFA present, sts:AssumeRole only), same three AWS managed policies, same 12-hour maximum session. Its name
# is var.identity_breakglass_admin_role_name, so every resource policy that names "the MFA admin role"
# (local.id_admin_role_arns in identity_alerts.tf) follows this resource.
#
# Transition (two PRs): PR 1 creates this role and keeps the hand-made role's name in local.id_admin_role_arns
# (var.identity_admin_role_legacy_names), so nothing locks the tech lead out before the profile switch. PR 2,
# merged only after `aws sts get-caller-identity --profile aa365-admin` returns this role, drops the legacy
# name and deletes the hand-made role.
#
# LOCAL-APPLY ONLY (MFA admin profile, targeted; runbook in the PR): the CI apply role cannot create or change
# a role without the workload boundary or outside aa-*-dev-* by design (CONTEXT.md, AA-806 role split). No
# permissions_boundary on purpose: this is the account administrator. prevent_destroy: a plan that would
# delete or replace it fails. Cost: 0 USD (IAM roles are free).
# =============================================================================

locals {
  # The managed policies of the hand-made role (S273 inventory): full admin plus the two billing policies
  # (AdministratorAccess does not cover every Billing console action on its own).
  admin_role_managed_policies = {
    administrator   = "arn:aws:iam::aws:policy/AdministratorAccess"
    billing         = "arn:aws:iam::aws:policy/job-function/Billing"
    billing_conduct = "arn:aws:iam::aws:policy/AWSBillingConductorFullAccess"
  }
}

data "aws_iam_policy_document" "admin_role_assume" {
  statement {
    sid     = "TechLeadUserWithMfa"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.account_id}:user/${var.identity_admin_user_name}"]
    }

    condition {
      test     = "Bool"
      variable = "aws:MultiFactorAuthPresent"
      values   = ["true"]
    }
  }
}

resource "aws_iam_role" "admin" {
  name                 = var.identity_breakglass_admin_role_name
  description          = "AA-1004: MFA admin role of the tech lead (CLI profiles aa365-admin and default). Local apply only."
  assume_role_policy   = data.aws_iam_policy_document.admin_role_assume.json
  max_session_duration = 43200 # 12 h, same as the hand-made role it replaces

  tags = merge(local.shared_tags, { Component = "security", Issue = "AA-1004" }) # S271 tagging standard (FIN-03)

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_iam_role_policy_attachment" "admin" {
  for_each   = local.admin_role_managed_policies
  role       = aws_iam_role.admin.name
  policy_arn = each.value
}
