# AA-852 — X1 step S12: workflows on the migrator task definition; `set-password` and `run-script` modes

Plan: `AA-Ecosys/docs/audits/2026-10-17-S241-x1/x1-plan.md` §3 XD2/XD5, §5 S12 (S17, S19, S22 use the new
modes). Builds on S11 (`AA-852-s11-sg-expand.md`, applied: family `aa-cis-dev-db-migrate` rev 1, container
`migrate`, SG `aa-cis-dev-sg-db-migrate`, roles `aa-cis-dev-db-migrate-{execution,task}-role`).
One PR, workflows + runner + tests only. **No Terraform change, no hand edit, no new environment variable.**

## Decisions
- **One helper for the three workflows: `.github/scripts/migrator-task.sh`** (`prepare` / `deregister <arn>` /
  `render <image>`). `prepare` reads the api service (`describe-services`) → its task definition → the image
  of container `api`; reads the family's latest ACTIVE revision (`describe-task-definition aa-cis-dev-db-migrate`);
  registers a copy with only `containerDefinitions[0].image` replaced (jq `del` of the read-only fields, so
  roles, secrets, logs, cpu/memory, command, volumes stay byte-for-byte); re-reads the new revision and fails if
  family, roles, network mode, cpu/memory, compatibilities or the container's name/command/secrets/environment/
  logConfiguration differ from the base, or the image is not the api's. Network: subnets + `assignPublicIp`
  from the api service as before; security group looked up by name `aa-cis-dev-sg-db-migrate` **and** the
  subnet's VPC, exactly one or fail. Outputs `arn`, `network`, `api_task_definition`, `image` (none secret).
  `deregister` refuses any ARN outside `task-definition/aa-cis-dev-db-migrate:<n>`.
- **Register in its own step before the run step; deregister as the last-but-one step with
  `if: always() && steps.td.outputs.arn != ''`.** `prepare` writes `arn` to `$GITHUB_OUTPUT` right after
  register, before its own checks, so a failed check still deregisters. Presigned URLs stay inside the run step.
- **Base = the family's latest ACTIVE revision** (normally Terraform's). A revision left ACTIVE by a run whose
  deregister failed, or by a concurrent run (DB Migrate, dump and probe have separate concurrency groups), is an
  identical copy apart from the image, which is replaced anyway; the invariant check guards the rest.
- **No tags on workflow revisions**: `registeredBy` already names the CI role; avoids depending on
  `ecs:TagResource` and keeps `ManagedBy=terraform` off revisions Terraform does not manage.
- **Deregister, not delete.** INACTIVE revisions stay describable (the stopped task references its ARN, useful
  when reading a failed run). They cost nothing; `delete-task-definitions` can be added later if the console
  list bothers anyone.
- **Inputs fold into existing variable names** (task rule: no new env var names). DB Migrate job env
  `MIGRATION` = `inputs.migration` for check/apply, `inputs.role` for set-password, `inputs.script` for
  run-script (one expression); a step "Unused inputs" refuses the inputs a mode does not take (e.g. a role with
  check, `override_busy_jobs` with set-password). The run step builds the task's `MIGRATION_MODE` value
  (`set-password:<role>`, `run-script:db/scripts/<name>.py`) in lower-case shell locals. Workflow validation:
  role `^(cis_app|db_migrator)$`, script `^db/scripts/[a-z0-9_]+\.py$` + exists on main + shape check.
- **Runner parses and allowlists `MIGRATION_MODE` first** (`parse_mode`, `re.fullmatch` for the path): unknown
  value → exit 10 before any fetch or connection. Before S12 an unknown mode silently behaved like `check`.
- **`set-password`** (`run_set_password`): login must be `aa_cis_admin` (exit 8); role must exist and be LOGIN
  (exit 11); secret read in-task with boto3, region `us-west-1` hard-coded (no env read); DSN parsed exactly
  like asyncpg (`netloc.partition('@')`, `auth.partition(':')`, percent-decoded), refusing a second `@`, and
  `user`/`password`/`passfile` in the query (asyncpg would read them); DSN user must equal the role; password
  ≥ 32 printable ASCII characters (plan S17's "≥ 32", and printable ASCII is what SASLprep leaves unchanged on
  both PostgreSQL and asyncpg, so the locally computed verifier matches). Verifier: RFC 5802/7677 with
  `hashlib.pbkdf2_hmac`, 4096 iterations, `os.urandom(16)` salt, format
  `SCRAM-SHA-256$4096:<salt>$<StoredKey>:<ServerKey>`. Then `ALTER ROLE "<role>" PASSWORD '<verifier>'`
  (autocommit), test login with the DSN printing only `current_user` and `rolconnlimit` (exit 12 if it fails or
  runs as another user, role not marked), then `COMMENT ON ROLE "<role>" IS 'x1:password-set <UTC> by DB Migrate
  set-password (run <id>)'`. Every error text passes through `_redact` (DSN, decoded + encoded password,
  verifier); a botocore error logs only its class and error code.
- **Run id for the marker comes from `RUNNER_URL`'s path** (`db-migrate/<run id>/run_migration.py`, only the
  digits are used). Reading `GITHUB_RUN_ID` or passing it would be a new variable name; `"unknown"` if the path
  ever changes.
- **`run-script`** (`run_script`): `MIGRATION_FILE` must equal the mode's path (exit 10), sha256 of the fetched
  file must match (exit 2), shape check (AST: a top-level `async def main(conn)` with one argument; exit 10),
  login must be the master (exit 8), then the apply idle check (`job_tables_busy` + `wait_until_idle`, exit 7,
  `MIGRATION_IDLE_OVERRIDE` honoured and logged), then `exec` in a fresh namespace (`__name__ = "db_script"`, so
  `if __name__ == "__main__"` blocks do not run) and `await main(conn)` on the master connection with the
  standard session settings. Exception or non-zero return → exit 13 (55P03 gets the lock hint). Contract over
  subprocess: the script never touches the DSN variable and inherits lock/statement timeouts and
  `application_name = db-migrate`.
- **File transport mirrors migrations**: the workflow uploads it as `db-migrate/<run id>/payload` next to the
  runner, passes the presigned URL in `MIGRATION_URL` and its sha256 in `MIGRATION_SHA256`. set-password sends no
  file (`MIGRATION_URL` empty).
- **New exit codes** 10 (mode input refused), 11 (set-password refused before any change), 12 (password set,
  test login failed), 13 (run-script failed); 8 also covers set-password/run-script under a non-master login.
  DB Migrate prints one `::error::` per code.
- **Dispatches after success:** dump after `apply` and `run-script` (a script may change structure); probe after
  every mode but `check` (set-password flips the probe's `cis_app_password_set` key).
- **Registry:** `owners.yaml` `password_roles: {cis_app: aa-cis/dev/rds-cis-app, db_migrator: aa-cis/dev/db-migrator}`
  mirrored by `run_migration.PASSWORD_ROLES`; `test_owners_registry` checks runner, workflow regex, the cis_app
  runtime secret and `PASSWORD_MARKER` = the probe's.
- **`db/scripts/session_info.py`**: a read-only smoke script (session user, database, version, session settings)
  so the mode can be verified without a write.

## Changed (vs. the plan / task text)
- **No IAM change.** The three workflows run as `aa-cis-infra-tf-apply` (environment prod). It has
  `ecs:RegisterTaskDefinition`, `ecs:DeregisterTaskDefinition`, `ecs:DescribeTaskDefinition` and `ecs:RunTask`
  through `AmazonECS_FullAccess`, `iam:PassRole` on `arn:aws:iam::005097885195:role/aa-*-dev-*` through
  `IAMRoleManageStack` (`cicd_split.tf`; the migrator roles `aa-cis-dev-db-migrate-*` match, and its boundary
  denies role writes only outside that pattern), and `ec2:DescribeSubnets/DescribeSecurityGroups` through
  `AmazonVPCFullAccess`. So the PR is safe to merge on its own; no Terraform Apply ordering is needed.
  (Read from Terraform; the IAM API itself could not be queried from this agent session.)
- **Plan S12's hand edit is gone.** The plan expected one new env var for the role name (Nghiệp to write two
  lines by hand). The role and script travel in the value of the existing `MIGRATION_MODE` instead, and the
  workflow inputs fold into the existing job variable `MIGRATION`. Root plan text to amend (root PR, not here).
- **`JOB_WORKER_IN_API=false` dropped from the overrides** (DB Migrate, dump): the migrator container never
  starts the api, so the variable has no reader.
- **`migration` input is no longer `required`** (set-password/run-script do not take it); check/apply still fail
  in "Validate input" without it.
- **`migration-copy-guard.yml`** also triggers on `db/scripts/**`, `.github/scripts/**` and `db-schema-dump.yml`,
  and its lint job checks the shape of every `db/scripts/*.py` (README promises a PR-time check).
- **`.gitignore`** ignored every `scripts/` dir (since AA-40); `!/db/scripts/` and `!/.github/scripts/` re-include
  the two tracked dirs (no file under any `scripts/` was tracked before).
- One existing test changed: `test_run_migration.RunTaskTest.test_sha_mismatch` now sets `MIGRATION_MODE=apply`
  (the mode is validated before the fetch). `test_isolation_probe` expects the probe dispatch on `mode != 'check'`.

## Tradeoffs
- Per-run register/deregister vs. Terraform owning the image: Terraform cannot know the deployed `dev-<sha>`;
  per-run copies keep "the migrator runs the api's image" true across deploys (S11 decision).
- Shared shell script vs. inline steps: one place for the image/SG/invariant logic instead of three copies; the
  cost is one more file the workflows depend on (covered by the copy-guard path filter and unit tests of `render`
  and `deregister`).
- In-process `main(conn)` vs. subprocess for run-script: in-process gives the script the runner's connection and
  settings and no access to the DSN variable; a script that blocks the event loop stalls the task (15 min
  statement timeout, 30 min waiter) — acceptable for reviewed one-off scripts.
- 32-character printable-ASCII rule may refuse a password someone chose by hand; it is cheaper than debugging a
  SASLprep mismatch (password "set" but logins fail).

## Should know
- **Verify after merge (plan S12):** DB Migrate `mode=check`, `migration=cis/242_…` → exit 0 and the step
  summary shows `migrator task definition: …aa-cis-dev-db-migrate:<n>`; the revision is INACTIVE afterwards
  (`aws ecs describe-task-definition --task-definition aa-cis-dev-db-migrate:<n> --profile aa365-admin --region us-west-1 --query taskDefinition.status`);
  DB Schema Dump dispatch green **and** a new object under `s3://aa-cis-bronze-005097885195/db-schema-dump/<run id>/`;
  DB Isolation Probe dispatch green; `pg_stat_activity` shows `db-migrate` sessions from the migrator SG's ENI.
  Optional: `mode=run-script`, `script=db/scripts/session_info.py` → `SCRIPT session_user=aa_cis_admin`.
- **set-password is not runnable until S17** (`aa-cis/dev/rds-cis-app` has no value yet → exit 11 "unreadable …
  ResourceNotFoundException", nothing changed). That refusal is the expected result of a dry dispatch today.
- **S22 must give these modes a master connection.** set-password and run-script refuse any login but
  `aa_cis_admin` (exit 8). When S22 switches the task's `DATABASE_URL` secret to `aa-cis/dev/db-migrator`, the
  runner needs a master connection read in-task from `aa-cis/dev/rds` (the task role already reads it) for
  `roles/`, set-password and run-script, as plan S22 says.
- **Memory:** the migrator is 0.25 vCPU / 0.5 GB (api: 0.5 vCPU / 1 GB). Runner, dump and probe hold only catalog
  rows; if a dump ever stops with exit 137 (OOM), raise `memory` in `db_migrator.tf`.
- The task log stream moves from `api/api/<id>` to `migrate/migrate/<id>` (same log group `/ecs/aa-cis-dev`).
- Cost: none (task definition revisions are free; the one-off task is smaller than the api-sized one it replaces).
- `actionlint` 1.7.12 (+ shellcheck): only the four pre-existing SC2034 warnings (`for i in 1 2 3` waiter loops,
  `page` loop), identical on `origin/main`; `shellcheck` on `migrator-task.sh` clean.
- Tests: `python3 -m unittest discover -s db/tests` → 213 tests OK (29 new in `test_runner_modes.py`: RFC 7677
  vector + independent client SCRAM exchange, mode allowlist, DSN parsing, set-password paths with
  no-secret-in-output checks, run-script paths, workflow guards incl. "no new env names", `render`/`deregister`).
