# AA-852 — X1 step S11: per-app security groups, migrator task definition, secret placeholders (expand)

Plan: `AA-Ecosys/docs/audits/2026-10-17-S241-x1/x1-plan.md` §5 S11; ADR `AA-Ecosys/docs/adr/0004b-per-app-security-groups.md`.
One PR, then the manual Terraform Apply workflow. No service, task or Lambda changes its security group
here (S13), nothing runs the migrator family yet (S12), and `sg-app` stays in every data-store list (S14).

## Decisions
- **Six groups in `accounts/aa365/app_security_groups.tf`** (`aa-cis-dev-sg-{cis-api,cis-worker,booking-api,tp-lambda,db-migrate,ops-lambda}`).
  Ingress only on cis-api / booking-api: tcp 8000 (`local.cis_port`, `local.bk_port`) from the ALB group. Egress `0.0.0.0/0` on all.
  Tags: cis-api, cis-worker, ops-lambda use `local.common_tags` (App = cis; dfs-balance is a CIS Lambda and already uses
  common_tags), booking-api `local.bk_tags`, tp-lambda `local.tp_tags`, db-migrate `local.shared_tags` (it migrates every owner).
- **Data-store lists live in root locals** (`rds_ingress_sg_ids`, `redis_ingress_sg_ids`, `efs_ingress_sg_ids`) and are passed
  to new optional module variables `modules/vpc` `rds_ingress_sg_ids`, `modules/elasticache` / `modules/efs` `ingress_sg_ids`.
  Default `null` → the old single source (`aws_security_group.app.id` / `var.sg_app_id`), so any other caller is unchanged.
  The variables feed the existing inline `ingress {}` blocks (authoritative); no `aws_vpc_security_group_ingress_rule`.
- **No cycle:** the new groups read `module.vpc.vpc_id` / `sg_alb_id`; the data-store groups read the new ids through the module
  variables. Terraform graphs module variables and outputs as separate nodes, and no new group references a data-store group.
  `terraform validate` and `plan` confirm.
- **Inline rule update is authorize-only.** Checked the provider source (hashicorp/aws 5.100.0, the locked version,
  `internal/service/ec2/vpc_security_group.go` `updateSecurityGroupRules`): old and new rules are expanded to one rule per
  source before the set difference, revocations go first but only for sources that left the set. So adding five sources to a
  rule that already admits `sg-app` revokes nothing (no connection gap), and S14 revokes only `sg-app`. The plan text still
  prints the whole rule as `-`/`+` (Terraform core compares the unexpanded objects); that is display only.
  (A per-group `dynamic "ingress"` variant was tried first and dropped: same API calls, more code.)
- **Migrator task definition `aa-cis-dev-db-migrate`** (`accounts/aa365/db_migrator.tf`): container `migrate`, 256 CPU / 512 MB,
  awslogs group `/ecs/aa-cis-dev` (new `modules/ecs` output `log_group_name`), stream prefix `migrate` → streams
  `migrate/migrate/<task id>` as S12 expects. No port, no health check, no ECS Exec.
- **Image = the `:latest` placeholder, like the api and worker task definitions.** run-task cannot override the image, and the CIS
  tag is immutable `dev-<sha>` per deploy (AA-869). Today's DB Migrate "runs the image the api runs" by using the api service's
  current task definition. The equivalent for S12: per run, read the image of the api service's task definition, register a
  revision of `aa-cis-dev-db-migrate` copied from the family's latest with only `containerDefinitions[0].image` swapped, run it by
  ARN (the AA-Booking deploy pattern). The apply role already has `ecs:RegisterTaskDefinition` (AmazonECS_FullAccess) and
  `iam:PassRole` on `aa-*-dev-*` (IAMRoleManageStack). Workflow-registered revisions are not Terraform drift (Terraform tracks its own revision ARN).
- **Default command exits 1** (`raise SystemExit(...)`): every run passes its command in `containerOverrides`; a run without one
  must not start the api server with the master DSN.
- **Execution role `aa-cis-dev-db-migrate-execution-role`**: ECR auth + pull on the CIS repo only (new output `ecr_repository_arn`),
  `logs:CreateLogStream/PutLogEvents` on `log-stream:migrate/*` of the CIS group only (new output `log_group_arn`),
  `GetSecretValue` on `aa-cis/dev/rds` only (exact ARN; `aa-cis/dev/db-migrator` is added in S22 with the `secrets` switch, as
  the plan's S11 item 3 says). `AmazonECSTaskExecutionRolePolicy` not attached (Booking pattern).
- **Task role `aa-cis-dev-db-migrate-task-role`**: `GetSecretValue` on `aa-cis/dev/rds`, `aa-cis/dev/rds-app-user` (not in
  Terraform: ARN pattern `…:secret:aa-cis/dev/rds-app-user-??????`), `aa-cis/dev/rds-cis-app`, `aa-cis/dev/db-migrator`,
  `booking/dev/database-url`, `tripplanner/dev/database-url`; `s3:PutObject` on `aa-cis-bronze-005097885195/db-schema-dump/*` only.
  No Bedrock, no ssmmessages, no logs (container logs go through the execution role).
- **Both roles**: names inside `aa-*-dev-*`, `permissions_boundary = aws_iam_policy.workload_boundary.arn` (required by
  `DenyCreateRoleWithoutWorkloadBoundary`), own assume-role document (ecs-tasks, `aws:SourceAccount` = this account),
  `depends_on = [time_sleep.wait_for_iam_propagation]` like the Booking roles.
- **`cis_app = 90`** added to `rds_role_connection_limits` → one new alarm `aa-cis-dev-rds-role-connections-cis_app`. No sessions
  until S18; `treat_missing_data = notBreaching` keeps it OK.
- **Placeholder merge gate:** the DSN env var name lives in `local.db_migrate_dsn_env_name`, and a `lifecycle.precondition` on
  `aws_ecs_task_definition.db_migrate` fails `terraform plan` while it still starts with `__NGHIEP`. So CI plan / Terraform Apply
  cannot register the task definition with the placeholder name (review finding, S242).
- **Empty-list guard:** the three new module variables reject `[]` (`validation`), since an empty list would render an inline
  ingress rule with no source; `null` keeps the old single source.

## Changed (vs. the plan / task text)
- **Secret placeholders follow `booking_db` (secret container, no version), not `tripplanner_db` (REPLACE_ME version +
  `ignore_changes = [secret_string]`).** Reason: every `aws_secretsmanager_secret_version` is read (GetSecretValue) on refresh, so
  `cicd_split.tf` says it must be added to `local.tf_plan_secret_arns`, which is a bootstrap change (human MFA apply), and the
  read-only plan role would then read the `cis_app` and `db_migrator` DSNs. With no version resource, Terraform never holds or
  reads the DSN, which is also what XD2 / SEC-2 want (Nghiệp writes the value in the Console). Reading a secret with no value
  fails the same way as a missing secret, which the probe already handles today. If the tripplanner pattern is preferred anyway:
  add `aws_secretsmanager_secret_version` resources and extend `tf_plan_secret_arns` in a bootstrap apply first.
- **No S3 grant for the probe.** `db/isolation_probe.py` returns its results as `PROBE …` lines in the task log
  (`db-isolation-probe.yml` builds probe.json from the log); it never writes S3. The only in-task S3 write is
  `db/schema_dump.py:366` `put_object` to `DUMP_KEY = db-schema-dump/<run id>/schema.json`. `db-schema-dump/latest.json` is copied
  by the workflow under the CI role.
- **Implementation notes file**: this repo keeps one file per X1 step (`AA-852-s2-…`, `-s3-…`, `-s7-…`), so S11 is
  `AA-852-s11-sg-expand.md` instead of a section in `AA-852.md` (S1).

## Tradeoffs
- `:latest` placeholder + per-run registration (S12) vs. letting Terraform own the image: Terraform cannot know the deployed
  `dev-<sha>`, and a static tag would drift from the api image after the next deploy.
- Exact secret ARNs instead of `aa-cis/dev/*` on the migrator roles: more lines, but the migrator cannot read OpenAI, JWT,
  admin or third-party secrets.
- The module variables take the full list (including `sg-app`) rather than "extra" ids, so S14 is just removing one element.

## Should know
- ⚠️ **Hand edit before merge (Nghiệp, VSCode):** `accounts/aa365/db_migrator.tf`, task definition `secrets`: replace
  `__NGHIEP_EDIT_DB_ENV_NAME__` with the DSN env var name that `db/run_migration.py` reads (passed to `connect()` in `main()`,
  line ~1184; same name as the first `secrets` entry of the api task definition in `modules/ecs/main.tf`). The value lives in
  `local.db_migrate_dsn_env_name` at the top of the file. Underscore env var: not written by the agent. Until it is edited,
  `terraform plan` fails on the precondition (intended merge gate); after the edit, `grep -rn "__NGHIEP_EDIT" accounts/` must
  return nothing and plan must show 14 to add, 3 to change, 0 to destroy.
- `terraform plan` (local, aa365-admin, `-lock=false`, 18/10/2026): **14 to add, 3 to change, 0 to destroy**. In place: the
  RDS (`sg-055c18ce0bd00b5e3`), Redis (`sg-0f5a810c884fd15bc`) and EFS (`sg-085fa83fd09be7fe7`) groups' inline ingress only.
  No replacement; no ECS service, task definition (api/worker/booking), Lambda, RDS, ElastiCache or EFS change.
- Terraform Apply has no job-idle gate; S11 needs none (standing rules: the migrator task def is unused, and the SG change is
  authorize-only).
- Verify after apply (plan §S11): RDS SG lists 6 sources, Redis and EFS 3; all apps still on `sg-app`.
- Cost: two secrets ≈ $0.80/month + the `cis_app` connections alarm $0.10/month (acc2 is past the 10 free alarms) ≈ $0.90/month
  for S11. Separately, `cis_app` (LOGIN, limit 90, created by rl-001) is discovered by the CIS sampler, which adds 2 AA/RDS metrics
  and takes acc2 from 10 to 12 custom metrics (~$0.60/month); caused by rl-001, recorded in the observability_ecosys.tf cost block.
- **Out of S11, before S20/S22:** the CIS task role grants `secretsmanager:GetSecretValue` on `*` (`modules/ecs/main.tf`), so it
  will be able to read `aa-cis/dev/db-migrator` once that secret has a value (S20). Narrow the CIS task role's secret access during
  the X1 runtime switch (S18/S19), before the migrator DSN is written.
- **Root-repo plan text drift (x1-plan.md S11 items 3/4, S12, S17/S20):** amended in the root PR, not in this repo.
- `terraform fmt -recursive` also reformats `accounts/acc1-bedrock/main.tf`, `accounts/acc3-bedrock/batch.tf` and
  `modules/monitoring/main.tf` with Terraform 1.15.5 (pre-existing drift, unrelated); those were left out of this PR.
