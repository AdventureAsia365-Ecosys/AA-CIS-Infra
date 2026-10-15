variable "project" {
  type = string
}

variable "environment" {
  type = string
}

# AA-824 (decision E5): db.t3.micro (1 GB) -> db.t4g.small (2 GB, Graviton). max_connections =
# LEAST(DBInstanceClassMemory/9531392, 5000), so roughly 80-110 -> roughly 190-200.
variable "instance_class" {
  type    = string
  default = "db.t4g.small"
}

variable "allocated_storage" {
  type    = number
  default = 20
}

variable "max_allocated_storage" {
  type        = number
  description = "Storage autoscaling ceiling in GB (AA-824)."
  default     = 100
}

variable "log_retention_days" {
  type        = number
  description = "Retention of the exported postgresql log group (AA-824)."
  default     = 14
}

variable "apply_immediately" {
  type        = bool
  description = "AA-824: false defers the class change and parameter group reboot to the maintenance window."
  default     = false
}

variable "db_name" {
  type    = string
  default = "aa_cis_dev"
}

variable "db_username" {
  type = string
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "db_subnet_group_name" {
  type = string
}

variable "sg_rds_id" {
  type = string
}
