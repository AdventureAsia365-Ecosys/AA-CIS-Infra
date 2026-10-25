# AA-874: the encrypted replication group.
output "tls_primary_endpoint" {
  description = "Primary endpoint of the TLS + AUTH replication group (clients: rediss://, REDIS_TLS=true)."
  value       = aws_elasticache_replication_group.main.primary_endpoint_address
}

output "tls_port" {
  value = aws_elasticache_replication_group.main.port
}

output "member_cluster_id" {
  description = "Cache cluster id of the group's single node (REDIS_CLUSTER_ID: GET /admin/infra/status describes it)."
  value       = "${aws_elasticache_replication_group.main.id}-001"
}

output "auth_secret_arn" {
  description = "Secrets Manager secret holding the AUTH token (ECS secrets entry REDIS_AUTH_TOKEN)."
  value       = aws_secretsmanager_secret.redis_auth.arn
}
