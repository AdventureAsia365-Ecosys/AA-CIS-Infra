# =============================================================================
# AA-CIS Dev — variables.tf (complete, S11 Phase 4)
# =============================================================================

variable "aws_region" {
  type    = string
  default = "us-west-1"
}

variable "environment" {
  type = string
}

variable "project" {
  type = string
}

variable "account_id" {
  type = string
}

# Networking
variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "db_subnet_ids" {
  type = list(string)
}

variable "sg_rds_id" {
  type = string
}

variable "sg_app_id" {
  type = string
}

variable "sg_alb_id" {
  type = string
}

# RDS
variable "db_name" {
  type = string
}

variable "db_username" {
  type = string
}

# S3
variable "uploads_bucket" {
  type = string
}

variable "outputs_bucket" {
  type = string
}

# Tags
variable "tags" {
  type    = map(string)
  default = {}
}

# ALB + ECS
variable "acm_certificate_arn" {
  type = string
}

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

# Secrets
variable "secret_rds_arn" {
  type = string
}

variable "secret_openai_arn" {
  type = string
}

variable "secret_langfuse_arn" {
  type = string
}

# =============================================================================
# Phase 4 additions — Lambda + Step Functions
# =============================================================================

variable "database_url" {
  description = "Full PostgreSQL connection string for Lambda functions"
  type        = string
  sensitive   = true
}

variable "redis_url" {
  description = "Redis connection URL (ElastiCache endpoint)"
  type        = string
  default     = ""
}

variable "dataforseo_login" {
  description = "DataForSEO API login email"
  type        = string
  default     = ""
  sensitive   = true
}

variable "dataforseo_password" {
  description = "DataForSEO API password"
  type        = string
  default     = ""
  sensitive   = true
}

variable "anthropic_api_key" {
  description = "Anthropic API key"
  type        = string
  default     = ""
  sensitive   = true
}
