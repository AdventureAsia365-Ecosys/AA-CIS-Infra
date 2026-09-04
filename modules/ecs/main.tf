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
      },
      # AA-459 — the first runtime-WRITE Secrets Manager use in this codebase (every prior
      # use, incl. the GetSecretValue statement above, is read-only against secrets an
      # admin/Terraform already pre-created). AA-CIS-App's api/routers/v1_integrations.py
      # (AA-457) writes one Secrets Manager secret per tenant at
      # acp/cms/{tenant_id} (create-or-update: create_secret, falling back to
      # put_secret_value on ResourceExistsException) — confirmed live 25/08/2026 via
      # CloudWatch that the task role lacked this, 502ing POST /v1/integrations/wordpress
      # for every real tenant. Deliberately a SEPARATE statement from the GetSecretValue
      # one above (that one is Resource="*", bundled with unrelated s3/sqs/logs/bedrock
      # actions) rather than widening that grant — this is scoped ONLY to the acp/cms/
      # namespace the Python code actually writes to, least-privilege, not
      # secretsmanager:* and not an unscoped Resource. secretsmanager:TagResource is
      # deliberately NOT included — confirmed by reading the real call site
      # (v1_integrations.py's create_secret(Name=secret_key, SecretString=payload) passes
      # no Tags argument), so AWS never invokes TagResource for this code path; add it
      # later only if a real future caller starts tagging secrets on create.
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:CreateSecret",
          "secretsmanager:PutSecretValue"
        ]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:005097885195:secret:acp/cms/*"
      },
      # AA-462 — same gap as AA-459 (comment above), same fix, different prefix. T11's new
      # Facebook integration (api/routers/v1_integrations.py::save_facebook()) writes to
      # acp/social/{tenant_id} — deliberately NOT acp/cms/{tenant_id} (a Page Access Token
      # isn't a CMS credential, and a tenant connecting both needs two independent secrets,
      # see that file's own header comment) — so the acp/cms/* grant above doesn't cover it.
      # Confirmed live before this PR: POST /v1/integrations/facebook 502'd "Could not save
      # credentials — try again" for a real tenant, identical shape to the AA-459 bug this
      # mirrors. Kept as its own statement (not widened into acp/cms/* or acp/*) for the same
      # least-privilege reasoning AA-459 already established — scoped only to the namespace
      # the Python code actually writes to.
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:CreateSecret",
          "secretsmanager:PutSecretValue"
        ]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:005097885195:secret:acp/social/*"
      }
    ]
  })
}

# AA-257 — GET /admin/infra/status (live ECS/RDS/NAT/ElastiCache health, aa-cis-dev-api's
# admin_pipeline.py) and the pre-existing GET /admin/metrics/spot-workers (built earlier,
# never actually granted this) both need read-only describe/list access this role has never
# had. Confirmed live before this PR: /admin/metrics/spot-workers has been returning
# AccessDeniedException on ecs:ListTasks in prod this whole time (degrades to zeros — no
# outage, but silently non-functional since it shipped).
#
# All Resource="*" — none of ecs:Describe*/List*, rds:DescribeDBInstances,
# ec2:DescribeInstances, elasticache:DescribeCacheClusters, or ecr:DescribeImages support
# resource-level ARN scoping in IAM (same constraint documented on the cloudwatch:PutMetricData
# statement above); every action here is describe/list/read-only, no write/delete verb in
# this statement, scoped to exactly the AWS API surface both endpoints' code actually calls.
#
# Deliberately opened as its own PR, NOT auto-merged — per the repo-wide "no self-added IAM
# via Terraform auto-merge" convention (same one AA-256's Cost Explorer ask hit), IAM changes
# get a manual look regardless of CI outcome.
resource "aws_iam_role_policy" "ecs_task_infra_status_readonly" {
  name = "${local.name_prefix}-ecs-task-infra-status-readonly"
  role = aws_iam_role.ecs_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecs:DescribeServices",
          "ecs:DescribeTasks",
          "ecs:ListTasks",
          "ecs:DescribeTaskDefinition",
          "ecr:DescribeImages",
          "rds:DescribeDBInstances",
          "ec2:DescribeInstances",
          "elasticache:DescribeCacheClusters"
        ]
        Resource = "*"
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
      { name = "JUDGE_MODEL",          value = var.judge_model },
      ],
      var.redis_host != null ? [{ name = "REDIS_HOST", value = var.redis_host }] : []
    )
    secrets = [
      { name = "DATABASE_URL",       valueFrom = var.secret_rds_arn },
      { name = "OPENAI_API_KEY",     valueFrom = var.secret_openai_arn },
      # { name = "LANGFUSE_SECRET_KEY", valueFrom = var.secret_langfuse_arn },            # AA-23: removed
      { name = "ADMIN_SECRET",        valueFrom = var.secret_admin_arn },
      { name = "JWT_SECRET",          valueFrom = var.secret_jwt_arn },
      # { name = "LANGFUSE_PUBLIC_KEY", valueFrom = var.secret_langfuse_public_key_arn }, # AA-23: removed
      # { name = "LANGFUSE_HOST",       valueFrom = var.secret_langfuse_host_arn },        # AA-23: removed
      # ANTHROPIC_API_KEY: removed AA-518 — provisioned but 0 callers in app code (direct-Anthropic
      # calls never shipped; the app only ever calls Claude via the Bedrock satellite pattern,
      # AA-296/397). Secret aa-cis/dev/anthropic-key itself deleted from Secrets Manager same PR.
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

  # AA-176 (scope item 2): a failed rolling deploy (new task never reaches healthy — bad image,
  # crashed startup, failing health check) used to just sit there consuming the deployment's
  # maximumPercent headroom indefinitely with no automatic rollback -- required a human to
  # notice and manually re-deploy the previous task definition revision. This does not touch
  # image tagging strategy (still :latest per this repo's own current convention -- see
  # AA-CIS-App CLAUDE.md "Image tag: always :latest" -- deliberately NOT changed here, that's
  # a separate, explicitly-conflicting decision this PR does not make) -- ECS's circuit
  # breaker triggers on deployment health regardless of tag scheme, and auto-rolls the SERVICE
  # back to the last-known-good task definition revision when the new deployment's tasks fail
  # to stabilize, closing the "nobody noticed, deploy just hangs broken" half of this gap on
  # its own.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

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
