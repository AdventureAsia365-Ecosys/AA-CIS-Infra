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

variable "tags" {
  description = "AA-828: tags merged into every taggable resource of this module (the root passes App = \"shared\", DM-10.1). Provider default_tags still add Project/Environment/ManagedBy/Account."
  type        = map(string)
  default     = {}
}

variable "rds_ingress_sg_ids" {
  description = "ADR 0004b (X1 S11): security groups admitted to the RDS group on 5432 (inline ingress, authoritative). Null keeps the old behaviour: only this module's app group."
  type        = list(string)
  default     = null

  validation {
    condition     = var.rds_ingress_sg_ids == null ? true : length(var.rds_ingress_sg_ids) > 0
    error_message = "rds_ingress_sg_ids: pass null (old single source) or a non-empty list; an empty list would make an ingress rule with no source."
  }
}
