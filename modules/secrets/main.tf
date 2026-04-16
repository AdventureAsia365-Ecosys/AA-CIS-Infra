# ============================================================
# Secrets Module — AA-CIS
# Reference existing secrets, không tạo mới
# (secrets đã tạo manually via CLI)
# ============================================================

locals {
  name_prefix = "${var.project}-${var.environment}"
}

data "aws_secretsmanager_secret" "openai" {
  name = "${local.name_prefix}/openai"
}

data "aws_secretsmanager_secret" "anthropic" {
  name = "${local.name_prefix}/anthropic"
}

data "aws_secretsmanager_secret" "dataforseo" {
  name = "${local.name_prefix}/dataforseo"
}

data "aws_secretsmanager_secret" "langfuse" {
  name = "${local.name_prefix}/langfuse"
}

data "aws_secretsmanager_secret" "rds" {
  name = "${local.name_prefix}/rds"
}

data "aws_secretsmanager_secret" "bedrock" {
  name = "${local.name_prefix}/bedrock"
}
