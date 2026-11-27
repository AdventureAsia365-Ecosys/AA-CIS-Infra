# =============================================================================
# AA-1185 scope 8 (S295 audit SA-37 / data-boundary DB-07, tech lead approval 27/11/2026): outbound rules of the
# per-caller security groups (app_security_groups.tf, ADR 0004b), narrowed from "all protocols to anywhere" to what
# each caller needs. 0 USD.
#
# Outbound dependency inventory (read from the app code and this repo on 27/11/2026; see
# docs/implementation-notes/AA-1185-net-b.md for the per-app list):
#   - TCP 443 to anywhere, through the NAT instance (or the S3 gateway endpoint for same-region S3): every AWS API
#     (ECR pull, CloudWatch Logs, Secrets Manager, SSM / ECS Exec, STS, SES v2, SQS, S3, Cognito, Bedrock in this
#     account and the cross-account Bedrock roles), the LLM and data providers (Anthropic, OpenAI, DataForSEO,
#     Geoapify, Overpass, Google APIs, Jev, Mapbox), Sentry, the public app hosts (api-cis., api-booking.,
#     api-tripplanner., portal., tripplanner.) and the tenant-named HTTPS sites behind the CIS SSRF-safe client.
#   - TCP 5432 to the db subnets (RDS): CIS api / worker, Booking api, CRM api, TripPlanner Lambdas, DB Migrate tasks.
#   - TCP 6379 to the private subnets (ElastiCache replication group): CIS api / worker only.
#   - TCP 25, 465, 587, 2525 to anywhere: CRM api only (agency SMTP send-as; AA-Partner
#     api/app/mail/providers/smtp.py PORTS, the only ports it dials).
#   - DNS needs no rule: the tasks use the Amazon-provided resolver (DHCP options AmazonProvidedDNS), and security
#     groups never filter traffic to it, to the instance / task metadata endpoints or to Amazon Time Sync.
#   - Responses to inbound traffic (ALB -> app port, health checks) need no egress rule: security groups are stateful.
#
# The data-store rules use the subnet CIDRs, not the RDS / Redis groups: those groups admit the ids of these groups
# (local.rds_ingress_sg_ids, module.vpc / module.elasticache), so referencing them back would be a dependency cycle.
# The data-store groups still admit only the listed callers.
#
# Rollback: sg_egress_narrowed = false puts the old single "all outbound" rule back on every group (one apply, no
# replacement: inline egress rules are revoked / authorized in place).
# =============================================================================

variable "sg_egress_narrowed" {
  description = "AA-1185: narrowed outbound rules on the per-caller app security groups (443 out, the data-store ports to their subnets, SMTP for the CRM api). false = the old all-outbound rule on every group (rollback)."
  type        = bool
  default     = true
}

locals {
  # One rule = one inline egress block. Descriptions use only the characters EC2 accepts in a rule description.
  egress_https = {
    description = "HTTPS out through the NAT instance: AWS APIs, Bedrock, LLM and data providers, Cognito, Sentry, public app hosts"
    protocol    = "tcp"
    from_port   = 443
    to_port     = 443
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress_postgres = {
    description = "PostgreSQL to the RDS instance in the db subnets"
    protocol    = "tcp"
    from_port   = 5432
    to_port     = 5432
    cidr_blocks = var.db_subnet_cidrs
  }
  egress_redis = {
    description = "Redis TLS to the ElastiCache replication group in the private subnets"
    protocol    = "tcp"
    from_port   = 6379
    to_port     = 6379
    cidr_blocks = var.private_subnet_cidrs
  }
  # AA-Partner api/app/mail/providers/smtp.py PORTS (relay, implicit TLS, submission, alternative submission).
  egress_smtp = [for port in [25, 465, 587, 2525] : {
    description = "Agency SMTP send-as, port ${port}"
    protocol    = "tcp"
    from_port   = port
    to_port     = port
    cidr_blocks = ["0.0.0.0/0"]
  }]
  egress_all = {
    description = "All outbound (rollback, sg_egress_narrowed = false)"
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Per caller (keys = the aws_security_group names in app_security_groups.tf).
  app_egress_narrowed = {
    cis_api         = [local.egress_https, local.egress_postgres, local.egress_redis]
    cis_worker      = [local.egress_https, local.egress_postgres, local.egress_redis]
    booking_api     = [local.egress_https, local.egress_postgres]
    crm_api         = concat([local.egress_https, local.egress_postgres], local.egress_smtp)
    crm_web         = [local.egress_https]
    staff_web       = [local.egress_https]
    tripplanner_web = [local.egress_https]
    tp_lambda       = [local.egress_https, local.egress_postgres]
    db_migrate      = [local.egress_https, local.egress_postgres]
    ops_lambda      = [local.egress_https]
  }

  app_egress = {
    for caller, rules in local.app_egress_narrowed : caller => var.sg_egress_narrowed ? rules : [local.egress_all]
  }
}
