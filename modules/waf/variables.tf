variable "project" { type = string }
variable "environment" { type = string }

variable "alb_arn" {
  type        = string
  description = "ALB ARN to associate WAF with"
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "rate_limit" {
  type        = number
  default     = 1000
  description = "Max requests per 5 minutes per IP"
}

variable "geo_allowed_countries" {
  type        = list(string)
  description = "ISO 3166-1 alpha-2 country codes allowed through geo-match rule"
  # Matches AWS console state at import time (AA-59). Update via PR after verifying with stakeholders.
  default = ["US", "GB", "AU", "SG", "VN", "IN", "JP", "TH", "NZ", "CA"]
}

variable "vpc_allow_cidr" {
  type        = string
  default     = null
  description = "Optional CIDR to bypass GeoBlock/RateLimit for internal VPC Link traffic health checks — leave null to skip this rule entirely"
}

variable "managed_rule_count_overrides" {
  type        = list(string)
  description = "AWSManagedRulesCommonRuleSet sub-rules set to COUNT instead of BLOCK (S235: known false positives for this API; S239: GenericLFI_BODY matches relative ../ links in content saves)"
  default     = ["SizeRestrictions_BODY", "CrossSiteScripting_BODY", "GenericLFI_BODY"]
}

variable "rest_api_stage_arns" {
  type        = map(string)
  description = "API Gateway REST API stage ARNs to associate with this web ACL, keyed by a static label (S235). Empty = none."
  default     = {}
}

variable "common_rules_count_only" {
  type        = bool
  description = "true = AWSManagedRulesCommonRuleSet in COUNT for the whole group (observe mode); false = enforce, with managed_rule_count_overrides still in COUNT (S235)"
  default     = true
}

variable "log_redacted_headers" {
  type        = list(string)
  description = "Request headers replaced with REDACTED in the WAF log (AA-806 S239: credentials must not be logged)"
  # AA-931: x-aa-origin is the CloudFront origin-verify secret (var.origin_verify_header).
  default = ["authorization", "x-admin-secret", "x-api-key", "cookie", "x-aa-origin"]
}

variable "origin_verify_header" {
  description = "AA-931 (CRM-03): header that CloudFront adds to every origin request ({ name, value }). When set, rule CloudFrontOriginAllow (priority 3) allows requests carrying exactly this value past the rate and geo rules. null = no rule. Add the header name to log_redacted_headers."
  type = object({
    name  = string
    value = string
  })
  default   = null
  sensitive = true
}

# S263 alert diet (AA-1025): Dev keeps the WAF log 30 days and only the requests a rule acted on.
variable "log_retention_days" {
  description = "Retention of the aws-waf-logs-<prefix> log group (365 = the AA-872 security class; Dev passes 30 since S263)"
  type        = number
  default     = 365
}

variable "log_only_acted_on" {
  description = "Log only the requests a rule blocked, challenged or counted (logging filter, default DROP); allowed requests with no rule match are not logged. Cuts the vended-log ingest on Dev (S263)."
  type        = bool
  default     = false
}

variable "staff_web_hosts" {
  description = "AA-911: host names of the staff frontends served by the ALB :443 (aa-cis.<zone>, booking.<zone>). Scoped out of RateLimit1000 and counted by StaffWebRateLimit. Empty = neither (the ACL as before AA-911)."
  type        = list(string)
  default     = []
}

variable "staff_web_rate_limit" {
  description = "AA-911: requests per 5 minutes per client IP on the staff hosts (rule StaffWebRateLimit)."
  type        = number
  default     = 5000
}
