variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "sg_alb_id" {
  type        = string
  description = "Security group ID for ALB"
}

variable "acm_certificate_arn" {
  type        = string
  description = "ACM certificate ARN for HTTPS listener"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs for the internal NLB (VPC Link, AA-272)"
}

variable "vpc_cidr_block" {
  type        = string
  description = "VPC CIDR block, for NLB security group ingress (AA-272)"
}

variable "access_logs_bucket" {
  type        = string
  default     = null
  description = "Optional S3 bucket for ALB access logs — leave null to skip (AA-272 diagnostic only)"
}

variable "access_logs_prefix" {
  type        = string
  default     = "alb-access-logs"
  description = "S3 key prefix for ALB access logs, if access_logs_bucket is set (AA-272 diagnostic only)"
}

variable "tags" {
  description = "AA-828: tags merged into every taggable resource of this module (the root passes App = \"shared\", DM-10.1). Provider default_tags still add Project/Environment/ManagedBy/Account."
  type        = map(string)
  default     = {}
}
