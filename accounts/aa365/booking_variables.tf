variable "booking_github_repo_id" {
  description = "Numeric GitHub repo id of AdventureAsia365-Ecosys/AA-Booking (GET /repos/AdventureAsia365-Ecosys/AA-Booking -> .id). Empty until the repo exists: the deploy-role trust then accepts any repo id for the exact name AA-Booking, in both the immutable and the plain OIDC subject form. Once set, only the immutable subject with this exact id is trusted (fail closed, same as aa-cis-dev-role)."
  type        = string
  default     = ""

  validation {
    condition     = can(regex("^([0-9]+)?$", var.booking_github_repo_id))
    error_message = "booking_github_repo_id must be empty or a numeric GitHub repo id."
  }
}
