# =============================================================================
# AA-873 (S261, architecture review F1 step 1) — resource policies on the two ecosystem ops keys.
#
# aa-ecosys/github/aa-agent-app-key  private key of the aa-agent GitHub App (ADR 0011; write on Contents,
#                                    Workflows, Actions and PRs of the five repos). Read by tools/github/as-app.sh.
# aa-ecosys/ops/linear-api-key       Linear API key. Read by tools/linear/linear_export.py.
#
# Both secrets were created by hand with the CLI (docs/security/github-apps.md part 4, S247; the Linear key S245).
# Terraform does NOT manage them: they are referenced by data source (DescribeSecret metadata only, never the
# value), so nothing is imported, recreated or deleted, and the value never enters state. Only the resource
# policy below is managed here.
#
# Same pattern as the break-glass secret (identity_alerts.tf, ADR 0006 decision 11): an explicit Deny of the
# value calls for every principal except the MFA admin role. Before this, any principal with a broad
# GetSecretValue grant could read them: the CIS ECS task role (Allow on "*", now also denied aa-ecosys/* in
# modules/ecs) and the Terraform apply role (SecretsManagerReadWrite, now capped by DenySecretValuesTerraform-
# DoesNotRefresh in cicd_split.tf). The resource policy is the layer that still holds if either identity
# policy is widened again, and it also covers roles added later.
#
# Who reads them (CloudTrail GetSecretValue 01-31/10/2026): only nghiep-admin-8h-session, the role the
# aa365-admin / default CLI profiles assume (as-app.sh key_profile, linear_export.py AWS_PROFILE_LINEAR default).
# An assumed-role session's aws:PrincipalArn is the role ARN, so the condition matches every session of it.
#
# Denied to everyone else: GetSecretValue and PutSecretValue (the pair the break-glass policy denies), plus the
# calls that change the value or copy it out of this policy's reach (UpdateSecret can carry a SecretString,
# RotateSecret hands the value to a Lambda, ReplicateSecretToRegions creates a replica that does not carry this
# policy). Not denied here: DescribeSecret / GetResourcePolicy (plan refresh) and PutResourcePolicy (the apply
# writes this policy; who may call it is decided by the boundaries below, not by this policy).
#
# The policy is one of three layers (review fix, S261). Who could still get a value if this policy were removed:
#   - the CIS task role: nobody (no PutResourcePolicy, and its identity Deny on aa-ecosys/*);
#   - the Terraform apply role, directly: nobody (boundary DenySecretValuesTerraformDoesNotRefresh);
#   - the apply role through a role it writes and runs (PutRolePolicy on an aa-*-dev-* role, then RunTask / ECS
#     exec): nobody, because every such role carries the workload boundary, which denies GetSecretValue on
#     aa-ecosys/* and aa-identity/* (DenyEcosystemGuardedSecretValues, cicd_split.tf);
#   - removing or rewriting this policy is itself denied to the apply role (boundary
#     DenyEcosystemGuardedSecretPolicyEdits): this file is LOCAL-APPLY ONLY (MFA admin profile). A CI apply that
#     creates or changes aws_secretsmanager_secret_policy.ops fails with AccessDenied by design.
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
