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

variable "tags" {
  description = "Resource tags"
  type        = map(string)
  default     = {}
}

variable "authorizer_lambda_invoke_arn" {
  description = "Invoke ARN of the tenant key authorizer Lambda"
  type        = string
}

variable "authorizer_lambda_name" {
  description = "Function name of the tenant key authorizer Lambda"
  type        = string
}

variable "alb_dns_name" {
  description = "DNS name of the internet-facing ALB"
  type        = string
  default     = "aa-cis-dev-alb-1114303360.us-west-1.elb.amazonaws.com"
}

variable "acm_cert_arn_us_east1" {
  description = "ACM certificate ARN (must be in same region as API — us-west-1 for REGIONAL endpoint)"
  type        = string
  default     = "arn:aws:acm:us-west-1:867490540162:certificate/260ab2f0-06f6-456b-b5d7-a4d0af96d405"
}
