# =============================================================================
# AA-1004 slice 3 (S267) — what the account root reads back from the TripPlanner stack (besides the per-file outputs
# in tripplanner.tf / tripplanner_jobs.tf, which the root re-exports under the same names). Each one replaces a direct
# reference the root had before the move; names and ids only, no secrets.
# =============================================================================

# TripPlanner naming, shared with the root files that still build TripPlanner-named objects (app_security_groups.tf
# tp_lambda, ses.tf tripplanner_lambda_ses_send). One definition, in tripplanner.tf.
output "tripplanner_name_prefix" {
  value = local.tp_name_prefix
}

output "tripplanner_tags" {
  value = local.tp_tags
}

output "tripplanner_db_secret_arn" {
  description = "Secret tripplanner/<env>/database-url (cicd_split.tf plan refresh list, db_migrator.tf probe logins)."
  value       = aws_secretsmanager_secret.tripplanner_db.arn
}

output "tripplanner_lambda_exec_role_id" {
  description = "Execution role of browse + assembly: the root attaches the SES send grant to it (ses.tf)."
  value       = aws_iam_role.tripplanner_lambda_exec.id
}

output "tripplanner_browse_function_name" {
  description = "Browse Lambda (observability_ecosys.tf log group and alarms)."
  value       = aws_lambda_function.tripplanner_browse.function_name
}

output "tripplanner_assembly_function_name" {
  description = "Assembly Lambda (observability_ecosys.tf log group and alarms)."
  value       = aws_lambda_function.tripplanner_assembly.function_name
}

output "tripplanner_http_api_id" {
  description = "TripPlanner HTTP API (custom_domains.tf API mapping, outputs_inventory.tf)."
  value       = aws_apigatewayv2_api.tripplanner.id
}

output "tripplanner_stage_id" {
  description = "The $default stage of the HTTP API (custom_domains.tf API mapping)."
  value       = aws_apigatewayv2_stage.tripplanner.id
}
