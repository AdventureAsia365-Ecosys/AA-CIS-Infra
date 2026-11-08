# =============================================================================
# AA-1038 R5 hosting (root ADR 0019 d23, S265 tech-lead decision with its cost yeses: one Fargate Spot task + CloudFront
# + a CLOUDFRONT-scope web ACL) — the TripPlanner frontend (AA-TripPlanner-Web frontend/, Next.js standalone) on ECS Dev.
# Until the DNS switch Vercel keeps serving tripplanner.<zone>; this service is reached through its own CloudFront
# distribution only (accounts/aa365 tripplanner_web_edge.tf). Same self-contained pattern as crm_web.tf and
# staff_web.tf (IMMUTABLE ECR, secret shell filled out of band, desired 0 at create, the app's deploy copies the
# family's latest revision with only the image swapped).
#
#   Resources:
#     - ECR aa-tripplanner-<env>-web (IMMUTABLE, one tag per git SHA, scan on push, keep last 10). CreateRepository for
#       the apply role: accounts/aa365 cicd_crm.tf CrmEcrRepoManage lists this one repository (bootstrap object).
#     - log group /ecs/aa-tripplanner-<env>-web (30 days, application logs)
#     - secret shell tripplanner/<env>/web: JSON {session_secret, catalog_revalidate_secret, sentry_dsn}; NO
#       secret_version: AA-CIS-Infra tools/identity/tripplanner_web_secret.py fills it (Terraform and the plan role
#       never read it)
#     - execution role aa-tripplanner-<env>-web-ecs-execution-role: pull ITS repo, write ITS log group, read ITS secrets
#       only (the shell above, the edge key tripplanner/<env>/api-key and the traveller identity keys the root passes)
#     - task definition aa-tripplanner-<env>-web: Fargate ARM64, 512 CPU / 1024 MB (SSR of the catalog pages and the
#       in-process ISR cache; the staff admins' 256 / 512 has no headroom for them), one container `web` :3000,
#       placeholder tag `bootstrap`. No task role: the BFF calls no AWS API (the Lambdas behind the HTTP API do).
#     - target group (health /api/health) and service: FARGATE_SPOT, desired 0 at create, ECS Exec OFF (an exec session
#       reads the task env, i.e. the secrets)
#     - alarm: no healthy target
#     - the TripPlanner deploy role's grant for this family, service and execution role ONLY
#
# Routing (accounts/aa365): viewer -> CloudFront tripplanner.<zone> (web ACL) -> the shared VPC origin on the internal
# NLB (crm_edge.tf) -> ALB :80 host rule tripplanner_web (host + X-AA-Origin, alb_rules.tf) -> this service. The BFF
# calls the HTTP API through api-tripplanner.<zone> (egress via the NAT instance), as it did from Vercel.
#
# Edge-aware app settings (AA-TripPlanner-Web lib/edgeGate.ts, lib/clientIp.ts): TP_EDGE_GATE=on (the model calls answer
# only on the two paths the web ACL guards) and TP_CLIENT_IP_SOURCE=cloudfront (the per-IP AI limits key on
# CloudFront-Viewer-Address, never on the viewer-written x-forwarded-for).
#
# Cost (us-west-1, Fargate Spot ARM64 ~0.0112 USD per vCPU-hour + ~0.0012 USD per GB-hour, D-19): one task of 0.5 vCPU /
# 1 GB at desired 1 ~ 5.0 USD/month (on demand ~ 16.6); ECR < 0.10; the secret 0.40; the alarm 0.10; logs < 0.50. The
# edge (CloudFront, web ACL) is in accounts/aa365 tripplanner_web_edge.tf.
# =============================================================================

variable "tripplanner_web_security_group_id" {
  description = "AA-1038: security group of the TripPlanner web service (accounts/aa365 app_security_groups.tf aws_security_group.tripplanner_web)."
  type        = string
}

variable "tripplanner_web_edge_on" {
  description = "AA-1038: 1 when the TripPlanner web edge exists (accounts/aa365 tripplanner_web_edge.tf local.tp_web_edge_on), else 0. Attaches the target group to the service and counts the alarm."
  type        = number

  validation {
    condition     = contains([0, 1], var.tripplanner_web_edge_on)
    error_message = "tripplanner_web_edge_on must be 0 or 1."
  }
}

variable "tripplanner_web_listener_rule_gate" {
  description = "AA-1038: ARN of the ALB :80 host rule tripplanner_web (empty while the edge is off); the service waits for it so ECS never registers targets in a group no rule reaches yet."
  type        = list(string)
  default     = []
}

variable "tripplanner_web_identity_secret_arns" {
  description = "AA-1038: env name -> ARN of a plain-string traveller identity secret the BFF needs (TP_COGNITO_BFF_KEY: tripplanner/<env>/cognito-bff-key, TP_COGNITO_SIGNUP_PROOF_KEY: tripplanner/<env>/cognito-signup-proof-key; accounts/aa365 identity.tf, each only while it exists)."
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for k in keys(var.tripplanner_web_identity_secret_arns) : contains(["TP_COGNITO_BFF_KEY", "TP_COGNITO_SIGNUP_PROOF_KEY"], k)])
    error_message = "tripplanner_web_identity_secret_arns takes TP_COGNITO_BFF_KEY and TP_COGNITO_SIGNUP_PROOF_KEY only."
  }
}

locals {
  tp_web_service   = "${local.tp_name_prefix}-web"
  tp_web_container = "web"
  tp_web_port      = 3000
  tp_web_health    = "/api/health"

  tp_web_tags = merge(local.tp_tags, { Component = "web", Issue = "AA-1038" })

  tp_web_task_def_pattern = "arn:aws:ecs:${var.aws_region}:${var.account_id}:task-definition/${local.tp_web_service}:*"
  tp_web_service_arn      = "arn:aws:ecs:${var.aws_region}:${var.account_id}:service/${var.ecs_cluster_name}/${local.tp_web_service}"

  # Env names read by the frontend (AA-TripPlanner-Web frontend/lib, app/api). Public values only; the secrets below.
  tp_web_env = [
    { name = "PORT", value = tostring(local.tp_web_port) },
    # The HTTP API custom domain (accounts/aa365 custom_domains.tf), the same base the Vercel production env holds.
    { name = "BROWSE_API_URL", value = "https://api-tripplanner.${var.dns_zone_name}" },
    { name = "TRIP_API_URL", value = "https://api-tripplanner.${var.dns_zone_name}" },
    { name = "SENTRY_ENVIRONMENT", value = var.environment },
    { name = "TP_EDGE_GATE", value = "on" },
    { name = "TP_CLIENT_IP_SOURCE", value = "cloudfront" },
  ]

  tp_web_secrets = concat(
    [
      { name = "TRIPPLANNER_API_KEY", valueFrom = aws_secretsmanager_secret.tripplanner_api_key.arn },
      { name = "TP_SESSION_SECRET", valueFrom = "${aws_secretsmanager_secret.tripplanner_web.arn}:session_secret::" },
      { name = "CATALOG_REVALIDATE_SECRET", valueFrom = "${aws_secretsmanager_secret.tripplanner_web.arn}:catalog_revalidate_secret::" },
      { name = "SENTRY_DSN", valueFrom = "${aws_secretsmanager_secret.tripplanner_web.arn}:sentry_dsn::" },
    ],
    [for name in sort(keys(var.tripplanner_web_identity_secret_arns)) : { name = name, valueFrom = var.tripplanner_web_identity_secret_arns[name] }],
  )

  # The ONLY secret ARNs the execution role may read.
  tp_web_secret_arns = concat(
    [aws_secretsmanager_secret.tripplanner_web.arn, aws_secretsmanager_secret.tripplanner_api_key.arn],
    [for name in sort(keys(var.tripplanner_web_identity_secret_arns)) : var.tripplanner_web_identity_secret_arns[name]],
  )
}

# -----------------------------------------------------------------------------
# ECR (immutable; AA-TripPlanner-Web .github/workflows/deploy-web-dev.yml pushes one tag per git SHA).
# -----------------------------------------------------------------------------
resource "aws_ecr_repository" "tripplanner_web" {
  name                 = local.tp_web_service
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.tp_web_tags

  depends_on = [var.iam_propagation_gate]
}

resource "aws_ecr_lifecycle_policy" "tripplanner_web" {
  repository = aws_ecr_repository.tripplanner_web.name
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
# Secret shell (no secret_version, crm_web.tf rule). Under tripplanner/*: the CIS task role is denied it (modules/ecs).
# -----------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "tripplanner_web" {
  name                    = "tripplanner/${var.environment}/web"
  description             = "AA-1038: TripPlanner web on ECS, JSON {session_secret, catalog_revalidate_secret, sentry_dsn}. Set by AA-CIS-Infra tools/identity/tripplanner_web_secret.py, never by Terraform."
  recovery_window_in_days = var.environment == "dev" ? 0 : 30
  tags                    = merge(local.tp_web_tags, { DataClassification = "restricted" })
}

# -----------------------------------------------------------------------------
# Logs (application logs: 30 days, S241 D-09).
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "tripplanner_web" {
  name              = "/ecs/${local.tp_web_service}"
  retention_in_days = 30
  tags              = local.tp_web_tags
}

# -----------------------------------------------------------------------------
# Execution role: pull its repo, write its log group, read its secrets only.
# -----------------------------------------------------------------------------
resource "aws_iam_role" "tripplanner_web_ecs_execution" {
  name                 = "${local.tp_web_service}-ecs-execution-role"
  permissions_boundary = var.permissions_boundary_arn
  assume_role_policy   = data.aws_iam_policy_document.booking_ecs_tasks_assume.json
  tags                 = local.tp_web_tags

  depends_on = [var.iam_propagation_gate]
}

resource "aws_iam_role_policy" "tripplanner_web_ecs_execution" {
  name = "${local.tp_web_service}-ecs-execution"
  role = aws_iam_role.tripplanner_web_ecs_execution.id

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
        Resource = aws_ecr_repository.tripplanner_web.arn
      },
      {
        Sid      = "WriteOwnLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.tripplanner_web.arn}:log-stream:*"
      },
      {
        Sid      = "ReadOwnSecrets"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = local.tp_web_secret_arns
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# Task definition. `bootstrap` is never pushed; the deploy copies the family's latest revision and swaps the image.
# -----------------------------------------------------------------------------
resource "aws_ecs_task_definition" "tripplanner_web" {
  family                   = local.tp_web_service
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.tripplanner_web_ecs_execution.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([{
    name         = local.tp_web_container
    image        = "${aws_ecr_repository.tripplanner_web.repository_url}:bootstrap"
    essential    = true
    portMappings = [{ containerPort = local.tp_web_port, protocol = "tcp" }]
    environment  = local.tp_web_env
    secrets      = local.tp_web_secrets
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.tripplanner_web.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = local.tp_web_container
      }
    }
    # The image has node, no curl.
    healthCheck = {
      command     = ["CMD-SHELL", "node -e \"fetch('http://127.0.0.1:${local.tp_web_port}${local.tp_web_health}').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))\""]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 30
    }
    stopTimeout = 20
  }])

  tags = local.tp_web_tags
}

# -----------------------------------------------------------------------------
# Target group. The ALB :80 host rule in front of it is accounts/aa365 tripplanner_web_edge.tf tripplanner_web.
# -----------------------------------------------------------------------------
resource "aws_lb_target_group" "tripplanner_web" {
  name                 = "${local.tp_web_service}-tg"
  port                 = local.tp_web_port
  protocol             = "HTTP"
  vpc_id               = var.vpc_id
  target_type          = "ip"
  deregistration_delay = 30

  health_check {
    enabled             = true
    path                = local.tp_web_health
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = local.tp_web_tags
}

# -----------------------------------------------------------------------------
# ECS service. desired_count 0 at create; FARGATE_SPOT only (stateless pages; a Spot interruption is a short 503 on
# Dev). ignore_changes keeps Terraform from scaling it back or reverting the deployed revision.
# -----------------------------------------------------------------------------
resource "aws_ecs_service" "tripplanner_web" {
  name            = local.tp_web_service
  cluster         = var.ecs_cluster_arn
  task_definition = aws_ecs_task_definition.tripplanner_web.arn
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

  health_check_grace_period_seconds = var.tripplanner_web_edge_on == 1 ? 60 : null

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.tripplanner_web_security_group_id] # ALB -> 3000 only; not admitted by RDS
    assign_public_ip = false
  }

  dynamic "load_balancer" {
    for_each = var.tripplanner_web_edge_on == 1 ? [1] : []
    content {
      target_group_arn = aws_lb_target_group.tripplanner_web.arn
      container_name   = local.tp_web_container
      container_port   = local.tp_web_port
    }
  }

  # OFF on purpose (header): an exec session reads the task env, i.e. the secrets.
  enable_execute_command = false
  propagate_tags         = "SERVICE"

  lifecycle {
    ignore_changes = [desired_count, task_definition]
  }

  tags = local.tp_web_tags

  depends_on = [var.tripplanner_web_listener_rule_gate, aws_iam_role_policy.tripplanner_web_ecs_execution]
}

# -----------------------------------------------------------------------------
# Alarm (staff_web.tf pattern; missing data does not alarm, so desired 0 stays quiet).
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "tripplanner_web_no_healthy_target" {
  count = var.tripplanner_web_edge_on

  alarm_name          = "${local.tp_web_service}-no-healthy-target"
  alarm_description   = "TripPlanner web target group ${aws_lb_target_group.tripplanner_web.name} has no healthy target for 5 minutes (task down or failing ${local.tp_web_health}).${var.runbook_suffix.api_5xx}"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  dimensions          = { TargetGroup = aws_lb_target_group.tripplanner_web.arn_suffix, LoadBalancer = var.alb_arn_suffix }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 5
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alerts_topic_arn]
  ok_actions          = [var.alerts_topic_arn]

  tags = merge(var.ecosys_tags, { App = "tripplanner" })
}

# -----------------------------------------------------------------------------
# TripPlanner deploy role (tripplanner.tf, OIDC from AA-TripPlanner-Web main only): this family, service and execution
# role ONLY. Own policy, so the Lambda deploy statements stay as they are. CI-appliable (an aa-tripplanner-<env>-* role).
# -----------------------------------------------------------------------------
resource "aws_iam_role_policy" "tripplanner_app_deploy_web" {
  name = "${local.tp_name_prefix}-app-deploy-web"
  role = aws_iam_role.tripplanner_app_deploy.id

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
        Sid    = "EcrPushWebRepo"
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
        Resource = aws_ecr_repository.tripplanner_web.arn
      },
      {
        # DescribeTaskDefinition takes no resource-level scope.
        Sid      = "EcsDescribeTaskDefinition"
        Effect   = "Allow"
        Action   = ["ecs:DescribeTaskDefinition"]
        Resource = "*"
      },
      {
        Sid      = "EcsRegisterWebTaskDefinition"
        Effect   = "Allow"
        Action   = ["ecs:RegisterTaskDefinition"]
        Resource = local.tp_web_task_def_pattern
      },
      {
        Sid      = "EcsTagOnRegisterWeb"
        Effect   = "Allow"
        Action   = ["ecs:TagResource"]
        Resource = local.tp_web_task_def_pattern
        Condition = {
          StringEquals = { "ecs:CreateAction" = "RegisterTaskDefinition" }
        }
      },
      {
        Sid      = "EcsDescribeWebService"
        Effect   = "Allow"
        Action   = ["ecs:DescribeServices"]
        Resource = local.tp_web_service_arn
      },
      {
        # Only a TripPlanner web revision; IfExists: a desired-count-only call carries no task definition.
        Sid      = "EcsUpdateWebService"
        Effect   = "Allow"
        Action   = ["ecs:UpdateService"]
        Resource = local.tp_web_service_arn
        Condition = {
          StringLikeIfExists = {
            "ecs:task-definition" = [local.tp_web_task_def_pattern, "${local.tp_web_service}:*"]
          }
        }
      },
      {
        # The running-image check of the deploy (list + describe the service's tasks in this cluster).
        Sid      = "EcsListAndDescribeTasks"
        Effect   = "Allow"
        Action   = ["ecs:ListTasks", "ecs:DescribeTasks"]
        Resource = "*"
        Condition = {
          ArnEquals = { "ecs:cluster" = var.ecs_cluster_arn }
        }
      },
      {
        Sid      = "PassWebExecutionRole"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = aws_iam_role.tripplanner_web_ecs_execution.arn
        Condition = {
          StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" }
        }
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# Outputs (names only).
# -----------------------------------------------------------------------------
output "tripplanner_web_target_group_arn" {
  value = aws_lb_target_group.tripplanner_web.arn
}

output "tripplanner_web_port" {
  description = "AA-1038: container port (the TripPlanner web security group admits it from the ALB)."
  value       = local.tp_web_port
}

output "tripplanner_web_ecs_service_name" {
  value = aws_ecs_service.tripplanner_web.name
}

output "tripplanner_web_ecr_repository_url" {
  value = aws_ecr_repository.tripplanner_web.repository_url
}

output "tripplanner_web_secret_name" {
  description = "AA-1038: the secret tools/identity/tripplanner_web_secret.py writes."
  value       = aws_secretsmanager_secret.tripplanner_web.name
}
