# AA-896 (+ AA-893 step 1) — Cost Anomaly Detection to the alerts topic, runbook links on alarms

Session S243 (19/10/2026), Claude Code. Branch `feat/aa896-cost-anomaly-alarm-runbooks`.
Root docs that go with it: AA-Ecosys `docs/ops/finops.md`, `docs/ops/cost/README.md` (branch
`docs/aa895-aa896-security-finops`).

## Decisions

- **Import the existing AWS services monitor instead of creating one.** `aws ce get-anomaly-monitors`
  (19/10/2026) shows `Default-Services-Monitor` (DIMENSIONAL / SERVICE), created by AWS on 20/04/2026.
  An account keeps one AWS-managed services monitor, so a second `aws_ce_anomaly_monitor` would fail.
  `cost_anomaly.tf` imports it with an `import {}` block (Terraform >= 1.7 in `versions.tf`); the plan
  shows only a tag update on it.
- **No `App` cost allocation tag monitor.** acc2 is a member account (`aws organizations
  describe-organization`: the management account is the reseller's payer). The AWS guide says monitors
  on linked accounts, cost allocation tags and cost categories can only be created in the management
  account. Per-App spend is already covered by the AA-828 per-App budgets and the AA-884 cost page.
- **One IMMEDIATE SNS subscription, threshold $5 absolute impact** (`var.cost_anomaly_alert_usd`).
  IMMEDIATE is the only frequency that accepts an SNS subscriber. $5 is about 2% of the $250 account
  budget. The default DAILY e-mail subscription ($100 and 40%) is left as it is and not imported.
- **Same topic as every alarm** (`aws_sns_topic.alerts`), so the one confirmed e-mail subscription gets
  the alert. Topic policy: one more statement for `costalerts.amazonaws.com` with
  `aws:SourceAccount` = this account (the AWS guide's statement).
- **CI grant split in two statements.** The AWS service reference (servicereference JSON for `ce`,
  read 19/10/2026) lists no resource type for `CreateAnomalyMonitor` / `CreateAnomalySubscription`, so
  they need `Resource "*"`; Get/Update/Delete/Tag/Untag/ListTags take
  `arn:aws:ce::<account>:anomalymonitor/*` and `anomalysubscription/*`.
- **Runbook links:** one local map in `alarm_runbooks.tf`, appended to each description as
  ` Runbook: <url>`. Paths follow the root catalog (OPS-01..OPS-11) and the AA-892 ops lane names:
  `playbooks/{5xx-spike,queue-stuck,llm-cost-spike,cognito-login,ses-bounce}.md`,
  `runbooks/{restore-rds-pitr,break-glass}.md`, `database-operations.md`, `incident-response.md`.

## Changed

| Alarm group | Runbook key |
|---|---|
| CIS / Booking 5XX, CIS latency p95, Booking target health and CPU, ECS running tasks, TripPlanner Lambda errors and throttles | `api_5xx` |
| Job queue age, overdue running, sampling stopped (CIS, Booking); ACP DLQ depth (module.eventbridge) | `queue_stuck` |
| `log_write_failed` (billed call not recorded) | `llm_cost_spike` |
| Identity trigger errors, throttles, duration, unexpected error | `cognito_login` |
| Identity break-glass token issued | `break_glass` |
| SES bounce and complaint rate | `ses_bounce` |
| Every RDS alarm, per-role connections, role sampler stopped, snapshot-expiry Lambda errors | `database` |
| NAT status check, N7 held-rate / grounding floor / repair count | `incident` |

`restore_pitr` is in the map for AA-893 step 2 and the database-operations page; no alarm points at it
directly (a restore is a decision taken from the database page, not an alarm reflex).

`module.eventbridge` gets a new optional input `alarm_runbook_url` (default empty = no link).

## Tradeoffs

- A link to a page that AA-892 is still writing is better than no link: the alarm text does not change
  when the page lands, and the ops lane uses the same names.
- Links point at the private root repo on `master`. Anyone who gets the alarm e-mail and has repo access
  can open them; there is no public copy (security pages stay private, D-25).
- Anomaly threshold $5 may be noisy in the first weeks (the model learns per service). Raise
  `cost_anomaly_alert_usd` instead of removing the subscription.

## Should know

- **Plan (read-only, `-lock=false`, dummy `TF_VAR_db_password`, Terraform 1.15.5, admin profile,
  19/10/2026):** `Plan: 1 to import, 2 to add, 64 to change, 1 to destroy.`
  - import + in-place: `aws_ce_anomaly_monitor.services` (tags only).
  - add: `aws_ce_anomaly_subscription.alerts_sns`.
  - in-place: 57 `aws_cloudwatch_metric_alarm` (description only, incl. `module.eventbridge.acp_dlq_depth`),
    `aws_sns_topic_policy.alerts`, `aws_iam_role_policy.tf_apply`.
  - `time_sleep.wait_for_iam_propagation` is replaced because the tf_apply policy hash changed (by design,
    observability.tf AA-402 note); that re-tags `module.eventbridge` bus / scheduler role / schedule group
    in place and re-reads the scheduler policy document at apply (same content).
  - No alarm is replaced; no other resource changes.
- **tf_apply inline policy size:** 9,041 -> 9,559 characters (minified) of the 10,240 limit. About 680
  left: the next bootstrap grant may need a managed policy instead.
- **Apply order (bootstrap):** the apply role cannot change its own policy. Nghiệp (MFA admin profile)
  applies first, locally:
  `terraform apply -target=aws_iam_role_policy.tf_apply` from `accounts/aa365/`, then merges; CI applies
  the rest. Without that, CI apply fails with AccessDenied on `ce:GetAnomalyMonitors` (import).
- **Plan role:** `aa-cis-infra-tf-plan` reads `ce:Get*` / `ce:List*` through the AWS managed
  `ReadOnlyAccess` (not verified with the simulator: the session guard blocks IAM calls). The PR's
  Terraform Plan check proves it; a 403 there means a `ce:GetAnomalyMonitors` grant is needed on the
  plan role (bootstrap too).
- **After apply:** `aws ce get-anomaly-subscriptions --profile aa365-admin --region us-west-1` shows two
  subscriptions; the SNS one has `Frequency: IMMEDIATE` and the topic as subscriber. A real alert can
  only be seen when an anomaly happens (there is no test-publish for Cost Anomaly Detection).
- Cost: $0/month (Cost Anomaly Detection is free; SNS e-mail inside the free tier). Each `aws ce` CLI
  read costs $0.01.
