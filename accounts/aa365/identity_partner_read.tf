# =============================================================================
# AA-1039 R6 slice 2 (root ADR 0019 d20, TL-20) — the CIS worker reads the e-mail of an agency's owner and content
# members from the PARTNER pool, to send the tour retirement notice (job tour_notice_email, AA-CIS-App
# services/tour_lifecycle/notice_mail.py) through the existing SES sender (ses.tf, approved S265).
#
# Why a read on the partner pool: CIS keeps no tenant address. shared.tenant_members (AA-978, CIS 276) holds the
# partner-pool identity (cognito_iss, cognito_sub) and the Content studio role only, so the address is looked up at
# send time with ListUsers (filter `sub = "<sub>"`, Limit 1) and never stored. ListUsers does not count as a Cognito
# MAU (same reason identity_iam.tf uses it instead of AdminGetUser).
#
# Allowed:   cognito-idp:ListUsers on the partner pool ARN only. Nothing that writes, creates, signs in or changes a
#            partner account (the CRM task role keeps the invitation and removal writes, identity_partner.tf).
# Denied:    every other action on the partner pool (NotAction ListUsers), explicitly, so a later broad grant on this
#            role (cognito-idp:*, cognito-idp:Update*) cannot undo the exclusion: the per-user admin calls and the
#            pool, app-client and identity-provider configuration writes alike (the fail-closed pattern of
#            DenyStaffTakeoverActions in identity_iam.tf, which covers the WORKFORCE and EXTERNAL pools).
#
# Role: module.ecs task role (aa-cis-<env>-ecs-task-role), used by the api AND the worker task definitions; the mail
# job runs on the worker. The role carries the AA-806 workload boundary, which allows cognito-idp.
#
# After apply (seconds; no redeploy): the next tour_notice_email job resolves its recipients (its result says
# `sent`); before it, the job defers the notices to the next daily digest (`recipients unavailable: AccessDenied...`).
# The digest reads the notices of the last 14 days, so apply this before (or with) the CIS rollout: a notice still
# deferred after 14 days is not mailed. Probe: one retire of a synthetic E2E tour (live step of the CIS PR).
# Cost: $0 (IAM; ListUsers is not billed as a MAU).
# =============================================================================

data "aws_iam_policy_document" "cis_partner_pool_read" {
  statement {
    sid       = "PartnerPoolMemberAddressRead"
    effect    = "Allow"
    actions   = ["cognito-idp:ListUsers"]
    resources = [aws_cognito_user_pool.partner.arn]
  }

  # Every other action on the partner pool is denied, not only the per-user admin calls: the pool, app-client and
  # identity-provider configuration writes (UpdateUserPoolClient / CreateUserPoolClient adding a callback URL,
  # Create/UpdateIdentityProvider, UpdateUserPool triggers, SetUserPoolMfaConfig) allow an account takeover as well.
  # NotAction keeps the one read the mail needs.
  statement {
    sid         = "DenyPartnerTakeoverActions"
    effect      = "Deny"
    not_actions = ["cognito-idp:ListUsers"]
    resources   = [aws_cognito_user_pool.partner.arn]
  }
}

resource "aws_iam_role_policy" "cis_ecs_task_partner_pool_read" {
  name   = "aa-cis-${var.environment}-ecs-partner-pool-read"
  role   = module.ecs.task_role_name
  policy = data.aws_iam_policy_document.cis_partner_pool_read.json
}
