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

output "content_lambda_arn" {
  description = "ARN of Content Generation Lambda"
  value       = aws_lambda_function.content.arn
}

output "content_lambda_name" {
  description = "Name of Content Generation Lambda"
  value       = aws_lambda_function.content.function_name
}

output "authorizer_lambda_arn" {
  description = "ARN of the API Gateway tenant key authorizer Lambda"
  value       = aws_lambda_function.authorizer.arn
}

output "authorizer_lambda_invoke_arn" {
  description = "Invoke ARN of the API Gateway tenant key authorizer Lambda"
  value       = aws_lambda_function.authorizer.invoke_arn
}

output "authorizer_lambda_name" {
  description = "Function name of the API Gateway tenant key authorizer Lambda"
  value       = aws_lambda_function.authorizer.function_name
}

output "brand_brief_parser_lambda_arn" {
  description = "ARN of the brand brief parser Lambda"
  value       = aws_lambda_function.brand_brief_parser.arn
}

output "brand_brief_parser_lambda_name" {
  description = "Name of the brand brief parser Lambda"
  value       = aws_lambda_function.brand_brief_parser.function_name
}

output "acp_s3_campaign_planner_lambda_arn" {
  description = "ARN of the ACP S3 Campaign Planner Lambda"
  value       = aws_lambda_function.acp_s3_campaign_planner.arn
}

output "acp_s3_campaign_planner_lambda_name" {
  description = "Name of the ACP S3 Campaign Planner Lambda"
  value       = aws_lambda_function.acp_s3_campaign_planner.function_name
}

output "acp_s4_evaluate_lambda_arn" {
  description = "ARN of the ACP S4 Evaluate Lambda (AA-49 H-1)"
  value       = aws_lambda_function.acp_s4_evaluate.arn
}

output "acp_s4_evaluate_lambda_name" {
  description = "Name of the ACP S4 Evaluate Lambda (AA-49 H-1)"
  value       = aws_lambda_function.acp_s4_evaluate.function_name
}
