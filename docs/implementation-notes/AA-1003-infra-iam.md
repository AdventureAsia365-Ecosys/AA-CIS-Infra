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
