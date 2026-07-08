# Existing outputs (already in outputs.tf)
output "cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "cluster_arn" {
  value = aws_ecs_cluster.main.arn
}

output "execution_role_arn" {
  value = aws_iam_role.ecs_execution.arn
}

output "task_role_arn" {
  value = aws_iam_role.ecs_task.arn
}

output "task_role_name" {
  value = aws_iam_role.ecs_task.name
}

# New outputs
output "ecr_repository_url" {
  value = aws_ecr_repository.api.repository_url
}

output "service_name" {
  value = aws_ecs_service.api.name
}

output "task_definition_arn" {
  value = aws_ecs_task_definition.api.arn
}
