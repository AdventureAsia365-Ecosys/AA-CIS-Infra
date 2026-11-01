# AA-1025 (lane alert-diet, S263) — CloudWatch alerting diet

Source of truth: root `docs/audits/2026-11-01-S263-alerting-cost/diet.md` (keep / remove / move table, written first).

## Decisions

- **Keep in CloudWatch only what an app cannot see**: no-healthy-task per service (CIS api added; Booking, CRM api,
  portal, web), RDS CPU / free storage / connections, NAT recover, Lambda Errors (4 Cognito triggers, TripPlanner
  browse / assembly / jobs, snapshot expiry), TripPlanner browse throttles, TripPlanner jobs not-run, SES bounce +
  complaint, RDS backup copy age (CRM-14), break-glass token, CRM KMS decrypt anomaly, and the admin session digest
  Lambda errors (added upstream by #581 the same day, kept without its OK mail). 25 alarms, 28 billed alarm-metric
  units (copy age has 2 metrics, the anomaly band 3).
- **RDS "one alarm"**: kept as three separate alarms (CPU, free storage, connections). A metric-math alarm is billed
  per metric inside it, so one combined alarm costs the same 0.30 USD and its e-mail says less.
- **In-app checks mail the alerts SNS topic** (`sns:Publish` on CIS, Booking, CRM task roles; env `ALERTS_TOPIC_ARN`
  added to the Booking and CRM task definitions; CIS already had it). Same recipients as the removed alarms, and a
  stuck worker cannot delay its own alert (the CIS SES `ops_alert_email` job runs on that worker).
- **Autoscaling**: the 4 target-tracking policies go, the 2 scalable targets stay (manual scale commands in
  `docs/ops/job-kinds.md` keep working).
- **Booking uptime probe**: `booking_health_url` default `""` removes the 5-minute schedule with its alarm (no reader
  left). The handler path stays.
- **Logs**: VPC flow logs REJECT-only + 30 days (flow log resources are replaced: `traffic_type` forces a new flow
  log; the log group is updated in place); WAF log 30 days + logging filter that keeps BLOCK / COUNT / CAPTCHA /
  CHALLENGE / EXCLUDED_AS_COUNT (module vars `log_retention_days`, `log_only_acted_on`, defaults keep the old
  behaviour for any other caller); `/aws/apigateway/welcome` imported with 30 days.
- **TripPlanner throttles**: the `for_each` alarm kept only browse; a `moved` block keeps the existing browse alarm
  (no destroy / create).

## Changed (vs. the brief)

- The identity break-glass token alarm and the CRM KMS anomaly alarm stay (security signals only AWS sees; the
  brief's keep list did not name them). The break-glass metric filter loses `default_value`, so its custom metric is
  billed only in hours with a token (it was a continuous 0).
- TripPlanner jobs not-run and the RDS backup copy-age alarms stay (compliance signals: DM-6.6 redaction schedule,
  CRM-14 backup promise).
- The ACP DLQ alarm is removed but the queue stays (no data resource destroyed).

## Tradeoffs

- No RDS memory / latency / disk-queue alarm on Dev; weekly C4.3 review instead.
- API 5xx bursts while healthy: Sentry, not a CloudWatch e-mail.
- No automatic scale-out of the CIS api / worker on Dev.

## Should know

- Expected plan: ~78 alarm destroys + 8 target-tracking alarms (AWS deletes them with the 4 policies), 20 metric
  filter destroys, 1 dashboard destroy, 3 IAM policy destroys (PutMetricData) + 2 creates / 2 updates (sns:Publish),
  1 alarm create (`aa-cis-dev-api-no-healthy-task`), 1 log group import, flow logs replaced (2 + 2), WAF logging
  config + 2 log groups updated in place, Booking and CRM task definitions: new revision (env), the ops-probe Lambda:
  env update, 1 schedule destroy. No `aws_db_instance`, secret, bucket, queue or log group destroyed.
- Order: this apply first (IAM + env), then the CIS / Booking / AA-Partner deploys (a new task definition revision
  reaches a task only on the next deploy). Between the two, the old app code logs AccessDenied on PutMetricData; harmless.
- Delete the `import` block for `/aws/apigateway/welcome` after the apply.
