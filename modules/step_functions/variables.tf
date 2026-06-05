variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "account_id" {
  type = string
}

# Lambda ARNs
variable "seo_lambda_arn" {
  type = string
}

variable "validation_lambda_arn" {
  type = string
}

variable "export_lambda_arn" {
  type = string
}

# ECS (Content Generation)
variable "ecs_cluster_arn" {
  type = string
}

variable "ecs_task_definition_arn" {
  type = string
}

variable "ecs_container_name" {
  type    = string
  default = "api"
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "sg_app_id" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "content_lambda_arn" {
  description = "ARN of the content generation Lambda"
  type        = string
}
