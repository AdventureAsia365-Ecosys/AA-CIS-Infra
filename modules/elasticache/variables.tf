variable "project" { type = string }
variable "environment" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "sg_app_id" { type = string }
variable "node_type" {
  type    = string
  default = "cache.t3.micro"
}
