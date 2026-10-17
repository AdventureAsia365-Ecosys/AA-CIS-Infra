# S241 D-07 / D-08 — ECS Exec session logging and RDS connection logging

No Linear issue: session decisions D-07 (ECS Exec audit trail) and D-08 (RDS connection log).

## Changed
- `modules/ecs/main.tf`
  - New log group `/ecs/aa-cis-dev/exec-sessions`, 30-day retention, no CMK.
  - `aws_ecs_cluster.main` gains `configuration.execute_command_configuration` with
    `logging = "OVERRIDE"` to that group, `cloud_watch_encryption_enabled = false`.
  - New `aws_iam_role_policy.ecs_task_exec_logging` on `aa-cis-dev-ecs-task-role` (CIS api and
    worker share it): `logs:DescribeLogGroups` on `*`, `logs:CreateLogStream`,
    `logs:DescribeLogStreams`, `logs:PutLogEvents` on `<exec group arn>:*`.
- `modules/ecs/outputs.tf`: output `exec_session_log_group_arn`.
- `accounts/aa365/booking.tf`: the same two statements added to the Booking task role policy.
- `modules/rds/main.tf`: `log_connections = 1`, `log_disconnections = 1` in `aa-cis-dev-pg15`.

## Decisions
- **OVERRIDE, not DEFAULT.** The cluster has no exec configuration today, which means DEFAULT:
  the SSM agent already writes each session into the task's awslogs group. Checked live
  (17/10/2026): `/ecs/aa-cis-dev` holds 5,055 `ecs-execute-command-*` streams (576 in the last
  7 days, ~80/day) mixed with app logs at 14-day retention. Booking's task role has no logs grant,
  so Booking sessions are most likely not recorded. OVERRIDE puts every session of the cluster
  (CIS api, CIS worker, Booking) into one group with its own retention.
- **No KMS key.** No log group in this stack uses a CMK (live: `kmsKeyId` = None on the ECS and RDS
  groups). CloudWatch Logs encrypts at rest with its own key regardless;
  `cloud_watch_encryption_enabled` only means "the group has a CMK", so it is false. Adding a CMK
  costs $1/month plus key policy work for no gain on Dev.
- **DescribeLogGroups on `*`.** It is a list call with no log group ARN to scope to; the AWS ECS
  Exec guide grants it on `*`. It returns names and metadata only.
- **Separate CIS policy** instead of editing `ecs_task_policy`: that policy already has
  `logs:CreateLogStream/PutLogEvents` on `*` (but not DescribeLogGroups). The new policy keeps the
  exec path working if the broad grant is narrowed later.
- **Boundary**: `aa-workload-boundary` allows everything except IAM writes and account/org
  actions, so the logs grants pass. Both task roles already carry it, so the apply role's
  `DenyRolePolicyWritesWithoutWorkloadBoundary` does not block the PutRolePolicy.
- **RDS parameters are immediate.** Read live (`describe-engine-default-parameters`, postgres15):
  both are `ApplyType dynamic`, `Source engine-default`. So `apply_method = "immediate"` (provider
  default) is valid, needs no reboot, and does not hit the AA-832 permanent diff (that only happens
  for parameters whose value RDS stores as `system`). The instance already exports `postgresql`
  logs to CloudWatch, so the new lines land in `/aws/rds/instance/aa-cis-dev-db/postgresql`
  (14 days).
- The parameter group `description` is not touched: changing it forces a replacement.

## Tradeoffs
- Exec transcripts contain whatever the session printed. Today's sessions are short (sample of
  25: 325–3,000 bytes each), but an ad-hoc script that prints a DSN or secret would now be kept 30
  days instead of 14, and Booking sessions are recorded for the first time. Both containers carry
  secret env vars (Booking `DATABASE_URL` with the DB password; the CIS secrets block). Rule: never
  run `env`/`printenv` in an exec session; scripts print counts and ids only, never DSNs or secret
  values (also in the log group comment in `modules/ecs/main.tf`). No current `.tmp-session`
  script was found printing a DSN or password. The presigned S3 URL in `sh -c` is not echoed into
  the transcript (it is in CloudTrail `ExecuteCommand` anyway and expires after 300 s).
  Not done here, left as follow-ups: the same one-line rule in `skill/aa-cis-schema/references/ecs-exec.md`
  (root repo) and in the global CLAUDE.md exec block (Nghiệp edits that file); a CloudWatch Logs
  data protection policy on the group (scan cost < $0.01/month, but its managed identifiers do not
  cover PostgreSQL DSNs); any role with account-wide `logs:GetLogEvents`/`FilterLogEvents` can now
  read this group, so scope such reads later.
- `log_connections` also logs RDS's own `rdsadmin` monitoring connections. Accepted: small volume
  (see cost).

## Cost (monthly, us-west-1: ingest $0.50/GB, storage $0.03/GB-month)
- Exec logs: ~80 sessions/day × ~1 KB ≈ 2.5 MB/month → < $0.01. They already cost this in
  `/ecs/aa-cis-dev`; this only moves them.
- RDS connection log: ~3 lines × ~200 bytes per connection. Pools (CIS api ≤7 tasks, worker,
  Booking) reconnect rarely; TripPlanner Lambdas and ECS exec scripts open short connections;
  `rdsadmin` health checks are the bulk. Estimate 5k–20k connections/day ≈ 0.1–0.4 GB/month →
  $0.05–0.20.
- Total: well under $1/month. No new AWS service.

## Should know
- In-place only: `UpdateCluster` (no task restart), `PutRolePolicy` × 2, `ModifyDBParameterGroup`
  (immediate, instance stays `in-sync`), `CreateLogGroup`. Nothing is replaced.
- `aws_ecs_cluster.main` has `depends_on = [aws_iam_role_policy.ecs_task_exec_logging]`, so the
  CIS grant always lands before `UpdateCluster`. The Booking grant lives in the root
  (`booking.tf`) and reads the module's log group ARN, so the cluster cannot depend on it without a
  cycle: apply in two steps (below).

## Apply (local, targeted, two steps)
Never `-target=module.ecs` or `-target=module.rds` as a whole: module.rds pulls in
`aws_db_instance.main` (`var.apply_immediately`, pending AA-824 class/param-group work, could
reboot the shared DB) and module.ecs re-registers the api/worker task definitions on `:latest`.
`aws_iam_role_policy.booking_ecs_task` depends (via `aws_iam_role.booking_ecs_task`) on
`time_sleep.wait_for_iam_propagation` → `aws_iam_role_policy.tf_apply`, and module.rds has
`depends_on = [module.vpc]`; any drift there would join a targeted apply, hence the exact counts.
`TF_VAR_db_password` must be set (variables are validated even under `-target`); these resources
do not read it.

Final target list:
```
-target=module.ecs.aws_cloudwatch_log_group.exec_sessions
-target=module.ecs.aws_iam_role_policy.ecs_task_exec_logging
-target=aws_iam_role_policy.booking_ecs_task
-target=module.ecs.aws_ecs_cluster.main
-target=module.rds.aws_db_parameter_group.main
```
- Plan with all five first. Required: `Plan: 2 to add, 3 to change, 0 to destroy` (create the log
  group and the CIS policy; update the cluster, the Booking policy and the param group in place).
  Checked 17/10/2026 against live state from this branch: exactly that, and the param group diff is
  only the two new parameters. Abort if `tf_apply`, `time_sleep`, `workload_boundary`,
  `aws_db_instance`, any VPC resource, any task definition/service or any secret appears.
- Step 1: the first three targets. Required: `2 to add, 1 to change, 0 to destroy` (checked
  17/10/2026). Apply, then wait ~15 s for IAM propagation.
- Step 2: `module.ecs.aws_ecs_cluster.main` + `module.rds.aws_db_parameter_group.main`. Required:
  `0 to add, 2 to change, 0 to destroy`.
- Do not start exec sessions or scheduled exec scripts between the steps.

## Verify after apply
- ECS Exec: one session each on `aa-cis-dev-api`, `aa-cis-dev-worker` and Booking, with the
  canonical S3 pattern and a trivial script (`python3 -c 'print(1)'`). Each must return output, and
  after it ends a new `ecs-execute-command-*` stream must appear in `/ecs/aa-cis-dev/exec-sessions`.
  The logging target is read when a session starts, so no redeploy is expected; if a session leaves
  no stream, check the task role grant before anything else.
- RDS: `log_connections`/`log_disconnections` only apply to new backends. Long-lived pools (CIS
  api/worker, Booking) log nothing until they reconnect, which is not a failure. Verify with a fresh
  connection: one asyncpg connect/close via the canonical ECS exec pattern (or a TripPlanner Lambda
  call), then look in `/aws/rds/instance/aa-cis-dev-db/postgresql` for `connection authorized:` and
  `disconnection: session time` lines for that user. `describe-db-instances`
  `DBParameterGroups[0].ParameterApplyStatus` must still be `in-sync`. Do not reboot the DB or
  redeploy services to get pool lines.
- Old exec streams in `/ecs/aa-cis-dev` expire with its 14-day retention; nothing to clean up.

## Rollback
A code change, not a block deletion (the provider may leave OVERRIDE live after the
`configuration` block is removed, with no Terraform owner): set `logging = "DEFAULT"` and drop
`log_configuration` in `aws_ecs_cluster.main`, re-apply the same targets (plan must show only the
cluster changing), then verify with one exec session again. The RDS parameters revert by removing
the two `parameter` blocks (dynamic, no reboot).
