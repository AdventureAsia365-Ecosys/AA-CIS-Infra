# ============================================================
# RDS Module — AA-CIS PostgreSQL 15
# ============================================================

locals {
  name_prefix = "${var.project}-${var.environment}"
}

resource "aws_db_instance" "main" {
  identifier        = "${local.name_prefix}-db"
  engine            = "postgres"
  engine_version = "15.17"
  instance_class    = var.instance_class
  allocated_storage = var.allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = var.db_subnet_group_name
  vpc_security_group_ids = [var.sg_rds_id]

  # Dev settings
  multi_az            = false
  publicly_accessible = false
  skip_final_snapshot = true
  deletion_protection = false

  # Backup
  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "mon:04:00-mon:05:00"

  # Monitoring
  performance_insights_enabled = false

  tags = {
    Name = "${local.name_prefix}-db"
  }
}
