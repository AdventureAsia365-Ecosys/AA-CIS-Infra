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

# S241 D-07: the Booking task role (accounts/aa365/booking.tf) grants its ECS Exec log writes here.
output "exec_session_log_group_arn" {
  value = aws_cloudwatch_log_group.exec_sessions.arn
}

# X1 S11: the DB migrator task definition (accounts/aa365/db_migrator.tf) pulls the CIS image and
# writes its container log into the CIS log group under stream prefix "migrate".
output "ecr_repository_arn" {
  value = aws_ecr_repository.api.arn
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.ecs.name
}

output "log_group_arn" {
  value = aws_cloudwatch_log_group.ecs.arn
}

# AA-893: the root inventory outputs (accounts/aa365/outputs_inventory.tf) list every ECS service.
output "worker_service_name" {
  value = aws_ecs_service.worker.name
}
