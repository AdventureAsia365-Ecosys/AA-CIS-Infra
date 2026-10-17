# =============================================================================
# AA-Booking (AAA) — Dev runtime (AA-678, root ADR 0004 decision 5). NEW service, NOT part of AA-CIS.
#
# WHAT THIS FILE ADDS (report for reviewers):
#   AA-Booking is a separate product (repo AdventureAsia365-Ecosys/AA-Booking, FastAPI + asyncpg)
#   that runs in the SAME acc2 (005097885195) VPC, ECS cluster and RDS as AA-CIS (ADR 0001
#   decisions 6-7). Same self-contained pattern as tripplanner.tf: every resource here uses the
#   `aa-booking-<env>-*` name prefix, lives only in this file, and only READS existing module
#   outputs (module.vpc, module.ecs, module.alb). It creates no VPC/subnet/SG/RDS/cluster/ALB.
#
#   Resources:
#     - ECR repo aa-booking-dev-api (immutable git-SHA tags, keep last 10)
#     - log group /ecs/aa-booking-dev
#     - secret booking/dev/database-url: CONTAINER ONLY, no value (Nghiep sets it out-of-band)
#     - execution role + task role (least privilege, see below)
#     - task definition aa-booking-dev-api (placeholder image tag, replaced by the app deploy)
#     - ECS service aa-booking-dev-api on aa-cis-dev-cluster, desired_count 0 at create
#     - ALB target group aa-booking-dev-api-tg (health check /booking/health)
#     - ONE listener rule (/booking, /booking/*) on the existing CIS ALB HTTP listener
#     - REST API aa-booking-dev-api on the existing VPC link (/booking, /booking/{proxy+})
#     - GitHub OIDC deploy role aa-booking-dev-app-deploy, trusted only by AA-Booking
#
#   The ONLY touch on a CIS resource is the new aws_lb_listener_rule on module.alb's HTTP
#   listener (priority 100, path-scoped). The listener's default action (CIS target group) is
#   unchanged, so every non-/booking path still reaches CIS exactly as before.
#
# PREREQUISITE: Infra phase 1 (cicd.tf BookingRoleTagging / BookingEcrRepoManage /
# BookingAlbListenerRuleManage + modules/alb http_listener_arn output) must be APPLIED before this
# file is planned/applied in CI, or CreateRole/CreateRepository/CreateRule are AccessDenied (IAM
# propagation trap, see observability.tf time_sleep.wait_for_iam_propagation).
#
# ROUTING (why a separate REST API):
#   API Gateway REST -> VPC link -> internal NLB :80 -> ALB HTTP :80 -> target group.
#   The CIS REST API (modules/api_gateway) has no catch-all proxy, and both CIS custom domains
#   (api-cis.lumiguides.it.com, api-cis-aa365.lumiguides.it.com) use an EMPTY base path mapping,
#   which API Gateway does not allow to coexist with a second mapping on the same domain. Booking
#   gets its own domain api-booking.lumiguides.it.com in custom_domains.tf (AA-818), gated by
#   var.custom_domains_enabled until the Route 53 NS switch; until then Dev uses this API's default
#   execute-api endpoint.
#
# EXPOSURE: the CIS ALB is internet-facing, but since S235 Phase 0 its security group admits :80
# only from the VPC CIDR (the VPC-link NLB), so /booking/* is reachable only through this REST API.
# The gateway does no auth (authorization NONE, same as CIS): the Booking app must authenticate
# every non-health route.
# =============================================================================

locals {
  bk_name_prefix = "aa-booking-${var.environment}"
  bk_service     = "${local.bk_name_prefix}-api"
  bk_container   = "api"
  bk_port        = 8000

  bk_tags = {
    Project     = "AA-Booking"
    Environment = var.environment
    ManagedBy   = "terraform"
    Service     = "booking"
    App         = "booking" # S235 Phase 0: per-app cost allocation tag (additive)
    Issue       = "AA-678"
  }

  bk_cluster_arn      = module.ecs.cluster_arn
  bk_service_arn      = "arn:aws:ecs:${var.aws_region}:${var.account_id}:service/${module.ecs.cluster_name}/${local.bk_service}"
  bk_task_def_pattern = "arn:aws:ecs:${var.aws_region}:${var.account_id}:task-definition/${local.bk_service}:*"

  # GitHub OIDC subjects for the AA-Booking deploy role. The org has no org-level subject
  # template; the program's repos turn on GitHub's immutable subject at repo level, giving
  #   repo:AdventureAsia365-Ecosys@276539096/<repo>@<repo_id>:<context>
  # (see cicd_split.tf local.oidc_sub_cis_app). AA-Booking does not exist yet, so its repo id is
  # unknown: until var.booking_github_repo_id is set, both the immutable form (any id, exact repo
  # name, pinned org id) and the plain form are accepted. Once the id is set, only the immutable
  # form with that exact id is trusted (fail closed).
  #
  # Contexts: ONLY `environment:dev` (deploy job with `environment: dev`) and
  # `ref:refs/heads/main` (a job without an environment, on main). No pull_request, no other
  # branch, no other environment. Give the AA-Booking `dev` environment a deployment-branch
  # policy of `main` only, otherwise any writer can use `environment: dev` from a branch.
  bk_oidc_contexts = ["environment:dev", "ref:refs/heads/main"]
  bk_oidc_repo_id  = var.booking_github_repo_id != "" ? var.booking_github_repo_id : "*"
  bk_oidc_subjects = concat(
    [for c in local.bk_oidc_contexts : "repo:AdventureAsia365-Ecosys@276539096/AA-Booking@${local.bk_oidc_repo_id}:${c}"],
    var.booking_github_repo_id != "" ? [] : [for c in local.bk_oidc_contexts : "repo:AdventureAsia365-Ecosys/AA-Booking:${c}"],
  )
}

# -----------------------------------------------------------------------------
# ECR. Immutable tags: the app deploy pushes one tag per git SHA (ADR 0004 decision 4), so a tag
# always names exactly one image. This is deliberately NOT the CIS ":latest" convention.
# -----------------------------------------------------------------------------
resource "aws_ecr_repository" "booking" {
  name                 = local.bk_service
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.bk_tags

  # CreateRepository is granted by cicd.tf BookingEcrRepoManage (phase 1).
  depends_on = [time_sleep.wait_for_iam_propagation]
}

resource "aws_ecr_lifecycle_policy" "booking" {
  repository = aws_ecr_repository.booking.name
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
# Logs
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "booking" {
  name              = "/ecs/${local.bk_name_prefix}"
  retention_in_days = 14
  tags              = local.bk_tags
}

# -----------------------------------------------------------------------------
# DB connection secret — CONTAINER ONLY. There is deliberately no aws_secretsmanager_secret_version:
# Terraform never holds the DSN, not even a placeholder. Nghiep puts the value (postgresql DSN for
# role `booking`, sslmode=require) with put-secret-value BEFORE the service is scaled above 0;
# until then a task would fail to start on the missing secret value, which is the intended
# fail-closed behaviour. The `booking` LOGIN password is set out-of-band (bk-001 creates the role
# NOLOGIN).
# -----------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "booking_db" {
  name                    = "booking/${var.environment}/database-url"
  description             = "AA-Booking DB connection string (role booking, schema booking, shared RDS). Value set out-of-band."
  recovery_window_in_days = var.environment == "dev" ? 0 : 30
  tags                    = local.bk_tags
}

# -----------------------------------------------------------------------------
# Execution role (ECS agent): pull this repo's image, write this log group, read this ONE secret.
# AmazonECSTaskExecutionRolePolicy is NOT attached (it grants ECR pull on every repo and logs on
# every group).
# -----------------------------------------------------------------------------
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

resource "aws_iam_role" "booking_ecs_execution" {
  name                 = "${local.bk_name_prefix}-ecs-execution-role"
  permissions_boundary = aws_iam_policy.workload_boundary.arn
  assume_role_policy   = data.aws_iam_policy_document.booking_ecs_tasks_assume.json
  tags                 = local.bk_tags

  # Tagged role -> CreateRole calls iam:TagRole (cicd.tf BookingRoleTagging, phase 1).
  depends_on = [time_sleep.wait_for_iam_propagation]
}

resource "aws_iam_role_policy" "booking_ecs_execution" {
  name = "${local.bk_name_prefix}-ecs-execution"
  role = aws_iam_role.booking_ecs_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # GetAuthorizationToken has no resource-level scoping.
        Sid      = "EcrAuth"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid      = "EcrPullBookingRepo"
        Effect   = "Allow"
        Action   = ["ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"]
        Resource = aws_ecr_repository.booking.arn
      },
      {
        Sid      = "WriteBookingLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.booking.arn}:log-stream:*"
      },
      {
        Sid      = "ReadBookingDbSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.booking_db.arn
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# Task role (the app process). DATABASE_URL is injected by the execution role. Grants: the SSM channel
# for ECS Exec (debugging, same access path as CIS, SSM only) and the exec session log writes below, and SES send as
# var.ses_from_address through the transactional configuration set (ses.tf
# aws_iam_role_policy.booking_ecs_task_ses_send, AA-811), and cloudwatch:PutMetricData into namespace
# AA/Jobs/Booking only (observability_ecosys.tf aws_iam_role_policy.booking_ecs_task_put_metric_jobs,
# the job backlog sampler, AA-751). No Bedrock, no S3, no CIS secrets: add them only when a feature
# needs them.
# -----------------------------------------------------------------------------
resource "aws_iam_role" "booking_ecs_task" {
  name                 = "${local.bk_name_prefix}-ecs-task-role"
  permissions_boundary = aws_iam_policy.workload_boundary.arn
  assume_role_policy   = data.aws_iam_policy_document.booking_ecs_tasks_assume.json
  tags                 = local.bk_tags

  depends_on = [time_sleep.wait_for_iam_propagation]
}

resource "aws_iam_role_policy" "booking_ecs_task" {
  name = "${local.bk_name_prefix}-ecs-task"
  role = aws_iam_role.booking_ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # ECS Exec (enable_execute_command). ssmmessages has no resource-level scoping.
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
        # S241 D-07: the cluster sends ECS Exec session logs to one group (modules/ecs
        # aws_cloudwatch_log_group.exec_sessions, logging OVERRIDE); the SSM agent in the task
        # uploads them with this role. DescribeLogGroups takes no log group ARN (AWS ECS Exec guide).
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
    ]
  })
}

# -----------------------------------------------------------------------------
# Task definition. The image tag `bootstrap` is never pushed: the service starts at
# desired_count 0, and the AA-Booking deploy workflow registers a new revision from this one with
# only containerDefinitions[0].image swapped to <repo>:<git_sha>. ignore_changes on the service's
# task_definition keeps Terraform from reverting that.
#
# Env names read by the app (backend/app/settings.py): DATABASE_URL (secret), DB_SSL, ENVIRONMENT, and the
# AA-811 staff e-mail settings (bk_notify_email job): STAFF_NOTIFY_EMAIL, SES_FROM_ADDRESS (must equal
# var.ses_from_address, the only From the task role may send as, ses.tf), SES_CONFIGURATION_SET (the
# transactional stream of ses.tf), STAFF_ADMIN_URL (links to the staff admin). GIT_SHA is baked into the
# image at build time.
#
# A change here registers a new revision that the service ignores (ignore_changes below); the next
# AA-Booking deploy copies the family's LATEST revision (deploy-dev.yml, AA-811) and carries it to the task.
# -----------------------------------------------------------------------------
resource "aws_ecs_task_definition" "booking" {
  family                   = local.bk_service
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.booking_ecs_execution.arn
  task_role_arn            = aws_iam_role.booking_ecs_task.arn

  container_definitions = jsonencode([{
    name         = local.bk_container
    image        = "${aws_ecr_repository.booking.repository_url}:bootstrap"
    essential    = true
    portMappings = [{ containerPort = local.bk_port, protocol = "tcp" }]
    environment = [
      { name = "ENVIRONMENT", value = var.environment },
      { name = "DB_SSL", value = "require" },
      { name = "STAFF_NOTIFY_EMAIL", value = var.booking_staff_notify_email },
      { name = "SES_FROM_ADDRESS", value = var.ses_from_address },
      { name = "SES_CONFIGURATION_SET", value = aws_sesv2_configuration_set.stream["transactional"].configuration_set_name },
      { name = "STAFF_ADMIN_URL", value = var.booking_staff_admin_url },
    ]
    secrets = [
      { name = "DATABASE_URL", valueFrom = aws_secretsmanager_secret.booking_db.arn },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.booking.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = local.bk_container
      }
    }
    # Liveness only (no DB call, ADR 0004 decision 9). python:3.12-slim has no curl.
    healthCheck = {
      command     = ["CMD-SHELL", "python -c \"import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:${local.bk_port}/booking/health', timeout=4).status == 200 else 1)\""]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 30
    }
    stopTimeout = 30
  }])

  tags = local.bk_tags
}

# -----------------------------------------------------------------------------
# ALB target group + the single listener rule on the CIS ALB's HTTP listener.
# -----------------------------------------------------------------------------
resource "aws_lb_target_group" "booking" {
  name        = "${local.bk_service}-tg"
  port        = local.bk_port
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "ip" # Fargate

  # One small task; 300s (AWS default) would make every deploy wait 5 minutes on draining.
  deregistration_delay = 30

  health_check {
    enabled             = true
    path                = "/booking/health"
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = local.bk_tags
}

resource "aws_lb_listener_rule" "booking" {
  # API Gateway reaches the ALB on :80 through the VPC-link NLB, so the rule goes on the HTTP
  # listener (modules/alb output http_listener_arn, phase 1). The HTTPS listener is untouched.
  listener_arn = module.alb.http_listener_arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.booking.arn
  }

  condition {
    path_pattern {
      values = ["/booking", "/booking/*"]
    }
  }

  tags = local.bk_tags

  # CreateRule is granted by cicd.tf BookingAlbListenerRuleManage (phase 1).
  depends_on = [time_sleep.wait_for_iam_propagation]
}

# -----------------------------------------------------------------------------
# ECS service. desired_count = 0 at create: nothing runs (and nothing is billed) until Nghiep has
# set the DB secret value and the first image is deployed, then scales it to 1 with
# `aws ecs update-service ... --desired-count 1`. ignore_changes keeps Terraform from scaling it
# back to 0 or reverting the app's task definition revision.
# -----------------------------------------------------------------------------
resource "aws_ecs_service" "booking" {
  name            = local.bk_service
  cluster         = module.ecs.cluster_arn
  task_definition = aws_ecs_task_definition.booking.arn
  desired_count   = 0

  # Same strategy as CIS api: the first task on on-demand FARGATE, any extra on Spot.
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

  # Single task: keep it serving while the new one starts.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  health_check_grace_period_seconds = 60

  network_configuration {
    subnets          = module.vpc.private_subnet_ids
    security_groups  = [module.vpc.sg_app_id] # same app-tier SG as CIS: ALB -> app allowed, app -> RDS :5432 allowed
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.booking.arn
    container_name   = local.bk_container
    container_port   = local.bk_port
  }

  enable_execute_command = true

  # AA-828: copy the service tags (local.bk_tags, App = "booking") onto every task, so Fargate cost
  # lands under the App cost allocation tag. SERVICE, not TASK_DEFINITION: deploy-dev.yml registers
  # each revision from `describe-task-definition` output, which carries no tags, so the revisions
  # that run are untagged. In-place UpdateService; it reaches tasks started after the change.
  propagate_tags = "SERVICE"

  lifecycle {
    ignore_changes = [desired_count, task_definition]
  }

  tags = local.bk_tags

  # ECS rejects a service whose target group is not attached to a load balancer yet.
  depends_on = [aws_lb_listener_rule.booking, aws_iam_role_policy.booking_ecs_execution]
}

# -----------------------------------------------------------------------------
# API Gateway — separate REST API on the EXISTING VPC link (module.alb.vpc_link_id -> NLB).
# Routes: ANY /booking and ANY /booking/{proxy+} -> http://<nlb>/booking[/{proxy}]. The path keeps
# its /booking prefix end to end, so the ALB rule above matches it.
# -----------------------------------------------------------------------------
resource "aws_api_gateway_rest_api" "booking" {
  name        = local.bk_service
  description = "AA-Booking Dev API (AA-678). Proxies /booking/* to the shared ALB via the CIS VPC link."
  endpoint_configuration {
    types = ["REGIONAL"]
  }
  tags = local.bk_tags
}

resource "aws_api_gateway_resource" "booking" {
  rest_api_id = aws_api_gateway_rest_api.booking.id
  parent_id   = aws_api_gateway_rest_api.booking.root_resource_id
  path_part   = "booking"
}

resource "aws_api_gateway_resource" "booking_proxy" {
  rest_api_id = aws_api_gateway_rest_api.booking.id
  parent_id   = aws_api_gateway_resource.booking.id
  path_part   = "{proxy+}"
}

resource "aws_api_gateway_method" "booking_any" {
  rest_api_id   = aws_api_gateway_rest_api.booking.id
  resource_id   = aws_api_gateway_resource.booking.id
  http_method   = "ANY"
  authorization = "NONE" # the app authenticates (same model as CIS, AA-750)
}

resource "aws_api_gateway_integration" "booking_any" {
  rest_api_id             = aws_api_gateway_rest_api.booking.id
  resource_id             = aws_api_gateway_resource.booking.id
  http_method             = aws_api_gateway_method.booking_any.http_method
  type                    = "HTTP_PROXY"
  integration_http_method = "ANY"
  connection_type         = "VPC_LINK"
  connection_id           = module.alb.vpc_link_id
  uri                     = "http://${module.alb.nlb_dns_name}/booking"
}

resource "aws_api_gateway_method" "booking_proxy_any" {
  rest_api_id   = aws_api_gateway_rest_api.booking.id
  resource_id   = aws_api_gateway_resource.booking_proxy.id
  http_method   = "ANY"
  authorization = "NONE"

  request_parameters = {
    "method.request.path.proxy" = true
  }
}

resource "aws_api_gateway_integration" "booking_proxy_any" {
  rest_api_id             = aws_api_gateway_rest_api.booking.id
  resource_id             = aws_api_gateway_resource.booking_proxy.id
  http_method             = aws_api_gateway_method.booking_proxy_any.http_method
  type                    = "HTTP_PROXY"
  integration_http_method = "ANY"
  connection_type         = "VPC_LINK"
  connection_id           = module.alb.vpc_link_id
  uri                     = "http://${module.alb.nlb_dns_name}/booking/{proxy}"

  request_parameters = {
    "integration.request.path.proxy" = "method.request.path.proxy"
  }
}

resource "aws_api_gateway_deployment" "booking" {
  rest_api_id = aws_api_gateway_rest_api.booking.id

  # A stage serves a frozen deployment snapshot: hash every route/integration attribute so any
  # change forces a new deployment (the CIS AA-432/AA-465 trap).
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.booking.id,
      aws_api_gateway_resource.booking_proxy.id,
      aws_api_gateway_method.booking_any.id,
      aws_api_gateway_method.booking_any.authorization,
      aws_api_gateway_method.booking_proxy_any.id,
      aws_api_gateway_method.booking_proxy_any.authorization,
      aws_api_gateway_integration.booking_any.uri,
      aws_api_gateway_integration.booking_any.connection_id,
      aws_api_gateway_integration.booking_any.timeout_milliseconds,
      aws_api_gateway_integration.booking_proxy_any.uri,
      aws_api_gateway_integration.booking_proxy_any.connection_id,
      aws_api_gateway_integration.booking_proxy_any.timeout_milliseconds,
    ]))
  }

  depends_on = [
    aws_api_gateway_integration.booking_any,
    aws_api_gateway_integration.booking_proxy_any,
  ]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "booking" {
  rest_api_id   = aws_api_gateway_rest_api.booking.id
  deployment_id = aws_api_gateway_deployment.booking.id
  stage_name    = var.environment
  tags          = local.bk_tags

  # Stage tagging (provider default_tags) — same propagation guard as tripplanner.tf.
  depends_on = [time_sleep.wait_for_iam_propagation]
}

# Unauthenticated edge: cap the stage so a scan cannot run up the shared ALB/RDS. Throttling only
# (no execution logging, which needs nothing new but is not wanted for Dev).
resource "aws_api_gateway_method_settings" "booking_throttle" {
  rest_api_id = aws_api_gateway_rest_api.booking.id
  stage_name  = aws_api_gateway_stage.booking.stage_name
  method_path = "*/*"

  settings {
    throttling_rate_limit  = 20
    throttling_burst_limit = 40
  }
}

# -----------------------------------------------------------------------------
# App deploy role — assumed via GitHub OIDC by AA-Booking's deploy workflow ONLY. Least privilege:
# push to this ECR repo, register revisions of THIS task family, point THIS service at them, wait
# for it and read back the running image. Separate from the broad aa-cis-dev-role (retired in
# AA-806 step 3), which AA-Booking never received.
# -----------------------------------------------------------------------------
resource "aws_iam_role" "booking_app_deploy" {
  name                 = "${local.bk_name_prefix}-app-deploy"
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
          "token.actions.githubusercontent.com:sub" = local.bk_oidc_subjects
        }
      }
    }]
  })

  tags = local.bk_tags

  depends_on = [time_sleep.wait_for_iam_propagation]
}

resource "aws_iam_role_policy" "booking_app_deploy" {
  name = "${local.bk_name_prefix}-app-deploy-policy"
  role = aws_iam_role.booking_app_deploy.id

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
        Sid    = "EcrPushBookingRepo"
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
        Resource = aws_ecr_repository.booking.arn
      },
      {
        # Read-only; DescribeTaskDefinition has no resource-level scoping.
        Sid      = "EcsDescribeTaskDefinition"
        Effect   = "Allow"
        Action   = ["ecs:DescribeTaskDefinition"]
        Resource = "*"
      },
      {
        # RegisterTaskDefinition IS resource-scoped (task-definition/<family>:<rev>), so this role
        # can only add revisions to the Booking family. It must never write a revision into the
        # CIS families: CIS deploy-dev copies the LATEST revision of aa-cis-dev-api/-worker.
        Sid      = "EcsRegisterBookingTaskDefinition"
        Effect   = "Allow"
        Action   = ["ecs:RegisterTaskDefinition"]
        Resource = local.bk_task_def_pattern
      },
      {
        # Only if the workflow registers with tags.
        Sid      = "EcsTagOnRegister"
        Effect   = "Allow"
        Action   = ["ecs:TagResource"]
        Resource = local.bk_task_def_pattern
        Condition = {
          StringEquals = { "ecs:CreateAction" = "RegisterTaskDefinition" }
        }
      },
      {
        Sid      = "EcsDescribeBookingService"
        Effect   = "Allow"
        Action   = ["ecs:DescribeServices"]
        Resource = local.bk_service_arn
      },
      {
        # The service can only be pointed at a Booking task definition. IfExists: a call that
        # changes only the desired count carries no task definition. Pass the full ARN returned by
        # register-task-definition (the CIS workflow does the same).
        Sid      = "EcsUpdateBookingService"
        Effect   = "Allow"
        Action   = ["ecs:UpdateService"]
        Resource = local.bk_service_arn
        Condition = {
          StringLikeIfExists = {
            "ecs:task-definition" = [local.bk_task_def_pattern, "${local.bk_service}:*"]
          }
        }
      },
      {
        # Post-deploy check: running task image == commit SHA.
        Sid      = "EcsListTasksInCluster"
        Effect   = "Allow"
        Action   = ["ecs:ListTasks"]
        Resource = "*"
        Condition = {
          ArnEquals = { "ecs:cluster" = local.bk_cluster_arn }
        }
      },
      {
        Sid      = "EcsDescribeTasksInCluster"
        Effect   = "Allow"
        Action   = ["ecs:DescribeTasks"]
        Resource = "arn:aws:ecs:${var.aws_region}:${var.account_id}:task/${module.ecs.cluster_name}/*"
      },
      {
        # Registering a task definition that names these roles requires PassRole on them.
        Sid    = "PassBookingTaskRoles"
        Effect = "Allow"
        Action = ["iam:PassRole"]
        Resource = [
          aws_iam_role.booking_ecs_execution.arn,
          aws_iam_role.booking_ecs_task.arn,
        ]
        Condition = {
          StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" }
        }
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# Outputs (values for the AA-Booking `dev` environment; names only, no secrets).
# -----------------------------------------------------------------------------
output "booking_app_deploy_role_arn" {
  value = aws_iam_role.booking_app_deploy.arn
}

output "booking_ecr_repository_url" {
  value = aws_ecr_repository.booking.repository_url
}

output "booking_ecs_service_name" {
  value = aws_ecs_service.booking.name
}

output "booking_task_definition_family" {
  value = aws_ecs_task_definition.booking.family
}

output "booking_api_base_url" {
  description = "Dev base URL; health = <this>/booking/health and <this>/booking/health/ready."
  value       = aws_api_gateway_stage.booking.invoke_url
}

output "booking_database_url_secret_arn" {
  value = aws_secretsmanager_secret.booking_db.arn
}
