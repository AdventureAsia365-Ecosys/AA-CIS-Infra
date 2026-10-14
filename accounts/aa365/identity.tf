# =============================================================================
# Ecosystem identity on Amazon Cognito (AA-703, root ADR 0006 "Ecosystem identity", ACCEPTED S236,
# Phase 0 "Pools and triggers"). Self-contained like booking.tf: every resource lives in this file,
# uses the aa-workforce-* / aa-external-* / aa-identity-* prefixes and only READS
# aws_sns_topic.alerts (observability.tf) and aws_iam_policy.workload_boundary (cicd_split.tf).
# No CIS / Booking / TripPlanner resource is changed.
#
# WHAT THIS FILE ADDS:
#   - 2 user pools on the Essentials plan, deletion protection ACTIVE (decision 1):
#       aa-workforce-<env>  staff + break-glass; admin-create only; MFA OPTIONAL (TOTP, break-glass only)
#       aa-external-<env>   tenant users + travellers; self sign-up gated per client by the trigger; MFA OFF
#   - 6 app clients (decision 2): workforce cis-admin / booking-staff / breakglass (confidential),
#     external cis-portal (confidential), booking-customer / tripplanner (public, PKCE)
#   - 6 WORKFORCE groups <app>-<role> (decision 3); EXTERNAL has none (tenant roles live in CIS DB)
#   - Staff sign in with an EMAIL ONE-TIME CODE ONLY (S236 amendment: adventure.asia mail is on
#     DreamHost, not Google Workspace, so there is no `hd` claim to restrict Google to staff). The
#     WORKFORCE pool has NO social identity provider. Google and Facebook exist on EXTERNAL only,
#     each created ONLY when its client id and secret ARN variables are set (count = 0 otherwise)
#   - 4 Python 3.12 trigger Lambdas (pre sign-up + pre token generation V2_0 per pool), outside
#     the VPC, published versions behind a `live` alias (decision 5), with alarms. Their roles carry
#     the AA-806 workload boundary (the CI apply role may only create roles that carry it)
#   - prefix domains (managed login v2) always; custom domains auth. / staff-auth. only when
#     identity_custom_domains_enabled = true (needs the AA-818 us-east-1 certificate)
#   - Cognito mail through the AA-811 SES identity only when identity_ses_enabled = true (needs the
#     identity verified, DKIM SUCCESS); until then COGNITO_DEFAULT and no EMAIL_OTP
#   - one REGIONAL WAF web ACL with per-IP rate rules, associated with both pools
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
#     per client). Nobody but break-glass has a usable password: staff are created by
#     AdminCreateUser without one, account recovery is admin_only, and no client enables
#     ALLOW_USER_PASSWORD_AUTH / ALLOW_USER_SRP_AUTH. ADR 0006 decision 2 ("EXTERNAL allows
#     EMAIL_OTP only") is therefore met by procedure, not by pool configuration.
#   - EXTERNAL clients that offer a social IdP get write access to email / email_verified / name:
#     Cognito requires the app client to be able to write every mapped attribute. Users still
#     cannot change them, because no client grants the aws.cognito.signin.user.admin scope, and the
#     EXTERNAL pre sign-up trigger refuses a native SignUp that sets email_verified. WORKFORCE
#     clients write `name` only.
#   - Break-glass is restricted to its own client only by procedure: the pre token trigger is a
#     pure function and cannot know client ids (pool -> trigger -> client would be a Terraform
#     cycle). It logs every break-glass token issue (alarm below).
#   - Managed-login branding is NOT here (provider 6.12+). Managed login v2 needs a branding style
#     per client before its pages render: create it with the CLI after apply (see output
#     identity_branding_commands).
#   - The break-glass USER is not created here (Terraform would hold its password). One-off script
#     in Phase 1 (ADR 0006 migration plan).
#
# APPLY PREREQUISITES (CI apply role aa-cis-infra-tf-apply, AA-806 split):
#   - cognito-idp:* and wafv2:CreateWebACL/DeleteWebACL/CheckCapacity: the AA-811 bootstrap grant
#     (local MFA apply) must be live first, or the CI apply fails with AccessDenied.
#   - identity_ses_enabled = true switches both pools to DEVELOPER email: Cognito then creates the
#     service-linked role AWSServiceRoleForAmazonCognitoIdpEmailService with the CALLER's
#     credentials, so the apply role needs iam:CreateServiceLinkedRole for
#     email.cognito-idp.amazonaws.com unless that role already exists in acc2.
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

  id_ext_google = var.identity_external_google_client_id != "" && var.identity_external_google_client_secret_arn != ""
  id_facebook   = var.identity_facebook_app_id != "" && var.identity_facebook_app_secret_arn != ""

  id_custom_domains = var.identity_custom_domains_enabled

  # ADR 0006 decision 3: group name = <app>-<role>. Precedence only matters for cognito:preferred_role (unused).
  id_staff_groups = {
    "cis-admin"           = { precedence = 10, description = "CIS admin (shared.admin_role = admin)" }
    "cis-reviewer"        = { precedence = 20, description = "CIS reviewer (shared.admin_role = reviewer)" }
    "cis-content"         = { precedence = 30, description = "CIS content (shared.admin_role = content)" }
    "booking-admin"       = { precedence = 40, description = "Booking staff admin" }
    "booking-sales"       = { precedence = 50, description = "Booking sales" }
    "booking-contracting" = { precedence = 60, description = "Booking contracting" }
  }

  id_ext_idps_portal    = concat(["COGNITO"], local.id_ext_google ? ["Google"] : [])
  id_ext_idps_traveller = concat(["COGNITO"], local.id_ext_google ? ["Google"] : [], local.id_facebook ? ["Facebook"] : [])

  id_federated_writes = ["email", "email_verified", "name"]

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
    "breakglass" = {
      secret = true, access_minutes = 15, refresh_hours = 1
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
    NATIVE_SIGNUP_ENABLED  = tostring(local.id_ses_enabled)
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

resource "aws_cloudwatch_log_group" "identity_trigger" {
  for_each          = local.id_triggers
  name              = "/aws/lambda/${local.id_prefix}-${each.key}"
  retention_in_days = 30
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
    source_arn            = local.id_ses_enabled ? var.identity_ses_identity_arn : null
    from_email_address    = local.id_ses_enabled ? var.identity_ses_from_address : null
    configuration_set     = local.id_ses_enabled && var.identity_ses_configuration_set_workforce != "" ? var.identity_ses_configuration_set_workforce : null
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
      condition     = !local.id_ses_enabled || (var.identity_ses_identity_arn != "" && var.identity_ses_from_address != "")
      error_message = "identity_ses_enabled = true needs identity_ses_identity_arn (the verified AA-811 identity) and identity_ses_from_address."
    }
    precondition {
      condition     = !local.id_custom_domains || var.identity_custom_domain_certificate_arn != ""
      error_message = "identity_custom_domains_enabled = true needs identity_custom_domain_certificate_arn (the AA-818 us-east-1 certificate, ISSUED)."
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
    source_arn            = local.id_ses_enabled ? var.identity_ses_identity_arn : null
    from_email_address    = local.id_ses_enabled ? var.identity_ses_from_address : null
    configuration_set     = local.id_ses_enabled && var.identity_ses_configuration_set_external != "" ? var.identity_ses_configuration_set_external : null
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
# custom domain otherwise). DNS: CNAME/alias of each name to its CloudFront target (output below).
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
  certificate_arn       = var.identity_custom_domain_certificate_arn
  user_pool_id          = aws_cognito_user_pool.workforce.id
  managed_login_version = 2
}

resource "aws_cognito_user_pool_domain" "external_custom" {
  count                 = local.id_custom_domains ? 1 : 0
  domain                = var.identity_external_custom_domain
  certificate_arn       = var.identity_custom_domain_certificate_arn
  user_pool_id          = aws_cognito_user_pool.external.id
  managed_login_version = 2
}

# =============================================================================
# WAF on both pools (ADR 0006 decision 1): per-IP rate limits on sign-up / sign-in / code resend
# (MAU + SES abuse) and a global per-IP cap. One shared web ACL (same rules for both pools).
# =============================================================================
resource "aws_wafv2_web_acl" "identity" {
  count       = var.identity_waf_enabled ? 1 : 0
  name        = "${local.id_prefix}-pools"
  description = "Rate limits for the WORKFORCE and EXTERNAL Cognito pools (AA-703)"
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

  rule {
    name     = "GlobalRatePerIp"
    priority = 1

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
  alarm_description   = "An identity trigger hit an unexpected exception (fail closed: sign-ins are being refused). AA-703."
  namespace           = "AA/Identity"
  metric_name         = "TriggerUnexpectedError"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  tags                = local.id_tags
}

resource "aws_cloudwatch_metric_alarm" "identity_trigger_errors" {
  for_each            = local.id_triggers
  alarm_name          = "${local.id_prefix}-${each.key}-errors"
  alarm_description   = "Burst of refusals/errors from ${each.key} (abuse or a broken release). AA-703."
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
  tags                = local.id_tags
}

resource "aws_cloudwatch_metric_alarm" "identity_trigger_throttles" {
  for_each            = local.id_triggers
  alarm_name          = "${local.id_prefix}-${each.key}-throttles"
  alarm_description   = "${each.key} is throttled: sign-ins are refused. AA-703."
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
  tags                = local.id_tags
}

resource "aws_cloudwatch_metric_alarm" "identity_trigger_duration" {
  for_each            = local.id_triggers
  alarm_name          = "${local.id_prefix}-${each.key}-duration-p99"
  alarm_description   = "${each.key} p99 duration above 3 s (Cognito kills triggers at 5 s). AA-703."
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
  alarm_description   = "A token was issued to the break-glass account. Log the use in the session log (ADR 0006 decision 11). AA-703."
  namespace           = "AA/Identity"
  metric_name         = "BreakglassTokenIssued"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
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
  description = "CNAME targets for the auth custom domains (set at Namecheap)."
  value = local.id_custom_domains ? {
    (var.identity_workforce_custom_domain) = aws_cognito_user_pool_domain.workforce_custom[0].cloudfront_distribution
    (var.identity_external_custom_domain)  = aws_cognito_user_pool_domain.external_custom[0].cloudfront_distribution
  } : {}
}

output "identity_breakglass_secret_arn" {
  value = aws_secretsmanager_secret.identity_breakglass.arn
}

output "identity_branding_commands" {
  description = "Managed login v2 needs a branding style per client (provider 6.12+ for Terraform); run once per client after apply."
  value = concat(
    [for k, c in aws_cognito_user_pool_client.workforce : "aws cognito-idp create-managed-login-branding --user-pool-id ${aws_cognito_user_pool.workforce.id} --client-id ${c.id} --use-cognito-provided-values --profile aa365-admin --region ${var.aws_region}"],
    [for k, c in aws_cognito_user_pool_client.external : "aws cognito-idp create-managed-login-branding --user-pool-id ${aws_cognito_user_pool.external.id} --client-id ${c.id} --use-cognito-provided-values --profile aa365-admin --region ${var.aws_region}"],
  )
}
