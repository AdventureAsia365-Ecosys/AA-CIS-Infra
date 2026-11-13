# =============================================================================
# AA-1004 P0 — inputs of modules/environment.
#
# Two kinds:
#   - environment inputs: the account and environment this instance builds (environment, aws_region, account_id) and
#     the per-app settings (booking_variables.tf, the same variables the root declares, passed through).
#   - platform inputs: the shared objects the slice-1 stacks run on that are still declared in the account root
#     (VPC, ECS cluster, ALB / VPC link, bronze bucket, SES, M2M pool, alerts topic) or are account bootstrap
#     (permission boundary, GitHub OIDC provider). Each later slice that moves the owner of one of these into this
#     module turns the input back into a direct reference.
# Values only, never secrets: nothing here is sensitive.
# =============================================================================

variable "environment" {
  description = "Environment name (dev / staging / prod). Names every resource (aa-booking-<env>-*) and the GitHub OIDC context of the deploy role (environment:<env>)."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Must be dev, staging, or prod."
  }
}

variable "aws_region" {
  description = "Region of the default provider (ARNs built from it)."
  type        = string
}

variable "account_id" {
  description = "AWS account id of this environment (ARNs, the aws:SourceAccount condition, bucket names)."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account id."
  }
}

# ---- Account bootstrap (applied by a human in each account root, never inside this module) ----

variable "permissions_boundary_arn" {
  description = "Workload permission boundary set on every IAM role of the module (accounts/aa365 cicd_split.tf aws_iam_policy.workload_boundary)."
  type        = string
}

variable "github_oidc_provider_arn" {
  description = "GitHub Actions OIDC provider of the account (accounts/aa365 cicd.tf), trusted by the app deploy roles."
  type        = string
}

variable "iam_propagation_gate" {
  description = "Id of the root's IAM propagation sleep (time_sleep.wait_for_iam_propagation). Resources whose create needs a fresh CI-role grant depend on it, as they did in the root."
  type        = string
}

# ---- Shared platform still declared in the account root ----

variable "vpc_id" {
  description = "VPC of the environment (module.vpc.vpc_id)."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets the ECS tasks run in (module.vpc.private_subnet_ids)."
  type        = list(string)
}

variable "ecs_cluster_arn" {
  description = "Shared ECS cluster ARN (module.ecs.cluster_arn)."
  type        = string
}

variable "ecs_cluster_name" {
  description = "Shared ECS cluster name (module.ecs.cluster_name)."
  type        = string
}

variable "ecs_exec_session_log_group_arn" {
  description = "Log group of the cluster's ECS Exec session logs (module.ecs.exec_session_log_group_arn)."
  type        = string
}

variable "cis_task_role_arn" {
  description = "CIS api/worker task role (module.ecs.task_role_arn): read-only reader of the Booking supply-media bucket, denied every write there."
  type        = string
}

variable "vpc_link_id" {
  description = "API Gateway VPC link to the internal NLB (module.alb.vpc_link_id)."
  type        = string
}

variable "nlb_dns_name" {
  description = "DNS name of the internal NLB behind the VPC link (module.alb.nlb_dns_name)."
  type        = string
}

variable "booking_listener_rule_gate" {
  description = "ARN of the root's aws_lb_listener_rule.booking (alb_rules.tf). The Booking ECS service waits for it: ECS refuses a service whose target group is on no load balancer yet."
  type        = string
}

variable "booking_security_group_id" {
  description = "Security group of the Booking tasks (accounts/aa365 app_security_groups.tf aws_security_group.booking_api, ADR 0004b)."
  type        = string
}

variable "bronze_bucket_arn" {
  description = "CIS bronze bucket (module.s3.bronze_bucket_arn); the Booking task role may put archive/booking/* only."
  type        = string
}

variable "gold_bucket_arn" {
  description = "CIS gold bucket (module.s3.gold_bucket_arn); the TripPlanner jobs role may put / get exports/tenants/*/tripplanner/* only (AA-1093)."
  type        = string
}

variable "gold_bucket_name" {
  description = "CIS gold bucket name (module.s3.gold_bucket_name): TENANT_EXPORT_BUCKET of the TripPlanner jobs Lambda (AA-1093)."
  type        = string
}

variable "ses_from_address" {
  description = "The only From address the app task roles may send as (ses.tf)."
  type        = string
}

variable "ses_configuration_set_name" {
  description = "SES transactional configuration set (ses.tf aws_sesv2_configuration_set.stream[\"transactional\"])."
  type        = string
}

variable "m2m_pool_endpoint" {
  description = "Endpoint of the M2M Cognito pool (identity_m2m.tf aws_cognito_user_pool.m2m.endpoint); COGNITO_M2M_ISSUER = https://<this>."
  type        = string
}

variable "m2m_crm_client_id" {
  description = "Client id of the AA-Partner (CRM) M2M client (identity_m2m.tf aws_cognito_user_pool_client.m2m_crm.id). Public value."
  type        = string
}

variable "alerts_topic_arn" {
  description = "Account alerts SNS topic (observability.tf aws_sns_topic.alerts); the in-app checks publish to it."
  type        = string
}
