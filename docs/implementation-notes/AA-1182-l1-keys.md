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
- **Two applies, no `[0]` on an empty list (review S297).** Provider hashicorp/aws 6.69.1 does not mark
  `master_user_secret` unknown when `manage_master_user_password` flips, so in the plan that turns management on the
  attribute is still the empty list of the state and any `master_user_secret[0]` fails the plan ("Invalid index";
  reproduced offline with the pinned provider, Terraform 1.15.5, a crafted state and `-refresh=false`, before and
  after the fix). The rotation resource is `count = length(aws_db_instance.main.master_user_secret)` (0 in apply 1, 1
  from apply 2 on), the output is `one(...[*].secret_arn)` (null in apply 1) and the migrator task role list is
  `compact([...])`, so a null ARN never reaches the policy JSON.
- **The migrator task role can read the managed secret from apply 1 on.** Statement `ReadManagedMasterSecret`:
  `secretsmanager:GetSecretValue` on `arn:...:secret:rds!db-*` with `StringEquals
  secretsmanager:ResourceTag/aws:rds:primaryDBInstanceArn = module.rds.db_arn` (RDS tags its managed secret with the
  instance ARN). Known at plan time, so DB Migrate can read the new password the moment RDS sets it; there is no window
  in which the legacy password is dead and the task role cannot read the managed one. The exact ARN also joins
  `ReadDsnSecrets` from apply 2 on (belt and braces, in case the tag condition does not match).
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
  otherwise moves AWSCURRENT back to the version current before the add (VersionId recorded first) and only then deletes the Cognito secret it just added (the apps keep the old one); if that move is not safe it keeps the Cognito secret and prints the manual steps (review S297: a put that landed before a failed read-back must not leave a dead value stored). `retire` deletes the old secret only when the
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
| `tools/identity/tripplanner_web_secret.py` (+ README) | `--rotate-session` for key ceremony group 5 (the tool kept the session key on every run) |
| tests | `tools/terraform/tests/test_aa1182_rds_managed_master.py`, `db/tests/test_aa1182_master_switch_check.py`, `tools/identity/tests/test_client_secret_rotate.py`, runner and registry tests, three workflow wiring tests |
| `CONTEXT.md`, `README.md`, `db/README.md`, `db/scripts/README.md`, two workflow header comments | the managed master |

## Tradeoffs

- **Discovery through DescribeDBInstances** adds one IAM grant and one API call per master run; a name passed in the
  task definition would need the task definition shape (and `migrator-task.sh check-base`) to change.
- **Two applies instead of one**: the alternative, a `-replace` or a `depends_on` trick, cannot make the provider mark
  `master_user_secret` unknown. A count gate plus a plan-time grant costs one extra targeted apply and keeps DB Migrate
  working in between.
- **`rds!db-*` + tag condition vs the exact ARN only**: the pattern alone would let the task read any RDS-managed
  secret in the account; the tag condition narrows it to this instance. The exact ARN is kept too, so a tag mismatch
  only costs the window between the two applies, not the managed path.
- **Fallback on a failed managed login** costs one extra failed login in the connection log before the legacy try; it
  only happens while both secrets exist.
- **The rotation interval is a Terraform variable, not an admin setting.** Infra has no admin-editable settings
  mechanism; the rotation schedule of an AWS secret belongs to the infrastructure. Follow-up noted in the PR body.

## Should know

- **Order:** merge (the runner falls back to the legacy secret until apply 1) → job tables idle → local MFA targeted
  apply 1 → apply 2 right after → DB Migrate run-script `aa1182_master_switch_check.py` → rotation schedule check →
  delete the GitHub secret `TF_VAR_DB_PASSWORD` and (after `legacy_master=refused`) the old Secrets Manager secret.
  Exact commands, prechecks and the record rows: root `docs/ops/runbooks/key-ceremony.md`, section "Before the day:
  switch the master to RDS management".
- **Apply 1** (from `accounts/aa365`, MFA credential pattern of the steering file):
  `-target=module.rds.aws_db_instance.main -target=aws_iam_role_policy.db_migrate_task`. Expected plan:
  `aws_db_instance.main` updated in place (`manage_master_user_password` → true, nothing else),
  `aws_iam_role_policy.db_migrate_task` updated in place (new statements `ReadManagedMasterSecret` and
  `DescribeMasterInstance`, the old DSN secret ARN replaced by its pattern). Plan: 0 to add, 2 to change, 0 to destroy.
  The rotation is not in this plan (count 0). Any replace, any other attribute on the instance, or the parameter group
  in the plan: stop and read (lessons: a targeted plan can pull in `aws_db_parameter_group.main`).
- **Apply 2** (same command with `-target=module.rds.aws_secretsmanager_secret_rotation.master
  -target=aws_iam_role_policy.db_migrate_task`): `aws_secretsmanager_secret_rotation.master[0]` created
  (`automatically_after_days = 180`), the task role policy updated in place (the exact `rds!db-...` ARN added to
  `ReadDsnSecrets`). Plan: 1 to add, 1 to change, 0 to destroy. Between the two applies the RDS default schedule
  (7 days) is active; nothing breaks if apply 2 waits, but run it the same hour.
- **No DB Migrate run may be in flight during apply 1** (the runner reads the master once per run; a run that started
  before the switch may have read the legacy password already).
- **Restore drills:** a PITR copy keeps the master password of its restore time; if the managed secret rotated since,
  reset the copy's master password before connecting to it.

## Rollback / recovery

- **No app outage is possible from the switch:** no app logs in as the master (CIS api/worker use `cis_app`, Booking
  `booking`, CRM `crm_app`, TripPlanner its own login). Only DB Migrate master modes (roles/ files, `set-password`,
  `run-script`) and the restore drill scripts use it.
- **There is deliberately no revert to a hand-kept password.** Turning management off needs
  `--no-manage-master-user-password` with a new password value on a command line, against the no-print rule, and would
  bring back a CI copy of the master. Recovery goes forward instead.
- **DB Migrate cannot log in as the master after apply 1:** (1) `aws rds describe-db-instances
  --db-instance-identifier aa-cis-dev-db --query DBInstances[0].MasterUserSecret` must show `SecretStatus` `active`
  (not `creating`/`impaired`); (2) `aws iam get-role-policy --role-name aa-cis-dev-db-migrate-task-role --policy-name
  aa-cis-dev-db-migrate-task` must list `ReadManagedMasterSecret` and `DescribeMasterInstance`; if not, re-run the
  targeted apply of `aws_iam_role_policy.db_migrate_task`; (3) if the secret is `impaired` or its value does not log in,
  `aws rds modify-db-instance --db-instance-identifier aa-cis-dev-db --rotate-master-user-password --apply-immediately`
  makes RDS set and store a fresh password (no value on the command line).
- **Break-glass access:** the MFA admin (`aa365-admin`) can read the managed secret like any other secret.
- **The legacy secret `aa-cis/dev/rds` is deleted only after `aa1182_master_switch_check.py` prints
  `legacy_master=refused`**, and with a recovery window (7 days), never `--force-delete-without-recovery`.
- **Restore drills:** a PITR copy keeps the master password of its restore time; if the managed secret rotated since,
  reset the copy's master password before connecting to it.
