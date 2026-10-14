# =============================================================================
# Ecosystem identity (AA-703, root ADR 0006) — inputs for identity.tf.
# Every optional piece defaults to "off" so the first apply works before Nghiep has created the
# Google / Facebook OAuth apps, the SES identity (AA-811) or the us-east-1 ACM certificate.
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

variable "identity_custom_domain_certificate_arn" {
  description = "Public ACM certificate in us-east-1 (acc2) covering the two auth custom domains. Empty = custom domains are not created (Dev runs on the prefix domains)."
  type        = string
  default     = ""

  validation {
    condition     = var.identity_custom_domain_certificate_arn == "" || can(regex("^arn:aws:acm:us-east-1:[0-9]{12}:certificate/", var.identity_custom_domain_certificate_arn))
    error_message = "The certificate must be an ACM certificate in us-east-1 (Cognito fronts custom domains with CloudFront)."
  }
}

variable "identity_workforce_custom_domain" {
  description = "WORKFORCE custom domain, used only when identity_custom_domain_certificate_arn is set."
  type        = string
  default     = "staff-auth.lumiguides.it.com"
}

variable "identity_external_custom_domain" {
  description = "EXTERNAL custom domain, used only when identity_custom_domain_certificate_arn is set."
  type        = string
  default     = "auth.lumiguides.it.com"
}

# ── Email (AA-811) ───────────────────────────────────────────────────────────
variable "identity_ses_identity_arn" {
  description = "ARN of the verified SES identity in acc2 us-west-1 (AA-811). Empty = COGNITO_DEFAULT sender (50 mails/day) and EMAIL_OTP is NOT enabled as a first factor (it requires SES)."
  type        = string
  default     = ""

  validation {
    condition     = var.identity_ses_identity_arn == "" || can(regex("^arn:aws:ses:us-west-1:[0-9]{12}:identity/", var.identity_ses_identity_arn))
    error_message = "The SES identity must be in us-west-1 (in-region only for a us-west-1 pool)."
  }
}

variable "identity_ses_from_address" {
  description = "FROM address for Cognito mail via SES, e.g. \"Adventure Asia <no-reply@lumiguides.it.com>\". Required when identity_ses_identity_arn is set."
  type        = string
  default     = ""
}

variable "identity_ses_configuration_set_workforce" {
  description = "Optional SES configuration set for WORKFORCE mail (separate reputation tracking from EXTERNAL, ADR 0006 Costs)."
  type        = string
  default     = ""
}

variable "identity_ses_configuration_set_external" {
  description = "Optional SES configuration set for EXTERNAL mail."
  type        = string
  default     = ""
}

# ── Google / Facebook IdPs (created only when both id and secret ARN are set) ─
variable "identity_workforce_google_client_id" {
  description = "Google OAuth client id for WORKFORCE (Internal consent screen, adventure.asia Cloud Organization). Empty = no Google IdP on WORKFORCE."
  type        = string
  default     = ""
}

variable "identity_workforce_google_client_secret_arn" {
  description = "Secrets Manager ARN (acc2) whose SecretString is the WORKFORCE Google client secret (plain string). Set out-of-band by Nghiep."
  type        = string
  default     = ""
}

variable "identity_external_google_client_id" {
  description = "Google OAuth client id for EXTERNAL (External consent screen, scopes openid email profile). Empty = no Google IdP on EXTERNAL."
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

# ── Google hd enforcement (ADR 0006 Open item 3, spike) ──────────────────────
variable "identity_workforce_map_google_hd" {
  description = "Add the custom:hd attribute to WORKFORCE and map Google's hd claim into it. A custom attribute can never be removed: turn on only after the spike shows the mapping works."
  type        = bool
  default     = false
}

variable "identity_workforce_require_hd" {
  description = "WORKFORCE pre sign-up refuses a Google sign-in whose custom:hd is not the staff domain. Default true = fail closed: Google staff sign-in is refused until hd mapping works OR Nghiep explicitly accepts the ADR fallback (Internal consent screen + pool allow-list) by setting this to false."
  type        = bool
  default     = true
}

# ── App client URLs ──────────────────────────────────────────────────────────
variable "identity_client_urls" {
  description = "Callback and sign-out URLs per app client key (cis-admin, booking-staff, breakglass, cis-portal, booking-customer, tripplanner). Paths are placeholders until each app implements its callback route."
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
      callback_urls = ["http://localhost:3003/auth/callback"]
      logout_urls   = ["http://localhost:3003/"]
    }
  }
}

# ── WAF on the pools (ADR 0006 decision 1) ───────────────────────────────────
variable "identity_waf_enabled" {
  description = "Attach a REGIONAL web ACL with per-IP rate rules to both pools (~$7/month for one shared ACL)."
  type        = bool
  default     = true
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
