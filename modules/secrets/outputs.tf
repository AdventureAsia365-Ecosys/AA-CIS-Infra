output "dataforseo_secret_arn" {
  value = data.aws_secretsmanager_secret.dataforseo.arn
}

# AA-23: removed
# output "langfuse_secret_arn" {
#   value = data.aws_secretsmanager_secret.langfuse.arn
# }

# AA-1182: rds_secret_arn removed with its data source (the old master DSN secret is not looked up any more).

# AA-878: acp_webhook_secret_arn / acp_partner_api_secret_arn removed with their secrets (forgotten).
