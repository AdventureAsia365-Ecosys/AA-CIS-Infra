# =============================================================================
# AA-730 — narrow IAM role for agent sessions (Kiro / Claude Code on WSL)
#
# Agents used to run AWS commands with the 8h MFA'd `aa365-admin` session in their own shell while
# reading untrusted input (supplier files, Jira, web). This role is what an agent shell assumes
# instead (profile `aa365-agent`, see docs/agent-session-role.md). It covers what agents actually
# do day to day (Step 0, from skills + session logs):
#   - ECS exec into the dev cluster (S3-mediated script runner, skill aa-cis-schema/ecs-exec.md)
#     and SSM port-forward to RDS through a task (DBeaver);
#   - put/get scripts and results under s3://<bronze>/scripts/ (+ presign — same GetObject);
#   - read CloudWatch logs / alarms / metrics, describe ECS / RDS / Scheduler (not Lambda config:
#     Lambda env values can hold secrets — the ops-probe Lambda carries the admin secret);
#   - invoke the CIS / TripPlanner Lambdas (extraction ops, probes);
#   - sts:GetCallerIdentity (no permission needed).
# Everything else is implicitly denied. The explicit Deny below keeps the dangerous classes denied
# even if an Allow is widened later: IAM writes, deletes of RDS data/snapshots, starting/stopping or
# scaling the environment, secret values, Terraform state.
#
# Terraform applies and prod migrations stay in GitHub workflows (terraform-apply.yml,
# db-migrate.yml). The MFA'd admin profile stays with Nghiệp, not in agent shells.
# Known limit: ECS exec runs code inside the api container with the task's own DATABASE_URL, so an
# agent can still run SQL through exec — that is the point of exec; IAM cannot narrow it.
# =============================================================================

locals {
  agent_role_name = "${local.name_prefix}-agent-session"
  agent_cluster   = "${local.name_prefix}-cluster"
}

data "aws_iam_policy_document" "agent_session_assume" {
  statement {
    sid     = "HumanWithMfa"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.account_id}:root"]
    }
    condition {
      test     = "Bool"
      variable = "aws:MultiFactorAuthPresent"
      values   = ["true"]
    }
  }
}

resource "aws_iam_role" "agent_session" {
  name                 = local.agent_role_name
  description          = "AA-730: agent shells (Kiro / Claude Code) - ECS exec, runner S3 prefix, logs, read-only describe"
  assume_role_policy   = data.aws_iam_policy_document.agent_session_assume.json
  max_session_duration = 28800 # 8h, same as the admin session it replaces

  # default_tags make CreateRole call iam:TagRole; the CI role gets that permission for this
  # role name in cicd.tf (AgentSessionRoleTagging). Wait for it to propagate, same as the
  # TripPlanner roles.
  depends_on = [time_sleep.wait_for_iam_propagation]
}

data "aws_iam_policy_document" "agent_session" {
  statement {
    sid       = "EcsRead"
    actions   = ["ecs:Describe*", "ecs:List*"]
    resources = ["*"]
  }

  statement {
    sid     = "EcsExecDevCluster"
    actions = ["ecs:ExecuteCommand"]
    resources = [
      "arn:aws:ecs:${var.aws_region}:${var.account_id}:cluster/${local.agent_cluster}",
      "arn:aws:ecs:${var.aws_region}:${var.account_id}:task/${local.agent_cluster}/*",
    ]
  }

  statement {
    sid     = "SsmPortForwardThroughTask"
    actions = ["ssm:StartSession"]
    resources = [
      "arn:aws:ecs:${var.aws_region}:${var.account_id}:task/${local.agent_cluster}/*",
      "arn:aws:ssm:${var.aws_region}::document/AWS-StartPortForwardingSessionToRemoteHost",
    ]
  }

  statement {
    sid       = "SsmOwnSessions"
    actions   = ["ssm:TerminateSession", "ssm:ResumeSession"]
    resources = ["arn:aws:ssm:${var.aws_region}:${var.account_id}:session/$${aws:userid}-*"]
  }

  statement {
    sid       = "RunnerPrefixObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${module.s3.bronze_bucket_arn}/scripts/*"]
  }

  statement {
    sid       = "RunnerPrefixList"
    actions   = ["s3:ListBucket"]
    resources = [module.s3.bronze_bucket_arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["scripts/*", "scripts"]
    }
  }

  statement {
    sid = "LogsRead"
    actions = [
      "logs:DescribeLogGroups", "logs:DescribeLogStreams", "logs:GetLogEvents",
      "logs:FilterLogEvents", "logs:StartQuery", "logs:GetQueryResults", "logs:StopQuery",
      "logs:StartLiveTail", "logs:StopLiveTail", "logs:GetLogRecord",
    ]
    resources = ["*"]
  }

  statement {
    sid = "ObservabilityRead"
    actions = [
      "cloudwatch:Describe*", "cloudwatch:Get*", "cloudwatch:List*",
      "rds:Describe*", "rds:ListTagsForResource",
      "scheduler:Get*", "scheduler:List*",
      "events:Describe*", "events:List*",
      "apigateway:GET",
      "sns:ListSubscriptionsByTopic", "sns:GetTopicAttributes",
    ]
    resources = ["*"]
  }

  statement {
    sid     = "InvokeAppLambdas"
    actions = ["lambda:InvokeFunction"]
    resources = [
      "arn:aws:lambda:${var.aws_region}:${var.account_id}:function:${local.name_prefix}-*",
      "arn:aws:lambda:${var.aws_region}:${var.account_id}:function:aa-tripplanner-${var.environment}-*",
    ]
  }

  statement {
    sid    = "DenyDangerous"
    effect = "Deny"
    actions = [
      # identity
      "iam:Create*", "iam:Delete*", "iam:Put*", "iam:Attach*", "iam:Detach*", "iam:Update*",
      "iam:Add*", "iam:Remove*", "iam:PassRole", "iam:Tag*", "iam:Untag*", "iam:Set*",
      "iam:ChangePassword", "iam:ResetServiceSpecificCredential", "iam:UploadSSHPublicKey",
      "sts:AssumeRole",
      # Lambda config carries env values (the ops-probe Lambda holds the admin secret in its env)
      "lambda:GetFunction", "lambda:GetFunctionConfiguration", "lambda:ListFunctions",
      "lambda:ListVersionsByFunction", "lambda:Update*", "lambda:Delete*", "lambda:Create*",
      # data loss
      "rds:Delete*", "rds:RestoreDBInstance*", "rds:ModifyDBInstance", "rds:ModifyDBCluster",
      "s3:DeleteBucket*", "s3:PutBucketPolicy", "s3:PutLifecycleConfiguration",
      # start / stop / scale the environment (Nghiệp's call only)
      "rds:StopDBInstance", "rds:StartDBInstance", "rds:RebootDBInstance",
      "ec2:StopInstances", "ec2:StartInstances", "ec2:TerminateInstances",
      "ecs:UpdateService", "ecs:DeleteService", "ecs:DeleteCluster", "ecs:StopTask", "ecs:RunTask",
      "application-autoscaling:*",
      # secrets and Terraform state
      "secretsmanager:GetSecretValue", "secretsmanager:PutSecretValue", "secretsmanager:DeleteSecret",
      "kms:Decrypt",
    ]
    resources = ["*"]
  }

  statement {
    sid     = "DenyTerraformState"
    effect  = "Deny"
    actions = ["s3:*", "dynamodb:*"]
    resources = [
      "arn:aws:s3:::aa-cis-tfstate-*",
      "arn:aws:s3:::aa-cis-tfstate-*/*",
      "arn:aws:dynamodb:${var.aws_region}:${var.account_id}:table/aa-cis-tfstate-lock-*",
    ]
  }
}

resource "aws_iam_role_policy" "agent_session" {
  name   = "${local.agent_role_name}-policy"
  role   = aws_iam_role.agent_session.id
  policy = data.aws_iam_policy_document.agent_session.json
}

output "agent_session_role_arn" {
  description = "AA-730 — role_arn for the `aa365-agent` profile (docs/agent-session-role.md)"
  value       = aws_iam_role.agent_session.arn
}
