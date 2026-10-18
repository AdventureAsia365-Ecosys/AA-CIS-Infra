# =============================================================================
# X1 plan S11 (AA-852, ADR 0004b decision 4): the DB migrator task definition, its two roles and the
# two new DSN secret containers. EXPAND only: nothing runs this family until S12 points DB Migrate,
# Schema Dump and the isolation probe at it (today they run as an override of the CIS api service's
# current task definition, under the CIS task role, which reads every secret).
#
# Image. Containers cannot override the image in run-task, and the CIS image tag changes on every
# deploy (immutable dev-<sha>, AA-869). So this revision carries the same ":latest" placeholder as the
# api and worker task definitions (modules/ecs/main.tf), and S12 does what DB Migrate does today in
# spirit, "run the image the api runs now": per run, read the api service's task definition image,
# register a revision of this family copied from the latest one with only containerDefinitions[0].image
# swapped, and run that revision by ARN (the AA-Booking deploy pattern, booking.tf). Terraform keeps
# tracking its own revision; extra revisions registered by the workflow are not drift. Apply-role
# needs for that: ecs:RegisterTaskDefinition (AmazonECS_FullAccess) and iam:PassRole on the two
# roles below (IAMRoleManageStack, aa-*-dev-*), both already granted.
#
# Command. The default command exits non-zero on purpose: every run supplies its own command in
# containerOverrides, and a run without one must not start the api server with the master DSN.
#
# Roles: names inside aa-*-dev-* and the workload boundary, so the CI apply role may create and pass
# them (cicd_split.tf DenyCreateRoleWithoutWorkloadBoundary, tf_managed_role_arns). No Bedrock, no
# ECS Exec (no ssmmessages), no S3 read (scripts and SQL arrive through presigned URLs).
#
# Cost: roles, task definition and security group are free; the two secrets ~$0.80/month.
# =============================================================================

locals {
  db_migrate_family    = "${local.name_prefix}-db-migrate"
  db_migrate_container = "migrate"

  # Secret ARN pattern of a secret Terraform does not manage (Secrets Manager appends "-" + 6 chars).
  secret_arn_prefix = "arn:aws:secretsmanager:${var.aws_region}:${var.account_id}:secret:"

  # DSN secrets the task itself reads with boto3 (isolation probe logins, S12 set-password):
  # master (probe catalog login + the CIS runtime secret while the api still runs on it), the tenant
  # pool, the two new X1 logins, and the Booking / TripPlanner runtime logins.
  db_migrate_task_secret_arns = [
    module.secrets.rds_secret_arn,
    "${local.secret_arn_prefix}${var.project}/${var.environment}/rds-app-user-??????",
    aws_secretsmanager_secret.rds_cis_app.arn,
    aws_secretsmanager_secret.db_migrator.arn,
    aws_secretsmanager_secret.booking_db.arn,
    aws_secretsmanager_secret.tripplanner_db.arn,
  ]

  # The only S3 write a migrator task makes itself: db/schema_dump.py put_object of
  # db-schema-dump/<run id>/schema.json (db-schema-dump.yml DUMP_KEY). The probe returns its result
  # through the task log (PROBE lines), not S3, so it gets no S3 grant. Workflow-side copies
  # (db-schema-dump/latest.json, uploads of runner/SQL) use the CI role, not this one.
  db_migrate_s3_put_arns = [
    "${module.s3.bronze_bucket_arn}/db-schema-dump/*",
  ]
}

# -----------------------------------------------------------------------------
# Secret containers (no value in Terraform). Same pattern as booking_db (booking.tf): Nghiệp writes
# the DSN in the Console (XD2 / SEC-2), so Terraform never holds or reads it. Deliberately NOT the
# tripplanner_db pattern (REPLACE_ME version + ignore_changes): an aws_secretsmanager_secret_version
# is read on every refresh, so it would have to join local.tf_plan_secret_arns (cicd_split.tf,
# bootstrap = human MFA apply) and the read-only plan role would then read two DSNs.
# Under aa-cis/dev/* so the CIS execution role's existing pattern can inject rds-cis-app in S18.
# -----------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "rds_cis_app" {
  name                    = "${var.project}/${var.environment}/rds-cis-app"
  description             = "X1 (AA-852/AA-860): DSN of LOGIN role cis_app, the CIS api + worker runtime (S18). Value set by hand in the Console (S17), then DB Migrate mode=set-password."
  recovery_window_in_days = var.environment == "dev" ? 0 : 30
  tags                    = local.common_tags
}

resource "aws_secretsmanager_secret" "db_migrator" {
  name                    = "${var.project}/${var.environment}/db-migrator"
  description             = "X1 (AA-852): DSN of LOGIN role db_migrator, the DB Migrate login from S22. Value set by hand in the Console (S20/S22), then DB Migrate mode=set-password."
  recovery_window_in_days = var.environment == "dev" ? 0 : 30
  tags                    = local.shared_tags
}

# -----------------------------------------------------------------------------
# Roles
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "db_migrate_assume" {
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

resource "aws_iam_role" "db_migrate_execution" {
  name                 = "${local.db_migrate_family}-execution-role"
  permissions_boundary = aws_iam_policy.workload_boundary.arn
  assume_role_policy   = data.aws_iam_policy_document.db_migrate_assume.json
  tags                 = local.shared_tags

  depends_on = [time_sleep.wait_for_iam_propagation]
}

# ECS agent: pull the CIS image, write stream prefix "migrate" of the CIS log group, inject the
# master DSN (S11..S21) and, from S22, the db_migrator DSN. AmazonECSTaskExecutionRolePolicy is NOT
# attached (ECR pull on every repo, logs on every group).
resource "aws_iam_role_policy" "db_migrate_execution" {
  name = "${local.db_migrate_family}-execution"
  role = aws_iam_role.db_migrate_execution.id

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
        Sid      = "EcrPullCisRepo"
        Effect   = "Allow"
        Action   = ["ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"]
        Resource = module.ecs.ecr_repository_arn
      },
      {
        Sid      = "WriteMigrateLogStreams"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${module.ecs.log_group_arn}:log-stream:${local.db_migrate_container}/*"
      },
      {
        Sid    = "InjectMigratorDsn"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = [
          module.secrets.rds_secret_arn,
          aws_secretsmanager_secret.db_migrator.arn,
        ]
      },
    ]
  })
}

resource "aws_iam_role" "db_migrate_task" {
  name                 = "${local.db_migrate_family}-task-role"
  permissions_boundary = aws_iam_policy.workload_boundary.arn
  assume_role_policy   = data.aws_iam_policy_document.db_migrate_assume.json
  tags                 = local.shared_tags

  depends_on = [time_sleep.wait_for_iam_propagation]
}

resource "aws_iam_role_policy" "db_migrate_task" {
  name = "${local.db_migrate_family}-task"
  role = aws_iam_role.db_migrate_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadDsnSecrets"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = local.db_migrate_task_secret_arns
      },
      {
        Sid      = "PutSchemaDump"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = local.db_migrate_s3_put_arns
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# Task definition (0.25 vCPU / 0.5 GB, container "migrate", log stream migrate/migrate/<task id>).
# -----------------------------------------------------------------------------
resource "aws_ecs_task_definition" "db_migrate" {
  family                   = local.db_migrate_family
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.db_migrate_execution.arn
  task_role_arn            = aws_iam_role.db_migrate_task.arn

  container_definitions = jsonencode([{
    name      = local.db_migrate_container
    image     = "${module.ecs.ecr_repository_url}:latest" # placeholder; S12 swaps in the api's image per run
    essential = true
    command   = ["python3", "-c", "raise SystemExit('aa-cis-dev-db-migrate: the command is supplied per run (containerOverrides)')"]
    # ⚠️ HAND EDIT (Nghiệp, VSCode) before merge: replace the placeholder name below with the name of
    # the DSN environment variable that db/run_migration.py reads (main(): the value passed to
    # connect(), line ~1184). It is the same name as the FIRST entry of the api task definition's
    # secrets list (modules/ecs/main.tf), which db/schema_dump.py and db/isolation_probe.py read too.
    # Underscore env var names are never written by the agent (workspace rule).
    secrets = [
      { name = "__NGHIEP_EDIT_DB_ENV_NAME__", valueFrom = module.secrets.rds_secret_arn },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = module.ecs.log_group_name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = local.db_migrate_container
      }
    }
  }])

  tags = merge(local.shared_tags, { Name = "${local.db_migrate_family}-task" })
}

output "db_migrate_task_definition_arn" {
  value = aws_ecs_task_definition.db_migrate.arn
}

output "db_migrate_security_group_id" {
  value = aws_security_group.db_migrate.id
}
