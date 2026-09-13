data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_actions.certificates[0].sha1_fingerprint]
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
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:AdventureAsia365-CIS/*:*"
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
        Sid      = "AutoscalingDescribeList"
        Effect   = "Allow"
        Action   = ["application-autoscaling:Describe*", "application-autoscaling:List*"]
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
