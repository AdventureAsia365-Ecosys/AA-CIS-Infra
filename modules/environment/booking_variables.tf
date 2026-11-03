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
  description = "Base URL of the AA-Booking staff admin (Vercel project aa-booking-admin); staff e-mail links to <this>/cases/<code>."
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
