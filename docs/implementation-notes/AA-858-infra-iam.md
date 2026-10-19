# AA-858 — Infra IAM PR: CloudWatch read for the CIS task role

Session S243 (19/10/2026), builder lane AA-858 step S4. Branch `feat/aa858-cloudwatch-read-iam`. Own PR and own
notes file (the data PR `chore/aa858-copy-bk017-tp015` has `AA-858-infra.md`), per the repo's "no self-added IAM via
auto-merge" convention.

## What changes

`modules/ecs/main.tf`, `aws_iam_role_policy.ecs_task_infra_status_readonly` (role `aa-cis-dev-ecs-task-role`, policy
`aa-cis-dev-ecs-task-infra-status-readonly`) gains two statements:

| Action | Resource | Why |
|---|---|---|
| `cloudwatch:GetMetricData` | `*` | no resource-level permission in IAM; returns metric values only |
| `cloudwatch:DescribeAlarms` | `arn:aws:cloudwatch:us-west-1:005097885195:alarm:*` | the alarm ARN is supported, so scoped to this account + region |

Expected plan: exactly one in-place update of `module.ecs.aws_iam_role_policy.ecs_task_infra_status_readonly`.

## Decisions

- **Same policy as the other read-only describes** (`ecs_task_infra_status_readonly`, AA-257 / AA-623): the overview
  health tiles are the same class of read as `/admin/infra/status`; no new policy resource.
- **DescribeAlarms on `alarm:*`, not per-prefix ARNs.** The plan suggested four prefix ARNs (`alarm:aa-cis-dev-*`,
  `aa-booking-dev-*`, `aa-tripplanner-dev-*`, `aa-ecosys-dev-*`) and named the risk that a list call made with
  `AlarmNamePrefix` may not match prefix-pattern ARNs (AccessDenied → a second IAM PR + apply cycle). `alarm:*` in this
  account/region matches whatever alarm ARN the service evaluates, so it cannot hit that. Live today (read-only
  `describe-alarms`, 19/10): 29 `aa-cis-dev-*`, 7 `aa-booking-dev-*`, 4 `aa-tripplanner-dev-*`, 1 `aa-ecosys-dev-*`,
  14 `aa-identity-dev-*`, 2 `aa-email-dev-*`, 8 `TargetTracking-*`. The response holds names, states, thresholds,
  dimensions and action ARNs — no secret.
- **No `lambda:GetFunctionConfiguration`** (returns environment variables; S241 design §8). Lambda health comes from
  the `AWS/Lambda` metrics through GetMetricData.
- **Account id hard-coded** like the neighbouring Secrets Manager statements of this module (it has no account
  variable); region from `var.aws_region`.

## Changed (vs. the plan)

- DescribeAlarms resource `alarm:*` (account + region) instead of four prefix ARNs (reason above). If a reviewer wants
  the prefixes, the CIS code calls DescribeAlarms once per prefix, so the four-ARN form can be tried and verified with
  one call after apply.

## Tradeoffs

- `alarm:*` lets the CIS runtime read every alarm's configuration in us-west-1 of acc2 (not other accounts/regions).
  Accepted: read-only, no secret, and it already sees the infra describes; it avoids a failed verification loop.

## Cost

- GetMetricData: $0.01 per 1,000 metrics requested; ~16 per cache miss, 5-minute Redis cache, worst case ≈ $0.60/month
  (page open 10 h/day every day), realistic < $0.10.
- DescribeAlarms: within the CloudWatch API free tier (1M requests/month), $0.
- No new AWS resource.

## Should know (main session / Nghiệp)

- Merge → Terraform Apply from `main` (lesson S240). If the prod-environment gate or the apply role refuses the IAM
  write, Nghiệp approves or applies locally with MFA, then a re-plan must say "No changes".
- Verify: `aws iam get-role-policy --role-name aa-cis-dev-ecs-task-role --policy-name aa-cis-dev-ecs-task-infra-status-readonly --profile aa365-admin --region us-west-1`
  shows both statements. The real proof is the CIS backend's first `/admin/overview/ops` health section (no
  AccessDenied in `/ecs/aa-cis-dev`).
- `modules/ecs/main.tf` is also edited by AA-860 S19 (Deny on the master secret, `ecs_task_policy`) and AA-884
  (GIT_SHA task-def env): different resources, a text conflict at most; merge one Infra PR at a time with its apply.
- Local checks (S243): `terraform fmt -check -recursive modules/ecs accounts/aa365` clean; `terraform init
  -backend=false` + `terraform validate` in a temp copy of `accounts/aa365` + `modules` (TF 1.15.5): valid. No plan
  run locally (needs the state + MFA); CI Terraform Plan is the check.
