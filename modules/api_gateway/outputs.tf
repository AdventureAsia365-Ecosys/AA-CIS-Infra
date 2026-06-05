output "api_gateway_id" {
  description = "ID of the REST API"
  value       = aws_api_gateway_rest_api.this.id
}

output "api_gateway_url" {
  description = "Invoke URL of the deployed stage"
  value       = "https://${aws_api_gateway_rest_api.this.id}.execute-api.${var.aws_region}.amazonaws.com/${var.environment}"
}

output "custom_domain_target" {
  description = "Regional domain name to set as CNAME in Namecheap"
  value       = aws_api_gateway_domain_name.api_cis.regional_domain_name
}
