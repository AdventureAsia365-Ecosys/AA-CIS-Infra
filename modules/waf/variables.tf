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
  description = "AWSManagedRulesCommonRuleSet sub-rules set to COUNT instead of BLOCK (S235: known false positives for this API)"
  default     = ["SizeRestrictions_BODY", "CrossSiteScripting_BODY"]
}

variable "rest_api_stage_arns" {
  type        = map(string)
  description = "API Gateway REST API stage ARNs to associate with this web ACL, keyed by a static label (S235). Empty = none."
  default     = {}
}
