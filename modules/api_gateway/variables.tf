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

variable "alb_dns_name" {
  description = "DNS name of the internet-facing ALB"
  type        = string
  default     = "aa-cis-dev-alb-1114303360.us-west-1.elb.amazonaws.com"
}

variable "nlb_dns_name" {
  description = "DNS name of the internal NLB fronting the ALB, reached via VPC Link (AA-272)"
  type        = string
}

variable "vpc_link_id" {
  description = "ID of the API Gateway VPC Link (V1) wrapping the NLB (AA-272)"
  type        = string
}

variable "acm_cert_arn_us_east1" {
  description = "ACM certificate ARN (must be in same region as API — us-west-1 for REGIONAL endpoint)"
  type        = string
  default     = "arn:aws:acm:us-west-1:867490540162:certificate/260ab2f0-06f6-456b-b5d7-a4d0af96d405"
}

variable "domain_name" {
  description = "Custom domain name for the API Gateway regional custom domain mapping"
  type        = string
  default     = "api-cis.lumiguides.it.com"
}

variable "enable_execution_logging" {
  description = "Enable INFO-level CloudWatch execution logging on the dev stage — AA-272 diagnostic only, requires aws_api_gateway_account.cloudwatch_role_arn to be set first"
  type        = bool
  default     = false
}
