# =============================================================================
# AA-1164 (root SEC-03, tech lead decision D11, S286) — the nightly Image Scan of the images that actually run.
#
# Flow: this repo's workflow "Image Scan (running images)" (.github/workflows/image-scan.yml) runs nightly on main. Its
# scan job reads the cluster and pulls each running digest with the READ-ONLY plan role aa-cis-infra-tf-plan
# (cicd_split.tf, already trusted for `ref:refs/heads/main`: ReadOnlyAccess covers ecs:List*/Describe* and the ECR pull
# reads), so nothing here grants a read. Its upload job writes ONE object, the masked summary, with the role below:
#
#   s3://<bronze>/docs-reader/security/image-scan/summary.json   counts by level, classes and the gate per running digest
#
# The prefix is inside docs-reader/ so the CIS task role can read it later (modules/ecs ReadDocsReader) for an admin
# page, while DenyDocsReaderWrites keeps CIS itself from writing it. The root Docs sync only syncs (with --delete) its
# own pages/ and assets/ subtrees, so it never removes this object; the bucket expires noncurrent docs-reader/
# versions after 7 days (modules/s3).
#
#   - Writer: OIDC role aa-cis-<env>-image-scan-upload, trusted only by THIS repo on refs/heads/main (immutable repo id
#     subject, local.oidc_sub_cis_infra; no environment), PutObject on that single key and nothing else (no Get, no
#     List, no Delete). Its ARN goes into this repo's secret IMAGE_SCAN_UPLOAD_ROLE_ARN (a secret, not a variable:
#     the repo is public and a variable is printed in the run log, lessons S249). Without it the workflow skips the
#     upload with a notice.
#
# Cost (us-west-1, D-19): one PUT of a few tens of kB a night = ~30 PUT/month (< $0.001) + 7 days of noncurrent copies
# (< 1 MB). IAM $0. No new bucket, KMS key or compute.
# =============================================================================

locals {
  image_scan_upload_role = "${local.name_prefix}-image-scan-upload"
  image_scan_summary_key = "${local.docs_reader_prefix}security/image-scan/summary.json"
}

resource "aws_iam_role" "image_scan_upload" {
  name                 = local.image_scan_upload_role
  description          = "AA-1164: AA-CIS-Infra Image Scan workflow on main uploads the masked nightly summary"
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
          "token.actions.githubusercontent.com:sub" = "${local.oidc_sub_cis_infra}:ref:refs/heads/main"
          "token.actions.githubusercontent.com:ref" = "refs/heads/main"
        }
      }
    }]
  })

  tags = merge(local.common_tags, { Issue = "AA-1164", Component = "cicd" })

  depends_on = [time_sleep.wait_for_iam_propagation]
}

resource "aws_iam_role_policy" "image_scan_upload" {
  name = "${local.image_scan_upload_role}-policy"
  role = aws_iam_role.image_scan_upload.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # The one object the workflow writes; the bucket is SSE-S3 (AES256), so no KMS grant is needed.
        Sid      = "WriteImageScanSummary"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "arn:aws:s3:::${module.s3.bronze_bucket_name}/${local.image_scan_summary_key}"
      },
    ]
  })
}

output "image_scan_upload_role_arn" {
  description = "AA-1164: set as this repo's (AA-CIS-Infra) Actions secret IMAGE_SCAN_UPLOAD_ROLE_ARN for image-scan.yml."
  value       = aws_iam_role.image_scan_upload.arn
}
