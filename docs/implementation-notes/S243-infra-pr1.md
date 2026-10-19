# S243 Infra PR-1: ops-probe secret by ARN only, staff reconcile path, stale imports, plan-role lockfile grant

Refs AA-816, AA-878. Bundles three lane steps that touch the same files (S243 critic, wave 1 B2):

- chore A1: drop the dead `import {}` blocks, and grant the plan role the S3 lockfile.
- AA-816 I-A: add the daily staff directory reconcile to the ops-probe default run.
- AA-878 I1: the ops-probe Lambda reads the admin secret only by ARN.

## Decisions

- **One PR for all three.** `handler.py` and `dfs_balance.tf` are shared by AA-816 I-A and AA-878 I1.
  `cicd_split.tf` `aws_iam_role_policy.tf_plan` is shared by chore A1 (new StateLockfile
  statement) and AA-878 I1 (`tf_plan_secret_arns` shrinks). Parallel PRs would go DIRTY, and each
  would need its own MFA sitting. Bundled, one local MFA targeted apply covers both `tf_plan`
  edits.
- **Fail closed, no raise.** With no `secret_id` in the event, a non-string `secret_id`, a failed
  read or an empty value, the handler:
  - logs `ops_probe admin_secret_unavailable`;
  - returns `{"statusCode": 500, "body": "{\"error\": \"admin_secret_unavailable\"}"}`;
  - makes no HTTP call.

  It does not raise, which matches the handler's existing "never raise" rule: a raise makes the
  async Lambda retry, and Scheduler has its own retry policy. A missing secret is a config fault,
  and retrying will not fix it. A transient Secrets Manager error loses that day's run, but the
  next daily run picks it up.
- **The env fallback is gone entirely.** Leaving it in place would keep the plaintext in the Lambda
  config and in Terraform state, which is what AA-878 removes. A test checks that a leftover
  `ADMIN_SECRET` env is ignored.
- **Reconcile goes in `_PATHS`, the 06:15 UTC default run.** It does not get its own schedule.
  `_ALLOWED_PATHS` is built from `_PATHS`, so an on-demand `{"paths": [...]}` invoke works too. The
  CIS route `POST /admin/job-runner/staff-reconcile/schedule` is on CIS main (af1bd84a,
  `api/routers/admin_job_runner.py:323`). It is idempotent per UTC day and already listed in
  `staff_authz.py` as called by this Lambda.
- **Tests use stdlib unittest, outside `lambda_src/dfs_balance_check/`.** This follows the
  rds_snapshot_expiry pattern: `sys.dont_write_bytecode` and `python -B`, so `archive_file` never
  zips a `__pycache__` (S240 lesson). A new workflow, `ops-probe-test.yml`, runs them on PRs and
  pushes that touch the handler.
- **Scope of the stale imports.** I removed all 5 `import {}` blocks the chore plan listed: 3 for
  branding through `for_each`, the 3 in observability_ecosys.tf, and the 1 in
  bedrock_satellite_assume.tf. The S243 plan checked live state (serial 193) and found every
  address already in state. I also rewrote the comments that described the imports as pending.

## Changed

- `accounts/aa365/lambda_src/dfs_balance_check/handler.py`:
  - added `/admin/job-runner/staff-reconcile/schedule` (AA-816 C7) to `_PATHS`;
  - deleted `_ENV_SECRET`;
  - `_resolve_secret` now returns the value or None, with no source tuple;
  - the handler fails closed;
  - updated the docstring.
- `accounts/aa365/lambda_src/dfs_balance_check_tests/test_handler.py` (new): 14 tests. They cover
  the default set including reconcile, the on-demand reconcile and retention paths, refusal of
  unknown paths, the header set from Secrets Manager, and no HTTP call when `secret_id` is missing,
  the read errors or the value is empty, even with an env `ADMIN_SECRET`. They also cover
  per-path failure isolation and a 502 when every path is down.
- `.github/workflows/ops-probe-test.yml` (new).
- `accounts/aa365/dfs_balance.tf`:
  - removed `data "aws_secretsmanager_secret_version" "dfs_balance_admin"`;
  - removed `ADMIN_SECRET` from the Lambda env, keeping `API_BASE_URL`;
  - updated the header comments (AA-816 path, AA-878).
  - Unchanged: the ReadAdminSecret IAM statement and both schedule inputs (`secret_id`).
- `accounts/aa365/cicd_split.tf`, in `aws_iam_role_policy.tf_plan`:
  - new statement `StateLockfile`: `s3:PutObject` and `s3:DeleteObject` on
    `arn:aws:s3:::aa-cis-tfstate-<acct>/dev/terraform.tfstate.tflock`;
  - `local.tf_plan_secret_arns` loses `var.secret_admin_arn` (6 ARNs down to 5);
  - comments updated.
- `accounts/aa365/identity.tf`: removed the `id_branding_existing_workforce` map and its
  `import {}` block, and wrote the header comment in the past tense. It keeps the
  "delete runs before create / pre-validate on EXTERNAL" warning.
- `accounts/aa365/observability_ecosys.tf`: removed 3 `import {}` blocks (the TripPlanner Lambda
  log groups browse and assembly, and `cis_apigw_execution`). Comments updated.
- `accounts/aa365/bedrock_satellite_assume.tf`: removed the `import {}` block for
  `aws_iam_role_policy.ecs_assume_bedrock_invoker`. Header comment updated.
- `docs/ci-role-split.md`: the plan-role row (lockfile grant, admin secret no longer readable) and
  the residual-risk paragraph.
- `CONTEXT.md`: the dfs_balance.tf line now covers the AA-816 path and the AA-878 ARN-only
  secret, plus the tests and workflow.

Not changed, though the lane plans list them:

- `use_lockfile` and the CI Terraform version bump (chore B) go in a later PR, after this grant is
  applied.
- The TripPlanner and Mapbox ARNs in `tf_plan_secret_arns` (AA-878 I2) stay; I2 drops them with
  their `removed` blocks.

## Tradeoffs

- **A 500 return instead of a raise:** the Lambda Errors metric does not move on a missing secret.
  No alarm watches this Lambda's Errors today, so nothing is lost. The signal is the
  `admin_secret_unavailable` log line, plus the CIS bells that stop firing.
- **Reconcile in the 06:15 UTC set** (13:15 ICT) enqueues one short `staff_directory_reconcile`
  job a day. That job briefly counts as queued or running for the Deploy Dev guard. A separate
  off-hours schedule would cost a new resource and CI scheduler grants. The job is report-only and
  short, so it stays in the shared run, as the AA-816 plan chose.
- **The lockfile grant before `use_lockfile`:** for a while the plan role can write one S3 key it
  does not use yet. That key is only the lock object, not the state. The grant has to come first,
  or every CI plan after chore B fails with a 403.

## Should know

- **Bootstrap apply order (critic finding 4).** `aws_iam_role_policy.tf_plan` belongs to the
  bootstrap role `aa-cis-infra-tf-plan`. The CI apply role is denied writes on it
  (DenyRoleWritesOutsideStack). After merge, do the local MFA targeted apply of
  `aws_iam_role_policy.tf_plan` **before** dispatching Terraform Apply. Otherwise the CI apply
  errors on PutRolePolicy, after it may already have updated the Lambda.
- **Expected CI Terraform Plan on this PR:** `Plan: 0 to add, 2 to change, 0 to destroy`, no
  `to import`, nothing else.
  - `~ aws_iam_role_policy.tf_plan` (in place): the policy JSON gains StateLockfile and drops the
    admin-secret ARN from ReadStackSecretValues.
  - `~ aws_lambda_function.dfs_balance_check` (in place): `source_code_hash` changes, and
    `environment.variables` shows as a sensitive change (ADMIN_SECRET removed).
  - Removing the `dfs_balance_admin` data source and the 5 import blocks produces no plan line.
  - Any other line is unexpected drift: stop and read it before merging.
- **Other open Infra branches cut before this merge** still contain the `dfs_balance_admin` data
  source. Once the `tf_plan` shrink is applied, their CI plan fails with AccessDenied on refresh.
  Rebase them on main after this PR merges.
- The reconcile invoke enqueues a `shared.job`. Run that evidence call right after a deploy, never
  just before a CIS merge.
- Admin secret ARN (not a secret, from terraform.tfvars):
  `arn:aws:secretsmanager:us-west-1:005097885195:secret:aa-cis/dev/admin-secret-gudNmP`.
- Local checks:
  - `terraform fmt -check -recursive accounts/aa365` passes.
  - `terraform validate` passes on a temp copy with `init -backend=false` and TF 1.15.5. CI uses
    1.7.5, and this PR adds no new syntax.
  - All 14 unittest cases pass.
  - flake8 is clean.
  - `fmt -check` on the whole `accounts/` tree flags acc1-bedrock/main.tf and acc3-bedrock/batch.tf.
    That was already there before this PR, and those files are untouched.
