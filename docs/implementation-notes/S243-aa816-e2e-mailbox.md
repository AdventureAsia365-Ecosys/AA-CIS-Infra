# AA-816 step I5 — SES inbound mailbox for the Cognito E2E (S243)

Goal: a mailbox CI can read, so a Playwright test can sign a staff user in with the WORKFORCE
email code (AA-816 E1, `cognito-e2e.yml` in AA-CIS-App). Decision D2 option a: the E2E staff user
is `e2e-cognito@adventure.asia`, a forwarder (set by Nghiệp in the adventure.asia mail host panel,
MailChannels) to `e2e@e2e-mail.lumiguides.it.com`, which this PR makes real.

## Decisions

- **One new file** `accounts/aa365/e2e_mailbox.tf`; the MX lives there too (not in `dns.tf`), so the
  whole feature is removable in one place.
- **Sub-domain `e2e-mail.lumiguides.it.com`**: the apex MX is Zoho and `bounce.` is the SES MAIL FROM.
  A new label touches neither. The label was free (`dig` → nothing).
- **No own SES identity for the sub-domain.** Receiving needs a verified domain; SES documents that
  "Subdomains and email addresses inherit verification from the parent domain" (dev guide,
  "Creating and verifying identities"). The apex identity in `ses.tf` is verified (read-only
  `sesv2 get-email-identity`: VerificationStatus SUCCESS). If the first test mail bounces with a
  verification error, add `aws_sesv2_email_identity` for the sub-domain + 3 DKIM CNAMEs ($0).
- **Region us-west-1 receives mail**: `inbound-smtp.us-west-1.amazonaws.com` resolves; the receipt
  API answers (`list-receipt-rule-sets` → `[]`, no active set). So the bucket can be in the same region
  without an SES IAM role.
- **Rule set `aa-cis-dev-e2e` is activated** (`aws_ses_active_receipt_rule_set`). One active set per
  region; none existed. Any future receiving in us-west-1 must add rules to this set.
- **Rule `e2e-cognito`**: recipients = exactly `e2e@e2e-mail.lumiguides.it.com`; scan on; S3 action,
  prefix `inbound/`; `tls_policy = Optional` (the forwarder may relay without TLS; tighten to Require
  once a forwarded mail's headers show TLS). `depends_on` the bucket policy, because SES writes a
  setup-notification object when it creates the rule.
- **Bucket `aa-cis-dev-e2e-mail-005097885195`**: BPA all four, BucketOwnerEnforced, SSE-S3 (AES256),
  lifecycle expire 1 day + abort multipart 1 day, `force_destroy` (only test mail).
- **Bucket policy**:
  - SES `PutObject` on `inbound/*` only, with `aws:SourceAccount` = 005097885195 and `aws:SourceArn`
    = the rule ARN (`receipt-rule-set/aa-cis-dev-e2e:receipt-rule/e2e-cognito`), as in the SES docs.
  - Deny `s3:GetObject*` on objects for every principal except the reader role and the MFA admin
    role (`local.id_breakglass_admin_role_arn` = `nghiep-admin-8h-session`, the role the
    aa365-admin profile assumes). This keeps the ECS task roles, the CI roles and ReadOnlyAccess out
    of the sign-in codes.
  - Bucket-level calls (`s3:ListBucket` = HeadBucket, `Get*Configuration`) are NOT denied, because
    Terraform plan/apply refresh needs them.
  - Deny non-TLS access.
- **Reader role `aa-cis-dev-e2e-mail-reader`**:
  - Workload boundary, as every new role must have; the name is inside `aa-*-dev-*`, so CI apply may
    create it.
  - Trust: the immutable AA-CIS-App subject + `:environment:e2e` and the `ref` claim
    `refs/heads/main`, the same form as `aa-cis-dev-app-deploy`.
  - Policy: `s3:ListBucket` with `s3:prefix` like `inbound/*`, plus `s3:GetObject` on `inbound/*`.
- **Read-only (S243 task):** no `DeleteObject`, which differs from the AA-816 plan text. The 1-day
  lifecycle does the cleanup. E1's mailbox helper must not delete, and must pick the newest object
  with LastModified after the test start, so it never reuses an older code.
- **CI grant**: one new statement `SESReceiptRuleManage` (`ses:*ReceiptRule*`, Resource `*`,
  `aws:RequestedRegion` = us-west-1) appended at the end of the `aws_iam_role_policy.tf_apply`
  statement list. It is a separate block that does not touch the `tf_plan` hunks of Infra #195, to
  keep the rebase clean.
  - Resource `*` because several receipt actions have no resource ARN (CreateReceiptRuleSet,
    DescribeActiveReceiptRuleSet, ListReceiptRuleSets).
  - Everything else is already granted: S3 (AmazonS3FullAccess), Route 53 (Route53ZoneManage), the
    role (IAMRoleManageStack + workload boundary).
  - Plan-side reads (`ses:Describe*`/`List*`, `s3:Get*`) come from ReadOnlyAccess on tf_plan, so
    tf_plan needs no change. The subagent hook blocked an `aws iam` read, so this was not re-read
    live; if the CI plan fails with a 403, that is the place to look.

## Changed

- `accounts/aa365/e2e_mailbox.tf` (new): MX, bucket + BPA + ownership + SSE + lifecycle + policy, rule
  set + active set + rule, reader role + inline policy, outputs `e2e_mail_reader_role_arn` and
  `e2e_mailbox`.
- `accounts/aa365/cicd_split.tf`: `SESReceiptRuleManage` on the apply role (bootstrap).
- `CONTEXT.md`: layout line for `e2e_mailbox.tf`.
- Compared with the plan: no `DeleteObject` (read-only), the MX is not in `dns.tf`, and no
  sub-domain SES identity (inherited).

## Tradeoffs

- **S3 vs SNS/Lambda delivery**: S3 alone is the fewest moving parts, and a CLI read in CI needs no
  new npm dependency. A Lambda that parses the code would be more code to own.
- **Denying object reads to the account vs trusting IAM**: the deny costs one statement, and it keeps
  sign-in codes away from the broad ECS task role and the CI roles.
- **TLS Optional vs Require**: Optional avoids a silent drop on the first forwarded mail. The codes
  are single-use and short-lived, and the user has the reviewer role.
- **Read-only reader**: it cannot clean up, so stale mails sit for up to a day. The helper filters by
  time, and nothing else depends on an empty prefix.

## Should know

- **Apply order (bootstrap):**
  1. CI plan green → merge → `git pull` on main.
  2. Local MFA targeted apply of `aws_iam_role_policy.tf_apply`. Batch it with the other S243
     bootstrap grants in MFA sitting #2. Use the safe credential export:
     `C=$(aws configure export-credentials --profile aa365-admin --format env) || exit 1; export $C`.
  3. Terraform Apply workflow.
  4. Re-plan → No changes.
- **Expected plan** (CI plan on the PR, before the bootstrap apply): Plan: 13 to add, 1 to change,
  1 to destroy, and 2 new outputs.
  - 12 creates:
    - `aws_route53_record.e2e_mail_mx`;
    - `aws_s3_bucket.e2e_mail`, plus its `_public_access_block`, `_ownership_controls`,
      `_server_side_encryption_configuration`, `_lifecycle_configuration` and `_policy`;
    - `aws_ses_receipt_rule_set.e2e`, `aws_ses_active_receipt_rule_set.e2e`,
      `aws_ses_receipt_rule.e2e_cognito`;
    - `aws_iam_role.e2e_mail_reader`, `aws_iam_role_policy.e2e_mail_reader`.
  - `~ aws_iam_role_policy.tf_apply` (one statement added).
  - `-/+ time_sleep.wait_for_iam_propagation` (its trigger is the md5 of that policy).
  - Anything else = stop.
  - After the local targeted apply of `aws_iam_role_policy.tf_apply`, the CI apply shows
    13 add / 0 change / 1 destroy (the time_sleep still replaces). The rule set `depends_on` that
    time_sleep, so it waits 15 s for propagation.
- **After apply (main session)**:
  1. Create GitHub environment `e2e` on AA-CIS-App (deployment branch rule: main).
  2. Set the environment secret `E2E_MAIL_ROLE_ARN` = output `e2e_mail_reader_role_arn`.
     ⚠️ This contains underscore env vars — edit manually in VSCode. It is a GitHub secret name, not
     an app/Vercel/Lambda env var.
- **Live check**: `dig +short MX e2e-mail.lumiguides.it.com` → `10 inbound-smtp.us-west-1.amazonaws.com.`.
  Send one mail to `e2e@e2e-mail.lumiguides.it.com` → an object under `inbound/` within ~2 min
  (`AMAZON_SES_SETUP_NOTIFICATION` also appears once at rule creation). Then mail to
  `e2e-cognito@adventure.asia` (after the forwarder) → second object.
- **Cost**: SES receiving $0.10 per 1,000 mails + $0.09 per 1,000 chunks; S3 < 1 MB for 1 day; R53
  record in the existing zone; IAM and rule set $0. Total < $0.01/month (plan budget "< $0.05").
- Destroying `aws_ses_active_receipt_rule_set.e2e` turns off SES receiving for the whole region.
