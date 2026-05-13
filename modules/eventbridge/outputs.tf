output "acp_event_bus_name" {
  description = "ACP custom EventBridge bus name"
  value       = aws_cloudwatch_event_bus.acp_events.name
}

output "acp_event_bus_arn" {
  description = "ACP custom EventBridge bus ARN"
  value       = aws_cloudwatch_event_bus.acp_events.arn
}

output "scheduler_role_arn" {
  description = "IAM role ARN for EventBridge Scheduler"
  value       = aws_iam_role.scheduler.arn
}

output "schedule_group_name" {
  description = "Scheduler schedule group name"
  value       = aws_scheduler_schedule_group.acp.name
}

output "schedule_group_arn" {
  description = "Scheduler schedule group ARN"
  value       = aws_scheduler_schedule_group.acp.arn
}
