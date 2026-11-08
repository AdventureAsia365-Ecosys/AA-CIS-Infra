# =============================================================================
# Ecosystem identity (AA-703, root ADR 0006, accepted S236) — inputs for identity.tf.
# Every optional piece defaults to "off" so the first apply works before the SES identity (AA-811)
# is verified, the us-east-1 ACM certificate (AA-818) is issued, or the EXTERNAL Google / Facebook
# OAuth apps exist. WORKFORCE has no social IdP at all (staff sign in with an email code).
# =============================================================================

variable "identity_staff_email_domain" {
  description = "Staff email domain. WORKFORCE triggers refuse any other domain (ADR 0006 decisions 3 and 5)."
  type        = string
  default     = "adventure.asia"
}

variable "identity_breakglass_email" {
  description = "Break-glass WORKFORCE user's email (ADR 0006 decision 11). Every token issued to it raises an alarm. Must be inside identity_staff_email_domain."
  type        = string
  default     = "admin@adventure.asia"
}

variable "identity_breakglass_admin_role_name" {
  description = "Name of the MFA admin role (admin_role.tf, AA-1004) that the admin CLI profiles (aa365-admin, default) assume; the role that alone may GetSecretValue / PutSecretValue on the break-glass secret (identity_alerts.tf, ADR 0006 decision 11). Every other principal, the CI apply role included, is denied; Terraform never needs the value."
  type        = string
  default     = "nghiep-admin-12h"
}

variable "identity_admin_user_name" {
  description = "IAM user that may assume the MFA admin role (admin_role.tf trust, MFA required). AA-1004."
  type        = string
  default     = "nghiep-admin"
}

# ── Prefix domains (Dev) and optional custom domains ─────────────────────────
variable "identity_workforce_domain_prefix" {
  description = "Cognito prefix domain for the WORKFORCE pool (<prefix>.auth.us-west-1.amazoncognito.com). Globally unique per region."
  type        = string
  default     = "aa365-staff-auth-dev"
}

variable "identity_external_domain_prefix" {
  description = "Cognito prefix domain for the EXTERNAL pool (<prefix>.auth.us-west-1.amazoncognito.com). Globally unique per region."
  type        = string
  default     = "aa365-auth-dev"
}

variable "identity_custom_domains_enabled" {
  description = "Create the custom domains auth. / staff-auth. (ADR 0006 decision 10) and their Route 53 alias records. Needs the AA-818 us-east-1 certificate ISSUED and the apex A record (dns.tf aws_route53_record.apex). Off = Dev runs on the prefix domains only (the prefix domains always stay, as fallback)."
  type        = bool
  default     = true # AA-816 S242: certificate ISSUED (S237), NS on Route 53; staff sign-in moves off amazoncognito.com (Safe Browsing flag)
}

variable "identity_custom_domain_certificate_arn" {
  description = "Override for the us-east-1 ACM certificate of auth. and staff-auth. Empty (default) = aws_acm_certificate.auth in custom_domains.tf (AA-818, same root)."
  type        = string
  default     = ""

  validation {
    condition     = var.identity_custom_domain_certificate_arn == "" || can(regex("^arn:aws:acm:us-east-1:[0-9]{12}:certificate/", var.identity_custom_domain_certificate_arn))
    error_message = "The certificate must be an ACM certificate in us-east-1 (Cognito fronts custom domains with CloudFront)."
  }
}

variable "identity_workforce_custom_domain" {
  description = "WORKFORCE custom domain, used only when identity_custom_domains_enabled = true."
  type        = string
  default     = "staff-auth.lumiguides.it.com"
}

variable "identity_external_custom_domain" {
  description = "EXTERNAL custom domain, used only when identity_custom_domains_enabled = true."
  type        = string
  default     = "auth.lumiguides.it.com"
}

# ── Email (AA-811) ───────────────────────────────────────────────────────────
variable "identity_ses_enabled" {
  description = "Send Cognito mail through the AA-811 SES identity (DEVELOPER mode) and enable EMAIL_OTP as a first factor in both pools. On by default since AA-854: the identity lumiguides.it.com shows VerifiedForSendingStatus=true, DKIM SUCCESS, MAIL FROM SUCCESS and the account has production access in us-west-1 (read-only check 17/10/2026). Off = COGNITO_DEFAULT sender, no email codes: only break-glass can sign in to WORKFORCE."
  type        = bool
  default     = true
}

variable "identity_external_native_signup_enabled" {
  description = "Let the EXTERNAL pre sign-up trigger accept native (email code) self sign-up on the traveller clients. Needs identity_ses_enabled AND identity_waf_enabled (both enforced by preconditions on the EXTERNAL pool). Off by default (AA-854): Phase 0/1 is staff only, and public self sign-up should sit behind the WAF rate rules (identity_waf_enabled, S241 D-19 quote first) so a script cannot burn the SES reputation that staff email codes share."
  type        = bool
  default     = false
}

variable "identity_ses_identity_arn" {
  description = "Override for the SES identity ARN (acc2 us-west-1). Empty = the AA-811 identity in ses.tf (local.ses_identity_arn, lumiguides.it.com)."
  type        = string
  default     = ""

  validation {
    condition     = var.identity_ses_identity_arn == "" || can(regex("^arn:aws:ses:us-west-1:[0-9]{12}:identity/", var.identity_ses_identity_arn))
    error_message = "The SES identity must be in us-west-1 (in-region only for a us-west-1 pool)."
  }
}

variable "identity_ses_from_address" {
  description = "FROM address for Cognito mail via SES (S237 D5 / ADR 0006 item 5: no-reply@ on the apex identity). Must be inside the identity's domain and match any ses:FromAddress condition AA-811 sets."
  type        = string
  default     = "Adventure Asia <no-reply@lumiguides.it.com>"
}

variable "identity_ses_configuration_set_workforce" {
  description = "Override for the WORKFORCE SES configuration set (separate bounce/complaint tracking from EXTERNAL, ADR 0006 Costs). Empty = ses.tf stream \"workforce\" (aa-email-<env>-workforce). Used only when identity_ses_enabled = true."
  type        = string
  default     = ""
}

variable "identity_ses_configuration_set_external" {
  description = "Override for the EXTERNAL SES configuration set. Empty = ses.tf stream \"external\" (aa-email-<env>-external). Used only when identity_ses_enabled = true."
  type        = string
  default     = ""
}

# ── EXTERNAL Google / Facebook IdPs (created only when both id and secret ARN are set) ─
variable "identity_external_google_client_id" {
  description = "Google OAuth client id for EXTERNAL (External consent screen, scopes openid email profile). Empty = no Google IdP on EXTERNAL. Setting it makes email_verified writable by the EXTERNAL clients (Cognito requires mapped attributes to be writable), and API sign-in tokens carry aws.cognito.signin.user.admin whatever the OAuth scopes say. Before setting it, prove that a traveller cannot set email_verified=true with UpdateUserAttributes, or move social sign-in to clients without ALLOW_USER_AUTH (AA-703 review S237)."
  type        = string
  default     = ""
}

variable "identity_external_google_client_secret_arn" {
  description = "Secrets Manager ARN (acc2) whose SecretString is the EXTERNAL Google client secret (plain string)."
  type        = string
  default     = ""
}

variable "identity_facebook_app_id" {
  description = "Facebook app id (EXTERNAL only). Leave empty until the app is Live with Advanced Access for email (ADR 0006 Open item 2)."
  type        = string
  default     = ""
}

variable "identity_facebook_app_secret_arn" {
  description = "Secrets Manager ARN (acc2) whose SecretString is the Facebook app secret (plain string)."
  type        = string
  default     = ""
}

variable "identity_facebook_api_version" {
  description = "Facebook Graph API version used by Cognito."
  type        = string
  default     = "v19.0"
}

# ── App client URLs ──────────────────────────────────────────────────────────
variable "identity_client_urls" {
  description = "Callback and sign-out URLs per app client key (cis-admin, booking-staff, breakglass, crm-staff, cis-portal, booking-customer, tripplanner). Hosts follow the S237 hostname decision (AA-818); they need not resolve yet. Paths are placeholders until each app implements its callback route. cis-admin and booking-staff point at the staff hosts aa-cis. and booking., served by ECS since AA-911 (the aa-booking-admin.vercel.app URLs and the Preview-only clients cis-admin-preview / booking-staff-preview of S246 went with the Vercel retirement, S272); breakglass stays production-only; cis-portal points at portal.lumiguides.it.com (S243, AA-885) and, since AA-935, also at the AA-Partner CRM web on partner-dev.lumiguides.it.com (/auth/callback, /signed-out); crm-staff (AA-939) points at the AA-Partner staff console on the agency host portal.lumiguides.it.com (AA-1019); booking-customer stays on localhost until its frontend host is chosen; tripplanner points at the public host tripplanner.lumiguides.it.com only (the aa-tripplanner.vercel.app URLs went with the TripPlanner Vercel retirement, AA-1038, S272)."
  type = map(object({
    callback_urls = list(string)
    logout_urls   = list(string)
  }))
  default = {
    "cis-admin" = {
      callback_urls = ["https://aa-cis.lumiguides.it.com/api/auth/callback/cognito", "http://localhost:3000/api/auth/callback/cognito"]
      logout_urls   = ["https://aa-cis.lumiguides.it.com/login", "http://localhost:3000/login"]
    }
    "breakglass" = {
      callback_urls = ["https://aa-cis.lumiguides.it.com/api/auth/callback/cognito-breakglass"]
      logout_urls   = ["https://aa-cis.lumiguides.it.com/login"]
    }
    "booking-staff" = {
      # booking.lumiguides.it.com (the ECS service aa-booking-<env>-admin since AA-911; the aa-booking-admin.vercel.app
      # URLs went with the Vercel retirement, S272); localhost:3001 for local dev.
      callback_urls = ["https://booking.lumiguides.it.com/api/auth/callback/cognito", "http://localhost:3001/api/auth/callback/cognito"]
      logout_urls   = ["https://booking.lumiguides.it.com/login", "http://localhost:3001/login"]
    }
    "cis-portal" = {
      # AA-935 (CRM-07, design v3 Fix C10): the AA-Partner CRM web's EXTERNAL-pool fallback (used only while
      # crm_partner_signin_enabled = false): its callback and sign-out pages on the partner host, local dev port 3005.
      # AA-979 P2b clean-up: the tenant portal's placeholder entries (portal. /api/auth/callback/cognito,
      # /tenant-login, localhost:3004) are removed: the studio signs in with the partner pool through the CRM web.
      callback_urls = ["https://partner-dev.lumiguides.it.com/auth/callback", "http://localhost:3005/auth/callback"]
      logout_urls   = ["https://partner-dev.lumiguides.it.com/signed-out", "http://localhost:3005/signed-out"]
    }
    "crm-staff" = {
      # AA-939: the AA-Partner staff pages. AA-1019: the staff console (AA-Partner web/app/staff) on the agency host
      # portal. (partner-dev. answers 301 there since AA-979, and the sign-in attempt cookie is host-only, so the
      # callback must be on portal.); local dev port 3005.
      callback_urls = ["https://portal.lumiguides.it.com/staff/auth/callback", "http://localhost:3005/staff/auth/callback"]
      logout_urls   = ["https://portal.lumiguides.it.com/staff/signed-out", "http://localhost:3005/staff/signed-out"]
    }
    "booking-customer" = {
      callback_urls = ["http://localhost:3002/auth/callback"]
      logout_urls   = ["http://localhost:3002/"]
    }
    "tripplanner" = {
      # AA-908 (S250): the public host tripplanner.lumiguides.it.com (CloudFront -> the ECS service
      # aa-tripplanner-<env>-web since AA-1038); localhost:3003 for local dev. The guest cookie (__Host-tp_guest) is
      # host-only, so the callback must land on the host where sign-in started. The aa-tripplanner.vercel.app URLs went
      # with the Vercel retirement (AA-1038, S272): this client is public (PKCE, no secret), so a callback on a
      # vercel.app name nobody holds any more would hand authorization codes to whoever claims it.
      callback_urls = ["https://tripplanner.lumiguides.it.com/auth/callback", "http://localhost:3003/auth/callback"]
      logout_urls   = ["https://tripplanner.lumiguides.it.com/", "http://localhost:3003/"]
    }
  }
}

# ── WAF on the pools (ADR 0006 decision 1) ───────────────────────────────────
variable "identity_waf_enabled" {
  description = "Attach one shared REGIONAL web ACL with per-IP rate rules to the WORKFORCE, EXTERNAL and PARTNER pools. BILLABLE: about $9/month for this single shared ACL ($5 ACL + 4 x $1 rules + $0.60 per million requests, AA-908; ADR 0006 quotes $12-15/month for two ACLs) plus $0.80/month for the TripPlanner BFF header secret and its sign-up proof key (the latter only with identity_external_native_signup_enabled). Off by default: S241 D-19 = quote first, enable only with Nghiep's go (AA-854). Required by identity_external_native_signup_enabled (precondition on the EXTERNAL pool)."
  type        = bool
  default     = false
}

variable "identity_waf_signup_rate_limit" {
  description = "Max SignUp / InitiateAuth / code-resend API calls plus managed-login form posts (any POST outside /oauth2/) per IP per 5 minutes before WAF blocks; the same limit per traveller address for the TripPlanner BFF's API calls (BffRatePerTravellerIp). A CI browser sign-in makes about 3-4 such posts, a traveller's BFF sign-in about 3 API calls (AA-908)."
  type        = number
  default     = 100
}

variable "identity_waf_global_rate_limit" {
  description = "Max requests of any kind per IP per 5 minutes to the pools (managed login + APIs)."
  type        = number
  default     = 1000
}
