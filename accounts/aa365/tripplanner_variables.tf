# =============================================================================
# AA-TripPlanner variables (see tripplanner.tf). Kept separate so the
# TripPlanner surface is easy to review/diff against the AA-CIS resources.
# =============================================================================

# tripplanner_advisor_email removed (AA-811, S238): TripPlanner sends no e-mail; AA-Booking sends the staff
# "new inquiry" e-mail (booking_staff_notify_email in booking_variables.tf).

# -----------------------------------------------------------------------------
# AA-806 (from AA-805): HTTP API route throttling. All numbers are Dev placeholders, not capacity
# planning; revisit with real traffic before any public launch.
#
# default_route_settings is applied to each route separately (ANY /browse/{proxy+} and
# ANY /trip/{proxy+} each get their own bucket); it is not one aggregate cap for the stage. It must
# stay generous: the map (MapView) fetches one /browse/tiles request per 1-degree cell with
# Promise.all on every moveend / filter change, so a whole viewport arrives as one burst of dozens of
# requests. The first cut (20 rps / burst 40) returned 429 on normal panning. Account-wide API
# Gateway limits are 10,000 rps / 5,000 burst.
#
# Tight limits apply only to the two routes that cost money per request:
#   POST /trip/{trip_id}/narrate  - Bedrock compose/renarrate (satellite roles)
#   GET  /browse/search           - one Cohere embedding call per query
# -----------------------------------------------------------------------------
variable "tripplanner_throttle_rate_limit" {
  type        = number
  description = "Dev placeholder. Steady-state requests per second, per route, for every TripPlanner route without its own route_settings (each route has its own bucket, not one stage-wide cap). Generous on purpose: map tile fan-out."
  default     = 500
}

variable "tripplanner_throttle_burst_limit" {
  type        = number
  description = "Dev placeholder. Burst (token bucket size), per route, for every TripPlanner route without its own route_settings."
  default     = 1000
}

variable "tripplanner_narrate_throttle_rate_limit" {
  type        = number
  description = "Dev placeholder. Requests per second for POST /trip/{trip_id}/narrate (Bedrock LLM call, costs money)."
  default     = 2
}

variable "tripplanner_narrate_throttle_burst_limit" {
  type        = number
  description = "Dev placeholder. Burst for POST /trip/{trip_id}/narrate."
  default     = 5
}

variable "tripplanner_search_throttle_rate_limit" {
  type        = number
  description = "Dev placeholder. Requests per second for GET /browse/search (one embedding call per query, costs money)."
  default     = 10
}

variable "tripplanner_search_throttle_burst_limit" {
  type        = number
  description = "Dev placeholder. Burst for GET /browse/search."
  default     = 20
}

# -----------------------------------------------------------------------------
# AA-824 (decision E6): reserved concurrency on browse and assembly, so the account Lambda quota
# (raised 10 -> 1000 on 15/10/2026, case 179197638600671) cannot turn a TripPlanner burst into
# hundreds of DB connections on the shared RDS. The TripPlanner pool is max 1 connection per
# instance (AA-TripPlanner-Web backend/shared/db.py, S237), so the TripPlanner connection budget
# is browse + assembly = 15 + 5 = 20, inside the 30 planned for the `tripplanner` role (data
# standards C2.2). Browse gets the larger share: the S237 UI verify saw 503s (Lambda throttling)
# when the /plan List view prefetched 24 tour pages at the interim cap of 5.
# -----------------------------------------------------------------------------
variable "tripplanner_browse_reserved_concurrency" {
  type        = number
  description = "Reserved concurrent executions for the TripPlanner browse Lambda (1 DB connection each)."
  default     = 15
}

variable "tripplanner_lambda_reserved_concurrency" {
  type        = number
  description = "Reserved concurrent executions for the TripPlanner assembly Lambda (1 DB connection each)."
  default     = 5
}
