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
  default     = "https://aa-booking-admin.vercel.app"

  validation {
    condition     = startswith(var.booking_staff_admin_url, "https://")
    error_message = "booking_staff_admin_url must be an https:// URL."
  }
}
