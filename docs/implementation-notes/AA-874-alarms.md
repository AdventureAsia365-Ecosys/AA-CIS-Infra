# AA-874 — tenant-pool alarms (Infra slice S3)

AA-874 also asks for an alarm when the tenant-pool flag read fails. Tenant routes in AA-CIS-App read a
per-route flag from Redis and fail closed (S241 D-12): a failed read keeps the route on the tenant pool (RLS);
only an explicit `"false"` moves it to the admin pool (BYPASSRLS). Before this PR no metric filter or alarm
existed for any of it, although an app comment promised one for `aa817_tenant_pool_unavailable`.
The Redis encryption part of AA-874 is a separate PR (notes: `AA-874.md`). This one is independent of it and
can merge and apply at any time, waves included.

## Decisions

- **Four filters + alarms** in `accounts/aa365/tenant_pool_alarms.tf`, same shape as `log_write_failed`
  (`observability.tf`): log group `module.ecs.log_group_name` (`/ecs/aa-cis-dev`, api + worker), namespace
  `aa-cis/ops`, Sum > 0 over 300 s, 1 period, `treat_missing_data = notBreaching`, `alarm_actions` and
  `ok_actions` = `aws_sns_topic.alerts` (e-mail on ALARM and again on OK, D-20).

  | Alarm | Filter pattern | Means |
  |---|---|---|
  | `aa-cis-dev-tenant-flag-read-failed` | `"aa817_tenant_flag_read_failed"` | Redis error / timeout / no client on a flag read |
  | `aa-cis-dev-tenant-flag-unrecognized` | `"aa817_tenant_flag_unrecognized"` | a flag value neither ON nor OFF (bad hand rollback) |
  | `aa-cis-dev-tenant-pool-unavailable` | `"aa817_tenant_pool_unavailable"` | no tenant connection (503 on fail-closed routes) |
  | `aa-cis-dev-tenant-route-admin-pool` | `{ $.used_tenant_pool IS FALSE }` | a tenant route ran on the admin pool (rolled back) |

- **The 4th alarm is a JSON pattern.** The api logs JSON (AA-871, `shared/log_config.py`); a Logs Insights
  query on 24/10 confirmed `used_tenant_pool` is a JSON boolean (`"used_tenant_pool": true`). Every line that
  carries the field comes from a route behind a tenant-pool flag (`acquire_scoped_conn`), so `false` always
  means a rolled-back route. It stays in ALARM for as long as a route is rolled back on purpose: intended,
  that traffic is not filtered by RLS.
- **Runbook:** `local.runbook_suffix.incident` (no dedicated tenant-pool playbook exists yet), as the
  docs-gen source guard requires.
- Alarm names start with `aa-cis-dev-tenant-`, so `describe-alarms --alarm-name-prefix aa-cis-dev-tenant`
  lists exactly these four.

## Changed

- New `accounts/aa365/tenant_pool_alarms.tf` (4 `aws_cloudwatch_log_metric_filter.tenant_pool[...]`,
  4 `aws_cloudwatch_metric_alarm.tenant_pool[...]`). Nothing else.

## Tradeoffs

- One alarm per event instead of one combined metric: each e-mail says which state it is, at $0.10 each.
- No alarm on `aa817_tenant_context_unavailable` (a tenant route with no valid tenant id): out of the issue's
  scope; it is a request-level 503, not a pool or Redis state.

## Should know

### Expected plan

`Plan: 8 to add, 0 to change, 0 to destroy` (4 filters, 4 alarms). Checked with a local read-only targeted
plan (`-lock=false`) on 24/10. Both pattern kinds were checked with `aws logs test-metric-filter` against
synthetic JSON lines: the JSON pattern matches only the `"used_tenant_pool": false` line, the quoted term
matches only the read-failed line.

### The admin-pool alarm will fire on Dev as soon as it is applied

Logs Insights, last 7 days (24/10): 1,645 lines with `used_tenant_pool: true` and **60 with `false`**:
- `publish_log_listed` (GET `/v1/publish-log`): 30 lines from 22/10 06:31 to 24/10 02:44 UTC, still going.
  The api task definition has no `TENANT_POOL_FORCE_ADMIN_FLAGS`, so Redis holds
  `aa544:publish_log_list_pool = "false"`. The S241 session log says this flag was pinned to `"false"` before
  the D-12 merge (#792); it was never switched back, although the app `CONTEXT.md` says all routes are ON
  since S240.
- A burst on 22/10 10:42–10:56 (`aa859_*` reads: reviews, slate, angle gate, marketplace, trip
  reallocation) and 07:56–08:08 (brand identity, T2 version detail): looks like a temporary rollback / test
  window, not current.

So `aa-cis-dev-tenant-route-admin-pool` goes to ALARM on the first portal call to `/v1/publish-log` after the
apply. That is the alarm doing its job. Decide whether the S241 pin is still needed (why it was pinned is
not written down) and, if not, `SET aa544:publish_log_list_pool true` (or `DEL`); the alarm then returns to
OK by itself. If the pin must stay, expect this alarm to stay in ALARM, and say so in the session log.
The AA-874 S4 key copy carries the `"false"` value over to the new Redis on purpose.

### Live check after apply

`aws logs create-log-stream --log-group-name /ecs/aa-cis-dev --log-stream-name aa874-alarm-test --profile aa365-admin --region us-west-1`,
then `aws logs put-log-events` with one JSON message containing `"event": "aa817_tenant_flag_read_failed"`
and one with `"used_tenant_pool": false`. Within ~5–6 min
`aws cloudwatch describe-alarms --alarm-name-prefix aa-cis-dev-tenant --profile aa365-admin --region us-west-1`
shows ALARM and the e-mail arrives; after a period with no matching data, OK and the OK e-mail.
`describe-alarm-history` keeps both transitions as evidence. Delete the test stream afterwards.

### Cost

4 alarms × $0.10 = **+$0.40/month**. Metric filters are free; the custom metrics exist only while lines
match.
