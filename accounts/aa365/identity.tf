# =============================================================================
# Ecosystem identity on Amazon Cognito (AA-703, root ADR 0006 "Ecosystem identity", ACCEPTED S236,
# Phase 0 "Pools and triggers"). Every resource lives in this file and uses the aa-workforce-* /
# aa-external-* / aa-identity-* prefixes. It only READS resources owned elsewhere:
#   - aws_sns_topic.alerts (observability.tf) and aws_iam_policy.workload_boundary (cicd_split.tf)
#   - ses.tf (AA-811): local.ses_identity_arn and aws_sesv2_configuration_set.stream["workforce"]
#     / ["external"], used by BOTH pools' email_configuration when identity_ses_enabled = true.
#     COUPLING: renaming ses_config_set_name, removing the workforce/external entries of
#     local.ses_streams or replacing the SES identity updates both user pools in place and can
#     break staff email codes (EMAIL_OTP). Plan identity.tf with any such ses.tf change.
# No CIS / Booking / TripPlanner resource is changed.
#
# WHAT THIS FILE ADDS:
#   - 2 user pools on the Essentials plan, deletion protection ACTIVE (decision 1):
#       aa-workforce-<env>  staff + break-glass; admin-create only; MFA OPTIONAL (TOTP, break-glass only)
#       aa-external-<env>   tenant users + travellers; self sign-up gated per client by the trigger; MFA OFF
#   - 8 app clients (decision 2): workforce cis-admin / booking-staff / breakglass (confidential) plus the
#     Preview-only cis-admin-preview / booking-staff-preview (confidential, capped at viewer by the APIs; AA-911
#     D-1, root ADR 0006a A11), external cis-portal (confidential), booking-customer / tripplanner (public, PKCE)
#   - 10 WORKFORCE groups <app>-<role> (decision 3): 3 CIS roles + every Booking staff role
#     (AA-Booking backend/app/auth/staff.py STAFF_ROLES, incl. content_creator: S241 Q4/Q5, AA-854)
#     + the 3 AA-Partner staff groups crm-platform-admin / crm-ops / crm-support (AA-939, root ADR 0006b
#     decision 6); EXTERNAL has none (tenant roles live in CIS DB)
#   - AA-939: the WORKFORCE crm-staff client (AA-Partner /crm/staff/v1); the PARTNER pool (agency people, MFA
#     required) is in identity_partner.tf
#   - Staff sign in with an EMAIL ONE-TIME CODE ONLY (S236 amendment: adventure.asia mail is on
#     DreamHost, not Google Workspace, so there is no `hd` claim to restrict Google to staff). The
#     WORKFORCE pool has NO social identity provider. Google and Facebook exist on EXTERNAL only,
#     each created ONLY when its client id and secret ARN variables are set (count = 0 otherwise)
#   - 4 Python 3.12 trigger Lambdas (pre sign-up + pre token generation V2_0 per pool), outside
#     the VPC, published versions behind a `live` alias (decision 5), with alarms (ALARM + OK mail,
#     S241 D-20) and 365-day log groups (auth audit logs, S241 D-09). Their roles carry
#     the AA-806 workload boundary (the CI apply role may only create roles that carry it)
#   - prefix domains (managed login v2) always (fallback); custom domains auth. / staff-auth. +
#     their Route 53 alias records when identity_custom_domains_enabled = true (default since
#     AA-816 S242; AA-818 us-east-1 certificate + apex A record in dns.tf)
#   - managed login branding (Adventure Asia style + logos) for every WORKFORCE client (AA-816 S242; 5 with AA-911)
#   - Cognito mail through the AA-811 SES identity (ses.tf, same root) when identity_ses_enabled = true
#     (default since AA-854: identity verified, DKIM SUCCESS, account out of the SES sandbox, checked
#     live 17/10/2026); off = COGNITO_DEFAULT and no EMAIL_OTP. EXTERNAL native self sign-up stays
#     refused until identity_external_native_signup_enabled = true, which a precondition on the
#     EXTERNAL pool only accepts together with identity_waf_enabled and identity_ses_enabled (D-19)
#   - optional REGIONAL WAF web ACL with per-IP rate rules on the pools, OFF by default
#     (identity_waf_enabled; billable, needs a quote and Nghiep's go per S241 D-19; on since AA-908)
#   - Secrets Manager container aa-identity/<env>/breakglass (no value; decision 11)
#
# SIGN-IN UNTIL SES IS ON: EMAIL_OTP needs the DEVELOPER (SES) email configuration, so with
# identity_ses_enabled = false nobody but break-glass (password + TOTP) can sign in to WORKFORCE,
# and EXTERNAL native sign-up is refused by the trigger (NATIVE_SIGNUP_ENABLED=false). The pools,
# clients and issuers are still stable, so the apps can wire their verifier config early.
#
# DELIBERATE DEVIATIONS / NOTES FOR REVIEWERS:
#   - PASSWORD stays in allowed_first_auth_factors on both pools: AWS documents that "the Password
#     option is always available" for choice-based sign-in, and first factors are pool-wide (not
#     per client), and ALLOW_USER_AUTH itself offers the PASSWORD challenge to any user who has a
#     password. Nobody but break-glass may have a usable one, which holds only by procedure:
#     account recovery is admin_only, no client enables ALLOW_USER_PASSWORD_AUTH /
#     ALLOW_USER_SRP_AUTH, and every AdminCreateUser call (staff directory AA-816, the Phase 1
#     bootstrap script, CIS invitations AA-813) MUST pass MessageAction=SUPPRESS. Cognito always
#     gives an admin-created user a temporary password; without SUPPRESS it mails that password
#     (COGNITO_DEFAULT works even before SES), the person can then set a permanent one through
#     managed login and sign in with a password alone (MFA is OPTIONAL and not enrolled), which
#     bypasses "staff sign in with an email code only". ADR 0006 decision 2 ("EXTERNAL allows
#     EMAIL_OTP only") is likewise met by procedure, not by pool configuration.
#   - EXTERNAL clients that offer a social IdP get write access to the mapped attributes (email,
#     name, and email_verified only when Google is on, since Facebook does not map it): Cognito
#     requires the app client to be able to write every mapped attribute. CAUTION: the
#     allowed_oauth_scopes below only limit tokens from the OAuth /token endpoint. AWS: "A token
#     from Amazon Cognito API sign-in only contains the scope aws.cognito.signin.user.admin", and
#     ALLOW_USER_AUTH lets anyone holding a public client id (booking-customer, tripplanner) sign in
#     through the API and call UpdateUserAttributes with whatever the client may write. Once
#     email_verified is client-writable, a traveller may be able to mark an arbitrary email as
#     verified, which ADR 0006 decision 6 (linking, lead merge) trusts. All social IdP variables
#     therefore stay empty until that is settled (see identity_external_google_client_id). The
#     EXTERNAL pre sign-up trigger already refuses a native SignUp that sets email_verified.
#     WORKFORCE clients write `name` only and are confidential (API sign-in needs the secret).
#   - Break-glass is restricted to its own client only by procedure: the pre token trigger is a
#     pure function and cannot know client ids (pool -> trigger -> client would be a Terraform
#     cycle). It logs every break-glass token issue (alarm below).
#   - Managed login v2 needs a branding style per client before its pages render. WORKFORCE clients
#     carry the AA style below (AA-816 S242, was a CLI --use-cognito-provided-values workaround,
#     imported then replaced in #194). EXTERNAL clients have NO style yet (no live users; needs its
#     own non-"staff" header logo): their managed login pages do not render until one is added here.
#   - The break-glass USER is not created here (Terraform would hold its password). One-off script
#     in Phase 1 (ADR 0006 migration plan).
#
# APPLY PREREQUISITES (CI apply role aa-cis-infra-tf-apply, AA-806 split):
#   - cognito-idp:* and wafv2:CreateWebACL/DeleteWebACL/CheckCapacity: statements
#     CognitoUserPoolManage in cicd_split.tf / WAFv2Manage in cicd.tf (AA-811 bootstrap grant, local MFA
#     apply) must be live first, or the CI apply fails with AccessDenied.
#   - identity_ses_enabled = true (the default) switches both pools to DEVELOPER email: Cognito then
#     creates the service-linked role AWSServiceRoleForAmazonCognitoIdpEmailService with the CALLER's
#     credentials; cicd_split.tf statement CognitoEmailServiceLinkedRole grants exactly that.
#   - EXTERNAL Google / Facebook: the plan role (aa-cis-infra-tf-plan) reads secret values only for
#     ARNs in local.tf_plan_secret_arns (cicd_split.tf, bootstrap). Add the IdP secret ARNs there
#     before setting the IdP variables, or the next CI plan fails on refresh.
# =============================================================================

locals {
  idwf_name  = "aa-workforce-${var.environment}"
  idext_name = "aa-external-${var.environment}"
  id_prefix  = "aa-identity-${var.environment}"

  id_tags = {
    Project     = "AA-Ecosys"
    Environment = var.environment
    ManagedBy   = "terraform"
    App         = "identity"
    Issue       = "AA-703"
  }

  id_ses_enabled   = var.identity_ses_enabled
  id_first_factors = local.id_ses_enabled ? ["PASSWORD", "EMAIL_OTP"] : ["PASSWORD"]

  # SES wiring (AA-854): empty variables fall back to the AA-811 identity and configuration sets
  # in ses.tf (same root), so no ARN has to be copied into tfvars.
  id_ses_identity_arn = var.identity_ses_identity_arn != "" ? var.identity_ses_identity_arn : local.ses_identity_arn
  id_ses_config_set = {
    workforce = var.identity_ses_configuration_set_workforce != "" ? var.identity_ses_configuration_set_workforce : aws_sesv2_configuration_set.stream["workforce"].configuration_set_name
    external  = var.identity_ses_configuration_set_external != "" ? var.identity_ses_configuration_set_external : aws_sesv2_configuration_set.stream["external"].configuration_set_name
  }

  # EXTERNAL native self sign-up (traveller clients) needs EMAIL_OTP (SES) AND an explicit opt-in:
  # without the WAF rate rules a script could burn SES reputation shared with staff email codes.
  id_ext_native_signup = local.id_ses_enabled && var.identity_external_native_signup_enabled

  id_ext_google = var.identity_external_google_client_id != "" && var.identity_external_google_client_secret_arn != ""
  id_facebook   = var.identity_facebook_app_id != "" && var.identity_facebook_app_secret_arn != ""

  id_custom_domains = var.identity_custom_domains_enabled
  # AA-818 certificate from custom_domains.tf (same root); the validation resource, when present,
  # makes Terraform wait for ISSUED before Cognito gets the ARN.
  id_custom_domain_cert_arn = var.identity_custom_domain_certificate_arn != "" ? var.identity_custom_domain_certificate_arn : (
    local.cd_enabled == 1 ? aws_acm_certificate_validation.auth[0].certificate_arn : aws_acm_certificate.auth.arn
  )

  # ADR 0006 decision 3: group name = <app>-<role>. Precedence only matters for cognito:preferred_role (unused).
  id_staff_groups = {
    "cis-admin"           = { precedence = 10, description = "CIS admin (shared.admin_role = admin)" }
    "cis-reviewer"        = { precedence = 20, description = "CIS reviewer (shared.admin_role = reviewer)" }
    "cis-content"         = { precedence = 30, description = "CIS content (shared.admin_role = content)" }
    "booking-admin"       = { precedence = 40, description = "Booking staff admin" }
    "booking-sales"       = { precedence = 50, description = "Booking sales" }
    "booking-contracting" = { precedence = 60, description = "Booking contracting" }
    # S241 Q4/Q5 (AA-854): every Booking staff role has a group, content_creator included.
    "booking-content_creator" = { precedence = 70, description = "Booking content creator" }
    # AA-939 / root ADR 0006b decision 6: AA-Partner staff groups. crm-platform-admin writes on the L1 console
    # (/crm/ops/v1), crm-ops and crm-support use /crm/staff/v1 (support also needs an active owner grant, CRM-13b).
    "crm-platform-admin" = { precedence = 80, description = "AA-Partner L1 platform console writes (/crm/ops/v1)" }
    "crm-ops"            = { precedence = 81, description = "AA-Partner ops release (/crm/staff/v1, spec module 8)" }
    "crm-support"        = { precedence = 82, description = "AA-Partner owner-granted support sessions (/crm/staff/v1)" }
  }

  id_ext_idps_portal    = concat(["COGNITO"], local.id_ext_google ? ["Google"] : [])
  id_ext_idps_traveller = concat(["COGNITO"], local.id_ext_google ? ["Google"] : [], local.id_facebook ? ["Facebook"] : [])

  # Mapped attributes must be client-writable. email_verified is mapped by Google only (Facebook
  # sends none), so it is writable only while the Google IdP exists (see the CAUTION above).
  id_federated_writes = concat(["email"], local.id_ext_google ? ["email_verified"] : [], ["name"])

  # ADR 0006 decisions 2 and 7. Lifetimes: access/id in minutes, refresh in hours. WORKFORCE has
  # no social IdP (staff sign in with an email code), so its clients offer COGNITO only.
  id_workforce_clients = {
    "cis-admin" = {
      secret = true, access_minutes = 15, refresh_hours = 12
      idps   = ["COGNITO"], writes = ["name"]
    }
    "booking-staff" = {
      secret = true, access_minutes = 15, refresh_hours = 12
      idps   = ["COGNITO"], writes = ["name"]
    }
    # AA-911 decision D-1 (S246, root ADR 0006a A11): one Preview-only client per staff app, registered with ONLY
    # the app's fixed Preview host (identity_variables.tf). Same settings as the production client. A session on a
    # Preview host is therefore a token for THIS client_id, which the APIs cap at viewer (CIS
    # api/core/staff_identity.py, Booking app/auth/staff.py): unmerged preview code never holds a real role.
    # Adding keys to this map creates new clients only; the existing ones (and their client_id / secret) are
    # untouched. Each new client also gets its managed login style (aws_cognito_managed_login_branding.workforce).
    "cis-admin-preview" = {
      secret = true, access_minutes = 15, refresh_hours = 12
      idps   = ["COGNITO"], writes = ["name"]
    }
    "booking-staff-preview" = {
      secret = true, access_minutes = 15, refresh_hours = 12
      idps   = ["COGNITO"], writes = ["name"]
    }
    "breakglass" = {
      secret = true, access_minutes = 15, refresh_hours = 1
      idps   = ["COGNITO"], writes = ["name"]
    }
    # AA-939 / root ADR 0006b decision 6: the WORKFORCE client of the AA-Partner staff routes (/crm/staff/v1). Its
    # managed login style is created with it (aws_cognito_managed_login_branding.workforce covers the whole map).
    "crm-staff" = {
      secret = true, access_minutes = 15, refresh_hours = 12
      idps   = ["COGNITO"], writes = ["name"]
    }
  }
  id_external_clients = {
    "cis-portal" = {
      secret = true, access_minutes = 30, refresh_hours = 168
      idps   = local.id_ext_idps_portal, writes = local.id_ext_google ? local.id_federated_writes : ["name"]
    }
    "booking-customer" = {
      secret = false, access_minutes = 60, refresh_hours = 720
      idps   = local.id_ext_idps_traveller, writes = (local.id_ext_google || local.id_facebook) ? local.id_federated_writes : ["name"]
    }
    "tripplanner" = {
      secret = false, access_minutes = 60, refresh_hours = 720
      idps   = local.id_ext_idps_traveller, writes = (local.id_ext_google || local.id_facebook) ? local.id_federated_writes : ["name"]
    }
  }

  # Client NAMES (not ids) go into the EXTERNAL trigger env: ids would create a Terraform cycle.
  id_portal_client_names    = ["${local.idext_name}-cis-portal"]
  id_traveller_client_names = ["${local.idext_name}-booking-customer", "${local.idext_name}-tripplanner"]

  id_workforce_env = {
    ALLOWED_EMAIL_DOMAIN = lower(var.identity_staff_email_domain)
    STAFF_GROUPS         = join(",", keys(local.id_staff_groups))
    BREAKGLASS_EMAIL     = lower(var.identity_breakglass_email)
  }
  id_external_env = {
    PORTAL_CLIENT_NAMES    = join(",", local.id_portal_client_names)
    TRAVELLER_CLIENT_NAMES = join(",", local.id_traveller_client_names)
    GOOGLE_PROVIDER_NAME   = "Google"
    FACEBOOK_PROVIDER_NAME = "Facebook"
    NATIVE_SIGNUP_ENABLED  = tostring(local.id_ext_native_signup)
  }

  # Roles: `pure` = logs only (both pre token triggers and the WORKFORCE pre sign-up, which make no
  # Cognito call); `external-signup` = logs + ListUsers / AdminLinkProviderForUser /
  # DescribeUserPoolClient on the EXTERNAL pool.
  id_triggers = {
    "workforce-pre-sign-up" = { handler = "workforce.pre_sign_up", role = "pure", env = local.id_workforce_env, pool = "workforce" }
    "workforce-pre-token"   = { handler = "workforce.pre_token_generation", role = "pure", env = local.id_workforce_env, pool = "workforce" }
    "external-pre-sign-up"  = { handler = "external.pre_sign_up", role = "external-signup", env = local.id_external_env, pool = "external" }
    "external-pre-token"    = { handler = "external.pre_token_generation", role = "pure", env = local.id_external_env, pool = "external" }
  }
  id_trigger_roles = toset(["pure", "external-signup"])

  id_pool_arns = {
    workforce = aws_cognito_user_pool.workforce.arn
    external  = aws_cognito_user_pool.external.arn
  }
}

# =============================================================================
# Trigger Lambdas (ADR 0006 decision 5). Outside the VPC, no DB, timeout 5 s (Cognito's hard
# limit), no reserved concurrency (a cap could throttle sign-ins). Released through a `live`
# alias pointing at a published version; rollback = repoint the alias.
# =============================================================================
data "archive_file" "identity_triggers" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_src/identity_triggers"
  output_path = "${path.module}/lambda_src/identity_triggers.zip"
  excludes    = ["__pycache__"]
}

data "aws_iam_policy_document" "identity_lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }
}

# The AA-806 workload boundary is mandatory: the CI apply role's boundary denies CreateRole without
# it (DenyCreateRoleWithoutWorkloadBoundary, cicd_split.tf). Names aa-identity-<env>-*-trigger sit
# inside local.tf_managed_role_arns (aa-*-<env>-*), so the apply role may create, tag and pass them.
resource "aws_iam_role" "identity_trigger" {
  for_each             = local.id_trigger_roles
  name                 = "${local.id_prefix}-${each.key}-trigger"
  assume_role_policy   = data.aws_iam_policy_document.identity_lambda_assume.json
  permissions_boundary = aws_iam_policy.workload_boundary.arn
  tags                 = local.id_tags
}

# 365 days (S241 D-09: security/audit logs 365, app logs 30): these are auth audit logs
# (break-glass token issued, admin-create with staff email, refused sign-ups). Volume is tiny.
resource "aws_cloudwatch_log_group" "identity_trigger" {
  for_each          = local.id_triggers
  name              = "/aws/lambda/${local.id_prefix}-${each.key}"
  retention_in_days = 365
  tags              = local.id_tags
}

# Logs: each role may write only the log groups of the functions that use it.
resource "aws_iam_role_policy" "identity_trigger_logs" {
  for_each = local.id_trigger_roles
  name     = "${local.id_prefix}-${each.key}-logs"
  role     = aws_iam_role.identity_trigger[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "WriteOwnLogs"
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = [for k, t in local.id_triggers : "${aws_cloudwatch_log_group.identity_trigger[k].arn}:log-stream:*" if t.role == each.key]
    }]
  })
}

# Cognito API on the trigger's OWN pool only, and only for the EXTERNAL pre sign-up (the other
# three triggers are pure functions of the event). Separate resource so the pool -> Lambda -> role
# chain has no cycle.
resource "aws_iam_role_policy" "identity_external_signup_cognito" {
  name = "${local.id_prefix}-external-signup-cognito"
  role = aws_iam_role.identity_trigger["external-signup"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "OwnPoolLinkAndClientName"
      Effect   = "Allow"
      Action   = ["cognito-idp:ListUsers", "cognito-idp:AdminLinkProviderForUser", "cognito-idp:DescribeUserPoolClient"]
      Resource = aws_cognito_user_pool.external.arn
    }]
  })
}

resource "aws_lambda_function" "identity_trigger" {
  for_each = local.id_triggers

  function_name = "${local.id_prefix}-${each.key}"
  role          = aws_iam_role.identity_trigger[each.value.role].arn
  handler       = each.value.handler
  runtime       = "python3.12"
  architectures = ["arm64"]
  timeout       = 5
  memory_size   = 256
  publish       = true

  filename         = data.archive_file.identity_triggers.output_path
  source_code_hash = data.archive_file.identity_triggers.output_base64sha256

  environment {
    variables = each.value.env
  }

  depends_on = [aws_cloudwatch_log_group.identity_trigger]

  tags = merge(local.id_tags, { Function = each.key })
}

resource "aws_lambda_alias" "identity_trigger_live" {
  for_each         = local.id_triggers
  name             = "live"
  function_name    = aws_lambda_function.identity_trigger[each.key].function_name
  function_version = aws_lambda_function.identity_trigger[each.key].version
}

resource "aws_lambda_permission" "identity_trigger_cognito" {
  for_each      = local.id_triggers
  statement_id  = "AllowCognitoInvokeLive"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.identity_trigger[each.key].function_name
  qualifier     = aws_lambda_alias.identity_trigger_live[each.key].name
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = local.id_pool_arns[each.value.pool]
}

# =============================================================================
# User pools (ADR 0006 decision 1). username_attributes and case sensitivity can never change:
# changing them means a new pool and new `sub` values for everyone.
# =============================================================================
resource "aws_cognito_user_pool" "workforce" {
  name                = local.idwf_name
  user_pool_tier      = "ESSENTIALS"
  deletion_protection = "ACTIVE"

  username_attributes = ["email"]
  username_configuration {
    case_sensitive = false
  }
  auto_verified_attributes = ["email"]

  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "admin_only"
      priority = 1
    }
  }

  # TOTP is for break-glass only; no SMS configuration (removing SMS later forces a new pool).
  mfa_configuration = "OPTIONAL"
  software_token_mfa_configuration {
    enabled = true
  }

  password_policy {
    minimum_length                   = 16
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 7
  }

  sign_in_policy {
    allowed_first_auth_factors = local.id_first_factors
  }

  user_attribute_update_settings {
    attributes_require_verification_before_update = ["email"]
  }

  email_configuration {
    email_sending_account = local.id_ses_enabled ? "DEVELOPER" : "COGNITO_DEFAULT"
    source_arn            = local.id_ses_enabled ? local.id_ses_identity_arn : null
    from_email_address    = local.id_ses_enabled ? var.identity_ses_from_address : null
    configuration_set     = local.id_ses_enabled ? local.id_ses_config_set["workforce"] : null
  }

  lambda_config {
    pre_sign_up          = aws_lambda_alias.identity_trigger_live["workforce-pre-sign-up"].arn
    pre_token_generation = aws_lambda_alias.identity_trigger_live["workforce-pre-token"].arn
    pre_token_generation_config {
      lambda_arn     = aws_lambda_alias.identity_trigger_live["workforce-pre-token"].arn
      lambda_version = "V2_0"
    }
  }

  # No custom attributes (ADR 0006 decision 1: they can never be changed or removed).

  tags = merge(local.id_tags, { Pool = "workforce" })

  lifecycle {
    precondition {
      condition     = endswith(lower(var.identity_breakglass_email), "@${lower(var.identity_staff_email_domain)}")
      error_message = "identity_breakglass_email must be inside identity_staff_email_domain, or the pre token trigger denies it."
    }
    precondition {
      condition     = !local.id_ses_enabled || var.identity_ses_from_address != ""
      error_message = "identity_ses_enabled = true needs identity_ses_from_address (inside the AA-811 identity's domain)."
    }
  }
}

resource "aws_cognito_user_pool" "external" {
  name                = local.idext_name
  user_pool_tier      = "ESSENTIALS"
  deletion_protection = "ACTIVE"

  username_attributes = ["email"]
  username_configuration {
    case_sensitive = false
  }
  auto_verified_attributes = ["email"]

  # Self sign-up allowed at pool level; the pre sign-up trigger decides per app client.
  admin_create_user_config {
    allow_admin_create_user_only = false
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "admin_only"
      priority = 1
    }
  }

  # OFF: an enrolled TOTP would block email-code sign-in for passwordless users.
  mfa_configuration = "OFF"

  password_policy {
    minimum_length                   = 16
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 7
  }

  sign_in_policy {
    allowed_first_auth_factors = local.id_first_factors
  }

  user_attribute_update_settings {
    attributes_require_verification_before_update = ["email"]
  }

  email_configuration {
    email_sending_account = local.id_ses_enabled ? "DEVELOPER" : "COGNITO_DEFAULT"
    source_arn            = local.id_ses_enabled ? local.id_ses_identity_arn : null
    from_email_address    = local.id_ses_enabled ? var.identity_ses_from_address : null
    configuration_set     = local.id_ses_enabled ? local.id_ses_config_set["external"] : null
  }

  lambda_config {
    pre_sign_up          = aws_lambda_alias.identity_trigger_live["external-pre-sign-up"].arn
    pre_token_generation = aws_lambda_alias.identity_trigger_live["external-pre-token"].arn
    pre_token_generation_config {
      lambda_arn     = aws_lambda_alias.identity_trigger_live["external-pre-token"].arn
      lambda_version = "V2_0"
    }
  }

  tags = merge(local.id_tags, { Pool = "external" })

  # The native sign-up gate is enforced, not a silent AND (AA-854 review): public self sign-up on
  # booking-customer / tripplanner without the WAF rate rules would let a script burn MAU and the
  # SES reputation that staff email codes share (ADR 0006 Costs); without SES the flag would be
  # ignored without notice.
  lifecycle {
    precondition {
      condition     = !var.identity_external_native_signup_enabled || var.identity_waf_enabled
      error_message = "identity_external_native_signup_enabled = true needs identity_waf_enabled = true (per-IP rate rules first; WAF is billable, quote and Nghiep's go per S241 D-19)."
    }
    precondition {
      condition     = !var.identity_external_native_signup_enabled || var.identity_ses_enabled
      error_message = "identity_external_native_signup_enabled = true needs identity_ses_enabled = true (native sign-up uses EMAIL_OTP, which needs the SES DEVELOPER email configuration)."
    }
  }
}

# =============================================================================
# Groups (WORKFORCE only). Written only by the staff directory (AA-816), never in the console.
# =============================================================================
resource "aws_cognito_user_group" "workforce" {
  for_each     = local.id_staff_groups
  name         = each.key
  user_pool_id = aws_cognito_user_pool.workforce.id
  description  = each.value.description
  precedence   = each.value.precedence
}

# =============================================================================
# Social identity providers, EXTERNAL only (WORKFORCE has none: staff sign in with an email code,
# ADR 0006 S236). Secrets are read from Secrets Manager (values set out-of-band by Nghiep); Cognito
# stores the client secret, so it also lands in Terraform state (encrypted S3).
# =============================================================================
data "aws_secretsmanager_secret_version" "identity_external_google" {
  count     = local.id_ext_google ? 1 : 0
  secret_id = var.identity_external_google_client_secret_arn
}

data "aws_secretsmanager_secret_version" "identity_facebook" {
  count     = local.id_facebook ? 1 : 0
  secret_id = var.identity_facebook_app_secret_arn
}

resource "aws_cognito_identity_provider" "external_google" {
  count         = local.id_ext_google ? 1 : 0
  user_pool_id  = aws_cognito_user_pool.external.id
  provider_name = "Google"
  provider_type = "Google"

  provider_details = {
    client_id        = var.identity_external_google_client_id
    client_secret    = data.aws_secretsmanager_secret_version.identity_external_google[0].secret_string
    authorize_scopes = "openid email profile"
  }

  attribute_mapping = {
    email          = "email"
    email_verified = "email_verified"
    name           = "name"
    username       = "sub"
  }
}

# Facebook sends no email_verified: never mapped, never linked (ADR 0006 decision 6).
resource "aws_cognito_identity_provider" "external_facebook" {
  count         = local.id_facebook ? 1 : 0
  user_pool_id  = aws_cognito_user_pool.external.id
  provider_name = "Facebook"
  provider_type = "Facebook"

  provider_details = {
    client_id        = var.identity_facebook_app_id
    client_secret    = data.aws_secretsmanager_secret_version.identity_facebook[0].secret_string
    authorize_scopes = "public_profile,email"
    api_version      = var.identity_facebook_api_version
  }

  attribute_mapping = {
    email    = "email"
    name     = "name"
    username = "id"
  }
}

# =============================================================================
# App clients (ADR 0006 decisions 2 and 7). Authorization code + PKCE; scopes openid email profile
# only (never aws.cognito.signin.user.admin); ALLOW_USER_AUTH only, refresh-token rotation on
# (ALLOW_REFRESH_TOKEN_AUTH is incompatible with rotation: refresh via /oauth2/token).
# =============================================================================
resource "aws_cognito_user_pool_client" "workforce" {
  for_each     = local.id_workforce_clients
  name         = "${local.idwf_name}-${each.key}"
  user_pool_id = aws_cognito_user_pool.workforce.id

  generate_secret                      = each.value.secret
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  explicit_auth_flows                  = ["ALLOW_USER_AUTH"]
  supported_identity_providers         = each.value.idps
  callback_urls                        = var.identity_client_urls[each.key].callback_urls
  logout_urls                          = var.identity_client_urls[each.key].logout_urls

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

  read_attributes  = distinct(concat(["email", "email_verified", "name"], each.value.writes))
  write_attributes = each.value.writes
}

resource "aws_cognito_user_pool_client" "external" {
  for_each     = local.id_external_clients
  name         = "${local.idext_name}-${each.key}"
  user_pool_id = aws_cognito_user_pool.external.id

  generate_secret                      = each.value.secret
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  explicit_auth_flows                  = ["ALLOW_USER_AUTH"]
  supported_identity_providers         = each.value.idps
  callback_urls                        = var.identity_client_urls[each.key].callback_urls
  logout_urls                          = var.identity_client_urls[each.key].logout_urls

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

  read_attributes  = distinct(concat(["email", "email_verified", "name"], each.value.writes))
  write_attributes = each.value.writes

  depends_on = [
    aws_cognito_identity_provider.external_google,
    aws_cognito_identity_provider.external_facebook,
  ]
}

# =============================================================================
# Domains (ADR 0006 decision 10). Prefix domains always (Dev, and the fallback if a custom domain
# breaks). Custom domains only with identity_custom_domains_enabled = true, which needs the AA-818
# us-east-1 certificate ISSUED and an A record on the parent lumiguides.it.com (Cognito refuses the
# custom domain otherwise: dns.tf aws_route53_record.apex, hence the depends_on). DNS: Route 53
# alias A record of each name to the CloudFront distribution Cognito creates.
#
# AA-816 (S242): Chrome Safe Browsing flagged the staff sign-in as deceptive: aa-cis. redirected to
# aa365-staff-auth-dev.auth.us-west-1.amazoncognito.com with the default AWS look. The CIS frontend
# now sends staff to https://staff-auth.lumiguides.it.com (managed_login base URL output below).
# Creating a custom domain needs cloudfront:UpdateDistribution on the caller (AWS docs; cicd_split.tf
# statement CognitoCustomDomainCloudFront, gated by time_sleep.wait_for_iam_propagation). First
# apply: if Cognito still answers "unable to resolve the A record of the parent domain" (resolver
# negative cache: min(SOA TTL 900, SOA minimum) = about 15 minutes on Route 53), wait ~15 min and
# re-run the apply.
# =============================================================================
resource "aws_cognito_user_pool_domain" "workforce_prefix" {
  domain                = var.identity_workforce_domain_prefix
  user_pool_id          = aws_cognito_user_pool.workforce.id
  managed_login_version = 2
}

resource "aws_cognito_user_pool_domain" "external_prefix" {
  domain                = var.identity_external_domain_prefix
  user_pool_id          = aws_cognito_user_pool.external.id
  managed_login_version = 2
}

resource "aws_cognito_user_pool_domain" "workforce_custom" {
  count                 = local.id_custom_domains ? 1 : 0
  domain                = var.identity_workforce_custom_domain
  certificate_arn       = local.id_custom_domain_cert_arn
  user_pool_id          = aws_cognito_user_pool.workforce.id
  managed_login_version = 2

  depends_on = [aws_route53_record.apex, time_sleep.wait_for_iam_propagation]
}

resource "aws_cognito_user_pool_domain" "external_custom" {
  count                 = local.id_custom_domains ? 1 : 0
  domain                = var.identity_external_custom_domain
  certificate_arn       = local.id_custom_domain_cert_arn
  user_pool_id          = aws_cognito_user_pool.external.id
  managed_login_version = 2

  depends_on = [aws_route53_record.apex, time_sleep.wait_for_iam_propagation]
}

locals {
  id_custom_domain_aliases = local.id_custom_domains ? {
    workforce = aws_cognito_user_pool_domain.workforce_custom[0]
    external  = aws_cognito_user_pool_domain.external_custom[0]
  } : {}
}

resource "aws_route53_record" "identity_custom_domain" {
  for_each = local.id_custom_domain_aliases

  zone_id = aws_route53_zone.lumiguides.zone_id
  name    = each.value.domain
  type    = "A"

  alias {
    name                   = each.value.cloudfront_distribution
    zone_id                = each.value.cloudfront_distribution_zone_id # Z2FDTNDATAQYW2 (CloudFront)
    evaluate_target_health = false
  }
}

# =============================================================================
# Managed login branding (AA-816 S242): the WORKFORCE sign-in pages in the Adventure Asia style of
# the CIS /login card (cream F4F1EC page, white card radius 16, gold DB9628 pill button, ink
# 1F2933), light mode only like /login. Cognito has no setting for the page title, the "Sign in"
# heading or the font, so the brand name and "Staff sign-in" are drawn in the header SVG. The AWS
# look (background graphic, blue palette, illustrations) is switched off. Accessibility: input and
# checkbox borders 9099A6, focus ring and links 9E6E16 (>= 3:1 / ~4.5:1 on white); the white text
# on the gold primary button (2.5:1) matches adventure.asia and /login on purpose.
#
# One style per client (Cognito allows exactly one). AA-911 (S246) adds two keys (the Preview-only clients):
# their styles are CREATED with the clients, the existing three are untouched. The three styles were first created with the
# CLI (--use-cognito-provided-values) in S242, adopted into state by an import block, and replaced
# by the first apply of #194 (new managed_login_branding_id per client); the import block and its
# id map were removed in S243 (the addresses are in state, so it was dead code). Any future change
# to the asset set still forces a replacement: the apply deletes and recreates each style (a few
# seconds without a style per client). Because the delete runs before the create, a payload Cognito
# rejects would leave every WORKFORCE client (breakglass included) without a style: pre-validate the
# exact payload on a temporary throwaway client first, never on a live EXTERNAL client (each EXTERNAL client
# has its own Terraform-managed style since S249; runbook + rollback commands in
# docs/implementation-notes/AA-816-staff-auth-domain.md). If Cognito rejects buttons.borderRadius
# 24, use 16.
# Assets: accounts/aa365/assets/identity/ (form logo = the official CIS frontend logo PNG; header,
# footer and favicon SVGs use only Cognito-allowed SVG elements; header/footer text is outlined to
# paths in Fahkwang SemiBold / Poppins Regular, since an SVG shown as an image cannot load web fonts).
# Each request <= 2 MB (assets ~41 KB).
# =============================================================================
locals {
  id_branding_assets_dir = "${path.module}/assets/identity"

  id_branding_assets = [
    { category = "FORM_LOGO", extension = "PNG", file = "aa-form-logo.png" },
    { category = "PAGE_HEADER_LOGO", extension = "SVG", file = "aa-header-logo.svg" },
    { category = "FAVICON_SVG", extension = "SVG", file = "aa-favicon.svg" },
  ]

  # Only values that differ from Cognito's defaults. Colours are RRGGBBAA.
  id_branding_settings_workforce = {
    categories = {
      global = { colorSchemeMode = "LIGHT", pageHeader = { enabled = true }, pageFooter = { enabled = false } }
      form   = { displayGraphics = false }
    }
    componentClasses = {
      buttons = { borderRadius = 24.0 }
      input = {
        borderRadius = 8.0
        lightMode    = { defaults = { backgroundColor = "ffffffff", borderColor = "9099a6ff" }, placeholderColor = "6b7380ff" }
      }
      inputLabel       = { lightMode = { textColor = "1f2933ff" } }
      inputDescription = { lightMode = { textColor = "6b7380ff" } }
      focusState       = { lightMode = { borderColor = "9e6e16ff" } }
      link             = { lightMode = { defaults = { textColor = "9e6e16ff" }, hover = { textColor = "1f2933ff" } } }
      optionControls = {
        lightMode = {
          defaults = { backgroundColor = "ffffffff", borderColor = "9099a6ff" }
          selected = { backgroundColor = "db9628ff", foregroundColor = "ffffffff" }
        }
      }
      divider = { lightMode = { borderColor = "e9e4dbff" } }
      dropDown = {
        borderRadius = 8.0
        lightMode = {
          hover = { itemBackgroundColor = "fbf3e3ff", itemBorderColor = "dda64eff", itemTextColor = "1f2933ff" }
          match = { itemTextColor = "9e6e16ff" }
        }
      }
    }
    components = {
      pageBackground = { image = { enabled = false }, lightMode = { color = "f4f1ecff" } }
      pageHeader = {
        logo      = { enabled = true, location = "START" }
        lightMode = { background = { color = "ffffffff" }, borderColor = "e9e4dbff" }
      }
      form = {
        borderRadius = 16.0
        logo         = { enabled = true, location = "CENTER", position = "TOP", formInclusion = "IN" }
        lightMode    = { backgroundColor = "ffffffff", borderColor = "d8d3ccff" }
      }
      pageText = { lightMode = { headingColor = "1f2933ff", bodyColor = "33363dff", descriptionColor = "4a5568ff" } }
      primaryButton = {
        lightMode = {
          defaults = { backgroundColor = "db9628ff", textColor = "ffffffff" }
          hover    = { backgroundColor = "9e6e16ff", textColor = "ffffffff" }
          active   = { backgroundColor = "9e6e16ff", textColor = "ffffffff" }
        }
      }
      secondaryButton = {
        lightMode = {
          defaults = { backgroundColor = "ffffffff", borderColor = "dda64eff", textColor = "9e6e16ff" }
          hover    = { backgroundColor = "fbf3e3ff", borderColor = "db9628ff", textColor = "9e6e16ff" }
          active   = { backgroundColor = "f4e2c2ff", borderColor = "9e6e16ff", textColor = "9e6e16ff" }
        }
      }
      alert   = { lightMode = { error = { backgroundColor = "fdf4f3ff", borderColor = "c20101ff" } } }
      favicon = { enabledTypes = ["SVG"] }
    }
  }
}

resource "aws_cognito_managed_login_branding" "workforce" {
  for_each = aws_cognito_user_pool_client.workforce

  user_pool_id = aws_cognito_user_pool.workforce.id
  client_id    = each.value.id
  settings     = jsonencode(local.id_branding_settings_workforce)

  dynamic "asset" {
    for_each = local.id_branding_assets
    content {
      bytes      = filebase64("${local.id_branding_assets_dir}/${asset.value.file}")
      category   = asset.value.category
      color_mode = "LIGHT"
      extension  = asset.value.extension
    }
  }
}

# =============================================================================
# EXTERNAL managed login branding (AA-935 follow-up, S249). With managed_login_version = 2 a client that has
# no style gets HTTP 403 "Login pages unavailable" on /login and /oauth2/authorize, on BOTH EXTERNAL domains
# (prefix and auth.lumiguides.it.com): the style is per client, not per domain. Before this resource no
# EXTERNAL client had one, so no traveller, tenant or CRM partner user could sign in through managed login.
#
# One style per EXTERNAL client, for_each over the client resource itself: a key added to
# id_external_clients gets its style in the same apply (tools/terraform/managed_login_branding.py fails CI
# for an interactive client of a v2 pool without one; it covers the AA-939 partner pool too).
#
# Same Adventure Asia look as WORKFORCE (local.id_branding_settings_workforce: colours, card, buttons), with
# one difference: the page header is OFF and its asset is left out. The WORKFORCE header SVG reads "Staff
# sign-in" (Cognito has no title/heading setting, the text is drawn in the SVG), which is wrong for
# travellers and partners; the form logo (mark + "Adventure Asia") carries the brand instead. A header SVG
# without "Staff" can be added later as a new asset (that change replaces each style, see the WORKFORCE note).
#
# Create only: no EXTERNAL client has a style today, so a payload Cognito rejects leaves them exactly as now
# (still 403); nothing is deleted first. S242 pre-validated the WORKFORCE payload on the EXTERNAL tripplanner
# client (accepted); this one is that payload minus the header. Cost: $0 (branding is part of the Essentials
# tier the pools already run).
# =============================================================================
locals {
  id_branding_assets_external = [for a in local.id_branding_assets : a if a.category != "PAGE_HEADER_LOGO"]

  id_branding_settings_external = {
    categories = {
      global = { colorSchemeMode = "LIGHT", pageHeader = { enabled = false }, pageFooter = { enabled = false } }
      form   = local.id_branding_settings_workforce.categories.form
    }
    componentClasses = local.id_branding_settings_workforce.componentClasses
    components       = { for k, v in local.id_branding_settings_workforce.components : k => v if k != "pageHeader" }
  }
}

resource "aws_cognito_managed_login_branding" "external" {
  for_each = aws_cognito_user_pool_client.external

  user_pool_id = aws_cognito_user_pool.external.id
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

# =============================================================================
# WAF on the pools (ADR 0006 decision 1): per-IP rate limits on sign-up / sign-in / code resend
# (MAU + SES abuse) and a global per-IP cap. One shared web ACL (same rules for the WORKFORCE, EXTERNAL
# and PARTNER pools; the partner association is in identity_partner.tf). The M2M pool has no managed
# login and no public sign-up, and is not associated.
# OFF by default (S241 D-19: every new AWS spend is quoted and approved first). Cost when on, us-west-1
# list prices: $5/web ACL + $1/rule x 3 + $0.60 per million requests = about $8/month for this one
# shared ACL (AA-908 added the third rule; it was $7 with two); the ADR's $12-15/month figure assumes two
# separate ACLs. Turn on before identity_external_native_signup_enabled. ON since AA-908 (S250, tfvars).
#
# AA-908: what the rate rules see. Two scoped rules share identity_waf_signup_rate_limit:
#   - SignUpAndCodeRatePerIp: the public user-pool API (cognito-idp.<region>.amazonaws.com, header
#     x-amz-target) for SignUp, InitiateAuth and ResendConfirmationCode;
#   - ManagedLoginPostRatePerIp: every POST to managed login except /oauth2/* (sign-in /login, /login/continue, /verifyCode,
#     /verifyPassword, sign-up /signup and /signup/confirm/resend-code, /forgotPassword, the email-MFA
#     resend). Managed login v2 is a server-rendered app on the pool's domain: its forms post to those
#     paths and never send x-amz-target, so an API-only scope would leave the browser sign-up path (the
#     one travellers use, and the one that sends SES mail) under the global cap only.
#   /oauth2/token (code exchange, refresh, client credentials) and /oauth2/revoke are left to the global
#   cap: they are called server-side by the app BFFs from shared egress addresses (Vercel), need a code,
#   a refresh token or a client secret, and send no mail.
# CI sign-ins (AA-CIS-App e2e-cognito.yml / ui-smoke.yml smoke-staff, AA-Partner e2e-dev.yml) are browser
# sign-ins through managed login on GitHub-hosted runners: about 3-4 scoped POSTs and fewer than 10
# requests on the pool domain per sign-in (the page assets come from Cognito's CloudFront hosts, which
# the web ACL never sees; checked 24/10/2026 on auth.lumiguides.it.com), 1-2 sign-ins per run, one run at
# a time per concurrency group, each job on its own runner address. That is under 10 % of either limit,
# so there is no CI allow-list: GitHub-hosted runners have no fixed addresses to list, and a shared-secret
# bypass header would be one more secret that skips the abuse limits. If a limit ever bites, the alarm
# identity_waf_blocked below mails the alert topic and the fix is one tfvars line
# (identity_waf_signup_rate_limit / identity_waf_global_rate_limit).
# =============================================================================
resource "aws_wafv2_web_acl" "identity" {
  count       = var.identity_waf_enabled ? 1 : 0
  name        = "${local.id_prefix}-pools"
  description = "Rate limits for the WORKFORCE, EXTERNAL and PARTNER Cognito pools (AA-703, AA-908)"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "SignUpAndCodeRatePerIp"
    priority = 0

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.identity_waf_signup_rate_limit
        aggregate_key_type = "IP"

        scope_down_statement {
          or_statement {
            dynamic "statement" {
              for_each = ["SignUp", "InitiateAuth", "ResendConfirmationCode"]
              content {
                byte_match_statement {
                  search_string         = "AWSCognitoIdentityProviderService.${statement.value}"
                  positional_constraint = "EXACTLY"
                  field_to_match {
                    single_header {
                      name = "x-amz-target"
                    }
                  }
                  text_transformation {
                    priority = 0
                    type     = "NONE"
                  }
                }
              }
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.id_prefix}-signup-rate"
      sampled_requests_enabled   = true
    }
  }

  # AA-908: managed login form posts (sign-in, sign-up, code verify and resend), see the header. A rule of
  # its own because the provider does not accept a NOT inside an AND inside the OR scope-down above.
  rule {
    name     = "ManagedLoginPostRatePerIp"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.identity_waf_signup_rate_limit
        aggregate_key_type = "IP"

        scope_down_statement {
          and_statement {
            statement {
              byte_match_statement {
                search_string         = "POST"
                positional_constraint = "EXACTLY"
                field_to_match {
                  method {}
                }
                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }
            statement {
              not_statement {
                statement {
                  byte_match_statement {
                    search_string         = "/oauth2/"
                    positional_constraint = "STARTS_WITH"
                    field_to_match {
                      uri_path {}
                    }
                    text_transformation {
                      priority = 0
                      type     = "LOWERCASE"
                    }
                  }
                }
              }
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.id_prefix}-managed-login-post-rate"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "GlobalRatePerIp"
    priority = 2

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.identity_waf_global_rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.id_prefix}-global-rate"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.id_prefix}-pools"
    sampled_requests_enabled   = true
  }

  tags = local.id_tags
}

resource "aws_wafv2_web_acl_association" "identity" {
  for_each     = var.identity_waf_enabled ? local.id_pool_arns : {}
  resource_arn = each.value
  web_acl_arn  = aws_wafv2_web_acl.identity[0].arn
}

# AA-908: any block by either rate rule (all three pools share the ACL) mails the alert topic, so a
# throttled CI sign-in or a real attack is seen at once. Raise the limit in tfvars if it is legitimate.
resource "aws_cloudwatch_metric_alarm" "identity_waf_blocked" {
  count               = var.identity_waf_enabled ? 1 : 0
  alarm_name          = "${local.id_prefix}-waf-blocked"
  alarm_description   = "The Cognito web ACL ${local.id_prefix}-pools blocked requests (per-IP rate rules: sign-up/sign-in/code abuse, or a legitimate burst such as CI sign-ins). AA-908.${local.runbook_suffix.cognito_login}"
  namespace           = "AWS/WAFV2"
  metric_name         = "BlockedRequests"
  dimensions          = { WebACL = aws_wafv2_web_acl.identity[0].name, Region = var.aws_region, Rule = "ALL" }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  tags                = local.id_tags
}

# =============================================================================
# Break-glass secret container (ADR 0006 decision 11). No value in Terraform: Nghiep stores the
# password + TOTP seed after the one-off bootstrap script creates the (disabled) user.
# =============================================================================
resource "aws_secretsmanager_secret" "identity_breakglass" {
  name                    = "aa-identity/${var.environment}/breakglass"
  description             = "WORKFORCE break-glass credentials (password + TOTP seed). Value set out-of-band. AA-703."
  recovery_window_in_days = var.environment == "dev" ? 0 : 30
  tags                    = local.id_tags
}

# =============================================================================
# Alarms (ADR 0006 decisions 5 and 11). A denial is raised as an exception, so Lambda `Errors`
# also counts refusals: the Errors alarm uses a burst threshold, while unexpected exceptions are
# caught exactly by the `*_error` log metric.
# Notifications: alarm_actions AND ok_actions (S241 D-20 "e-mail on OK too"), like every alarm on
# the topic since AA-872.
# =============================================================================
resource "aws_cloudwatch_log_metric_filter" "identity_trigger_unexpected" {
  for_each       = local.id_triggers
  name           = "${local.id_prefix}-${each.key}-unexpected"
  log_group_name = aws_cloudwatch_log_group.identity_trigger[each.key].name
  pattern        = "{ $.event = \"*_error\" }"

  metric_transformation {
    name          = "TriggerUnexpectedError"
    namespace     = "AA/Identity"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "identity_trigger_unexpected" {
  alarm_name          = "${local.id_prefix}-trigger-unexpected-error"
  alarm_description   = "An identity trigger hit an unexpected exception (fail closed: sign-ins are being refused). AA-703.${local.runbook_suffix.cognito_login}"
  namespace           = "AA/Identity"
  metric_name         = "TriggerUnexpectedError"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  tags                = local.id_tags
}

resource "aws_cloudwatch_metric_alarm" "identity_trigger_errors" {
  for_each            = local.id_triggers
  alarm_name          = "${local.id_prefix}-${each.key}-errors"
  alarm_description   = "Burst of refusals/errors from ${each.key} (abuse or a broken release). AA-703.${local.runbook_suffix.cognito_login}"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.identity_trigger[each.key].function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 20
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  tags                = local.id_tags
}

resource "aws_cloudwatch_metric_alarm" "identity_trigger_throttles" {
  for_each            = local.id_triggers
  alarm_name          = "${local.id_prefix}-${each.key}-throttles"
  alarm_description   = "${each.key} is throttled: sign-ins are refused. AA-703.${local.runbook_suffix.cognito_login}"
  namespace           = "AWS/Lambda"
  metric_name         = "Throttles"
  dimensions          = { FunctionName = aws_lambda_function.identity_trigger[each.key].function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  tags                = local.id_tags
}

resource "aws_cloudwatch_metric_alarm" "identity_trigger_duration" {
  for_each            = local.id_triggers
  alarm_name          = "${local.id_prefix}-${each.key}-duration-p99"
  alarm_description   = "${each.key} p99 duration above 3 s (Cognito kills triggers at 5 s). AA-703.${local.runbook_suffix.cognito_login}"
  namespace           = "AWS/Lambda"
  metric_name         = "Duration"
  dimensions          = { FunctionName = aws_lambda_function.identity_trigger[each.key].function_name }
  extended_statistic  = "p99"
  period              = 300
  evaluation_periods  = 1
  threshold           = 3000
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  tags                = local.id_tags
}

resource "aws_cloudwatch_log_metric_filter" "identity_breakglass" {
  name           = "${local.id_prefix}-breakglass-token"
  log_group_name = aws_cloudwatch_log_group.identity_trigger["workforce-pre-token"].name
  pattern        = "{ $.event = \"breakglass_token_issued\" }"

  metric_transformation {
    name          = "BreakglassTokenIssued"
    namespace     = "AA/Identity"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "identity_breakglass" {
  alarm_name          = "${local.id_prefix}-breakglass-token-issued"
  alarm_description   = "A token was issued to the break-glass account. Log the use in the session log (ADR 0006 decision 11). AA-703.${local.runbook_suffix.break_glass}"
  namespace           = "AA/Identity"
  metric_name         = "BreakglassTokenIssued"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  tags                = local.id_tags
}

# =============================================================================
# Outputs. Issuer = the pool endpoint as Cognito reports it; verify against the pool's
# /.well-known/openid-configuration after apply (ADR 0006 decision 8: never hand-build it).
# Client secrets are NOT output: read them with describe-user-pool-client when wiring the BFFs.
# =============================================================================
output "identity_workforce_pool_id" {
  value = aws_cognito_user_pool.workforce.id
}

output "identity_external_pool_id" {
  value = aws_cognito_user_pool.external.id
}

output "identity_workforce_issuer" {
  value = "https://${aws_cognito_user_pool.workforce.endpoint}"
}

output "identity_external_issuer" {
  value = "https://${aws_cognito_user_pool.external.endpoint}"
}

output "identity_workforce_jwks_url" {
  value = "https://${aws_cognito_user_pool.workforce.endpoint}/.well-known/jwks.json"
}

output "identity_external_jwks_url" {
  value = "https://${aws_cognito_user_pool.external.endpoint}/.well-known/jwks.json"
}

output "identity_workforce_client_ids" {
  value = { for k, c in aws_cognito_user_pool_client.workforce : k => c.id }
}

output "identity_external_client_ids" {
  value = { for k, c in aws_cognito_user_pool_client.external : k => c.id }
}

# EXTERNAL moves to auth.lumiguides.it.com with custom domains on, now that its clients have a managed login
# style (aws_cognito_managed_login_branding.external); crm_web.tf already uses the same host.
output "identity_managed_login_base_urls" {
  value = {
    workforce = local.id_custom_domains ? "https://${var.identity_workforce_custom_domain}" : "https://${aws_cognito_user_pool_domain.workforce_prefix.domain}.auth.${var.aws_region}.amazoncognito.com"
    external  = local.id_custom_domains ? "https://${var.identity_external_custom_domain}" : "https://${aws_cognito_user_pool_domain.external_prefix.domain}.auth.${var.aws_region}.amazoncognito.com"
  }
}

# Exact redirect URIs to register in the EXTERNAL Google / Facebook consoles (WORKFORCE has no IdP).
output "identity_idp_redirect_uris" {
  value = concat(
    ["https://${var.identity_external_domain_prefix}.auth.${var.aws_region}.amazoncognito.com/oauth2/idpresponse"],
    ["https://${var.identity_external_custom_domain}/oauth2/idpresponse"],
  )
}

output "identity_custom_domain_cloudfront_targets" {
  description = "CloudFront targets of the auth custom domains (Route 53 alias records aws_route53_record.identity_custom_domain point at them)."
  value = local.id_custom_domains ? {
    (var.identity_workforce_custom_domain) = aws_cognito_user_pool_domain.workforce_custom[0].cloudfront_distribution
    (var.identity_external_custom_domain)  = aws_cognito_user_pool_domain.external_custom[0].cloudfront_distribution
  } : {}
}

output "identity_workforce_branding_ids" {
  description = "Managed login branding id per WORKFORCE client (changes when a style is replaced)."
  value       = { for k, b in aws_cognito_managed_login_branding.workforce : k => b.managed_login_branding_id }
}

output "identity_external_branding_ids" {
  description = "Managed login branding id per EXTERNAL client (changes when a style is replaced)."
  value       = { for k, b in aws_cognito_managed_login_branding.external : k => b.managed_login_branding_id }
}

output "identity_breakglass_secret_arn" {
  value = aws_secretsmanager_secret.identity_breakglass.arn
}
