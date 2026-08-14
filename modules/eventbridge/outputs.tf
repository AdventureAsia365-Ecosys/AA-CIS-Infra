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

output "acp_dlq_arn" {
  description = "ACP events FIFO DLQ ARN"
  value       = aws_sqs_queue.acp_events_dlq.arn
}

output "acp_dlq_url" {
  description = "ACP events FIFO DLQ URL"
  value       = aws_sqs_queue.acp_events_dlq.id
}

output "acp_dlq_name" {
  description = "ACP events FIFO DLQ name"
  value       = aws_sqs_queue.acp_events_dlq.name
}
