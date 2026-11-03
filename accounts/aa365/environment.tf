# =============================================================================
# AA-1004 P0 (prod plan P0, root docs/audits/2026-11-03-S265-ecosystem-restructure/clarifications.md section 5):
# the Dev instance of modules/environment, the environment-scoped stack a future accounts/aa-prod root instantiates
# with its own inputs.
#
# Filled slice by slice. Every slice moves a coherent set of resources with `moved` blocks, so Terraform Plan on this
# root stays a pure no-op: "0 to add, 0 to change, 0 to destroy", only "has moved to" notices. Keep the moved blocks
# after the apply that records them (they cost nothing; removing them later is its own no-op PR once every state that
# used the old addresses has been applied).
#
# Slice 1 (S266): the AA-Booking service stack, i.e. the former booking.tf (ECR, logs, the two secret shells, the
# execution / task / deploy roles and their policies, task definition, target group, ECS service, REST API, stage,
# throttle), booking_media.tf and booking_ops_docs.tf: 41 resources, one moved block each below.
# Kept in this root on purpose (they move with their own files in later slices):
#   - aws_lb_listener_rule.booking (alb_rules.tf): it sits on the shared ALB listener whose order alb_rules.tf owns and
#     alb_rule_order.py checks in source mode; it moves when the ALB and its rules move.
#   - the two Booking task-role grants that live with their topic: ses.tf booking_ecs_task_ses_send and
#     observability_ecosys.tf booking_ecs_task_publish_alerts; the alarm booking_no_healthy_task.
#   - aws_security_group.booking_api (app_security_groups.tf, ADR 0004b: one SG file for every DB caller).
#   - data.aws_iam_policy_document.booking_ecs_tasks_assume below: the CRM roles (crm_app.tf, crm_web.tf,
#     crm_portal.tf) assume through it too; the module has its own copy (same JSON).
# Left for P1+ (one slice each, same pattern): the CRM stack (crm_*.tf), TripPlanner (tripplanner*.tf), identity
# (identity*.tf, ses.tf, dns), observability + security, then the platform module calls of main.tf (vpc, rds, alb,
# ecs, api_gateway, waf, ...) as module.environment.module.<name>. Account bootstrap (cicd*.tf, agent_session.tf, the
# boundaries, the OIDC provider, security_baseline.tf) stays in each account root.
# =============================================================================

module "environment" {
  source = "../../modules/environment"

  environment = var.environment
  aws_region  = var.aws_region
  account_id  = var.account_id

  # Account bootstrap of this root (cicd.tf, cicd_split.tf, observability.tf).
  permissions_boundary_arn = aws_iam_policy.workload_boundary.arn
  github_oidc_provider_arn = aws_iam_openid_connect_provider.github_actions.arn
  iam_propagation_gate     = time_sleep.wait_for_iam_propagation.id

  # Shared platform still declared here.
  vpc_id                         = module.vpc.vpc_id
  private_subnet_ids             = module.vpc.private_subnet_ids
  ecs_cluster_arn                = module.ecs.cluster_arn
  ecs_cluster_name               = module.ecs.cluster_name
  ecs_exec_session_log_group_arn = module.ecs.exec_session_log_group_arn
  cis_task_role_arn              = module.ecs.task_role_arn
  vpc_link_id                    = module.alb.vpc_link_id
  nlb_dns_name                   = module.alb.nlb_dns_name
  bronze_bucket_arn              = module.s3.bronze_bucket_arn
  booking_listener_rule_gate     = aws_lb_listener_rule.booking.arn
  booking_security_group_id      = aws_security_group.booking_api.id
  ses_from_address               = var.ses_from_address
  ses_configuration_set_name     = aws_sesv2_configuration_set.stream["transactional"].configuration_set_name
  m2m_pool_endpoint              = aws_cognito_user_pool.m2m.endpoint
  m2m_crm_client_id              = aws_cognito_user_pool_client.m2m_crm.id
  alerts_topic_arn               = aws_sns_topic.alerts.arn

  # Booking settings (booking_variables.tf of this root, passed through unchanged).
  booking_github_repo_id     = var.booking_github_repo_id
  booking_staff_notify_email = var.booking_staff_notify_email
  booking_staff_admin_url    = var.booking_staff_admin_url
  booking_sentry_enabled     = var.booking_sentry_enabled
}

locals {
  # Booking naming for the root files that still build Booking-named objects (see the header). One definition, in
  # the module.
  bk_name_prefix = module.environment.booking_name_prefix
  bk_port        = module.environment.booking_port
  bk_tags        = module.environment.booking_tags
}

# ecs-tasks.amazonaws.com may assume, this account only. Used by the CRM task roles; the Booking roles use the
# module's own copy (identical document).
data "aws_iam_policy_document" "booking_ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }
}

# -----------------------------------------------------------------------------
# Outputs that were declared in booking.tf / booking_media.tf / booking_ops_docs.tf, same names and values (the
# AA-Booking `dev` environment values and the runbooks read them by name).
# -----------------------------------------------------------------------------
output "booking_app_deploy_role_arn" {
  value = module.environment.booking_app_deploy_role_arn
}

output "booking_ecr_repository_url" {
  value = module.environment.booking_ecr_repository_url
}

output "booking_ecs_service_name" {
  value = module.environment.booking_ecs_service_name
}

output "booking_task_definition_family" {
  value = module.environment.booking_task_definition_family
}

output "booking_api_base_url" {
  description = "Dev base URL; health = <this>/booking/health and <this>/booking/health/ready."
  value       = module.environment.booking_api_base_url
}

output "booking_database_url_secret_arn" {
  value = module.environment.booking_database_url_secret_arn
}

output "booking_supply_media_bucket" {
  description = "AA-835: the Booking supply-media bucket (Booking env SUPPLY_MEDIA_BUCKET; booking.v_supply_media names it)."
  value       = module.environment.booking_supply_media_bucket
}

output "booking_ops_docs_bucket" {
  description = "AA-682: the Booking ops-docs bucket (Booking env OPS_DOCS_BUCKET; booking.ops_files.s3_bucket names it)."
  value       = module.environment.booking_ops_docs_bucket
}

# -----------------------------------------------------------------------------
# Slice 1 moves: root address -> module.environment address, one per resource (tools/terraform/tests/
# test_aa1004_environment_moves.py checks that the list matches the module and that no root resource shadows one).
# -----------------------------------------------------------------------------
# booking.tf
moved {
  from = aws_ecr_repository.booking
  to   = module.environment.aws_ecr_repository.booking
}

moved {
  from = aws_ecr_lifecycle_policy.booking
  to   = module.environment.aws_ecr_lifecycle_policy.booking
}

moved {
  from = aws_cloudwatch_log_group.booking
  to   = module.environment.aws_cloudwatch_log_group.booking
}

moved {
  from = aws_secretsmanager_secret.booking_db
  to   = module.environment.aws_secretsmanager_secret.booking_db
}

moved {
  from = aws_secretsmanager_secret.booking_sentry_dsn
  to   = module.environment.aws_secretsmanager_secret.booking_sentry_dsn
}

moved {
  from = aws_iam_role.booking_ecs_execution
  to   = module.environment.aws_iam_role.booking_ecs_execution
}

moved {
  from = aws_iam_role_policy.booking_ecs_execution
  to   = module.environment.aws_iam_role_policy.booking_ecs_execution
}

moved {
  from = aws_iam_role.booking_ecs_task
  to   = module.environment.aws_iam_role.booking_ecs_task
}

moved {
  from = aws_iam_role_policy.booking_ecs_task
  to   = module.environment.aws_iam_role_policy.booking_ecs_task
}

moved {
  from = aws_iam_role_policy.booking_ecs_task_retention_archive
  to   = module.environment.aws_iam_role_policy.booking_ecs_task_retention_archive
}

moved {
  from = aws_ecs_task_definition.booking
  to   = module.environment.aws_ecs_task_definition.booking
}

moved {
  from = aws_lb_target_group.booking
  to   = module.environment.aws_lb_target_group.booking
}

moved {
  from = aws_ecs_service.booking
  to   = module.environment.aws_ecs_service.booking
}

moved {
  from = aws_api_gateway_rest_api.booking
  to   = module.environment.aws_api_gateway_rest_api.booking
}

moved {
  from = aws_api_gateway_resource.booking
  to   = module.environment.aws_api_gateway_resource.booking
}

moved {
  from = aws_api_gateway_resource.booking_proxy
  to   = module.environment.aws_api_gateway_resource.booking_proxy
}

moved {
  from = aws_api_gateway_method.booking_any
  to   = module.environment.aws_api_gateway_method.booking_any
}

moved {
  from = aws_api_gateway_integration.booking_any
  to   = module.environment.aws_api_gateway_integration.booking_any
}

moved {
  from = aws_api_gateway_method.booking_proxy_any
  to   = module.environment.aws_api_gateway_method.booking_proxy_any
}

moved {
  from = aws_api_gateway_integration.booking_proxy_any
  to   = module.environment.aws_api_gateway_integration.booking_proxy_any
}

moved {
  from = aws_api_gateway_deployment.booking
  to   = module.environment.aws_api_gateway_deployment.booking
}

moved {
  from = aws_api_gateway_stage.booking
  to   = module.environment.aws_api_gateway_stage.booking
}

moved {
  from = aws_api_gateway_method_settings.booking_throttle
  to   = module.environment.aws_api_gateway_method_settings.booking_throttle
}

moved {
  from = aws_iam_role.booking_app_deploy
  to   = module.environment.aws_iam_role.booking_app_deploy
}

moved {
  from = aws_iam_role_policy.booking_app_deploy
  to   = module.environment.aws_iam_role_policy.booking_app_deploy
}

# booking_media.tf
moved {
  from = aws_s3_bucket.booking_supply_media
  to   = module.environment.aws_s3_bucket.booking_supply_media
}

moved {
  from = aws_s3_bucket_public_access_block.booking_supply_media
  to   = module.environment.aws_s3_bucket_public_access_block.booking_supply_media
}

moved {
  from = aws_s3_bucket_ownership_controls.booking_supply_media
  to   = module.environment.aws_s3_bucket_ownership_controls.booking_supply_media
}

moved {
  from = aws_s3_bucket_server_side_encryption_configuration.booking_supply_media
  to   = module.environment.aws_s3_bucket_server_side_encryption_configuration.booking_supply_media
}

moved {
  from = aws_s3_bucket_versioning.booking_supply_media
  to   = module.environment.aws_s3_bucket_versioning.booking_supply_media
}

moved {
  from = aws_s3_bucket_lifecycle_configuration.booking_supply_media
  to   = module.environment.aws_s3_bucket_lifecycle_configuration.booking_supply_media
}

moved {
  from = aws_s3_bucket_policy.booking_supply_media
  to   = module.environment.aws_s3_bucket_policy.booking_supply_media
}

moved {
  from = aws_iam_role_policy.booking_ecs_task_supply_media
  to   = module.environment.aws_iam_role_policy.booking_ecs_task_supply_media
}

# booking_ops_docs.tf
moved {
  from = aws_s3_bucket.booking_ops_docs
  to   = module.environment.aws_s3_bucket.booking_ops_docs
}

moved {
  from = aws_s3_bucket_public_access_block.booking_ops_docs
  to   = module.environment.aws_s3_bucket_public_access_block.booking_ops_docs
}

moved {
  from = aws_s3_bucket_ownership_controls.booking_ops_docs
  to   = module.environment.aws_s3_bucket_ownership_controls.booking_ops_docs
}

moved {
  from = aws_s3_bucket_server_side_encryption_configuration.booking_ops_docs
  to   = module.environment.aws_s3_bucket_server_side_encryption_configuration.booking_ops_docs
}

moved {
  from = aws_s3_bucket_versioning.booking_ops_docs
  to   = module.environment.aws_s3_bucket_versioning.booking_ops_docs
}

moved {
  from = aws_s3_bucket_lifecycle_configuration.booking_ops_docs
  to   = module.environment.aws_s3_bucket_lifecycle_configuration.booking_ops_docs
}

moved {
  from = aws_s3_bucket_policy.booking_ops_docs
  to   = module.environment.aws_s3_bucket_policy.booking_ops_docs
}

moved {
  from = aws_iam_role_policy.booking_ecs_task_ops_docs
  to   = module.environment.aws_iam_role_policy.booking_ecs_task_ops_docs
}
