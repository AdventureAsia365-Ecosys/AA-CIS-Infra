# =============================================================================
# AA-1004 — GitHub Actions OIDC for this root (README §11): CI plans and applies the management account without a
# human MFA session. Same shape as accounts/aa365/cicd_split.tf (AA-806), one role per job:
#
#   aa-terraform-plan    terraform-plan.yml (pull_request) and terraform-drift.yml (ref main, no environment).
#                        ReadOnlyAccess + the state lockfile + the Identity Center / budget reads ReadOnlyAccess may
#                        lack. No permissions boundary, like aa-cis-infra-tf-plan: it holds no write that could
#                        escalate (its only write is one lockfile object).
#   aa-terraform-apply   terraform-apply.yml, input root = management, GitHub environment `org` (required reviewer)
#                        on main. Service grants for exactly what this root manages (not AdministratorAccess), capped
#                        by the permissions boundary aa-terraform-apply-boundary, like aa-cis-infra-tf-apply.
#
# Bootstrap objects (this file): the OIDC provider, both roles, their policies and the boundary. The apply role cannot
# change any of them (the boundary denies every role write outside the Identity Center reserved path, every customer
# managed policy write and every identity-provider write), so a change here is a local apply in the tech lead's
# session (README §4 wrapper), as for the aa365 CI roles. A CI apply of such a change fails with AccessDenied by design.
#
# No account ID is written here (public repo): every ARN is built from var.management_account_id. The GitHub org and
# repo IDs in var.github_oidc_subject_prefix are not secrets (the same prefix is in accounts/aa365/cicd_split.tf).
# Cost: 0 USD (IAM and OIDC are free).
# =============================================================================

variable "github_oidc_subject_prefix" {
  description = <<-EOT
    Immutable OIDC subject prefix of AdventureAsia365-Ecosys/AA-CIS-Infra (CONTEXT.md "CI/CD and OIDC": the repo has
    use_immutable_subject on, so the sub is repo:<org>@<org id>/<repo>@<repo id>:<context>; a plain
    repo:<org>/<repo>:* subject never matches). Same value as local.oidc_sub_cis_infra in accounts/aa365. If the repo
    is renamed, re-created or turns the immutable subject off, both roles stop trusting it (fail closed).
  EOT
  type        = string
  default     = "repo:AdventureAsia365-Ecosys@276539096/AA-CIS-Infra@1212290412"

  validation {
    condition     = can(regex("^repo:[A-Za-z0-9-]+@[0-9]+/[A-Za-z0-9._-]+@[0-9]+$", var.github_oidc_subject_prefix))
    error_message = "github_oidc_subject_prefix must be the immutable form repo:<org>@<org id>/<repo>@<repo id>, without a context."
  }
}

locals {
  ci_plan_role_name  = "aa-terraform-plan"
  ci_apply_role_name = "aa-terraform-apply"
  ci_boundary_name   = "aa-terraform-apply-boundary"

  # State backend of this root (README §3 bucket name, versions.tf key). The CI workflows build the same bucket name
  # from the MGMT_ACCOUNT_ID secret, so no separate bucket setting exists.
  state_bucket_arn   = "arn:aws:s3:::aa-tfstate-${var.management_account_id}-usw1"
  state_object_arn   = "${local.state_bucket_arn}/management/terraform.tfstate"
  state_lockfile_arn = "${local.state_object_arn}.tflock"

  # Roles and SAML providers Identity Center itself provisions in this account when a permission set is assigned to
  # it (AA-Admin, AA-Billing). The only IAM principals the apply role may write.
  sso_reserved_role_arn = "arn:aws:iam::${var.management_account_id}:role/aws-reserved/sso.amazonaws.com/*"
  sso_saml_provider_arn = "arn:aws:iam::${var.management_account_id}:saml-provider/AWSSSO_*"

  # Every IAM role write plus PassRole (same list as accounts/aa365, plus boundary removal).
  ci_role_write_actions = [
    "iam:CreateRole", "iam:DeleteRole", "iam:UpdateRole", "iam:UpdateRoleDescription",
    "iam:UpdateAssumeRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy",
    "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:PutRolePermissionsBoundary",
    "iam:DeleteRolePermissionsBoundary", "iam:TagRole", "iam:UntagRole", "iam:PassRole",
  ]
}

# GitHub's OIDC issuer. No thumbprint: AWS validates token.actions.githubusercontent.com against its own trusted CAs,
# and the provider no longer requires the argument (also saves the hashicorp/tls provider in this root).
resource "aws_iam_openid_connect_provider" "github_actions" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

# -----------------------------------------------------------------------------
# aa-terraform-plan — PR plan and nightly drift (read only)
# -----------------------------------------------------------------------------
resource "aws_iam_role" "ci_plan" {
  name                 = local.ci_plan_role_name
  description          = "AA-1004: AA-CIS-Infra terraform plan (pull_request) and drift (main) of accounts/management; read only"
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github_actions.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        # Same two contexts as aa-cis-infra-tf-plan: terraform-plan.yml on pull_request (no environment; fork PRs get
        # no token) and terraform-drift.yml on main (no environment -> ref:refs/heads/main).
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = [
            "${var.github_oidc_subject_prefix}:pull_request",
            "${var.github_oidc_subject_prefix}:ref:refs/heads/main",
          ]
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ci_plan_readonly" {
  role       = aws_iam_role.ci_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "ci_plan" {
  name = "${local.ci_plan_role_name}-policy"
  role = aws_iam_role.ci_plan.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # use_lockfile: a PR plan writes and deletes <key>.tflock (the drift run uses -lock=false). ReadOnlyAccess
        # already reads the state object. Nothing else in the account is writable by this role.
        Sid      = "StateLockfile"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:DeleteObject"]
        Resource = local.state_lockfile_arn
      },
      {
        # Refresh reads of this root that ReadOnlyAccess may not carry (Identity Center, identity store, budget and
        # anomaly tags, centralized root access). Read verbs only. A refresh that still fails with AccessDenied adds
        # its action here (bootstrap: local apply).
        Sid    = "PlanRefreshReads"
        Effect = "Allow"
        Action = [
          "sso:Describe*", "sso:List*", "sso:GetInlinePolicyForPermissionSet",
          "sso:GetPermissionsBoundaryForPermissionSet",
          "identitystore:Describe*", "identitystore:List*", "identitystore:GetGroupId", "identitystore:GetUserId",
          "identitystore:GetGroupMembershipId",
          "budgets:ViewBudget", "budgets:ListTagsForResource",
          "ce:GetAnomalyMonitors", "ce:GetAnomalySubscriptions", "ce:ListTagsForResource",
          "iam:ListOrganizationsFeatures",
        ]
        Resource = "*"
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# Permissions boundary of aa-terraform-apply
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "ci_apply_boundary" {
  statement {
    sid       = "AllowWithinIdentityPolicy"
    actions   = ["*"]
    resources = ["*"]
  }

  # The only roles this root writes are the ones Identity Center provisions here. The CI roles, any future role and
  # the temporary AA-Bootstrap role are out of reach (bootstrap objects, local apply).
  statement {
    sid           = "DenyRoleWritesOutsideIdentityCenter"
    effect        = "Deny"
    actions       = local.ci_role_write_actions
    not_resources = [local.sso_reserved_role_arn]
  }

  # A new identity provider (or a new client id on the GitHub one) would let a trust policy accept tokens from
  # someone else. Identity Center's own AWSSSO_* SAML providers stay writable.
  statement {
    sid    = "DenyOidcProviderWrites"
    effect = "Deny"
    actions = [
      "iam:CreateOpenIDConnectProvider", "iam:DeleteOpenIDConnectProvider",
      "iam:UpdateOpenIDConnectProviderThumbprint", "iam:AddClientIDToOpenIDConnectProvider",
      "iam:RemoveClientIDFromOpenIDConnectProvider", "iam:TagOpenIDConnectProvider",
      "iam:UntagOpenIDConnectProvider",
    ]
    resources = ["*"]
  }

  statement {
    sid           = "DenySamlProviderWritesOutsideIdentityCenter"
    effect        = "Deny"
    actions       = ["iam:CreateSAMLProvider", "iam:UpdateSAMLProvider", "iam:DeleteSAMLProvider"]
    not_resources = [local.sso_saml_provider_arn]
  }

  # No IAM users, keys, groups or customer managed policies (this boundary included): this root creates none through
  # CI, and each would be a way around the boundary.
  statement {
    sid    = "DenyIdentityAndPolicyAdmin"
    effect = "Deny"
    actions = [
      "iam:CreateUser", "iam:CreateAccessKey", "iam:CreateLoginProfile", "iam:UpdateLoginProfile",
      "iam:AttachUserPolicy", "iam:PutUserPolicy", "iam:AddUserToGroup", "iam:CreateGroup",
      "iam:AttachGroupPolicy", "iam:PutGroupPolicy", "iam:CreatePolicy", "iam:CreatePolicyVersion",
      "iam:DeletePolicy", "iam:DeletePolicyVersion", "iam:SetDefaultPolicyVersion", "iam:TagPolicy",
      "iam:UntagPolicy",
    ]
    resources = ["*"]
  }

  # Organization actions no plan of this root needs and whose misuse is hard to undo: members leaving or being
  # removed, closing accounts, deleting the organization, invitations and handshakes (human steps, README §6), and
  # delegating administration or opening the organization's resource policy to a member account. Switching off
  # centralized root access is also a local decision.
  statement {
    sid    = "DenyOrganizationExitAndDelegation"
    effect = "Deny"
    actions = [
      "organizations:LeaveOrganization", "organizations:DeleteOrganization", "organizations:CloseAccount",
      "organizations:RemoveAccountFromOrganization", "organizations:InviteAccountToOrganization",
      "organizations:AcceptHandshake", "organizations:DeclineHandshake", "organizations:CancelHandshake",
      "organizations:RegisterDelegatedAdministrator", "organizations:DeregisterDelegatedAdministrator",
      "organizations:PutResourcePolicy", "organizations:DeleteResourcePolicy",
      "iam:DisableOrganizationsRootCredentialsManagement", "iam:DisableOrganizationsRootSessions",
      "account:*",
    ]
    resources = ["*"]
  }

  # The audit trail: CI never stops it, never deletes its bucket, never touches a locked log file, never disables
  # or deletes its key. (A trail delete is still possible, behind the plan guard, for README §9 rollback.)
  statement {
    sid       = "DenyTrailStop"
    effect    = "Deny"
    actions   = ["cloudtrail:StopLogging"]
    resources = ["*"]
  }

  statement {
    sid    = "DenyTrailBucketAndLogTampering"
    effect = "Deny"
    actions = [
      "s3:DeleteBucket", "s3:BypassGovernanceRetention", "s3:PutObjectRetention", "s3:PutObjectLegalHold",
      "s3:DeleteObject", "s3:DeleteObjectVersion", "s3:PutObject",
    ]
    resources = [local.trail_bucket_arn, "${local.trail_bucket_arn}/*"]
  }

  statement {
    sid       = "DenyTrailKeyDisableAndDecrypt"
    effect    = "Deny"
    actions   = ["kms:ScheduleKeyDeletion", "kms:DisableKey", "kms:Decrypt"]
    resources = [aws_kms_key.trail.arn]
  }

  # Terraform in this root never assumes a role, and never opens a root session in a member account (centralized
  # root access): both would hand CI more than this boundary.
  statement {
    sid       = "DenyAssumeRoleAndRoot"
    effect    = "Deny"
    actions   = ["sts:AssumeRole", "sts:AssumeRoot"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "ci_apply_boundary" {
  name        = local.ci_boundary_name
  description = "AA-1004: permissions boundary of the management account Terraform apply role"
  policy      = data.aws_iam_policy_document.ci_apply_boundary.json
}

# -----------------------------------------------------------------------------
# aa-terraform-apply — Terraform Apply, root management, environment org (required reviewer)
# -----------------------------------------------------------------------------
resource "aws_iam_role" "ci_apply" {
  name                 = local.ci_apply_role_name
  description          = "AA-1004: AA-CIS-Infra terraform apply of accounts/management (environment org, main)"
  max_session_duration = 3600
  permissions_boundary = aws_iam_policy.ci_apply_boundary.arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github_actions.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        # Only a job in the `org` environment (required reviewer, deployment branch main) and only from main: the
        # `ref` claim is checked as for aa-cis-infra-tf-apply (AA-866), so a branch that edits the workflow and
        # drops the job's main-only `if` still gets no credentials.
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = ["${var.github_oidc_subject_prefix}:environment:org"]
          "token.actions.githubusercontent.com:ref" = "refs/heads/main"
        }
      }
    }]
  })
}

# Refresh reads (every Describe/Get/List this root needs) and Identity Center administration as AWS documents it for
# the management account (permission sets, assignments, and the aws-reserved roles + AWSSSO_ SAML providers it
# provisions here). The inline policy below adds the writes of the other services this root manages.
resource "aws_iam_role_policy_attachment" "ci_apply_managed" {
  for_each = toset([
    "arn:aws:iam::aws:policy/ReadOnlyAccess",
    "arn:aws:iam::aws:policy/AWSSSOMasterAccountAdministrator",
  ])
  role       = aws_iam_role.ci_apply.name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "ci_apply" {
  name = "${local.ci_apply_role_name}-policy"
  role = aws_iam_role.ci_apply.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # organization.tf + scp.tf: OUs, accounts (create, move, tag), SCPs and attachments, trusted access, policy
        # types. The boundary removes leave/close/remove/delete/invite/delegation.
        Sid      = "OrganizationsManage"
        Effect   = "Allow"
        Action   = ["organizations:*"]
        Resource = "*"
      },
      {
        # identity_center.tf: groups, users, memberships.
        Sid      = "IdentityStoreManage"
        Effect   = "Allow"
        Action   = ["identitystore:*"]
        Resource = "*"
      },
      {
        # Assigning a permission set to this account provisions an aws-reserved role (and an AWSSSO_ SAML provider)
        # here. Also in AWSSSOMasterAccountAdministrator; stated so it does not hang on that policy's contents.
        Sid    = "IdentityCenterReservedRoles"
        Effect = "Allow"
        Action = [
          "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:UpdateRole", "iam:UpdateRoleDescription",
          "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy", "iam:ListRolePolicies",
          "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:ListAttachedRolePolicies",
          "iam:PutRolePermissionsBoundary", "iam:DeleteRolePermissionsBoundary",
        ]
        Resource = local.sso_reserved_role_arn
      },
      {
        Sid      = "IdentityCenterSamlProviders"
        Effect   = "Allow"
        Action   = ["iam:CreateSAMLProvider", "iam:GetSAMLProvider", "iam:UpdateSAMLProvider", "iam:DeleteSAMLProvider"]
        Resource = local.sso_saml_provider_arn
      },
      {
        # Trusted access and the organization trail create these service-linked roles on first use.
        Sid      = "ServiceLinkedRoles"
        Effect   = "Allow"
        Action   = ["iam:CreateServiceLinkedRole"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "iam:AWSServiceName" = ["organizations.amazonaws.com", "sso.amazonaws.com", "cloudtrail.amazonaws.com"]
          }
        }
      },
      {
        # organization.tf aws_iam_organizations_features (enable only; disabling is denied by the boundary).
        Sid    = "CentralizedRootAccess"
        Effect = "Allow"
        Action = [
          "iam:EnableOrganizationsRootCredentialsManagement", "iam:EnableOrganizationsRootSessions",
          "iam:ListOrganizationsFeatures",
        ]
        Resource = "*"
      },
      {
        # budgets.tf: the organization and per-account budgets (same actions as aa365 BudgetsManage, AA-287).
        Sid    = "BudgetsManage"
        Effect = "Allow"
        Action = [
          "budgets:ViewBudget", "budgets:ModifyBudget", "budgets:TagResource", "budgets:UntagResource",
          "budgets:ListTagsForResource",
        ]
        Resource = "*"
      },
      {
        # budgets.tf anomaly monitors and subscriptions. Create takes no resource ARN (as aa365 CostAnomalyCreate).
        Sid      = "CostAnomalyCreate"
        Effect   = "Allow"
        Action   = ["ce:CreateAnomalyMonitor", "ce:CreateAnomalySubscription"]
        Resource = "*"
      },
      {
        Sid    = "CostAnomalyManage"
        Effect = "Allow"
        Action = [
          "ce:GetAnomalyMonitors", "ce:UpdateAnomalyMonitor", "ce:DeleteAnomalyMonitor",
          "ce:GetAnomalySubscriptions", "ce:UpdateAnomalySubscription", "ce:DeleteAnomalySubscription",
          "ce:TagResource", "ce:UntagResource", "ce:ListTagsForResource",
        ]
        Resource = [
          "arn:aws:ce::${var.management_account_id}:anomalymonitor/*",
          "arn:aws:ce::${var.management_account_id}:anomalysubscription/*",
        ]
      },
      {
        # cloudtrail.tf: the organization trail (the boundary denies StopLogging).
        Sid      = "CloudTrailManage"
        Effect   = "Allow"
        Action   = ["cloudtrail:*"]
        Resource = "*"
      },
      {
        # cloudtrail.tf: the trail key and its alias. CreateKey takes no resource ARN. No crypto use (Encrypt,
        # Decrypt, GenerateDataKey): CloudTrail encrypts through the key policy, Terraform never needs to.
        Sid      = "KmsCreateKey"
        Effect   = "Allow"
        Action   = ["kms:CreateKey"]
        Resource = "*"
      },
      {
        Sid    = "KmsManageKeysAndAliases"
        Effect = "Allow"
        Action = [
          "kms:PutKeyPolicy", "kms:EnableKeyRotation", "kms:DisableKeyRotation", "kms:UpdateKeyDescription",
          "kms:TagResource", "kms:UntagResource", "kms:CreateAlias", "kms:DeleteAlias", "kms:UpdateAlias",
          "kms:CancelKeyDeletion",
        ]
        Resource = [
          "arn:aws:kms:${var.region}:${var.management_account_id}:key/*",
          "arn:aws:kms:${var.region}:${var.management_account_id}:alias/aa-*",
        ]
      },
      {
        # cloudtrail.tf: the trail bucket's own settings (bucket ARN only: no object action is granted, and the
        # boundary denies object deletes, retention changes and the governance bypass).
        Sid      = "TrailBucketSettings"
        Effect   = "Allow"
        Action   = ["s3:*"]
        Resource = local.trail_bucket_arn
      },
      {
        # The S3 backend of this root: the state object and its lockfile only.
        Sid      = "StateBucketList"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = local.state_bucket_arn
      },
      {
        Sid      = "StateObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = [local.state_object_arn, local.state_lockfile_arn]
      },
      {
        Sid      = "StateLockfileDelete"
        Effect   = "Allow"
        Action   = ["s3:DeleteObject"]
        Resource = local.state_lockfile_arn
      },
    ]
  })
}

output "ci_plan_role_arn" {
  description = "Role terraform-plan.yml and terraform-drift.yml assume for this root (built from MGMT_ACCOUNT_ID in CI)."
  value       = aws_iam_role.ci_plan.arn
}

output "ci_apply_role_arn" {
  description = "Role terraform-apply.yml (root = management, environment org) assumes."
  value       = aws_iam_role.ci_apply.arn
}
