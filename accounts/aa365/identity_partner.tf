# =============================================================================
# AA-939 (CRM-11) — the partner pool: agency people (CRM owners, agents, assistants; after P2b the Content studio
# users) sign in here, with two-step sign-in required. Root ADR 0006b decisions 1, 5 and 6 (accepted S247).
#
# WHAT THIS FILE ADDS:
#   - user pool aa-partner-<env>: Essentials tier, deletion protection ACTIVE, the immutable settings of ADR 0006
#     decision 1 (e-mail usernames, case-insensitive), ADMIN-CREATE ONLY (invitations, decision 5), account recovery
#     admin_only, e-mail change only after verification, MFA REQUIRED ("ON") with TOTP (authenticator app);
#   - one confidential app client, partner-web (the AA-Partner CRM web on the partner host): authorization code +
#     PKCE, scopes openid email profile, ALLOW_USER_AUTH only, refresh-token rotation, the same settings as the EXTERNAL
#     cis-portal client it replaces (30 min access / 168 h refresh: the CRM web session lasts 7 days);
#   - managed login v2 on a prefix domain (always) and the custom domain partner-auth.<zone> (with
#     identity_custom_domains_enabled, the ADR's "one more per region", 3 of the 4 allowed) on its OWN us-east-1
#     certificate, so the AA-818 auth certificate of auth. / staff-auth. is not replaced;
#   - a managed login branding style for every client of the pool (for_each over the client resource: the S249
#     guard tools/terraform/managed_login_branding.py fails CI for an interactive v2 client without one). Same
#     Adventure Asia look as EXTERNAL (local.id_branding_settings_external: no "Staff sign-in" header);
#   - the WAF association when identity_waf_enabled (identity.tf web ACL, off by default);
#   - the CRM API task role's partner-pool allow-list of decision 5 (AdminCreateUser, ListUsers, AdminDisableUser,
#     AdminUserGlobalSignOut on this pool only) and AA system mail (ses_send, transactional stream) for the
#     invitation and owner-recovery mails (crm_app.tf passes the pool, client, origin and sender to the task);
#   - two EventBridge -> SNS alerts on the partner pool (identity_alerts.tf topic): a change of the pool's MFA /
#     configuration by anyone but the Terraform apply role, and any admin call that bypasses the invitation +
#     authenticator model (password set or reset, MFA preference, user deletion, AdminCreateUser by anyone but the
#     CRM API).
#
# PASSKEYS (deliberate, recorded in AA-Partner docs/implementation-notes/AA-939.md): the pool starts with password +
# authenticator (the ADR's "TOTP-only fallback"). AA-930 found that a passkey satisfies required MFA only with
# WebAuthn FactorConfiguration = MULTI_FACTOR_WITH_USER_VERIFICATION, and the pinned AWS provider (6.69) has no
# argument for it: web_authn_configuration here would fall back to SINGLE_FACTOR, which Cognito does not accept as a
# first factor while MFA is required. Passkeys are added (allowed_first_auth_factors + WEB_AUTHN, relying party =
# the custom domain) when the provider supports the factor configuration; the custom domain exists from day one so
# the relying-party id does not move later.
#
# SIGN-IN SWITCH (safe rollout): the CRM web keeps the EXTERNAL cis-portal client until
# var.crm_partner_signin_enabled = true (crm_web.tf). The API accepts both pairs on Dev meanwhile (ADR 0006b route
# classes; the cis-portal bridge is refused outside dev). Order: apply this file -> e2e users on the partner pool
# (tools/identity/crm_dev_identity.py e2e-users --pool partner --apply --write-secrets) -> seeder members with the
# partner issuer -> crm_partner_signin_enabled = true + apply -> crm_dev_identity.py web-secret --pool partner
# --apply -> Deploy Web Dev (a new task reads the new client id and secret together).
#
# COST (us-west-1, AWS list prices, est., D-19): pool $0 (Essentials, 10,000 MAU per month free across the account's
# pools; Dev has a handful of synthetic users), custom domain $0 (Cognito-managed CloudFront), ACM certificate $0,
# Route 53 records $0 (existing zone; queries are cents), EventBridge rules on CloudTrail management events $0,
# SES about $0.10 per 1,000 mails. Total about $0 per month.
#
# APPLY: CI apply role (cicd_split.tf CognitoUserPoolManage, ACM, Route 53, EventBridgeIdentityRuleManage); no
# secret value is read on plan. MFA applies: none beyond the usual CI apply.
# =============================================================================

variable "identity_partner_domain_prefix" {
  description = "AA-939: Cognito prefix domain of the partner pool (<prefix>.auth.<region>.amazoncognito.com). Globally unique per region."
  type        = string
  default     = "aa365-partner-dev"
}

variable "identity_partner_custom_domain" {
  description = "AA-939 / ADR 0006b decision 1: the partner pool's managed login custom domain, used only when identity_custom_domains_enabled = true."
  type        = string
  default     = "partner-auth.lumiguides.it.com"
}

variable "identity_partner_client_urls" {
  description = "AA-939: callback and sign-out URLs per partner-pool app client key. partner-web = the AA-Partner CRM web on the partner host (/auth/callback, /signed-out) and its local development port 3005."
  type = map(object({
    callback_urls = list(string)
    logout_urls   = list(string)
  }))
  default = {
    "partner-web" = {
      callback_urls = ["https://partner-dev.lumiguides.it.com/auth/callback", "http://localhost:3005/auth/callback"]
      logout_urls   = ["https://partner-dev.lumiguides.it.com/signed-out", "http://localhost:3005/signed-out"]
    }
  }
}

locals {
  idpartner_name = "aa-partner-${var.environment}"
  idpartner_tags = merge(local.id_tags, { Pool = "partner", Issue = "AA-939" })

  # ADR 0006b decision 6: one interactive client for the AA-Partner web. Lifetimes as cis-portal (crm_web.tf).
  idpartner_clients = {
    "partner-web" = { access_minutes = 30, refresh_hours = 168 }
  }

  idpartner_custom_host = var.identity_partner_custom_domain
  idpartner_issuer      = "https://${aws_cognito_user_pool.partner.endpoint}"
  idpartner_login_base  = local.id_custom_domains ? "https://${local.idpartner_custom_host}" : "https://${aws_cognito_user_pool_domain.partner_prefix.domain}.auth.${var.aws_region}.amazoncognito.com"

  # Who may change the pool's configuration without an alert (Terraform), and who may create users (the CRM API).
  idpartner_tf_apply_role_arn = "arn:aws:iam::${var.account_id}:role/${local.tf_apply_role_name}"
}

resource "aws_cognito_user_pool" "partner" {
  name                = local.idpartner_name
  user_pool_tier      = "ESSENTIALS"
  deletion_protection = "ACTIVE"

  username_attributes = ["email"]
  username_configuration {
    case_sensitive = false
  }
  auto_verified_attributes = ["email"]

  # Decision 5: people are created by the invitation flow only (AdminCreateUser, SUPPRESS), never by self sign-up.
  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  # A lost second factor is reset by an AA admin after the agency owner confirms (runbook in the AA-939 notes).
  account_recovery_setting {
    recovery_mechanism {
      name     = "admin_only"
      priority = 1
    }
  }

  # Decision 1: two-step sign-in REQUIRED for every user (Q1 3.13). TOTP (authenticator app); no SMS.
  mfa_configuration = "ON"
  software_token_mfa_configuration {
    enabled = true
  }

  password_policy {
    minimum_length                   = 14
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 7
  }

  # Password then the authenticator. An e-mail code is never enough here (OTP sign-in is incompatible with required
  # MFA). WEB_AUTHN joins when passkeys can satisfy MFA through Terraform (header).
  sign_in_policy {
    allowed_first_auth_factors = ["PASSWORD"]
  }

  user_attribute_update_settings {
    attributes_require_verification_before_update = ["email"]
  }

  # Cognito itself mails nothing in the normal flow (SUPPRESS, admin-only recovery); an e-mail change verification
  # goes through the AA SES identity like the other pools.
  email_configuration {
    email_sending_account = local.id_ses_enabled ? "DEVELOPER" : "COGNITO_DEFAULT"
    source_arn            = local.id_ses_enabled ? local.id_ses_identity_arn : null
    from_email_address    = local.id_ses_enabled ? var.identity_ses_from_address : null
    configuration_set     = local.id_ses_enabled ? local.id_ses_config_set["external"] : null
  }

  # No custom attributes (ADR 0006 decision 1) and no triggers: no self sign-up to gate, no group or claim to add
  # (roles live in crm.member, ADR 0006b decision 4).

  tags = local.idpartner_tags

  lifecycle {
    precondition {
      condition     = !local.id_ses_enabled || var.identity_ses_from_address != ""
      error_message = "identity_ses_enabled = true needs identity_ses_from_address (inside the AA-811 identity's domain)."
    }
  }
}

resource "aws_cognito_user_pool_client" "partner" {
  for_each     = local.idpartner_clients
  name         = "${local.idpartner_name}-${each.key}"
  user_pool_id = aws_cognito_user_pool.partner.id

  generate_secret                      = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  explicit_auth_flows                  = ["ALLOW_USER_AUTH"]
  supported_identity_providers         = ["COGNITO"]
  callback_urls                        = var.identity_partner_client_urls[each.key].callback_urls
  logout_urls                          = var.identity_partner_client_urls[each.key].logout_urls

  access_token_validity  = each.value.access_minutes
  id_token_validity      = each.value.access_minutes
  refresh_token_validity = each.value.refresh_hours
  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "hours"
  }
  refresh_token_rotation {
    feature                    = "ENABLED"
    retry_grace_period_seconds = 60
  }

  enable_token_revocation       = true
  prevent_user_existence_errors = "ENABLED"
  auth_session_validity         = 3

  read_attributes  = ["email", "email_verified", "name"]
  write_attributes = ["name"]
}

resource "aws_cognito_user_pool_domain" "partner_prefix" {
  domain                = var.identity_partner_domain_prefix
  user_pool_id          = aws_cognito_user_pool.partner.id
  managed_login_version = 2
}

# Its own us-east-1 certificate (Cognito custom domains need us-east-1, RSA 2048): adding a SAN to the AA-818 auth
# certificate would replace it under both existing custom domains.
resource "aws_acm_certificate" "partner_auth" {
  provider = aws.us_east_1

  domain_name       = local.idpartner_custom_host
  validation_method = "DNS"
  key_algorithm     = "RSA_2048"

  tags = merge(local.cd_tags, { Name = "aa-ecosys-dev-partner-auth-domain", Issue = "AA-939" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "partner_auth_acm_validation" {
  for_each = { for dvo in aws_acm_certificate.partner_auth.domain_validation_options : dvo.domain_name => dvo }

  zone_id = aws_route53_zone.lumiguides.zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  ttl     = 300
  records = [each.value.resource_record_value]
}

resource "aws_acm_certificate_validation" "partner_auth" {
  count    = local.id_custom_domains ? 1 : 0
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.partner_auth.arn
  validation_record_fqdns = [for r in aws_route53_record.partner_auth_acm_validation : r.fqdn]
}

resource "aws_cognito_user_pool_domain" "partner_custom" {
  count                 = local.id_custom_domains ? 1 : 0
  domain                = local.idpartner_custom_host
  certificate_arn       = aws_acm_certificate_validation.partner_auth[0].certificate_arn
  user_pool_id          = aws_cognito_user_pool.partner.id
  managed_login_version = 2

  depends_on = [aws_route53_record.apex, time_sleep.wait_for_iam_propagation]
}

resource "aws_route53_record" "partner_auth_custom_domain" {
  count = local.id_custom_domains ? 1 : 0

  zone_id = aws_route53_zone.lumiguides.zone_id
  name    = aws_cognito_user_pool_domain.partner_custom[0].domain
  type    = "A"

  alias {
    name                   = aws_cognito_user_pool_domain.partner_custom[0].cloudfront_distribution
    zone_id                = aws_cognito_user_pool_domain.partner_custom[0].cloudfront_distribution_zone_id
    evaluate_target_health = false
  }
}

# One style per client of the pool (the whole client map, so a key added later is covered automatically).
resource "aws_cognito_managed_login_branding" "partner" {
  for_each = aws_cognito_user_pool_client.partner

  user_pool_id = aws_cognito_user_pool.partner.id
  client_id    = each.value.id
  settings     = jsonencode(local.id_branding_settings_external)

  dynamic "asset" {
    for_each = local.id_branding_assets_external
    content {
      bytes      = filebase64("${local.id_branding_assets_dir}/${asset.value.file}")
      category   = asset.value.category
      color_mode = "LIGHT"
      extension  = asset.value.extension
    }
  }
}

resource "aws_wafv2_web_acl_association" "identity_partner" {
  count        = var.identity_waf_enabled ? 1 : 0
  resource_arn = aws_cognito_user_pool.partner.arn
  web_acl_arn  = aws_wafv2_web_acl.identity[0].arn
}

# -----------------------------------------------------------------------------
# The CRM API's partner-pool allow-list (ADR 0006b decision 5) and AA system mail.
# -----------------------------------------------------------------------------
resource "aws_iam_role_policy" "crm_ecs_task_partner_pool" {
  name = "${local.crm_name_prefix}-ecs-task-partner-pool"
  role = aws_iam_role.crm_ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      # Invitation claim (create or find the account), member removal (sign out), owner recovery notice (address of
      # an owner). AdminDisableUser is allowed by the ADR but not called by the app today (a person may belong to
      # several agencies). Nothing else: no password, MFA or attribute writes.
      Sid      = "PartnerPoolInvitationAllowList"
      Effect   = "Allow"
      Action   = ["cognito-idp:AdminCreateUser", "cognito-idp:ListUsers", "cognito-idp:AdminDisableUser", "cognito-idp:AdminUserGlobalSignOut"]
      Resource = aws_cognito_user_pool.partner.arn
    }]
  })
}

resource "aws_iam_role_policy" "crm_ecs_task_ses_send" {
  name   = "${local.crm_name_prefix}-ecs-ses-send"
  role   = aws_iam_role.crm_ecs_task.id
  policy = data.aws_iam_policy_document.ses_send.json
}

# -----------------------------------------------------------------------------
# Alerts (CloudTrail -> EventBridge -> the alerts topic; rule names aa-identity-<env>-*, already allowed by the topic
# policy and the CI apply role). Cost $0 (management events, none expected).
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "identity_partner_pool_config" {
  name        = "${local.id_prefix}-partner-pool-config"
  description = "AA-939: partner pool configuration or MFA changed by anyone but the Terraform apply role (required MFA could be turned off).${local.runbook_suffix.incident}"
  state       = "ENABLED"

  event_pattern = jsonencode({
    source        = ["aws.cognito-idp"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["cognito-idp.amazonaws.com"]
      eventName   = ["SetUserPoolMfaConfig", "UpdateUserPool", "UpdateUserPoolClient", "DeleteUserPool", "DeleteUserPoolClient"]
      requestParameters = {
        userPoolId = [aws_cognito_user_pool.partner.id]
      }
      userIdentity = {
        sessionContext = {
          sessionIssuer = {
            # exists=false: a call without a role session (an IAM user's static key, root) has no
            # sessionIssuer at all, and anything-but alone would not match it (AA-939 review).
            arn = [{ "anything-but" = [local.idpartner_tf_apply_role_arn] }, { exists = false }]
          }
        }
      }
    }
  })

  tags = local.idpartner_tags
}

resource "aws_cloudwatch_event_target" "identity_partner_pool_config" {
  rule      = aws_cloudwatch_event_rule.identity_partner_pool_config.name
  target_id = "alerts-sns"
  arn       = aws_sns_topic.alerts.arn

  input_transformer {
    input_paths = {
      principal = "$.detail.userIdentity.arn"
      event     = "$.detail.eventName"
      time      = "$.detail.eventTime"
      error     = "$.detail.errorCode"
    }
    input_template = "\"[aa-identity] PARTNER pool ${aws_cognito_user_pool.partner.id}: <event> by <principal> at <time> (errorCode: <error>). The pool's configuration (required MFA, clients) is changed only by Terraform; check describe-user-pool and get-user-pool-mfa-config, and re-apply Terraform if it drifted (root ADR 0006b decision 1).${local.runbook_suffix.incident}\""
  }
}

resource "aws_cloudwatch_event_rule" "identity_partner_admin_bypass" {
  name        = "${local.id_prefix}-partner-admin-bypass"
  description = "AA-939: a partner pool admin call outside the invitation + authenticator model (password set/reset, MFA preference, delete, or AdminCreateUser by anyone but the CRM API).${local.runbook_suffix.incident}"
  state       = "ENABLED"

  event_pattern = jsonencode({
    source        = ["aws.cognito-idp"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["cognito-idp.amazonaws.com"]
      requestParameters = {
        userPoolId = [aws_cognito_user_pool.partner.id]
      }
      "$or" = [
        { eventName = ["AdminSetUserPassword", "AdminResetUserPassword", "AdminSetUserMFAPreference", "AdminDeleteUser", "AdminDeleteUserAttributes", "AdminUpdateUserAttributes", "AdminEnableUser", "AdminLinkProviderForUser"] },
        {
          eventName = ["AdminCreateUser"]
          userIdentity = {
            sessionContext = {
              sessionIssuer = {
                arn = [{ "anything-but" = [aws_iam_role.crm_ecs_task.arn] }, { exists = false }]
              }
            }
          }
        },
      ]
    }
  })

  tags = local.idpartner_tags
}

resource "aws_cloudwatch_event_target" "identity_partner_admin_bypass" {
  rule      = aws_cloudwatch_event_rule.identity_partner_admin_bypass.name
  target_id = "alerts-sns"
  arn       = aws_sns_topic.alerts.arn

  input_transformer {
    input_paths = {
      principal = "$.detail.userIdentity.arn"
      event     = "$.detail.eventName"
      time      = "$.detail.eventTime"
      error     = "$.detail.errorCode"
    }
    input_template = "\"[aa-identity] PARTNER pool ${aws_cognito_user_pool.partner.id}: <event> by <principal> at <time> (errorCode: <error>). Agency people are created only by the CRM invitation flow and reset only by the lost-factor runbook after the agency owner confirms (AA-939 notes). Unless this was that runbook or the e2e identity tool, find the user (ListUsers by time), disable it and sign it out everywhere.${local.runbook_suffix.incident}\""
  }
}

output "identity_partner_pool_id" {
  description = "AA-939: the partner pool (agency people, MFA required)."
  value       = aws_cognito_user_pool.partner.id
}

output "identity_partner_issuer" {
  value = local.idpartner_issuer
}

output "identity_partner_client_ids" {
  value = { for k, c in aws_cognito_user_pool_client.partner : k => c.id }
}

output "identity_partner_managed_login_base_url" {
  description = "AA-939: the partner pool's managed login (custom domain when on, else the prefix domain); the CRM web's COGNITO_DOMAIN after the switch."
  value       = local.idpartner_login_base
}

output "identity_partner_branding_ids" {
  value = { for k, b in aws_cognito_managed_login_branding.partner : k => b.managed_login_branding_id }
}
