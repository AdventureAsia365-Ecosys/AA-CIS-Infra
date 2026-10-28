# AA-682 — Booking ops-docs bucket (S1 follow-up)

The AA-697 drift check (S256, root `docs/audits/2026-10-28-S256-aa697-drift/`) found that the Booking ops-docs
bucket of the AA-682 S1 design was never built: no `aa-booking-<env>-ops-docs-<account>` bucket, no task-role grant,
no `OPS_DOCS_BUCKET` on the Booking task definition. Every operations document upload / download on Dev answered 503
`ops_storage_unavailable`. This branch adds `accounts/aa365/booking_ops_docs.tf` and the env var in `booking.tf`.
The app side (AA-Booking `fix/aa-682-ops-docs-sse-s3`) changes the upload header to SSE-S3 and reports the storage
on `/booking/health/ready`.

## Decisions

- **SSE-S3, not a CMK.** The S252 design (D10) asked for a customer managed KMS key (~$1/month). A new paid
  resource needs its own approval, and the existing CMKs cannot be reused: the three CRM keys are fenced off by the
  workload boundary (`DenyCrmKeyUseAndPolicyEdits`, keyed on `App = crm`) and their key policies, and the CloudTrail
  key is for CloudTrail. So the bucket default is AES256 and a PutObject naming another algorithm is denied, as on the
  supply-media bucket.
- **The confidentiality the CMK gave is moved into the bucket policy.** With SSE-KMS, a principal that can
  `s3:GetObject` the bucket still cannot decrypt without key rights; with SSE-S3 it can. The CIS task role has
  `s3:GetObject` / `s3:PutObject` on `*` (modules/ecs) and the read-only / plan roles `s3:Get*` on `*`, so
  `DenyObjectAccessOutsideBookingTask` denies `s3:GetObject*`, `s3:PutObject*`, `s3:DeleteObject*`,
  `s3:RestoreObject`, `s3:ReplicateObject` on the objects to every principal whose `aws:PrincipalArn` is not the
  Booking task role. Bucket-level verbs are not in the list, so Terraform (plan refresh, apply) still manages the
  bucket. Staff downloads are presigned GETs signed by the Booking task role, so they pass.
- **Versioning on, noncurrent versions expire after 30 days** (design cost line "versioning"; DM-6.7 erasure bound).
  The app never overwrites a key (keys are `ops-docs/<kind>/<uuid>.<ext>`), so noncurrent versions appear only when
  a later removal / erasure job deletes an object; that delete is then final within 30 days. Incomplete multipart
  uploads after 1 day, expired delete markers cleaned.
- **No current-object expiration.** Retention is per row (root data standards DM-7 rows of S252): money documents
  under the accounting exception (proposed 10 years), vouchers / confirmations with the trip case, removed files
  outside the exception 30 days after removal. Those windows are still "proposed" (DM-7.5) and a lifecycle rule
  cannot see a row's kind or status, so the deletion belongs to a Booking job in a later slice.
- **Identity grant `PutObject` / `GetObject` on `ops-docs/*` only** (no List, no Delete), the same shape as the
  supply-media grant. No KMS grant (no key).
- **Env `OPS_DOCS_BUCKET` only.** `OPS_DOCS_REGION` defaults to `us-west-1` in the app (same as
  `SUPPLY_MEDIA_REGION`, which is not set either).

## Changed (vs. the design)

- SSE-S3 instead of SSE-KMS with a CMK (above). The design's cost line drops from ≈ $1.05 to < $0.05 a month.
- The bucket policy denies object access to every other principal (the design relied on the CMK for that).

## Tradeoffs

- **CMK vs bucket-policy deny.** A CMK adds a second, independent control (key policy) and CloudTrail data on every
  decrypt; the deny statement is one control, but it covers the same principals today and costs nothing. A later
  move to SSE-KMS is a CMK + key policy + bucket default + `ServerSideEncryption="aws:kms"` in AA-Booking
  `app/ops/files.py` in the same release (the deny on other algorithms would otherwise refuse the old header).
- **Deny for admins too.** An admin cannot read or delete an object by hand; an erasure by hand or an incident needs
  a reviewed edit of the deny statement (visible in CloudTrail and the PR). Accepted for PII: the normal paths
  (upload, download, a future removal job) all run as the Booking task role.

## Should know

- **Plan (read-only, `-lock=false`, 29/10/2026): 9 to add, 0 to change, 1 to destroy.** The adds: bucket, public
  access block, ownership controls, SSE configuration, versioning, lifecycle, bucket policy, the task-role inline
  policy (and the policy document data source). The "1 to destroy" is `aws_ecs_task_definition.booking` **must be
  replaced** (an env change on a task definition always registers a new revision and deregisters the Terraform
  template revision, here `:70`); the service runs a deploy-registered revision (`:82` at plan time) and ignores
  `task_definition`, so nothing running stops. The env diff is the single `OPS_DOCS_BUCKET` entry (the rest is the
  usual empty-list normalisation).
- Running revision `:82` env names = the template's 12 names (no hand-set flag), so the next Booking deploy, which
  copies the family's latest revision, carries exactly the template + `OPS_DOCS_BUCKET` (lesson S250 on task-def
  drift checked).
- **Ship order.** (1) Infra PR merge + apply (bucket, grant, new task-def revision; the running task is untouched).
  (2) AA-Booking PR `fix/aa-682-ops-docs-sse-s3` merge + Deploy Dev: the new image sends `AES256` and the deploy
  copies the new revision with `OPS_DOCS_BUCKET`. Before step 2 the old image sends `aws:kms`, which the bucket policy
  denies; that only matters if some other Booking deploy lands between the two steps (uploads then answer 503 "could
  not be stored" until step 2).
- Cost: < $0.05/month on Dev (S3 Standard, a few MB, a handful of requests). No KMS.
