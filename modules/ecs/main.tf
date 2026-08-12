# ============================================================
# ECS Module — AA-CIS
# Cluster + IAM + ECR + Task Definition + Service + Auto Scaling
# ============================================================

locals {
  name_prefix = "${var.project}-${var.environment}"
}

# ── ECS Cluster ───────────────────────────────────────────────
resource "aws_ecs_cluster" "main" {
  name = "${local.name_prefix}-cluster"
  setting {
    name  = "containerInsights"
    value = "disabled"
  }
  tags = { Name = "${local.name_prefix}-cluster" }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 1
  }
}

# ── IAM Roles ─────────────────────────────────────────────────
resource "aws_iam_role" "ecs_execution" {
  name = "${local.name_prefix}-ecs-execution-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# AmazonECSTaskExecutionRolePolicy does not include secretsmanager:GetSecretValue,
# which the execution role needs to inject the task definition's `secrets` block.
# Optional — only created when execution_role_secrets_arn_pattern is set.
resource "aws_iam_role_policy" "ecs_execution_secrets" {
  count = var.execution_role_secrets_arn_pattern != null ? 1 : 0

  name = "${local.name_prefix}-ecs-execution-secrets"
  role = aws_iam_role.ecs_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [var.execution_role_secrets_arn_pattern]
    }]
  })
}

resource "aws_iam_role" "ecs_task" {
  name = "${local.name_prefix}-ecs-task-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}
# AWS managed policy required for ECS Exec (execute-command) — grants ssmmessages:
# CreateControlChannel/CreateDataChannel/OpenControlChannel/OpenDataChannel on the task role.
# Account 1 already has this attached out-of-band (not in prior Terraform state) — same
# class of drift as ecs_execution_secrets above. AttachRolePolicy is idempotent, so applying
# this where it already exists in AWS is safe (no EntityAlreadyExists on this resource type).
resource "aws_iam_role_policy_attachment" "ecs_task_ssm" {
  role       = aws_iam_role.ecs_task.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "ecs_task_policy" {
  name = "${local.name_prefix}-ecs-task-policy"
  role = aws_iam_role.ecs_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject", "s3:PutObject", "s3:ListBucket",
          "secretsmanager:GetSecretValue",
          "sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage",
          "logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents",
          "bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = "*"
      },
      # AA-380 — cloudwatch:PutMetricData has no ARN-scoped Resource (always "*"
      # per AWS IAM); the cloudwatch:namespace condition key is the only way to
      # restrict which namespace this role can write to. Scoped to "acp" — the
      # sole custom-metric namespace in use (AA-141 api/routers/acp_health.py,
      # AA-362 services/acp_produce/metrics.py) — not a wildcard grant.
      {
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" = "acp"
          }
        }
      }
    ]
  })
}

# ── CloudWatch Log Group ──────────────────────────────────────
resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${local.name_prefix}"
  retention_in_days = 14
}

# ── ECR Repository ────────────────────────────────────────────
resource "aws_ecr_repository" "api" {
  name                 = "${local.name_prefix}-api"
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
  tags = { Name = "${local.name_prefix}-api" }
}

resource "aws_ecr_lifecycle_policy" "api" {
  repository = aws_ecr_repository.api.name
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

# ── Task Definition ───────────────────────────────────────────
resource "aws_ecs_task_definition" "api" {
  family                   = "${local.name_prefix}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "api"
    image     = "${aws_ecr_repository.api.repository_url}:latest"
    essential = true
    portMappings = [{ containerPort = 8000, protocol = "tcp" }]
    environment = concat([
      { name = "PORT",                 value = "8000" },
      { name = "ENVIRONMENT",          value = var.environment },
      { name = "PROJECT",              value = var.project },
      { name = "AWS_REGION",           value = var.aws_region },
      { name = "STEP_FUNCTIONS_ARN",   value = var.step_functions_arn },
      { name = "SF_BATCH_THRESHOLD",   value = tostring(var.sf_batch_threshold) },
      { name = "BRONZE_BUCKET",        value = var.bronze_bucket_name },
      ],
      var.redis_host != null ? [{ name = "REDIS_HOST", value = var.redis_host }] : []
    )
    secrets = [
      { name = "DATABASE_URL",       valueFrom = var.secret_rds_arn },
      { name = "OPENAI_API_KEY",     valueFrom = var.secret_openai_arn },
      # { name = "LANGFUSE_SECRET_KEY", valueFrom = var.secret_langfuse_arn },            # AA-23: removed
      { name = "ADMIN_SECRET",        valueFrom = var.secret_admin_arn },
      # { name = "LANGFUSE_PUBLIC_KEY", valueFrom = var.secret_langfuse_public_key_arn }, # AA-23: removed
      # { name = "LANGFUSE_HOST",       valueFrom = var.secret_langfuse_host_arn },        # AA-23: removed
      { name = "ANTHROPIC_API_KEY",   valueFrom = var.secret_anthropic_arn },
      { name = "DATAFORSEO_LOGIN",    valueFrom = "${var.secret_dataforseo_arn}:login::" },
      { name = "DATAFORSEO_PASSWORD", valueFrom = "${var.secret_dataforseo_arn}:password::" },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "api"
      }
    }
    healthCheck = {
      command     = ["CMD-SHELL", "curl -f http://localhost:8000/health || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 60
    }
  }])

  tags = { Name = "${local.name_prefix}-api-task" }
}

# ── ECS Service ───────────────────────────────────────────────
resource "aws_ecs_service" "api" {
  name            = "${local.name_prefix}-api"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = var.service_desired_count

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

  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.sg_app_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = "api"
    container_port   = 8000
  }

  enable_execute_command = true

  lifecycle {
    ignore_changes = [desired_count, task_definition]
  }

  depends_on = [aws_iam_role_policy_attachment.ecs_execution]

  tags = { Name = "${local.name_prefix}-api-service" }
}

# ── Auto Scaling ──────────────────────────────────────────────
resource "aws_appautoscaling_target" "api" {
  max_capacity       = 10
  min_capacity       = var.service_desired_count
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.api.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "cpu_scale_out" {
  name               = "${local.name_prefix}-cpu-scale-out"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.api.resource_id
  scalable_dimension = aws_appautoscaling_target.api.scalable_dimension
  service_namespace  = aws_appautoscaling_target.api.service_namespace
  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 70.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

resource "aws_appautoscaling_policy" "memory_scale_out" {
  name               = "${local.name_prefix}-memory-scale-out"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.api.resource_id
  scalable_dimension = aws_appautoscaling_target.api.scalable_dimension
  service_namespace  = aws_appautoscaling_target.api.service_namespace
  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
    target_value       = 80.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}
