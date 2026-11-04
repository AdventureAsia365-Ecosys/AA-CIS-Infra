# AA-1004 P1 — modules/environment slice 3: the AA-TripPlanner stack (S267, lane p1-tripplanner-stack)

Follows slice 1 (Booking, Infra #633, `AA-1004-l3-prod-p0.md`) and slice 2 (CRM, Infra #643, `AA-1004-l12-prod-p1.md`).
0 USD: no resource is created, changed or destroyed, and nothing is applied from the lane. The Dev plan must be a pure
no-op.

## Decisions

- **Moved (git mv, one moved block per resource, 42 resources):** `tripplanner.tf` (edge key + its random value, the
  DB DSN / edge key / Sentry DSN secrets, the artifacts bucket + its 3 settings + 2 placeholder objects, the browse /
  assembly execution role + policy + VPC attachment, the two Lambdas, the HTTP API with 2 integrations, 5 routes, the
  stage and 2 invoke permissions, the app deploy role + policy) and `tripplanner_jobs.tf` (the jobs Lambda, placeholder,
  role + policy + VPC attachment, log group, event invoke config, 2 alarms, scheduler role + policy, daily schedule).
- **Kept in the root on purpose:**
  - `aws_security_group.tp_lambda` (app_security_groups.tf, ADR 0004b: one SG file for every DB caller), passed in as
    `tripplanner_lambda_security_group_id`.
  - `ses.tf` `tripplanner_lambda_ses_send` (grant with its topic, like the Booking SES grant).
  - `observability_ecosys.tf`: the browse / assembly log groups, errors and throttles alarms (observability slice).
  - `custom_domains.tf`: the api-tripplanner. domain, API mapping and DNS record (DNS / edge slice).
  - The two Mapbox `removed` blocks → new root file `tripplanner_removed.tf`: they name root addresses (a `removed`
    block in the module would name module addresses, a different object).
- **Mechanical substitution, one input per root expression** (frozen as `SLICE_3_INPUTS` in the test). New inputs in
  `modules/environment/tripplanner_inputs.tf`: the Lambda SG, `bedrock_acct_primary`, the EventBridge schedule group,
  the placeholder zip path. Reused: boundary, OIDC provider, IAM gate, private subnets, alerts topic, runbook suffix.
- **The acc3 invoker ARN is built from `var.bedrock_acct_primary`** (was a literal; same value). The module has no
  12-digit literal anywhere now, comments included (the Booking header comment lost its account id too; the test now
  checks comments as well).
- **The placeholder zip path is an input** (`"${path.module}/artifacts/placeholder.zip"` evaluated in the root), not a
  `path.module` inside the module: the value of `source` stays byte-identical and the zip stays in one place.
- **Settings:** the root keeps `tripplanner_variables.tf` (tfvars, `-var`, `db/connection_budget.json` read it) and
  gains the two jobs settings that lived in `tripplanner_jobs.tf`; the module declares the same 12 blocks
  (`tripplanner_variables.tf` copy + the two in `tripplanner_jobs.tf`), passed through as `var.<same name>`.
- **Naming has one definition, in the module** (`tp_name_prefix`, `tp_tags`); the root reads them back as locals of the
  same names (environment.tf) for the SG and the SES grant.
- **`random` added to the module's required_providers** (the root's default random provider, no configuration).
- **Not generalised in this slice (same value):** the deploy role trust subject (`ref:refs/heads/main` of the
  AA-TripPlanner-Web repo id) and the satellite role name / external id. A prod instance needs its own context and
  invoker role; that is the prod-root slice's change, not a no-op move.

## Changed

- Moved: `accounts/aa365/tripplanner.tf`, `tripplanner_jobs.tf` → `modules/environment/`. New:
  `modules/environment/tripplanner_inputs.tf`, `tripplanner_outputs.tf`, `tripplanner_variables.tf`;
  `accounts/aa365/tripplanner_removed.tf`. `modules/environment/versions.tf` (+ random).
- `accounts/aa365/environment.tf`: inputs + settings, locals `tp_name_prefix` / `tp_tags`, the 6 root outputs
  re-exported with the same names, 42 moved blocks, header.
- Root reference rewrites (value-equal, through module outputs): `ses.tf` (role id), `observability_ecosys.tf`
  (function names), `outputs_inventory.tf` (HTTP API id), `security_access_analyzer_archive.tf` (deploy role ARN),
  `cicd_split.tf` (plan refresh list: DB + edge key secret ARNs), `db_migrator.tf` (DB secret ARN), `custom_domains.tf`
  (API id + stage id). Comment path updates in `cicd.tf`, `custom_domains.tf`, `security_baseline.tf`, `identity.tf`,
  `app_security_groups.tf`, `accounts/acc3-bedrock/main.tf` (comments only, no plan change there).
- Tests: `test_aa1004_environment_moves.py` (SLICE_3 frozen list, inputs value equality, settings identical on both
  sides and passed, TripPlanner module files read no root object and no `path.module`, satellite ARN from the input,
  pieces kept in the root incl. the removed blocks, outputs re-exported, random provider; the backend check now looks
  for a `backend "` block instead of the word, which the Lambda handler strings contain; the account-id check covers
  comments). `test_secret_read_guards.py`: secret versions in `modules/environment` must reach `tf_plan_secret_arns`
  through a module output returning exactly that secret's ARN.
- Docs: `CONTEXT.md`, `README.md`.

## Tradeoffs

- No `terraform plan` from the lane (no AWS). Offline proof: `terraform validate` (init -backend=false, no cycle across
  the boundary), `terraform fmt -check`, and a reverse substitution of both moved files (each `var.<input>` back to
  the root expression) diffed against `origin/main` with comments stripped: identical except the two `removed`
  blocks that left the file. The real proof is the orchestrator's plan.
- The plan-refresh list (`cicd_split.tf`, bootstrap) now reads the two secret ARNs through module outputs; same value,
  so no bootstrap apply is needed.

## Should know

- Expected Dev plan: `Plan: 0 to add, 0 to change, 0 to destroy` plus 42 `has moved to module.environment.…` lines.
  Any `~`, `+`, `-` or `-/+` on a `module.environment.*tripplanner*` address or on a root resource that reads one
  (`aws_iam_role_policy.tripplanner_lambda_ses_send`, `aws_apigatewayv2_api_mapping.tripplanner`, the TripPlanner log
  groups / alarms, the bootstrap policies of `cicd_split.tf`) means a value changed: stop and compare.
- `random_password.tripplanner_api_key` moves with its result; the edge key secret version keeps the same value.
- The apply touches no ECS service, task definition or RDS (moves only): the job-idle gate is skipped.
- The AA-TripPlanner-Web docs may cite `accounts/aa365/tripplanner.tf`; the path is now
  `modules/environment/tripplanner.tf` (follow-up in that repo, no behaviour change).
- Left for later slices: identity (+ the CRM edge, the TripPlanner custom domain), observability + security (the TP log
  groups / alarms), then the platform module calls of `main.tf`.
