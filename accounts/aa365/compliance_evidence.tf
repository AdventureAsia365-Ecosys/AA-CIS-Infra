# =============================================================================
# AA-1173 (S290, compliance readiness phase 2; tech lead decisions S287 Q6 / Q8 / Q11, root advisory
# docs/audits/2026-11-21-S287-compliance-tracking/README.md section 4 C.5) — the immutable evidence store of the CIS
# admin page Platform › Compliance and the role its collectors write with.
#
# Bucket aa-cis-<env>-compliance-evidence-<account>: versioning + Object Lock (default retention GOVERNANCE,
# var.compliance_evidence_retention_days), SSE-S3 (no KMS key: 1 USD/month + requests would break the ~0 USD budget,
# advisory D.5), all public access blocked, BucketOwnerEnforced, TLS only. GOVERNANCE alone does not stop an
# administrator (s3:BypassGovernanceRetention is in AdministratorAccess), so the bucket policy denies EVERY principal:
#   - s3:BypassGovernanceRetention, s3:PutObjectRetention, s3:PutObjectLegalHold, s3:DeleteObject,
#     s3:DeleteObjectVersion (no delete marker, no version removal, no shorter lock; lifecycle expiry is done by S3
#     itself after the retention and is not a principal's request);
#   - s3:PutObject without `If-None-Match: *` (S3 conditional writes): every object is write-once, an overwrite of an
#     existing key is refused (412) and a plain PUT is refused (403);
#   - s3:PutObject by anyone but the collector role (the CIS task role keeps its broad put grant elsewhere; it may not
#     write evidence).
# Lifting any of this means editing the bucket policy (a Terraform change, reviewed, CloudTrail management event). Dev
# is GOVERNANCE only: tools/terraform/plan_guard.py refuses a COMPLIANCE create and any change of the lock
# configuration (so changing the retention variable after the first apply needs the guard's allow_guarded override and
# the tech lead). Lifecycle: a current version expires one day after the retention, then its noncurrent copy a day
# later (S3 never removes a version that is still locked). No CloudTrail data events on this bucket (billed per event).
#
# Layout (the writer is tools/compliance/seal.py, the same file in the root repo and here; the reader is AA-CIS-App
# api/services/compliance_store.py):
#   evidence/<source>/bundles/<yyyy>/<mm>/<dd>/<HHMMSS>Z-<run>.json    the evidence bundle the CIS page ingests
#   evidence/<source>/raw/<yyyy>/<mm>/<dd>/<HHMMSS>Z-<run>/<file>      raw output (Prowler findings, AWS answers)
#   evidence/<source>/manifest/<yyyy>/<mm>/<dd>/<HHMMSS>Z-<run>.json   SHA-256 of each object + the previous manifest
#                                                                       of the source (hash chain)
# Sources: root_daily (root compliance-evidence.yml), aws_nightly and prowler_weekly (this repo's compliance-aws.yml).
# No personal data of customers in evidence (advisory C.5 point 5: Object Lock would block an erasure request); staff
# identities only.
#
# Role aa-cis-<env>-compliance-evidence (Q6): SecurityAudit + ViewOnlyAccess (AWS managed, read-only; no s3:GetObject
# on other buckets, no log events; known leftover: Lambda environment values stay readable through lambda:ListFunctions /
# GetFunctionConfiguration, which Prowler's secrets-in-variables check needs), a small read addition for Prowler and the nightly checks
# (below, without the data reads Prowler's own extra policy asks for: lambda:GetFunction, logs:FilterLogEvents,
# ssm:GetDocument, glue:SearchTables, securityhub:BatchImportFindings), List/Get/Put on evidence/ of this bucket only,
# and an explicit deny of every delete and lock change. Trust: GitHub OIDC, one statement per workflow, each pinned on
# the immutable repo subject + branch AND `job_workflow_ref` (the exact workflow file on the default branch; AWS
# evaluates it for GitHub tokens, IAM condition keys "Available keys for AWS OIDC federation"), so no other workflow
# of either repo can write evidence, and pull_request runs never get it. Its ARN goes into the Actions secret
# COMPLIANCE_EVIDENCE_ROLE_ARN of the root repo and of this repo, the bucket name into COMPLIANCE_EVIDENCE_BUCKET
# (secrets: both repos are public and a variable is printed in the run log, lessons S249). Without them the workflows
# skip the upload with a notice. The role carries the workload boundary (no IAM writes, no guarded secret values).
#
# CIS reader: the CIS task role gets ListBucket on evidence/ and GetObject on evidence/* of this bucket (read only).
#
# AA-1183 part 2 (S297): the same role runs the weekly secret rotation check (root .github/workflows/secret-rotation.yml,
# tools/security/rotation_check.py) through a third trust statement pinned on that workflow file on master. The tool
# makes 13 metadata calls only (`rotation_check.py iam-actions` prints them; its tests pin the list); they are granted
# explicitly in RotationCheckMetadata, so the check does not depend on what SecurityAudit / ViewOnlyAccess happen to
# contain. None returns a secret value. The managed policies would grant some (SecurityAudit has cognito-idp:Describe*:
# DescribeUserPoolClient returns the app client secret, DescribeIdentityProvider the external IdP client secret), so the
# role is denied every secret-value read explicitly (DenySecretValueReads: secretsmanager:GetSecretValue /
# BatchGetSecretValue, both Cognito calls, acm:ExportCertificate, kms:Decrypt); ListUserPoolClientSecrets never returns
# a value. The two Prowler checks that need DescribeUserPoolClient are excluded in compliance-aws.yml (they would report
# a false FAIL per client); tools/terraform/tests/test_aa1183_rotation_metadata.py pins the same two client settings on
# every aws_cognito_user_pool_client instead. Writes nothing in AWS (issues go to GitHub with the run's own token).
# Cost: 0 USD (a few hundred free read calls a week).
#
# Cost (us-west-1, D-19; estimates): storage a few MB a year (daily bundles of a few kB, weekly Prowler JSON of a few MB)
# < 0.01 USD/month; PUT ~10 a day + manifests ~= 400/month < 0.01 USD; GET/LIST from the CIS page (cached 5 min per
# process) a few thousand a month < 0.01 USD. Object Lock and versioning have no fee. IAM 0 USD. Total < 0.05 USD/month.
# =============================================================================

variable "compliance_evidence_retention_days" {
  description = "AA-1173: Object Lock default retention (GOVERNANCE) of the compliance evidence bucket, in days. Root data standards D-09 security/audit class: 365. Changing it after the first apply is an Object Lock configuration update, which tools/terraform/plan_guard.py refuses without allow_guarded (tech lead)."
  type        = number
  default     = 365

  validation {
    condition     = var.compliance_evidence_retention_days >= 30 && var.compliance_evidence_retention_days <= 2557
    error_message = "compliance_evidence_retention_days must be between 30 days and 7 years (2557 days)."
  }
}

locals {
  compliance_evidence_bucket = "${local.name_prefix}-compliance-evidence-${var.account_id}"
  compliance_evidence_role   = "${local.name_prefix}-compliance-evidence"
  compliance_evidence_prefix = "evidence/"
  compliance_evidence_tags   = merge(local.shared_tags, { Component = "security", Issue = "AA-1173" })

  # The exact workflow file (on the default branch) each trust statement accepts, besides the immutable subject
  # (org id / repo id, same form as local.oidc_sub_cis_infra in cicd_split.tf and local.docs_sync_oidc_sub in
  # docs_reader.tf) and the ref.
  compliance_evidence_root_workflow     = "AdventureAsia365-Ecosys/AA-Ecosys/.github/workflows/compliance-evidence.yml@refs/heads/master"
  compliance_evidence_infra_workflow    = "AdventureAsia365-Ecosys/AA-CIS-Infra/.github/workflows/compliance-aws.yml@refs/heads/main"
  compliance_evidence_rotation_workflow = "AdventureAsia365-Ecosys/AA-Ecosys/.github/workflows/secret-rotation.yml@refs/heads/master"

  # AA-1183 part 2: exactly the calls of the root rotation check (tools/security/rotation_check.py AWS_CALLS). Metadata
  # only; change it together with that list (both repos pin it in a test).
  compliance_evidence_rotation_read = [
    "acm:DescribeCertificate", "acm:ListCertificates",
    "cognito-idp:ListUserPoolClientSecrets", "cognito-idp:ListUserPoolClients", "cognito-idp:ListUserPools",
    "iam:ListAccessKeys", "iam:ListUsers",
    "kms:DescribeKey", "kms:GetKeyRotationStatus", "kms:ListAliases",
    "rds:DescribeDBInstances",
    "secretsmanager:ListSecretVersionIds", "secretsmanager:ListSecrets",
  ]
  # Calls that return a secret value or key material: never this role's, whatever a managed policy grows into.
  # SecurityAudit grants cognito-idp:Describe*, which includes the two Cognito calls (app client secret, external IdP
  # client secret); the deny wins over that grant.
  compliance_evidence_secret_value_reads = [
    "secretsmanager:GetSecretValue", "secretsmanager:BatchGetSecretValue",
    "cognito-idp:DescribeUserPoolClient", "cognito-idp:DescribeIdentityProvider",
    "acm:ExportCertificate", "kms:Decrypt",
  ]

  # Read-only additions for Prowler and the nightly checks that SecurityAudit / ViewOnlyAccess do not cover. No data
  # reads (object bodies, log events, function code or environment, parameter documents, table contents).
  compliance_evidence_read_extra = [
    "account:GetAlternateContact", "account:GetContactInformation", "account:GetPrimaryEmail",
    "auditmanager:GetAccountStatus",
    "backup:ListBackupPlans", "backup:ListBackupVaults", "backup:ListRecoveryPointsByBackupVault",
    "cloudtrail:GetInsightSelectors",
    "cognito-idp:GetUserPoolMfaConfig",
    "ec2:GetEbsEncryptionByDefault", "ec2:GetInstanceMetadataDefaults", "ec2:GetSnapshotBlockPublicAccessState",
    "ecr:DescribeImageScanFindings", "ecr:DescribeRegistry", "ecr:GetRegistryScanningConfiguration",
    "iam:GenerateCredentialReport", "iam:GetCredentialReport",
    "s3:GetAccountPublicAccessBlock",
    "shield:GetSubscriptionState",
    "tag:GetTagKeys",
  ]

  # Every way to remove, shorten or overwrite evidence. Denied to every principal on the bucket and to the role.
  compliance_evidence_tamper_actions = [
    "s3:BypassGovernanceRetention", "s3:PutObjectRetention", "s3:PutObjectLegalHold",
    "s3:DeleteObject", "s3:DeleteObjectVersion",
  ]
  # The role also never changes the bucket's own protection.
  compliance_evidence_role_denies = concat(local.compliance_evidence_tamper_actions, [
    "s3:PutBucketPolicy", "s3:DeleteBucketPolicy", "s3:PutBucketObjectLockConfiguration",
    "s3:PutLifecycleConfiguration", "s3:PutBucketVersioning",
  ])
}

# ── Bucket ────────────────────────────────────────────────────────────────────────────────────────────────────────────
resource "aws_s3_bucket" "compliance_evidence" {
  bucket = local.compliance_evidence_bucket
  # Object Lock must be enabled at creation (an existing bucket can be switched too, but plan_guard treats both alike).
  object_lock_enabled = true
  force_destroy       = false

  tags = merge(local.compliance_evidence_tags, { Name = local.compliance_evidence_bucket, DataClassification = "internal" })
}

resource "aws_s3_bucket_public_access_block" "compliance_evidence" {
  bucket                  = aws_s3_bucket.compliance_evidence.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "compliance_evidence" {
  bucket = aws_s3_bucket.compliance_evidence.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "compliance_evidence" {
  bucket = aws_s3_bucket.compliance_evidence.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # SSE-S3: no KMS key fee (advisory D.5)
    }
  }
}

resource "aws_s3_bucket_versioning" "compliance_evidence" {
  bucket = aws_s3_bucket.compliance_evidence.id
  versioning_configuration {
    status = "Enabled" # Object Lock requires it
  }
}

resource "aws_s3_bucket_object_lock_configuration" "compliance_evidence" {
  bucket              = aws_s3_bucket.compliance_evidence.id
  object_lock_enabled = "Enabled"

  rule {
    default_retention {
      mode = "GOVERNANCE" # never COMPLIANCE on Dev (plan_guard refuses it); the bucket policy denies the bypass
      days = var.compliance_evidence_retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.compliance_evidence]
}

resource "aws_s3_bucket_lifecycle_configuration" "compliance_evidence" {
  bucket = aws_s3_bucket.compliance_evidence.id

  rule {
    id     = "expire-after-retention"
    status = "Enabled"
    filter {}

    expiration {
      days = var.compliance_evidence_retention_days + 1
    }
    noncurrent_version_expiration {
      noncurrent_days = 1
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  rule {
    id     = "remove-expired-delete-markers"
    status = "Enabled"
    filter {}

    expiration {
      expired_object_delete_marker = true
    }
  }

  depends_on = [aws_s3_bucket_versioning.compliance_evidence]
}

data "aws_iam_policy_document" "compliance_evidence_bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.compliance_evidence.arn, "${aws_s3_bucket.compliance_evidence.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # Every principal, the account root and administrators included: no delete, no version removal, no shorter lock,
  # no legal-hold games. Undoing this is a reviewed change of this file.
  statement {
    sid       = "DenyEvidenceTampering"
    effect    = "Deny"
    actions   = local.compliance_evidence_tamper_actions
    resources = ["${aws_s3_bucket.compliance_evidence.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }

  # Write-once: a PutObject must carry If-None-Match: * (S3 conditional write); an existing key then answers 412.
  statement {
    sid       = "DenyOverwrite"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.compliance_evidence.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Null"
      variable = "s3:if-none-match"
      values   = ["true"]
    }
  }

  # Only the collector role writes, and only under evidence/.
  statement {
    sid       = "DenyWritesButTheCollector"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.compliance_evidence.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "ArnNotEquals"
      variable = "aws:PrincipalArn"
      values   = [aws_iam_role.compliance_evidence.arn]
    }
  }

  statement {
    sid           = "DenyWritesOutsideThePrefix"
    effect        = "Deny"
    actions       = ["s3:PutObject"]
    not_resources = ["${aws_s3_bucket.compliance_evidence.arn}/${local.compliance_evidence_prefix}*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }
}

resource "aws_s3_bucket_policy" "compliance_evidence" {
  bucket = aws_s3_bucket.compliance_evidence.id
  policy = data.aws_iam_policy_document.compliance_evidence_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.compliance_evidence, aws_s3_bucket_object_lock_configuration.compliance_evidence]
}

# ── Collector role ────────────────────────────────────────────────────────────────────────────────────────────────────
resource "aws_iam_role" "compliance_evidence" {
  name                 = local.compliance_evidence_role
  description          = "AA-1173: compliance collectors (root compliance-evidence.yml, Infra compliance-aws.yml on the default branch) read the account and write write-once evidence; AA-1183: root secret-rotation.yml reads secret metadata"
  permissions_boundary = aws_iam_policy.workload_boundary.arn
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "GitHubOidcRootDaily"
        Effect    = "Allow"
        Principal = { Federated = aws_iam_openid_connect_provider.github_actions.arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud"              = "sts.amazonaws.com"
            "token.actions.githubusercontent.com:sub"              = local.docs_sync_oidc_sub
            "token.actions.githubusercontent.com:ref"              = "refs/heads/master"
            "token.actions.githubusercontent.com:job_workflow_ref" = local.compliance_evidence_root_workflow
          }
        }
      },
      {
        Sid       = "GitHubOidcInfraAws"
        Effect    = "Allow"
        Principal = { Federated = aws_iam_openid_connect_provider.github_actions.arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud"              = "sts.amazonaws.com"
            "token.actions.githubusercontent.com:sub"              = "${local.oidc_sub_cis_infra}:ref:refs/heads/main"
            "token.actions.githubusercontent.com:ref"              = "refs/heads/main"
            "token.actions.githubusercontent.com:job_workflow_ref" = local.compliance_evidence_infra_workflow
          }
        }
      },
      {
        # AA-1183 part 2: the weekly secret rotation check (its check job has no environment, so the subject is the
        # master ref, as for compliance-evidence.yml).
        Sid       = "GitHubOidcRootRotation"
        Effect    = "Allow"
        Principal = { Federated = aws_iam_openid_connect_provider.github_actions.arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud"              = "sts.amazonaws.com"
            "token.actions.githubusercontent.com:sub"              = local.docs_sync_oidc_sub
            "token.actions.githubusercontent.com:ref"              = "refs/heads/master"
            "token.actions.githubusercontent.com:job_workflow_ref" = local.compliance_evidence_rotation_workflow
          }
        }
      },
    ]
  })

  tags = merge(local.compliance_evidence_tags, { Component = "cicd" })

  depends_on = [time_sleep.wait_for_iam_propagation]
}

resource "aws_iam_role_policy_attachment" "compliance_evidence_security_audit" {
  role       = aws_iam_role.compliance_evidence.name
  policy_arn = "arn:aws:iam::aws:policy/SecurityAudit"
}

resource "aws_iam_role_policy_attachment" "compliance_evidence_view_only" {
  role       = aws_iam_role.compliance_evidence.name
  policy_arn = "arn:aws:iam::aws:policy/job-function/ViewOnlyAccess"
}

resource "aws_iam_role_policy" "compliance_evidence" {
  name = "${local.compliance_evidence_role}-policy"
  role = aws_iam_role.compliance_evidence.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadExtraForProwlerAndChecks"
        Effect   = "Allow"
        Action   = local.compliance_evidence_read_extra
        Resource = "*"
      },
      {
        # AA-1183 part 2: the metadata calls of the root rotation check (names, dates, rotation and renewal status).
        Sid      = "RotationCheckMetadata"
        Effect   = "Allow"
        Action   = local.compliance_evidence_rotation_read
        Resource = "*"
      },
      {
        # AA-1183 part 2: never a secret value or key material, whatever SecurityAudit / ViewOnlyAccess grow into.
        Sid      = "DenySecretValueReads"
        Effect   = "Deny"
        Action   = local.compliance_evidence_secret_value_reads
        Resource = "*"
      },
      {
        # The previous manifest of a source (the hash chain) is listed and read back before a run writes its own.
        Sid      = "ListEvidencePrefix"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.compliance_evidence.arn
        Condition = {
          StringLike = { "s3:prefix" = ["${local.compliance_evidence_prefix}*"] }
        }
      },
      {
        Sid      = "ReadAndWriteOnceEvidence"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "${aws_s3_bucket.compliance_evidence.arn}/${local.compliance_evidence_prefix}*"
      },
      {
        # Belt and braces with the bucket policy: whatever a managed policy grows into, this role never removes,
        # shortens or overwrites evidence, and never reads another bucket's objects.
        Sid      = "DenyTampering"
        Effect   = "Deny"
        Action   = local.compliance_evidence_role_denies
        Resource = [aws_s3_bucket.compliance_evidence.arn, "${aws_s3_bucket.compliance_evidence.arn}/*"]
      },
      {
        Sid         = "DenyOtherObjectReads"
        Effect      = "Deny"
        Action      = ["s3:GetObject", "s3:GetObjectVersion"]
        NotResource = ["${aws_s3_bucket.compliance_evidence.arn}/${local.compliance_evidence_prefix}*"]
      },
    ]
  })
}

# ── CIS reader ────────────────────────────────────────────────────────────────────────────────────────────────────────
resource "aws_iam_role_policy" "ecs_read_compliance_evidence" {
  name = "${local.name_prefix}-ecs-read-compliance-evidence"
  role = module.ecs.task_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListComplianceEvidence"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.compliance_evidence.arn
        Condition = {
          StringLike = { "s3:prefix" = ["${local.compliance_evidence_prefix}*"] }
        }
      },
      {
        Sid      = "ReadComplianceEvidence"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.compliance_evidence.arn}/${local.compliance_evidence_prefix}*"
      },
    ]
  })
}

output "compliance_evidence_role_arn" {
  description = "AA-1173: set as the Actions secret COMPLIANCE_EVIDENCE_ROLE_ARN of the root repo (AA-Ecosys) and of AA-CIS-Infra."
  value       = aws_iam_role.compliance_evidence.arn
}

output "compliance_evidence_bucket" {
  description = "AA-1173: set as the Actions secret COMPLIANCE_EVIDENCE_BUCKET of the root repo and of AA-CIS-Infra."
  value       = aws_s3_bucket.compliance_evidence.bucket
}
