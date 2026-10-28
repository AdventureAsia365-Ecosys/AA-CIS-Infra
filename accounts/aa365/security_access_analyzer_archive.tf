# =============================================================================
# AA-873 (S256) — IAM Access Analyzer archive rules for the findings triaged as intended.
#
# The external-access analyzer (security_baseline.tf) reported 11 ACTIVE findings on its first scan (28/10/2026,
# read with list-findings-v2 / get-finding-v2, root audit docs/audits/2026-10-28-S256-aa873-triage/). All 11 are
# intended; none is a real exposure:
#   - 9 IAM roles trusted by the GitHub Actions OIDC provider. Access Analyzer drops the token claims from the
#     finding ("condition": {}), so each trust policy was read in this repo: every one pins the audience
#     (sts.amazonaws.com) AND an exact subject of one repo by immutable owner/repo ids (no wildcard: the Booking and
#     CRM repo-id variables are set in terraform.tfvars), most also the ref (refs/heads/main or master).
#   - 1 role of the organization's IAM Identity Center permission set AdministratorAccess (trusts the AWSSSO SAML
#     provider). Created and owned by Identity Center, not by this repo; it cannot be removed here.
#   - 1 statement of the bronze bucket policy for the Bedrock batch-inference service role of the LLM account
#     (modules/s3, AA-399/AA-606): GetObject/PutObject on the batch-input/ and batch-output/ prefixes and a
#     prefix-limited ListBucket. The former statement for the retired account is already RESOLVED (AA-998).
#
# Why explicit resource lists and not "any role trusted by the OIDC provider": the analyzer cannot see the subject
# claim, so a new OIDC role with a loose trust (repo:*, a branch wildcard) would look identical. Each new OIDC role
# therefore raises one "[aa-sec] access_analyzer" e-mail; review its trust, then add it below. The guard test
# tools/terraform/tests/test_sec_access_analyzer.py fails when an OIDC role is missing here or its trust is loose.
#
# Archive rules act on NEW findings only. After the first apply the orchestrator archives the 11 existing findings
# once with `aws accessanalyzer apply-archive-rule` (one call per rule, MFA admin; root .tmp-session/S256/aa873/).
#
# Cost: 0 USD (archive rules are free; the external-access analyzer is free).
# Apply: the apply role needs access-analyzer:*ArchiveRule + ListArchiveRules (cicd_sec.tf, bootstrap policy
# aa-cis-infra-tf-apply-sec): targeted local MFA apply of aws_iam_policy.tf_apply_sec first, then CI applies this file.
# =============================================================================

locals {
  # Every role trusted by aws_iam_openid_connect_provider.github_actions, reviewed one by one (S256 triage table).
  sec_aa_github_oidc_roles = concat(
    [
      aws_iam_role.cis_app_deploy.arn,         # AA-CIS-App, environment dev, ref main
      aws_iam_role.e2e_mail_reader.arn,        # AA-CIS-App + AA-Partner, environment e2e, ref main
      aws_iam_role.tf_plan.arn,                # AA-CIS-Infra, pull_request or ref main (read only)
      aws_iam_role.tf_apply.arn,               # AA-CIS-Infra, environment prod, ref main
      aws_iam_role.docs_sync.arn,              # root repo, ref master
      aws_iam_role.booking_app_deploy.arn,     # AA-Booking, environment dev or ref main
      aws_iam_role.tripplanner_app_deploy.arn, # AA-TripPlanner-Web, ref main
      aws_iam_role.crm_app_deploy.arn,         # AA-Partner, environment dev
    ],
    aws_iam_role.crm_scrub_corpus[*].arn, # AA-Partner, environment scrub-corpus (only when the guardrail is on)
  )

  # The bucket-policy principal of modules/s3 (AllowBedrockBatch*Acc3).
  sec_aa_bronze_batch_principal = "arn:aws:iam::${local.bedrock_acct_primary}:role/aa3-bedrock-batch-inference-role"
}

resource "aws_accessanalyzer_archive_rule" "github_oidc_roles" {
  analyzer_name = aws_accessanalyzer_analyzer.external.analyzer_name
  rule_name     = "github-oidc-deploy-roles"

  filter {
    criteria = "resourceType"
    eq       = ["AWS::IAM::Role"]
  }

  # Only the OIDC trust is archived: if one of these roles later trusts another account as well, that finding has a
  # principal.AWS and stays ACTIVE.
  filter {
    criteria = "principal.Federated"
    eq       = [aws_iam_openid_connect_provider.github_actions.arn]
  }

  filter {
    criteria = "resource"
    eq       = local.sec_aa_github_oidc_roles
  }

  lifecycle {
    precondition {
      condition     = length(local.sec_aa_github_oidc_roles) <= 20
      error_message = "An Access Analyzer filter takes at most 20 values: split github_oidc_roles into two rules."
    }
  }
}

# Identity Center: only the AdministratorAccess permission set seen in the triage. A new permission set assigned to
# this account (another name) still raises a finding, so a new way in is never silent.
resource "aws_accessanalyzer_archive_rule" "identity_center_admin" {
  analyzer_name = aws_accessanalyzer_analyzer.external.analyzer_name
  rule_name     = "identity-center-admin-permission-set"

  filter {
    criteria = "resourceType"
    eq       = ["AWS::IAM::Role"]
  }

  filter {
    criteria = "resource"
    contains = ["role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_AdministratorAccess_"]
  }

  filter {
    criteria = "principal.Federated"
    contains = [":saml-provider/AWSSSO_"]
  }
}

resource "aws_accessanalyzer_archive_rule" "bronze_bedrock_batch" {
  analyzer_name = aws_accessanalyzer_analyzer.external.analyzer_name
  rule_name     = "bronze-bedrock-batch-satellite"

  filter {
    criteria = "resourceType"
    eq       = ["AWS::S3::Bucket"]
  }

  filter {
    criteria = "resource"
    eq       = [module.s3.bronze_bucket_arn]
  }

  filter {
    criteria = "principal.AWS"
    eq       = [local.sec_aa_bronze_batch_principal]
  }

  filter {
    criteria = "isPublic"
    eq       = ["false"]
  }
}
