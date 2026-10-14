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
  description = "Email address for SNS alert subscription + AWS Budgets notifications"
  type        = string
  default     = "pqnghiep1354@gmail.com"
}

# S235 Phase 0 (AA-678): associate the REGIONAL web ACL (modules/waf) with the CIS and Booking REST
# API stages. Keep false until (1) the CI role has apigateway:SetWebACL (otherwise the CI apply
# fails with AccessDenied on the association) and (2) the geo allow-list is confirmed for Booking
# (customers outside the 10 allowed countries would be blocked).
variable "waf_protect_rest_api_stages" {
  type    = bool
  default = false
}
