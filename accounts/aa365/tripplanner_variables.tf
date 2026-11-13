# =============================================================================
# AA-TripPlanner variables. Kept separate so the TripPlanner surface is easy to review/diff against the AA-CIS
# resources. AA-1004 slice 3 (S267): the stack lives in modules/environment (tripplanner.tf, tripplanner_jobs.tf);
# every variable here is declared identically there and passed through as var.<same name> (environment.tf), so
# terraform.tfvars and every -var keep working. db/connection_budget.json reads the defaults from this file.
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

# AA-861: the jobs Lambda (tripplanner_jobs.tf) is the single worker of tripplanner.job: one run at a time, one DB
# connection (TripPlanner budget 15 + 5 + 1 = 21 of 30; db/connection_budget.json pool tp-jobs).
variable "tripplanner_jobs_reserved_concurrency" {
  type        = number
  description = "Reserved concurrent executions for the TripPlanner jobs Lambda (1 DB connection; keep 1: one runner)."
  default     = 1

  validation {
    condition     = var.tripplanner_jobs_reserved_concurrency == 1
    error_message = "The jobs Lambda is the single tripplanner.job runner: reserved concurrency must stay 1."
  }
}

# -----------------------------------------------------------------------------
# AA-1015: the daily cap on TripPlanner's customer-facing model spend (tp_compose + tp_search_embed, UTC day),
# enforced by the app (backend/shared/llm_gateway.py budget_status). Set explicitly on browse and assembly so the live
# value is in Terraform, not an implicit code default. Same value as the app default (5.0): no behaviour change.
# The CIS Apps board mirrors it (AA-CIS-App api/core/app_registry.py TP_DEFAULT_DAILY_CAP_USD); change both together.
# Optional per-stage caps (TP_DAILY_SPEND_CAP_SEARCH_USD / _COMPOSE_USD) stay unset: combined cap only.
# -----------------------------------------------------------------------------
variable "tripplanner_daily_spend_cap_usd" {
  type        = string
  description = "TripPlanner daily customer-facing AI spend cap in USD (TP_DAILY_SPEND_CAP_USD on the browse and assembly Lambdas). The app default is 5.0."
  default     = "5.0"
}

# -----------------------------------------------------------------------------
# AA-861: the jobs Lambda's schedule and its live-override switch. Declared next to the code in
# modules/environment/tripplanner_jobs.tf (as before AA-1004 slice 3) and here, identically, for the root.
# -----------------------------------------------------------------------------
variable "tripplanner_jobs_schedule_expression" {
  description = "AA-861 — when the TripPlanner jobs Lambda wakes (queues the daily runs, then runs due jobs)"
  type        = string
  # 19:30 UTC = 02:30 ICT: outside VN working hours, after Booking's 19:00 retention runs, before the 20:30 CIS
  # retention enqueue and the 22:00 snapshot expiry, away from the RDS backup window (03:00-04:00 UTC).
  default = "cron(30 19 * * ? *)"
}

variable "tripplanner_jobs_erasure_feed_schedule_expression" {
  description = "AA-1093 — how often the TripPlanner jobs Lambda reads the CIS erasure request feed (op erasure_feed: queues and runs tp_tenant_erase only)"
  type        = string
  # Booking reads the same feed every 300 s (EraseSchedule); CIS shows each app's report on the saga page.
  default = "rate(5 minutes)"
}

variable "tripplanner_jobs_retention_override_enabled" {
  description = "AA-861 — \"true\" (exact string) opens the LIVE manual_override of tp_retention_outbox_redact on this deployment (Dev proof runs before rows reach 90 days); a DRY RUN override never needs it"
  type        = string
  # Closed by default: a live override redacts Dev outbox rows younger than 90 days. Open it only for an approved
  # proof run (destructive-ops.md), then close it again.
  default = "false"

  validation {
    condition     = contains(["true", "false"], var.tripplanner_jobs_retention_override_enabled)
    error_message = "tripplanner_jobs_retention_override_enabled must be \"true\" or \"false\"."
  }
}

variable "tripplanner_jobs_tenant_erase_apply_enabled" {
  description = "AA-1093 — \"true\" (exact string) lets tp_tenant_erase APPLY an approved erasure plan on this deployment (TENANT_ERASE_APPLY_ENABLED); a DRY RUN, a verify, a backup and a restore drill never need it"
  type        = string
  # Closed by default: an apply deletes every TripPlanner row of a tenant. Open it only for an approved erasure (on Dev:
  # a synthetic tenant, the end-to-end offboarding drill), then close it again.
  default = "false"

  validation {
    condition     = contains(["true", "false"], var.tripplanner_jobs_tenant_erase_apply_enabled)
    error_message = "tripplanner_jobs_tenant_erase_apply_enabled must be \"true\" or \"false\"."
  }
}
