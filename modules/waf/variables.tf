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
  # AA-931: x-aa-origin is the CloudFront origin-verify secret (var.origin_verify_header). AA-1090: x-aa-tp-site is the
  # TripPlanner distribution's site header (var.tripplanner_site_header), a secret too.
  default = ["authorization", "x-admin-secret", "x-api-key", "cookie", "x-aa-origin", "x-aa-tp-site"]
}

variable "origin_verify_header" {
  description = "AA-931 (CRM-03): header that CloudFront adds to every origin request ({ name, value }). When set, rule CloudFrontOriginAllow (local.rule_priorities) allows requests carrying exactly this value past the rate and geo rules. null = no rule. Add the header name to log_redacted_headers."
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

variable "tripplanner_web" {
  description = "AA-1038: the TripPlanner web rules (TripPlannerRateLimitPerIp, TripPlannerRateLimitModelPaths, TripPlannerChallengePlanner), each scoped to host AND the exact origin secret (needs origin_verify_header). viewer_ip_header: the header the CloudFront viewer-request function writes with the viewer's address (the rate key). protected_paths: the BFF paths that are rate-limited per viewer and challenged (the model calls and Send to advisor). path_transformations run on every path match, in order. null = no rule (the ACL as before AA-1038)."
  type = object({
    host                 = string
    viewer_ip_header     = string
    rate_limit           = number
    model_rate_limit     = number
    challenge_immunity_s = number
    protected_paths      = list(string)
    path_transformations = list(string)
  })
  default = null
}

variable "tripplanner_site_header" {
  description = "AA-1090 R8: the header the TripPlanner CloudFront distribution adds to every origin request ({ name, value }; an origin custom header, so a viewer cannot set it). When set, the three TripPlanner web rules match this header (EXACTLY) instead of the TripPlanner Host, so they apply to every alternate domain name of the distribution (agency domains). null = Host scope as before. Add the header name to log_redacted_headers."
  type = object({
    name  = string
    value = string
  })
  default   = null
  sensitive = true
}

variable "rate_limit_exempt_cidrs" {
  description = "AA-1092: public egress addresses of our own services (the NAT instance EIP, /32) whose server-to-server calls to the REST APIs (CRM and staff web -> api-cis / api-booking) all share one source IP. Scoped out of RateLimit1000, which would otherwise count every internal caller as one client. They still pass CommonRuleSet. Empty = no IP set (the ACL as before AA-1092)."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.rate_limit_exempt_cidrs : can(cidrhost(c, 0)) && endswith(c, "/32")])
    error_message = "rate_limit_exempt_cidrs takes single IPv4 addresses as /32 CIDRs only."
  }
}

variable "geo_exempt_hosts" {
  description = "AA-1092: hosts scoped out of GeoBlockNonAllowed: the public REST API hosts (api-cis, api-booking) once the ACL is on their stages. Travellers anywhere load catalogue images from api-cis and partner agencies call Booking from anywhere; the geo list was made for the staff hosts on the ALB. Empty = geo applies to every host (the ACL as before AA-1092)."
  type        = list(string)
  default     = []
}

variable "cloudfront_viewer_rate" {
  description = "AA-1165: rule CloudFrontViewerRateLimit, a per-viewer rate limit on the CloudFront path (requests carrying the exact origin secret, needs origin_verify_header), before both allow rules. TripPlanner traffic is scoped out (its own rules) and so is our own NAT egress (rate_limit_exempt_cidrs, matched on the viewer header: the CRM web's server-side calls reach the API through CloudFront from that one address). viewer_ip_header: the header the CloudFront viewer-request functions write with the viewer's address (the rate key). limit: requests per 5 minutes per viewer. count_only: true = COUNT (observe), false = BLOCK with a 429. null = no rule."
  type = object({
    viewer_ip_header = string
    limit            = number
    count_only       = bool
  })
  default = null

  validation {
    condition     = var.cloudfront_viewer_rate == null || try(var.cloudfront_viewer_rate.limit >= 100 && floor(var.cloudfront_viewer_rate.limit) == var.cloudfront_viewer_rate.limit, false)
    error_message = "cloudfront_viewer_rate.limit must be a whole number of at least 100 (a page load is dozens of requests)."
  }
}

variable "custom_response_header_quota" {
  type        = number
  description = "AWS WAF quota: custom response headers per web ACL, 100 by default and adjustable in Service Quotas at no cost. The web ACL precondition keeps every custom response header of the ACL under it (AA-1111, S294). Raise it only after AWS raised the quota."
  default     = 100
}
