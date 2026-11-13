# =============================================================================
# AA-1004 slice 2 (S266) — the AA-Partner (CRM) settings of this root. The CRM stack moved into modules/environment
# (crm_app.tf, crm_web.tf, crm_data.tf, crm_storage.tf, crm_mail.tf, crm_scrub.tf, crm_llm.tf); the
# module declares the same variables next to the resources that read them, and environment.tf passes each one through
# unchanged. Same names, types, defaults and validations as before the move, so terraform.tfvars and every -var stay
# valid. Change a setting here AND in the module file (tools/terraform/tests/test_aa1004_environment_moves.py checks
# that both declarations stay identical).
# =============================================================================

# as in modules/environment/crm_app.tf
variable "crm_github_repo_id" {
  description = "AA-933: numeric GitHub repository id of AdventureAsia365-Ecosys/AA-Partner (`gh api repos/AdventureAsia365-Ecosys/AA-Partner --jq .id`). Set: the deploy role trusts only the immutable OIDC subject with this exact id. Empty: any id with the exact repo name (fail open to the name only — keep it set)."
  type        = string
  default     = ""

  validation {
    condition     = var.crm_github_repo_id == "" || can(regex("^[0-9]+$", var.crm_github_repo_id))
    error_message = "crm_github_repo_id must be empty or a numeric GitHub repository id."
  }
}

# as in modules/environment/crm_app.tf
variable "crm_cis_api_url" {
  description = "AA-978: CIS_API_URL of the AA-Partner task, the base URL the CRM worker pulls the CIS membership feed from (contract tenant.membership.v1, <this>/tenant/membership/v1). The public CIS REST API custom domain (route /tenant/membership/{membership_proxy+}, modules/api_gateway); no trailing slash."
  type        = string
  default     = "https://api-cis.lumiguides.it.com"

  validation {
    condition     = can(regex("^https://[a-z0-9.-]+$", var.crm_cis_api_url))
    error_message = "crm_cis_api_url must be an https origin without a path or trailing slash."
  }
}

# as in modules/environment/crm_app.tf
variable "crm_booking_api_url" {
  description = "AA-947: BOOKING_API_URL of the AA-Partner task, the Booking API origin the CRM calls booking.b2b.v1 on (<this>/booking/b2b/v1: quotes, holds, confirms, the /events feed) with the same M2M_CLIENT (scopes booking.b2b/*, identity_m2m.tf). The public Booking REST API custom domain (custom_domains.tf); no path, no trailing slash. Empty: AA requests stay pending in the CRM."
  type        = string
  default     = "https://api-booking.lumiguides.it.com"

  validation {
    condition     = var.crm_booking_api_url == "" || can(regex("^https://[a-z0-9.-]+$", var.crm_booking_api_url))
    error_message = "crm_booking_api_url must be empty or an https origin without a path or trailing slash."
  }
}

# as in modules/environment/crm_app.tf
variable "crm_booking_admin_url" {
  description = "AA-956 (CRM-26, design v3 Fix B3): BOOKING_ADMIN_URL of the AA-Partner task, the origin of the AA-Booking staff admin (ECS service aa-booking-<env>-admin since AA-911; the Vercel project aa-booking-admin was retired in S272). The S-02 ops release links AA ops to <this>/b2b-desk (tab Departures & incidents) to flag an incident on a departure; the CRM never flags one itself. No path, no trailing slash. Empty: S-02 shows the departure ids without the link."
  type        = string
  default     = "https://booking.lumiguides.it.com"

  validation {
    condition     = var.crm_booking_admin_url == "" || can(regex("^https://[a-z0-9.-]+$", var.crm_booking_admin_url))
    error_message = "crm_booking_admin_url must be empty or an https origin without a path or trailing slash."
  }
}

# as in modules/environment/crm_app.tf
variable "crm_sentry_enabled" {
  description = "AA-933: map secret crm/<env>/sentry-dsn into the AA-Partner task (SENTRY_DSN) and set SENTRY_REQUIRED=true. Turn on only AFTER the secret has a value (Sentry project aa-partner-api): a task whose secret has no value fails to start."
  type        = bool
  default     = false
}

# as in modules/environment/crm_web.tf
variable "crm_partner_signin_enabled" {
  description = "AA-939 (ADR 0006b): the CRM web signs in with the partner pool (partner-web client, MFA required) instead of the EXTERNAL cis-portal client. Flip only after the e2e users exist on the partner pool; then write the web secret for the partner client (crm_dev_identity.py web-secret --pool partner) and deploy the web. Since AA-979 P2b the CRM API no longer accepts cis-portal tokens on /crm/v1, so false is NOT a working rollback any more: keep it true."
  type        = bool
  default     = true

  validation {
    condition     = var.crm_partner_signin_enabled
    error_message = "false is retired since AA-979 P2b: the CRM API refuses cis-portal tokens on /crm/v1, so a CRM web on the cis-portal client breaks every agency page after sign-in."
  }
}

# as in modules/environment/crm_web.tf
variable "crm_web_client_hosts" {
  description = "AA-935: extra traveller (client) hosts the CRM web serves /c/* on (WEB_CLIENT_HOSTS). AA-936 adds go-dev. itself (crm_client_edge.tf); list only additional hosts here."
  type        = list(string)
  default     = []
}

# as in modules/environment/crm_storage.tf
variable "crm_audit_compliance_enabled" {
  description = "AA-932: put the 12-month audit bucket (aa-crm-<env>-audit-c-*) in COMPLIANCE mode. Irreversible for every locked version (nobody, root included, can shorten or lift it). Go-real only (CRM-38); a precondition refuses it on Dev (design v3 §3.6: Dev governance only)."
  type        = bool
  default     = false
}

# as in modules/environment/crm_mail.tf
variable "crm_ingest_subdomain" {
  description = "AA-945: label under dns_zone_name of the AA-Partner forward-in mail domain (design v3 lane §6.5 'in.<domain>'). Agencies forward to <local_part>@<label>.<zone>; the AA-Partner task gets the full domain as CRM_INGEST_DOMAIN."
  type        = string
  default     = "crm-in"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.crm_ingest_subdomain))
    error_message = "crm_ingest_subdomain must be one DNS label."
  }
}

# as in modules/environment/crm_mail.tf
variable "crm_mail_oauth_enabled" {
  description = "AA-945: map secret crm/<env>/mail-oauth (Google + Microsoft OAuth client of the agencies' send-as) into the AA-Partner task as MAIL_OAUTH. Turn on only AFTER the secret has a value: a task whose valueFrom secret has no value fails to start."
  type        = bool
  default     = false
}

# as in modules/environment/crm_scrub.tf
variable "crm_scrub_guardrail_enabled" {
  description = "AA-938: create the F3 scrub guardrail (acc2), grant the CRM task role and the corpus role ApplyGuardrail on it, and pass its id / version to the AA-Partner task. Turn on only AFTER the MFA bootstrap apply of the cicd_crm.tf CrmBedrockGuardrail* statements."
  type        = bool
  default     = false
}

# as in modules/environment/crm_llm.tf
variable "crm_llm_bedrock_enabled" {
  description = "AA-1027 F4: run the CRM AI gateway on Amazon Nova Lite (acc2 Bedrock, the CRM task role): the task env CRM_LLM_* and bedrock:InvokeModel on that inference profile only. Off = the app's stub provider (cost 0). Apply AFTER AA-Partner crm-042 (the draft route) is applied."
  type        = bool
  default     = false
}

# as in modules/environment/crm_slo.tf (AA-1096 L6)
variable "crm_slo" {
  description = "AA-969 / AA-1096 L6: the AA-Partner SLO alarm thresholds (AA-Partner docs/operations/slo.md, keep both in step): five_xx_percent = 5xx share of requests in a 5-minute window, min_requests = smallest window judged, p95_latency_s = target group p95, alarm_periods / alarm_breaching = windows evaluated / breaching to alarm."
  type = object({
    five_xx_percent = number
    min_requests    = number
    p95_latency_s   = number
    alarm_periods   = number
    alarm_breaching = number
  })
  default = {
    five_xx_percent = 2
    min_requests    = 20
    p95_latency_s   = 1.5
    alarm_periods   = 3
    alarm_breaching = 2
  }

  validation {
    condition     = var.crm_slo.five_xx_percent > 0 && var.crm_slo.five_xx_percent <= 100 && var.crm_slo.min_requests >= 1 && var.crm_slo.p95_latency_s > 0 && var.crm_slo.alarm_breaching >= 1 && var.crm_slo.alarm_breaching <= var.crm_slo.alarm_periods
    error_message = "crm_slo: five_xx_percent in (0, 100], min_requests >= 1, p95_latency_s > 0, 1 <= alarm_breaching <= alarm_periods."
  }
}
