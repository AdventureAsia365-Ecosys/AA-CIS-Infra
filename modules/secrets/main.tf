# ============================================================
# Secrets Module — AA-CIS
# Reference existing secrets tạo bằng CLI
# Naming: aa-cis/dev/<service>
# ============================================================
locals {
  secret_prefix = "${var.project}/${var.environment}"
}

data "aws_secretsmanager_secret" "dataforseo" {
  name = "${local.secret_prefix}/dataforseo"
}

# ── ACP Pipeline Secrets — AA-40 ─────────────────────────────

resource "aws_secretsmanager_secret" "acp_webhook_secret" {
  name                    = "${local.secret_prefix}/acp-webhook-secret"
  description             = "HMAC shared secret for ACP API Gateway webhook validation"
  recovery_window_in_days = var.environment == "dev" ? 0 : 30

  tags = {
    Environment = var.environment
    Feature     = "acp-pipeline"
  }
}

resource "aws_secretsmanager_secret_version" "acp_webhook_secret" {
  secret_id     = aws_secretsmanager_secret.acp_webhook_secret.id
  secret_string = "REPLACE_ME"

  lifecycle {
    ignore_changes = [secret_string]
  }
}

resource "aws_secretsmanager_secret" "acp_partner_api" {
  name                    = "${local.secret_prefix}/acp-partner-api"
  description             = "ACP partner system API credentials (JSON: {api_key, endpoint})"
  recovery_window_in_days = var.environment == "dev" ? 0 : 30

  tags = {
    Environment = var.environment
    Feature     = "acp-pipeline"
  }
}

resource "aws_secretsmanager_secret_version" "acp_partner_api" {
  secret_id     = aws_secretsmanager_secret.acp_partner_api.id
  secret_string = jsonencode({ api_key = "REPLACE_ME", endpoint = "REPLACE_ME" })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

data "aws_secretsmanager_secret" "langfuse" {
  name = "${local.secret_prefix}/langfuse"
}

data "aws_secretsmanager_secret" "rds" {
  name = "${local.secret_prefix}/rds"
}
