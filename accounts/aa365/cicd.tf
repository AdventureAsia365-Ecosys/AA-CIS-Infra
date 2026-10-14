data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_actions.certificates[0].sha1_fingerprint]
}

locals {
  # GitHub OIDC subjects allowed to assume aa-cis-dev-role (AA-678, S235).
  #
  # Both repos have GitHub's immutable subject claim ON ("use_immutable_subject": true, read
  # 14/10/2026 via GET /repos/{owner}/{repo}/actions/oidc/customization/sub), so the sub is
  #   repo:<org>@<org_id>/<repo>@<repo_id>:<context>
  # e.g. repo:AdventureAsia365-Ecosys@276539096/AA-CIS-Infra@1212290412:pull_request (also seen in
  # CloudTrail, AA-588). A plain "repo:<org>/<repo>:*" pattern does NOT match that form (the
  # AA-588 AccessDenied). Pinning the numeric org + repo ids means no org/repo-name wildcard is
  # needed and a renamed or re-created repo cannot inherit this role. The trailing "*" is the
  # context, which must stay open because the callers use three forms:
  #   AA-CIS-App   deploy-dev.yml (build-and-push, deploy) + eval-regression.yml -> environment:dev
  #   AA-CIS-Infra terraform-plan.yml                                            -> pull_request
  #   AA-CIS-Infra terraform-apply.yml + db-migrate.yml                          -> environment:prod
  # AA-TripPlanner-Web uses its own aa-tripplanner-dev-app-deploy role (tripplanner.tf), and
  # AA-Booking will get its own aa-booking-dev-app-deploy role (booking.tf). Do NOT add them here.
  # If a repo turns the immutable subject off, or is renamed or re-created, this role stops
  # trusting it (fail closed): re-read the sub prefix with the API call above and update the list.
  cicd_oidc_subjects = [
    "repo:AdventureAsia365-Ecosys@276539096/AA-CIS-App@1212291079:*",
    "repo:AdventureAsia365-Ecosys@276539096/AA-CIS-Infra@1212290412:*",
  ]
}

resource "aws_iam_role" "cicd" {
  name = "aa-cis-dev-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github_actions.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        # AA-678 (S235, 14/10/2026): trust ONLY the two repos that assume this role. It used to
        # trust "repo:AdventureAsia365-Ecosys*/*:*" (every repo in the org), so any new org repo
        # (AA-Booking next) would have inherited RDS/Secrets/ECS full access and iam:CreateRole/
        # PassRole on "*". Each repo now gets its exact immutable subject prefix, see
        # local.cicd_oidc_subjects above.
        StringLike = {
          "token.actions.githubusercontent.com:sub" = local.cicd_oidc_subjects
        }
      }
    }]
  })
}

locals {
  cicd_managed_policies = [
    "arn:aws:iam::aws:policy/AmazonRDSFullAccess",
    "arn:aws:iam::aws:policy/SecretsManagerReadWrite",
    "arn:aws:iam::aws:policy/AmazonECS_FullAccess",
    "arn:aws:iam::aws:policy/CloudWatchFullAccess",
    "arn:aws:iam::aws:policy/AmazonSQSFullAccess",
    "arn:aws:iam::aws:policy/AmazonVPCFullAccess",
    "arn:aws:iam::aws:policy/AmazonElastiCacheFullAccess",
    "arn:aws:iam::aws:policy/AWSStepFunctionsFullAccess",
    "arn:aws:iam::aws:policy/AmazonS3FullAccess",
    "arn:aws:iam::aws:policy/AWSLambda_FullAccess",
  ]
}

resource "aws_iam_role_policy_attachment" "cicd_managed" {
  for_each   = toset(local.cicd_managed_policies)
  role       = aws_iam_role.cicd.name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "cicd_inline" {
  name = "CISDevInlinePolicy"
  role = aws_iam_role.cicd.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRPushPull"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:DescribeRepositories",
          "ecr:ListImages",
          "ecr:ListTagsForResource",
          "ecr:DescribeImages",
          "ecr:GetLifecyclePolicy",
          "ecr:GetLifecyclePolicyPreview",
          "ecr:GetRepositoryPolicy",
        ]
        Resource = "*"
      },
      {
        Sid      = "ELBDescribe"
        Effect   = "Allow"
        Action   = ["elasticloadbalancing:Describe*", "elasticloadbalancing:Get*"]
        Resource = "*"
      },
      {
        Sid    = "ELBManageVpcLinkNLB"
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:CreateLoadBalancer",
          "elasticloadbalancing:DeleteLoadBalancer",
          "elasticloadbalancing:ModifyLoadBalancerAttributes",
          "elasticloadbalancing:CreateTargetGroup",
          "elasticloadbalancing:DeleteTargetGroup",
          "elasticloadbalancing:ModifyTargetGroup",
          "elasticloadbalancing:ModifyTargetGroupAttributes",
          "elasticloadbalancing:RegisterTargets",
          "elasticloadbalancing:DeregisterTargets",
          "elasticloadbalancing:CreateListener",
          "elasticloadbalancing:DeleteListener",
          "elasticloadbalancing:ModifyListener",
          "elasticloadbalancing:AddTags",
          "elasticloadbalancing:RemoveTags",
        ]
        Resource = "*"
      },
      {
        Sid      = "EFSDescribeList"
        Effect   = "Allow"
        Action   = ["elasticfilesystem:Describe*", "elasticfilesystem:List*"]
        Resource = "*"
      },
      {
        # AA-651 — the worker ECS service's autoscaling target+policies (modules/ecs) are now
        # Terraform-managed, so CI needs the write verbs too, not just Describe/List. The api's
        # scalable target predates this and was registered out-of-band (admin), which is why CI
        # never needed these before. RegisterScalableTarget tags the target, so TagResource is
        # required (that exact action is what the first apply hit: AccessDeniedException on
        # application-autoscaling:TagResource). All application-autoscaling actions are IAM-global
        # (no resource-level ARN scoping), so Resource must be "*".
        Sid    = "AutoscalingManage"
        Effect = "Allow"
        Action = [
          "application-autoscaling:Describe*",
          "application-autoscaling:List*",
          "application-autoscaling:RegisterScalableTarget",
          "application-autoscaling:DeregisterScalableTarget",
          "application-autoscaling:PutScalingPolicy",
          "application-autoscaling:DeleteScalingPolicy",
          "application-autoscaling:TagResource",
          "application-autoscaling:UntagResource",
        ]
        Resource = "*"
      },
      {
        Sid    = "IAMRoleManage"
        Effect = "Allow"
        Action = [
          "iam:CreateRole", "iam:DeleteRole", "iam:AttachRolePolicy",
          "iam:DetachRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy",
          "iam:PassRole", "iam:GetRole", "iam:GetRolePolicy",
          "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
          # UpdateAssumeRolePolicy needed to change a role's trust policy in
          # place (e.g. the TripPlanner app-deploy OIDC sub fix) — CreateRole
          # only covers the initial trust, not later edits.
          "iam:UpdateAssumeRolePolicy",
          # AA-750: DeleteRole first lists the role's instance profiles; without this the
          # provider fails to delete any role (live AccessDenied on aa-cis-dev-sfn-exec /
          # aa-cis-dev-lambda-exec during the Lambda retirement apply).
          "iam:ListInstanceProfilesForRole",
        ]
        Resource = "*"
      },
      {
        Sid    = "OIDCProviderManage"
        Effect = "Allow"
        Action = [
          "iam:GetOpenIDConnectProvider",
          "iam:CreateOpenIDConnectProvider",
          "iam:DeleteOpenIDConnectProvider",
          "iam:UpdateOpenIDConnectProviderThumbprint",
          "iam:TagOpenIDConnectProvider",
          "iam:UntagOpenIDConnectProvider",
          "iam:ListOpenIDConnectProviderTags",
          "iam:ListOpenIDConnectProviders",
        ]
        Resource = "*"
      },
      {
        Sid    = "APIGatewayManage"
        Effect = "Allow"
        Action = [
          "apigateway:GET",
          "apigateway:POST",
          "apigateway:PUT",
          "apigateway:PATCH",
          "apigateway:DELETE",
          # TagResource/UntagResource are separate actions for API Gateway v2
          # (HTTP API) tagging and are NOT covered by the HTTP verbs above. The
          # provider's default_tags (versions.tf) tags every taggable resource,
          # so creating the TripPlanner HTTP API stage calls TagResource.
          "apigateway:TagResource",
          "apigateway:UntagResource",
        ]
        Resource = "*"
      },
      {
        Sid    = "WAFv2Manage"
        Effect = "Allow"
        Action = [
          "wafv2:GetWebACL",
          "wafv2:ListWebACLs",
          "wafv2:GetWebACLForResource",
          "wafv2:UpdateWebACL",
          "wafv2:AssociateWebACL",
          "wafv2:DisassociateWebACL",
          "wafv2:GetLoggingConfiguration",
          "wafv2:PutLoggingConfiguration",
          "wafv2:DeleteLoggingConfiguration",
          "wafv2:ListTagsForResource",
          "wafv2:TagResource",
          "wafv2:GetIPSet",
          "wafv2:ListIPSets",
        ]
        Resource = "*"
      },
      {
        Sid    = "IAMInstanceProfileManage"
        Effect = "Allow"
        Action = [
          "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile", "iam:GetInstanceProfile",
          "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile", "iam:TagInstanceProfile",
        ]
        Resource = "*"
      },
      {
        Sid    = "DynamoDBStateLock"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:DeleteItem",
          "dynamodb:DescribeTable",
        ]
        Resource = "arn:aws:dynamodb:us-west-1:005097885195:table/aa-cis-tfstate-lock-005097885195"
      },
      {
        # AA-287 — aws_budgets_budget. ViewBudget/ModifyBudget are AWS's
        # consolidated fine-grained actions (in effect for any account/org
        # created on or after 2023-03-06) that gate all Budgets read and
        # write API calls respectively — the old granular Create/Describe/
        # Update/DeleteBudget actions are superseded by these two, not used
        # alongside them. Resource is "*" because Budgets' console-level
        # actions don't support resource-level ARN scoping (confirmed via
        # AWS Cost Management's own IAM policy examples, which use
        # Resource: "*" throughout).
        # Tagging is a SEPARATE API surface, not covered by ViewBudget/
        # ModifyBudget — missed on the first pass (AA-286/287 IAM PR),
        # which caused an AccessDeniedException on budgets:TagResource at
        # apply time (default_tags applies to every taggable resource,
        # including this one, even with no explicit `tags` block on the
        # resource itself). TagResource/UntagResource/ListTagsForResource
        # confirmed via the official Budgets API reference
        # (docs.aws.amazon.com/aws-cost-management/latest/APIReference/
        # API_budgets_{Tag,Untag,ListTagsFor}Resource.html), not assumed
        # from the CloudTrail Sid's AddTags/RemoveTags/ListTags pattern —
        # Budgets uses the generic resource-tagging API shape, CloudTrail
        # uses its own older service-specific one.
        Sid    = "BudgetsManage"
        Effect = "Allow"
        Action = [
          "budgets:ViewBudget",
          "budgets:ModifyBudget",
          "budgets:TagResource",
          "budgets:UntagResource",
          "budgets:ListTagsForResource",
        ]
        Resource = "*"
      },
      {
        # AA-286 — aws_cloudtrail.main. Exact action list confirmed against
        # the terraform-provider-aws source (internal/service/cloudtrail/
        # trail.go) so plan/refresh (Describe/Get*) and full apply lifecycle
        # (Create/Update/Delete/StartLogging/StopLogging/PutEventSelectors/
        # PutInsightSelectors) all work — not just the create path. Tagging
        # uses CloudTrail's own AddTags/RemoveTags/ListTags API (not the
        # generic TagResource/UntagResource some newer services use).
        # Resource "*" matches AWS's own CloudTrail IAM policy examples,
        # which state the Resource element is always "*" for these actions.
        Sid    = "CloudTrailManage"
        Effect = "Allow"
        Action = [
          "cloudtrail:CreateTrail",
          "cloudtrail:UpdateTrail",
          "cloudtrail:DeleteTrail",
          "cloudtrail:DescribeTrails",
          "cloudtrail:ListTrails",
          "cloudtrail:GetTrailStatus",
          "cloudtrail:StartLogging",
          "cloudtrail:StopLogging",
          "cloudtrail:GetEventSelectors",
          "cloudtrail:PutEventSelectors",
          "cloudtrail:GetInsightSelectors",
          "cloudtrail:PutInsightSelectors",
          "cloudtrail:AddTags",
          "cloudtrail:RemoveTags",
          "cloudtrail:ListTags",
        ]
        Resource = "*"
      },
      {
        # AA-402 — module.eventbridge's scheduler IAM role
        # (aa-cis-dev-acp-scheduler-role). TagRole/UntagRole were missing
        # from IAMRoleManage above (which otherwise already grants Create/
        # Get/PutRolePolicy/PassRole etc with Resource "*") — confirmed via
        # a live partial-apply AccessDenied on iam:TagRole. Scoped to this
        # one role ARN rather than folded into IAMRoleManage's wildcard,
        # since this is prod and the module only ever creates this one role.
        Sid      = "EventBridgeSchedulerRoleTagging"
        Effect   = "Allow"
        Action   = ["iam:TagRole", "iam:UntagRole"]
        Resource = "arn:aws:iam::${var.account_id}:role/${local.name_prefix}-acp-scheduler-role"
      },
      {
        # AA-TripPlanner — the TripPlanner roles (lambda-exec + app-deploy,
        # accounts/aa365/tripplanner.tf) are tagged, so CreateRole calls
        # iam:TagRole. Same gap/precedent as the EventBridgeSchedulerRoleTagging
        # statement above (IAMRoleManage grants Create/Put/PassRole with
        # Resource "*" but not TagRole). Scoped to the aa-tripplanner-* name
        # prefix so it covers both roles without a bare "*" wildcard.
        Sid      = "TripPlannerRoleTagging"
        Effect   = "Allow"
        Action   = ["iam:TagRole", "iam:UntagRole"]
        Resource = "arn:aws:iam::${var.account_id}:role/aa-tripplanner-${var.environment}-*"
      },
      {
        # AA-730 — the agent-session role (agent_session.tf) is tagged by default_tags, so its
        # CreateRole calls iam:TagRole. Same gap/precedent as the two statements above; scoped to
        # that one role name.
        Sid      = "AgentSessionRoleTagging"
        Effect   = "Allow"
        Action   = ["iam:TagRole", "iam:UntagRole"]
        Resource = "arn:aws:iam::${var.account_id}:role/${local.name_prefix}-agent-session"
      },
      {
        # AA-678 (Booking bootstrap) — booking.tf creates tagged roles (e.g. aa-booking-dev-ecs-exec,
        # -ecs-task, -app-deploy), so CreateRole calls iam:TagRole. Same gap/precedent as
        # TripPlannerRoleTagging. This statement must be APPLIED BEFORE booking.tf is planned/applied
        # (two-phase Infra apply): IAM is eventually consistent, and a grant created in the same run
        # as the role can still be AccessDenied (time_sleep.wait_for_iam_propagation only covers
        # resources that depend_on it). Scoped to the aa-booking-<env>-* name prefix.
        Sid      = "BookingRoleTagging"
        Effect   = "Allow"
        Action   = ["iam:TagRole", "iam:UntagRole"]
        Resource = "arn:aws:iam::${var.account_id}:role/aa-booking-${var.environment}-*"
      },
      {
        # AA-678 — booking.tf creates its own ECR repo (aa-booking-dev-api). ECRPushPull above only
        # has push/pull + read verbs (the CIS repo in modules/ecs was created before this role
        # managed it), so CreateRepository, the lifecycle policy and tag-on-create would be
        # AccessDenied. Scoped to aa-booking-<env>-* repositories; CIS repos are untouched.
        Sid    = "BookingEcrRepoManage"
        Effect = "Allow"
        Action = [
          "ecr:CreateRepository",
          "ecr:DeleteRepository",
          "ecr:BatchDeleteImage",
          "ecr:PutLifecyclePolicy",
          "ecr:DeleteLifecyclePolicy",
          "ecr:PutImageScanningConfiguration",
          "ecr:PutImageTagMutability",
          "ecr:TagResource",
          "ecr:UntagResource",
        ]
        Resource = "arn:aws:ecr:${var.aws_region}:${var.account_id}:repository/aa-booking-${var.environment}-*"
      },
      {
        # AA-678 — booking.tf adds an aws_lb_listener_rule (/booking/*) on the CIS ALB's HTTP
        # listener (module.alb http_listener_arn output). No statement on this role grants the
        # listener-rule verbs explicitly (ELBManageVpcLinkNLB covers listeners/target groups only),
        # so grant them here instead of relying on a managed policy's contents. Scoped to
        # listeners and rules of the aa-cis-<env>-alb load balancer only.
        Sid    = "BookingAlbListenerRuleManage"
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:CreateRule",
          "elasticloadbalancing:DeleteRule",
          "elasticloadbalancing:ModifyRule",
          "elasticloadbalancing:SetRulePriorities",
        ]
        Resource = [
          "arn:aws:elasticloadbalancing:${var.aws_region}:${var.account_id}:listener/app/${local.name_prefix}-alb/*",
          "arn:aws:elasticloadbalancing:${var.aws_region}:${var.account_id}:listener-rule/app/${local.name_prefix}-alb/*",
        ]
      },
      {
        # AA-402 — module.eventbridge's custom EventBridge bus
        # (aa-cis-dev-acp-events). No events:* action existed anywhere on
        # this role before (confirmed via live AccessDenied on
        # events:CreateEventBus/events:TagResource) — CloudWatchFullAccess
        # does not cover the "events" namespace, only cloudwatch/logs/sns.
        Sid    = "EventBridgeAcpBusManage"
        Effect = "Allow"
        Action = [
          "events:CreateEventBus",
          "events:DeleteEventBus",
          "events:DescribeEventBus",
          "events:TagResource",
          "events:UntagResource",
          "events:ListTagsForResource",
        ]
        Resource = "arn:aws:events:${var.aws_region}:${var.account_id}:event-bus/${local.name_prefix}-acp-events"
      },
      {
        # AA-402 — module.eventbridge's schedule group (aa-cis-dev-acp).
        # No scheduler:* action existed anywhere on this role before
        # (confirmed via live AccessDenied on scheduler:CreateScheduleGroup).
        Sid    = "EventBridgeSchedulerGroupManage"
        Effect = "Allow"
        Action = [
          "scheduler:CreateScheduleGroup",
          "scheduler:GetScheduleGroup",
          "scheduler:DeleteScheduleGroup",
          "scheduler:TagResource",
          "scheduler:UntagResource",
          "scheduler:ListTagsForResource",
        ]
        Resource = "arn:aws:scheduler:${var.aws_region}:${var.account_id}:schedule-group/${local.name_prefix}-acp"
      },
      {
        # AA-402 — module.eventbridge's 3 named schedules (acp_daily_ingest,
        # acp_weekly_export, acp_veto_window_close), all created under the
        # aa-cis-dev-acp schedule group above. Scheduler schedule ARNs are
        # always schedule/{group-name}/{schedule-name} (confirmed against
        # AWS's own botocore service model regex for the scheduler service,
        # not assumed) — the /* here covers only schedule names under this
        # one group, not schedules in any other group.
        Sid    = "EventBridgeSchedulerScheduleManage"
        Effect = "Allow"
        Action = [
          "scheduler:CreateSchedule",
          "scheduler:GetSchedule",
          "scheduler:UpdateSchedule",
          "scheduler:DeleteSchedule",
        ]
        Resource = "arn:aws:scheduler:${var.aws_region}:${var.account_id}:schedule/${local.name_prefix}-acp/*"
      },
    ]
  })
}

output "cicd_role_arn" {
  value = aws_iam_role.cicd.arn
}
