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
#     booking.b2b.v1 securitySchemes.m2m). Later receivers add their own resource server here: AA-976 adds
#     "cis.catalog" (scope read, contract catalog.http.v1, served by AA-CIS-App /catalog/v1); AA-978 adds
#     "cis.tenant" (scope read, contract tenant.membership.v1, served by AA-CIS-App /tenant/membership/v1); AA-1038 R5
#     slice 3 adds "tripplanner.leads" (scope deliver, root contract lead.submitted.v1, served by the AA-TripPlanner-Web
#     assembly Lambda under /trip/m2m/v1: the CRM pulls and acknowledges its agencies' leads).
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
#   3. AA-978: add cis.tenant/read to the "scopes" value of that JSON (same container; client id and secret unchanged).
#      AA-1038: likewise tripplanner.leads/deliver ("scopes" is informational for the CRM: it asks each receiver's scope
#      by name, AA-Partner app/cis/m2m.py), and TRIPPLANNER_API_URL reaches the CRM task on its next deploy.
#      crm_app.tf injects the whole JSON into the AA-Partner task as the secret env M2M_CLIENT, so the next AA-Partner
#      deploy (which copies the latest task definition revision) gives the CRM worker its credentials.
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

  # AA-976 (CRM-B4): contract catalog.http.v1 securitySchemes.m2m. AA-CIS-App pins the CRM client and this scope
  # (api/core/m2m_auth.py; the issuer and client id are code constants there with an env override, so the CIS task
  # definition needs no new variable).
  idm2m_catalog_identifier = "cis.catalog"
  idm2m_catalog_scopes = {
    read = "Published tours, destinations and AA-authored content (CIS /catalog/v1)"
  }

  # AA-978 (CRM-P1): contract tenant.membership.v1 securitySchemes.m2m. The CRM pulls the CIS membership feed with this
  # scope only (AA-Partner app/cis/m2m.py asks for it alone); CIS pins the CRM client and this scope per route like
  # catalog.http.v1, so no CIS task definition variable is needed either.
  idm2m_tenant_identifier = "cis.tenant"
  idm2m_tenant_scopes = {
    read = "Agency membership snapshot, identity lookup and event feed (CIS /tenant/membership/v1)"
    # AA-979 P2b (contract tenant.membership.v1 1.1): the CRM binds an accepted studio invitation's partner-pool
    # identity (POST /tenant/membership/v1/invitations/{id}/activate). Granted to the CRM client only (m2m_crm below
    # takes every scope of this server; it is the pool's only client).
    activate = "Bind the partner-pool identity of an accepted Content studio invitation (CIS /tenant/membership/v1)"
    # AA-1036 R3 (root contract tenant.addons.v1): the CRM reads an agency's add-ons and relays its CRM owner's add-on
    # request to CIS (GET /tenant/v1/tenants/{id}/add-ons, POST /tenant/v1/tenants/{id}/add-on-requests), for an
    # agency whose owner has no Content studio membership. Same client; an in-place update of the resource server and
    # of the client's allowed scopes (re-plan after the apply: the client takes the new scope on the second apply).
    addons = "Read an agency's add-ons and request one for its CRM owner (CIS /tenant/v1, tenant.addons.v1)"
    # AA-1093 lane L2 (root contract tenant.erasure.v1): the CRM reads the tenant offboarding erasure requests and
    # reports its own DRY RUN, apply and census (GET /tenant/v1/erasure-requests, POST .../{id}/reports). Same client;
    # an in-place update of the resource server and of the client's allowed scopes (re-plan after the apply).
    erasure = "Read the tenant erasure requests and report the CRM's own erasure step (CIS /tenant/v1, tenant.erasure.v1)"
  }

  # AA-1038 R5 slice 3 (root ADR 0019 d11 + its S272 amendment, root contract lead.submitted.v1): the CRM pulls each
  # agency's TripPlanner leads and acknowledges them (GET /trip/m2m/v1/tenants/{agency}/leads + the ack) on the
  # assembly Lambda's M2M route class. TripPlanner pins issuer + the CRM client + this scope before any SQL
  # (AA-TripPlanner-Web backend/shared/m2m_auth.py; issuer and client id arrive as TP_M2M_ISSUER /
  # TP_M2M_CRM_CLIENT_ID on the assembly Lambda, modules/environment/tripplanner.tf). Granted to the CRM client only
  # (m2m_crm below; the pool's only client). A new resource server: its scope_identifiers are known after the create,
  # so the client's allowed_oauth_scopes shows as an in-place update with a value known after apply; re-plan after the
  # apply ("No changes" expected, S252 lesson).
  idm2m_tripplanner_identifier = "tripplanner.leads"
  idm2m_tripplanner_scopes = {
    deliver = "Pull and acknowledge an agency's TripPlanner leads (TripPlanner /trip/m2m/v1, lead.submitted.v1)"
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

  tags = merge(local.idm2m_tags, { DataClassification = "restricted" })
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

resource "aws_cognito_resource_server" "cis_catalog" {
  identifier   = local.idm2m_catalog_identifier
  name         = "AA-CIS-App catalog API catalog.http.v1"
  user_pool_id = aws_cognito_user_pool.m2m.id

  dynamic "scope" {
    for_each = local.idm2m_catalog_scopes
    content {
      scope_name        = scope.key
      scope_description = scope.value
    }
  }
}

resource "aws_cognito_resource_server" "cis_tenant" {
  identifier   = local.idm2m_tenant_identifier
  name         = "AA-CIS-App tenant membership API tenant.membership.v1"
  user_pool_id = aws_cognito_user_pool.m2m.id

  dynamic "scope" {
    for_each = local.idm2m_tenant_scopes
    content {
      scope_name        = scope.key
      scope_description = scope.value
    }
  }
}

resource "aws_cognito_resource_server" "tripplanner_leads" {
  identifier   = local.idm2m_tripplanner_identifier
  name         = "AA-TripPlanner-Web lead pull lead.submitted.v1"
  user_pool_id = aws_cognito_user_pool.m2m.id

  dynamic "scope" {
    for_each = local.idm2m_tripplanner_scopes
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
  # AA-976: + cis.catalog/read. Each receiver checks its own scope per route, so a scope of another API grants nothing
  # there. Updating the scopes of an existing client is in place (no new client id, the secret is kept).
  # AA-978: + cis.tenant/read (the CIS membership feed), same in-place update.
  # AA-1038: + tripplanner.leads/deliver (the TripPlanner lead pull), same in-place update.
  allowed_oauth_scopes = concat(
    [for s in aws_cognito_resource_server.booking_b2b.scope_identifiers : s],
    [for s in aws_cognito_resource_server.cis_catalog.scope_identifiers : s],
    [for s in aws_cognito_resource_server.cis_tenant.scope_identifiers : s],
    [for s in aws_cognito_resource_server.tripplanner_leads.scope_identifiers : s],
  )
  # Cognito always allows refresh-token auth; nothing else (no SRP, no password, no USER_AUTH: there are no users).
  explicit_auth_flows = ["ALLOW_REFRESH_TOKEN_AUTH"]

  access_token_validity = var.identity_m2m_access_token_minutes
  id_token_validity     = 60
  # Cognito requires access/id token validity <= refresh token validity; client_credentials never uses a
  # refresh token, so it only has to be at least as long as the access token.
  refresh_token_validity = max(var.identity_m2m_access_token_minutes, 60)
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

# AA-1092 (S278 audit M24): the token endpoint of the aa-m2m pool joins the shared Cognito web ACL (identity.tf), like
# the PARTNER pool: GlobalRatePerIp caps any caller per IP; the other rules are scoped to the managed login and
# sign-up paths this pool does not serve. The CRM fetches one token per lifetime (cached), far under the cap. No new
# ACL and no new rule: about 0.60 USD per million requests inspected.
resource "aws_wafv2_web_acl_association" "identity_m2m" {
  count        = var.identity_waf_enabled ? 1 : 0
  resource_arn = aws_cognito_user_pool.m2m.arn
  web_acl_arn  = aws_wafv2_web_acl.identity[0].arn
}

resource "aws_secretsmanager_secret" "m2m_crm_client" {
  name                    = "aa-crm/${var.environment}/m2m-booking-client"
  description             = "AA-Partner (CRM) client credentials of the aa-m2m pool (JSON: client_id, client_secret, token_url, scopes). Value set after apply, never by Terraform. AA-972."
  recovery_window_in_days = var.environment == "dev" ? 0 : 30
  tags                    = merge(local.idm2m_tags, { App = "crm", DataClassification = "restricted" })
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

output "identity_m2m_catalog_scopes" {
  value = sort(aws_cognito_resource_server.cis_catalog.scope_identifiers)
}

output "identity_m2m_tenant_scopes" {
  value = sort(aws_cognito_resource_server.cis_tenant.scope_identifiers)
}

output "identity_m2m_tripplanner_scopes" {
  value = sort(aws_cognito_resource_server.tripplanner_leads.scope_identifiers)
}

output "identity_m2m_crm_secret_arn" {
  value = aws_secretsmanager_secret.m2m_crm_client.arn
}
