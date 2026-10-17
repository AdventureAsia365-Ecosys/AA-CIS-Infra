# ============================================================
# RDS Module — AA-CIS PostgreSQL 15
# ============================================================

locals {
  name_prefix = "${var.project}-${var.environment}"
}

# -----------------------------------------------------------------------------
# AA-824 (S237 data review §5.1, decision E5): guardrails for the shared instance (CIS + TripPlanner
# + Booking). Custom parameter group instead of default.postgres15.
#
# Checked live on default.postgres15 (15/10/2026): shared_preload_libraries = pg_stat_statements,
# rds.force_ssl = 1 and track_io_timing = 1 are already the RDS system defaults. They are set here
# anyway so the group states them explicitly and a future engine default change cannot drop them
# silently. Every parameter below is dynamic except shared_preload_libraries (static), whose value
# is unchanged; attaching a new group to the instance still needs one reboot to reach "in-sync",
# which the instance class change takes anyway (see apply_immediately).
# pg_stat_statements still needs CREATE EXTENSION in a CIS migration (not in this repo).
# -----------------------------------------------------------------------------
resource "aws_db_parameter_group" "main" {
  name        = "${local.name_prefix}-pg15"
  family      = "postgres15"
  description = "AA-824 guardrails for ${local.name_prefix}-db (slow-query log, lock waits, idle-in-transaction timeout)"

  # Log statements slower than 500 ms (ms).
  parameter {
    name  = "log_min_duration_statement"
    value = "500"
  }

  # The slow-query log runs on asyncpg prepared statements, so PostgreSQL would also log the bind
  # values ("DETAIL: parameters: $1 = ...") at full length by default (-1). Those can be Booking
  # customer PII or sign-in codes, and this log is exported to CloudWatch. 0 = log the statement
  # text only, never the bind values.
  parameter {
    name  = "log_parameter_max_length"
    value = "0"
  }

  parameter {
    name  = "log_lock_waits"
    value = "1"
  }

  # S241 D-08: one line per connection opened and closed (user, database, client host, session
  # length), so a DB session can be traced to a client. Both are dynamic and engine-default (not
  # system) on postgres15, so "immediate" applies them to new connections with no reboot and no
  # permanent plan diff (unlike the AA-832 parameters below). Lands in the exported postgresql log.
  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  # Kill sessions idle inside an open transaction for 60 s (ms). Default is 86400000 (24 h).
  parameter {
    name  = "idle_in_transaction_session_timeout"
    value = "60000"
  }

  # AA-832: track_io_timing and rds.force_ssl equal the engine defaults, so RDS stores them as
  # Source = system and always reads them back with apply_method "pending-reboot", whatever was sent.
  # With the provider default ("immediate") every plan showed a permanent in-place diff on this group.
  # Declaring what RDS returns makes the plan clean; both are dynamic and their values do not change,
  # so nothing waits for a reboot (instance ParameterApplyStatus stayed in-sync, checked 16/10/2026).
  parameter {
    name         = "track_io_timing"
    value        = "1"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_stat_statements"
    apply_method = "pending-reboot"
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-pg15"
  })
}

# RDS creates /aws/rds/instance/<id>/postgresql on the first export with no expiry; creating it
# first lets Terraform own the 14-day retention.
resource "aws_cloudwatch_log_group" "postgresql" {
  name              = "/aws/rds/instance/${local.name_prefix}-db/postgresql"
  retention_in_days = var.log_retention_days

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-db-postgresql"
  })
}

resource "aws_db_instance" "main" {
  identifier        = "${local.name_prefix}-db"
  engine            = "postgres"
  engine_version    = "15.17"
  instance_class    = var.instance_class
  allocated_storage = var.allocated_storage
  # AA-824: storage autoscaling up to 100 GB (free until used). The provider ignores the
  # allocated_storage drift once RDS grows the volume.
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = var.db_subnet_group_name
  vpc_security_group_ids = [var.sg_rds_id]
  parameter_group_name   = aws_db_parameter_group.main.name

  # AA-824: false = the class change and the parameter group attach wait for the maintenance
  # window (mon 04:00-05:00 UTC). The orchestrator may apply with -var to take the reboot now, in a
  # window where shared.job and booking.job are idle.
  apply_immediately = var.apply_immediately

  # Dev settings
  multi_az            = false
  publicly_accessible = false
  # AA-824: keep a final snapshot if the instance is ever deleted (deletion_protection is on too).
  skip_final_snapshot       = false
  final_snapshot_identifier = "${local.name_prefix}-db-final"
  copy_tags_to_snapshot     = true
  # S235 Phase 0 (AA-678): shared CIS + TripPlanner + Booking database. In-place modify
  # (ModifyDBInstance, no reboot, no replacement). A deliberate delete now needs this set back to
  # false in a reviewed PR first.
  deletion_protection = true

  # Backup
  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "mon:04:00-mon:05:00"

  # Monitoring. AA-824: Performance Insights at the free tier (7 days). db.t3.micro also supports
  # it for PG 15.17 (describe-orderable-db-instance-options), but it ships with the t4g.small resize
  # (decision E5) so there is one reboot.
  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  enabled_cloudwatch_logs_exports       = ["postgresql"]

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-db"
  })

  # AA-267: RDS password rotated outside Terraform in the past (proven via
  # direct connect + Secrets Manager cross-check, S93 07/07/2026). TF_VAR
  # value is correct; state itself is stale. Ignore drift instead of
  # re-applying a password value on every plan.
  lifecycle {
    ignore_changes = [password]
  }

  depends_on = [aws_cloudwatch_log_group.postgresql]
}
