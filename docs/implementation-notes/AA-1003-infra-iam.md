# AA-1003 R2 — Infra IAM: logs:FilterLogEvents on the CIS log group

## Decisions

- One statement `FilterOwnLogGroup` added to `modules/ecs/main.tf` `aws_iam_role_policy.ecs_task_infra_status_readonly`
  (role `aa-cis-<env>-ecs-task-role`, shared by the api and the worker task definitions): `logs:FilterLogEvents` on
  the app's own log group `/ecs/aa-cis-<env>` only. The ARN comes from `aws_cloudwatch_log_group.ecs.arn`, so no
  account ID is written; both the bare ARN and the `:*` form are listed (IAM evaluates log-group actions against
  either form).
- Not narrowed to the `migrate/migrate/*` streams: `FilterLogEvents` is authorized on the log group, not the stream;
  the CIS reader passes `logStreamNamePrefix=migrate/migrate/` itself.

## Should know

- Expected plan: exactly one in-place update, `module.ecs.aws_iam_role_policy.ecs_task_infra_status_readonly`.
- Cost: $0 (IAM; FilterLogEvents has no per-call charge, CloudWatch Logs bills scanned data only for Logs Insights).
- Until applied, the CIS KPI snapshot records `unavailable.nightly_probes = "not_permitted: ..."` and the OPS-12
  digest prints "Nightly probe results unavailable (not_permitted)" (AA-CIS-App `docs/implementation-notes/AA-1003.md`).
- The log group also holds the api and worker application logs; the role could already read nothing there. With this
  grant the CIS task role can search its own application logs too (same app, same data class).

# AA-1003 R4 part 2 — logs:DescribeLogStreams on the same log group

## Decisions

- `logs:DescribeLogStreams` added to the same `FilterOwnLogGroup` statement, same two resources (the action is
  authorized on the log group). The CIS reader (AA-CIS-App `services/reports/probes.py`, `read_streams_day`) lists the
  streams of `/ecs/aa-cis-<env>` ordered by LastEventTime back to the start of the ICT day, keeps the
  `migrate/migrate/*` ones and runs FilterLogEvents with `logStreamNames` over the whole day.
- Why: measured on Dev (30/10/2026, read-only) a FilterLogEvents with only the stream prefix took 18 s for 16 hours
  (it scans every api / worker stream), and GitHub runs the probe crons 5-9 hours late, so the narrow time slices of
  the S259 fix missed runs (read "missing"). Listing then searching by name: 3 list pages + 5 search pages, ~6 s.

## Should know

- Expected plan: exactly one in-place update, `module.ecs.aws_iam_role_policy.ecs_task_infra_status_readonly`.
- Cost: $0 (DescribeLogStreams and FilterLogEvents have no per-call charge).
- Apply before (or together with) the CIS PR; until applied the CIS reader falls back to the slice search and says so
  (`window.mode = slices`, why "not permitted").
- The stream names list the api / worker / migrator task IDs of the app's own group: same app, same data class.
