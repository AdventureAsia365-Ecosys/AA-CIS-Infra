# AA-1004 P0 — modules/environment slice 1, Deploy Prod skeleton, DB Migrate prod path (S266, lane l3-prod-p0)

Prod plan P0 (root `docs/audits/2026-11-03-S265-ecosystem-restructure/clarifications.md` §5; ADR 0018 as amended by
ADR 0019: US by default, EU cell on triggers). 0 USD: no resource is created, changed or destroyed, and nothing is
applied. The earlier AA-1004 notes (management account root) are in `AA-1004.md`.

## Decisions

- **`modules/environment` is one module, filled slice by slice, with the root's file layout.** A future
  `accounts/aa-prod` root instantiates the same module with its own inputs. Each slice moves whole files with `git
  mv` and one `moved` block per resource (`accounts/aa365/environment.tf`), so the Dev plan is a pure no-op.
- **Slice 1 = the AA-Booking service stack** (`booking.tf`, `booking_media.tf`, `booking_ops_docs.tf`, 41
  resources). It is self-contained (7 references from other root files, all replaced by module outputs) and is a
  real service stack prod needs. The alternative first slice, wrapping the ten platform module calls of `main.tf`
  (`module.vpc` → `module.environment.module.vpc`), needs only ten moved blocks but rewrites about 160 references in
  some 40 files and about 10 source-text tests at once, conflicting with every parallel Infra lane: kept for last.
- **Kept in the root on purpose:** `aws_lb_listener_rule.booking` (now in `alb_rules.tf`: the shared listener's order
  is owned and checked there, `alb_rule_order.py --source accounts/aa365` still sees all 10 rules); the Booking
  task-role grants that live with their topic (`ses.tf` SES send, `observability_ecosys.tf` alert publish) and the
  no-healthy-task alarm; `aws_security_group.booking_api` (`app_security_groups.tf`, ADR 0004b); the
  `booking_ecs_tasks_assume` policy document (the CRM roles use it; the module has its own identical copy).
- **Root-only values become inputs with the same value**: module.vpc / ecs / alb / s3 outputs, the workload
  boundary, the GitHub OIDC provider, the IAM propagation sleep (`depends_on = [var.iam_propagation_gate]`, Terraform
  accepts a variable there and the dependency still reaches `time_sleep`), the SES configuration set, the M2M pool
  endpoint and CRM client id, the alerts topic, the Booking SG, and the listener rule ARN (the ECS service keeps
  waiting for the rule through `var.booking_listener_rule_gate`).
- **Two value-equal generalisations**, so the module is right for prod without a Dev change: the deploy role's OIDC
  context is `environment:${var.environment}` (was the literal `environment:dev`), and the REST API description is
  `AA-Booking ${title(var.environment)} API ...` (`title("dev")` = `Dev`, checked with `terraform console`).
- **Booking naming has one definition** (module locals); the root reads `booking_name_prefix`, `booking_port`,
  `booking_tags` from module outputs for the files that still build Booking-named objects.
- **Deploy Prod lives in this repo** and is the Terraform plan/apply of `accounts/aa-prod` (app image deploys to prod
  belong to the app repos, later). Plan text is never printed (drift_report summary only, like the management plan);
  apply runs the saved plan after `plan_guard.py`, and needs `confirm = 'apply prod'`.
- **One guard script for both prod paths** (`.github/scripts/prod-guard.sh`): `ready` / `names` / `identity`.
  "Never Dev" is proven without an account id in any file: the guard job (no environment) hashes the account of the
  repo secret `AWS_ROLE_ARN` (the Dev plan role); the prod job compares the hash of its caller account with it, and
  requires the caller to equal the `prod` environment secret `PROD_ACCOUNT_ID`. A hash crosses jobs (GitHub drops job
  outputs that contain a secret) and never shows the id.
- **`prod-guard.sh protected` (review fix)**: the GitHub environment `prod` already exists (left by AA-1023) with no
  required reviewer, no branch policy and no secrets, so "P2 creates it protected" was wrong. Both prod paths now
  refuse unless `prod` has a `required_reviewers` rule naming at least one reviewer and a non-null deployment branch
  policy: in the guard / target job (no environment, `actions: read`, so no unreviewed `prod` job starts and a
  missing `prod` is never auto-created by a run) and again as the first step of the `prod` job, before any secret
  (the same check `terraform-apply.yml` runs for `org`). Read with `gh api` + `jq` in the script, so the tests drive
  it with a fake `gh` on PATH. A missing environment (404) is a refusal.
- **Prod apply prints nothing (review fix)**: `apply -json > $LOG` + `drift_report.py --mode apply`, like the
  management apply; the earlier `apply -no-color` would have printed every `[id=...]` (ARNs / URLs with the prod
  account id) to a public log.
- **Prod jobs use secrets of their own names** (`PROD_TF_ROLE_ARN`, `PROD_DB_MIGRATE_ROLE_ARN`,
  `PROD_TF_STATE_BUCKET`, `PROD_ACCOUNT_ID`). With the same name, an unset environment secret would silently fall
  back to the repo-level Dev secret.
- **DB Migrate keeps one `migrate` job** with every Dev value selected first: `inputs.environment == 'dev' &&
  '<dev literal>' || vars.<PROD_VAR>`, so an unset prod variable is empty (refused by `names`), never the Dev name
  (the reverse `a && b || c` order would fall back to Dev). Validate input now refuses an environment that
  `db/owners.yaml` does not list (read with sed, no PyYAML on the runner needed); prod is added there in P3.

## Changed

- Moved: `accounts/aa365/booking.tf`, `booking_media.tf`, `booking_ops_docs.tf` → `modules/environment/` (git sees
  renames). New: `modules/environment/{versions,variables,outputs,booking_variables}.tf`,
  `accounts/aa365/environment.tf` (module call, 41 moved blocks, the 8 root outputs re-exported with the same names).
- Root reference rewrites (value-equal): `db_migrator.tf`, `observability_ecosys.tf`, `ses.tf`, `outputs_inventory.tf`,
  `custom_domains.tf`, `main.tf` (WAF stage map), `security_access_analyzer_archive.tf` (+ `terraform fmt`).
- `db/connection_budget.json` reads the Booking `deployment_maximum_percent` from `modules/environment/booking.tf`;
  `connection-budget.yml` and `tf-plan-guard-test.yml` trigger on the new paths.
- Tests: new `test_aa1004_environment_moves.py` (moved-block coverage, no shadowing, no provider/backend in the
  module, one instance with `environment = var.environment`) and `test_aa1004_prod_paths.py` (guard script
  behaviour with invented ids, workflow shapes). Updated: `test_aa1022_hardening.py`, `test_sec_access_analyzer.py`
  (scan `modules/environment` too, OIDC provider may arrive as `var.github_oidc_provider_arn`),
  `test_aa1023_env_dev_workflows.py`, `test_aa1023_env_rename.py` (the two prod-account jobs may name `prod`),
  `db/tests/test_owners_registry.py` (choice list = registry + guarded prod; prod refused by the step).
- New workflow `deploy-prod.yml`; `db-migrate.yml`: choice `prod`, job `target`, prod names / identity steps, region
  from `env.AWS_REGION`, follow-up dispatches Dev only.

## Tradeoffs

- No offline `terraform plan` against the real state (no AWS from a lane). Instead: `terraform validate` (no cycle
  through the module boundary), `terraform fmt -check`, and a one-off script that substitutes each module variable
  with the expression the root passes and compares all 53 moved blocks with `origin/main`: identical except the REST
  API description (value-equal) and the listener rule's target group reference. The real proof is the orchestrator's
  plan: `No changes` with 41 "has moved to" notices.
- Leaving the listener rule and two grants in the root splits the Booking stack across the boundary for now; moving
  them would have weakened `alb_rule_order.py` source mode or churned `ses.tf` / observability for no Dev gain.
- `migrator-task.sh` is still Dev-shaped (family / SG / role names, DSN secret regex); a prod run cannot reach it
  today (refused by `ready` and by owners.yaml). P3 parameterises it with the prod migrator.

## Should know

- Expected Dev plan: `Plan: 0 to add, 0 to change, 0 to destroy` plus 41 `has moved to module.environment.…` lines.
  Any `~`, `+` or `-` on a `module.environment.*` address means a value changed: stop and compare.
- An apply records the moves in state (still 0/0/0). It touches no ECS service or RDS, so the job-idle scope is not
  gated; the moved blocks stay (removing them later is its own no-op PR).
- Left for P1+: the CRM stack (`crm_*.tf`), TripPlanner (`tripplanner*.tf`), identity (`identity*.tf`, `ses.tf`, DNS),
  observability + security, then the platform module calls of `main.tf`; account bootstrap (`cicd*.tf`,
  `agent_session.tf`, the boundaries, the OIDC provider, `security_baseline.tf`) stays in each account root.
- P2 GitHub setup for the prod paths: protect the existing environment `prod` (required reviewer, main-only
  branch policy; until then `protected` refuses every prod run, independent of `PROD_ACCOUNT_READY`), its secrets
  `PROD_ACCOUNT_ID`, `PROD_TF_ROLE_ARN`, `PROD_TF_STATE_BUCKET`, `PROD_DB_MIGRATE_ROLE_ARN`, variables
  `PROD_AWS_REGION`, `DB_MIGRATE_{CLUSTER,SERVICE,BUCKET,LOG_GROUP,DB_INSTANCE}`, the prod roles trusting
  `<AA-CIS-Infra>:environment:prod` + ref main; then repo variable `PROD_ACCOUNT_READY=true`.
