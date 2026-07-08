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

# AA-23: removed
# variable "secret_langfuse_arn" {
#   type        = string
#   description = "Secrets Manager ARN for LANGFUSE_SECRET_KEY"
# }

variable "secret_admin_arn" {
  description = "ARN of Secrets Manager secret for ADMIN_SECRET"
  type        = string
}

# AA-23: removed
# variable "secret_langfuse_public_key_arn" {
#   description = "ARN of Langfuse public key secret"
#   type        = string
# }

# AA-23: removed
# variable "secret_langfuse_host_arn" {
#   description = "ARN of Langfuse host secret"
#   type        = string
# }

variable "secret_anthropic_arn" {
  description = "ARN of Anthropic API key secret"
  type        = string
}

variable "secret_dataforseo_arn" {
  description = "ARN of Secrets Manager secret for DataForSEO credentials"
  type        = string
  default     = ""
}

variable "step_functions_arn" {
  description = "ARN of the pipeline Step Functions state machine"
  type        = string
  default     = ""
}

variable "sf_batch_threshold" {
  description = "Tour count above which ingest-s3 routes to Step Functions instead of direct background tasks"
  type        = number
  default     = 15
}

variable "execution_role_secrets_arn_pattern" {
  description = "ARN pattern granting the ECS execution role secretsmanager:GetSecretValue, needed to inject task-def secrets. Optional — leave null when the execution role already has this permission out-of-band."
  type        = string
  default     = null
}
