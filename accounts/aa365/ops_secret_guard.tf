# =============================================================================
# AA-873 (S261, architecture review F1 step 1) — resource policies on the two ecosystem ops keys:
#
#   aa-ecosys/github/aa-agent-app-key  (ADR 0011)
#   aa-ecosys/ops/linear-api-key
#
# Terraform does NOT manage the secrets: they are referenced by data source (metadata only, never the value),
# so nothing is imported, recreated or deleted, and the value never enters state. Only the resource policy
# below is managed here, same pattern as the break-glass secret (identity_alerts.tf, ADR 0006 decision 11).
# The allowed reader is local.ops_secret_reader_role_arns. LOCAL-APPLY ONLY (MFA admin profile): a CI apply that
# creates or changes aws_secretsmanager_secret_policy.ops fails with AccessDenied by design.
# Analysis: Linear AA-873.
#
# Rotation of either key: unchanged (admin profile, put-secret-value), docs/security/github-apps.md.
# Cost: 0 USD (resource policies are free).
# =============================================================================

locals {
  ops_secret_names = {
    github_agent_app = "aa-ecosys/github/aa-agent-app-key"
    linear_api       = "aa-ecosys/ops/linear-api-key"
  }

  # The only principal that may read or write the values: the MFA admin role (identity_alerts.tf local, the
  # role var.identity_breakglass_admin_role_name names).
  ops_secret_reader_role_arns = [local.id_breakglass_admin_role_arn]
}

data "aws_secretsmanager_secret" "ops" {
  for_each = local.ops_secret_names
  name     = each.value
}

data "aws_iam_policy_document" "ops_secret" {
  statement {
    sid    = "DenyValueAccessExceptAdminRole"
    effect = "Deny"
    actions = [
      "secretsmanager:GetSecretValue", "secretsmanager:PutSecretValue", "secretsmanager:UpdateSecret",
      "secretsmanager:RotateSecret", "secretsmanager:ReplicateSecretToRegions",
    ]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "StringNotEquals"
      variable = "aws:PrincipalArn"
      values   = local.ops_secret_reader_role_arns
    }
  }
}

resource "aws_secretsmanager_secret_policy" "ops" {
  for_each            = local.ops_secret_names
  secret_arn          = data.aws_secretsmanager_secret.ops[each.key].arn
  policy              = data.aws_iam_policy_document.ops_secret.json
  block_public_policy = true
}
