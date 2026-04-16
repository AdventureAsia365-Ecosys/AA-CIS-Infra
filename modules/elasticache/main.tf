# ============================================================
# ElastiCache Redis — AA-CIS
# SEO context cache TTL 24h
# ============================================================

locals {
  name_prefix = "${var.project}-${var.environment}"
}

resource "aws_elasticache_subnet_group" "main" {
  name       = "${local.name_prefix}-redis-subnet-group"
  subnet_ids = var.private_subnet_ids

  tags = {
    Name = "${local.name_prefix}-redis-subnet-group"
  }
}

resource "aws_security_group" "redis" {
  name        = "${local.name_prefix}-sg-redis"
  description = "ElastiCache Redis security group"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [var.sg_app_id]
  }

  tags = {
    Name = "${local.name_prefix}-sg-redis"
  }
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

  tags = {
    Name = "${local.name_prefix}-redis"
  }
}
