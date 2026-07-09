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
