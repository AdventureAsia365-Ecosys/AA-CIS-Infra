variable "project"     { type = string }
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
