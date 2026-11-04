# =============================================================================
# AA-1004 slice 3 (S267) — the inputs the AA-TripPlanner stack reads from the account root.
#
# The TripPlanner stack (tripplanner.tf, tripplanner_jobs.tf) moved here from accounts/aa365 with one `moved` block
# per resource (accounts/aa365/environment.tf). Its per-app settings stay declared next to the code that reads them,
# as before the move (tripplanner_variables.tf, a copy of the root file, and the two jobs settings in
# tripplanner_jobs.tf); the root declares the same variables and passes them through.
#
# The variables below are the objects the TripPlanner stack runs on that are still declared in the account root. The
# slice-1 / slice-2 inputs it also reads (permissions_boundary_arn, github_oidc_provider_arn, iam_propagation_gate,
# private_subnet_ids, alerts_topic_arn, runbook_suffix) are reused. Each later slice that moves the owner of one of
# them into this module turns the input back into a direct reference. Values only, never secrets.
# =============================================================================

variable "tripplanner_lambda_security_group_id" {
  description = "Security group of the TripPlanner Lambdas, no ingress (accounts/aa365 app_security_groups.tf aws_security_group.tp_lambda, ADR 0004b)."
  type        = string
}

variable "bedrock_acct_primary" {
  description = "Account of the Bedrock satellite invoker role the assembly Lambda assumes (bedrock_satellite_assume.tf local.bedrock_acct_primary). Builds the caller-side AssumeRole grant and BEDROCK_ACCT_PRIMARY."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.bedrock_acct_primary))
    error_message = "bedrock_acct_primary must be a 12-digit AWS account id."
  }
}

variable "eventbridge_schedule_group_name" {
  description = "EventBridge Scheduler group the CI role may manage (module.eventbridge.schedule_group_name); holds the jobs Lambda's daily schedule."
  type        = string
}

variable "tripplanner_placeholder_zip" {
  description = "Local path of the placeholder Lambda zip that seeds browse.zip / assembly.zip / jobs.zip on first create (the account root passes its own artifacts/placeholder.zip). The objects ignore later changes of source and etag."
  type        = string
}
