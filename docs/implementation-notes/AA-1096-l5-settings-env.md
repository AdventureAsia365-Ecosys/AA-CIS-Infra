# AA-1096 lane l5-settings-env (S281) — the erasure retention env leaves Terraform

Last Done-when of AA-1096: "No env var remains for a migrated setting after one release". Lane L6 (S279) already
removed every settings env var from the task definitions and Lambdas except one: `ERASURE_TENANT_RETENTION_DAYS`,
emitted on the CIS api and worker only while `local.erasure_drill` is true (the Dev erasure drill set it to 0).
AA-CIS-App CIS 428 (same wave) retires that override in the app, so the variable goes too.

## Decisions

- `modules/ecs` drops `variable "erasure_tenant_retention_days"` and the conditional env entry; `erasure_env` carries
  `ERASURE_APPLY_ENABLED` only. `accounts/aa365` no longer passes the value. The drill switch `local.erasure_drill`
  stays (it drives the apply switch); the drill sets the window to 0 on Platform › Settings for its run.
- Proof that nothing else is left (`git grep` over `*.tf`, comments aside): no CIS, CRM, Booking or TripPlanner
  settings env var is set; `tools/terraform/tests/test_aa1096_l6_infra_cleanup.py` keeps that true (the drill
  exception is gone) and a new test fails on any `erasure_tenant_retention_days` / `ERASURE_TENANT_RETENTION_DAYS` in
  Terraform code.
- Comments in `crm_app.tf` / `crm_llm.tf` and `CONTEXT.md` no longer call the CRM env vars "emergency overrides"
  (AA-Partner crm-070 retired them).

## Changed

- `modules/ecs/main.tf`, `modules/ecs/variables.tf`, `accounts/aa365/main.tf`, `modules/environment/crm_app.tf`,
  `modules/environment/crm_llm.tf`, `CONTEXT.md`, `tools/terraform/tests/test_aa1096_l6_infra_cleanup.py`.

## Tradeoffs

- No plan change today: `erasure_drill` is false on main, so the variable was null and no env was emitted; removing it
  leaves the task definitions as they are (`terraform plan` shows no change to `module.ecs`).

## Should know

- The next erasure drill no longer flips an env var: it approves `cis.erasure.tenant_retention_days = 0` (admin may
  self-approve in the dev phase), runs, then approves 30 again. Root `docs/legal/dsar-erasure-runbook.md` section 5
  should say so (root repo follow-up).
