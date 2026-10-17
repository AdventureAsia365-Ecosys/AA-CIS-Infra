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
  default     = "breakglass@adventure.asia"
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
  description = "Create the custom domains auth. / staff-auth. (ADR 0006 decision 10). Turn on only after the AA-818 us-east-1 certificate is ISSUED and the parent lumiguides.it.com has an A record; then add the CNAMEs from output identity_custom_domain_cloudfront_targets. Off = Dev runs on the prefix domains."
  type        = bool
  default     = false
}

variable "identity_custom_domain_certificate_arn" {
  description = "Public ACM certificate in us-east-1 (acc2, AA-818) covering auth. and staff-auth. Required when identity_custom_domains_enabled = true."
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
  description = "Let the EXTERNAL pre sign-up trigger accept native (email code) self sign-up on the traveller clients. Needs identity_ses_enabled. Off by default (AA-854): Phase 0/1 is staff only, and public self sign-up should sit behind the WAF rate rules (identity_waf_enabled, S241 D-19 quote first) so a script cannot burn the SES reputation that staff email codes share."
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
  description = "Callback and sign-out URLs per app client key (cis-admin, booking-staff, breakglass, cis-portal, booking-customer, tripplanner). Hosts follow the S237 hostname decision (AA-818); they need not resolve yet. Paths are placeholders until each app implements its callback route. booking-staff / booking-customer stay on localhost until their frontend hosts are chosen."
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
      callback_urls = ["http://localhost:3001/api/auth/callback/cognito"]
      logout_urls   = ["http://localhost:3001/login"]
    }
    "cis-portal" = {
      callback_urls = ["https://aa-cis.lumiguides.it.com/portal/api/auth/callback/cognito", "http://localhost:3000/portal/api/auth/callback/cognito"]
      logout_urls   = ["https://aa-cis.lumiguides.it.com/portal/login", "http://localhost:3000/portal/login"]
    }
    "booking-customer" = {
      callback_urls = ["http://localhost:3002/auth/callback"]
      logout_urls   = ["http://localhost:3002/"]
    }
    "tripplanner" = {
      callback_urls = ["https://tripplanner.lumiguides.it.com/auth/callback", "http://localhost:3003/auth/callback"]
      logout_urls   = ["https://tripplanner.lumiguides.it.com/", "http://localhost:3003/"]
    }
  }
}

# ── WAF on the pools (ADR 0006 decision 1) ───────────────────────────────────
variable "identity_waf_enabled" {
  description = "Attach one shared REGIONAL web ACL with per-IP rate rules to both pools. BILLABLE: about $7/month for this single shared ACL ($5 ACL + 2 x $1 rules + $0.60 per million requests; ADR 0006 quotes $12-15/month for two ACLs). Off by default: S241 D-19 = quote first, enable only with Nghiep's go (AA-854). Enable before identity_external_native_signup_enabled."
  type        = bool
  default     = false
}

variable "identity_waf_signup_rate_limit" {
  description = "Max SignUp / InitiateAuth / code-resend calls per IP per 5 minutes before WAF blocks."
  type        = number
  default     = 100
}

variable "identity_waf_global_rate_limit" {
  description = "Max requests of any kind per IP per 5 minutes to the pools (managed login + APIs)."
  type        = number
  default     = 1000
}
