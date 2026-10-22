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
