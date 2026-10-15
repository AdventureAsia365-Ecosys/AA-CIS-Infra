variable "project" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.1.0.0/16"
}

variable "availability_zones" {
  description = "List of availability zones"
  type        = list(string)
  default     = ["us-west-1a", "us-west-1c"]
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDR blocks"
  type        = list(string)
  default     = ["10.1.1.0/24", "10.1.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDR blocks"
  type        = list(string)
  default     = ["10.1.10.0/24", "10.1.11.0/24"]
}

variable "db_subnet_cidrs" {
  description = "DB subnet CIDR blocks"
  type        = list(string)
  default     = ["10.1.20.0/24", "10.1.21.0/24"]
}

variable "permissions_boundary_arn" {
  description = "AA-806 step 4: ARN of the permissions boundary set on every IAM role this module creates (accounts/aa365 passes aa-workload-boundary). Null leaves the roles unbounded."
  type        = string
  default     = null
}
