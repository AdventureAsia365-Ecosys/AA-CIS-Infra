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
# Bootstrap objects, which the apply role cannot change (a CI apply of a change to them fails with
# AccessDenied by design; a human applies them with the MFA admin profile, like the acc1/acc3 roots):
#   - aa-cis-infra-tf-plan / -apply: names outside aa-*-dev-*;
#   - aa-cis-dev-app-deploy, aa-cis-dev-agent-session: inside the pattern, so explicitly denied
#     (local.tf_apply_protected_role_arns);
#   - aa-cis-dev-role (legacy, cicd.tf): explicitly denied except DeleteRole / DetachRolePolicy /
#     DeleteRolePolicy (retirement only), never PassRole;
#   - both boundary policies, and the GitHub OIDC provider (no OIDC/SAML provider writes at all).
#
# What the apply boundary does NOT stop yet (closed only by steps 3 + 4 of docs/ci-role-split.md):
# every other aa-*-dev-* role (ECS task/execution, Lambda exec, ...) has no boundary today. The apply
# role may rewrite its inline policy or trust and PassRole it to an ECS task or Lambda it can start,
# so code running under that role gets whatever IAM rights the apply role wrote into it - including
# rights the boundary denies the apply role itself. The sts:AssumeRole deny does not help there (no
# AssumeRole call is involved). Phase 3 (var.tf_apply_require_boundary_on_role_policy_writes) after
# step 4 caps such roles at the workload boundary (no IAM writes).
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
  legacy_cicd_role_arn = "arn:aws:iam::${var.account_id}:role/aa-cis-dev-role"

  # Roles Terraform in this root may create, change, tag or pass. Every role in accounts/aa365 and
  # its modules is aa-<app>-<env>-*, except the NAT instance role (modules/vpc), which predates the
  # convention and is listed by its exact name.
  tf_managed_role_arns = [
    "arn:aws:iam::${var.account_id}:role/aa-*-${var.environment}-*",
    "arn:aws:iam::${var.account_id}:role/aa-cis-nat-instance-role",
  ]

  # Roles that match tf_managed_role_arns but that the apply role must not write or pass: the app
  # deploy role created here (its permissions are the whole point of the split) and the agent
  # session role (humans' agent shells). The legacy aa-cis-dev-role is handled separately (it may be
  # dismantled, never edited upward or passed).
  tf_apply_protected_role_arns = [
    "arn:aws:iam::${var.account_id}:role/${local.app_deploy_role_name}",
    "arn:aws:iam::${var.account_id}:role/${local.name_prefix}-agent-session",
  ]

  # Every IAM role write the apply role's identity policy grants, plus PassRole.
  iam_role_write_actions = [
    "iam:CreateRole", "iam:DeleteRole", "iam:UpdateRole", "iam:UpdateRoleDescription",
    "iam:UpdateAssumeRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy",
    "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:PutRolePermissionsBoundary",
    "iam:TagRole", "iam:UntagRole", "iam:PassRole",
  ]

  # Secret values terraform plan reads on refresh: every aws_secretsmanager_secret_version in this
  # root and the dfs_balance admin-secret data source. Nothing else (no RDS DSN, JWT, OpenAI key).
  # A new aws_secretsmanager_secret_version must be added here (bootstrap: local apply), or plan
  # fails with AccessDenied on refresh after it is first applied.
  tf_plan_secret_arns = [
    aws_secretsmanager_secret.tripplanner_db.arn,
    aws_secretsmanager_secret.tripplanner_api_key.arn,
    aws_secretsmanager_secret.tripplanner_mapbox.arn,
    module.secrets.acp_webhook_secret_arn,
    module.secrets.acp_partner_api_secret_arn,
    var.secret_admin_arn,
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
    "OIDCProviderManage", # -> OIDCProviderRead; the provider is a bootstrap object
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
# aa-cis-dev-role; this boundary keeps it off the bootstrap objects, other systems' roles, users and
# keys. It does NOT by itself stop escalation through an unbounded aa-*-dev-* workload role (header
# comment); phase 3 after step 4 of the cut-over closes that.
data "aws_iam_policy_document" "tf_apply_boundary" {
  statement {
    sid       = "AllowWithinIdentityPolicy"
    actions   = ["*"]
    resources = ["*"]
  }

  # Create/change/tag/pass only roles named like this stack's roles. The bootstrap roles in this
  # file (aa-cis-infra-tf-*) and any role of another system are out of reach.
  statement {
    sid           = "DenyRoleWritesOutsideStack"
    effect        = "Deny"
    actions       = local.iam_role_write_actions
    not_resources = local.tf_managed_role_arns
  }

  # Inside the pattern but bootstrap: the app deploy role and the agent session role.
  statement {
    sid       = "DenyProtectedRoleWrites"
    effect    = "Deny"
    actions   = local.iam_role_write_actions
    resources = local.tf_apply_protected_role_arns
  }

  # Legacy aa-cis-dev-role: no boundary and IAM rights on "*", so editing its trust or passing it
  # would be a direct escalation. Only the actions that take it apart (step 3) stay possible.
  statement {
    sid    = "DenyLegacyCiRoleWrites"
    effect = "Deny"
    actions = [
      for a in local.iam_role_write_actions : a
      if !contains(["iam:DeleteRole", "iam:DetachRolePolicy", "iam:DeleteRolePolicy"], a)
    ]
    resources = [local.legacy_cicd_role_arn]
  }

  # The GitHub OIDC provider is a bootstrap object: adding an issuer or client id would let a
  # rewritten aa-*-dev-* trust accept tokens from an attacker-controlled issuer.
  statement {
    sid    = "DenyIdentityProviderWrites"
    effect = "Deny"
    actions = [
      "iam:CreateOpenIDConnectProvider", "iam:DeleteOpenIDConnectProvider",
      "iam:UpdateOpenIDConnectProviderThumbprint", "iam:AddClientIDToOpenIDConnectProvider",
      "iam:RemoveClientIDFromOpenIDConnectProvider", "iam:TagOpenIDConnectProvider",
      "iam:UntagOpenIDConnectProvider", "iam:CreateSAMLProvider", "iam:UpdateSAMLProvider",
      "iam:DeleteSAMLProvider",
    ]
    resources = ["*"]
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
  # UpdateAssumeRolePolicy and PassRole cannot be conditioned on iam:PermissionsBoundary (AWS does
  # not populate that key for them), so they are not in this statement: once every role carries
  # the workload boundary, passing or re-trusting one only ever yields bounded rights.
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

  # Terraform never assumes another role from this root. Denying it closes the direct path "rewrite
  # the trust policy of an aa-*-dev-* role to trust me, then assume it". It does not close the
  # PassRole path (header comment).
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
        # Refresh of the aws_secretsmanager_secret_version resources and the dfs_balance
        # admin-secret data source reads these values; ReadOnlyAccess has no GetSecretValue. This
        # role is assumed from any PR branch of AA-CIS-Infra, whose workflow file the PR can edit,
        # so it is limited to exactly the secrets Terraform reads (residual risk:
        # docs/ci-role-split.md).
        Sid      = "ReadStackSecretValues"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = local.tf_plan_secret_arns
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
          # enforces the same scope, carves out the bootstrap roles and requires the workload
          # boundary on CreateRole.
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
          # OIDCProviderManage of aa-cis-dev-role, read only (refresh of the provider).
          Sid    = "OIDCProviderRead"
          Effect = "Allow"
          Action = [
            "iam:GetOpenIDConnectProvider", "iam:ListOpenIDConnectProviders",
            "iam:ListOpenIDConnectProviderTags",
          ]
          Resource = "*"
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
        # ---- AA-811 bootstrap grants (S237): one local MFA apply covers SES + Route 53 (AA-811),
        # ACM (AA-818) and Cognito + its web ACL (AA-703). Inline statements, not managed policies:
        # the role already has 10 managed attachments (default per-role quota). Keep them compact:
        # all inline policies of a role share one 10,240-character limit.
        {
          # ses.tf: domain identity, DKIM/MAIL FROM attributes, configuration sets + event
          # destinations, tags. No Send*: the CI role never sends mail.
          Sid    = "SESIdentityManage"
          Effect = "Allow"
          Action = [
            "ses:CreateEmailIdentity", "ses:DeleteEmailIdentity", "ses:GetEmailIdentity",
            "ses:PutEmailIdentity*", "ses:*ConfigurationSet*", "ses:TagResource",
            "ses:UntagResource", "ses:ListTagsForResource",
          ]
          Resource = [
            "arn:aws:ses:${var.aws_region}:${var.account_id}:identity/*",
            "arn:aws:ses:${var.aws_region}:${var.account_id}:configuration-set/*",
          ]
        },
        {
          # dns.tf / ses.tf / AA-818 / AA-703 records in the lumiguides.it.com zone. No
          # DeleteHostedZone: removing the zone after the NS switch is an outage (local admin only).
          Sid    = "Route53ZoneManage"
          Effect = "Allow"
          Action = [
            "route53:Get*", "route53:List*", "route53:CreateHostedZone",
            "route53:UpdateHostedZoneComment", "route53:ChangeResourceRecordSets",
            "route53:ChangeTagsForResource",
          ]
          Resource = "*"
        },
        {
          # AA-818: API GW custom-domain certs (us-west-1) and the Cognito custom-domain cert
          # (us-east-1, ADR 0006 decision 10). RequestCertificate has no resource ARN.
          Sid    = "ACMCertManage"
          Effect = "Allow"
          Action = [
            "acm:RequestCertificate", "acm:DescribeCertificate", "acm:DeleteCertificate",
            "acm:ListCertificates", "acm:AddTagsToCertificate", "acm:RemoveTagsFromCertificate",
            "acm:ListTagsForCertificate", "acm:UpdateCertificateOptions",
          ]
          Resource = "*"
          Condition = {
            StringEquals = { "aws:RequestedRegion" = [var.aws_region, "us-east-1"] }
          }
        },
        {
          # AA-703 (Infra PR #105): the two user pools, clients, groups, domains, identity
          # providers, triggers config, WAF association. Several Cognito actions (CreateUserPool,
          # DescribeUserPoolDomain, ...) have no resource ARN, so the scope is the region. Control
          # plane only: no Admin* (AdminCreateUser / AdminSetUserPassword / AdminInitiateAuth would
          # let a CI apply mint a staff login) and no Start/StopUserImportJob.
          Sid    = "CognitoUserPoolManage"
          Effect = "Allow"
          Action = [
            "cognito-idp:Create*", "cognito-idp:Delete*", "cognito-idp:Update*",
            "cognito-idp:Describe*", "cognito-idp:Get*", "cognito-idp:List*", "cognito-idp:Set*",
            "cognito-idp:AddCustomAttributes", "cognito-idp:TagResource",
            "cognito-idp:UntagResource", "cognito-idp:AssociateWebACL",
            "cognito-idp:DisassociateWebACL",
          ]
          Resource = "*"
          Condition = {
            StringEquals = { "aws:RequestedRegion" = var.aws_region }
          }
        },
        {
          # AA-703: the Cognito web ACL (WAFv2Manage in cicd.tf has update/associate only).
          Sid      = "WAFv2WebACLCreate"
          Effect   = "Allow"
          Action   = ["wafv2:CreateWebACL", "wafv2:DeleteWebACL", "wafv2:CheckCapacity"]
          Resource = "*"
        },
        {
          # AA-703: a pool in DEVELOPER (SES) email mode makes Cognito create its email
          # service-linked role on first use; the caller needs this. Only that one service.
          Sid      = "CognitoEmailServiceLinkedRole"
          Effect   = "Allow"
          Action   = ["iam:CreateServiceLinkedRole"]
          Resource = "arn:aws:iam::${var.account_id}:role/aws-service-role/email.cognito-idp.amazonaws.com/*"
          Condition = {
            StringEquals = { "iam:AWSServiceName" = "email.cognito-idp.amazonaws.com" }
          }
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
