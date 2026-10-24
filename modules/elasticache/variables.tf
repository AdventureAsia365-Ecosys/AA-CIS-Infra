variable "project" { type = string }
variable "environment" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "sg_app_id" { type = string }

variable "ingress_sg_ids" {
  description = "ADR 0004b (X1 S11): security groups admitted on 6379 (inline ingress, authoritative). Null keeps the old behaviour: only var.sg_app_id."
  type        = list(string)
  default     = null

  validation {
    condition     = var.ingress_sg_ids == null ? true : length(var.ingress_sg_ids) > 0
    error_message = "ingress_sg_ids: pass null (old single source) or a non-empty list; an empty list would make an ingress rule with no source."
  }
}
variable "node_type" {
  type    = string
  default = "cache.t3.micro"
}

variable "tags" {
  description = "AA-828: tags merged into every taggable resource of this module (the root passes App = \"cis\", DM-10.1). Provider default_tags still add Project/Environment/ManagedBy/Account."
  type        = map(string)
  default     = {}
}

variable "cache_engine" {
  description = "AA-874: engine of the encrypted replication group. valkey (Redis-wire compatible, ~20% cheaper per node hour) or redis."
  type        = string
  default     = "valkey"

  validation {
    condition     = contains(["valkey", "redis"], var.cache_engine)
    error_message = "cache_engine must be valkey or redis."
  }
}

variable "cache_engine_version" {
  description = "AA-874: engine version of the replication group; must match the parameter group family (valkey 8.x -> default.valkey8, redis 7.x -> default.redis7)."
  type        = string
  default     = "8.2"

  # Fail at plan, not at apply: the parameter group is picked by engine, so the major version must fit it.
  validation {
    condition     = can(regex(var.cache_engine == "valkey" ? "^8\\." : "^7\\.", var.cache_engine_version))
    error_message = "cache_engine_version must be 8.x for valkey (default.valkey8) or 7.x for redis (default.redis7)."
  }
}

variable "auth_token_version" {
  description = "AA-874: version of the write-only AUTH token. Bumping it generates a new token and writes it to both the replication group and the secret in one apply (rotation, see main.tf)."
  type        = number
  default     = 1
}
