# =============================================================================
# AA-898 — the /admin/docs reader of the CIS admin: where the docs bundle lives and who may write / read it.
#
# Flow: the root repo (AA-Ecosys) workflow "Docs sync" (.github/workflows/docs-sync.yml) runs on every push to master
# that touches docs/. On a clean CI checkout it runs tools/docs/build_docs_reader.py (publication rule v1: catalog
# pages and ADRs only; journals, audits, docs/security/ and templates never; every account / VPC / user-pool / API
# Gateway ID redacted, a guard fails the build if one is left) and uploads the bundle to the bronze bucket:
#
#   s3://<bronze>/docs-reader/manifest.json             the list of published pages (format 1)
#   s3://<bronze>/docs-reader/pages/<repo>/<path>.md     one redacted Markdown body per page
#
# The CIS api (AA-CIS-App api/services/docs_reader.py, GET /admin/docs/manifest and /admin/docs/page, admin only, the
# SEC / infrastructure-map pages owner only) reads those objects with the CIS task role.
#
#   - Writer: OIDC role aa-cis-<env>-docs-sync, trusted only by the root repo on refs/heads/master (immutable repo id
#     subject, like TripPlanner's tp_oidc_subjects). ListBucket on docs-reader/ and Put / Delete on docs-reader/* of
#     the bronze bucket, nothing else. Its ARN goes into the root repo secret DOCS_SYNC_ROLE_ARN (a secret, not a
#     variable: the root repo is public for now and a variable is printed in the run log, lessons S249).
#   - Reader: the CIS task role (modules/ecs ReadDocsReader; DenyDocsReaderWrites keeps the CIS "*" put grant off
#     the prefix, so only CI writes what the admin shows).
#   - Retention: the bronze bucket is versioned, and `aws s3 sync` from a fresh checkout re-uploads every page (new
#     mtimes), so modules/s3 expires noncurrent docs-reader/ versions after 7 days.
#
# Cost (us-west-1, D-19): ~100 pages, ~2 MB current + at most ~7 days of noncurrent copies (a few runs a day,
# ~2 MB each) < 0.05 GB = ~$0.001/month storage; ~100 PUT per sync x ~5 syncs a day = ~15,000 PUT/month = ~$0.08;
# GETs are cached 5 min in the api, a few hundred a month = ~$0. Total under $0.10/month, IAM $0. No new bucket,
# KMS key or compute.
# =============================================================================

locals {
  # Immutable subject (org id / repo id) of the root repo, same form as local.oidc_sub_cis_app (cicd_split.tf).
  docs_sync_oidc_sub = "repo:AdventureAsia365-Ecosys@276539096/AA-Ecosys@1371676753:ref:refs/heads/master"
  docs_reader_prefix = "docs-reader/"
  docs_sync_role     = "${local.name_prefix}-docs-sync"
}

resource "aws_iam_role" "docs_sync" {
  name                 = local.docs_sync_role
  description          = "AA-898: root repo Docs sync workflow on master uploads the admin docs reader bundle"
  permissions_boundary = aws_iam_policy.workload_boundary.arn
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github_actions.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = local.docs_sync_oidc_sub
          "token.actions.githubusercontent.com:ref" = "refs/heads/master"
        }
      }
    }]
  })

  tags = merge(local.common_tags, { Issue = "AA-898" })

  depends_on = [time_sleep.wait_for_iam_propagation]
}

resource "aws_iam_role_policy" "docs_sync" {
  name = "${local.docs_sync_role}-policy"
  role = aws_iam_role.docs_sync.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListDocsReaderPrefix"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${module.s3.bronze_bucket_name}"
        Condition = {
          StringLike = { "s3:prefix" = ["${local.docs_reader_prefix}*"] }
        }
      },
      {
        Sid      = "WriteDocsReaderObjects"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:DeleteObject"]
        Resource = "arn:aws:s3:::${module.s3.bronze_bucket_name}/${local.docs_reader_prefix}*"
      },
    ]
  })
}

output "docs_sync_role_arn" {
  description = "AA-898: set as the root repo (AA-Ecosys) Actions secret DOCS_SYNC_ROLE_ARN for docs-sync.yml."
  value       = aws_iam_role.docs_sync.arn
}
