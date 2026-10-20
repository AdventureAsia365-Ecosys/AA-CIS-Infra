# AA-846 (S245) part B: TripPlanner zip tag drift, exact Terraform pin, lockfile-only backend

One of three AA-846 branches in S245. Each branch keeps its own notes file (`-guard`, `-drift`,
`-iam`) so parallel PRs do not conflict on one notes file (lessons log, S242).

## Decisions

- **Zip tag drift fix: `override_provider { default_tags { tags = {} } }`** on
  `aws_s3_object.tripplanner_browse_zip` and `aws_s3_object.tripplanner_assembly_zip`.
  - Root cause: AA-TripPlanner-Web `deploy-lambdas.yml` uploads both zips with `aws s3 cp`. That
    replaces the S3 object, and a replaced object has no object tags. The provider `default_tags`
    (Project/Environment/ManagedBy/Account) then put `tags_all` +4 on every plan, and each full-root
    apply re-tagged both objects until the next TripPlanner deploy wiped them again.
  - `override_provider` is a per-resource block of `aws_s3_object` in provider 6.69.1 (checked with
    `terraform providers schema -json`). An empty override makes `tags_all` `{}`, which is exactly
    what the deploy leaves, so plan and reality agree in both orders (deploy-then-plan and
    apply-then-deploy).
  - Rejected: `lifecycle.ignore_changes = [tags_all]` (the scout report rates it unreliable for
    computed tag maps, and it hides intent); adding `--tagging` to the TripPlanner deploy (a
    cross-repo change that keeps the two repos coupled on a tag list); object tags on these two
    objects have no use (cost allocation uses resource tags on the bucket, which keeps its tags).
- **Exact pin `required_version = "1.15.5"`** only in `accounts/aa365`, matching
  `terraform_version` in both CI workflows and the local binary. acc1-bedrock / acc3-bedrock stay
  `>= 1.7.0, < 2.0.0`: they are applied by a human only, from any recent local binary, and have no
  CI version to match.
- **Backend: `dynamodb_table` removed, `use_lockfile = true` kept.** The S244 change took both
  locks; CI plan and apply have run green with the lockfile since #218.

## Changed

- `accounts/aa365/tripplanner.tf`: `override_provider` block on both zip objects.
- `accounts/aa365/versions.tf`: exact pin; `dynamodb_table` removed from `backend "s3"`.
- `CONTEXT.md`, section State backend: lockfile-only locking, version pins (the old line still said
  Terraform `>= 1.7.0` and AWS `~> 5.40`).

## Tradeoffs

- The first apply after merge records `override_provider` in state: the plan shows
  `~ update in-place` on both zips with only `+ override_provider { + default_tags {} }`; no
  `tags_all`, `etag` or `source` change. The provider's update path uploads object content only when
  a content attribute (`etag`, `source`, `content*`, `metadata`, ...) changes, and `etag`/`source`
  are in `ignore_changes`, so this apply should not overwrite the deployed zip with the placeholder.
  It is still worth a `head-object` ETag check before and after that first apply (see Should know).
- The DynamoDB lock table is left in place on purpose (its deletion is a data-delete step for the
  orchestrator, after this PR is merged and no branch still references it). Its IAM grants are
  removed in the `-iam` branch (bootstrap objects, local MFA apply).

## Should know

- Local verification (S245, read-only, `-lock=false`, MFA-exported aa365-admin credentials, this
  branch): full-root `terraform plan` = `0 to add, 2 to change, 0 to destroy`; the two changes are
  the zips, each only `+ override_provider { + default_tags {} }`, with no `tags_all` line. Every
  `aws_secretsmanager_secret_version`, `random_password` and `aws_db_instance` in the plan is
  `no-op`. After one apply, the full-root plan should be "No changes".
- Removing `dynamodb_table` changes the backend configuration. CI runs a fresh `terraform init`, so
  nothing to do there; a local checkout needs `terraform init -reconfigure` once.
- A branch that still has `dynamodb_table` keeps taking both locks; it still conflicts with this
  config on the lockfile, so mixed configs during the rollout cannot both hold the state.
- Suggested ETag check around the first apply (orchestrator, single line each):
  `aws s3api head-object --bucket <tripplanner artifacts bucket> --key browse.zip --query ETag --profile aa365-admin --region us-west-1`
  (same for `assembly.zip`); the ETag must be the same before and after.
