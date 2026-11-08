# =============================================================================
# AA-1004 — the 3 service control policies of the lean model (blueprint S258 §0 "Quản trị tối thiểu").
#
# Policy text: policies/*.json.tftpl (plain JSON with template slots), minified here so the 5,120-character SCP
# limit counts no whitespace (today 0.25k / 2.1k / 1.6k characters with the default variables).
#
# All three are attached to the OUs NonProd, Prod and Suspended, NEVER to the root. SCPs never apply to the management
# account itself, nor to service-linked roles. AWS keeps FullAWSAccess attached at every level, so each of these OUs
# holds 4 direct SCPs (max 5).
#
# OU Transitional (S273, Billing Transfer of 01/12/2026) gets SCP 1 only. An invited account arrives there with its
# workload running (the nonprod account: ECS, RDS, Lambda, CI), so only a guardrail that no workload ever calls is safe
# on day one:
#   SCP 1 deny leave / close   ATTACHED. No workload, pipeline or person calls LeaveOrganization or CloseAccount in
#                              normal work. The rollback stays open: the management account can still remove the
#                              account (RemoveAccountFromOrganization is not subject to SCPs).
#   SCP 2 protect audit/billing  HELD BACK. Before the move it would deny, outside the exempt roles: the account's own
#                              trail changes from a local MFA apply, the IAM writes of the bootstrap applies on the
#                              exempt CI role names (cicd*.tf of accounts/aa365 run locally with the MFA admin
#                              profile, which is not exempt), and the clean-up of the old reseller's access. It moves
#                              with the account to NonProd, once those applies are done or that profile is exempted.
#   SCP 3 region allow-list    HELD BACK. A resource or call of the account outside the allowed regions would fail at
#                              once. It moves with the account to NonProd after the region inventory of
#                              docs/runbooks/org-move-readiness-checks.md shows nothing outside the list.
# Moving the account from Transitional to NonProd is one in-place change of member_accounts.<key>.ou (README §4 apply 4).
# =============================================================================

locals {
  scps = {
    # SCP 1. Why: a member account that leaves takes its resources out of every control here (SCPs, trail,
    # budgets, Identity Center), and closing an account from the inside destroys everything in it. Both are
    # decisions for the management account only.
    "aa-scp-deny-leave-close" = {
      description = "Members cannot leave the organization or close themselves (AA-1004)."
      content     = templatefile("${path.module}/policies/scp-deny-leave-close.json.tftpl", {})
    }

    # SCP 2. Why: the audit trail and the billing and account settings must not be changeable by the people and
    # pipelines they audit or bill. Only the exempt admin / Terraform apply roles may touch a trail (the nonprod
    # account still manages its own trail in Terraform until the organization trail replaces it), billing, tax,
    # contact or account-name settings. A third statement protects the exempt roles themselves (AWS "protect IAM
    # roles" SCP example): without it, AdministratorAccess in a member account (AA-Developer) could create a role
    # with an exempt name, or rewrite the trust of OrganizationAccountAccessRole, and assume it to bypass the rest.
    # The retired aws-portal:Modify* actions are not listed: AWS replaced them with the billing/payments/tax/account
    # actions below.
    "aa-scp-protect-audit-billing" = {
      description = "No trail, billing, tax or account-setting change and no edit of the exempt roles outside those roles (AA-1004)."
      content = templatefile("${path.module}/policies/scp-protect-audit-billing.json.tftpl", {
        exempt_role_arn_patterns = jsonencode(var.scp_exempt_role_arn_patterns)
      })
    }

    # SCP 3. Why: everything we run is in us-west-1 (+ us-east-1 for ACM, us-west-2 for backup copies); a
    # resource started anywhere else is a mistake or an attacker, and is easy to miss on the bill. Global
    # services are exempt (NotAction). Bedrock gets its own statement: a call outside the allowed regions is
    # denied unless it carries bedrock:InferenceProfileArn, i.e. unless it is a geographic ("us.") or global
    # ("global.") cross-Region inference request, which Bedrock routes to destination regions itself (the
    # condition the Bedrock cross-Region inference SCP guidance uses).
    "aa-scp-region-allowlist" = {
      description = "Deny regions outside the allow-list; global services and Bedrock cross-Region inference exempt (AA-1004)."
      content = templatefile("${path.module}/policies/scp-region-allowlist.json.tftpl", {
        allowed_regions = jsonencode(var.allowed_regions)
      })
    }
  }

  scp_target_ous = {
    transitional = aws_organizations_organizational_unit.transitional.id
    nonprod      = aws_organizations_organizational_unit.nonprod.id
    prod         = aws_organizations_organizational_unit.prod.id
    suspended    = aws_organizations_organizational_unit.suspended.id
  }

  # Which SCPs each OU carries (header: why Transitional holds SCP 1 only).
  scp_ou_policies = {
    transitional = ["aa-scp-deny-leave-close"]
    nonprod      = keys(local.scps)
    prod         = keys(local.scps)
    suspended    = keys(local.scps)
  }

  # Keys "<policy>:<ou>", unchanged for the attachments that existed before Transitional (no replace in the plan).
  scp_attachments = merge([
    for ou, policies in local.scp_ou_policies : {
      for policy in policies : "${policy}:${ou}" => { policy = policy, ou = ou }
    }
  ]...)
}

resource "aws_organizations_policy" "scp" {
  for_each = local.scps

  name        = each.key
  description = each.value.description
  type        = "SERVICE_CONTROL_POLICY"
  content     = jsonencode(jsondecode(each.value.content))

  # SCPs exist only once the policy type is enabled on the root (organization.tf).
  depends_on = [aws_organizations_organization.this]
}

resource "aws_organizations_policy_attachment" "scp" {
  for_each = local.scp_attachments

  policy_id = aws_organizations_policy.scp[each.value.policy].id
  target_id = local.scp_target_ous[each.value.ou]
}
