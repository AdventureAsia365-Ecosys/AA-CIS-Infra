# =============================================================================
# AA-911 (root ADR 0019 d23, S265 tech-lead cost yes) — the two staff frontends on ECS: CIS admin (AA-CIS-App
# frontend/) and Booking admin (AA-Booking frontend/), today on Vercel (aa-cis-frontend, aa-booking-admin).
#
# ADR 0019 d23 (Dev): the two staff apps run TOGETHER in ONE Fargate task (two containers in one task definition,
# 0.5 vCPU / 1 GB, Spot) behind the shared ALB with the existing REGIONAL web ACL and no CDN. Same self-contained
# pattern as crm_web.tf (Next.js standalone, IMMUTABLE ECR, secret shells filled out of band, desired 0 at create).
#
#   Resources:
#     - ECR aa-cis-<env>-admin (App cis) and aa-booking-<env>-admin (App booking): IMMUTABLE, one tag per git SHA,
#       scan on push, keep last 10. The CIS repo is created by the bootstrap apply (the CI apply role may only
#       configure aa-cis-<env>-* repos, cicd.tf CisEcrRepoConfigure); the Booking one by CI (BookingEcrRepoManage).
#     - secret shells aa-cis/<env>/admin-web {cis_admin_client_secret, breakglass_client_secret} and
#       booking/<env>/admin-web {booking_staff_client_secret}. NO secret_version: AA-CIS-Infra
#       tools/identity/staff_web_secret.py copies the WORKFORCE client secrets in (Terraform and the plan role never
#       read them). ADMIN_SECRET of the CIS BFF maps the existing aa-cis/<env>/admin-secret (var.cis_admin_secret_arn).
#     - log group /ecs/aa-staff-<env>-web (30 days, application logs), one stream prefix per container
#     - execution role aa-staff-<env>-web-ecs-execution-role: pull the two repos, write the log group, read the two
#       shells and the admin secret only
#     - task role aa-staff-<env>-web-ecs-task-role: ECS Exec channel + exec session logs only (the apps call no AWS API)
#     - task definition aa-staff-<env>-web: Fargate ARM64, 512 CPU / 1024 MB, containers `cis-admin` (port 3000) and
#       `booking-admin` (port 3001; one network namespace, so the ports differ), placeholder tag `bootstrap`
#     - two target groups (health /api/healthz) and ONE ECS service aa-staff-<env>-web with two load_balancer blocks,
#       FARGATE_SPOT, desired 0 at create
#     - alarms: no healthy target, per target group
#     - an extra inline policy on the Booking deploy role (booking.tf) for its container of this family
#
# Routing (accounts/aa365): viewer -> https://aa-cis.<zone> / https://booking.<zone> -> ALB :443 (staff_web_edge.tf
# certificate, alb_rules.tf host rules staff_cis_admin / staff_booking_admin) -> this service. DNS stays on Vercel
# until the cut-over (accounts/aa365 var.staff_web_dns_on_ecs). The apps call their APIs through the public API hosts
# (egress via the NAT instance), like the CRM web.
#
# Deploys: each app repo's deploy workflow copies the family's LATEST revision and swaps only ITS container's image
# (AA-CIS-App deploy-admin-dev.yml, AA-Booking deploy-admin-dev.yml). While the other container is still on the
# placeholder tag `bootstrap` the workflow registers the revision and stops (no rollout). The service ignores
# task_definition, so a change here reaches the task on the next deploy of either app.
#
# Cost (us-west-1, Fargate Spot ARM64 ~0.0112 USD per vCPU-hour + ~0.0012 USD per GB-hour, D-19): desired 1 at
# 0.5 vCPU / 1 GB ~ 4.9 USD/month (on demand ~ 16.6). ECR < 0.10, two secrets 0.80, two alarms 0.20, logs < 0.50.
# Total ~ 6.5 USD/month running, ~ 1.5 USD/month at desired 0. No new load balancer, CDN or web ACL.
# =============================================================================

variable "cis_admin_secret_arn" {
  description = "AA-911: ARN of aa-cis/<env>/admin-secret (the CIS API's ADMIN_SECRET, accounts/aa365 var.secret_admin_arn); the CIS admin BFF maps it as ADMIN_SECRET."
  type        = string
}

variable "cognito_workforce_booking_staff_client_id" {
  description = "AA-911: the WORKFORCE booking-staff app client id (identity.tf); the Booking admin container signs in with it."
  type        = string
}

variable "staff_web_security_group_id" {
  description = "AA-911: security group of the staff web task (accounts/aa365 app_security_groups.tf aws_security_group.staff_web)."
  type        = string
}

variable "staff_web_listener_rule_gate" {
  description = "AA-911: ARNs of the two HTTPS host rules (alb_rules.tf staff_cis_admin / staff_booking_admin); the service waits for them so ECS never registers targets in a group no rule reaches yet."
  type        = list(string)
  default     = []
}

locals {
  staff_name_prefix = "aa-staff-${var.environment}"
  staff_web_service = "${local.staff_name_prefix}-web"

  # One container per app; awsvpc gives the task one network namespace, so each app has its own port.
  staff_web_apps = {
    cis = {
      container = "cis-admin"
      port      = 3000
      repo      = "aa-cis-${var.environment}-admin"
      app_tag   = "cis"
      tg_name   = "${local.staff_name_prefix}-cis-tg"
    }
    booking = {
      container = "booking-admin"
      port      = 3001
      repo      = "aa-booking-${var.environment}-admin"
      app_tag   = "booking"
      tg_name   = "${local.staff_name_prefix}-bk-tg"
    }
  }

  staff_web_health_path = "/api/healthz"

  # Shared by two apps: App = shared (DM-10.1); each ECR repo and secret keeps its owner's App tag.
  staff_web_tags = {
    Project     = "AA-Ecosys"
    Environment = var.environment
    ManagedBy   = "terraform"
    App         = "shared"
    Service     = "staff-web"
    Issue       = "AA-911"
  }

  staff_web_service_arn      = "arn:aws:ecs:${var.aws_region}:${var.account_id}:service/${var.ecs_cluster_name}/${local.staff_web_service}"
  staff_web_task_def_pattern = "arn:aws:ecs:${var.aws_region}:${var.account_id}:task-definition/${local.staff_web_service}:*"

  # WORKFORCE managed login (staff-auth. custom domain when on, else the prefix domain) and issuer; the same
  # expressions as crm_web.tf local.crm_web_staff_domain and the CIS API's identity config.
  staff_web_workforce_domain = var.identity_custom_domains_enabled ? "https://${var.identity_workforce_custom_domain}" : "https://${var.cognito_workforce_prefix_domain}.auth.${var.aws_region}.amazoncognito.com"
  staff_web_workforce_issuer = "https://${var.cognito_workforce_pool_endpoint}"

  # Env names read by each app (AA-CIS-App frontend/lib/cognito.ts + BFF routes; AA-Booking frontend/lib/config.ts +
  # lib/cognito.ts). Public values only; the secrets come from the shells below.
  staff_web_env = {
    cis = [
      { name = "PORT", value = tostring(local.staff_web_apps.cis.port) },
      { name = "API_URL", value = "https://api-cis.${var.dns_zone_name}" },
      { name = "COGNITO_WORKFORCE_DOMAIN", value = local.staff_web_workforce_domain },
      { name = "COGNITO_WORKFORCE_ISSUER", value = local.staff_web_workforce_issuer },
      { name = "COGNITO_CIS_ADMIN_CLIENT_ID", value = var.cognito_workforce_cis_admin_client_id },
      { name = "COGNITO_BREAKGLASS_CLIENT_ID", value = var.cognito_workforce_breakglass_client_id },
    ]
    booking = [
      { name = "PORT", value = tostring(local.staff_web_apps.booking.port) },
      { name = "BOOKING_API_URL", value = "https://api-booking.${var.dns_zone_name}" },
      { name = "CIS_API_URL", value = "https://api-cis.${var.dns_zone_name}" },
      { name = "COGNITO_WORKFORCE_DOMAIN", value = local.staff_web_workforce_domain },
      { name = "COGNITO_WORKFORCE_ISSUER", value = local.staff_web_workforce_issuer },
      { name = "COGNITO_BOOKING_STAFF_CLIENT_ID", value = var.cognito_workforce_booking_staff_client_id },
    ]
  }
}

# -----------------------------------------------------------------------------
# ECR (immutable; each app's deploy workflow pushes one tag per git SHA).
# -----------------------------------------------------------------------------
resource "aws_ecr_repository" "staff_web" {
  for_each = local.staff_web_apps

  name                 = each.value.repo
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(local.staff_web_tags, { App = each.value.app_tag })

  depends_on = [var.iam_propagation_gate]
}

resource "aws_ecr_lifecycle_policy" "staff_web" {
  for_each = local.staff_web_apps

  repository = aws_ecr_repository.staff_web[each.key].name
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
# Secret shells (no secret_version, crm_web.tf rule). Each app's own prefix: the CIS task role is denied booking/*
# (modules/ecs, AA-873), so the Booking client secret is never readable from a CIS task.
# -----------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "staff_web_cis" {
  name                    = "aa-cis/${var.environment}/admin-web"
  description             = "AA-911: CIS admin on ECS, JSON {cis_admin_client_secret, breakglass_client_secret} (WORKFORCE app clients). Set by AA-CIS-Infra tools/identity/staff_web_secret.py, never by Terraform."
  recovery_window_in_days = var.environment == "dev" ? 0 : 30
  tags                    = merge(local.staff_web_tags, { App = "cis" })
}

resource "aws_secretsmanager_secret" "staff_web_booking" {
  name                    = "booking/${var.environment}/admin-web"
  description             = "AA-911: Booking admin on ECS, JSON {booking_staff_client_secret} (WORKFORCE booking-staff client). Set by AA-CIS-Infra tools/identity/staff_web_secret.py, never by Terraform."
  recovery_window_in_days = var.environment == "dev" ? 0 : 30
  tags                    = merge(local.staff_web_tags, { App = "booking" })
}

# -----------------------------------------------------------------------------
# Logs (application logs: 30 days, S241 D-09).
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "staff_web" {
  name              = "/ecs/${local.staff_web_service}"
  retention_in_days = 30
  tags              = local.staff_web_tags
}

# -----------------------------------------------------------------------------
# Execution role: pull the two repos, write the log group, read the two shells and the admin secret only.
# -----------------------------------------------------------------------------
resource "aws_iam_role" "staff_web_ecs_execution" {
  name                 = "${local.staff_web_service}-ecs-execution-role"
  permissions_boundary = var.permissions_boundary_arn
  assume_role_policy   = data.aws_iam_policy_document.booking_ecs_tasks_assume.json
  tags                 = local.staff_web_tags

  depends_on = [var.iam_propagation_gate]
}

resource "aws_iam_role_policy" "staff_web_ecs_execution" {
  name = "${local.staff_web_service}-ecs-execution"
  role = aws_iam_role.staff_web_ecs_execution.id

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
        Sid      = "EcrPullStaffRepos"
        Effect   = "Allow"
        Action   = ["ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"]
        Resource = [for r in aws_ecr_repository.staff_web : r.arn]
      },
      {
        Sid      = "WriteStaffWebLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.staff_web.arn}:log-stream:*"
      },
      {
        Sid    = "ReadStaffWebSecrets"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = [
          aws_secretsmanager_secret.staff_web_cis.arn,
          aws_secretsmanager_secret.staff_web_booking.arn,
          var.cis_admin_secret_arn,
        ]
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# Task role: ECS Exec (SSM channel, never SSH) and its session logs only.
# -----------------------------------------------------------------------------
resource "aws_iam_role" "staff_web_ecs_task" {
  name                 = "${local.staff_web_service}-ecs-task-role"
  permissions_boundary = var.permissions_boundary_arn
  assume_role_policy   = data.aws_iam_policy_document.booking_ecs_tasks_assume.json
  tags                 = local.staff_web_tags

  depends_on = [var.iam_propagation_gate]
}

resource "aws_iam_role_policy" "staff_web_ecs_task" {
  name = "${local.staff_web_service}-ecs-task"
  role = aws_iam_role.staff_web_ecs_task.id

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
        Resource = "${var.ecs_exec_session_log_group_arn}:*"
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# Task definition. `bootstrap` is never pushed; each app's deploy copies the family's LATEST revision and swaps only
# its own container's image. Both containers are essential: a crashed app stops the task and ECS starts a new one
# (one task on Dev, so a crash of one app is a short outage of both; accepted for Dev, ADR 0019 d23).
# -----------------------------------------------------------------------------
resource "aws_ecs_task_definition" "staff_web" {
  family                   = local.staff_web_service
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.staff_web_ecs_execution.arn
  task_role_arn            = aws_iam_role.staff_web_ecs_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([
    for key, app in local.staff_web_apps : {
      name         = app.container
      image        = "${aws_ecr_repository.staff_web[key].repository_url}:bootstrap"
      essential    = true
      portMappings = [{ containerPort = app.port, protocol = "tcp" }]
      environment  = local.staff_web_env[key]
      secrets = key == "cis" ? [
        { name = "ADMIN_SECRET", valueFrom = var.cis_admin_secret_arn },
        { name = "COGNITO_CIS_ADMIN_CLIENT_SECRET", valueFrom = "${aws_secretsmanager_secret.staff_web_cis.arn}:cis_admin_client_secret::" },
        { name = "COGNITO_BREAKGLASS_CLIENT_SECRET", valueFrom = "${aws_secretsmanager_secret.staff_web_cis.arn}:breakglass_client_secret::" },
        ] : [
        { name = "COGNITO_BOOKING_STAFF_CLIENT_SECRET", valueFrom = "${aws_secretsmanager_secret.staff_web_booking.arn}:booking_staff_client_secret::" },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.staff_web.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = app.container
        }
      }
      # Liveness only (no dependency). The images have node, no curl.
      healthCheck = {
        command     = ["CMD-SHELL", "node -e \"fetch('http://127.0.0.1:${app.port}${local.staff_web_health_path}').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))\""]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 30
      }
      stopTimeout = 20
    }
  ])

  tags = local.staff_web_tags
}

# -----------------------------------------------------------------------------
# Target groups. The HTTPS host rules in front of them are accounts/aa365 alb_rules.tf staff_cis_admin /
# staff_booking_admin.
# -----------------------------------------------------------------------------
resource "aws_lb_target_group" "staff_web" {
  for_each = local.staff_web_apps

  name                 = each.value.tg_name
  port                 = each.value.port
  protocol             = "HTTP"
  vpc_id               = var.vpc_id
  target_type          = "ip"
  deregistration_delay = 30

  health_check {
    enabled             = true
    path                = local.staff_web_health_path
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = local.staff_web_tags
}

# -----------------------------------------------------------------------------
# ECS service: one task, both apps. desired_count 0 at create; FARGATE_SPOT only (stateless pages, no job worker; a
# Spot interruption is a short 503 on Dev). ignore_changes keeps Terraform from scaling it back or reverting the
# deployed revision.
# -----------------------------------------------------------------------------
resource "aws_ecs_service" "staff_web" {
  name            = local.staff_web_service
  cluster         = var.ecs_cluster_arn
  task_definition = aws_ecs_task_definition.staff_web.arn
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

  health_check_grace_period_seconds = 60

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.staff_web_security_group_id] # ALB -> 3000/3001 only; not admitted by RDS
    assign_public_ip = false
  }

  dynamic "load_balancer" {
    for_each = local.staff_web_apps
    content {
      target_group_arn = aws_lb_target_group.staff_web[load_balancer.key].arn
      container_name   = load_balancer.value.container
      container_port   = load_balancer.value.port
    }
  }

  enable_execute_command = true
  propagate_tags         = "SERVICE"

  lifecycle {
    ignore_changes = [desired_count, task_definition]
  }

  tags = local.staff_web_tags

  depends_on = [var.staff_web_listener_rule_gate, aws_iam_role_policy.staff_web_ecs_execution]
}

# -----------------------------------------------------------------------------
# Alarms (crm_web.tf pattern; missing data does not alarm, so desired 0 stays quiet).
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "staff_web_no_healthy_target" {
  for_each = local.staff_web_apps

  alarm_name          = "${local.staff_web_service}-${each.key}-no-healthy-target"
  alarm_description   = "Staff web target group ${aws_lb_target_group.staff_web[each.key].name} (${each.value.container}) has no healthy target for 5 minutes (task down or failing ${local.staff_web_health_path}).${var.runbook_suffix.api_5xx}"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  dimensions          = { TargetGroup = aws_lb_target_group.staff_web[each.key].arn_suffix, LoadBalancer = var.alb_arn_suffix }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 5
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alerts_topic_arn]
  ok_actions          = [var.alerts_topic_arn]

  tags = merge(var.ecosys_tags, { App = "shared" })
}

# -----------------------------------------------------------------------------
# Booking deploy role (booking.tf): its container of the staff family. Own policy, so booking.tf's statements stay
# as they are. The CIS deploy role gets the same grant in accounts/aa365 cicd_split.tf (a bootstrap object).
# -----------------------------------------------------------------------------
resource "aws_iam_role_policy" "booking_app_deploy_staff_web" {
  name = "${local.bk_name_prefix}-app-deploy-staff-web"
  role = aws_iam_role.booking_app_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EcrPushBookingAdminRepo"
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
        Resource = aws_ecr_repository.staff_web["booking"].arn
      },
      {
        Sid      = "EcsRegisterStaffWebTaskDefinition"
        Effect   = "Allow"
        Action   = ["ecs:RegisterTaskDefinition"]
        Resource = local.staff_web_task_def_pattern
      },
      {
        Sid      = "EcsTagOnRegisterStaffWeb"
        Effect   = "Allow"
        Action   = ["ecs:TagResource"]
        Resource = local.staff_web_task_def_pattern
        Condition = {
          StringEquals = { "ecs:CreateAction" = "RegisterTaskDefinition" }
        }
      },
      {
        Sid      = "EcsDescribeStaffWebService"
        Effect   = "Allow"
        Action   = ["ecs:DescribeServices"]
        Resource = local.staff_web_service_arn
      },
      {
        # Only a staff-web revision; IfExists: a desired-count-only call carries no task definition.
        Sid      = "EcsUpdateStaffWebService"
        Effect   = "Allow"
        Action   = ["ecs:UpdateService"]
        Resource = local.staff_web_service_arn
        Condition = {
          StringLikeIfExists = {
            "ecs:task-definition" = [local.staff_web_task_def_pattern, "${local.staff_web_service}:*"]
          }
        }
      },
      {
        Sid    = "PassStaffWebTaskRoles"
        Effect = "Allow"
        Action = ["iam:PassRole"]
        Resource = [
          aws_iam_role.staff_web_ecs_execution.arn,
          aws_iam_role.staff_web_ecs_task.arn,
        ]
        Condition = {
          StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" }
        }
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# Outputs (names only; the root reads the target groups for its host rules and the roles for the CIS deploy grant).
# -----------------------------------------------------------------------------
output "staff_web_deploy_scope" {
  description = "AA-911: names the CIS deploy grant (accounts/aa365 cicd_split.tf, a bootstrap object) is scoped to, built from locals only so that grant can be applied alone (-target) before the stack exists."
  value = {
    family             = local.staff_web_service
    service            = local.staff_web_service
    execution_role_arn = "arn:aws:iam::${var.account_id}:role/${local.staff_web_service}-ecs-execution-role"
    task_role_arn      = "arn:aws:iam::${var.account_id}:role/${local.staff_web_service}-ecs-task-role"
  }
}

output "staff_web_target_group_arns" {
  description = "AA-911: target group ARN per app key (cis, booking)."
  value       = { for k, tg in aws_lb_target_group.staff_web : k => tg.arn }
}

output "staff_web_ports" {
  description = "AA-911: container port per app key (the staff web security group admits these from the ALB)."
  value       = { for k, app in local.staff_web_apps : k => app.port }
}

output "staff_web_ecs_service_name" {
  value = aws_ecs_service.staff_web.name
}

output "staff_web_task_definition_family" {
  value = aws_ecs_task_definition.staff_web.family
}

output "staff_web_container_names" {
  description = "AA-911: container name per app key (each deploy workflow swaps only its own)."
  value       = { for k, app in local.staff_web_apps : k => app.container }
}

output "staff_web_ecr_repository_urls" {
  value = { for k, r in aws_ecr_repository.staff_web : k => r.repository_url }
}

output "staff_web_role_arns" {
  description = "AA-911: execution and task role ARNs (PassRole of the CIS deploy grant, accounts/aa365 cicd_split.tf)."
  value = {
    execution = aws_iam_role.staff_web_ecs_execution.arn
    task      = aws_iam_role.staff_web_ecs_task.arn
  }
}

output "staff_web_secret_names" {
  description = "AA-911: the secrets tools/identity/staff_web_secret.py writes."
  value = {
    cis     = aws_secretsmanager_secret.staff_web_cis.name
    booking = aws_secretsmanager_secret.staff_web_booking.name
  }
}
