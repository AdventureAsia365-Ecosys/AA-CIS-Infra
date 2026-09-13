# =============================================================================
# AA-TripPlanner variables (see tripplanner.tf). Kept separate so the
# TripPlanner surface is easy to review/diff against the AA-CIS resources.
# =============================================================================

variable "tripplanner_advisor_email" {
  type        = string
  description = "Single advisor notification address for send-to-advisor."
  default     = "pqnghiep1354@gmail.com"
}
