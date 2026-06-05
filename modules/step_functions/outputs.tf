output "state_machine_arn" {
  description = "ARN of the pipeline state machine"
  value       = aws_sfn_state_machine.pipeline.arn
}

output "state_machine_name" {
  description = "Name of the pipeline state machine"
  value       = aws_sfn_state_machine.pipeline.name
}

output "sfn_exec_role_arn" {
  description = "ARN of Step Functions execution role"
  value       = aws_iam_role.sfn_exec.arn
}
