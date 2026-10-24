# AA-835 — supply photo purge grant: Infra part (lane C, S250 review round)

The app side is AA-CIS-App `feat/aa-835-supply-content-consumer` (S6): the `supply_media_purge` job removes the CIS
WebP copies of a Booking supply photo once Booking withdraws its usage rights or removes it (root DM-7 row
"supply_media": a supply_media row and its CIS photo objects go when Booking removes the media). The independent
review of S6 found the copies stayed public on the img. CDN after a withdrawal.

## Decisions

- **`s3:DeleteObject` on `<bronze>/photos/supply/*` only** (`DeleteSupplyPhotoCopies` on the CIS task role). The
  role had no S3 delete before; the CON photo sync (`photos/<country slug>/`) never deletes and keeps put / get only.
  The bucket is the bronze bucket because the app's `photo_bucket()` falls back to `BRONZE_BUCKET` (no
  `PHOTO_BUCKET` env is set).
- **`cloudfront:CreateInvalidation` on the photos distribution only** (`InvalidateSupplyPhotoCopies`), and the
  worker env `PHOTO_CDN_DISTRIBUTION_ID` (the id parsed from the ARN). The CDN keeps an object up to a year (min TTL
  one day), so deleting the S3 object alone does not take it off the edges. The job invalidates one wildcard path
  per media (`/supply/<type>/<media_id>-*`, both sizes and every `?v=`).
- **Gated with the CDN**: `photos_cdn_distribution_arn` is `""` when `local.photos_cdn_on` is 0, which drops the
  statement and the env; the job then reports `invalidation: not_configured`.
- Worker task definition only: the job runs on the worker (`JOB_WORKER_IN_API=false`).

## Changed

- Nothing beyond the review finding. The task policy's `Statement` became `concat([...], [...])` to add the
  conditional statement; the existing statements are unchanged.

## Tradeoffs

- One invalidation per withdrawn photo. CloudFront gives 1,000 invalidation paths a month free, then $0.005 a path;
  a wildcard path counts as one. Dev withdrawals are a handful a month: $0.

## Should know

- Apply order: this grant can be applied any time; the job only exists once the S6 app PR is deployed. Until it is
  applied, a purge job fails at once (NonRetryable, "s3:DeleteObject denied"), visible on the Jobs page and on
  `/admin/supply-content/status` (`photo_purge_jobs_7d`).
- The worker picks up `PHOTO_CDN_DISTRIBUTION_ID` with the next CIS Deploy Dev (the deploy copies the latest task
  definition revision).
