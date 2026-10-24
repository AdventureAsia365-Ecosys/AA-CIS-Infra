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
  description = "IAM role that alone may GetSecretValue / PutSecretValue on the break-glass secret (identity_alerts.tf, ADR 0006 decision 11): the role the MFA admin CLI profiles (aa365-admin, default) assume. Every other principal, the CI apply role included, is denied; Terraform never needs the value."
  type        = string
  default     = "nghiep-admin-8h-session"
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
  description = "Callback and sign-out URLs per app client key (cis-admin, cis-admin-preview, booking-staff, booking-staff-preview, breakglass, cis-portal, booking-customer, tripplanner). Hosts follow the S237 hostname decision (AA-818); they need not resolve yet. Paths are placeholders until each app implements its callback route. booking-staff points at the aa-booking-admin Vercel hosts (S242); AA-911 (S246, root ADR 0006a A11, decision D-1) adds two Preview-only WORKFORCE clients, booking-staff-preview (booking-preview on aa-booking-admin) and cis-admin-preview (aa-cis-preview on aa-cis-frontend), each with ONLY its fixed Preview host, aliased by CI to the preview under test; the production clients keep their URLs (a Preview host is never a production callback) and both APIs cap the preview client ids at viewer; breakglass stays production-only; cis-portal points at portal.lumiguides.it.com (S243, AA-885) and, since AA-935, also at the AA-Partner CRM web on partner-dev.lumiguides.it.com (/auth/callback, /signed-out); crm-staff (AA-939) points at the AA-Partner staff pages on partner-dev.lumiguides.it.com; booking-customer stays on localhost until its frontend host is chosen."
  type = map(object({
    callback_urls = list(string)
    logout_urls   = list(string)
  }))
  default = {
    "cis-admin" = {
      callback_urls = ["https://aa-cis.lumiguides.it.com/api/auth/callback/cognito", "http://localhost:3000/api/auth/callback/cognito"]
      logout_urls   = ["https://aa-cis.lumiguides.it.com/login", "http://localhost:3000/login"]
    }
    "cis-admin-preview" = {
      # AA-911 D-1 (S246): ONLY the fixed Preview host of aa-cis-frontend. The CIS API caps this client at viewer.
      callback_urls = ["https://aa-cis-preview.lumiguides.it.com/api/auth/callback/cognito"]
      logout_urls   = ["https://aa-cis-preview.lumiguides.it.com/login"]
    }
    "breakglass" = {
      callback_urls = ["https://aa-cis.lumiguides.it.com/api/auth/callback/cognito-breakglass"]
      logout_urls   = ["https://aa-cis.lumiguides.it.com/login"]
    }
    "booking-staff" = {
      # AA-854 I1 (S242): Vercel project aa-booking-admin serves booking.lumiguides.it.com (custom, AA-818)
      # and aa-booking-admin.vercel.app (both production domains, verified); localhost:3001 for local dev.
      callback_urls = ["https://booking.lumiguides.it.com/api/auth/callback/cognito", "https://aa-booking-admin.vercel.app/api/auth/callback/cognito", "http://localhost:3001/api/auth/callback/cognito"]
      logout_urls   = ["https://booking.lumiguides.it.com/login", "https://aa-booking-admin.vercel.app/login", "http://localhost:3001/login"]
    }
    "booking-staff-preview" = {
      # AA-911 D-1 (S246): ONLY the fixed Preview host of aa-booking-admin. The Booking API caps this client at
      # read-only (viewer).
      callback_urls = ["https://booking-preview.lumiguides.it.com/api/auth/callback/cognito"]
      logout_urls   = ["https://booking-preview.lumiguides.it.com/login"]
    }
    "cis-portal" = {
      # S243 AA-885: the tenant portal is its own Vercel project (aa-cis-portal, root portal/) on
      # portal.lumiguides.it.com; local dev port 3004. Still placeholders: tenants sign in with an API key
      # until AA-813 (Phase 3) adds the Cognito callback route at this path.
      # AA-935 (CRM-07, design v3 Fix C10): the AA-Partner CRM web signs agency users in with this same client on
      # Dev until AA-939 (partner pool): its callback and sign-out pages on the partner host, local dev port 3005.
      callback_urls = ["https://portal.lumiguides.it.com/api/auth/callback/cognito", "http://localhost:3004/api/auth/callback/cognito", "https://partner-dev.lumiguides.it.com/auth/callback", "http://localhost:3005/auth/callback"]
      logout_urls   = ["https://portal.lumiguides.it.com/tenant-login", "http://localhost:3004/tenant-login", "https://partner-dev.lumiguides.it.com/signed-out", "http://localhost:3005/signed-out"]
    }
    "crm-staff" = {
      # AA-939: the AA-Partner staff pages on the partner host (their UI arrives with CRM-13b / CRM-26).
      callback_urls = ["https://partner-dev.lumiguides.it.com/staff/auth/callback", "http://localhost:3005/staff/auth/callback"]
      logout_urls   = ["https://partner-dev.lumiguides.it.com/staff/signed-out", "http://localhost:3005/staff/signed-out"]
    }
    "booking-customer" = {
      callback_urls = ["http://localhost:3002/auth/callback"]
      logout_urls   = ["http://localhost:3002/"]
    }
    "tripplanner" = {
      # AA-908 (S250): both production hosts of the Vercel project aa-tripplanner. The guest cookie
      # (__Host-tp_guest) is host-only, so the callback must land on the host where sign-in started.
      callback_urls = ["https://tripplanner.lumiguides.it.com/auth/callback", "https://aa-tripplanner.vercel.app/auth/callback", "http://localhost:3003/auth/callback"]
      logout_urls   = ["https://tripplanner.lumiguides.it.com/", "https://aa-tripplanner.vercel.app/", "http://localhost:3003/"]
    }
  }
}

# ── WAF on the pools (ADR 0006 decision 1) ───────────────────────────────────
variable "identity_waf_enabled" {
  description = "Attach one shared REGIONAL web ACL with per-IP rate rules to the WORKFORCE, EXTERNAL and PARTNER pools. BILLABLE: about $9/month for this single shared ACL ($5 ACL + 4 x $1 rules + $0.60 per million requests, AA-908; ADR 0006 quotes $12-15/month for two ACLs) plus $0.40/month for the TripPlanner BFF header secret. Off by default: S241 D-19 = quote first, enable only with Nghiep's go (AA-854). Required by identity_external_native_signup_enabled (precondition on the EXTERNAL pool)."
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
