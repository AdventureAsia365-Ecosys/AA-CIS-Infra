output "dataforseo_secret_arn" {
  value = data.aws_secretsmanager_secret.dataforseo.arn
}

output "langfuse_secret_arn" {
  value = data.aws_secretsmanager_secret.langfuse.arn
}

output "rds_secret_arn" {
  value = data.aws_secretsmanager_secret.rds.arn
}
