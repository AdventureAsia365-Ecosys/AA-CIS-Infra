# =============================================================================
# AA-806 — split the shared CI role (aa-cis-dev-role, cicd.tf) by job.
#
# aa-cis-dev-role is assumed by two repos for three very different jobs: AA-CIS-App deploys an
# image, AA-CIS-Infra plans on every PR, and AA-CIS-Infra applies Terraform / runs DB Migrate. All
# three get the same RDS/Secrets/ECS/S3/Lambda full access plus iam:CreateRole/PassRole on "*".
# This file adds one role per job:
#
#   aa-cis-dev-app-deploy   AA-CIS-App deploy-dev.yml + eval-regression.yml (environment:dev).
#                           Push to the CIS ECR repo, add revisions to the CIS task families, point
#                           the CIS services at them, PassRole on the CIS task/execution roles only.
#   aa-cis-infra-tf-plan    AA-CIS-Infra terraform-plan.yml (pull_request). Read only.
#   aa-cis-infra-tf-apply   AA-CIS-Infra terraform-apply.yml + db-migrate.yml (environment:prod).
#                           Same grants as aa-cis-dev-role (so the cut-over is a drop-in), capped by
#                           the permissions boundary aa-cis-infra-tf-apply-boundary.
#
# Bootstrap: the three roles and the two boundary policies are NOT manageable by the apply role
# (their names are outside aa-*-dev-*, and the boundary denies writes to the boundary policies).
# They are applied by a human with the MFA admin profile, like the acc1/acc3 roots. A CI apply of a
# change to them fails with AccessDenied by design.
#
# aa-cis-dev-role stays until both repos have switched (cut-over plan: docs/ci-role-split.md).
# =============================================================================

locals {
  # Immutable OIDC subject prefixes (see local.cicd_oidc_subjects in cicd.tf for how they were read).
  oidc_sub_cis_app   = "repo:AdventureAsia365-Ecosys@276539096/AA-CIS-App@1212291079"
  oidc_sub_cis_infra = "repo:AdventureAsia365-Ecosys@276539096/AA-CIS-Infra@1212290412"

  app_deploy_role_name = "${local.name_prefix}-app-deploy"
  tf_plan_role_name    = "aa-cis-infra-tf-plan"
  tf_apply_role_name   = "aa-cis-infra-tf-apply"

  # Roles Terraform in this root may create, change, tag or pass. Every role in accounts/aa365 and
  # its modules is aa-<app>-<env>-*, except the NAT instance role (modules/vpc), which predates the
  # convention and is listed by its exact name.
  tf_managed_role_arns = [
    "arn:aws:iam::${var.account_id}:role/aa-*-${var.environment}-*",
    "arn:aws:iam::${var.account_id}:role/aa-cis-nat-instance-role",
  ]

  # CIS app objects the app deploy role may touch.
  cis_task_families = ["${local.name_prefix}-api", "${local.name_prefix}-worker"]
  cis_task_def_arns = [
    for f in local.cis_task_families : "arn:aws:ecs:${var.aws_region}:${var.account_id}:task-definition/${f}:*"
  ]
  cis_service_arns = [
    for s in local.cis_task_families : "arn:aws:ecs:${var.aws_region}:${var.account_id}:service/${module.ecs.cluster_name}/${s}"
  ]

  # Statements of aa-cis-dev-role that the apply role replaces with name-scoped versions below.
  tf_apply_superseded_sids = [
    "IAMRoleManage",                   # CreateRole/PassRole/... on "*" -> tf_managed_role_arns
    "EventBridgeSchedulerRoleTagging", # four per-name iam:TagRole grants -> one pattern
    "TripPlannerRoleTagging",
    "AgentSessionRoleTagging",
    "BookingRoleTagging",
  ]
}

# -----------------------------------------------------------------------------
# Permissions boundaries
# -----------------------------------------------------------------------------

# Boundary for roles that run workloads or deploy apps (ECS tasks, Lambdas, app deploy roles). It
# allows everything the identity policy allows except IAM writes (iam:PassRole stays allowed) and
# account/organization changes. The apply role may only create roles that carry this boundary.
data "aws_iam_policy_document" "workload_boundary" {
  statement {
    sid       = "AllowWithinIdentityPolicy"
    actions   = ["*"]
    resources = ["*"]
  }

  statement {
    sid    = "DenyIamWrites"
    effect = "Deny"
    actions = [
      "iam:Add*", "iam:Attach*", "iam:Change*", "iam:Create*", "iam:Deactivate*", "iam:Delete*",
      "iam:Detach*", "iam:Enable*", "iam:Put*", "iam:Remove*", "iam:Reset*", "iam:Resync*",
      "iam:Set*", "iam:Tag*", "iam:Untag*", "iam:Update*", "iam:Upload*",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "DenyAccountAndOrg"
    effect    = "Deny"
    actions   = ["account:*", "organizations:*"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "workload_boundary" {
  name        = "aa-workload-boundary"
  description = "AA-806: permissions boundary for workload and app-deploy roles (no IAM writes)"
  policy      = data.aws_iam_policy_document.workload_boundary.json
}

# Boundary of the Terraform apply role. Its identity policy keeps the broad service grants of
# aa-cis-dev-role; this boundary is what stops it from escalating through IAM.
data "aws_iam_policy_document" "tf_apply_boundary" {
  statement {
    sid       = "AllowWithinIdentityPolicy"
    actions   = ["*"]
    resources = ["*"]
  }

  # Create/change/tag/pass only roles named like this stack's roles. The bootstrap roles in this
  # file (aa-cis-infra-tf-*) and any role of another system are out of reach.
  statement {
    sid    = "DenyRoleWritesOutsideStack"
    effect = "Deny"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:UpdateRole", "iam:UpdateRoleDescription",
      "iam:UpdateAssumeRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:PutRolePermissionsBoundary",
      "iam:TagRole", "iam:UntagRole", "iam:PassRole",
    ]
    not_resources = local.tf_managed_role_arns
  }

  # A role the apply role creates must carry the workload boundary. StringNotEquals is also true
  # when no boundary is passed, so CreateRole without one is denied.
  statement {
    sid       = "DenyCreateRoleWithoutWorkloadBoundary"
    effect    = "Deny"
    actions   = ["iam:CreateRole", "iam:PutRolePermissionsBoundary"]
    resources = ["*"]
    condition {
      test     = "StringNotEquals"
      variable = "iam:PermissionsBoundary"
      values   = [aws_iam_policy.workload_boundary.arn]
    }
  }

  # Phase 3 switch (docs/ci-role-split.md): once every aa-*-dev-* role carries the workload
  # boundary, also require it on policy writes to existing roles. Off by default because no
  # existing role has a boundary yet, so turning it on now would block every role policy change.
  dynamic "statement" {
    for_each = var.tf_apply_require_boundary_on_role_policy_writes ? [1] : []
    content {
      sid    = "DenyRolePolicyWritesWithoutWorkloadBoundary"
      effect = "Deny"
      actions = [
        "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:AttachRolePolicy", "iam:DetachRolePolicy",
      ]
      resources = ["*"]
      condition {
        test     = "StringNotEquals"
        variable = "iam:PermissionsBoundary"
        values   = [aws_iam_policy.workload_boundary.arn]
      }
    }
  }

  statement {
    sid       = "DenyBoundaryRemoval"
    effect    = "Deny"
    actions   = ["iam:DeleteRolePermissionsBoundary"]
    resources = ["*"]
  }

  statement {
    sid    = "DenyBoundaryPolicyEdits"
    effect = "Deny"
    actions = [
      "iam:CreatePolicyVersion", "iam:DeletePolicy", "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion", "iam:TagPolicy", "iam:UntagPolicy",
    ]
    resources = [
      aws_iam_policy.workload_boundary.arn,
      "arn:aws:iam::${var.account_id}:policy/aa-cis-infra-tf-apply-boundary",
    ]
  }

  # No users, keys, groups or account/org changes, whatever the identity policy says later.
  statement {
    sid    = "DenyIdentityAndAccountAdmin"
    effect = "Deny"
    actions = [
      "iam:CreateUser", "iam:CreateAccessKey", "iam:CreateLoginProfile", "iam:UpdateLoginProfile",
      "iam:AttachUserPolicy", "iam:PutUserPolicy", "iam:AddUserToGroup", "iam:AttachGroupPolicy",
      "iam:PutGroupPolicy", "iam:CreateGroup", "account:*", "organizations:*",
    ]
    resources = ["*"]
  }

  # Terraform never assumes another role from this root. Denying it closes the path "rewrite the
  # trust policy of an aa-*-dev-* role to trust me, then assume it" (that role has no boundary yet).
  statement {
    sid       = "DenyAssumeRole"
    effect    = "Deny"
    actions   = ["sts:AssumeRole"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "tf_apply_boundary" {
  name        = "aa-cis-infra-tf-apply-boundary"
  description = "AA-806: permissions boundary of the AA-CIS-Infra Terraform apply role"
  policy      = data.aws_iam_policy_document.tf_apply_boundary.json
}

# -----------------------------------------------------------------------------
# aa-cis-dev-app-deploy — AA-CIS-App deploy (and the on-demand eval workflow)
# -----------------------------------------------------------------------------
resource "aws_iam_role" "cis_app_deploy" {
  name                 = local.app_deploy_role_name
  description          = "AA-806: AA-CIS-App deploy-dev / eval-regression (environment dev)"
  permissions_boundary = aws_iam_policy.workload_boundary.arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github_actions.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        # Every job that assumes this role (deploy-dev.yml build-and-push + deploy,
        # eval-regression.yml eval) runs in the `dev` environment, so the sub context is
        # `environment:dev` (the ref is not part of the sub when an environment is set). "main
        # only" is enforced by the `dev` environment's deployment-branch rule (main), which must
        # stay set in the AA-CIS-App repo settings. pull_request runs and other repos are denied.
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = ["${local.oidc_sub_cis_app}:environment:dev"]
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "cis_app_deploy" {
  name = "${local.app_deploy_role_name}-policy"
  role = aws_iam_role.cis_app_deploy.id

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
        # api and worker run the same image from aa-cis-dev-api; the pattern also covers a future
        # aa-cis-dev-* repo but not aa-booking-dev-api or aa-tripplanner-*.
        Sid    = "EcrPushCisRepos"
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
        Resource = "arn:aws:ecr:${var.aws_region}:${var.account_id}:repository/${local.name_prefix}-*"
      },
      {
        # Read only; DescribeTaskDefinition has no resource-level scoping.
        Sid      = "EcsDescribeTaskDefinition"
        Effect   = "Allow"
        Action   = ["ecs:DescribeTaskDefinition"]
        Resource = "*"
      },
      {
        # Resource-scoped: only new revisions of aa-cis-dev-api / aa-cis-dev-worker. It cannot
        # write a revision into the Booking family.
        Sid      = "EcsRegisterCisTaskDefinitions"
        Effect   = "Allow"
        Action   = ["ecs:RegisterTaskDefinition"]
        Resource = local.cis_task_def_arns
      },
      {
        Sid      = "EcsTagOnRegister"
        Effect   = "Allow"
        Action   = ["ecs:TagResource"]
        Resource = local.cis_task_def_arns
        Condition = {
          StringEquals = { "ecs:CreateAction" = "RegisterTaskDefinition" }
        }
      },
      {
        # describe-services is also what `aws ecs wait services-stable` polls.
        Sid      = "EcsDescribeCisServices"
        Effect   = "Allow"
        Action   = ["ecs:DescribeServices"]
        Resource = local.cis_service_arns
      },
      {
        # deploy-dev sets --desired-count 1 (no task definition in that call, hence IfExists) and
        # then points the service at the revision it registered (full ARN).
        Sid      = "EcsUpdateCisServices"
        Effect   = "Allow"
        Action   = ["ecs:UpdateService"]
        Resource = local.cis_service_arns
        Condition = {
          StringLikeIfExists = {
            "ecs:task-definition" = concat(local.cis_task_def_arns, [for f in local.cis_task_families : "${f}:*"])
          }
        }
      },
      {
        # eval-regression.yml picks a running api task.
        Sid      = "EcsListTasksInCisCluster"
        Effect   = "Allow"
        Action   = ["ecs:ListTasks"]
        Resource = "*"
        Condition = {
          ArnEquals = { "ecs:cluster" = module.ecs.cluster_arn }
        }
      },
      {
        Sid      = "EcsDescribeTasksInCisCluster"
        Effect   = "Allow"
        Action   = ["ecs:DescribeTasks"]
        Resource = "arn:aws:ecs:${var.aws_region}:${var.account_id}:task/${module.ecs.cluster_name}/*"
      },
      {
        # eval-regression.yml runs the eval inside the api container via ECS exec. Same blast radius
        # as deploying an image, which this role can already do.
        Sid    = "EcsExecCisCluster"
        Effect = "Allow"
        Action = ["ecs:ExecuteCommand"]
        Resource = [
          module.ecs.cluster_arn,
          "arn:aws:ecs:${var.aws_region}:${var.account_id}:task/${module.ecs.cluster_name}/*",
        ]
      },
      {
        # Registering a task definition that names these roles requires PassRole on them.
        Sid      = "PassCisTaskRoles"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = [module.ecs.execution_role_arn, module.ecs.task_role_arn]
        Condition = {
          StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" }
        }
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# aa-cis-infra-tf-plan — AA-CIS-Infra terraform-plan.yml on pull requests
# -----------------------------------------------------------------------------
resource "aws_iam_role" "tf_plan" {
  name        = local.tf_plan_role_name
  description = "AA-806: AA-CIS-Infra terraform plan on pull requests (read only)"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github_actions.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        # terraform-plan.yml runs on pull_request with no environment -> context `pull_request`.
        # Fork PRs get no OIDC token with write permissions, so only branches of this repo reach it.
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = ["${local.oidc_sub_cis_infra}:pull_request"]
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "tf_plan_readonly" {
  role       = aws_iam_role.tf_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "tf_plan" {
  name = "${local.tf_plan_role_name}-policy"
  role = aws_iam_role.tf_plan.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # plan takes the state lock.
        Sid      = "StateLock"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem", "dynamodb:DescribeTable"]
        Resource = "arn:aws:dynamodb:${var.aws_region}:${var.account_id}:table/aa-cis-tfstate-lock-${var.account_id}"
      },
      {
        # Refresh of aws_secretsmanager_secret_version resources and the dfs_balance admin-secret
        # data source reads the values. ReadOnlyAccess does not include GetSecretValue. The same
        # values are already in the state file this role reads, so this widens nothing in practice.
        Sid    = "ReadStackSecretValues"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = [
          "arn:aws:secretsmanager:${var.aws_region}:${var.account_id}:secret:${var.project}/${var.environment}/*",
          "arn:aws:secretsmanager:${var.aws_region}:${var.account_id}:secret:tripplanner/${var.environment}/*",
          "arn:aws:secretsmanager:${var.aws_region}:${var.account_id}:secret:booking/${var.environment}/*",
        ]
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# aa-cis-infra-tf-apply — AA-CIS-Infra terraform-apply.yml + db-migrate.yml (environment prod)
# -----------------------------------------------------------------------------
resource "aws_iam_role" "tf_apply" {
  name                 = local.tf_apply_role_name
  description          = "AA-806: AA-CIS-Infra terraform apply + DB Migrate (environment prod)"
  permissions_boundary = aws_iam_policy.tf_apply_boundary.arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github_actions.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        # terraform-apply.yml and db-migrate.yml both run in the `prod` environment ->
        # `environment:prod`. The environment's deployment-branch rule (main) and required reviewer
        # are what keep it to reviewed main; they must stay set in the AA-CIS-Infra repo settings.
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = ["${local.oidc_sub_cis_infra}:environment:prod"]
        }
      }
    }]
  })
}

# Same managed policies as aa-cis-dev-role (10, the default per-role quota), so the apply role can
# refresh and change everything the old role could.
resource "aws_iam_role_policy_attachment" "tf_apply_managed" {
  for_each   = toset(local.cicd_managed_policies)
  role       = aws_iam_role.tf_apply.name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "tf_apply" {
  name = "${local.tf_apply_role_name}-policy"
  role = aws_iam_role.tf_apply.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [for s in local.cicd_inline_statements : s if !contains(local.tf_apply_superseded_sids, s.Sid)],
      [
        {
          Sid    = "IAMRoleRead"
          Effect = "Allow"
          Action = [
            "iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
            "iam:ListInstanceProfilesForRole", "iam:ListRoleTags",
          ]
          Resource = "*"
        },
        {
          # IAMRoleManage of aa-cis-dev-role, scoped to the stack's role names. The boundary
          # enforces the same scope and requires the workload boundary on CreateRole.
          Sid    = "IAMRoleManageStack"
          Effect = "Allow"
          Action = [
            "iam:CreateRole", "iam:DeleteRole", "iam:UpdateRole", "iam:UpdateRoleDescription",
            "iam:UpdateAssumeRolePolicy", "iam:AttachRolePolicy", "iam:DetachRolePolicy",
            "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:PutRolePermissionsBoundary",
            "iam:PassRole",
            # Every role here is tagged by provider default_tags (replaces the four per-name
            # TagRole statements of aa-cis-dev-role).
            "iam:TagRole", "iam:UntagRole",
          ]
          Resource = local.tf_managed_role_arns
        },
        {
          # Associating the REGIONAL web ACL with the CIS / Booking REST API stages
          # (var.waf_protect_rest_api_stages) needs SetWebACL on the stage, besides
          # wafv2:AssociateWebACL.
          Sid      = "APIGatewaySetWebACL"
          Effect   = "Allow"
          Action   = ["apigateway:SetWebACL"]
          Resource = "arn:aws:apigateway:${var.aws_region}::/restapis/*/stages/*"
        },
      ],
    )
  })
}

output "cis_app_deploy_role_arn" {
  value = aws_iam_role.cis_app_deploy.arn
}

output "tf_plan_role_arn" {
  value = aws_iam_role.tf_plan.arn
}

output "tf_apply_role_arn" {
  value = aws_iam_role.tf_apply.arn
}
