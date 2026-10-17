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
  days instead of 14. Same exposure as before, longer retention; rule stays "scripts never print
  secrets".
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
- Verify after apply: run one ECS Exec session on CIS api and one on Booking, then check that a
  stream `ecs-execute-command-<id>` appears in `/ecs/aa-cis-dev/exec-sessions`; and look for
  `connection authorized:` / `disconnection:` lines in the RDS postgresql log group.
- Running tasks: the logging target is read when a session starts, so no redeploy is expected. If
  the first session after apply does not show up in the new group, force a new deployment of that
  service.
- Old exec streams in `/ecs/aa-cis-dev` expire with its 14-day retention; nothing to clean up.
