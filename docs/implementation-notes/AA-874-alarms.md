# AA-874 — tenant-pool alarms (Infra slice S3)

AA-874 also asks for an alarm when the tenant-pool flag read fails. Tenant routes in AA-CIS-App read a
per-route flag from Redis and fail closed (S241 D-12): a failed read keeps the route on the tenant pool (RLS);
only an explicit `"false"` moves it to the admin pool (BYPASSRLS). Before this PR no metric filter or alarm
existed for any of it, although an app comment promised one for `aa817_tenant_pool_unavailable`.
The Redis encryption part of AA-874 is a separate PR (notes: `AA-874.md`). This one is independent of it and
can merge and apply at any time, waves included.

## Decisions

- **Five filters + alarms** in `accounts/aa365/tenant_pool_alarms.tf`, same shape as `log_write_failed`
  (`observability.tf`): log group `module.ecs.log_group_name` (`/ecs/aa-cis-dev`, api + worker), namespace
  `aa-cis/ops`, Sum > 0 over 300 s, 1 period, `treat_missing_data = notBreaching`, `alarm_actions` and
  `ok_actions` = `aws_sns_topic.alerts` (e-mail on ALARM and again on OK, D-20).

  | Alarm | Filter pattern | Means |
  |---|---|---|
  | `aa-cis-dev-tenant-flag-read-failed` | `"aa817_tenant_flag_read_failed"` | Redis error / timeout / no client on a flag read |
  | `aa-cis-dev-tenant-flag-unrecognized` | `"aa817_tenant_flag_unrecognized"` | a flag value neither ON nor OFF (bad hand rollback) |
  | `aa-cis-dev-tenant-pool-unavailable` | `"aa817_tenant_pool_unavailable"` | no tenant connection (503 on fail-closed routes) |
  | `aa-cis-dev-tenant-guc-not-applied` | `"aa817_tenant_guc_not_applied"` | `app.tenant_id` did not take on the tenant connection (503) |
  | `aa-cis-dev-tenant-route-admin-pool` | `{ ($.used_tenant_pool IS FALSE) && ($.event != "publish_log_listed") }` | a tenant route ran on the admin pool (rolled back), minus the known pin |

- **The 4th alarm is a JSON pattern.** The api logs JSON (AA-871, `shared/log_config.py`); a Logs Insights
  query on 24/10 confirmed `used_tenant_pool` is a JSON boolean (`"used_tenant_pool": true`). Every line that
  carries the field comes from a route behind a tenant-pool flag (`acquire_scoped_conn`), so `false` always
  means a rolled-back route.
- **Known deliberate rollbacks are excluded, not tolerated** (review round). CloudWatch e-mails only on a state
  change, so an alarm held in ALARM by a route rolled back on purpose would stay silent on a second,
  unintended rollback. `local.tenant_pool_known_rollback_events` lists the `event` names of routes rolled back
  on purpose; the pattern is built from it (empty list → plain `{ $.used_tenant_pool IS FALSE }`). Today it
  holds `publish_log_listed` (the S241 pin, below), with its removal condition next to it. A deliberate
  rollback that is not listed holds the alarm in ALARM: the safe side.
- **`aa817_tenant_guc_not_applied` added** (review round, +$0.10): the fail-closed 503 when the tenant id did
  not take on the connection, the most direct RLS-context failure.
- **Runbook:** `local.runbook_suffix.incident` (no dedicated tenant-pool playbook exists yet), as the
  docs-gen source guard requires.
- Alarm names start with `aa-cis-dev-tenant-`, so `describe-alarms --alarm-name-prefix aa-cis-dev-tenant`
  lists exactly these five.

## Changed

- New `accounts/aa365/tenant_pool_alarms.tf` (5 `aws_cloudwatch_log_metric_filter.tenant_pool[...]`,
  5 `aws_cloudwatch_metric_alarm.tenant_pool[...]`). Nothing else.

## Tradeoffs

- One alarm per event instead of one combined metric: each e-mail says which state it is, at $0.10 each.
- No alarm on `aa817_tenant_context_unavailable` (a tenant route with no valid tenant id, or no tenant pool at
  all): it is a request-level 503 driven by the caller's token, so a malformed token from any client would page;
  a missing tenant pool also shows in `/health/ready`. Add it if it turns out to matter.
- Excluding the pinned route by event name instead of switching the flag back ON here: whether the S241 pin is
  still needed is not written down, and flipping a Redis flag is a live write outside this PR. The exclusion
  keeps the alarm useful for every other route either way.

## Should know

### Expected plan

`Plan: 10 to add, 0 to change, 0 to destroy` (5 filters, 5 alarms). Checked with a local read-only targeted
plan (`-lock=false`) on 24/10. Patterns checked with `aws logs test-metric-filter` against synthetic JSON
lines: the admin-pool pattern matches a `"used_tenant_pool": false` line of any other event and neither
`publish_log_listed` with `false`, nor any `true` line, nor a plain-text line; each quoted term matches only
its own event.

### The S241 pin on `/v1/publish-log` (excluded from the admin-pool alarm)

Logs Insights, last 7 days (24/10): 1,645 lines with `used_tenant_pool: true` and **60 with `false`**:
- `publish_log_listed` (GET `/v1/publish-log`): 30 lines from 22/10 06:31 to 24/10 02:44 UTC, still going.
  The api task definition has no `TENANT_POOL_FORCE_ADMIN_FLAGS`, so Redis holds
  `aa544:publish_log_list_pool = "false"`. The S241 session log says this flag was pinned to `"false"` before
  the D-12 merge (#792); it was never switched back, although the app `CONTEXT.md` says all routes are ON
  since S240.
- A burst on 22/10 10:42–10:56 (`aa859_*` reads: reviews, slate, angle gate, marketplace, trip
  reallocation) and 07:56–08:08 (brand identity, T2 version detail): looks like a temporary rollback / test
  window, not current.

Logs Insights, last 48 h (24/10, after the review): the only `used_tenant_pool = false` event is
`publish_log_listed` (8 lines, last 02:44 UTC), so with the exclusion the alarm starts in OK.

Before the pin, the route's flag was OFF by default (AA-815); D-12 made a missing key mean ON, and the pin
kept the route where it was. It was never flipped afterwards, so the app `CONTEXT.md` line "All ON on Dev
since S240" is wrong for this route (the AA-874 CIS PR records the pin there). The route is written for both
pools (`acquire_scoped_conn(fail_closed=True)`; the AA-986 `annotate_by_request` takes either connection).
To end the pin: `SET aa544:publish_log_list_pool true` (or `DEL`), confirm `publish_log_listed` with
`used_tenant_pool=true` in Logs Insights, then remove `publish_log_listed` from
`local.tenant_pool_known_rollback_events` and the CONTEXT.md note in one follow-up. Until then the AA-874 S4
key copy carries the `"false"` value over to the new Redis on purpose.

### Live check after apply

`aws logs create-log-stream --log-group-name /ecs/aa-cis-dev --log-stream-name aa874-alarm-test --profile aa365-admin --region us-west-1`,
then `aws logs put-log-events` with one JSON message containing `"event": "aa817_tenant_flag_read_failed"`
and one with `"used_tenant_pool": false`. Within ~5–6 min
`aws cloudwatch describe-alarms --alarm-name-prefix aa-cis-dev-tenant --profile aa365-admin --region us-west-1`
shows ALARM and the e-mail arrives; after a period with no matching data, OK and the OK e-mail.
`describe-alarm-history` keeps both transitions as evidence. Delete the test stream afterwards.

### Cost

5 alarms × $0.10 = **+$0.50/month**. Metric filters are free; the custom metrics exist only while lines
match.
