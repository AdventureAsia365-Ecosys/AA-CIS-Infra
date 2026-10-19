output "dataforseo_secret_arn" {
  value = data.aws_secretsmanager_secret.dataforseo.arn
}

# AA-23: removed
# output "langfuse_secret_arn" {
#   value = data.aws_secretsmanager_secret.langfuse.arn
# }

output "rds_secret_arn" {
  value = data.aws_secretsmanager_secret.rds.arn
}

# AA-878: acp_webhook_secret_arn / acp_partner_api_secret_arn removed with their secrets (forgotten).
