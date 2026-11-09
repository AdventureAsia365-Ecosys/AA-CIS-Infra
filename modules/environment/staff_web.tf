# =============================================================================
# AA-911 (root ADR 0019 d23 + its S271 amendment, S265 tech-lead cost yes) — the two staff frontends on ECS: CIS admin
# (AA-CIS-App frontend/) and Booking admin (AA-Booking frontend/); until S272 on Vercel (aa-cis-frontend, aa-booking-admin, retired by AA-911).
#
# ONE SERVICE PER APP (S271 amendment of d23, which first said one task with two containers): aa-cis-<env>-admin and
# aa-booking-<env>-admin, each one Fargate Spot task of 0.25 vCPU / 0.5 GB (the same cost as one 0.5 / 1 task: Fargate
# bills per vCPU and per GB). Per-app secret isolation (AA-873): each app has its own task definition family and its
# own execution role, and each app's deploy role may register and pass ONLY its own. Both services sit behind the shared
# ALB's HTTPS listener (one host rule each) with the existing REGIONAL web ACL and no CDN. Same self-contained pattern
# as crm_web.tf (Next.js standalone, IMMUTABLE ECR, secret shells filled out of band, desired 0 at create).
#
#   Resources, per app key (cis, booking) of local.staff_web_apps:
#     - ECR aa-cis-<env>-admin / aa-booking-<env>-admin: IMMUTABLE, one tag per git SHA, scan on push, keep last 10.
#       The CIS repo is created by the bootstrap apply (the CI apply role may only configure aa-cis-<env>-* repos,
#       cicd.tf CisEcrRepoConfigure); the Booking one by CI (BookingEcrRepoManage).
#     - log group /ecs/<service> (30 days, application logs)
#     - execution role <service>-ecs-execution-role: pull ITS repo, write ITS log group, read ITS secrets only
#     - task definition <service> (family = service name): Fargate ARM64, 256 CPU / 512 MB, one container
#       (`cis-admin` :3000, `booking-admin` :3001), placeholder tag `bootstrap`. No task role: the apps call no AWS API.
#     - target group (health /api/healthz) and service <service>: FARGATE_SPOT, desired 0 at create, ECS Exec OFF
#     - alarm: no healthy target
#     - AA-1060: the Booking admin task also carries the WordPress test site sidecar (test_wp.tf: a second, non-essential
#       container and, once attached, a second load_balancer block); the CIS admin task does not.
#   Plus the secret shells aa-cis/<env>/admin-web {cis_admin_client_secret, breakglass_client_secret} and
#   booking/<env>/admin-web {booking_staff_client_secret}. NO secret_version: AA-CIS-Infra
#   tools/identity/staff_web_secret.py copies the WORKFORCE client secrets in (Terraform and the plan role never read
#   them). ADMIN_SECRET of the CIS BFF maps the existing aa-cis/<env>/admin-secret (var.cis_admin_secret_arn), so ONLY
#   the CIS execution role reads it. And an extra inline policy on the Booking deploy role (booking.tf) for the Booking
#   family; the CIS deploy role's grant is accounts/aa365 cicd_split.tf (a bootstrap object), CIS family only.
#
# ECS Exec is OFF on both services (an exec session reads the task env, i.e. the app's secrets; AA-911 review notes in
# Linear). The containers are debugged from their logs.
#
# Routing (accounts/aa365): viewer -> https://aa-cis.<zone> / https://booking.<zone> -> ALB :443 (staff_web_edge.tf
# certificate, alb_rules.tf host rules staff_cis_admin / staff_booking_admin) -> the app's service. DNS: accounts/aa365
# staff_web_edge.tf aws_route53_record.staff_web (Vercel retired, S272). The apps call their APIs through the public API hosts
# (egress via the NAT instance), like the CRM web.
#
# Deploys: each app repo's Deploy Admin Dev (AA-CIS-App, AA-Booking) copies ITS family's latest revision with only the
# image swapped, points ITS service at it and waits. The service ignores task_definition, so a change here (env,
# secrets, size) registers a revision on `bootstrap` that reaches the task on the next deploy of THAT app (the deploy
# takes env and secrets from the latest revision and only replaces the image).
#
# Cost (us-west-1, Fargate Spot ARM64 ~0.0112 USD per vCPU-hour + ~0.0012 USD per GB-hour, D-19): two tasks at desired
# 1, each 0.25 vCPU / 0.5 GB ~ 2.45 USD/month, so ~ 4.9 USD/month for both (on demand ~ 16.6). ECR < 0.10, two
# secrets 0.80, two alarms 0.20, logs < 0.50. Total ~ 6.5 USD/month running, ~ 1.5 USD/month at desired 0. No new load
# balancer, CDN or web ACL.
# =============================================================================

variable "cis_admin_secret_arn" {
  description = "AA-911: ARN of aa-cis/<env>/admin-secret (the CIS API's ADMIN_SECRET, accounts/aa365 var.secret_admin_arn); the CIS admin BFF maps it as ADMIN_SECRET (CIS execution role only)."
  type        = string
}

variable "cognito_workforce_booking_staff_client_id" {
  description = "AA-911: the WORKFORCE booking-staff app client id (identity.tf); the Booking admin container signs in with it."
  type        = string
}

variable "staff_web_security_group_id" {
  description = "AA-911: security group of the two staff web services (accounts/aa365 app_security_groups.tf aws_security_group.staff_web)."
  type        = string
}

variable "staff_web_listener_rule_gate" {
  description = "AA-911: ARNs of the two HTTPS host rules (alb_rules.tf staff_cis_admin / staff_booking_admin); the services wait for them so ECS never registers targets in a group no rule reaches yet."
  type        = list(string)
  default     = []
}

locals {
  # One service per app. The ports differ only so the shared security group stays readable (3000 = CIS, 3001 =
  # Booking); each task has its own network namespace.
  staff_web_apps = {
    cis = {
      service   = "aa-cis-${var.environment}-admin"
      container = "cis-admin"
      port      = 3000
      app_tag   = "cis"
    }
    booking = {
      service   = "aa-booking-${var.environment}-admin"
      container = "booking-admin"
      port      = 3001
      app_tag   = "booking"
    }
  }

  staff_web_health_path = "/api/healthz"

  # S271 (tagging standard FIN-03): Component replaces the retired Service key; App is set per resource.
  staff_web_tags = {
    Component = "admin"
    Issue     = "AA-911"
  }

  # WORKFORCE managed login (staff-auth. custom domain when on, else the prefix domain) and issuer; the same
  # expressions as crm_web.tf local.crm_web_staff_domain and the CIS API's identity config.
  staff_web_workforce_domain = var.identity_custom_domains_enabled ? "https://${var.identity_workforce_custom_domain}" : "https://${var.cognito_workforce_prefix_domain}.auth.${var.aws_region}.amazoncognito.com"
  staff_web_workforce_issuer = "https://${var.cognito_workforce_pool_endpoint}"

  # Env names read by each app (AA-CIS-App frontend/lib/cognito.ts + BFF routes; AA-Booking frontend/lib/config.ts +
  # lib/cognito.ts). Public values only; the secrets come from local.staff_web_secrets.
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

  # Container secrets per app, and the ONLY secret ARNs that app's execution role may read.
  staff_web_secrets = {
    cis = [
      { name = "ADMIN_SECRET", valueFrom = var.cis_admin_secret_arn },
      { name = "COGNITO_CIS_ADMIN_CLIENT_SECRET", valueFrom = "${aws_secretsmanager_secret.staff_web_cis.arn}:cis_admin_client_secret::" },
      { name = "COGNITO_BREAKGLASS_CLIENT_SECRET", valueFrom = "${aws_secretsmanager_secret.staff_web_cis.arn}:breakglass_client_secret::" },
    ]
    booking = [
      { name = "COGNITO_BOOKING_STAFF_CLIENT_SECRET", valueFrom = "${aws_secretsmanager_secret.staff_web_booking.arn}:booking_staff_client_secret::" },
    ]
  }
  # AA-1060: the Booking admin task also runs the WordPress test site sidecar (test_wp.tf), whose container reads the
  # test-only secret aa-cis/<env>/e2e-wordpress-test while test_wp_enabled is on.
  staff_web_secret_arns = {
    cis     = [aws_secretsmanager_secret.staff_web_cis.arn, var.cis_admin_secret_arn]
    booking = concat([aws_secretsmanager_secret.staff_web_booking.arn], data.aws_secretsmanager_secret.test_wp_credentials[*].arn)
  }

  # Deploy scope per app, from names only (no resource attribute): accounts/aa365 cicd_split.tf applies the CIS
  # grant alone with -target before this stack exists.
  staff_web_deploy_scope = {
    for k, app in local.staff_web_apps : k => {
      family             = app.service
      service            = app.service
      container          = app.container
      task_def_pattern   = "arn:aws:ecs:${var.aws_region}:${var.account_id}:task-definition/${app.service}:*"
      service_arn        = "arn:aws:ecs:${var.aws_region}:${var.account_id}:service/${var.ecs_cluster_name}/${app.service}"
      execution_role_arn = "arn:aws:iam::${var.account_id}:role/${app.service}-ecs-execution-role"
    }
  }
}

# -----------------------------------------------------------------------------
# ECR (immutable; each app's deploy workflow pushes one tag per git SHA).
# -----------------------------------------------------------------------------
resource "aws_ecr_repository" "staff_web" {
  for_each = local.staff_web_apps

  name                 = each.value.service
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
# (modules/ecs, AA-873), and each execution role below reads only its own app's secrets.
# -----------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "staff_web_cis" {
  name                    = "aa-cis/${var.environment}/admin-web"
  description             = "AA-911: CIS admin on ECS, JSON {cis_admin_client_secret, breakglass_client_secret} (WORKFORCE app clients). Set by AA-CIS-Infra tools/identity/staff_web_secret.py, never by Terraform."
  recovery_window_in_days = var.environment == "dev" ? 0 : 30
  tags                    = merge(local.staff_web_tags, { App = "cis", DataClassification = "restricted" })
}

resource "aws_secretsmanager_secret" "staff_web_booking" {
  name                    = "booking/${var.environment}/admin-web"
  description             = "AA-911: Booking admin on ECS, JSON {booking_staff_client_secret} (WORKFORCE booking-staff client). Set by AA-CIS-Infra tools/identity/staff_web_secret.py, never by Terraform."
  recovery_window_in_days = var.environment == "dev" ? 0 : 30
  tags                    = merge(local.staff_web_tags, { App = "booking", DataClassification = "restricted" })
}

# -----------------------------------------------------------------------------
# Logs (application logs: 30 days, S241 D-09), one group per app.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "staff_web" {
  for_each = local.staff_web_apps

  name              = "/ecs/${each.value.service}"
  retention_in_days = 30
  tags              = merge(local.staff_web_tags, { App = each.value.app_tag })
}

# -----------------------------------------------------------------------------
# Execution role per app: pull its repo, write its log group, read its secrets only.
# -----------------------------------------------------------------------------
resource "aws_iam_role" "staff_web_ecs_execution" {
  for_each = local.staff_web_apps

  name                 = "${each.value.service}-ecs-execution-role"
  permissions_boundary = var.permissions_boundary_arn
  assume_role_policy   = data.aws_iam_policy_document.booking_ecs_tasks_assume.json
  tags                 = merge(local.staff_web_tags, { App = each.value.app_tag })

  depends_on = [var.iam_propagation_gate]
}

resource "aws_iam_role_policy" "staff_web_ecs_execution" {
  for_each = local.staff_web_apps

  name = "${each.value.service}-ecs-execution"
  role = aws_iam_role.staff_web_ecs_execution[each.key].id

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
        Sid      = "EcrPullOwnRepo"
        Effect   = "Allow"
        Action   = ["ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"]
        Resource = aws_ecr_repository.staff_web[each.key].arn
      },
      {
        Sid      = "WriteOwnLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.staff_web[each.key].arn}:log-stream:*"
      },
      {
        Sid      = "ReadOwnSecrets"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = local.staff_web_secret_arns[each.key]
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# Task definition per app. `bootstrap` is never pushed; the app's deploy copies the family's latest revision and swaps
# the image. No task role (the apps call no AWS API; ECS Exec is off).
# -----------------------------------------------------------------------------
resource "aws_ecs_task_definition" "staff_web" {
  for_each = local.staff_web_apps

  family                   = each.value.service
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.staff_web_ecs_execution[each.key].arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  # AA-1060: the Booking admin task carries the WordPress test site sidecar while test_wp_enabled is on (test_wp.tf).
  container_definitions = jsonencode(concat([
    {
      name         = each.value.container
      image        = "${aws_ecr_repository.staff_web[each.key].repository_url}:bootstrap"
      essential    = true
      portMappings = [{ containerPort = each.value.port, protocol = "tcp" }]
      environment  = local.staff_web_env[each.key]
      secrets      = local.staff_web_secrets[each.key]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.staff_web[each.key].name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = each.value.container
        }
      }
      # The images have node, no curl.
      healthCheck = {
        command     = ["CMD-SHELL", "node -e \"fetch('http://127.0.0.1:${each.value.port}${local.staff_web_health_path}').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))\""]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 30
      }
      stopTimeout = 20
    }
  ], each.key == local.test_wp_host_app ? local.test_wp_container_definitions : []))

  tags = merge(local.staff_web_tags, { App = each.value.app_tag })
}

# -----------------------------------------------------------------------------
# Target groups. The HTTPS host rules in front of them are accounts/aa365 alb_rules.tf staff_cis_admin /
# staff_booking_admin.
# -----------------------------------------------------------------------------
resource "aws_lb_target_group" "staff_web" {
  for_each = local.staff_web_apps

  name                 = "${each.value.service}-tg"
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

  tags = merge(local.staff_web_tags, { App = each.value.app_tag })
}

# -----------------------------------------------------------------------------
# ECS service per app. desired_count 0 at create; FARGATE_SPOT only (stateless pages, no job worker; a Spot
# interruption is a short 503 on Dev). ignore_changes keeps Terraform from scaling it back or reverting the deployed
# revision.
# -----------------------------------------------------------------------------
resource "aws_ecs_service" "staff_web" {
  for_each = local.staff_web_apps

  name            = each.value.service
  cluster         = var.ecs_cluster_arn
  task_definition = aws_ecs_task_definition.staff_web[each.key].arn
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

  load_balancer {
    target_group_arn = aws_lb_target_group.staff_web[each.key].arn
    container_name   = each.value.container
    container_port   = each.value.port
  }

  # AA-1060: the WordPress test site sidecar of the Booking admin task (test_wp.tf), once test_wp_service_attached is on.
  dynamic "load_balancer" {
    for_each = each.key == local.test_wp_host_app && var.test_wp_service_attached ? aws_lb_target_group.test_wp[*].arn : []
    content {
      target_group_arn = load_balancer.value
      container_name   = local.test_wp_container
      container_port   = local.test_wp_port
    }
  }

  # OFF on purpose (header): an exec session reads the task env, i.e. the app's secrets.
  enable_execute_command = false
  propagate_tags         = "SERVICE"

  lifecycle {
    ignore_changes = [desired_count, task_definition]
  }

  tags = merge(local.staff_web_tags, { App = each.value.app_tag })

  depends_on = [var.staff_web_listener_rule_gate, aws_iam_role_policy.staff_web_ecs_execution]
}

# -----------------------------------------------------------------------------
# Alarms (crm_web.tf pattern; missing data does not alarm, so desired 0 stays quiet).
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "staff_web_no_healthy_target" {
  for_each = local.staff_web_apps

  alarm_name          = "${each.value.service}-no-healthy-target"
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

  tags = merge(var.ecosys_tags, { App = each.value.app_tag })
}

# -----------------------------------------------------------------------------
# Booking deploy role (booking.tf): the Booking admin family, service and execution role ONLY. Own policy, so
# booking.tf's statements stay as they are. The CIS deploy role gets the CIS twin in accounts/aa365 cicd_split.tf (a
# bootstrap object).
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
        Resource = local.staff_web_deploy_scope.booking.task_def_pattern
      },
      {
        Sid      = "EcsTagOnRegisterStaffWeb"
        Effect   = "Allow"
        Action   = ["ecs:TagResource"]
        Resource = local.staff_web_deploy_scope.booking.task_def_pattern
        Condition = {
          StringEquals = { "ecs:CreateAction" = "RegisterTaskDefinition" }
        }
      },
      {
        Sid      = "EcsDescribeStaffWebService"
        Effect   = "Allow"
        Action   = ["ecs:DescribeServices"]
        Resource = local.staff_web_deploy_scope.booking.service_arn
      },
      {
        # Only a Booking admin revision; IfExists: a desired-count-only call carries no task definition.
        Sid      = "EcsUpdateStaffWebService"
        Effect   = "Allow"
        Action   = ["ecs:UpdateService"]
        Resource = local.staff_web_deploy_scope.booking.service_arn
        Condition = {
          StringLikeIfExists = {
            "ecs:task-definition" = [local.staff_web_deploy_scope.booking.task_def_pattern, "${local.staff_web_deploy_scope.booking.family}:*"]
          }
        }
      },
      {
        Sid      = "PassStaffWebTaskRoles"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = aws_iam_role.staff_web_ecs_execution["booking"].arn
        Condition = {
          StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" }
        }
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# Outputs (names only; the root reads the target groups for its host rules and the CIS scope for the CIS deploy
# grant).
# -----------------------------------------------------------------------------
output "staff_web_deploy_scope" {
  description = "AA-911: per app key, the names a deploy grant is scoped to (family, service, container, ARNs), built from locals only so the CIS grant (accounts/aa365 cicd_split.tf, a bootstrap object) can be applied alone (-target) before the stack exists."
  value       = local.staff_web_deploy_scope
}

output "staff_web_target_group_arns" {
  description = "AA-911: target group ARN per app key (cis, booking)."
  value       = { for k, tg in aws_lb_target_group.staff_web : k => tg.arn }
}

output "staff_web_ports" {
  description = "AA-911: container port per app key (the staff web security group admits these from the ALB)."
  value       = { for k, app in local.staff_web_apps : k => app.port }
}

output "staff_web_ecs_service_names" {
  description = "AA-911: ECS service name per app key (= its task definition family)."
  value       = { for k, s in aws_ecs_service.staff_web : k => s.name }
}

output "staff_web_task_definition_families" {
  value = { for k, td in aws_ecs_task_definition.staff_web : k => td.family }
}

output "staff_web_container_names" {
  description = "AA-911: container name per app key."
  value       = { for k, app in local.staff_web_apps : k => app.container }
}

output "staff_web_ecr_repository_urls" {
  value = { for k, r in aws_ecr_repository.staff_web : k => r.repository_url }
}

output "staff_web_execution_role_arns" {
  description = "AA-911: execution role ARN per app key (each deploy role may pass only its own)."
  value       = { for k, r in aws_iam_role.staff_web_ecs_execution : k => r.arn }
}

output "staff_web_secret_names" {
  description = "AA-911: the secrets tools/identity/staff_web_secret.py writes."
  value = {
    cis     = aws_secretsmanager_secret.staff_web_cis.name
    booking = aws_secretsmanager_secret.staff_web_booking.name
  }
}
