# AA-678 — S235 Phase 0: observability (retention, alarms, tags)

Branch `feat/s235-p0-observability`. Part of the ecosystem blueprint Phase 0 approved in S235.

## Decisions

- **Retention via `import` blocks**, not `aws logs put-retention-policy` by hand. Live 14/10/2026:
  `/aws/lambda/aa-tripplanner-dev-browse` (10.2 MB), `/aws/lambda/aa-tripplanner-dev-assembly`
  (0.1 MB), `API-Gateway-Execution-Logs_4ylo382khg/dev` (157 MB), all retention "never expire",
  none in state. Only one `API-Gateway-Execution-Logs_*` group exists (Booking stage has no
  execution logging). `/aws/apigateway/welcome` (108 bytes) left alone.
- **Booking health = target group metrics**, because Container Insights is disabled on
  `aa-cis-dev-cluster` (so `ECS/ContainerInsights RunningTaskCount` does not exist; the existing
  CIS `ecs-running-tasks-low` alarm is silent for the same reason). `HealthyHostCount < 1` stands in
  for "running < desired", plus `UnHealthyHostCount > 0` and service CPU.
- **Thresholds**: NAT `StatusCheckFailed >= 1` 3x1 min; Booking 5XX `>= 5`/5 min; TP `Errors >= 3`/5
  min, `Throttles > 0`; RDS `FreeStorageSpace < 4 GiB` (now ~17.4 GB free of 20) and
  `DatabaseConnections > 70` (3-day peak 25; t3.micro limit ~80-110). All `notBreaching` on
  missing data, `ok_actions` to the same topic, like the existing alarms.
- **Tags: provider `default_tags` NOT changed.** Any value change there (Project AA-CIS ->
  AA-Ecosys, ManagedBy Terraform -> terraform) re-tags every resource in the root, including IAM
  roles the CI role cannot `iam:TagRole` (only the scheduler, TripPlanner, agent-session and Booking
  role patterns are granted). A CI apply would fail half-way. Instead: new resources carry the full
  blueprint set (`Project = AA-Ecosys`, `App`, `Environment`, `ManagedBy = terraform`), and
  `App = tripplanner|booking` is added to the existing `tp_tags` / `bk_tags` (additive key; every
  tagged type there is covered by the CI role: TagRole patterns, SecretsManagerReadWrite, Lambda /
  ECS / S3 full access, APIGatewayManage, BookingEcrRepoManage, ELB AddTags, logs:*).

## Changed

- New `accounts/aa365/observability_ecosys.tf`; `modules/alb/outputs.tf` adds `alb_arn_suffix`;
  `App` key in `tripplanner.tf` / `booking.tf` locals; CONTEXT.md + README.md file list.

## Tradeoffs

- One email SNS topic for everything (no paging). Fine for Dev.
- `App` is missing on CIS resources until default_tags move; in Cost Explorer, "no App tag" =
  CIS + shared. `Project` (AA-CIS / aa-cis / AA-TripPlanner / AA-Booking) and `Service`
  (tripplanner / booking) already split the apps today once activated.

## Should know

- Cost allocation tags must be activated by Nghiệp in Billing -> Cost allocation tags (`App`,
  `Project`, `Service`); they only apply to costs from the activation date.
- Local speculative plan (14/10/2026, `-lock=false`, real state): 3 to import, 11 to add, 28 to
  change, 0 to destroy. Changes = tag-only (`App`) on TP/Booking resources, retention + tags on the
  3 imported groups, plus pre-existing local-build noise (`dfs_balance_check` source_code_hash,
  `tripplanner_*_zip` s3 objects `tags_all`).
- After apply the `import` blocks are no-ops; remove them in a later PR.
