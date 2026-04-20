# Existing variables (already in variables.tf)
variable "project" {
  type = string
}

variable "environment" {
  type = string
}

# New variables for ECS Service + ALB integration
variable "aws_region" {
  type    = string
  default = "us-west-1"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnets for ECS tasks"
}

variable "sg_app_id" {
  type        = string
  description = "Security group for ECS tasks"
}

variable "target_group_arn" {
  type        = string
  description = "ALB target group ARN"
}

variable "task_cpu" {
  type        = number
  default     = 512
  description = "Fargate task CPU units (256/512/1024/2048/4096)"
}

variable "task_memory" {
  type        = number
  default     = 1024
  description = "Fargate task memory in MB"
}

variable "service_desired_count" {
  type        = number
  default     = 1
  description = "Desired number of ECS tasks"
}

variable "secret_rds_arn" {
  type        = string
  description = "Secrets Manager ARN for DATABASE_URL"
}

variable "secret_openai_arn" {
  type        = string
  description = "Secrets Manager ARN for OPENAI_API_KEY"
}

variable "secret_langfuse_arn" {
  type        = string
  description = "Secrets Manager ARN for LANGFUSE_SECRET_KEY"
}
