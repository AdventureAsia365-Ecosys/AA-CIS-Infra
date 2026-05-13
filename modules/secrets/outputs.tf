output "dataforseo_secret_arn" {
  value = data.aws_secretsmanager_secret.dataforseo.arn
}

output "langfuse_secret_arn" {
  value = data.aws_secretsmanager_secret.langfuse.arn
}

output "rds_secret_arn" {
  value = data.aws_secretsmanager_secret.rds.arn
}

output "acp_webhook_secret_arn" {
  description = "ARN of ACP webhook validation secret"
  value       = aws_secretsmanager_secret.acp_webhook_secret.arn
}

output "acp_partner_api_secret_arn" {
  description = "ARN of ACP partner API credentials secret"
  value       = aws_secretsmanager_secret.acp_partner_api.arn
}
