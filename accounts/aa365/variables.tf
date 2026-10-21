# =============================================================================
# AA-246 Track B — variables
# =============================================================================

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-west-1"
}

variable "environment" {
  description = "Environment name (dev/staging/prod)"
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Must be dev, staging, or prod."
  }
}

variable "project" {
  description = "Project name"
  type        = string
  default     = "aa-cis"
}

variable "account_id" {
  description = "AWS Account ID (aa365 — must NOT default to the account-1 value)"
  type        = string
}

# ── Networking (own CIDR range — non-overlapping with account 1's 10.1.0.0/16) ──
variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.2.0.0/16"
}

variable "availability_zones" {
  type    = list(string)
  default = ["us-west-1a", "us-west-1c"]
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.2.1.0/24", "10.2.2.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.2.10.0/24", "10.2.11.0/24"]
}

variable "db_subnet_cidrs" {
  type    = list(string)
  default = ["10.2.20.0/24", "10.2.21.0/24"]
}

# ── RDS ──
variable "db_username" {
  description = "RDS master username"
  type        = string
  default     = "aa_cis_admin"
}

variable "db_password" {
  description = "RDS master password — supply via TF_VAR_db_password, never in tfvars"
  type        = string
  sensitive   = true
}

variable "rds_apply_immediately" {
  description = "AA-824: false (default) defers the RDS class change + parameter group reboot to the maintenance window. Pass -var=rds_apply_immediately=true only in a window where shared.job and booking.job are idle."
  type        = bool
  default     = false
}

# ── S3 ──
variable "s3_allowed_role_arns" {
  description = "IAM Role ARNs allowed to access CIS S3 buckets"
  type        = list(string)
  default     = []
}

# ── ALB / ACM ──
variable "acm_certificate_arn" {
  description = "ACM certificate ARN for HTTPS on ALB (aa365 domain, issued in this account)"
  type        = string
}

variable "domain_name" {
  description = "Custom domain for API Gateway regional custom domain mapping (aa365)"
  type        = string
}

# ── ECS ──
variable "task_cpu" {
  type    = number
  default = 512
}

variable "task_memory" {
  type    = number
  default = 1024
}

variable "service_desired_count" {
  type    = number
  default = 1
}

# ── Secrets referenced directly by ARN (not covered by modules/secrets data sources) ──
variable "secret_openai_arn" {
  description = "Secrets Manager ARN for OPENAI_API_KEY (aa365 — create manually first)"
  type        = string
}

variable "secret_admin_arn" {
  description = "Secrets Manager ARN for ADMIN_SECRET (aa365 — create manually first)"
  type        = string
}

variable "secret_jwt_arn" {
  description = "Secrets Manager ARN for JWT_SECRET (aa365 — create manually first, AA-506)"
  type        = string
}

# ── Lambda runtime config (plaintext vars, same pattern as existing root module) ──
variable "database_url" {
  description = "PostgreSQL connection string for Lambda functions — placeholder until real RDS provisioned"
  type        = string
  sensitive   = true
}

variable "redis_url" {
  type    = string
  default = ""
}

variable "dataforseo_login" {
  type      = string
  default   = ""
  sensitive = true
}

variable "dataforseo_password" {
  type      = string
  default   = ""
  sensitive = true
}

# ── Observability (AA-284/286/287) ──
variable "alert_email" {
  description = "Bootstrap recipient of the alerts topic (the one Terraform-managed e-mail subscription, shown locked in the CIS admin page, AA-913); AWS Budgets now notify the topic. Work inbox since S245; was a personal Gmail"
  type        = string
  default     = "nghieppham@adventure.asia"
}

# AA-828: monthly USD limit per `App` cost allocation tag value (one aws_budgets_budget each,
# observability.tf). Keys must be App tag values (DM-10.1). Defaults split the $250 account total
# (aws_budgets_budget.total_monthly) by expected footprint and give ~$50 to shared infrastructure
# (RDS, NAT, ALB, VPC); untagged spend is covered only by the total budget:
#   cis         150 — ECS api + worker (Fargate), ElastiCache, S3 medallion buckets, REST API; most of the account.
#   tripplanner  25 — 2 Lambdas + REST API + Cohere embed calls in acc2.
#   booking      25 — Fargate service (desired_count 0 today) + REST API + SES.
#   shared       50 — shared RDS, NAT instance + EIP, ALB + VPC-link NLB, WAF, CloudTrail (App =
#                     "shared", DM-10.1/10.3; added with the tag coverage, AA-828).
# Starting points only: tune after one full month of Cost Explorer data grouped by App.
variable "per_app_monthly_budgets" {
  description = "Monthly USD budget per App cost allocation tag value (AA-828)"
  type        = map(number)
  default = {
    cis         = 150
    tripplanner = 25
    booking     = 25
    shared      = 50 # shared RDS/NAT/ALB
  }

  validation {
    condition     = alltrue([for k, v in var.per_app_monthly_budgets : contains(["cis", "tripplanner", "booking", "crm", "shared"], k) && v > 0])
    error_message = "Keys must be App tag values (cis, tripplanner, booking, crm, shared) and amounts must be > 0."
  }
}

# AA-896: an anomaly whose total cost impact reaches this many USD is sent to the alerts SNS topic
# (cost_anomaly.tf). $5 is ~2% of the $250 account budget: small enough to catch a runaway batch or a
# forgotten resource within a day, large enough to skip day-to-day noise. Raise it if it is noisy.
variable "cost_anomaly_alert_usd" {
  description = "Total-impact threshold (USD) for Cost Anomaly Detection alerts to the alerts SNS topic (AA-896)"
  type        = number
  default     = 5

  validation {
    condition     = var.cost_anomaly_alert_usd >= 1
    error_message = "Use at least 1 USD."
  }
}

# S235 Phase 0 (AA-678): associate the REGIONAL web ACL (modules/waf) with the CIS and Booking REST
# API stages. Keep false until (1) the CI role has apigateway:SetWebACL (otherwise the CI apply
# fails with AccessDenied on the association) and (2) the geo allow-list is confirmed for Booking
# (customers outside the 10 allowed countries would be blocked).
# AA-876 (S246): still deferred per S241 (turn on when customer sign-up opens). Until then the edge caps are the
# API Gateway method throttles (modules/api_gateway) plus the CIS app's per-IP login throttle. Reusing this web
# ACL on the stages adds no ACL or rule fee, only ~0.60 USD per million requests inspected (blocker (2) above
# still applies).
variable "waf_protect_rest_api_stages" {
  type    = bool
  default = false
}

# S235 Phase 0 (AA-678): AWSManagedRulesCommonRuleSet rollout switch. true (default) = the whole
# managed group runs in COUNT: matches show up in the WAF log (terminatingRuleMatchDetails is empty,
# look at nonTerminatingMatchingRules / labels) and in AWS/WAFV2 CountedRequests, nothing is
# blocked. Set false to enforce once the counted matches have been reviewed.
# AA-806 (S239): reviewed. Count window 14/10 02:00Z..16/10 04:01Z had 0 CommonRuleSet matches on
# ~70.7k requests; the pre-flip test (large real content writes) matched only SizeRestrictions_BODY
# and GenericLFI_BODY, both kept in COUNT by modules/waf managed_rule_count_overrides.
variable "waf_common_rules_count_only" {
  type    = bool
  default = false
}

# AA-806: phase 3 of the CI role split (docs/ci-role-split.md). When true, the Terraform apply
# role's boundary also requires the workload boundary on role policy writes (Put/Delete/Attach/
# DetachRolePolicy), not only on CreateRole. Requires every aa-*-dev-* role the apply role writes to
# carry aws_iam_policy.workload_boundary (step 4, S237), or every policy change to such a role is
# denied. Turned on in step 3 (S239), together with the removal of the unbounded aa-cis-dev-role.
# The boundary policy is a bootstrap object: flipping this is a local MFA admin apply.
variable "tf_apply_require_boundary_on_role_policy_writes" {
  type    = bool
  default = true
}
