# S244 chore: Terraform S3 native state locking (`use_lockfile`)

Follow-up of the S243 chore B (see `S243-infra-pr1.md`): the plan role got `PutObject`/`DeleteObject`
on `dev/terraform.tfstate.tflock` first, so this PR can switch the backend without a 403.

## Decisions

- `accounts/aa365` backend gets `use_lockfile = true` **next to** `dynamodb_table`. With both set,
  Terraform takes both locks, so a local run on an old Terraform (DynamoDB only) and a CI run on the
  new one still exclude each other during the transition.
- CI Terraform `1.7.5` → `1.15.5` in `terraform-plan.yml` and `terraform-apply.yml` (`use_lockfile`
  needs >= 1.10). 1.15.5 is the version used locally for the MFA applies, so CI and local now match.
- `required_version` for `accounts/aa365` raised to `>= 1.10.0` so an older binary fails fast
  instead of silently ignoring the lockfile.
- `acc1-bedrock` / `acc3-bedrock` are unchanged (local-only roots, no lock table, single operator).

## Changed

- `accounts/aa365/versions.tf`, both Terraform workflows, `docs/ci-role-split.md` (lockfile line).

## Tradeoffs

- Keeping `dynamodb_table` for now costs nothing (on-demand table, a few requests per run) and keeps
  the rollback a one-line revert. Removing it is a later PR (also the table and the `StateLock` /
  `DynamoDBStateLock` grants) after CI plan + apply have run green with the lockfile.

## Should know

- Local working directories must re-init once: `terraform init -reconfigure` (backend config changed).
- Apply role `aa-cis-infra-tf-apply` has `AmazonS3FullAccess`, so it can write the lockfile already.
