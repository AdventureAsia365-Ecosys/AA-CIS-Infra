# =============================================================================
# AA-829 (S248) — stable private DB hostname: db.<env>.internal -> the shared RDS instance.
#
# Every app DSN secret (aa-cis/<env>/rds, db-migrator, rds-cis-app, rds-app-user, booking/<env>/database-url,
# tripplanner/<env>/database-url, crm/<env>/database-url) names this CNAME instead of the RDS endpoint, so a
# restore or replacement of the instance (PITR drill, snapshot restore, new identifier) changes ONE record here
# instead of seven hand-edited secrets. The secrets themselves stay out of Terraform (shell only or REPLACE_ME +
# ignore_changes): their host is switched by the operator script of AA-829, not by this file.
#
# Resolution: a private hosted zone answers only inside the VPC it is associated with (VPC DNS support and
# hostnames are on, modules/vpc). Every DB caller (ECS api/worker/booking/crm/migrator tasks, TripPlanner
# Lambdas, ops Lambdas, the NAT instance used by the SSM tunnel) runs in module.vpc. The CNAME target is the
# RDS endpoint name, which the VPC resolver already answers with the private IP.
#
# TLS: all clients use sslmode/ssl "require" (no server-certificate hostname check). A client that moves to
# verify-full must keep the RDS endpoint name: the RDS certificate does not cover db.<env>.internal.
#
# Cost (D-19): 0.50 USD/month for the hosted zone + 0.40 USD per million queries (negligible on Dev).
# =============================================================================

variable "db_dns_target_override" {
  description = "AA-829: point db.<env>.internal at another RDS endpoint address (e.g. a restored instance outside Terraform, runbook restore-rds-pitr). null = the Terraform-managed instance (module.rds). Bare hostname, no port."
  type        = string
  default     = null
  validation {
    condition     = var.db_dns_target_override == null || can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.db_dns_target_override))
    error_message = "db_dns_target_override must be a bare lowercase hostname (no scheme, no port)."
  }
}

locals {
  db_private_zone_name = "${var.environment}.internal"
  db_private_dns_name  = "db.${local.db_private_zone_name}"
}

resource "aws_route53_zone" "private" {
  name    = local.db_private_zone_name
  comment = "AA-829: private names inside the ${var.environment} VPC (db.${local.db_private_zone_name} = shared RDS). Managed by AA-CIS-Infra."

  vpc {
    vpc_id = module.vpc.vpc_id
  }

  tags = merge(local.shared_tags, { Issue = "AA-829" })
}

resource "aws_route53_record" "db" {
  zone_id = aws_route53_zone.private.zone_id
  name    = local.db_private_dns_name
  type    = "CNAME"
  ttl     = 60 # short: a repoint after a restore is picked up within a minute by new connections
  records = [coalesce(var.db_dns_target_override, module.rds.db_address)]
}

output "db_private_dns" {
  description = "AA-829: the private DB hostname every DSN secret names, its zone and the current CNAME target."
  value = {
    name    = aws_route53_record.db.fqdn
    zone    = aws_route53_zone.private.name
    zone_id = aws_route53_zone.private.zone_id
    target  = one(aws_route53_record.db.records)
  }
}
