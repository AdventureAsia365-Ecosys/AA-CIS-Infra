# =============================================================================
# ADR 0004b (AA-Ecosys docs/adr/0004b-per-app-security-groups.md) — one security group per caller.
# X1 (AA-852) moved every service, task and Lambda from the old shared app group onto these groups (S11 expand, S13
# move, S14 contract); AA-1185 (S296) removed the shared group itself once its last two network interfaces (left by
# the deleted Lambda aa-cis-dev-ingestion) were deleted. (EFS and its group were removed in S257, AA-697.)
#
# Ingress only where a caller serves traffic: each serving group takes only its app port from the ALB group.
# Egress: each group's outbound rules are in its egress block(s) below. AWS APIs, Bedrock and third-party APIs
# leave through the NAT instance (no VPC interface endpoints, so no self-443 rule; same-region S3 uses the gateway
# endpoint on the private route table).
#
# No rule references another of these groups and none of them references a data-store group, so there
# is no cycle with module.vpc: the groups read module.vpc.vpc_id / sg_alb_id, and the data-store groups
# read the ids below through the module list variables.
# =============================================================================

locals {
  cis_port = 8000 # modules/ecs container port (api task definition, target group)

  # Callers admitted by each data store (ADR 0004b decision 2). The shared app group left these lists in
  # X1 S14 (contract) and was deleted in AA-1185.
  rds_ingress_sg_ids = [
    aws_security_group.cis_api.id,
    aws_security_group.cis_worker.id,
    aws_security_group.booking_api.id,
    aws_security_group.crm_api.id,
    aws_security_group.tp_lambda.id,
    aws_security_group.db_migrate.id,
  ]
  redis_ingress_sg_ids = [
    aws_security_group.cis_api.id,
    aws_security_group.cis_worker.id,
  ]
}

# ── CIS api (ECS service aa-cis-dev-api) ──────────────────────
resource "aws_security_group" "cis_api" {
  name        = "${local.name_prefix}-sg-cis-api"
  description = "CIS api service (ADR 0004b)"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "App port from the ALB"
    from_port       = local.cis_port
    to_port         = local.cis_port
    protocol        = "tcp"
    security_groups = [module.vpc.sg_alb_id]
  }

  # AA-1185: outbound rules from app_egress.tf (sg_egress_narrowed = false is the rollback).
  dynamic "egress" {
    for_each = local.app_egress.cis_api
    content {
      description = egress.value.description
      from_port   = egress.value.from_port
      to_port     = egress.value.to_port
      protocol    = egress.value.protocol
      cidr_blocks = egress.value.cidr_blocks
    }
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-sg-cis-api", Component = "api" })
}

# ── CIS worker (ECS service aa-cis-dev-worker): serves no traffic ─────────────
resource "aws_security_group" "cis_worker" {
  name        = "${local.name_prefix}-sg-cis-worker"
  description = "CIS job worker service, no ingress (ADR 0004b)"
  vpc_id      = module.vpc.vpc_id

  # AA-1185: outbound rules from app_egress.tf (sg_egress_narrowed = false is the rollback).
  dynamic "egress" {
    for_each = local.app_egress.cis_worker
    content {
      description = egress.value.description
      from_port   = egress.value.from_port
      to_port     = egress.value.to_port
      protocol    = egress.value.protocol
      cidr_blocks = egress.value.cidr_blocks
    }
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-sg-cis-worker", Component = "worker" })
}

# ── Booking api (ECS service aa-booking-dev-api, booking.tf) ──
resource "aws_security_group" "booking_api" {
  name        = "${local.name_prefix}-sg-booking-api"
  description = "Booking api service (ADR 0004b)"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "App port from the ALB (/booking/* listener rule)"
    from_port       = local.bk_port
    to_port         = local.bk_port
    protocol        = "tcp"
    security_groups = [module.vpc.sg_alb_id]
  }

  # AA-1185: outbound rules from app_egress.tf (sg_egress_narrowed = false is the rollback).
  dynamic "egress" {
    for_each = local.app_egress.booking_api
    content {
      description = egress.value.description
      from_port   = egress.value.from_port
      to_port     = egress.value.to_port
      protocol    = egress.value.protocol
      cidr_blocks = egress.value.cidr_blocks
    }
  }

  tags = merge(local.bk_tags, { Name = "${local.name_prefix}-sg-booking-api" })
}

# ── AA-Partner api (ECS service aa-crm-dev-api, crm_app.tf, AA-933): API + crm.job worker ──
resource "aws_security_group" "crm_api" {
  name        = "${local.name_prefix}-sg-crm-api"
  description = "AA-Partner (CRM) api service (ADR 0004b)"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "App port from the ALB (/crm/* rule behind CloudFront)"
    from_port       = local.crm_port
    to_port         = local.crm_port
    protocol        = "tcp"
    security_groups = [module.vpc.sg_alb_id]
  }

  # AA-1185: outbound rules from app_egress.tf (sg_egress_narrowed = false is the rollback).
  dynamic "egress" {
    for_each = local.app_egress.crm_api
    content {
      description = egress.value.description
      from_port   = egress.value.from_port
      to_port     = egress.value.to_port
      protocol    = egress.value.protocol
      cidr_blocks = egress.value.cidr_blocks
    }
  }

  tags = merge(local.crm_app_tags, { Name = "${local.name_prefix}-sg-crm-api" })
}

# ── AA-Partner web (ECS service aa-crm-dev-web, crm_web.tf, AA-935): Next.js standalone ──
# Ingress only from the ALB on 3000 (the partner host's default rule). Not in rds_ingress_sg_ids: the web has no
# database access (it reaches data only through the CRM API, over the public partner host).
resource "aws_security_group" "crm_web" {
  name        = "${local.name_prefix}-sg-crm-web"
  description = "AA-Partner (CRM) web service (ADR 0004b)"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "Web port from the ALB (partner host default rule behind CloudFront)"
    from_port       = local.crm_web_port
    to_port         = local.crm_web_port
    protocol        = "tcp"
    security_groups = [module.vpc.sg_alb_id]
  }

  # AA-1185: outbound rules from app_egress.tf (sg_egress_narrowed = false is the rollback).
  dynamic "egress" {
    for_each = local.app_egress.crm_web
    content {
      description = egress.value.description
      from_port   = egress.value.from_port
      to_port     = egress.value.to_port
      protocol    = egress.value.protocol
      cidr_blocks = egress.value.cidr_blocks
    }
  }

  tags = merge(local.crm_web_tags, { Name = "${local.name_prefix}-sg-crm-web" })
}

# ── Staff frontends (ECS services aa-cis-dev-admin + aa-booking-dev-admin, modules/environment/staff_web.tf, AA-911) ─
# Next.js standalone, one service per app: CIS admin on 3000, Booking admin on 3001. Ingress only from the ALB on those ports (the
# HTTPS host rules of alb_rules.tf). Not in rds_ingress_sg_ids: neither app has database access (both reach data only
# through their public API hosts).
resource "aws_security_group" "staff_web" {
  name        = "${local.name_prefix}-sg-staff-web"
  description = "Staff frontends web tasks: CIS admin and Booking admin (ADR 0004b, AA-911)"
  vpc_id      = module.vpc.vpc_id

  dynamic "ingress" {
    for_each = module.environment.staff_web_ports
    content {
      description     = "Staff web ${ingress.key} port from the ALB (HTTPS host rule)"
      from_port       = ingress.value
      to_port         = ingress.value
      protocol        = "tcp"
      security_groups = [module.vpc.sg_alb_id]
    }
  }

  # AA-1060: the WordPress test site sidecar of the Booking admin task (modules/environment test_wp.tf), HTTPS host rule
  # test_wp of alb_rules.tf. Only while test_wp_enabled is on.
  dynamic "ingress" {
    for_each = var.test_wp_enabled ? [module.environment.test_wp_port] : []
    content {
      description     = "WordPress test site sidecar port from the ALB (HTTPS host rule, AA-1060)"
      from_port       = ingress.value
      to_port         = ingress.value
      protocol        = "tcp"
      security_groups = [module.vpc.sg_alb_id]
    }
  }

  # AA-1185: outbound rules from app_egress.tf (sg_egress_narrowed = false is the rollback).
  dynamic "egress" {
    for_each = local.app_egress.staff_web
    content {
      description = egress.value.description
      from_port   = egress.value.from_port
      to_port     = egress.value.to_port
      protocol    = egress.value.protocol
      cidr_blocks = egress.value.cidr_blocks
    }
  }

  tags = merge(local.staff_web_tags, { Name = "${local.name_prefix}-sg-staff-web" })
}

# ── TripPlanner web (ECS service aa-tripplanner-dev-web, modules/environment/tripplanner_web.tf, AA-1038) ─────────
resource "aws_security_group" "tripplanner_web" {
  name        = "${local.name_prefix}-sg-tp-web"
  description = "TripPlanner web task behind CloudFront and the ALB host rule (ADR 0004b, AA-1038)"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "TripPlanner web port from the ALB (CloudFront VPC origin host rule)"
    from_port       = module.environment.tripplanner_web_port
    to_port         = module.environment.tripplanner_web_port
    protocol        = "tcp"
    security_groups = [module.vpc.sg_alb_id]
  }

  # AA-1185: outbound rules from app_egress.tf (sg_egress_narrowed = false is the rollback).
  dynamic "egress" {
    for_each = local.app_egress.tripplanner_web
    content {
      description = egress.value.description
      from_port   = egress.value.from_port
      to_port     = egress.value.to_port
      protocol    = egress.value.protocol
      cidr_blocks = egress.value.cidr_blocks
    }
  }

  tags = merge(local.tp_tags, { Component = "web", Name = "${local.name_prefix}-sg-tp-web" })
}

# ── TripPlanner Lambdas (browse + assembly + jobs, modules/environment/tripplanner*.tf): no ingress ─────────
resource "aws_security_group" "tp_lambda" {
  name        = "${local.name_prefix}-sg-tp-lambda"
  description = "TripPlanner browse and assembly Lambdas, no ingress (ADR 0004b)"
  vpc_id      = module.vpc.vpc_id

  # AA-1185: outbound rules from app_egress.tf (sg_egress_narrowed = false is the rollback).
  dynamic "egress" {
    for_each = local.app_egress.tp_lambda
    content {
      description = egress.value.description
      from_port   = egress.value.from_port
      to_port     = egress.value.to_port
      protocol    = egress.value.protocol
      cidr_blocks = egress.value.cidr_blocks
    }
  }

  tags = merge(local.tp_tags, { Name = "${local.name_prefix}-sg-tp-lambda" })
}

# ── DB Migrate / Schema Dump / isolation probe (task family aa-cis-dev-db-migrate, db_migrator.tf) ──
resource "aws_security_group" "db_migrate" {
  name        = "${local.name_prefix}-sg-db-migrate"
  description = "DB Migrate, Schema Dump and isolation probe one-off tasks, no ingress (ADR 0004b)"
  vpc_id      = module.vpc.vpc_id

  # AA-1185: outbound rules from app_egress.tf (sg_egress_narrowed = false is the rollback).
  dynamic "egress" {
    for_each = local.app_egress.db_migrate
    content {
      description = egress.value.description
      from_port   = egress.value.from_port
      to_port     = egress.value.to_port
      protocol    = egress.value.protocol
      cidr_blocks = egress.value.cidr_blocks
    }
  }

  tags = merge(local.shared_tags, { Name = "${local.name_prefix}-sg-db-migrate", Component = "db" })
}

# ── Ops Lambdas (dfs-balance check, dfs_balance.tf): reach the CIS API through the NAT, no data store ──
resource "aws_security_group" "ops_lambda" {
  name        = "${local.name_prefix}-sg-ops-lambda"
  description = "Ops Lambdas (dfs-balance check), no ingress, no data-store access (ADR 0004b)"
  vpc_id      = module.vpc.vpc_id

  # AA-1185: outbound rules from app_egress.tf (sg_egress_narrowed = false is the rollback).
  dynamic "egress" {
    for_each = local.app_egress.ops_lambda
    content {
      description = egress.value.description
      from_port   = egress.value.from_port
      to_port     = egress.value.to_port
      protocol    = egress.value.protocol
      cidr_blocks = egress.value.cidr_blocks
    }
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-sg-ops-lambda", Component = "jobs" })
}
