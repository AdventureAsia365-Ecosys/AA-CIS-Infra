variable "project" { type = string }
variable "environment" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "sg_app_id" { type = string }

variable "ingress_sg_ids" {
  description = "ADR 0004b (X1 S11): security groups admitted on 2049 (inline ingress, authoritative). Null keeps the old behaviour: only var.sg_app_id."
  type        = list(string)
  default     = null
}

variable "tags" {
  description = "AA-828: tags merged into every taggable resource of this module (the root passes App = \"cis\", DM-10.1). Provider default_tags still add Project/Environment/ManagedBy/Account."
  type        = map(string)
  default     = {}
}
