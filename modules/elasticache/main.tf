# ============================================================
# ElastiCache Redis — AA-CIS
# SEO context cache TTL 24h
# ============================================================

locals {
  name_prefix = "${var.project}-${var.environment}"

  # AA-874: default parameter group per engine (the replication group switches engine with one variable).
  cache_parameter_groups = { for engine, major in { valkey = 8, redis = 7 } : engine => "default.${engine}${major}" }
}

resource "aws_elasticache_subnet_group" "main" {
  name       = "${local.name_prefix}-redis-subnet-group"
  subnet_ids = var.private_subnet_ids

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-redis-subnet-group"
  })
}

resource "aws_security_group" "redis" {
  name        = "${local.name_prefix}-sg-redis"
  description = "ElastiCache Redis security group"
  vpc_id      = var.vpc_id

  # ADR 0004b (X1 S11): admitted groups from var.ingress_sg_ids (null = only var.sg_app_id). Inline
  # block = authoritative; adding a group is authorize-only (see modules/vpc aws_security_group.rds).
  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = var.ingress_sg_ids != null ? var.ingress_sg_ids : [var.sg_app_id]
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-sg-redis"
  })
}

resource "aws_elasticache_cluster" "main" {
  cluster_id           = "${local.name_prefix}-redis"
  engine               = "redis"
  node_type            = var.node_type
  num_cache_nodes      = 1
  parameter_group_name = "default.redis7"
  engine_version       = "7.1"
  port                 = 6379
  subnet_group_name    = aws_elasticache_subnet_group.main.name
  security_group_ids   = [aws_security_group.redis.id]

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-redis"
  })
}

# ============================================================
# AA-874 — encrypted replication group (blue/green next to aws_elasticache_cluster.main)
#
# The standalone cluster above cannot get in-transit encryption in place (ForceNew) and standalone
# clusters do not offer at-rest encryption at all, so a replace would mean ~10-15 min with no node and
# every key lost (SEO cache, any tenant-pool rollback flag set to "false"). Instead a new group is built
# next to it with TLS (required), an AUTH token and at-rest encryption; keys are copied over, the CIS
# api + worker task definitions are switched in a later PR, then the old cluster is removed.
#
# The AUTH token is never in state: an ephemeral random_password feeds two write-only arguments in the
# same apply (the group's auth_token_wo and the secret version's secret_string_wo). Rotation: set
# auth_token_update_strategy explicitly (provider v6 has no default), bump var.auth_token_version (both
# *_wo_version follow it, so one apply writes the same new token to both), then redeploy CIS; procedure
# (ROTATE, redeploy, then SET) in docs/implementation-notes/AA-874.md.
# ============================================================

ephemeral "random_password" "auth" {
  length  = 64
  special = false # ElastiCache AUTH tokens: printable ASCII without @, " and /; alphanumerics only is simplest
}

resource "aws_secretsmanager_secret" "redis_auth" {
  name                    = "${var.project}/${var.environment}/redis-auth"
  description             = "AA-874: AUTH token of the CIS ElastiCache replication group (${local.name_prefix}-cache). Injected into the CIS api + worker as REDIS_AUTH_TOKEN by the ECS execution role. Written once by Terraform (write-only), never in state."
  recovery_window_in_days = var.environment == "dev" ? 0 : 30

  tags = merge(var.tags, {
    Name = "${var.project}/${var.environment}/redis-auth"
  })
}

resource "aws_secretsmanager_secret_version" "redis_auth" {
  secret_id                = aws_secretsmanager_secret.redis_auth.id
  secret_string_wo         = ephemeral.random_password.auth.result
  secret_string_wo_version = var.auth_token_version

  # Write the token to the secret only after the node has accepted it. Without this the version lands
  # seconds into the apply while the group takes 10-15 min; a failed group create would leave token A in
  # the secret, and the retry (a new group with a fresh ephemeral token B) would not rewrite the version
  # (secret_string_wo_version unchanged): a silent mismatch. With it, a failed group create writes nothing
  # and the retry writes the same token to both. The reverse case (group created, version write failed)
  # still needs the bump in docs/implementation-notes/AA-874.md.
  depends_on = [aws_elasticache_replication_group.main]
}

resource "aws_elasticache_replication_group" "main" {
  replication_group_id = "${local.name_prefix}-cache"
  description          = "AA-874: CIS cache (api + worker) with TLS, AUTH and at-rest encryption"

  engine               = var.cache_engine
  engine_version       = var.cache_engine_version
  parameter_group_name = local.cache_parameter_groups[var.cache_engine]
  node_type            = var.node_type
  port                 = 6379

  # One node, like the standalone cluster: no replica, no failover (Dev, cache-only data).
  num_cache_clusters         = 1
  automatic_failover_enabled = false
  multi_az_enabled           = false

  subnet_group_name  = aws_elasticache_subnet_group.main.name
  security_group_ids = [aws_security_group.redis.id]

  transit_encryption_enabled = true
  transit_encryption_mode    = "required"
  at_rest_encryption_enabled = true # AWS-managed key (no kms_key_id): no extra cost
  auth_token_wo              = ephemeral.random_password.auth.result
  auth_token_wo_version      = var.auth_token_version

  maintenance_window       = "sat:12:00-sat:13:00" # same window as the standalone cluster
  snapshot_retention_limit = 0                     # cache only, as before
  apply_immediately        = true

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-cache"
  })
}
