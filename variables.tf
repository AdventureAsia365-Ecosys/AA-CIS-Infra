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
