# ============================================================
# Secrets Module — AA-CIS
# Reference existing secrets tạo bằng CLI
# Naming: aa-cis/dev/<service>
# ============================================================

locals {
  secret_prefix = "${var.project}/${var.environment}"
}

data "aws_secretsmanager_secret" "openai" {
  name = "${local.secret_prefix}/openai"
}

data "aws_secretsmanager_secret" "anthropic" {
  name = "${local.secret_prefix}/anthropic"
}

data "aws_secretsmanager_secret" "dataforseo" {
  name = "${local.secret_prefix}/dataforseo"
}

data "aws_secretsmanager_secret" "langfuse" {
  name = "${local.secret_prefix}/langfuse"
}

data "aws_secretsmanager_secret" "rds" {
  name = "${local.secret_prefix}/rds"
}

data "aws_secretsmanager_secret" "bedrock" {
  name = "${local.secret_prefix}/bedrock"
}
