# =============================================================================
# AA-1004 slice 2 (S266) — the AA-Partner (CRM) stack's naming contract and the inputs it reads from the account root.
#
# The CRM stack (crm_app.tf, crm_web.tf, crm_data.tf, crm_storage.tf, crm_mail.tf, crm_scrub.tf,
# crm_llm.tf) moved here from accounts/aa365 with one `moved` block per resource (accounts/aa365/environment.tf). Its
# per-app settings (crm_github_repo_id, crm_*_enabled, ...) stay declared in the file that reads them, as before the
# move, and the root declares the same variables (accounts/aa365/crm_variables.tf) and passes them through.
#
# The variables below are the objects the CRM stack runs on that are still declared in the account root: the CRM edge
# (crm_edge.tf, crm_agency_edge.tf, crm_client_edge.tf: CloudFront, certificates, DNS records, the host listener rules
# and the hosts they answer), the identity pools and clients (identity*.tf), the CRM security groups
# (app_security_groups.tf, ADR 0004b), the M2M client secret (identity_m2m.tf), the alarm runbook links and the
# ecosystem tags. Each later slice that moves the owner of one of them into this module turns the input back into a
# direct reference. Values only, never secrets: nothing here is sensitive.
# =============================================================================

locals {
  # The CRM naming contract (was accounts/aa365 cicd_crm.tf; the root reads both back through module outputs, the CI
  # role grants and the boundary denies key on them): resources aa-crm-<env>-*, tag App = "crm".
  crm_name_prefix = "aa-crm-${var.environment}"

  crm_tags = {
    Project     = "AA-Partner"
    Environment = var.environment
    ManagedBy   = "terraform"
    App         = "crm" # DM-10.1 cost allocation; the KMS grants and boundary denies key on it
  }
}

# ---- Shared platform (generic, also usable by later slices) ----

variable "alb_arn_suffix" {
  description = "ARN suffix of the shared ALB (module.alb.alb_arn_suffix); dimension of the no-healthy-task alarms."
  type        = string
}

variable "dns_zone_name" {
  description = "Public DNS zone of the environment (ses_variables.tf); the CRM ingest mail domain and the Content studio host are names under it."
  type        = string
}

variable "ecosys_tags" {
  description = "Ecosystem tags of the shared alarms (observability_ecosys.tf local.ecosys_tags); the CRM alarms add App = crm."
  type        = map(string)
}

variable "runbook_suffix" {
  description = "Alarm description suffixes, ' Runbook: <url>' per runbook key (alarm_runbooks.tf local.runbook_suffix)."
  type        = map(string)
}

variable "m2m_crm_client_secret_arn" {
  description = "Secret aa-crm/<env>/m2m-booking-client of the CRM's M2M client (identity_m2m.tf); the CRM task maps it as M2M_CLIENT."
  type        = string
}

# ---- CRM security groups (app_security_groups.tf, ADR 0004b: one SG file for every DB caller) ----

variable "crm_api_security_group_id" {
  description = "Security group of the AA-Partner API tasks (aws_security_group.crm_api)."
  type        = string
}

variable "crm_web_security_group_id" {
  description = "Security group of the AA-Partner web tasks (aws_security_group.crm_web)."
  type        = string
}

# ---- CRM edge (crm_edge.tf, crm_agency_edge.tf, crm_client_edge.tf) ----

variable "crm_edge_on" {
  description = "1 when the CRM edge exists (crm_edge.tf local.crm_edge_on: crm_edge_enabled and custom_domains_enabled), else 0. Counts the no-healthy-task alarms and attaches the target groups to the ECS services."
  type        = number

  validation {
    condition     = contains([0, 1], var.crm_edge_on)
    error_message = "crm_edge_on must be 0 or 1."
  }
}

variable "crm_partner_host" {
  description = "The partner host (crm_edge.tf local.crm_partner_host): CRM_API_ORIGIN of the web, the API base URL."
  type        = string
}

variable "crm_agency_host" {
  description = "The agency host (crm_agency_edge.tf local.crm_agency_host): public origin of the web, the Content studio and the mail OAuth callback."
  type        = string
}

variable "crm_client_hosts" {
  description = "The client hosts (crm_client_edge.tf local.crm_client_hosts; empty without the edge)."
  type        = list(string)
}

variable "crm_intake_origin" {
  description = "Origin of the public inquiry form pages (crm_client_edge.tf local.crm_intake_origin; empty without the edge)."
  type        = string
}

variable "crm_api_listener_rule_gate" {
  description = "ARNs of the root's aws_lb_listener_rule.crm_api (alb_rules.tf; empty without the edge). The API service waits for it: ECS refuses a target group that is on no load balancer."
  type        = list(string)
}

variable "crm_partner_default_rule_gate" {
  description = "ARNs of the root's aws_lb_listener_rule.crm_partner_default (crm_edge.tf). The web service waits for it."
  type        = list(string)
}

# ---- Identity (identity.tf, identity_partner.tf, identity_variables.tf). Public values: issuers, pool / client ids. ----

variable "cognito_workforce_pool_endpoint" {
  description = "Endpoint of the WORKFORCE pool (aws_cognito_user_pool.workforce.endpoint); COGNITO_WORKFORCE_ISSUER = https://<this>."
  type        = string
}

variable "cognito_workforce_cis_admin_client_id" {
  description = "WORKFORCE client cis-admin (aws_cognito_user_pool_client.workforce[\"cis-admin\"].id)."
  type        = string
}

variable "cognito_workforce_breakglass_client_id" {
  description = "WORKFORCE client breakglass (aws_cognito_user_pool_client.workforce[\"breakglass\"].id)."
  type        = string
}

variable "cognito_workforce_crm_staff_client_id" {
  description = "WORKFORCE client crm-staff (aws_cognito_user_pool_client.workforce[\"crm-staff\"].id): the AA staff console of the CRM web and the API's staff route class."
  type        = string
}

variable "cognito_workforce_prefix_domain" {
  description = "Prefix domain of the WORKFORCE managed login (aws_cognito_user_pool_domain.workforce_prefix.domain)."
  type        = string
}

variable "cognito_partner_pool_id" {
  description = "Id of the PARTNER pool (aws_cognito_user_pool.partner.id)."
  type        = string
}

variable "cognito_partner_web_client_id" {
  description = "PARTNER client partner-web (aws_cognito_user_pool_client.partner[\"partner-web\"].id)."
  type        = string
}

variable "cognito_partner_issuer" {
  description = "Issuer URL of the PARTNER pool (identity_partner.tf local.idpartner_issuer)."
  type        = string
}

variable "cognito_partner_login_base" {
  description = "Managed-login base URL of the PARTNER pool (identity_partner.tf local.idpartner_login_base)."
  type        = string
}

variable "cognito_external_cis_portal_client_id" {
  description = "EXTERNAL client cis-portal (aws_cognito_user_pool_client.external[\"cis-portal\"].id): the CRM web's sign-in client while crm_partner_signin_enabled is false."
  type        = string
}

variable "cognito_external_prefix_domain" {
  description = "Prefix domain of the EXTERNAL managed login (aws_cognito_user_pool_domain.external_prefix.domain)."
  type        = string
}

variable "identity_custom_domains_enabled" {
  description = "True when the Cognito custom domains are on (identity.tf local.id_custom_domains); the CRM web then uses the custom managed-login hosts below."
  type        = bool
}

variable "identity_external_custom_domain" {
  description = "Custom domain of the EXTERNAL managed login (identity_variables.tf)."
  type        = string
}

variable "identity_workforce_custom_domain" {
  description = "Custom domain of the WORKFORCE managed login (identity_variables.tf)."
  type        = string
}
