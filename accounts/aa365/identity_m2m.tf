# =============================================================================
# AA-972 (CRM-B1) — Cognito M2M pool for service-to-service calls (root ADR 0006b decision 7).
#
# ADR 0006b replaces ADR 0006 decision 2's "machine callers do not get Cognito clients" for SERVICE callers: a
# separate pool aa-m2m-<env> issues OAuth client-credentials access tokens, one app client per calling service, one
# resource server per API. This file adds the pool, the AA-Booking B2B resource server and the first client
# (AA-Partner / the CRM API server calling AA-Booking booking.b2b.v1), the prefix domain that serves the token
# endpoint, and the Secrets Manager container where the CRM's client credentials are kept.
#
# Receivers verify with the shared multi-issuer verifier and pin issuer + client + scope. AA-Booking reads the issuer
# and the client id from its task definition (booking.tf: COGNITO_M2M_ISSUER, COGNITO_M2M_CRM_CLIENT_ID, wired from the
# resources below, so no id is copied by hand). Until a Booking deploy carries them, /booking/b2b/v1 answers 503.
#
# WHAT THIS FILE ADDS (no human users, no triggers, no custom domain: the token endpoint is never shown to a person):
#   - user pool aa-m2m-<env>: Essentials tier like the other pools (no users, so no MAU), deletion protection ACTIVE,
#     admin-create only, no self sign-up, MFA off (nobody signs in), account recovery admin_only.
#   - resource server "booking.b2b" with the four contract scopes read / quote / hold / book (contract
#     booking.b2b.v1 securitySchemes.m2m). Later receivers (cis.catalog, cis.tenant: AA-976, AA-978) add their own
#     resource server here.
#   - app client aa-m2m-<env>-crm: confidential (generated secret), client_credentials ONLY, all four booking.b2b
#     scopes (hold/book routes arrive with AA-973; Booking checks a scope per route, so an extra scope grants nothing
#     until its route exists), access tokens 6 h (ADR 0006b: cached in process), token revocation on.
#   - prefix domain <identity_m2m_domain_prefix>.auth.<region>.amazoncognito.com (token URL in the outputs).
#   - secret container aa-crm/<env>/m2m-booking-client (no value: Terraform never writes it; App = crm tag).
#
# COST (AWS list prices as known on 23/10/2026, to be confirmed by AA-930): M2M is billed per app client per month
# plus per token request — about 6 USD per client-month and ~2.25 USD per 10,000 token requests; with 6 h tokens cached
# in process the CRM asks for a few hundred tokens a month (cents). Secrets Manager 0.40 USD per secret-month. The pool
# itself has no users (0 MAU). Total ≈ 6.5 USD per month on Dev.
#
# APPLY: through the CI apply role (cicd_split.tf CognitoUserPoolManage covers pools, clients, resource servers and
# domains; SecretsManagerReadWrite covers the container). No secret VALUE is read on plan refresh (no secret_version
# resource), so local.tf_plan_secret_arns needs no change.
#
# AFTER APPLY (one line each, single-line CLI; the value never passes through a terminal or a file):
#   1. Store the CRM credentials in the container (orchestrator / Nghiep; reads the generated client secret from Cognito
#      and writes {client_id, client_secret, token_url, scopes} as JSON) — see the AA-972 handoff for the exact command.
#   2. A Booking deploy (or Deploy Dev dispatch) copies the latest task definition revision with the two env vars.
# =============================================================================

variable "identity_m2m_domain_prefix" {
  description = "AA-972: Cognito prefix domain of the M2M pool (<prefix>.auth.<region>.amazoncognito.com), serves the client-credentials token endpoint. Globally unique per region."
  type        = string
  default     = "aa365-m2m-dev"
}

variable "identity_m2m_access_token_minutes" {
  description = "AA-972 / ADR 0006b decision 7: lifetime of M2M access tokens in minutes (callers cache them in process)."
  type        = number
  default     = 360

  validation {
    condition     = var.identity_m2m_access_token_minutes >= 5 && var.identity_m2m_access_token_minutes <= 1440
    error_message = "identity_m2m_access_token_minutes must be between 5 and 1440 (Cognito limits)."
  }
}

locals {
  idm2m_name = "aa-m2m-${var.environment}"

  idm2m_tags = merge(local.id_tags, { Pool = "m2m", Issue = "AA-972" })

  # Contract booking.b2b.v1 components.securitySchemes.m2m scopes (scope string = "<identifier>/<name>").
  idm2m_booking_identifier = "booking.b2b"
  idm2m_booking_scopes = {
    read  = "Products, departures, holds, events, FX rates, price parity"
    quote = "Create quotes"
    hold  = "Place, extend and release holds"
    book  = "Confirm and cancel bookings"
  }
}

resource "aws_cognito_user_pool" "m2m" {
  name                = local.idm2m_name
  user_pool_tier      = "ESSENTIALS"
  deletion_protection = "ACTIVE"

  # Nobody signs in to this pool: client-credentials tokens only. Admin-create only closes self sign-up.
  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "admin_only"
      priority = 1
    }
  }

  mfa_configuration = "OFF"

  tags = local.idm2m_tags
}

resource "aws_cognito_resource_server" "booking_b2b" {
  identifier   = local.idm2m_booking_identifier
  name         = "AA-Booking B2B API booking.b2b.v1"
  user_pool_id = aws_cognito_user_pool.m2m.id

  dynamic "scope" {
    for_each = local.idm2m_booking_scopes
    content {
      scope_name        = scope.key
      scope_description = scope.value
    }
  }
}

resource "aws_cognito_user_pool_client" "m2m_crm" {
  name         = "${local.idm2m_name}-crm"
  user_pool_id = aws_cognito_user_pool.m2m.id

  generate_secret                      = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = [for s in aws_cognito_resource_server.booking_b2b.scope_identifiers : s]
  # Cognito always allows refresh-token auth; nothing else (no SRP, no password, no USER_AUTH: there are no users).
  explicit_auth_flows = ["ALLOW_REFRESH_TOKEN_AUTH"]

  access_token_validity  = var.identity_m2m_access_token_minutes
  id_token_validity      = 60
  refresh_token_validity = 60
  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "minutes"
  }

  enable_token_revocation       = true
  prevent_user_existence_errors = "ENABLED"
}

resource "aws_cognito_user_pool_domain" "m2m_prefix" {
  domain       = var.identity_m2m_domain_prefix
  user_pool_id = aws_cognito_user_pool.m2m.id
  # v2 renders no login page without a branding style; the token endpoint does not need one.
  managed_login_version = 2
}

resource "aws_secretsmanager_secret" "m2m_crm_client" {
  name                    = "aa-crm/${var.environment}/m2m-booking-client"
  description             = "AA-Partner (CRM) client credentials of the aa-m2m pool (JSON: client_id, client_secret, token_url, scopes). Value set after apply, never by Terraform. AA-972."
  recovery_window_in_days = var.environment == "dev" ? 0 : 30
  tags                    = merge(local.idm2m_tags, { App = "crm" })
}

output "identity_m2m_pool_id" {
  value = aws_cognito_user_pool.m2m.id
}

output "identity_m2m_issuer" {
  value = "https://${aws_cognito_user_pool.m2m.endpoint}"
}

output "identity_m2m_token_url" {
  value = "https://${aws_cognito_user_pool_domain.m2m_prefix.domain}.auth.${var.aws_region}.amazoncognito.com/oauth2/token"
}

output "identity_m2m_client_ids" {
  description = "App client id per calling service (public values; the secrets stay in Cognito and the aa-crm/<env>/m2m-* secret)."
  value       = { crm = aws_cognito_user_pool_client.m2m_crm.id }
}

output "identity_m2m_booking_scopes" {
  value = sort(aws_cognito_resource_server.booking_b2b.scope_identifiers)
}

output "identity_m2m_crm_secret_arn" {
  value = aws_secretsmanager_secret.m2m_crm_client.arn
}
