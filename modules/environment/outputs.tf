# =============================================================================
# AA-1004 P0 — outputs the account root reads from modules/environment (besides the per-file outputs in booking*.tf,
# which the root re-exports under the same names). Each one replaces a direct reference the root had before slice 1;
# names only, no secrets.
# =============================================================================

# Booking naming, shared with the root files that still build Booking-named objects (app_security_groups.tf SG,
# ses.tf / observability_ecosys.tf task-role grants, the no-healthy-task alarm). One definition, here.
output "booking_name_prefix" {
  value = local.bk_name_prefix
}

output "booking_port" {
  value = local.bk_port
}

output "booking_tags" {
  value = local.bk_tags
}

output "booking_target_group_arn" {
  description = "Target group of the Booking API (the root's listener rule forwards to it)."
  value       = aws_lb_target_group.booking.arn
}

output "booking_target_group_name" {
  value = aws_lb_target_group.booking.name
}

output "booking_target_group_arn_suffix" {
  value = aws_lb_target_group.booking.arn_suffix
}

output "booking_ecs_task_role_id" {
  description = "Booking task role name/id: the root attaches the SES send and alert publish grants to it."
  value       = aws_iam_role.booking_ecs_task.id
}

output "booking_rest_api_id" {
  value = aws_api_gateway_rest_api.booking.id
}

output "booking_stage_name" {
  value = aws_api_gateway_stage.booking.stage_name
}

output "booking_stage_arn" {
  description = "Booking REST API stage (the root's WAF association when var.waf_protect_rest_api_stages)."
  value       = aws_api_gateway_stage.booking.arn
}
