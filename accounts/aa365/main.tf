# =============================================================================
# AA-246 Track B — AA-CIS root module for account 005097885195 (aa365)
# Mirrors the architecture of the account-1 root module (../../main.tf) but
# wires ARNs through module outputs instead of literal account-1 ARNs.
# Scope (confirmed): VPC, RDS, ECS, ALB, S3, Secrets, API Gateway, WAF,
# EventBridge (AA-402, 2026-08-14). The CIS Lambdas, the Step Functions pipeline
# and its SQS queues were retired in AA-750 (#88); the STEP_FUNCTIONS_ARN env var
# still passed to the ECS task def below is kept on purpose (unused computed
# string; dropping it would change the task definitions, see AA-750 notes).
# AA-180 (ACPv1 orchestration epic) stays separate and deferred/dead — the
# eventbridge module below is ACPv2's own schedules (daily ingest, weekly
# export, Gate C veto window), not an AA-180 revival.
# AA-477 (2026-08-27): removed the other 2 ACP Lambdas (acp-s3-campaign-planner,
# acp-s4-evaluate) — 0 EventBridge rule, 0 resource policy, 0 invocation ever
# recorded, dead ACPv1 stage-chain source (services/acp_s3/, services/
# acp_s4_evaluate/ in AA-CIS-App). brand_brief_parser, the last "1 ACP" Lambda,
# was retired with the rest in AA-750.
# =============================================================================

locals {
  # AA-828 (DM-10.1): App is the cost allocation tag the per-App budgets filter on
  # (observability.tf aws_budgets_budget.per_app_monthly). Everything in this root that is not
  # TripPlanner (local.tp_tags), Booking (local.bk_tags) or shared is CIS, so common_tags carries
  # App = "cis" and shared resources override it with local.shared_tags.
  #
  # Set here and in the module tag maps, NOT in the provider default_tags (versions.tf): a
  # default_tags App would (1) silently bill every future resource that forgets its own App to
  # "cis", including TripPlanner/Booking ones, and (2) re-tag every resource in the root at once,
  # including the bootstrap IAM roles of cicd.tf / cicd_split.tf / agent_session.tf that only a
  # human MFA apply may change. Resource-level tags win over default_tags for the same key.
  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    App         = "cis"
  }

  # Infrastructure used by more than one app: VPC/NAT/subnets, RDS, ALB + VPC-link NLB, WAF, the ECS
  # cluster, the account alert topic, CloudTrail and the AA-272 network diagnostics.
  shared_tags = merge(local.common_tags, { App = "shared" })

  # Modules that had no tags input before AA-828 get only the App key, so the Project/ManagedBy
  # values they already carry from the provider default_tags do not change.
  cis_app_tags    = { App = "cis" }
  shared_app_tags = { App = "shared" }

  # Breaks the ECS <-> Step Functions mutual module dependency (ECS task def
  # embeds STEP_FUNCTIONS_ARN as an env var; the state machine definition
  # embeds the ECS cluster + task-definition ARNs). Both ARNs are fully
  # deterministic from name + account + region, so build them from vars
  # instead of module outputs — avoids a real dependency cycle without
  # hardcoding an account-specific literal (unlike the account-1 root, which
  # hardcodes the account-1 ARNs directly).
  name_prefix          = "${var.project}-${var.environment}"
  ecs_cluster_arn      = "arn:aws:ecs:${var.aws_region}:${var.account_id}:cluster/${local.name_prefix}-cluster"
  ecs_api_task_def_arn = "arn:aws:ecs:${var.aws_region}:${var.account_id}:task-definition/${local.name_prefix}-api"
  sfn_pipeline_arn     = "arn:aws:states:${var.aws_region}:${var.account_id}:stateMachine:${local.name_prefix}-pipeline"

  # AA-839: the Dev erasure drill switch, the ONLY line a drill PR changes. false = DRY RUN only
  # (ERASURE_APPLY_ENABLED=false, retention = the code default 30 days). true = apply on and retention 0
  # days, for the approved drill on a synthetic tenant only (root docs/legal/dsar-erasure-runbook.md
  # section 5). A change reaches the tasks only after Terraform Apply AND a CIS Deploy Dev dispatch
  # (the services ignore task_definition; the deploy copies the latest revision and swaps the image).
  erasure_drill = false
}

module "vpc" {
  source = "../../modules/vpc"

  project              = var.project
  environment          = var.environment
  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  db_subnet_cidrs      = var.db_subnet_cidrs

  # AA-806 step 4: aa-cis-nat-instance-role is in local.tf_managed_role_arns, so it carries the
  # workload boundary like every other role the CI apply role may write.
  permissions_boundary_arn = aws_iam_policy.workload_boundary.arn

  # ADR 0004b (X1 S11): one source group per DB caller (app_security_groups.tf).
  rds_ingress_sg_ids = local.rds_ingress_sg_ids

  tags = local.shared_app_tags # AA-828: VPC, subnets, NAT instance + EIP, route tables, SGs
}

module "rds" {
  source = "../../modules/rds"

  project              = var.project
  environment          = var.environment
  db_username          = var.db_username
  db_password          = var.db_password
  db_subnet_group_name = module.vpc.db_subnet_group_name
  sg_rds_id            = module.vpc.sg_rds_id
  apply_immediately    = var.rds_apply_immediately

  # AA-828 / DM-10.3: one instance for CIS + TripPlanner + Booking, owned by Infra. Tag change is
  # AddTagsToResource only (no ModifyDBInstance, no reboot); copy_tags_to_snapshot carries it to
  # new snapshots.
  tags = local.shared_app_tags

  depends_on = [module.vpc]
}

module "s3" {
  source = "../../modules/s3"

  project           = var.project
  environment       = var.environment
  allowed_role_arns = var.s3_allowed_role_arns
  tags              = local.common_tags

  # AA-844 (photos_cdn.tf): one bucket-policy statement for the photos CDN's OAC, photos/* only.
  # null while the CDN is gated off. No cycle: bucket -> distribution -> this policy statement.
  bronze_cloudfront_read = local.photos_cdn_on == 1 ? {
    distribution_arn = aws_cloudfront_distribution.photos_cdn[0].arn
    prefix           = local.photos_cdn_prefix
  } : null
}

module "secrets" {
  source = "../../modules/secrets"

  project     = var.project
  environment = var.environment
  tags        = local.cis_app_tags
}

module "elasticache" {
  source = "../../modules/elasticache"

  project            = var.project
  environment        = var.environment
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  sg_app_id          = module.vpc.sg_app_id
  ingress_sg_ids     = local.redis_ingress_sg_ids # ADR 0004b (X1 S11), app_security_groups.tf
  tags               = local.cis_app_tags         # only the CIS api reads REDIS_HOST

  depends_on = [module.vpc]
}

module "efs" {
  source = "../../modules/efs"

  project            = var.project
  environment        = var.environment
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  sg_app_id          = module.vpc.sg_app_id
  ingress_sg_ids     = local.efs_ingress_sg_ids # ADR 0004b (X1 S11), app_security_groups.tf
  tags               = local.cis_app_tags

  depends_on = [module.vpc]
}

module "alb" {
  source = "../../modules/alb"

  project             = var.project
  environment         = var.environment
  vpc_id              = module.vpc.vpc_id
  public_subnet_ids   = module.vpc.public_subnet_ids
  sg_alb_id           = module.vpc.sg_alb_id
  acm_certificate_arn = var.acm_certificate_arn
  private_subnet_ids  = module.vpc.private_subnet_ids
  vpc_cidr_block      = var.vpc_cidr
  access_logs_bucket  = aws_s3_bucket.diag_alb_logs.id # AA-272 diagnostic only
  tags                = local.shared_app_tags          # AA-828: CIS + Booking (/booking/* rule) behind it

  # AA-931 (crm_edge.tf): CloudFront VPC origin on the NLB -> prefix-list ingress on the NLB
  # group + a second ALB group admitting the NLB group. Plain bool from variables (no resource ref).
  cloudfront_vpc_origin_enabled = local.crm_edge_on == 1

  depends_on = [module.vpc, aws_s3_bucket_policy.diag_alb_logs]
}

module "ecs" {
  source = "../../modules/ecs"

  project     = var.project
  environment = var.environment
  aws_region  = var.aws_region

  private_subnet_ids = module.vpc.private_subnet_ids
  sg_app_id          = module.vpc.sg_app_id
  # ADR 0004b (X1 S13c): api and worker on their own groups (app_security_groups.tf).
  sg_api_id    = aws_security_group.cis_api.id
  sg_worker_id = aws_security_group.cis_worker.id

  target_group_arn = module.alb.target_group_arn

  # AA-874 S5: the TLS + AUTH replication group (modules/elasticache), the only CIS cache since S6 removed the
  # old plain node. A task-definition change here ships with the next CIS deploy-dev (services ignore
  # task_definition).
  redis_host            = module.elasticache.tls_primary_endpoint
  redis_tls             = true
  redis_auth_secret_arn = module.elasticache.auth_secret_arn
  redis_cluster_id      = module.elasticache.member_cluster_id

  # AA-902: satellite account IDs as env (the public CIS repo no longer carries them)
  bedrock_acct_primary  = local.bedrock_acct_primary
  bedrock_acct_fallback = local.bedrock_acct_fallback

  # AA-847 lines: the place_shape job (line geometry, Geoapify credits). The flip is false -> true in its own PR;
  # it reaches the tasks on the next CIS Deploy Dev (the deploy copies the latest task-def revision).
  place_shapes_enabled = true
  # AA-988: delete zero-reference orphan segments in every platform recompute (S252: backfill of 7,671 done by the
  # runbook with a snapshot + restore file; DRY RUN after = 0 deletable). Rollback: "report".
  segment_gc_mode = "apply"
  # AA-779: on since S247 (shadow verdicts read on real blogs first; ADR 0011 in AA-CIS-App). Rollback: "shadow".
  t9_faq_llm_filter = "on"
  # AA-645: S1 writer v2 on the worker, on since S248 (set by hand until S250, now carried here so a template
  # revision keeps it). Rollback to writer v1: false, apply, then CIS deploy-dev.
  s1_writer_v2_enabled = true
  # AA-835 (S6 review): the supply_media_purge job invalidates withdrawn Booking photo copies on the photos CDN.
  photos_cdn_distribution_arn = local.photos_cdn_on == 1 ? aws_cloudfront_distribution.photos_cdn[0].arn : ""
  # AA-839: data_erasure apply switch + tenant retention window, driven by local.erasure_drill above.
  erasure_apply_enabled         = local.erasure_drill
  erasure_tenant_retention_days = local.erasure_drill ? 0 : null # null = module default (30)

  task_cpu              = var.task_cpu
  task_memory           = var.task_memory
  service_desired_count = var.service_desired_count

  # Wired via module outputs (no hardcoded account-1 ARNs) — the two
  # exceptions are ecs_cluster/task_def <-> step_functions, see locals above.
  # X1 S18 (AA-860): api + worker DATABASE_URL = the cis_app DSN (db_migrator.tf). Was the RDS master
  # (module.secrets.rds_secret_arn, aa-cis/dev/rds), which DB Migrate keeps until S22. Rollback: put the
  # master back here, or update-service to the revision recorded before the apply (plan S18).
  secret_rds_arn        = aws_secretsmanager_secret.rds_cis_app.arn
  secret_openai_arn     = var.secret_openai_arn
  secret_admin_arn      = var.secret_admin_arn
  secret_jwt_arn        = var.secret_jwt_arn
  secret_dataforseo_arn = module.secrets.dataforseo_secret_arn
  bronze_bucket_name    = module.s3.bronze_bucket_name

  step_functions_arn = local.sfn_pipeline_arn
  sf_batch_threshold = 15

  # AmazonECSTaskExecutionRolePolicy alone doesn't grant secretsmanager:GetSecretValue —
  # account 1's execution role has this attached out-of-band; account 2 needs it explicit.
  execution_role_secrets_arn_pattern = "arn:aws:secretsmanager:${var.aws_region}:${var.account_id}:secret:${var.project}/${var.environment}/*"

  # AA-806 step 4: workload boundary on the CIS execution + task roles (cicd_split.tf).
  permissions_boundary_arn = aws_iam_policy.workload_boundary.arn

  # AA-828: App = "cis" on the api/worker services (propagated to their Fargate tasks), task
  # definitions, ECR repo, log group and roles; the cluster is shared with aws_ecs_service.booking.
  tags         = local.cis_app_tags
  cluster_tags = local.shared_app_tags

  # AA-828: operator alert e-mail env (api + worker). Send permission: aws_iam_role_policy
  # .cis_ecs_task_ses_send in ses.tf (only this From, only the transactional configuration set).
  ops_alert_email       = var.cis_ops_alert_email
  ses_from_address      = var.ses_from_address
  ses_configuration_set = aws_sesv2_configuration_set.stream["transactional"].configuration_set_name

  # AA-913: the admin page manages the e-mail subscriptions of this topic (grant: alert_recipients.tf)
  # and shows var.alert_email (the Terraform bootstrap subscription) locked. ALERT_EMAIL_TO above stays
  # the ops-mail fallback.
  alerts_topic_arn      = aws_sns_topic.alerts.arn
  alert_bootstrap_email = var.alert_email

  depends_on = [module.vpc, module.alb]
}

module "eventbridge" {
  source = "../../modules/eventbridge"

  project          = var.project
  environment      = var.environment
  aws_region       = var.aws_region
  account_id       = var.account_id
  tags             = local.common_tags
  alerts_topic_arn = aws_sns_topic.alerts.arn
  # AA-893: runbook link in the DLQ alarm description (alarm_runbooks.tf).
  alarm_runbook_url = local.runbook_url.queue_stuck

  # AA-402: same IAM propagation race as AA-287 — this module's event bus,
  # scheduler role, and schedule group needed aa-cis-dev-role's (retired, AA-806) newly-added
  # events:*/scheduler:*/iam:TagRole statements to actually be authorized
  # before they're created. A module-level depends_on was tried first but
  # cascaded to every resource/data-source inside the module (including the
  # DLQ policy, unrelated to these statements), producing a false diff on
  # an already-applied resource — this narrower, variable-gated dependency
  # only touches the 3 resources that actually need it (see
  # modules/eventbridge/variables.tf's iam_propagation_gate).
  iam_propagation_gate = time_sleep.wait_for_iam_propagation.id

  # AA-806 step 4: workload boundary on the ACP scheduler role (cicd_split.tf).
  permissions_boundary_arn = aws_iam_policy.workload_boundary.arn
}

module "monitoring" {
  source = "../../modules/monitoring"

  project     = var.project
  environment = var.environment
  aws_region  = var.aws_region
  account_id  = var.account_id
  tags        = local.common_tags
}

module "waf" {
  source = "../../modules/waf"

  project        = var.project
  environment    = var.environment
  alb_arn        = module.alb.alb_arn
  rate_limit     = 1000
  vpc_allow_cidr = var.vpc_cidr

  # AA-931: CloudFront VPC-origin requests carry the origin secret; rule CloudFrontOriginAllow lets them
  # past rate + geo (their source is a CloudFront edge address, not the viewer). null = no rule.
  origin_verify_header = local.crm_edge_on == 1 ? {
    name  = local.alb_origin_header_name
    value = random_password.crm_origin_verify[0].result
  } : null
  tags = local.shared_tags # AA-828: on the ALB and on the CIS + Booking REST API stages

  # S235 Phase 0: CommonRuleSet started in observe mode (whole group COUNT); enforced since
  # AA-806 S239 (var.waf_common_rules_count_only = false) after the count review + pre-flip test.
  common_rules_count_only = var.waf_common_rules_count_only

  # S235 Phase 0: same web ACL on the CIS and Booking REST API stages (real client IP -> rate + geo
  # actually apply). Gated OFF by default: associating a web ACL with an API Gateway stage needs
  # apigateway:SetWebACL, which the CI role (cicd.tf APIGatewayManage) does not have yet. Turn on
  # after that grant is applied (separate cicd.tf PR), see var.waf_protect_rest_api_stages.
  rest_api_stage_arns = var.waf_protect_rest_api_stages ? {
    cis     = module.api_gateway.stage_arn
    booking = aws_api_gateway_stage.booking.arn
  } : {}

  depends_on = [module.alb]
}

module "api_gateway" {
  source = "../../modules/api_gateway"

  project     = var.project
  environment = var.environment
  aws_region  = var.aws_region
  account_id  = var.account_id
  tags        = local.common_tags

  alb_dns_name             = module.alb.alb_dns_name
  nlb_dns_name             = module.alb.nlb_dns_name
  vpc_link_id              = module.alb.vpc_link_id
  acm_cert_arn_us_east1    = var.acm_certificate_arn
  domain_name              = var.domain_name
  enable_execution_logging = true # AA-272 diagnostic only

  # AA-876 — throttling without the WAF (deferred per S241). Sized from 14 days of execution logs (21/10/2026):
  # busiest second per method — /content 100, other /auth 20, the two login routes 6. Stage default 50/100 per
  # method; logins 3x their peak; /content 3x its peak (TripPlanner cover images).
  stage_throttle_rate_limit    = 50
  stage_throttle_burst_limit   = 100
  login_throttle_rate_limit    = 20
  login_throttle_burst_limit   = 40
  content_throttle_rate_limit  = 300
  content_throttle_burst_limit = 600

  depends_on = [module.alb, aws_api_gateway_account.this]
}
