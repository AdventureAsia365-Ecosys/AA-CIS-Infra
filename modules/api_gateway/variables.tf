variable "project" {
  description = "Project name prefix"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "account_id" {
  description = "AWS account ID"
  type        = string
}

variable "tags" {
  description = "Resource tags"
  type        = map(string)
  default     = {}
}

variable "alb_dns_name" {
  description = "DNS name of the internet-facing ALB"
  type        = string
  default     = "aa-cis-dev-alb-1114303360.us-west-1.elb.amazonaws.com"
}

variable "nlb_dns_name" {
  description = "DNS name of the internal NLB fronting the ALB, reached via VPC Link (AA-272)"
  type        = string
}

variable "vpc_link_id" {
  description = "ID of the API Gateway VPC Link (V1) wrapping the NLB (AA-272)"
  type        = string
}

variable "acm_cert_arn_us_east1" {
  description = "ACM certificate ARN (must be in same region as API — us-west-1 for REGIONAL endpoint). No default: the old default named a cert in acc1 that no caller used (AA-998)."
  type        = string
}

variable "domain_name" {
  description = "Custom domain name for the API Gateway regional custom domain mapping"
  type        = string
  default     = "api-cis.lumiguides.it.com"
}

variable "enable_execution_logging" {
  description = "Enable INFO-level CloudWatch execution logging on the dev stage — AA-272 diagnostic only, requires aws_api_gateway_account.cloudwatch_role_arn to be set first"
  type        = bool
  default     = false
}

# AA-876 — API Gateway throttling (WAF deferred per S241). Values are passed explicitly by the account root,
# sized from the per-second peaks in the execution logs (see docs/implementation-notes/AA-876.md).
variable "stage_throttle_rate_limit" {
  description = "Stage default (*/*) steady-state requests per second, applied to each method"
  type        = number
  default     = 50
}

variable "stage_throttle_burst_limit" {
  description = "Stage default (*/*) burst (token bucket size), applied to each method"
  type        = number
  default     = 100
}

variable "login_throttle_rate_limit" {
  description = "Requests per second on POST /auth/admin-login and POST /auth/tenant-login (each), all callers together"
  type        = number
  default     = 10
}

variable "login_throttle_burst_limit" {
  description = "Burst on POST /auth/admin-login and POST /auth/tenant-login (each)"
  type        = number
  default     = 20
}

variable "content_throttle_rate_limit" {
  description = "Optional override (requests per second) on /content/{content_proxy+} ANY; null = stage default"
  type        = number
  default     = null
}

variable "content_throttle_burst_limit" {
  description = "Burst for the /content override; null = 2 x content_throttle_rate_limit"
  type        = number
  default     = null
}
