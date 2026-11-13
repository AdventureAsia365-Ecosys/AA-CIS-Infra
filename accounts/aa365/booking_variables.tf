variable "booking_github_repo_id" {
  description = "Numeric GitHub repo id of AdventureAsia365-Ecosys/AA-Booking (GET /repos/AdventureAsia365-Ecosys/AA-Booking -> .id). Empty until the repo exists: the deploy-role trust then accepts any repo id for the exact name AA-Booking, in both the immutable and the plain OIDC subject form. Once set, only the immutable subject with this exact id is trusted (fail closed, same as aa-cis-dev-role)."
  type        = string
  default     = ""

  validation {
    condition     = can(regex("^([0-9]+)?$", var.booking_github_repo_id))
    error_message = "booking_github_repo_id must be empty or a numeric GitHub repo id."
  }
}

# AA-811: the staff "new inquiry" e-mail sent by AA-Booking (job bk_notify_email).
variable "booking_staff_notify_email" {
  description = "Staff inbox that receives the AA-Booking new inquiry e-mail. Empty = Booking sends no e-mail (the job logs skipped)."
  type        = string
  default     = ""

  validation {
    condition     = var.booking_staff_notify_email == "" || can(regex("^[^@\\s,]+@[^@\\s,]+$", var.booking_staff_notify_email))
    error_message = "booking_staff_notify_email must be empty or a single e-mail address."
  }
}

variable "booking_staff_admin_url" {
  description = "Base URL of the AA-Booking staff admin (ECS service aa-booking-<env>-admin behind the shared ALB, AA-911); staff e-mail links to <this>/cases/<code>."
  type        = string
  default     = "https://booking.lumiguides.it.com"

  validation {
    condition     = startswith(var.booking_staff_admin_url, "https://")
    error_message = "booking_staff_admin_url must be an https:// URL."
  }
}

# AA-871: Sentry for the Booking API + job worker (backend/app/observability/sentry.py reads SENTRY_DSN).
# The secret shell booking/<env>/sentry-dsn always exists (booking.tf); this flag only decides whether the
# task definition maps it into the container. Keep it false until the secret HOLDS a value: ECS refuses to
# start a task whose `secrets` entry points at a secret with no AWSCURRENT version, and the Booking deploy
# copies the family's latest revision, so flipping it early would break every Booking deploy.
# true also sets SENTRY_REQUIRED=true (the app's missing-DSN guard: start-up fails on an empty DSN).
variable "booking_sentry_enabled" {
  description = "AA-871: map booking/<env>/sentry-dsn into the Booking task as SENTRY_DSN (and set SENTRY_REQUIRED=true). Only after the secret has a value."
  type        = bool
  default     = false
}

# AA-1093 (S279): the kill switch of bk_tenant_erase (AA-Booking backend/app/b2b/tenant_erase.py, env
# TENANT_ERASE_APPLY_ENABLED, read by app/settings.py). "false" (default): the Booking step of the tenant offboarding
# erasure saga runs DRY RUN and verify only; an approved apply is refused (apply_disabled). "true" only for an approved
# erasure (on Dev: a synthetic tenant), then back to "false". Declared identically in the root
# (accounts/aa365/booking_variables.tf) and passed through. The next AA-Booking deploy carries the new revision.
variable "booking_tenant_erase_apply_enabled" {
  description = "AA-1093: \"true\" (exact string) lets bk_tenant_erase APPLY an approved tenant erasure plan (TENANT_ERASE_APPLY_ENABLED); DRY RUN and verify never need it"
  type        = string
  default     = "false"

  validation {
    condition     = contains(["true", "false"], var.booking_tenant_erase_apply_enabled)
    error_message = "booking_tenant_erase_apply_enabled must be \"true\" or \"false\"."
  }
}

# AA-1096 L6 (S279): the Booking REST API stage throttle (every method, `*/*`), a capacity backstop under the app's own
# limits (the RDS connection budget). Was the literal 20 / 40 in booking.tf; same values. Declared identically in the
# root (accounts/aa365/booking_variables.tf) and passed through.
variable "booking_throttle_rate_limit" {
  description = "Booking REST API stage default (*/*) requests per second, applied to each method."
  type        = number
  default     = 20
}

variable "booking_throttle_burst_limit" {
  description = "Booking REST API stage default (*/*) burst, applied to each method."
  type        = number
  default     = 40
}
