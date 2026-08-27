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

# Networking
variable "private_subnet_ids" {
  description = "Private subnet IDs for Lambda VPC config"
  type        = list(string)
}

variable "sg_app_id" {
  description = "Security group ID for Lambda functions"
  type        = string
}

# S3
variable "bronze_bucket_arn" {
  description = "ARN of Bronze S3 bucket (raw intake)"
  type        = string
}

variable "bronze_bucket_name" {
  description = "Name of Bronze S3 bucket"
  type        = string
}

variable "gold_bucket_arn" {
  description = "ARN of Gold S3 bucket (published content)"
  type        = string
}

variable "gold_bucket_name" {
  description = "Name of Gold S3 bucket"
  type        = string
}

# Secrets
variable "secret_rds_arn" {
  description = "ARN of RDS credentials secret"
  type        = string
}

variable "secret_openai_arn" {
  description = "ARN of OpenAI API key secret"
  type        = string
}

# AA-23: removed
# variable "secret_langfuse_arn" {
#   description = "ARN of Langfuse credentials secret"
#   type        = string
# }

# Step Functions
variable "step_functions_arn" {
  description = "ARN of Step Functions state machine (set after SF created)"
  type        = string
  default     = ""
}

# ECS (for content gen task invocation)
variable "ecs_cluster_arn" {
  description = "ECS cluster ARN"
  type        = string
}

variable "ecs_task_definition_arn" {
  description = "ECS task definition ARN for content generation"
  type        = string
}

variable "ecs_container_name" {
  description = "ECS container name"
  type        = string
  default     = "aa-cis-api"
}

variable "ecs_task_role_name" {
  description = "Name of the ECS task IAM role (aws_iam_role_policy.role only accepts a name, not an ARN) — pass module.ecs.task_role_name explicitly when project/environment differ from the default"
  type        = string
  default     = "aa-cis-dev-ecs-task-role"
}

# Lambda zip paths (built by package_lambdas.sh)
variable "lambda_zip_dir" {
  description = "Directory containing Lambda zip files"
  type        = string
  default     = "../../dist/lambdas"
}

# Runtime config
variable "database_url" {
  description = "PostgreSQL connection string"
  type        = string
  sensitive   = true
}

variable "redis_url" {
  description = "Redis connection URL"
  type        = string
  default     = ""
}

variable "dataforseo_login" {
  description = "DataForSEO API login"
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
  description = "Anthropic API key for content generation"
  type        = string
  default     = ""
  sensitive   = true
}

variable "tags" {
  description = "Resource tags"
  type        = map(string)
  default     = {}
}

variable "api_base_url" {
  description = "Base URL of the ECS API for content Lambda to call"
  type        = string
  default     = ""
}

variable "brand_brief_parser_zip" {
  description = "Path to brand brief parser Lambda ZIP file"
  type        = string
}
