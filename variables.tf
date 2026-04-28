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

variable "db_username" {
  description = "RDS master username"
  type        = string
  default     = "aa_cis_admin"
}

variable "db_password" {
  description = "RDS master password"
  type        = string
  sensitive   = true
}

variable "account_id" {
  description = "AWS Account ID"
  type        = string
  default     = "867490540162"
}

variable "s3_allowed_role_arns" {
  description = "IAM Role ARNs allowed to access CIS S3 buckets"
  type        = list(string)
  default     = []
}

variable "acm_certificate_arn" {
  description = "ACM certificate ARN for HTTPS on ALB"
  type        = string
}

variable "task_cpu" {
  description = "ECS task CPU units"
  type        = number
  default     = 512
}

variable "task_memory" {
  description = "ECS task memory (MB)"
  type        = number
  default     = 1024
}

variable "service_desired_count" {
  description = "Initial number of ECS tasks"
  type        = number
  default     = 1
}

variable "secret_rds_arn" {
  description = "Secrets Manager ARN for DATABASE_URL"
  type        = string
}

variable "secret_openai_arn" {
  description = "Secrets Manager ARN for OPENAI_API_KEY"
  type        = string
}

variable "secret_langfuse_arn" {
  description = "Secrets Manager ARN for LANGFUSE_SECRET_KEY"
  type        = string
}

# Phase 4 — Lambda + Step Functions
variable "database_url" {
  description = "PostgreSQL connection string for Lambda functions"
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

variable "anthropic_api_key" {
  type      = string
  default   = ""
  sensitive = true
}

variable "secret_admin_arn" {
  description = "ARN of Secrets Manager secret for ADMIN_SECRET"
  type        = string
}
