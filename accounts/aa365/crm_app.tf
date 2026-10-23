# =============================================================================
# AA-933 (CRM-05) — AA-Partner (partner CRM) API runtime on Dev: image repo, ECS service, deploy role.
#
# Repo AdventureAsia365-Ecosys/AA-Partner (public), root ADR 0010 decisions 1-3, design v3 §6.3 card CRM-05. Same
# self-contained pattern as booking.tf: every resource uses the CRM naming contract of cicd_crm.tf (aa-crm-<env>-*,
# tag App = "crm"), lives in this file (plus the security group in app_security_groups.tf and the job alarms in
# observability_ecosys.tf) and only READS module outputs. No VPC / subnet / RDS / cluster / ALB / NLB is created.
#
#   Resources:
#     - ECR repo aa-crm-dev-api (IMMUTABLE, one tag per git SHA, scan on push, keep last 10)
#     - log group /ecs/aa-crm-dev (30 days, AA-872)
#     - secret shell crm/dev/sentry-dsn (no value; the DSN secret crm/dev/database-url is crm_data.tf, AA-932)
#     - execution role aa-crm-dev-ecs-execution-role: pull this repo, write this log group, read the two secrets
#     - task role aa-crm-dev-ecs-task-role (the name the AA-932 KMS key policies already trust): ECS Exec channel,
#       exec session logs, PutMetricData into AA/Jobs/Crm only. No KMS, S3 or SES grant yet: the cards that use
#       them add them (CRM-06 KeyProvider, CRM-12 audit, CRM-17 mail).
#     - task definition aa-crm-dev-api (Fargate ARM64, 0.25 vCPU / 0.5 GB, placeholder tag `bootstrap`)
#     - ALB target group aa-crm-dev-api-tg (health /crm/health) + ONE listener rule on the HTTP listener:
#       Host = the partner host AND X-AA-Origin = the CloudFront secret AND path /crm or /crm/*  (alb_rules.tf crm_api,
#       above crm_partner_default, so /crm/* reaches the API and every other path of the host gets the fixed 404 JSON
#       of crm_edge.tf until the CRM web (AA-935) takes the host's default)
#     - ECS service aa-crm-dev-api on aa-cis-dev-cluster, desired_count 0 at create
#     - GitHub OIDC deploy role aa-crm-dev-app-deploy, trusted only by AA-Partner (immutable subject with the repo id)
#     - alarms: target group no healthy / unhealthy target, CPU (job backlog alarms: observability_ecosys.tf)
#
# Routing: viewer -> CloudFront partner-dev. -> VPC origin -> internal NLB -> ALB :80 (crm_edge.tf). The API is
# reachable ONLY through CloudFront: the rule needs the secret origin header, and the API Gateway path (no header) has
# no /crm rule, so /crm/* from API Gateway falls to the CIS default action, which has no /crm route (404). Every route
# except /crm/health* and the deploy gate authenticates in the app (route classes, ADR 0006b decision 6).
#
# Order of applies: AA-931 (cicd_crm.tf grants, edge) and AA-932 (crm_data.tf: DSN secret, keys) first. This file
# reads aws_secretsmanager_secret.crm_db and local.crm_task_role_name from crm_data.tf. The apply role already has every
# verb needed (cicd_crm.tf CrmEcrRepoManage; IAMRoleManage on aa-*-<env>-* roles; ELB / ECS / logs / EC2 SG grants
# used by booking.tf and crm_edge.tf), so no bootstrap MFA apply is needed.
#
# Cost (us-west-1, est., D-19): $0 at desired 0 (ECR storage < 1 GB of images ~ $0.05/month, log group cents,
# Sentry secret shell $0.40/month, 3 alarms here + 3 job alarms x $0.10 = $0.60/month). At desired 1: Fargate ARM64
# 0.25 vCPU / 0.5 GB ~ $7.2/month on demand (the first task runs on FARGATE, like Booking); CloudFront / NLB / ALB
# traffic at Dev volume < $0.10/month. Total ~ $1/month idle, ~ $8.3/month with one task around the clock.
# =============================================================================

variable "crm_github_repo_id" {
  description = "AA-933: numeric GitHub repository id of AdventureAsia365-Ecosys/AA-Partner (`gh api repos/AdventureAsia365-Ecosys/AA-Partner --jq .id`). Set: the deploy role trusts only the immutable OIDC subject with this exact id. Empty: any id with the exact repo name (fail open to the name only — keep it set)."
  type        = string
  default     = ""

  validation {
    condition     = var.crm_github_repo_id == "" || can(regex("^[0-9]+$", var.crm_github_repo_id))
    error_message = "crm_github_repo_id must be empty or a numeric GitHub repository id."
  }
}

variable "crm_sentry_enabled" {
  description = "AA-933: map secret crm/<env>/sentry-dsn into the AA-Partner task (SENTRY_DSN) and set SENTRY_REQUIRED=true. Turn on only AFTER the secret has a value (Sentry project aa-partner-api): a task whose secret has no value fails to start."
  type        = bool
  default     = false
}

locals {
  crm_service   = "${local.crm_name_prefix}-api"
  crm_container = "api"
  crm_port      = 8000

  crm_app_tags = merge(local.crm_tags, { Service = "crm", Issue = "AA-933" })

  crm_cluster_arn      = module.ecs.cluster_arn
  crm_service_arn      = "arn:aws:ecs:${var.aws_region}:${var.account_id}:service/${module.ecs.cluster_name}/${local.crm_service}"
  crm_task_def_pattern = "arn:aws:ecs:${var.aws_region}:${var.account_id}:task-definition/${local.crm_service}:*"

  # GitHub OIDC subjects (same model as booking.tf): AA-Partner turns on GitHub's immutable subject at repo level
  #   repo:AdventureAsia365-Ecosys@276539096/AA-Partner@<repo_id>:<context>
  # Context: ONLY environment:dev. Every deploy-dev.yml job runs with `environment: dev`, so no ref subject is needed;
  # trusting ref:refs/heads/main as well (as booking.tf does) would let any future job on main with id-token: write
  # but no environment assume this role past the environment's protection rules (AA-933 review round). The
  # AA-Partner `dev` environment must exist with a deployment-branch policy of main only BEFORE this role is applied:
  # otherwise a branch job naming `environment: dev` auto-creates an unprotected environment with this subject.
  crm_oidc_contexts = ["environment:dev"]
  crm_oidc_repo_id  = var.crm_github_repo_id != "" ? var.crm_github_repo_id : "*"
  crm_oidc_subjects = concat(
    [for c in local.crm_oidc_contexts : "repo:AdventureAsia365-Ecosys@276539096/AA-Partner@${local.crm_oidc_repo_id}:${c}"],
    var.crm_github_repo_id != "" ? [] : [for c in local.crm_oidc_contexts : "repo:AdventureAsia365-Ecosys/AA-Partner:${c}"],
  )

  # Identity values of the route classes (AA-Partner api/app/settings.py; ADR 0006b decision 6). Public values
  # (issuer URLs, client ids), never secrets. The repo is public, so they live only here (DM-6.10). Classes whose pool
  # or client does not exist yet stay empty = the class accepts nothing (fail closed): the PARTNER pool and the
  # AA-Partner web client (AA-939), the crm-staff WORKFORCE client (CRM-13b). The EXTERNAL cis-portal bridge is the
  # Dev-only stand-in for partner sign-in until AA-939 (the app refuses it outside dev / test / local).
  crm_identity_env = [
    { name = "COGNITO_WORKFORCE_ISSUER", value = "https://${aws_cognito_user_pool.workforce.endpoint}" },
    { name = "COGNITO_CIS_ADMIN_CLIENT_ID", value = aws_cognito_user_pool_client.workforce["cis-admin"].id },
    { name = "COGNITO_BREAKGLASS_CLIENT_ID", value = aws_cognito_user_pool_client.workforce["breakglass"].id },
    { name = "COGNITO_CRM_STAFF_CLIENT_ID", value = "" },
    { name = "COGNITO_PARTNER_ISSUER", value = "" },
    { name = "COGNITO_PARTNER_WEB_CLIENT_ID", value = "" },
    { name = "COGNITO_EXTERNAL_ISSUER", value = "https://${aws_cognito_user_pool.external.endpoint}" },
    { name = "COGNITO_CIS_PORTAL_CLIENT_ID", value = aws_cognito_user_pool_client.external["cis-portal"].id },
  ]
}

# -----------------------------------------------------------------------------
# ECR. Immutable tags: the AA-Partner deploy pushes one tag per git SHA (as Booking, ADR 0004 decision 4).
# -----------------------------------------------------------------------------
resource "aws_ecr_repository" "crm_api" {
  name                 = local.crm_service
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.crm_app_tags

  # CreateRepository: cicd_crm.tf CrmEcrRepoManage (aa-crm-<env>-*).
  depends_on = [time_sleep.wait_for_iam_propagation]
}

resource "aws_ecr_lifecycle_policy" "crm_api" {
  repository = aws_ecr_repository.crm_api.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

# -----------------------------------------------------------------------------
# Logs + Sentry DSN secret shell (same rule as booking_sentry_dsn: no secret_version, Terraform never holds the DSN;
# the CIS task role is denied crm/* by modules/ecs, AA-932).
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "crm_api" {
  name              = "/ecs/${local.crm_name_prefix}"
  retention_in_days = 30 # AA-872 (S241 D-09): app logs 30 days
  tags              = local.crm_app_tags
}

resource "aws_secretsmanager_secret" "crm_sentry_dsn" {
  name                    = "crm/${var.environment}/sentry-dsn"
  description             = "AA-Partner Sentry DSN (project aa-partner-api), SENTRY_DSN of the api + crm.job worker. Value set out-of-band."
  recovery_window_in_days = var.environment == "dev" ? 0 : 30
  tags                    = local.crm_app_tags
}

# -----------------------------------------------------------------------------
# Execution role (ECS agent): pull this repo's image, write this log group, read the two CRM secrets only.
# AmazonECSTaskExecutionRolePolicy is NOT attached (ECR pull on every repo, logs on every group).
# -----------------------------------------------------------------------------
resource "aws_iam_role" "crm_ecs_execution" {
  name                 = "${local.crm_name_prefix}-ecs-execution-role"
  permissions_boundary = aws_iam_policy.workload_boundary.arn
  assume_role_policy   = data.aws_iam_policy_document.booking_ecs_tasks_assume.json # ecs-tasks, this account only
  tags                 = local.crm_app_tags

  depends_on = [time_sleep.wait_for_iam_propagation]
}

resource "aws_iam_role_policy" "crm_ecs_execution" {
  name = "${local.crm_name_prefix}-ecs-execution"
  role = aws_iam_role.crm_ecs_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrAuth" # GetAuthorizationToken has no resource-level scoping
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid      = "EcrPullCrmRepo"
        Effect   = "Allow"
        Action   = ["ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"]
        Resource = aws_ecr_repository.crm_api.arn
      },
      {
        Sid      = "WriteCrmLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.crm_api.arn}:log-stream:*"
      },
      {
        # crm_data.tf (AA-932) names this role as the DSN secret's only runtime reader.
        Sid      = "ReadCrmSecrets"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.crm_db.arn, aws_secretsmanager_secret.crm_sentry_dsn.arn]
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# Task role (the app process). The name is fixed by crm_data.tf (local.crm_task_role_name): the AA-932 key policies
# already allow crypto use to exactly this role ARN (aws:PrincipalArn), so creating it changes no key policy.
# -----------------------------------------------------------------------------
resource "aws_iam_role" "crm_ecs_task" {
  name                 = local.crm_task_role_name
  permissions_boundary = aws_iam_policy.workload_boundary.arn
  assume_role_policy   = data.aws_iam_policy_document.booking_ecs_tasks_assume.json
  tags                 = local.crm_app_tags

  depends_on = [time_sleep.wait_for_iam_propagation]
}

resource "aws_iam_role_policy" "crm_ecs_task" {
  name = "${local.crm_name_prefix}-ecs-task"
  role = aws_iam_role.crm_ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # ECS Exec (enable_execute_command; SSM only, never SSH). ssmmessages has no resource-level scoping.
        Sid    = "EcsExecSsmChannel"
        Effect = "Allow"
        Action = [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel",
        ]
        Resource = "*"
      },
      {
        # S241 D-07: ECS Exec session logs go to the cluster's one group (modules/ecs). DescribeLogGroups takes no ARN.
        Sid      = "EcsExecSessionLogDescribeGroups"
        Effect   = "Allow"
        Action   = ["logs:DescribeLogGroups"]
        Resource = "*"
      },
      {
        Sid      = "EcsExecSessionLogWrite"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:DescribeLogStreams", "logs:PutLogEvents"]
        Resource = "${module.ecs.exec_session_log_group_arn}:*"
      },
      {
        # crm.job backlog sampler (AA-Partner api/app/jobs/metrics.py): its own namespace only (AA-751 model).
        Sid       = "PutMetricDataCrmJobs"
        Effect    = "Allow"
        Action    = "cloudwatch:PutMetricData"
        Resource  = "*"
        Condition = { StringEquals = { "cloudwatch:namespace" = "AA/Jobs/Crm" } }
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# Task definition. The tag `bootstrap` is never pushed: the service starts at desired_count 0 and the AA-Partner
# deploy registers a revision copied from the family's LATEST revision with only the image swapped
# (.github/workflows/deploy-dev.yml). ignore_changes on the service keeps Terraform from reverting it; a change here
# reaches the task on the next deploy.
#
# Env names read by the app (api/app/settings.py): DATABASE_URL (secret, role crm_app), DB_SSL, ENVIRONMENT,
# WORKER_ENABLED, JOB_RETENTION_DRY_RUN (DM-7.2: counts only until a human turns it off), RATE_LIMIT_PUBLIC_PER_MINUTE,
# RATE_LIMIT_XFF_HOPS (2 = CloudFront viewer address appended, then the NLB's; verify on the first live request),
# SENTRY_DSN / SENTRY_REQUIRED (only with var.crm_sentry_enabled), the identity values (local.crm_identity_env).
# GIT_SHA and APP_VERSION are baked into the image.
# -----------------------------------------------------------------------------
resource "aws_ecs_task_definition" "crm_api" {
  family                   = local.crm_service
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.crm_ecs_execution.arn
  task_role_arn            = aws_iam_role.crm_ecs_task.arn

  # ADR 0010 decision 2: ARM64 (Graviton). The image is built natively on an arm64 runner.
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([{
    name         = local.crm_container
    image        = "${aws_ecr_repository.crm_api.repository_url}:bootstrap"
    essential    = true
    portMappings = [{ containerPort = local.crm_port, protocol = "tcp" }]
    environment = concat([
      { name = "ENVIRONMENT", value = var.environment },
      { name = "DB_SSL", value = "require" },
      { name = "WORKER_ENABLED", value = "true" },
      { name = "JOB_RETENTION_DRY_RUN", value = "true" },
      { name = "RATE_LIMIT_PUBLIC_PER_MINUTE", value = "60" },
      { name = "RATE_LIMIT_XFF_HOPS", value = "2" },
      ], local.crm_identity_env, var.crm_sentry_enabled ? [
      { name = "SENTRY_REQUIRED", value = "true" },
    ] : [])
    secrets = concat([
      { name = "DATABASE_URL", valueFrom = aws_secretsmanager_secret.crm_db.arn },
      ], var.crm_sentry_enabled ? [
      { name = "SENTRY_DSN", valueFrom = aws_secretsmanager_secret.crm_sentry_dsn.arn },
    ] : [])
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.crm_api.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = local.crm_container
      }
    }
    # Liveness only (no DB call). The image has no curl.
    healthCheck = {
      command     = ["CMD-SHELL", "python -c \"import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:${local.crm_port}/crm/health', timeout=4).status == 200 else 1)\""]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 30
    }
    stopTimeout = 30 # the worker releases its claimed job on SIGTERM
  }])

  tags = local.crm_app_tags
}

# -----------------------------------------------------------------------------
# ALB target group + the CloudFront-path rule (priority: alb_rules.tf crm_api; order checked by alb_rule_order.py).
# -----------------------------------------------------------------------------
resource "aws_lb_target_group" "crm_api" {
  name                 = "${local.crm_service}-tg"
  port                 = local.crm_port
  protocol             = "HTTP"
  vpc_id               = module.vpc.vpc_id
  target_type          = "ip" # Fargate
  deregistration_delay = 30

  health_check {
    enabled             = true
    path                = "/crm/health"
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = local.crm_app_tags
}

resource "aws_lb_listener_rule" "crm_api" {
  count = local.crm_edge_on

  listener_arn = module.alb.http_listener_arn
  priority     = local.alb_http_rule_priorities.crm_api

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.crm_api.arn
  }

  condition {
    host_header {
      values = [local.crm_partner_host]
    }
  }

  condition {
    http_header {
      http_header_name = local.alb_origin_header_name
      values           = [random_password.crm_origin_verify[0].result]
    }
  }

  condition {
    path_pattern {
      values = ["/crm", "/crm/*"]
    }
  }

  tags = local.crm_app_tags

  depends_on = [time_sleep.wait_for_iam_propagation]
}

# -----------------------------------------------------------------------------
# ECS service. desired_count 0 at create: nothing runs until the crm_app DSN is set, crm-001 / crm-002 are applied and
# the first image is deployed; then `aws ecs update-service ... --desired-count 1` (a separate step). ignore_changes
# keeps Terraform from scaling it back or reverting the deployed revision.
# -----------------------------------------------------------------------------
resource "aws_ecs_service" "crm_api" {
  name            = local.crm_service
  cluster         = module.ecs.cluster_arn
  task_definition = aws_ecs_task_definition.crm_api.arn
  desired_count   = 0

  # Same as Booking: the first task on on-demand FARGATE (the worker holds job leases), any extra on Spot.
  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 1
  }
  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 3
    base              = 0
  }

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  health_check_grace_period_seconds = local.crm_edge_on == 1 ? 60 : null

  network_configuration {
    subnets          = module.vpc.private_subnet_ids
    security_groups  = [aws_security_group.crm_api.id] # ADR 0004b: own group, ALB -> 8000, admitted by RDS
    assign_public_ip = false
  }

  # Without the edge there is no rule in front of the target group, and ECS rejects a target group that is not
  # attached to a load balancer.
  dynamic "load_balancer" {
    for_each = local.crm_edge_on == 1 ? [1] : []
    content {
      target_group_arn = aws_lb_target_group.crm_api.arn
      container_name   = local.crm_container
      container_port   = local.crm_port
    }
  }

  enable_execute_command = true

  # App = crm on every task (cost allocation, DM-10.1). SERVICE, not TASK_DEFINITION: the deploy registers untagged
  # revisions (AA-828, as Booking).
  propagate_tags = "SERVICE"

  lifecycle {
    ignore_changes = [desired_count, task_definition]
  }

  tags = local.crm_app_tags

  depends_on = [aws_lb_listener_rule.crm_api, aws_iam_role_policy.crm_ecs_execution]
}

# -----------------------------------------------------------------------------
# App deploy role — assumed via GitHub OIDC by AA-Partner's Deploy Dev workflow ONLY. Least privilege (booking.tf
# booking_app_deploy): push to this repo, register revisions of THIS family, point THIS service at them, read the
# service's task counts (the deploy job guard) and the running image.
# -----------------------------------------------------------------------------
resource "aws_iam_role" "crm_app_deploy" {
  name                 = "${local.crm_name_prefix}-app-deploy"
  permissions_boundary = aws_iam_policy.workload_boundary.arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github_actions.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = local.crm_oidc_subjects
        }
      }
    }]
  })

  tags = local.crm_app_tags

  depends_on = [time_sleep.wait_for_iam_propagation]
}

resource "aws_iam_role_policy" "crm_app_deploy" {
  name = "${local.crm_name_prefix}-app-deploy-policy"
  role = aws_iam_role.crm_app_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrAuth"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "EcrPushCrmRepo"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:DescribeImages",
          "ecr:DescribeRepositories",
        ]
        Resource = aws_ecr_repository.crm_api.arn
      },
      {
        Sid      = "EcsDescribeTaskDefinition" # read-only, no resource-level scoping
        Effect   = "Allow"
        Action   = ["ecs:DescribeTaskDefinition"]
        Resource = "*"
      },
      {
        # Resource-scoped: this role can add revisions to the CRM family only, never to the CIS / Booking families
        # (their deploys copy their family's LATEST revision).
        Sid      = "EcsRegisterCrmTaskDefinition"
        Effect   = "Allow"
        Action   = ["ecs:RegisterTaskDefinition"]
        Resource = local.crm_task_def_pattern
      },
      {
        Sid      = "EcsTagOnRegister"
        Effect   = "Allow"
        Action   = ["ecs:TagResource"]
        Resource = local.crm_task_def_pattern
        Condition = {
          StringEquals = { "ecs:CreateAction" = "RegisterTaskDefinition" }
        }
      },
      {
        # Also the deploy job guard (.github/scripts/partner-deploy-preflight.sh: running / pending / desired counts).
        Sid      = "EcsDescribeCrmService"
        Effect   = "Allow"
        Action   = ["ecs:DescribeServices"]
        Resource = local.crm_service_arn
      },
      {
        # Only a CRM task definition. IfExists: a desired-count-only call carries none (the workflow never makes one).
        Sid      = "EcsUpdateCrmService"
        Effect   = "Allow"
        Action   = ["ecs:UpdateService"]
        Resource = local.crm_service_arn
        Condition = {
          StringLikeIfExists = {
            "ecs:task-definition" = [local.crm_task_def_pattern, "${local.crm_service}:*"]
          }
        }
      },
      {
        Sid      = "EcsListTasksInCluster"
        Effect   = "Allow"
        Action   = ["ecs:ListTasks"]
        Resource = "*"
        Condition = {
          ArnEquals = { "ecs:cluster" = local.crm_cluster_arn }
        }
      },
      {
        Sid      = "EcsDescribeTasksInCluster"
        Effect   = "Allow"
        Action   = ["ecs:DescribeTasks"]
        Resource = "arn:aws:ecs:${var.aws_region}:${var.account_id}:task/${module.ecs.cluster_name}/*"
      },
      {
        Sid    = "PassCrmTaskRoles"
        Effect = "Allow"
        Action = ["iam:PassRole"]
        Resource = [
          aws_iam_role.crm_ecs_execution.arn,
          aws_iam_role.crm_ecs_task.arn,
        ]
        Condition = {
          StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" }
        }
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# Service health alarms (Booking pattern, observability_ecosys.tf). Container Insights is off on the cluster, so the
# target group metrics are the signal. Missing data does not alarm: desired 0 (the normal Dev state) stays quiet.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "crm_no_healthy_task" {
  count = local.crm_edge_on

  alarm_name          = "${local.crm_name_prefix}-no-healthy-task"
  alarm_description   = "AA-Partner target group ${aws_lb_target_group.crm_api.name} has no healthy target for 5 minutes (service down or failing /crm/health).${local.runbook_suffix.api_5xx}"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  dimensions          = { TargetGroup = aws_lb_target_group.crm_api.arn_suffix, LoadBalancer = module.alb.alb_arn_suffix }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 5
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = merge(local.ecosys_tags, { App = "crm" })
}

resource "aws_cloudwatch_metric_alarm" "crm_unhealthy_hosts" {
  count = local.crm_edge_on

  alarm_name          = "${local.crm_name_prefix}-unhealthy-hosts"
  alarm_description   = "AA-Partner target group ${aws_lb_target_group.crm_api.name} has an unhealthy target for 5 minutes in a row.${local.runbook_suffix.api_5xx}"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  dimensions          = { TargetGroup = aws_lb_target_group.crm_api.arn_suffix, LoadBalancer = module.alb.alb_arn_suffix }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = merge(local.ecosys_tags, { App = "crm" })
}

resource "aws_cloudwatch_metric_alarm" "crm_cpu_high" {
  alarm_name          = "${local.crm_name_prefix}-cpu-high"
  alarm_description   = "AA-Partner ECS service ${local.crm_service} CPU above 85% for 15 minutes.${local.runbook_suffix.api_5xx}"
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  dimensions          = { ClusterName = module.ecs.cluster_name, ServiceName = aws_ecs_service.crm_api.name }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = 85
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = merge(local.ecosys_tags, { App = "crm" })
}

# -----------------------------------------------------------------------------
# Outputs (values for the AA-Partner `dev` environment variables; names only, no secrets).
# -----------------------------------------------------------------------------
output "crm_app_deploy_role_arn" {
  description = "AA-933: AWS_ROLE_ARN of the AA-Partner GitHub environment dev."
  value       = aws_iam_role.crm_app_deploy.arn
}

output "crm_ecr_repository_url" {
  value = aws_ecr_repository.crm_api.repository_url
}

output "crm_ecs_service_name" {
  value = aws_ecs_service.crm_api.name
}

output "crm_task_definition_family" {
  value = aws_ecs_task_definition.crm_api.family
}

output "crm_api_base_url" {
  description = "AA-933: CRM_API_BASE_URL of the AA-Partner dev environment; health = <this>/crm/health and /crm/health/ready."
  value       = "https://${local.crm_partner_host}"
}
