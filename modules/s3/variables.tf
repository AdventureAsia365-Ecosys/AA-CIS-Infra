variable "project" {
  description = "Project prefix: aa-cis"
  type        = string
  default     = "aa-cis"
}

variable "environment" {
  description = "dev | staging | prod"
  type        = string
}

variable "allowed_role_arns" {
  description = "List of IAM Role ARNs allowed to access CIS S3 buckets (Lambda + ECS task roles)"
  type        = list(string)
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default     = {}
}
