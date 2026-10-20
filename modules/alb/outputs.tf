output "alb_dns_name" {
  value = aws_lb.main.dns_name
}

output "alb_arn" {
  value = aws_lb.main.arn
}

output "alb_arn_suffix" {
  description = "ALB ARN suffix (app/<name>/<id>) for AWS/ApplicationELB alarm dimensions (S235)"
  value       = aws_lb.main.arn_suffix
}

output "alb_subnet_ids" {
  description = "Subnets the ALB is deployed in (AA-272 diagnostic flow logs)"
  value       = aws_lb.main.subnets
}

output "target_group_arn" {
  value = aws_lb_target_group.api.arn
}

output "https_listener_arn" {
  value = aws_lb_listener.https.arn
}

output "http_listener_arn" {
  description = "Port-80 listener ARN. API Gateway reaches the ALB on HTTP through the VPC-link NLB, so path rules for other services (AA-678 /booking/*) attach here, not to the HTTPS listener."
  value       = aws_lb_listener.http.arn
}

output "nlb_dns_name" {
  description = "DNS name of the internal NLB fronting the ALB (VPC Link target, AA-272)"
  value       = aws_lb.vpc_link_nlb.dns_name
}

output "vpc_link_id" {
  description = "ID of the API Gateway VPC Link (V1) wrapping the NLB (AA-272)"
  value       = aws_api_gateway_vpc_link.this.id
}

output "nlb_security_group_id" {
  description = "Security group of the VPC-link NLB (AA-893 inventory outputs)"
  value       = aws_security_group.nlb.id
}
