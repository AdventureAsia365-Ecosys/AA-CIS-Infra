# AA-869 item 5 — manual RDS snapshot expiry (DM-7.5)

Approved by Nghiệp in S241: manual snapshots of `aa-cis-dev-db` expire after 30 days unless kept on
purpose. The DM-7.5 retention-table amendment is in the root repo (separate PR).

## Decisions
- One daily Lambda (`aa-cis-dev-rds-snapshot-expiry`, python3.12 arm64, stdlib + bundled boto3),
  scheduled by EventBridge Scheduler at 22:00 UTC (05:00 ICT) in the `module.eventbridge` group,
  the same mechanism and group as `dfs_balance.tf` (the CI role's scheduler grants are scoped to it).
  22:00 UTC is away from the RDS backup window (03:00-04:00 UTC), the 06:00 ACP ingest, the 06:15
  probes and the 20:30 retention enqueue.
- Rule, in order: not a candidate (type != manual, `rds:`/`awsbackup:` prefix, instance not in the
  allowlist, status != available) -> skip. `keep-` prefix, `aa:retain=keep`, malformed
  `aa:retain-until` (fail safe, reported), `aa:retain-until` >= today (UTC) -> keep. Then
  `aa:retain-until` < today -> expire; else age > 30 days -> expire; else keep.
- Orphan guard (review finding, fail safe): a snapshot that would expire is kept and reported when
  its source instance no longer exists or was re-created (snapshot `InstanceCreateTime` differs
  from the live instance's, or either is missing). Reason: `modules/rds` writes the final snapshot
  `aa-cis-dev-db-final` (manual type, instance tags only) when the instance is deleted; with the
  automated backups gone it can be the only copy, and age alone must not remove it. Chosen over
  renaming `final_snapshot_identifier` to `keep-...` because it also covers a ForceNew replacement
  (same identifier, new instance) and any other snapshot of a former incarnation, and it leaves the
  shared DB module untouched. Cost: one `DescribeDBInstances` per allowlisted instance per run,
  scoped to those `db:` ARNs. Any error other than "not found" fails the run (nothing deleted).
  Tag such a snapshot `aa:retain=keep` (or `aa:retain-until`) to keep it on purpose and stop the
  daily report. Verified on the live list: the 4 current snapshots match the live instance
  (`InstanceCreateTime` 2026-07-07T10:53:04.051Z), so none is flagged.
- "Older than 30 days" is strict: `now - SnapshotCreateTime > 30 days`. Exactly 30 days is kept.
- `aa:retain=keep` is compared case-insensitively with spaces stripped: a sloppy `Keep` keeps the
  snapshot (the safe direction). `aa:retain-until` is strict `YYYY-MM-DD`; anything else is
  "malformed" and therefore kept and reported.
- DRY_RUN: only the exact string `"false"` deletes. Terraform default `"true"` (variable
  `rds_snapshot_expiry_dry_run`, validated to `true`/`false`).
- Cap 3 per run, oldest first; the rest are `over_cap` and reported, picked up the next day.
- SNS (shared `aa-cis-dev-acp-alerts`) only when something is deleted / would be deleted / over
  cap / failed, a malformed tag is seen, or the orphan guard kept a snapshot. Subject <= 100 chars, body = one line per affected
  snapshot + how to keep one. No secrets in it.
- Outside the VPC (like the identity triggers): only RDS + SNS control-plane calls, so no NAT
  dependency and no security group.
- Tags tell the DB Migrate snapshot's lifetime: `aa:retain-until = today + 30 d`,
  `aa:purpose = "db-migrate pre-apply <migration>"`, `aa:source = db-migrate`. Existing tags
  (`purpose`, `migration`, `run`) are kept.

## Changed
- New `accounts/aa365/rds_snapshot_expiry.tf`: role + inline policy, log group (30 d, AA-872 app
  class), Lambda, event-invoke config, Errors alarm (alarm + OK actions), scheduler role, schedule.
- New `accounts/aa365/lambda_src/rds_snapshot_expiry/handler.py` and tests in
  `lambda_src/rds_snapshot_expiry_tests/` (outside the zipped dir), plus a path-filtered workflow
  `.github/workflows/rds-snapshot-expiry-test.yml` (stdlib unittest, mirrors identity-triggers-test).
- `.github/workflows/db-migrate.yml`: the pre-destructive snapshot step adds the three `aa:` tags;
  the comment and the step-summary line now say it expires automatically instead of "delete by
  hand". Nothing else in that flow changed.
- `db/README.md` (destructive directive) and `CONTEXT.md` (Layout entry, DB Migrate paragraph) now
  describe the automatic expiry of manual snapshots (review findings).

## Tradeoffs
- `aws_lambda_function_event_invoke_config.maximum_retry_attempts = 0`. Scheduler invokes
  asynchronously; with Lambda's default 2 retries a run that deleted some snapshots and then failed
  could delete up to 3 x cap in one day. A failed run raises (after the SNS report) so the Errors
  alarm fires; the next day retries naturally.
- IAM: `rds:DescribeDBInstances` scoped to the allowlisted `db:` ARNs (orphan guard);
  `rds:DescribeDBSnapshots` needs `*`; `ListTagsForResource` and `DeleteDBSnapshot` are scoped
  to `snapshot:*` of this account/region. Defence in depth: explicit Deny on `snapshot:rds:*`,
  `snapshot:awsbackup:*`, `snapshot:keep-*`, and on any snapshot tagged `aa:retain=keep`
  (`aws:ResourceTag`, ignore case). There is no IAM condition key for the source DB instance, so
  the instance allowlist is enforced in the handler only.
- `ListTagsForResource` is granted but normally unused: DescribeDBSnapshots returns `TagList`. It
  is only a fallback if a response lacks it.
- No reserved concurrency: the account's unreserved-concurrency floor makes `reserved = 1` risky to
  apply; one schedule + no retries already gives one run a day.
- Terraform validation: `retain_days >= 14` (db-migrate asked for >= 14 days on a destructive
  snapshot) and `1 <= max_deletes_per_run <= 10`.

## Should know
- CI apply: the apply role can create every resource (roles `aa-cis-dev-rds-snapshot-expiry-*`
  match `aa-*-dev-*` and carry the workload boundary; Lambda via AWSLambda_FullAccess; log group,
  alarm via CloudWatchFullAccess; schedule in the `aa-cis-dev-acp` group). No bootstrap change.
  CloudWatchFullAccess/AWSLambda_FullAccess contents were not re-read live (subagent hook blocks
  `aws iam`); dfs_balance.tf and the AA-872 log-group changes went through CI with the same grants.
- Dry run on the live list (17/10/2026, rule fed with `describe-db-snapshots` output):
  `aa-cis-dev-db-g0-audit-20260916` (31.2 d) would delete; `pre-rerun-20261001` (16.5 d),
  `pre-bhutan-rerun-20261005` (12.1 d), `db-migrate-tp-012-38847454819-1` (1.4 d) kept. The first
  real deletion of g0-audit happens only after `rds_snapshot_expiry_dry_run = "false"`. To keep it,
  rename is not possible in place: tag it `aa:retain=keep` (or copy to `keep-...`).
- While DRY_RUN is on, a "would delete" snapshot produces one e-mail per day until it is kept or
  the flag is flipped.
- Going live: set `rds_snapshot_expiry_dry_run = "false"` in `terraform.tfvars` (or the variable
  default) in a follow-up PR after a few dry-run mails look right.
- Cost: Lambda + schedule ~0 USD/month. Savings = storage of expired snapshots: RDS
  ChargedBackupUsage was 5.87 GB-month in Oct (to 16/10) = 0.56 USD; Sep 0.35 USD at
  0.095 USD/GB-month.
- Tests: `cd accounts/aa365 && python3 -B -m unittest discover -s lambda_src/rds_snapshot_expiry_tests -v`.
