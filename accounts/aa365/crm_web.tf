# =============================================================================
# AA-935 (CRM-07) — AA-Partner CRM web (Next.js standalone) on Dev: image repo, ECS service, roles, secret shell.
#
# Repo AdventureAsia365-Ecosys/AA-Partner `web/`, design v3 §6.3 card CRM-07, root ADR 0010 decision 2 (one agency host
# behind CloudFront). Same self-contained pattern as crm_app.tf: CRM naming contract of cicd_crm.tf (aa-crm-<env>-*,
# tag App = "crm"), resources in this file (plus the security group in app_security_groups.tf, the partner host's
# default ALB rule in crm_edge.tf and the deploy-role grants in crm_app.tf), module outputs read only.
#
#   Resources:
#     - ECR repo aa-crm-dev-web (IMMUTABLE, one tag per git SHA, scan on push, keep last 10)
#     - secret shell crm/dev/web (JSON {cognito_client_secret, session_secret, staff_cognito_client_secret,
#       staff_session_secret}; NO secret_version: the value is set out of band by tools/identity/crm_dev_identity.py
#       web-secret / staff-web-secret, so Terraform and the plan role never read it)
#     - execution role aa-crm-dev-web-ecs-execution-role: pull this repo, write the CRM log group, read crm/dev/web only
#       (never the DSN: the web has no database access)
#     - task role aa-crm-dev-web-ecs-task-role: ECS Exec channel + exec session logs only (no AWS API the app calls)
#     - task definition aa-crm-dev-web (Fargate ARM64, 0.25 vCPU / 0.5 GB, port 3000, placeholder tag `bootstrap`)
#     - ALB target group aa-crm-dev-web-tg (health /healthz). The partner host's default rule (crm_edge.tf
#       crm_partner_default, priority 10, below crm_api) forwards to it, so every partner path except /crm and /crm/*
#       reaches the web
#     - ECS service aa-crm-dev-web on aa-cis-dev-cluster, desired_count 0 at create, FARGATE_SPOT (stateless, no worker)
#     - alarms: no healthy target, unhealthy target
#
# Routing: viewer -> CloudFront partner-dev. -> VPC origin -> NLB -> ALB :80 host + X-AA-Origin rules (alb_rules.tf):
# crm_api (/crm, /crm/*) first, then crm_partner_default -> this service. The web calls the API back through the
# public partner host (CRM_API_ORIGIN, egress via the NAT instance): it never holds the CloudFront origin secret.
# Sign-in: the EXTERNAL `cis-portal` client until AA-939 (design v3 Fix C10); its callback / sign-out URLs on the
# partner host are in identity_variables.tf. AA-939 points COGNITO_* at the partner pool's web client.
# AA-1019: the AA staff console (/staff on the agency host) signs in with the WORKFORCE crm-staff client (root ADR 0006b
# decision 6): STAFF_COGNITO_DOMAIN / STAFF_COGNITO_CLIENT_ID here, STAFF_COGNITO_CLIENT_SECRET / STAFF_SESSION_SECRET
# from two more keys of crm/dev/web. ORDER: write those keys (crm_dev_identity.py staff-web-secret --apply) BEFORE the
# AA-1019 Terraform apply (tools/identity/README.md runbook); a task whose secret lacks a mapped key fails to start.
# (The service ignores task_definition changes, so the apply alone never restarts the running task: writing the keys
# after the apply and before the next web deploy would also work, but the runbook uses one order.)
#
# Order of applies: after AA-933 (crm_app.tf, crm_edge.tf). The secret value must exist before the first task starts
# (a task whose secret has no value fails to start): apply -> `crm_dev_identity.py web-secret --apply` -> deploy the
# first image (AA-Partner Deploy Web Dev, variable CRM_WEB_ENABLED=true) -> scale 0 -> 1.
#
# Cost (us-west-1, est., D-19): $0 compute at desired 0; ECR < $0.05/month; secret $0.40/month; 2 alarms $0.20/month.
# At desired 1 on FARGATE_SPOT ARM64 0.25 vCPU / 0.5 GB: ~ $2.2/month (on demand would be ~ $7.2). Web -> API calls
# through the NAT instance and CloudFront at Dev volume: < $0.10/month. Total ~ $0.65/month idle, ~ $2.9/month running.
# =============================================================================

variable "crm_partner_signin_enabled" {
  description = "AA-939 (ADR 0006b): the CRM web signs in with the partner pool (partner-web client, MFA required) instead of the EXTERNAL cis-portal client. Flip only after the e2e users exist on the partner pool; then write the web secret for the partner client (crm_dev_identity.py web-secret --pool partner) and deploy the web. Since AA-979 P2b the CRM API no longer accepts cis-portal tokens on /crm/v1, so false is NOT a working rollback any more: keep it true."
  type        = bool
  default     = true

  validation {
    condition     = var.crm_partner_signin_enabled
    error_message = "false is retired since AA-979 P2b: the CRM API refuses cis-portal tokens on /crm/v1, so a CRM web on the cis-portal client breaks every agency page after sign-in."
  }
}

variable "crm_web_client_hosts" {
  description = "AA-935: extra traveller (client) hosts the CRM web serves /c/* on (WEB_CLIENT_HOSTS). AA-936 adds go-dev. itself (crm_client_edge.tf); list only additional hosts here."
  type        = list(string)
  default     = []
}

locals {
  crm_web_service   = "${local.crm_name_prefix}-web"
  crm_web_container = "web"
  crm_web_port      = 3000

  crm_web_tags = merge(local.crm_tags, { Service = "crm-web", Issue = "AA-935" })

  crm_web_service_arn      = "arn:aws:ecs:${var.aws_region}:${var.account_id}:service/${module.ecs.cluster_name}/${local.crm_web_service}"
  crm_web_task_def_pattern = "arn:aws:ecs:${var.aws_region}:${var.account_id}:task-definition/${local.crm_web_service}:*"

  # Managed login of the pool the web signs in with (AA-939, safe rollout): the partner pool's partner-web client once
  # crm_partner_signin_enabled = true, else the EXTERNAL cis-portal client (custom domain when on, else the prefix
  # domain). The client secret in crm/dev/web must belong to the same client: after flipping the variable and
  # applying, run tools/identity/crm_dev_identity.py web-secret --pool partner --apply, then deploy the web.
  crm_web_external_domain = local.id_custom_domains ? "https://${var.identity_external_custom_domain}" : "https://${aws_cognito_user_pool_domain.external_prefix.domain}.auth.${var.aws_region}.amazoncognito.com"
  crm_web_cognito_domain  = var.crm_partner_signin_enabled ? local.idpartner_login_base : local.crm_web_external_domain
  crm_web_client_id       = var.crm_partner_signin_enabled ? aws_cognito_user_pool_client.partner["partner-web"].id : aws_cognito_user_pool_client.external["cis-portal"].id
  # AA-1019: the WORKFORCE managed login (staff-auth. custom domain when on, else the prefix domain; same expression as
  # identity.tf output identity_managed_login_base_urls.workforce).
  crm_web_staff_domain = local.id_custom_domains ? "https://${var.identity_workforce_custom_domain}" : "https://${aws_cognito_user_pool_domain.workforce_prefix.domain}.auth.${var.aws_region}.amazoncognito.com"

  # Env names read by the web (AA-Partner web/lib/config.ts). Public values only; the two secrets come from
  # crm/dev/web.
  crm_web_env = [
    { name = "ENVIRONMENT", value = var.environment },
    # AA-979 clean-up: the fallback public origin is the agency host (the old partner host answers 301 there except
    # /crm/*, so the web only sees portal. requests).
    { name = "WEB_PUBLIC_ORIGIN", value = "https://${local.crm_agency_host}" },
    # AA-979 P2b (Q1, Q12): the web answers BOTH hosts, each with its own public origin (AA-Partner web/lib/hosts.ts
    # publicOriginFor); kept after the clean-up so removing the partner-host 301 needs no web change. CRM_API_ORIGIN
    # stays on the partner host: server to server, /crm/* is not redirected.
    { name = "WEB_PARTNER_HOSTS", value = join(",", local.crm_edge_on == 1 ? [local.crm_partner_host, local.crm_agency_host] : [local.crm_partner_host]) },
    # AA-936: the client host of crm_client_edge.tf, plus any extra host given here.
    { name = "WEB_CLIENT_HOSTS", value = join(",", distinct(concat(local.crm_client_hosts, var.crm_web_client_hosts))) },
    { name = "CRM_API_ORIGIN", value = "https://${local.crm_partner_host}" },
    { name = "COGNITO_DOMAIN", value = local.crm_web_cognito_domain },
    { name = "COGNITO_CLIENT_ID", value = local.crm_web_client_id },
    # Content studio cross-link (design v3 Fix C10): the tenant portal host (custom_domains_variables.tf `portal`).
    # AA-979 P2b: same-origin on portal.; on partner-dev. the web turns the path into the portal. URL.
    { name = "CONTENT_STUDIO_URL", value = "https://portal.${var.dns_zone_name}" },
    # AA-979 P2b runbook 4.3: the client-host trip page /trip/<id> (AA-Partner web/lib/tripPage.ts) reads the public
    # CIS GET /v1/trip/{id} from here; the same CIS API origin the CRM API pulls the membership feed from (crm_app.tf).
    { name = "CIS_API_URL", value = var.crm_cis_api_url },
    # AA-1019: the AA staff console's WORKFORCE client (its secret and cookie key come from crm/dev/web).
    { name = "STAFF_COGNITO_DOMAIN", value = local.crm_web_staff_domain },
    { name = "STAFF_COGNITO_CLIENT_ID", value = aws_cognito_user_pool_client.workforce["crm-staff"].id },
  ]
}

# -----------------------------------------------------------------------------
# ECR (immutable; the AA-Partner Deploy Web Dev workflow pushes one tag per git SHA).
# -----------------------------------------------------------------------------
resource "aws_ecr_repository" "crm_web" {
  name                 = local.crm_web_service
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.crm_web_tags

  # CreateRepository: cicd_crm.tf CrmEcrRepoManage (aa-crm-<env>-*).
  depends_on = [time_sleep.wait_for_iam_propagation]
}

resource "aws_ecr_lifecycle_policy" "crm_web" {
  repository = aws_ecr_repository.crm_web.name
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
# Secret shell (no secret_version, same rule as crm_sentry_dsn): JSON {cognito_client_secret, session_secret}.
# The CIS task role is denied crm/* (modules/ecs, AA-932).
# -----------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "crm_web" {
  name                    = "crm/${var.environment}/web"
  description             = "AA-Partner CRM web (AA-935, AA-1019): JSON {cognito_client_secret, session_secret, staff_cognito_client_secret, staff_session_secret}. Set by AA-CIS-Infra tools/identity/crm_dev_identity.py web-secret and staff-web-secret, never by Terraform."
  recovery_window_in_days = var.environment == "dev" ? 0 : 30
  tags                    = local.crm_web_tags
}

# -----------------------------------------------------------------------------
# Execution role: pull the web repo, write the CRM log group (stream prefix `web`), read crm/dev/web only.
# -----------------------------------------------------------------------------
resource "aws_iam_role" "crm_web_ecs_execution" {
  name                 = "${local.crm_web_service}-ecs-execution-role"
  permissions_boundary = aws_iam_policy.workload_boundary.arn
  assume_role_policy   = data.aws_iam_policy_document.booking_ecs_tasks_assume.json
  tags                 = local.crm_web_tags

  depends_on = [time_sleep.wait_for_iam_propagation]
}

resource "aws_iam_role_policy" "crm_web_ecs_execution" {
  name = "${local.crm_web_service}-ecs-execution"
  role = aws_iam_role.crm_web_ecs_execution.id

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
        Sid      = "EcrPullWebRepo"
        Effect   = "Allow"
        Action   = ["ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"]
        Resource = aws_ecr_repository.crm_web.arn
      },
      {
        Sid      = "WriteCrmLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.crm_api.arn}:log-stream:*"
      },
      {
        Sid      = "ReadWebSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.crm_web.arn
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# Task role: nothing but ECS Exec (SSM channel, never SSH) and its session logs. The web calls no AWS API.
# -----------------------------------------------------------------------------
resource "aws_iam_role" "crm_web_ecs_task" {
  name                 = "${local.crm_web_service}-ecs-task-role"
  permissions_boundary = aws_iam_policy.workload_boundary.arn
  assume_role_policy   = data.aws_iam_policy_document.booking_ecs_tasks_assume.json
  tags                 = local.crm_web_tags

  depends_on = [time_sleep.wait_for_iam_propagation]
}

resource "aws_iam_role_policy" "crm_web_ecs_task" {
  name = "${local.crm_web_service}-ecs-task"
  role = aws_iam_role.crm_web_ecs_task.id

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
# Task definition. `bootstrap` is never pushed; the deploy copies the family's LATEST revision with only the image
# swapped (AA-Partner .github/workflows/deploy-web-dev.yml), so a change here reaches the task on the next deploy.
# -----------------------------------------------------------------------------
resource "aws_ecs_task_definition" "crm_web" {
  family                   = local.crm_web_service
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.crm_web_ecs_execution.arn
  task_role_arn            = aws_iam_role.crm_web_ecs_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([{
    name         = local.crm_web_container
    image        = "${aws_ecr_repository.crm_web.repository_url}:bootstrap"
    essential    = true
    portMappings = [{ containerPort = local.crm_web_port, protocol = "tcp" }]
    environment  = local.crm_web_env
    secrets = [
      { name = "COGNITO_CLIENT_SECRET", valueFrom = "${aws_secretsmanager_secret.crm_web.arn}:cognito_client_secret::" },
      { name = "WEB_SESSION_SECRET", valueFrom = "${aws_secretsmanager_secret.crm_web.arn}:session_secret::" },
      # AA-1019: the staff console's client secret and its own cookie key (never the agency key above).
      { name = "STAFF_COGNITO_CLIENT_SECRET", valueFrom = "${aws_secretsmanager_secret.crm_web.arn}:staff_cognito_client_secret::" },
      { name = "STAFF_SESSION_SECRET", valueFrom = "${aws_secretsmanager_secret.crm_web.arn}:staff_session_secret::" },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.crm_api.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = local.crm_web_container
      }
    }
    # Liveness only (no dependency). The image has node, no curl.
    healthCheck = {
      command     = ["CMD-SHELL", "node -e \"fetch('http://127.0.0.1:${local.crm_web_port}/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))\""]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 20
    }
    stopTimeout = 20
  }])

  tags = local.crm_web_tags
}

# -----------------------------------------------------------------------------
# ALB target group. The listener rule in front of it is crm_edge.tf crm_partner_default.
# -----------------------------------------------------------------------------
resource "aws_lb_target_group" "crm_web" {
  name                 = "${local.crm_web_service}-tg"
  port                 = local.crm_web_port
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

  tags = local.crm_web_tags
}

# -----------------------------------------------------------------------------
# ECS service. desired_count 0 at create; FARGATE_SPOT only (stateless pages, no job worker, a Spot interruption is a
# few seconds of 503 on Dev). ignore_changes keeps Terraform from scaling it back or reverting the deployed revision.
# -----------------------------------------------------------------------------
resource "aws_ecs_service" "crm_web" {
  name            = local.crm_web_service
  cluster         = module.ecs.cluster_arn
  task_definition = aws_ecs_task_definition.crm_web.arn
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
    security_groups  = [aws_security_group.crm_web.id] # ALB -> 3000 only; not admitted by RDS
    assign_public_ip = false
  }

  dynamic "load_balancer" {
    for_each = local.crm_edge_on == 1 ? [1] : []
    content {
      target_group_arn = aws_lb_target_group.crm_web.arn
      container_name   = local.crm_web_container
      container_port   = local.crm_web_port
    }
  }

  enable_execute_command = true
  propagate_tags         = "SERVICE"

  lifecycle {
    ignore_changes = [desired_count, task_definition]
  }

  tags = local.crm_web_tags

  depends_on = [aws_lb_listener_rule.crm_partner_default, aws_iam_role_policy.crm_web_ecs_execution]
}

# -----------------------------------------------------------------------------
# Alarms (crm_app.tf pattern; missing data does not alarm, so desired 0 stays quiet).
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "crm_web_no_healthy_task" {
  count = local.crm_edge_on

  alarm_name          = "${local.crm_web_service}-no-healthy-task"
  alarm_description   = "AA-Partner web target group ${aws_lb_target_group.crm_web.name} has no healthy target for 5 minutes (service down or failing /healthz).${local.runbook_suffix.api_5xx}"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  dimensions          = { TargetGroup = aws_lb_target_group.crm_web.arn_suffix, LoadBalancer = module.alb.alb_arn_suffix }
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

resource "aws_cloudwatch_metric_alarm" "crm_web_unhealthy_hosts" {
  count = local.crm_edge_on

  alarm_name          = "${local.crm_web_service}-unhealthy-hosts"
  alarm_description   = "AA-Partner web target group ${aws_lb_target_group.crm_web.name} has an unhealthy target for 5 minutes in a row.${local.runbook_suffix.api_5xx}"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  dimensions          = { TargetGroup = aws_lb_target_group.crm_web.arn_suffix, LoadBalancer = module.alb.alb_arn_suffix }
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

# -----------------------------------------------------------------------------
# Outputs (values for the AA-Partner `dev` environment variables; names only).
# -----------------------------------------------------------------------------
output "crm_web_ecr_repository_url" {
  value = aws_ecr_repository.crm_web.repository_url
}

output "crm_web_ecs_service_name" {
  value = aws_ecs_service.crm_web.name
}

output "crm_web_task_definition_family" {
  value = aws_ecs_task_definition.crm_web.family
}

output "crm_web_secret_name" {
  description = "AA-935: the secret tools/identity/crm_dev_identity.py web-secret writes."
  value       = aws_secretsmanager_secret.crm_web.name
}
