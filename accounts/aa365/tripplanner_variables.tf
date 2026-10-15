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
# hundreds of DB connections on the shared RDS. 5 per function = the interim cap set by hand on
# 15/10/2026 (put-function-concurrency) when AWS approved the quota early: total 10 = the old
# account limit, and with the TripPlanner pool at max 5 per instance that is <= 50 connections.
# Raise it (AA-824 scope: 10 each) only after the TripPlanner pool max 1 per instance has shipped.
# -----------------------------------------------------------------------------
variable "tripplanner_lambda_reserved_concurrency" {
  type        = number
  description = "Reserved concurrent executions for each TripPlanner Lambda (browse, assembly). Interim 5 while the TP DB pool max is 5 per instance; raise after pool max 1 ships."
  default     = 5
}
