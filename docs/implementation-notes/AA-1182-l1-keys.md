# AA-1182 — RDS-managed master password and the client secret rotation helper (S297 part, lane l1-keys)

Scope of this PR: issue scope item 4 (RDS-managed master password with a 180-day schedule, DB Migrate on the managed
secret, the CI copy of the master password no longer read) and the tool fix item 5 needs before the key ceremony
(Cognito client secret rotation that keeps the value from the add response). The S296 part is `AA-1182.md`. The key
ceremony runbook and the secrets register rows are in the root repo (same lane).

## Decisions

- **`manage_master_user_password = true` on the existing instance, no replacement.** It is an in-place
  ModifyDBInstance; RDS applies it at once whatever `apply_immediately` says, with no reboot and no downtime (RDS
  User Guide, "Settings for DB instances": turning management on "occurs immediately. This change ignores the apply
  immediately setting"). RDS sets a new random master password at that moment, so the old one stops working. The
  `password` argument is gone (it conflicts with the managed setting); `ignore_changes = [password]` stays so the plan
  carries no password diff (the state still holds the pre-S93 value, dead since S93).
- **Rotation schedule: `aws_secretsmanager_secret_rotation.master`, 180 days, `rotate_immediately = false`.** RDS owns
  the managed secret and its rotation; Secrets Manager takes the schedule (no Lambda ARN). No immediate second
  rotation: enabling the management already set a fresh password. The interval is a module variable with a 1..365
  validation (default 180, tech lead S295).
- **KMS: the default `aws/secretsmanager` key.** A customer managed key costs about 1 USD a month and needs key policy
  work; the default key is what every other secret uses.
- **How DB Migrate finds the managed secret: DescribeDBInstances, not a name.** The managed secret's name
  (`rds!db-<id>`) is unknown until the apply, and the migrator task definition carries no plain environment (the
  `check-base` shape of `.github/scripts/migrator-task.sh`), so the runner asks the instance
  (`MasterUserSecret.SecretArn`). New constants `MASTER_DB_INSTANCE` / `MASTER_MANAGED_ID` mirror `db/owners.yaml`
  `master_db_instance`. The managed secret holds `{username, password}` only, so host, port, database and query come
  from the task's own `DATABASE_URL` (db_migrator's DSN, which names `db.<env>.internal` like every DSN secret).
- **Compatible switchover: managed first, legacy DSN secret second.** Before the apply the instance has no managed
  secret (LookupError) and the runner falls back to `aa-cis/dev/rds`; after it the managed secret logs in and the
  legacy one is never read. A managed secret that is unusable or fails to log in also falls back (each step logged with
  class and SQLSTATE only). Deleting the legacy secret then needs no code change.
- **The legacy secret stays readable by ARN pattern, not by data source.** `module.secrets.data.aws_secretsmanager_secret.rds`
  and the output `rds_secret_arn` are removed; the migrator task role keeps `aa-cis/<env>/rds-??????` as a pattern, so
  the orchestrator can delete the secret after verifying without breaking any plan. The clean-up PR drops the pattern
  and the fallback code.
- **`TF_VAR_DB_PASSWORD` is no longer read.** The variable `db_password` is removed from the root and the module, and
  the three Terraform workflows stop passing it, so the GitHub secret can be deleted right after the merge. The three
  workflow wiring tests that used it as the anchor of the aa365 env blocks now anchor on the aa365-only variables.
- **Client secret rotation: `tools/identity/client_secret_rotate.py`.** Lesson S296: the new value exists only in the
  `AddUserPoolClientSecret` response; Describe returns none once a client has rotated secrets. The tool writes the add
  response straight into the client's Secrets Manager key, checks the stored copy by SHA-256, retries once and
  otherwise deletes the secret it just added (the apps keep the old one). `retire` deletes the old secret only when the
  kept id is the newest and the Secrets Manager secret changed after it was created. The refill tools
  (`staff_web_secret.py`, `crm_dev_identity.py`, `workforce_bootstrap.py`) now use the stored copy when Describe
  returns no secret instead of failing (crm `web-secret --rotate-session` keeps working after a rotation).
- **`booking` and `aa_app_user` join DB Migrate `set-password`.** The key ceremony (group 1) rotates every app
  login; S296 left these two out because their DSNs never sat in state. Both DSN secrets are isolation-probe login
  secrets the migrator task already reads, so no IAM change; the runner allowlist, `owners.yaml` `password_roles` and
  the workflow role regex move together (registry test).
- **`db/scripts/aa1182_master_switch_check.py`:** read-only evidence after the apply: managed secret status, and that
  the legacy DSN no longer logs in (issue Done-when 1: "a login with the old password fails").

## Changed

| File | Change |
|---|---|
| `modules/rds/main.tf`, `variables.tf`, `outputs.tf` | managed master password, rotation resource, `master_password_rotation_days`, outputs `db_arn`, `master_user_secret_arn`; `db_password` removed |
| `accounts/aa365/main.tf`, `variables.tf`, `terraform.tfvars`, `.gitignore` | `db_password` removed (comments updated) |
| `accounts/aa365/db_migrator.tf` | task role reads the managed secret (+ legacy by pattern), new statement `DescribeMasterInstance` |
| `modules/secrets/main.tf`, `outputs.tf` | the `rds` data source and `rds_secret_arn` output removed |
| `.github/workflows/terraform-{plan,apply,drift}.yml` | no `TF_VAR_db_password` |
| `db/run_migration.py`, `db/owners.yaml` | managed-first master login, `managed_master_dsn`, `_get_secret` resolves `rds-managed:<instance>`; `booking` + `aa_app_user` in `password_roles` |
| `.github/workflows/db-migrate.yml` | set-password role regex and texts |
| `db/scripts/aa1182_master_switch_check.py`, `s249_drill_*.py` | new check script; drill scripts read the managed secret first |
| `tools/identity/client_secret_rotate.py` (+ README) | new rotation tool |
| `tools/identity/{staff_web_secret,crm_dev_identity,workforce_bootstrap}.py` | stored copy when Describe returns none |
| tests | `tools/terraform/tests/test_aa1182_rds_managed_master.py`, `db/tests/test_aa1182_master_switch_check.py`, `tools/identity/tests/test_client_secret_rotate.py`, runner and registry tests, three workflow wiring tests |
| `CONTEXT.md`, `README.md`, `db/README.md`, `db/scripts/README.md`, two workflow header comments | the managed master |

## Tradeoffs

- **Discovery through DescribeDBInstances** adds one IAM grant and one API call per master run; a name passed in the
  task definition would need the task definition shape (and `migrator-task.sh check-base`) to change.
- **Fallback on a failed managed login** costs one extra failed login in the connection log before the legacy try; it
  only happens while both secrets exist.
- **The rotation interval is a Terraform variable, not an admin setting.** Infra has no admin-editable settings
  mechanism; the rotation schedule of an AWS secret belongs to the infrastructure. Follow-up noted in the PR body.

## Should know

- **Order:** merge (the runner falls back to the legacy secret until the apply) → job tables idle → local MFA targeted
  apply (`module.rds.aws_db_instance.main`, `module.rds.aws_secretsmanager_secret_rotation.master`,
  `aws_iam_role_policy.db_migrate_task`) → DB Migrate run-script `aa1182_master_switch_check.py` → delete the GitHub
  secret and the old Secrets Manager secret.
- **Expected plan:** `aws_db_instance.main` updated in place (`manage_master_user_password` to true, `master_user_secret`
  known after apply, nothing else), `aws_secretsmanager_secret_rotation.master` created, `aws_iam_role_policy.db_migrate_task`
  updated in place. Plan: 1 to add, 2 to change, 0 to destroy. Any replace, any other attribute on the instance, or
  the parameter group in the plan: stop and read (lessons: a targeted plan can pull in `aws_db_parameter_group.main`).
- **A seconds-long window** inside the apply: the instance switches before the task role policy names the managed
  secret (the policy depends on the instance output). No DB Migrate run may be in flight during the apply.
- **Restore drills:** a PITR copy keeps the master password of its restore time; if the managed secret rotated since,
  reset the copy's master password before connecting to it.
