output "ingestion_lambda_arn" {
  description = "ARN of Ingestion Lambda"
  value       = aws_lambda_function.ingestion.arn
}

output "ingestion_lambda_name" {
  description = "Name of Ingestion Lambda"
  value       = aws_lambda_function.ingestion.function_name
}

output "seo_lambda_arn" {
  description = "ARN of SEO Intelligence Lambda"
  value       = aws_lambda_function.seo.arn
}

output "seo_lambda_name" {
  description = "Name of SEO Intelligence Lambda"
  value       = aws_lambda_function.seo.function_name
}

output "validation_lambda_arn" {
  description = "ARN of Validation Lambda"
  value       = aws_lambda_function.validation.arn
}

output "validation_lambda_name" {
  description = "Name of Validation Lambda"
  value       = aws_lambda_function.validation.function_name
}

output "export_lambda_arn" {
  description = "ARN of Export Lambda"
  value       = aws_lambda_function.export.arn
}

output "export_lambda_name" {
  description = "Name of Export Lambda"
  value       = aws_lambda_function.export.function_name
}

output "lambda_exec_role_arn" {
  description = "ARN of shared Lambda execution role"
  value       = aws_iam_role.lambda_exec.arn
}
