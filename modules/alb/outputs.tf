output "alb_dns_name" {
  value = aws_lb.main.dns_name
}

output "alb_arn" {
  value = aws_lb.main.arn
}

output "target_group_arn" {
  value = aws_lb_target_group.api.arn
}

output "https_listener_arn" {
  value = aws_lb_listener.https.arn
}

output "nlb_dns_name" {
  description = "DNS name of the internal NLB fronting the ALB (VPC Link target, AA-272)"
  value       = aws_lb.vpc_link_nlb.dns_name
}

output "vpc_link_id" {
  description = "ID of the API Gateway VPC Link (V1) wrapping the NLB (AA-272)"
  value       = aws_api_gateway_vpc_link.this.id
}
