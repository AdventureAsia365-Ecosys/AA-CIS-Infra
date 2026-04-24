# Phase 4 outputs — append to existing outputs.tf

output "state_machine_arn" {
  description = "Step Functions pipeline state machine ARN"
  value       = module.step_functions.state_machine_arn
}

output "ingestion_lambda_arn" {
  description = "Ingestion Lambda ARN"
  value       = module.lambda.ingestion_lambda_arn
}

output "seo_lambda_arn" {
  description = "SEO Intelligence Lambda ARN"
  value       = module.lambda.seo_lambda_arn
}

output "validation_lambda_arn" {
  description = "Validation Lambda ARN"
  value       = module.lambda.validation_lambda_arn
}

output "export_lambda_arn" {
  description = "Export Lambda ARN"
  value       = module.lambda.export_lambda_arn
}
