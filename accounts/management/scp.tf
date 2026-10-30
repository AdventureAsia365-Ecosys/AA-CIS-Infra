# =============================================================================
# AA-1004 — the 3 service control policies of the lean model (blueprint S258 §0 "Quản trị tối thiểu").
#
# Policy text: policies/*.json.tftpl (plain JSON with template slots), minified here so the 5,120-character SCP
# limit counts no whitespace (today 0.25k / 2.1k / 1.6k characters with the default variables).
#
# Attached to the OUs NonProd, Prod and Suspended only, NEVER to the root: an invited account first sits directly
# under the root (the transitional place) where no SCP of ours applies, so it can still leave the organization
# if billing, credits or Bedrock break after joining. SCPs never apply to the management account itself, nor to
# service-linked roles. AWS keeps FullAWSAccess attached at every level, so each OU holds 4 direct SCPs (max 5).
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
    nonprod   = aws_organizations_organizational_unit.nonprod.id
    prod      = aws_organizations_organizational_unit.prod.id
    suspended = aws_organizations_organizational_unit.suspended.id
  }

  scp_attachments = {
    for pair in setproduct(keys(local.scps), keys(local.scp_target_ous)) :
    "${pair[0]}:${pair[1]}" => { policy = pair[0], ou = pair[1] }
  }
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
