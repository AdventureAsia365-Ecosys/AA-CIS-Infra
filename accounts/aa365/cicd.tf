data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_actions.certificates[0].sha1_fingerprint]
}

# AA-806 step 3 (S239): the legacy shared CI role aa-cis-dev-role (aws_iam_role.cicd, its 10
# managed attachments, the CISDevInlinePolicy inline policy, local.cicd_oidc_subjects and output
# cicd_role_arn) is retired. Its last AssumeRoleWithWebIdentity was 14/10/2026 (CloudTrail); every
# CI job now uses a per-job role from cicd_split.tf, tripplanner.tf or booking.tf.
#
# The two lists below are no longer attached to any role in this file: they are the grant set of
# the Terraform apply role aa-cis-infra-tf-apply (cicd_split.tf), which takes
# local.cicd_managed_policies as-is and local.cicd_inline_statements minus
# local.tf_apply_superseded_sids. Editing either list changes a bootstrap object (the apply role
# cannot rewrite its own policy), so such a change is applied locally with the MFA admin profile.
locals {
  cicd_managed_policies = [
    "arn:aws:iam::aws:policy/AmazonRDSFullAccess",
    "arn:aws:iam::aws:policy/SecretsManagerReadWrite",
    "arn:aws:iam::aws:policy/AmazonECS_FullAccess",
    "arn:aws:iam::aws:policy/CloudWatchFullAccess",
    "arn:aws:iam::aws:policy/AmazonSQSFullAccess",
    "arn:aws:iam::aws:policy/AmazonVPCFullAccess",
    "arn:aws:iam::aws:policy/AmazonElastiCacheFullAccess",
    # AA-931: AWSStepFunctionsFullAccess removed. No Step Functions resource exists since AA-750 (the
    # pipeline state machine was retired) and its only other useful action, iam:ListRoles, is also in
    # AWSLambda_FullAccess. The freed slot (default quota: 10 managed policies per role) holds the
    # customer managed aa-cis-infra-tf-apply-crm (cicd_crm.tf).
    "arn:aws:iam::aws:policy/AmazonS3FullAccess",
    "arn:aws:iam::aws:policy/AWSLambda_FullAccess",
  ]
}

# AA-806: statement list of the apply role (see above). Sids that the apply role replaces with
# name-scoped versions are listed in local.tf_apply_superseded_sids and dropped there.
#
# AA-846 (S245) narrowing, to give the apply role's single inline policy headroom under the
# 10,240-character limit and drop grants nothing uses:
#   - ECRPushPull -> read verbs only, inside RefreshRead. No workflow on the apply role pushes or
#     pulls an image (the app repos push with their own deploy roles); Terraform refresh of the ECR
#     repositories needs only the Describe/List/Get* reads.
#   - DynamoDBStateLock removed: the backend locks with the S3 lockfile only (use_lockfile), and S3
#     access comes from AmazonS3FullAccess.
#   - The read-only Resource "*" statements (ELBDescribe, EFSDescribeList, IAMPolicyRead and the ECR
#     reads) are one statement, RefreshRead: same actions (ECR reads as Describe*/List*/Get*Policy*),
#     less per-statement overhead. WAFv2WebACLCreate (cicd_split.tf) is folded into WAFv2Manage.
locals {
  cicd_inline_statements = [
    {
      # Plan/refresh reads with no resource-level scoping. No write verb belongs here.
      Sid    = "RefreshRead"
      Effect = "Allow"
      Action = [
        "ecr:Describe*", "ecr:List*", "ecr:GetLifecyclePolicy*", "ecr:GetRepositoryPolicy",
        "elasticloadbalancing:Describe*", "elasticloadbalancing:Get*",
        "elasticfilesystem:Describe*", "elasticfilesystem:List*",
        # AA-806: the permissions-boundary policies in cicd_split.tf are customer managed policies;
        # refreshing them needs these.
        "iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListPolicyVersions", "iam:ListPolicyTags",
        "iam:ListRoleTags",
      ]
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
        # AA-703: the Cognito web ACL (was Sid WAFv2WebACLCreate in cicd_split.tf, merged AA-846).
        "wafv2:CreateWebACL",
        "wafv2:DeleteWebACL",
        "wafv2:CheckCapacity",
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
      # AA-678 — booking.tf creates its own ECR repo (aa-booking-dev-api). RefreshRead above only
      # has the ECR read verbs (the CIS repo in modules/ecs was created before this role
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
      # AA-869 (S241) — the CIS repo (modules/ecs, aa-cis-<env>-api) became IaC-managed for its
      # settings: tag mutability, lifecycle policy (a policy change is a delete + create) and scan
      # config. Configuration verbs only: no CreateRepository, DeleteRepository or BatchDeleteImage,
      # so CI can neither recreate nor empty the repo that every CIS task definition pulls from.
      Sid    = "CisEcrRepoConfigure"
      Effect = "Allow"
      Action = [
        "ecr:PutLifecyclePolicy",
        "ecr:DeleteLifecyclePolicy",
        "ecr:PutImageScanningConfiguration",
        "ecr:PutImageTagMutability",
        "ecr:TagResource",
        "ecr:UntagResource",
      ]
      Resource = "arn:aws:ecr:${var.aws_region}:${var.account_id}:repository/${local.name_prefix}-api"
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
      # AA-402 — schedules in the aa-cis-dev-acp schedule group above (the
      # module.eventbridge ACP schedules were removed in AA-989; the group now
      # holds the accounts/aa365 schedules: dfs_balance, retention, photo_sync,
      # booking_uptime, rds_snapshot_expiry). Scheduler schedule ARNs are
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
}
