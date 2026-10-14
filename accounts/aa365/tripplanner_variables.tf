# =============================================================================
# AA-TripPlanner variables (see tripplanner.tf). Kept separate so the
# TripPlanner surface is easy to review/diff against the AA-CIS resources.
# =============================================================================

variable "tripplanner_advisor_email" {
  type        = string
  description = "Single advisor notification address for send-to-advisor."
  default     = "pqnghiep1354@gmail.com"
}

# -----------------------------------------------------------------------------
# AA-806 (from AA-805): HTTP API stage throttling. Account-wide API Gateway limits are 10,000 rps /
# 5,000 burst; these Dev defaults sit far below that and are meant as a backstop against a scan or
# a runaway client, not as capacity planning. Revisit with real traffic before any public launch.
# -----------------------------------------------------------------------------
variable "tripplanner_throttle_rate_limit" {
  type        = number
  description = "Steady-state requests per second for all TripPlanner routes (stage default)."
  default     = 20
}

variable "tripplanner_throttle_burst_limit" {
  type        = number
  description = "Burst (token bucket size) for all TripPlanner routes (stage default)."
  default     = 40
}

variable "tripplanner_narrate_throttle_rate_limit" {
  type        = number
  description = "Requests per second for POST /trip/{trip_id}/narrate (LLM call, costs money)."
  default     = 2
}

variable "tripplanner_narrate_throttle_burst_limit" {
  type        = number
  description = "Burst for POST /trip/{trip_id}/narrate."
  default     = 5
}
