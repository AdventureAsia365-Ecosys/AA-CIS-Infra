# =============================================================================
# AA-993 Phase E slice I1 (root ADR 0017 decision 6, design §2 I1, critic point 1): the narrow role the
# expand-migration auto-apply (migration-apply.yml, slice M3) assumes instead of aa-cis-infra-tf-apply.
#
#   aa-cis-infra-db-auto-apply   AA-CIS-Infra jobs in the environment `dev-db-auto`, on refs/heads/main only.
#                                Enough to run ONE one-off task of the migrator family exactly the way
#                                .github/scripts/migrator-task.sh does for DB Migrate: register a per-run
#                                revision of aa-cis-dev-db-migrate (image swapped), run it in the CIS cluster,
#                                read its log, deregister it; upload the runner + SQL under one S3 prefix and
#                                presign them. Nothing else: no Terraform state, no secret, no RDS API, no IAM
#                                write, no other task family, no service update.
#
# What the task itself can do is unchanged: it runs under the migrator task role (db_migrator.tf), which is
# what reads the DSN. This role only passes that role (and the execution role) to ECS.
#
# Bootstrap object (like aa-cis-infra-tf-plan / -apply, cicd_split.tf header): the name is outside
# aa-*-dev-*, so the CI apply role is denied every write to it (tf_apply_boundary DenyRoleWritesOutsideStack).
# A CI terraform-apply whose plan creates or changes it fails with AccessDenied by design; a human applies
# this file with the MFA admin profile from an up-to-date main checkout (lesson S240):
#   terraform plan -target=aws_iam_role.db_auto_apply -target=aws_iam_role_policy.db_auto_apply
# then apply the same targets. Rollback: terraform destroy with the same targets (no workflow uses the role
# until M3 merges; the proof workflow db-auto-apply-role-check.yml then fails at the OIDC step, nothing else).
#
# Trust: `environment:dev-db-auto` (the sub when a job sets an environment) AND the `ref` claim main, the same
# double gate as aa-cis-dev-app-deploy (AA-866: AWS evaluates `ref` for GitHub tokens). The environment's
# deployment-branch rule (main only, tools/github/db_auto_apply_gate.sh) is the third gate, and the ruleset on
# main (same script: PR required, no direct push, ci-bot included) is what keeps the code that runs here
# reviewed. Those GitHub-side rules exist on GitHub Free only while AA-CIS-Infra is public (root ADR 0014);
# going private sets DB_AUTO_APPLY=false (ADR 0017 decision 8, Q16).
#
# Permissions boundary: aa-workload-boundary (no IAM writes, no account/org), the boundary every non-bootstrap
# CI-adjacent role carries. Cost: $0 (IAM).
# =============================================================================

locals {
  db_auto_apply_role_name = "aa-cis-infra-db-auto-apply"

  # S3 prefix of the auto-apply uploads (runner + SQL, presigned for the task). M3's migration-apply.yml must use
  # it; DB Migrate keeps db-migrate/* under the apply role.
  db_auto_apply_s3_prefix = "db-auto-apply"

  db_migrate_task_def_arns = [
    "arn:aws:ecs:${var.aws_region}:${var.account_id}:task-definition/${local.db_migrate_family}:*",
  ]
  # migrator-task.sh prepare reads the api service (its image and subnets); nothing else of the service.
  db_auto_apply_api_service_arn = "arn:aws:ecs:${var.aws_region}:${var.account_id}:service/${module.ecs.cluster_name}/${local.name_prefix}-api"
}

resource "aws_iam_role" "db_auto_apply" {
  name                 = local.db_auto_apply_role_name
  description          = "AA-993 I1: AA-CIS-Infra migration auto-apply (environment dev-db-auto, main only): run the migrator task"
  permissions_boundary = aws_iam_policy.workload_boundary.arn
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github_actions.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        # Only a job with `environment: dev-db-auto` gets this sub; a job without an environment (pull_request,
        # ref:...) or in `prod` / `dev` gets another one. The ref claim keeps a branch run out even if the
        # environment's branch rule is ever removed.
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = ["${local.oidc_sub_cis_infra}:environment:dev-db-auto"]
          "token.actions.githubusercontent.com:ref" = "refs/heads/main"
        }
      }
    }]
  })

  tags = local.shared_tags
}

resource "aws_iam_role_policy" "db_auto_apply" {
  name = "${local.db_auto_apply_role_name}-policy"
  role = aws_iam_role.db_auto_apply.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # migrator-task.sh: list + describe the family's revisions (pick_base), describe the api task definition
        # (its image). These two actions have no resource-level scoping.
        Sid      = "EcsReadTaskDefinitions"
        Effect   = "Allow"
        Action   = ["ecs:ListTaskDefinitions", "ecs:DescribeTaskDefinition"]
        Resource = "*"
      },
      {
        # The api service's current image and network configuration (read only).
        Sid      = "EcsDescribeApiService"
        Effect   = "Allow"
        Action   = ["ecs:DescribeServices"]
        Resource = local.db_auto_apply_api_service_arn
      },
      {
        # One per-run revision of aa-cis-dev-db-migrate. Not the CIS, Booking or CRM families.
        Sid      = "EcsRegisterMigratorRevision"
        Effect   = "Allow"
        Action   = ["ecs:RegisterTaskDefinition"]
        Resource = local.db_migrate_task_def_arns
      },
      {
        # DeregisterTaskDefinition is not resource-scoped in the ECS service authorization reference, so the
        # scope is the script: migrator-task.sh deregister refuses any ARN outside the migrator family. Worst
        # case of a misuse: a deregistered revision (running tasks and services keep running).
        Sid      = "EcsDeregisterRevision"
        Effect   = "Allow"
        Action   = ["ecs:DeregisterTaskDefinition"]
        Resource = "*"
      },
      {
        # Run the per-run revision in the CIS cluster only.
        Sid      = "EcsRunMigratorTask"
        Effect   = "Allow"
        Action   = ["ecs:RunTask"]
        Resource = local.db_migrate_task_def_arns
        Condition = {
          ArnEquals = { "ecs:cluster" = module.ecs.cluster_arn }
        }
      },
      {
        # `aws ecs wait tasks-stopped` and the exit code (describe-tasks). Tasks of this cluster only.
        Sid      = "EcsDescribeTasks"
        Effect   = "Allow"
        Action   = ["ecs:DescribeTasks"]
        Resource = "arn:aws:ecs:${var.aws_region}:${var.account_id}:task/${module.ecs.cluster_name}/*"
      },
      {
        # Registering and running a revision that names the migrator roles needs PassRole on exactly these two.
        Sid      = "PassMigratorRoles"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = [aws_iam_role.db_migrate_task.arn, aws_iam_role.db_migrate_execution.arn]
        Condition = {
          StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" }
        }
      },
      {
        # The api subnets' VPC and the security group aa-cis-dev-sg-db-migrate (migrator-task.sh prepare).
        Sid      = "Ec2DescribeNetwork"
        Effect   = "Allow"
        Action   = ["ec2:DescribeSubnets", "ec2:DescribeSecurityGroups"]
        Resource = "*"
      },
      {
        # Runner + SQL uploads, the presigned GETs the task makes (a presigned URL carries the signer's rights,
        # so GetObject is needed), and the clean-up. One prefix of the bronze bucket.
        Sid      = "S3AutoApplyPrefix"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
        Resource = "${module.s3.bronze_bucket_arn}/${local.db_auto_apply_s3_prefix}/*"
      },
      {
        # `aws s3 rm --recursive` lists the run's prefix first.
        Sid      = "S3ListAutoApplyPrefix"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = module.s3.bronze_bucket_arn
        Condition = {
          StringLike = { "s3:prefix" = ["${local.db_auto_apply_s3_prefix}/*"] }
        }
      },
      {
        # The task's log (stream migrate/migrate/<task id> in the CIS log group). Read only.
        Sid      = "LogsReadMigratorStreams"
        Effect   = "Allow"
        Action   = ["logs:GetLogEvents"]
        Resource = "${module.ecs.log_group_arn}:log-stream:migrate/migrate/*"
      },
    ]
  })
}

output "db_auto_apply_role_arn" {
  value = aws_iam_role.db_auto_apply.arn
}
