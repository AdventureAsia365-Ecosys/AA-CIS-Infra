# ============================================================
# EFS Module — AA-CIS
# ChromaDB + LangGraph SqliteSaver persistence
# ============================================================

locals {
  name_prefix = "${var.project}-${var.environment}"
}

resource "aws_security_group" "efs" {
  name        = "${local.name_prefix}-sg-efs"
  description = "EFS security group"
  vpc_id      = var.vpc_id

  # ADR 0004b (X1 S11): admitted groups from var.ingress_sg_ids (null = only var.sg_app_id). Inline
  # block = authoritative; adding a group is authorize-only (see modules/vpc aws_security_group.rds).
  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = var.ingress_sg_ids != null ? var.ingress_sg_ids : [var.sg_app_id]
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-sg-efs"
  })
}

resource "aws_efs_file_system" "main" {
  creation_token   = "${local.name_prefix}-efs"
  performance_mode = "generalPurpose"
  throughput_mode  = "bursting"
  encrypted        = true

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-efs"
  })
}

resource "aws_efs_mount_target" "main" {
  count           = length(var.private_subnet_ids)
  file_system_id  = aws_efs_file_system.main.id
  subnet_id       = var.private_subnet_ids[count.index]
  security_groups = [aws_security_group.efs.id]
}

resource "aws_efs_access_point" "chromadb" {
  file_system_id = aws_efs_file_system.main.id

  posix_user {
    gid = 1000
    uid = 1000
  }

  root_directory {
    path = "/chromadb"
    creation_info {
      owner_gid   = 1000
      owner_uid   = 1000
      permissions = "755"
    }
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-efs-chromadb"
  })
}

resource "aws_efs_access_point" "langgraph" {
  file_system_id = aws_efs_file_system.main.id

  posix_user {
    gid = 1000
    uid = 1000
  }

  root_directory {
    path = "/langgraph"
    creation_info {
      owner_gid   = 1000
      owner_uid   = 1000
      permissions = "755"
    }
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-efs-langgraph"
  })
}
