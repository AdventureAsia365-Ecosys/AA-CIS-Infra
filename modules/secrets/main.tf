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

# ── ACP Pipeline Secrets — AA-40: forgotten, not deleted (AA-878, S243) ──
# aa-cis/dev/acp-webhook-secret and aa-cis/dev/acp-partner-api were placeholders for the retired
# ACP v1 webhook/partner path: no code on main of any repo reads them, and CloudTrail since 18/10
# shows only the plan role (refresh) reading them. Terraform forgets the secrets and their versions
# here instead of deleting them: recovery_window_in_days was 0 in dev, so removing the resource
# blocks alone would have deleted them at once with no recovery. They are deleted by hand with a
# 30-day recovery window after a DRY RUN (AA-878 step M2). The removed blocks live in this module
# because it declared the resources.
removed {
  from = aws_secretsmanager_secret.acp_webhook_secret

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_secretsmanager_secret_version.acp_webhook_secret

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_secretsmanager_secret.acp_partner_api

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_secretsmanager_secret_version.acp_partner_api

  lifecycle {
    destroy = false
  }
}

# AA-23: removed
# data "aws_secretsmanager_secret" "langfuse" {
#   name = "${local.secret_prefix}/langfuse"
# }

data "aws_secretsmanager_secret" "rds" {
  name = "${local.secret_prefix}/rds"
}
