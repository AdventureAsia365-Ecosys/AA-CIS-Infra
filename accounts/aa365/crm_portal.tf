# =============================================================================
# AA-979 (CRM-P2b) — the tenant Content studio (AA-Partner `portal/`, Next.js standalone) on Fargate, behind the agency
# host portal.<zone>. Root ADR 0010 §2 / §6, ADR 0010a; design S252 `.tmp-session/s252/aa979/design.md` §2.5.
#
# Same self-contained pattern as crm_web.tf: CRM naming contract (aa-crm-<env>-*, tag App = "crm"), resources here
# plus the security group in app_security_groups.tf, the host rules and distribution in crm_agency_edge.tf, the
# deploy-role grants in crm_app.tf.
#
#   Resources:
#     - ECR repo aa-crm-dev-portal (IMMUTABLE, one tag per git SHA, scan on push, keep last 10)
#     - secret shell crm/dev/portal-sentry-dsn (NO secret_version; mapped only with crm_portal_sentry_enabled)
#     - execution role aa-crm-dev-portal-ecs-execution-role: pull this repo, write the CRM log group (stream prefix
#       `portal`, Q8: the shared /ecs/aa-crm-dev group, 30 days), read crm/dev/web (only its session_secret JSON key is
#       mapped: the portal reads the CRM web session READ ONLY, Q2; IAM cannot scope to a JSON key, so this role can
#       read the whole secret, accepted for Dev, see the design) and the portal Sentry DSN
#     - task role aa-crm-dev-portal-ecs-task-role: ECS Exec channel + exec session logs only (no AWS API)
#     - task definition aa-crm-dev-portal (Fargate ARM64, 0.25 vCPU / 0.5 GB, port 3000, placeholder tag `bootstrap`)
#     - ALB target group aa-crm-dev-portal-tg (health /healthz)
#     - ECS service aa-crm-dev-portal, desired_count 0 at create, FARGATE_SPOT (Q13: a Spot interruption is a 1-2 min
#       studio 503 on Dev, accepted)
#     - alarms: no healthy target, unhealthy target, target 5xx > 5 in 5 min
#
# The portal is UI only (ADR 0010 §7): it calls the CIS API server to server (API_URL, egress via the NAT instance),
# never the crm schema or /crm/*. Its sign-in reads the CRM web's sealed session cookie on the same host (read only)
# and exchanges the partner-pool access token at CIS POST /auth/tenant-session. During the P2b window the API-key
# sign-in stays on (PORTAL_API_KEY_SIGNIN, crm_portal_api_key_signin).
#
# Order: this apply (desired 0) -> the AA-Partner portal PR merges -> Deploy Portal Dev pushes the first image ->
# scale 0 -> 1 -> pre-cutover smoke with --resolve (crm_agency_edge.tf). Nothing here changes what users see while
# crm_agency_live = false (the portal. CNAME still points at Vercel).
#
# Cost (us-west-1, est., D-19): $0 compute at desired 0; at desired 1 FARGATE_SPOT ARM64 0.25 vCPU / 0.5 GB ~ $2.2/month
# (on demand ~ $7.2); ECR < $0.05; Sentry DSN secret $0.40; 3 alarms $0.30; logs < $0.10; NAT egress to CIS < $0.10.
# ~ $0.85/month idle, ~ $3.1/month running.
# =============================================================================

variable "crm_portal_sentry_enabled" {
  description = "AA-979: map secret crm/<env>/portal-sentry-dsn into the portal task (SENTRY_DSN). Turn on only AFTER the secret has a value (Sentry project aa-partner-portal): a task whose secret has no value fails to start."
  type        = bool
  default     = false
}

variable "crm_portal_api_key_signin" {
  description = "AA-979 (Q3): keep the Content studio's tenant API-key sign-in (/tenant-login) during the P2b window. false at clean-up (P2b + 7 days); machines keep X-API-Key on the CIS API either way."
  type        = bool
  default     = true
}

locals {
  crm_portal_service   = "${local.crm_name_prefix}-portal"
  crm_portal_container = "portal"
  crm_portal_port      = 3000

  crm_portal_tags = merge(local.crm_tags, { Service = "crm-portal", Issue = "AA-979" })

  crm_portal_service_arn      = "arn:aws:ecs:${var.aws_region}:${var.account_id}:service/${module.ecs.cluster_name}/${local.crm_portal_service}"
  crm_portal_task_def_pattern = "arn:aws:ecs:${var.aws_region}:${var.account_id}:task-definition/${local.crm_portal_service}:*"

  # Env names read by the portal (AA-Partner portal/lib/config.ts). Public values only.
  crm_portal_env = [
    { name = "ENVIRONMENT", value = var.environment },
    # The CIS API (server to server; the same base the Vercel project uses).
    { name = "API_URL", value = var.crm_cis_api_url },
    { name = "PORTAL_HOSTS", value = local.crm_agency_host },
    # Behind CloudFront -> ALB the standalone server sees its bind address; redirects and the same-origin write guard
    # use this public origin instead (critic C2).
    { name = "PORTAL_PUBLIC_ORIGIN", value = "https://${local.crm_agency_host}" },
    { name = "PORTAL_API_KEY_SIGNIN", value = var.crm_portal_api_key_signin ? "true" : "false" },
    # The CRM web's refresh route on the same host (it renews the partner session or falls back to managed login).
    { name = "CRM_WEB_SIGN_IN_PATH", value = "/auth/refresh" },
    { name = "CRM_WEB_SIGN_OUT_PATH", value = "/auth/sign-out" },
  ]
}

# -----------------------------------------------------------------------------
# ECR (immutable; the AA-Partner Deploy Portal Dev workflow pushes one tag per git SHA).
# -----------------------------------------------------------------------------
resource "aws_ecr_repository" "crm_portal" {
  name                 = local.crm_portal_service
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.crm_portal_tags

  # CreateRepository: cicd_crm.tf CrmEcrRepoManage (aa-crm-<env>-*).
  depends_on = [time_sleep.wait_for_iam_propagation]
}

resource "aws_ecr_lifecycle_policy" "crm_portal" {
  repository = aws_ecr_repository.crm_portal.name
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
# Sentry DSN secret shell (no secret_version: the value is set out of band, like crm_sentry_dsn).
# -----------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "crm_portal_sentry_dsn" {
  name                    = "crm/${var.environment}/portal-sentry-dsn"
  description             = "AA-Partner Content studio (portal) Sentry DSN, SENTRY_DSN of the portal task (AA-979). Value set out-of-band, never by Terraform."
  recovery_window_in_days = var.environment == "dev" ? 0 : 30
  tags                    = local.crm_portal_tags
}

# -----------------------------------------------------------------------------
# Execution role.
# -----------------------------------------------------------------------------
resource "aws_iam_role" "crm_portal_ecs_execution" {
  name                 = "${local.crm_portal_service}-ecs-execution-role"
  permissions_boundary = aws_iam_policy.workload_boundary.arn
  assume_role_policy   = data.aws_iam_policy_document.booking_ecs_tasks_assume.json
  tags                 = local.crm_portal_tags

  depends_on = [time_sleep.wait_for_iam_propagation]
}

resource "aws_iam_role_policy" "crm_portal_ecs_execution" {
  name = "${local.crm_portal_service}-ecs-execution"
  role = aws_iam_role.crm_portal_ecs_execution.id

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
        Sid      = "EcrPullPortalRepo"
        Effect   = "Allow"
        Action   = ["ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"]
        Resource = aws_ecr_repository.crm_portal.arn
      },
      {
        Sid      = "WriteCrmLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.crm_api.arn}:log-stream:*"
      },
      {
        # Q2: the web session key, to read (never write) the CRM web's sealed session cookie on the same host.
        Sid      = "ReadPortalSecrets"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.crm_web.arn, aws_secretsmanager_secret.crm_portal_sentry_dsn.arn]
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# Task role: ECS Exec (SSM channel, never SSH) and its session logs only.
# -----------------------------------------------------------------------------
resource "aws_iam_role" "crm_portal_ecs_task" {
  name                 = "${local.crm_portal_service}-ecs-task-role"
  permissions_boundary = aws_iam_policy.workload_boundary.arn
  assume_role_policy   = data.aws_iam_policy_document.booking_ecs_tasks_assume.json
  tags                 = local.crm_portal_tags

  depends_on = [time_sleep.wait_for_iam_propagation]
}

resource "aws_iam_role_policy" "crm_portal_ecs_task" {
  name = "${local.crm_portal_service}-ecs-task"
  role = aws_iam_role.crm_portal_ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
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
# Task definition. The deploy copies the family's LATEST revision with only the image swapped (AA-Partner
# .github/workflows/deploy-portal-dev.yml), so a change here reaches the task on the next portal deploy.
# -----------------------------------------------------------------------------
resource "aws_ecs_task_definition" "crm_portal" {
  family                   = local.crm_portal_service
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.crm_portal_ecs_execution.arn
  task_role_arn            = aws_iam_role.crm_portal_ecs_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([{
    name         = local.crm_portal_container
    image        = "${aws_ecr_repository.crm_portal.repository_url}:bootstrap"
    essential    = true
    portMappings = [{ containerPort = local.crm_portal_port, protocol = "tcp" }]
    environment  = local.crm_portal_env
    secrets = concat(
      [{ name = "WEB_SESSION_SECRET", valueFrom = "${aws_secretsmanager_secret.crm_web.arn}:session_secret::" }],
      var.crm_portal_sentry_enabled ? [
        { name = "SENTRY_DSN", valueFrom = aws_secretsmanager_secret.crm_portal_sentry_dsn.arn },
      ] : [],
    )
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.crm_api.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = local.crm_portal_container
      }
    }
    # Liveness only. The image has node, no curl.
    healthCheck = {
      command     = ["CMD-SHELL", "node -e \"fetch('http://127.0.0.1:${local.crm_portal_port}/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))\""]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 20
    }
    stopTimeout = 20
  }])

  tags = local.crm_portal_tags
}

# -----------------------------------------------------------------------------
# ALB target group. The listener rules in front of it are crm_agency_edge.tf crm_agency_studio(_x).
# -----------------------------------------------------------------------------
resource "aws_lb_target_group" "crm_portal" {
  name                 = "${local.crm_portal_service}-tg"
  port                 = local.crm_portal_port
  protocol             = "HTTP"
  vpc_id               = module.vpc.vpc_id
  target_type          = "ip"
  deregistration_delay = 30

  health_check {
    enabled             = true
    path                = "/healthz"
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = local.crm_portal_tags
}

# -----------------------------------------------------------------------------
# ECS service. desired_count 0 at create (-> 1 after the first image); FARGATE_SPOT (Q13).
# -----------------------------------------------------------------------------
resource "aws_ecs_service" "crm_portal" {
  name            = local.crm_portal_service
  cluster         = module.ecs.cluster_arn
  task_definition = aws_ecs_task_definition.crm_portal.arn
  desired_count   = 0

  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 1
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
    security_groups  = [aws_security_group.crm_portal.id] # ALB -> 3000 only; not admitted by RDS
    assign_public_ip = false
  }

  dynamic "load_balancer" {
    for_each = local.crm_edge_on == 1 ? [1] : []
    content {
      target_group_arn = aws_lb_target_group.crm_portal.arn
      container_name   = local.crm_portal_container
      container_port   = local.crm_portal_port
    }
  }

  enable_execute_command = true
  propagate_tags         = "SERVICE"

  lifecycle {
    ignore_changes = [desired_count, task_definition]
  }

  tags = local.crm_portal_tags

  depends_on = [aws_lb_listener_rule.crm_agency_studio, aws_iam_role_policy.crm_portal_ecs_execution]
}

# -----------------------------------------------------------------------------
# Alarms (crm_web.tf pattern; missing data does not alarm, so desired 0 stays quiet).
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "crm_portal_no_healthy_task" {
  count = local.crm_edge_on

  alarm_name          = "${local.crm_portal_service}-no-healthy-task"
  alarm_description   = "AA-Partner Content studio target group ${aws_lb_target_group.crm_portal.name} has no healthy target for 5 minutes (service down or failing /healthz).${local.runbook_suffix.api_5xx}"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  dimensions          = { TargetGroup = aws_lb_target_group.crm_portal.arn_suffix, LoadBalancer = module.alb.alb_arn_suffix }
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

resource "aws_cloudwatch_metric_alarm" "crm_portal_unhealthy_hosts" {
  count = local.crm_edge_on

  alarm_name          = "${local.crm_portal_service}-unhealthy-hosts"
  alarm_description   = "AA-Partner Content studio target group ${aws_lb_target_group.crm_portal.name} has an unhealthy target for 5 minutes in a row.${local.runbook_suffix.api_5xx}"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  dimensions          = { TargetGroup = aws_lb_target_group.crm_portal.arn_suffix, LoadBalancer = module.alb.alb_arn_suffix }
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

resource "aws_cloudwatch_metric_alarm" "crm_portal_target_5xx" {
  count = local.crm_edge_on

  alarm_name          = "${local.crm_portal_service}-target-5xx"
  alarm_description   = "AA-Partner Content studio answered more than 5 HTTP 5xx in 5 minutes (target ${aws_lb_target_group.crm_portal.name}).${local.runbook_suffix.api_5xx}"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  dimensions          = { TargetGroup = aws_lb_target_group.crm_portal.arn_suffix, LoadBalancer = module.alb.alb_arn_suffix }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 5
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = merge(local.ecosys_tags, { App = "crm" })
}

# -----------------------------------------------------------------------------
# Outputs (values for the AA-Partner `dev` environment variables; names only).
# -----------------------------------------------------------------------------
output "crm_portal_ecr_repository_url" {
  value = aws_ecr_repository.crm_portal.repository_url
}

output "crm_portal_ecs_service_name" {
  value = aws_ecs_service.crm_portal.name
}

output "crm_portal_task_definition_family" {
  value = aws_ecs_task_definition.crm_portal.family
}

output "crm_portal_sentry_secret_name" {
  value = aws_secretsmanager_secret.crm_portal_sentry_dsn.name
}
