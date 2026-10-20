# AA-844 (S246) part 1: CloudFront grant for the CI apply role

One of two AA-844 Infra branches. This one only adds the IAM grant; the photos CDN itself
(`photos_cdn.tf`, bucket policy statement, daily photo_sync schedule) is the second branch, with its
own notes file `AA-844.md`, so the two parallel PRs never conflict on one notes file (lesson S242).

Bootstrap object: `aws_iam_role_policy.tf_apply` cannot be changed by a CI apply, so the orchestrator
applies it locally with MFA from merged `main` (lessons S225, S240), with
`-target=aws_iam_role_policy.tf_apply`, then re-plans the same target ("No changes"). Only then is
the CDN branch applied by `terraform-apply`.

## Decisions

- **New Sid `PhotosCdnCloudFront`, not a widened `CognitoCustomDomainCloudFront`.** The Cognito Sid
  is justified by an AWS-managed distribution (AA-816) and `docs/generated/iam-roles.md` plus the
  AA-816 notes refer to it by name. Keeping the photos grant separate keeps the audit trail readable.
  Only the Cognito Sid's comment changed ("this repo defines no CloudFront distributions" was about
  to become false; it now points at the new Sid).
- **Actions:** `cloudfront:*Distribution*` (Create/Get/Update/Delete/List distribution and
  `GetDistributionConfig`, `CreateDistributionWithTags`), `*OriginAccessControl*`, `*CachePolicy*`,
  `*ResponseHeadersPolicy*`, and the three tag verbs. No `CreateInvalidation`, functions, key groups,
  field-level encryption or realtime logs: nothing in the CDN branch uses them.
- **`Resource = "*"`:** CloudFront is a global service, and `CreateOriginAccessControl`,
  `CreateCachePolicy`, `CreateResponseHeadersPolicy` and the `List*` calls take no resource ARN.
  Scoping distributions by ARN would need the distribution id before it exists.
- **ACM and Route 53 need nothing new:** `ACMCertManage` already allows us-east-1 and
  `Route53ZoneManage` covers the alias and validation records. The S3 bucket policy change is
  covered by the managed S3 policy. The plan role's `ReadOnlyAccess` already reads CloudFront.
- **Permissions boundary:** `aa-cis-infra-tf-apply-boundary` allows `*` apart from role/OIDC writes,
  so it does not cap CloudFront.

## Changed

- `accounts/aa365/cicd_split.tf`: one statement added to `aws_iam_role_policy.tf_apply`; comment on
  `CognitoCustomDomainCloudFront` corrected.

## Tradeoffs

- `*Distribution*` also matches `DeleteDistribution`, `CopyDistribution` and the tenant /
  multi-tenant distribution verbs. A precise list would cost about 150 more characters of the shared
  10,240-character inline limit; the wildcard is bounded to one service on one Dev account.

## Should know

- **Size:** the new statement is 285 characters minified (with its separating comma). The last
  offline render of this policy (AA-846, #230) was 8,678 characters, and #244 did not touch it, so
  the expected total is about 8,963 of 10,240. The orchestrator confirms against the live policy
  before applying (`aws iam get-role-policy ...`, one line). If it does not fit, fold these actions
  into `CognitoCustomDomainCloudFront` instead (saves about 60 characters of statement overhead).
- Expected targeted plan: 1 to change (`aws_iam_role_policy.tf_apply`), 0 add, 0 destroy.
- Zero AWS cost (an IAM policy edit).
