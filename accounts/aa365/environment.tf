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
#
# Slice 2 (S266, AA-1004 P1): the AA-Partner (CRM) stack, i.e. the former crm_app.tf (API: ECR, logs, Sentry secret
# shell, execution / task / deploy roles, task definition, target group, ECS service, no-healthy-task alarm),
# crm_web.tf (the web service; the Content studio is part of it since AA-1036), crm_data.tf (DSN secret shell, the
# three KMS keys + aliases, key alarms), crm_storage.tf (the four buckets, Object Lock, decrypt anomaly alarm, audit
# export grant), crm_mail.tf (mail grant, OAuth secret shell), crm_scrub.tf (guardrail, corpus role) and crm_llm.tf
# (Nova Lite grant): 70 resources, one moved block each below (AA-1036 deleted the 11 of the retired Content studio,
# crm_portal.tf, with their moved blocks). The CRM ecs-tasks trust now uses the module's
# booking_ecs_tasks_assume document (the root copy had no other user and is gone; same JSON).
# Kept in this root on purpose:
#   - aws_lb_listener_rule.crm_api (now alb_rules.tf, same reason as the Booking rule); the CRM services wait for
#     their listener rules through module inputs crm_*_rule_gate.
#   - the CRM edge files crm_edge.tf, crm_agency_edge.tf, crm_client_edge.tf (CloudFront, ACM, DNS records, the
#     origin secret and the host rules on the shared listener): they move with DNS and the ALB.
#   - crm_mail_receipt.tf (the MX record in the account zone and the receipt rule in the region's one active SES rule
#     set, ordered by e2e_mailbox.tf).
#   - the CRM grants that live with their topic: identity_partner.tf (partner pool, SES send) on the CRM task role.
#   - cicd_crm.tf (account bootstrap); it reads the CRM naming contract back from the module.
#
# Slice 3 (S267, AA-1004 P1): the AA-TripPlanner stack, i.e. the former tripplanner.tf (edge key + random value, DB
# DSN and Sentry DSN secret shells, the Lambda artifacts bucket and its placeholder objects, the browse / assembly
# execution role, the two Lambdas, the HTTP API with its routes, stage and invoke permissions, the app deploy role)
# and tripplanner_jobs.tf (the jobs Lambda, its role, log group, alarms, scheduler role and daily schedule): 42
# resources, one moved block each below. The TripPlanner settings (tripplanner_variables.tf of this root) are
# declared identically in the module and passed through.
# Kept in this root on purpose:
#   - aws_security_group.tp_lambda (app_security_groups.tf, ADR 0004b), passed in as
#     tripplanner_lambda_security_group_id.
#   - the grants and observability that live with their topic: ses.tf tripplanner_lambda_ses_send on the execution
#     role, observability_ecosys.tf (the browse / assembly log groups, errors and throttles alarms).
#   - the custom domain api-tripplanner. (custom_domains.tf: domain name, API mapping, DNS record); it moves with DNS.
#   - the two Mapbox `removed` blocks (tripplanner_removed.tf): they name root addresses.
# Left for P1+ (one slice each, same pattern): identity (identity*.tf, ses.tf, dns, the CRM edge, the TripPlanner
# custom domain), observability + security, then the platform module calls of main.tf (vpc, rds, alb, ecs,
# api_gateway, waf, ...) as module.environment.module.<name>. Account bootstrap (cicd*.tf, agent_session.tf, the
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
  gold_bucket_arn                = module.s3.gold_bucket_arn
  gold_bucket_name               = module.s3.gold_bucket_name
  booking_listener_rule_gate     = aws_lb_listener_rule.booking.arn
  booking_security_group_id      = aws_security_group.booking_api.id
  ses_from_address               = var.ses_from_address
  ses_configuration_set_name     = aws_sesv2_configuration_set.stream["transactional"].configuration_set_name
  m2m_pool_endpoint              = aws_cognito_user_pool.m2m.endpoint
  m2m_crm_client_id              = aws_cognito_user_pool_client.m2m_crm.id
  alerts_topic_arn               = aws_sns_topic.alerts.arn

  # Slice 2 (CRM) platform inputs: generic shared objects, the CRM security groups, the CRM edge (crm_edge.tf,
  # crm_agency_edge.tf, crm_client_edge.tf, alb_rules.tf) and the identity pools / clients the CRM tasks read.
  alb_arn_suffix                = module.alb.alb_arn_suffix
  dns_zone_name                 = var.dns_zone_name
  ecosys_tags                   = local.ecosys_tags
  runbook_suffix                = local.runbook_suffix
  m2m_crm_client_secret_arn     = aws_secretsmanager_secret.m2m_crm_client.arn
  crm_api_security_group_id     = aws_security_group.crm_api.id
  crm_web_security_group_id     = aws_security_group.crm_web.id
  crm_edge_on                   = local.crm_edge_on
  crm_partner_host              = local.crm_partner_host
  crm_agency_host               = local.crm_agency_host
  crm_client_hosts              = local.crm_client_hosts
  crm_intake_origin             = local.crm_intake_origin
  crm_api_listener_rule_gate    = aws_lb_listener_rule.crm_api[*].arn
  crm_partner_default_rule_gate = aws_lb_listener_rule.crm_partner_default[*].arn

  cognito_workforce_pool_endpoint        = aws_cognito_user_pool.workforce.endpoint
  cognito_workforce_cis_admin_client_id  = aws_cognito_user_pool_client.workforce["cis-admin"].id
  cognito_workforce_breakglass_client_id = aws_cognito_user_pool_client.workforce["breakglass"].id
  cognito_workforce_crm_staff_client_id  = aws_cognito_user_pool_client.workforce["crm-staff"].id
  # AA-911: the staff frontends on ECS (staff_web.tf of the module, staff_web_edge.tf + alb_rules.tf here).
  cognito_workforce_booking_staff_client_id = aws_cognito_user_pool_client.workforce["booking-staff"].id
  cis_admin_secret_arn                      = var.secret_admin_arn
  staff_web_security_group_id               = aws_security_group.staff_web.id
  staff_web_listener_rule_gate              = concat([aws_lb_listener_rule.staff_cis_admin.arn, aws_lb_listener_rule.staff_booking_admin.arn], aws_lb_listener_rule.test_wp[*].arn)
  # AA-1060: the WordPress test site sidecar of the Booking admin task (test_wp.tf of the module, test_wp_edge.tf here).
  test_wp_enabled          = var.test_wp_enabled
  test_wp_service_attached = var.test_wp_service_attached
  # AA-1038: the TripPlanner frontend on ECS (tripplanner_web.tf of the module, tripplanner_web_edge.tf + alb_rules.tf
  # here). The traveller identity keys exist only while their identity.tf switches are on.
  tripplanner_web_security_group_id  = aws_security_group.tripplanner_web.id
  tripplanner_web_edge_on            = local.tp_web_edge_on
  tripplanner_web_listener_rule_gate = aws_lb_listener_rule.tripplanner_web[*].arn
  tripplanner_web_identity_secret_arns = merge(
    { for arn in aws_secretsmanager_secret.identity_traveller_bff[*].arn : "TP_COGNITO_BFF_KEY" => arn },
    { for arn in aws_secretsmanager_secret.identity_traveller_signup_proof[*].arn : "TP_COGNITO_SIGNUP_PROOF_KEY" => arn },
  )
  cognito_workforce_prefix_domain       = aws_cognito_user_pool_domain.workforce_prefix.domain
  cognito_partner_pool_id               = aws_cognito_user_pool.partner.id
  cognito_partner_web_client_id         = aws_cognito_user_pool_client.partner["partner-web"].id
  cognito_partner_issuer                = local.idpartner_issuer
  cognito_partner_login_base            = local.idpartner_login_base
  cognito_external_cis_portal_client_id = aws_cognito_user_pool_client.external["cis-portal"].id
  cognito_external_prefix_domain        = aws_cognito_user_pool_domain.external_prefix.domain
  identity_custom_domains_enabled       = local.id_custom_domains
  identity_external_custom_domain       = var.identity_external_custom_domain
  identity_workforce_custom_domain      = var.identity_workforce_custom_domain

  # CRM settings (crm_variables.tf of this root, passed through unchanged).
  crm_github_repo_id           = var.crm_github_repo_id
  crm_cis_api_url              = var.crm_cis_api_url
  crm_booking_api_url          = var.crm_booking_api_url
  crm_booking_admin_url        = var.crm_booking_admin_url
  crm_sentry_enabled           = var.crm_sentry_enabled
  crm_partner_signin_enabled   = var.crm_partner_signin_enabled
  crm_web_client_hosts         = var.crm_web_client_hosts
  crm_audit_compliance_enabled = var.crm_audit_compliance_enabled
  crm_ingest_subdomain         = var.crm_ingest_subdomain
  crm_mail_oauth_enabled       = var.crm_mail_oauth_enabled
  crm_scrub_guardrail_enabled  = var.crm_scrub_guardrail_enabled
  crm_llm_bedrock_enabled      = var.crm_llm_bedrock_enabled
  crm_slo                      = var.crm_slo

  # Booking settings (booking_variables.tf of this root, passed through unchanged).
  booking_github_repo_id     = var.booking_github_repo_id
  booking_staff_notify_email = var.booking_staff_notify_email
  booking_staff_admin_url    = var.booking_staff_admin_url
  booking_sentry_enabled     = var.booking_sentry_enabled
  # AA-1093: the bk_tenant_erase kill switch (default "false").
  booking_tenant_erase_apply_enabled = var.booking_tenant_erase_apply_enabled
  # AA-1096 L6: the stage throttle (was a literal in the module).
  booking_throttle_rate_limit  = var.booking_throttle_rate_limit
  booking_throttle_burst_limit = var.booking_throttle_burst_limit

  # Slice 3 (TripPlanner) platform inputs (tripplanner_inputs.tf of the module).
  tripplanner_lambda_security_group_id = aws_security_group.tp_lambda.id
  bedrock_acct_primary                 = local.bedrock_acct_primary
  eventbridge_schedule_group_name      = module.eventbridge.schedule_group_name
  tripplanner_placeholder_zip          = "${path.module}/artifacts/placeholder.zip"

  # TripPlanner settings (tripplanner_variables.tf of this root, passed through unchanged).
  tripplanner_throttle_rate_limit                   = var.tripplanner_throttle_rate_limit
  tripplanner_throttle_burst_limit                  = var.tripplanner_throttle_burst_limit
  tripplanner_narrate_throttle_rate_limit           = var.tripplanner_narrate_throttle_rate_limit
  tripplanner_narrate_throttle_burst_limit          = var.tripplanner_narrate_throttle_burst_limit
  tripplanner_search_throttle_rate_limit            = var.tripplanner_search_throttle_rate_limit
  tripplanner_search_throttle_burst_limit           = var.tripplanner_search_throttle_burst_limit
  tripplanner_browse_reserved_concurrency           = var.tripplanner_browse_reserved_concurrency
  tripplanner_lambda_reserved_concurrency           = var.tripplanner_lambda_reserved_concurrency
  tripplanner_jobs_reserved_concurrency             = var.tripplanner_jobs_reserved_concurrency
  tripplanner_jobs_schedule_expression              = var.tripplanner_jobs_schedule_expression
  tripplanner_jobs_erasure_feed_schedule_expression = var.tripplanner_jobs_erasure_feed_schedule_expression
  tripplanner_jobs_retention_override_enabled       = var.tripplanner_jobs_retention_override_enabled
  tripplanner_jobs_tenant_erase_apply_enabled       = var.tripplanner_jobs_tenant_erase_apply_enabled
}

locals {
  # Booking naming for the root files that still build Booking-named objects (see the header). One definition, in
  # the module.
  bk_name_prefix = module.environment.booking_name_prefix
  bk_port        = module.environment.booking_port
  bk_tags        = module.environment.booking_tags

  # CRM naming and per-service values for the root files that still build CRM-named objects or grants (cicd_crm.tf,
  # the edge files, alb_rules.tf crm_api, app_security_groups.tf, identity_partner.tf, identity_alerts.tf,
  # e2e_mailbox.tf). One definition, in the module (crm_inputs.tf, crm_app.tf, crm_web.tf).
  crm_name_prefix  = module.environment.crm_name_prefix
  crm_tags         = module.environment.crm_tags
  crm_port         = module.environment.crm_port
  crm_app_tags     = module.environment.crm_app_tags
  crm_web_port     = module.environment.crm_web_port
  crm_web_tags     = module.environment.crm_web_tags
  crm_oidc_repo_id = module.environment.crm_oidc_repo_id

  # TripPlanner naming for the root files that still build TripPlanner-named objects (app_security_groups.tf
  # tp_lambda, ses.tf tripplanner_lambda_ses_send). One definition, in the module (tripplanner.tf).
  tp_name_prefix = module.environment.tripplanner_name_prefix
  tp_tags        = module.environment.tripplanner_tags
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
# Outputs that were declared in the CRM files (crm_app.tf, crm_web.tf, crm_data.tf, crm_storage.tf,
# crm_mail.tf, crm_scrub.tf, crm_llm.tf), same names and values (the AA-Partner `dev` environment values, the
# runbooks and tools/identity/crm_dev_identity.py read them by name).
# -----------------------------------------------------------------------------
output "crm_app_deploy_role_arn" {
  description = "AA-933: AWS_ROLE_ARN of the AA-Partner GitHub environment dev."
  value       = module.environment.crm_app_deploy_role_arn
}

output "crm_ecr_repository_url" {
  value = module.environment.crm_ecr_repository_url
}

output "crm_ecs_service_name" {
  value = module.environment.crm_ecs_service_name
}

output "crm_task_definition_family" {
  value = module.environment.crm_task_definition_family
}

output "crm_api_base_url" {
  description = "AA-933: CRM_API_BASE_URL of the AA-Partner dev environment; health = <this>/crm/health and /crm/health/ready."
  value       = module.environment.crm_api_base_url
}

output "crm_web_ecr_repository_url" {
  value = module.environment.crm_web_ecr_repository_url
}

output "crm_web_ecs_service_name" {
  value = module.environment.crm_web_ecs_service_name
}

output "crm_web_task_definition_family" {
  value = module.environment.crm_web_task_definition_family
}

output "crm_web_secret_name" {
  description = "AA-935: the secret tools/identity/crm_dev_identity.py web-secret writes."
  value       = module.environment.crm_web_secret_name
}

output "crm_kms_aliases" {
  description = "AA-932: aliases of the CRM KMS keys (KeyProvider config of AA-Partner, AA-934)."
  value       = module.environment.crm_kms_aliases
}

output "crm_db_secret_name" {
  description = "AA-932: the crm_app DSN secret (shell; Nghiệp writes the value, then DB Migrate set-password)."
  value       = module.environment.crm_db_secret_name
}

output "crm_bucket_names" {
  description = "AA-932: the AA-Partner buckets (audit-c, audit-g, documents, ingest)."
  value       = module.environment.crm_bucket_names
}

output "crm_mail_ingest" {
  description = "AA-945: where the AA-Partner forward-in mail lands (domain, rule, bucket prefix)."
  value       = module.environment.crm_mail_ingest
}

output "crm_scrub_guardrail_id" {
  description = "AA-938: SCRUB_GUARDRAIL_ID (AA-Partner task env, set here; and the scrub-corpus environment variable)."
  value       = module.environment.crm_scrub_guardrail_id
}

output "crm_scrub_guardrail_version" {
  description = "AA-938: SCRUB_GUARDRAIL_VERSION (published version the task and the corpus workflow use)."
  value       = module.environment.crm_scrub_guardrail_version
}

output "crm_scrub_corpus_role_arn" {
  description = "AA-938: SCRUB_CORPUS_ROLE_ARN of the AA-Partner GitHub environment scrub-corpus."
  value       = module.environment.crm_scrub_corpus_role_arn
}

output "crm_llm_model_id" {
  description = "AA-1027 F4: CRM_LLM_MODEL_ID of the AA-Partner task (null = the stub provider)."
  value       = module.environment.crm_llm_model_id
}

# -----------------------------------------------------------------------------
# Outputs that were declared in tripplanner.tf / tripplanner_jobs.tf, same names and values (the AA-TripPlanner-Web
# deploy and runbooks read them by name).
# -----------------------------------------------------------------------------
output "tripplanner_api_base_url" {
  value = module.environment.tripplanner_api_base_url
}

output "tripplanner_lambda_exec_role_arn" {
  value = module.environment.tripplanner_lambda_exec_role_arn
}

output "tripplanner_app_deploy_role_arn" {
  value = module.environment.tripplanner_app_deploy_role_arn
}

output "tripplanner_artifacts_bucket" {
  value = module.environment.tripplanner_artifacts_bucket
}

output "tripplanner_api_key_secret_arn" {
  value = module.environment.tripplanner_api_key_secret_arn
}

output "tripplanner_jobs_function_name" {
  value = module.environment.tripplanner_jobs_function_name
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

# -----------------------------------------------------------------------------
# Slice 2 moves (S266): the AA-Partner (CRM) stack, one per resource. A resource-level move carries every count /
# for_each instance with its key unchanged (aws_s3_bucket.crm["audit-c"] -> module.environment.aws_s3_bucket.crm["audit-c"]).
# -----------------------------------------------------------------------------
# crm_app.tf
moved {
  from = aws_ecr_repository.crm_api
  to   = module.environment.aws_ecr_repository.crm_api
}

moved {
  from = aws_ecr_lifecycle_policy.crm_api
  to   = module.environment.aws_ecr_lifecycle_policy.crm_api
}

moved {
  from = aws_cloudwatch_log_group.crm_api
  to   = module.environment.aws_cloudwatch_log_group.crm_api
}

moved {
  from = aws_secretsmanager_secret.crm_sentry_dsn
  to   = module.environment.aws_secretsmanager_secret.crm_sentry_dsn
}

moved {
  from = aws_iam_role.crm_ecs_execution
  to   = module.environment.aws_iam_role.crm_ecs_execution
}

moved {
  from = aws_iam_role_policy.crm_ecs_execution
  to   = module.environment.aws_iam_role_policy.crm_ecs_execution
}

moved {
  from = aws_iam_role.crm_ecs_task
  to   = module.environment.aws_iam_role.crm_ecs_task
}

moved {
  from = aws_iam_role_policy.crm_ecs_task
  to   = module.environment.aws_iam_role_policy.crm_ecs_task
}

moved {
  from = aws_ecs_task_definition.crm_api
  to   = module.environment.aws_ecs_task_definition.crm_api
}

moved {
  from = aws_lb_target_group.crm_api
  to   = module.environment.aws_lb_target_group.crm_api
}

moved {
  from = aws_ecs_service.crm_api
  to   = module.environment.aws_ecs_service.crm_api
}

moved {
  from = aws_iam_role.crm_app_deploy
  to   = module.environment.aws_iam_role.crm_app_deploy
}

moved {
  from = aws_iam_role_policy.crm_app_deploy
  to   = module.environment.aws_iam_role_policy.crm_app_deploy
}

moved {
  from = aws_cloudwatch_metric_alarm.crm_no_healthy_task
  to   = module.environment.aws_cloudwatch_metric_alarm.crm_no_healthy_task
}

# crm_web.tf
moved {
  from = aws_ecr_repository.crm_web
  to   = module.environment.aws_ecr_repository.crm_web
}

moved {
  from = aws_ecr_lifecycle_policy.crm_web
  to   = module.environment.aws_ecr_lifecycle_policy.crm_web
}

moved {
  from = aws_secretsmanager_secret.crm_web
  to   = module.environment.aws_secretsmanager_secret.crm_web
}

moved {
  from = aws_iam_role.crm_web_ecs_execution
  to   = module.environment.aws_iam_role.crm_web_ecs_execution
}

moved {
  from = aws_iam_role_policy.crm_web_ecs_execution
  to   = module.environment.aws_iam_role_policy.crm_web_ecs_execution
}

moved {
  from = aws_iam_role.crm_web_ecs_task
  to   = module.environment.aws_iam_role.crm_web_ecs_task
}

moved {
  from = aws_iam_role_policy.crm_web_ecs_task
  to   = module.environment.aws_iam_role_policy.crm_web_ecs_task
}

moved {
  from = aws_ecs_task_definition.crm_web
  to   = module.environment.aws_ecs_task_definition.crm_web
}

moved {
  from = aws_lb_target_group.crm_web
  to   = module.environment.aws_lb_target_group.crm_web
}

moved {
  from = aws_ecs_service.crm_web
  to   = module.environment.aws_ecs_service.crm_web
}

moved {
  from = aws_cloudwatch_metric_alarm.crm_web_no_healthy_task
  to   = module.environment.aws_cloudwatch_metric_alarm.crm_web_no_healthy_task
}

# crm_data.tf
moved {
  from = aws_secretsmanager_secret.crm_db
  to   = module.environment.aws_secretsmanager_secret.crm_db
}

moved {
  from = aws_kms_key.crm_data
  to   = module.environment.aws_kms_key.crm_data
}

moved {
  from = aws_kms_key.crm_ingest
  to   = module.environment.aws_kms_key.crm_ingest
}

moved {
  from = aws_kms_key.crm_seal
  to   = module.environment.aws_kms_key.crm_seal
}

moved {
  from = aws_kms_alias.crm
  to   = module.environment.aws_kms_alias.crm
}

moved {
  from = aws_cloudwatch_event_rule.crm_kms_key_admin
  to   = module.environment.aws_cloudwatch_event_rule.crm_kms_key_admin
}

moved {
  from = aws_cloudwatch_event_target.crm_kms_key_admin
  to   = module.environment.aws_cloudwatch_event_target.crm_kms_key_admin
}

moved {
  from = aws_cloudwatch_event_rule.crm_kms_foreign_use
  to   = module.environment.aws_cloudwatch_event_rule.crm_kms_foreign_use
}

moved {
  from = aws_cloudwatch_event_target.crm_kms_foreign_use
  to   = module.environment.aws_cloudwatch_event_target.crm_kms_foreign_use
}

# crm_storage.tf
moved {
  from = aws_s3_bucket.crm
  to   = module.environment.aws_s3_bucket.crm
}

moved {
  from = aws_s3_bucket_public_access_block.crm
  to   = module.environment.aws_s3_bucket_public_access_block.crm
}

moved {
  from = aws_s3_bucket_ownership_controls.crm
  to   = module.environment.aws_s3_bucket_ownership_controls.crm
}

moved {
  from = aws_s3_bucket_server_side_encryption_configuration.crm
  to   = module.environment.aws_s3_bucket_server_side_encryption_configuration.crm
}

moved {
  from = aws_s3_bucket_versioning.crm
  to   = module.environment.aws_s3_bucket_versioning.crm
}

moved {
  from = aws_s3_bucket_object_lock_configuration.crm_audit
  to   = module.environment.aws_s3_bucket_object_lock_configuration.crm_audit
}

moved {
  from = aws_s3_bucket_lifecycle_configuration.crm_audit
  to   = module.environment.aws_s3_bucket_lifecycle_configuration.crm_audit
}

moved {
  from = aws_s3_bucket_lifecycle_configuration.crm_documents
  to   = module.environment.aws_s3_bucket_lifecycle_configuration.crm_documents
}

moved {
  from = aws_s3_bucket_lifecycle_configuration.crm_ingest
  to   = module.environment.aws_s3_bucket_lifecycle_configuration.crm_ingest
}

moved {
  from = aws_s3_bucket_policy.crm
  to   = module.environment.aws_s3_bucket_policy.crm
}

moved {
  from = aws_cloudwatch_log_group.crm_kms_decrypt
  to   = module.environment.aws_cloudwatch_log_group.crm_kms_decrypt
}

moved {
  from = aws_cloudwatch_log_resource_policy.crm_kms_decrypt
  to   = module.environment.aws_cloudwatch_log_resource_policy.crm_kms_decrypt
}

moved {
  from = aws_cloudwatch_event_rule.crm_kms_decrypt
  to   = module.environment.aws_cloudwatch_event_rule.crm_kms_decrypt
}

moved {
  from = aws_cloudwatch_event_target.crm_kms_decrypt
  to   = module.environment.aws_cloudwatch_event_target.crm_kms_decrypt
}

moved {
  from = aws_cloudwatch_log_metric_filter.crm_kms_decrypt
  to   = module.environment.aws_cloudwatch_log_metric_filter.crm_kms_decrypt
}

moved {
  from = aws_cloudwatch_metric_alarm.crm_kms_decrypt_anomaly
  to   = module.environment.aws_cloudwatch_metric_alarm.crm_kms_decrypt_anomaly
}

moved {
  from = aws_iam_role_policy.crm_ecs_task_audit_export
  to   = module.environment.aws_iam_role_policy.crm_ecs_task_audit_export
}

# crm_mail.tf
moved {
  from = aws_iam_role_policy.crm_ecs_task_mail
  to   = module.environment.aws_iam_role_policy.crm_ecs_task_mail
}

moved {
  from = aws_secretsmanager_secret.crm_mail_oauth
  to   = module.environment.aws_secretsmanager_secret.crm_mail_oauth
}

# crm_scrub.tf
moved {
  from = aws_bedrock_guardrail.crm_scrub
  to   = module.environment.aws_bedrock_guardrail.crm_scrub
}

moved {
  from = aws_bedrock_guardrail_version.crm_scrub
  to   = module.environment.aws_bedrock_guardrail_version.crm_scrub
}

moved {
  from = aws_iam_role_policy.crm_ecs_task_scrub
  to   = module.environment.aws_iam_role_policy.crm_ecs_task_scrub
}

moved {
  from = aws_iam_role.crm_scrub_corpus
  to   = module.environment.aws_iam_role.crm_scrub_corpus
}

moved {
  from = aws_iam_role_policy.crm_scrub_corpus
  to   = module.environment.aws_iam_role_policy.crm_scrub_corpus
}

# crm_llm.tf
moved {
  from = aws_iam_role_policy.crm_ecs_task_llm
  to   = module.environment.aws_iam_role_policy.crm_ecs_task_llm
}

# -----------------------------------------------------------------------------
# Slice 3 moves (S267): the AA-TripPlanner stack, one per resource (tools/terraform/tests/
# test_aa1004_environment_moves.py SLICE_3).
# -----------------------------------------------------------------------------

# tripplanner.tf
moved {
  from = random_password.tripplanner_api_key
  to   = module.environment.random_password.tripplanner_api_key
}

moved {
  from = aws_secretsmanager_secret.tripplanner_db
  to   = module.environment.aws_secretsmanager_secret.tripplanner_db
}

moved {
  from = aws_secretsmanager_secret_version.tripplanner_db
  to   = module.environment.aws_secretsmanager_secret_version.tripplanner_db
}

moved {
  from = aws_secretsmanager_secret.tripplanner_api_key
  to   = module.environment.aws_secretsmanager_secret.tripplanner_api_key
}

moved {
  from = aws_secretsmanager_secret_version.tripplanner_api_key
  to   = module.environment.aws_secretsmanager_secret_version.tripplanner_api_key
}

moved {
  from = aws_secretsmanager_secret.tripplanner_sentry_dsn
  to   = module.environment.aws_secretsmanager_secret.tripplanner_sentry_dsn
}

moved {
  from = aws_s3_bucket.tripplanner_artifacts
  to   = module.environment.aws_s3_bucket.tripplanner_artifacts
}

moved {
  from = aws_s3_bucket_versioning.tripplanner_artifacts
  to   = module.environment.aws_s3_bucket_versioning.tripplanner_artifacts
}

moved {
  from = aws_s3_bucket_public_access_block.tripplanner_artifacts
  to   = module.environment.aws_s3_bucket_public_access_block.tripplanner_artifacts
}

moved {
  from = aws_s3_bucket_server_side_encryption_configuration.tripplanner_artifacts
  to   = module.environment.aws_s3_bucket_server_side_encryption_configuration.tripplanner_artifacts
}

moved {
  from = aws_s3_object.tripplanner_browse_zip
  to   = module.environment.aws_s3_object.tripplanner_browse_zip
}

moved {
  from = aws_s3_object.tripplanner_assembly_zip
  to   = module.environment.aws_s3_object.tripplanner_assembly_zip
}

moved {
  from = aws_iam_role.tripplanner_lambda_exec
  to   = module.environment.aws_iam_role.tripplanner_lambda_exec
}

moved {
  from = aws_iam_role_policy_attachment.tripplanner_lambda_vpc
  to   = module.environment.aws_iam_role_policy_attachment.tripplanner_lambda_vpc
}

moved {
  from = aws_iam_role_policy.tripplanner_lambda_permissions
  to   = module.environment.aws_iam_role_policy.tripplanner_lambda_permissions
}

moved {
  from = aws_lambda_function.tripplanner_browse
  to   = module.environment.aws_lambda_function.tripplanner_browse
}

moved {
  from = aws_lambda_function.tripplanner_assembly
  to   = module.environment.aws_lambda_function.tripplanner_assembly
}

moved {
  from = aws_apigatewayv2_api.tripplanner
  to   = module.environment.aws_apigatewayv2_api.tripplanner
}

moved {
  from = aws_apigatewayv2_integration.tripplanner_browse
  to   = module.environment.aws_apigatewayv2_integration.tripplanner_browse
}

moved {
  from = aws_apigatewayv2_integration.tripplanner_assembly
  to   = module.environment.aws_apigatewayv2_integration.tripplanner_assembly
}

moved {
  from = aws_apigatewayv2_route.tripplanner_browse
  to   = module.environment.aws_apigatewayv2_route.tripplanner_browse
}

moved {
  from = aws_apigatewayv2_route.tripplanner_assembly
  to   = module.environment.aws_apigatewayv2_route.tripplanner_assembly
}

moved {
  from = aws_apigatewayv2_route.tripplanner_me
  to   = module.environment.aws_apigatewayv2_route.tripplanner_me
}

moved {
  from = aws_apigatewayv2_route.tripplanner_narrate
  to   = module.environment.aws_apigatewayv2_route.tripplanner_narrate
}

moved {
  from = aws_apigatewayv2_route.tripplanner_search
  to   = module.environment.aws_apigatewayv2_route.tripplanner_search
}

moved {
  from = aws_apigatewayv2_stage.tripplanner
  to   = module.environment.aws_apigatewayv2_stage.tripplanner
}

moved {
  from = aws_lambda_permission.tripplanner_browse_apigw
  to   = module.environment.aws_lambda_permission.tripplanner_browse_apigw
}

moved {
  from = aws_lambda_permission.tripplanner_assembly_apigw
  to   = module.environment.aws_lambda_permission.tripplanner_assembly_apigw
}

moved {
  from = aws_iam_role.tripplanner_app_deploy
  to   = module.environment.aws_iam_role.tripplanner_app_deploy
}

moved {
  from = aws_iam_role_policy.tripplanner_app_deploy
  to   = module.environment.aws_iam_role_policy.tripplanner_app_deploy
}

# tripplanner_jobs.tf
moved {
  from = aws_s3_object.tripplanner_jobs_zip
  to   = module.environment.aws_s3_object.tripplanner_jobs_zip
}

moved {
  from = aws_iam_role.tripplanner_jobs_exec
  to   = module.environment.aws_iam_role.tripplanner_jobs_exec
}

moved {
  from = aws_iam_role_policy_attachment.tripplanner_jobs_vpc
  to   = module.environment.aws_iam_role_policy_attachment.tripplanner_jobs_vpc
}

moved {
  from = aws_iam_role_policy.tripplanner_jobs_permissions
  to   = module.environment.aws_iam_role_policy.tripplanner_jobs_permissions
}

moved {
  from = aws_cloudwatch_log_group.tripplanner_jobs
  to   = module.environment.aws_cloudwatch_log_group.tripplanner_jobs
}

moved {
  from = aws_lambda_function.tripplanner_jobs
  to   = module.environment.aws_lambda_function.tripplanner_jobs
}

moved {
  from = aws_lambda_function_event_invoke_config.tripplanner_jobs
  to   = module.environment.aws_lambda_function_event_invoke_config.tripplanner_jobs
}

moved {
  from = aws_cloudwatch_metric_alarm.tripplanner_jobs_errors
  to   = module.environment.aws_cloudwatch_metric_alarm.tripplanner_jobs_errors
}

moved {
  from = aws_cloudwatch_metric_alarm.tripplanner_jobs_not_run
  to   = module.environment.aws_cloudwatch_metric_alarm.tripplanner_jobs_not_run
}

moved {
  from = aws_iam_role.tripplanner_jobs_scheduler
  to   = module.environment.aws_iam_role.tripplanner_jobs_scheduler
}

moved {
  from = aws_iam_role_policy.tripplanner_jobs_scheduler_invoke
  to   = module.environment.aws_iam_role_policy.tripplanner_jobs_scheduler_invoke
}

moved {
  from = aws_scheduler_schedule.tripplanner_jobs_daily
  to   = module.environment.aws_scheduler_schedule.tripplanner_jobs_daily
}
