# AA-1004 P1 — modules/environment slice 2: the AA-Partner (CRM) stack (S266, lane l12-prod-p1)

Prod plan P1 (follows P0 slice 1, Infra #633, notes in `AA-1004-l3-prod-p0.md`). 0 USD: no resource is created,
changed or destroyed, and nothing is applied from the lane. The Dev plan must be a pure no-op.

## Decisions

- **One PR, not two.** The CRM stack is 70 resources in 8 files, but every change is a mechanical move: a split
  (roles and secrets first, services second) would add a temporary set of cross-boundary inputs (the task role, the
  KMS keys, the buckets each service file reads) that the second PR deletes again, and doubles the moved-block review.
  The value-equality proof below covers the whole slice at once.
- **Moved (git mv, one moved block per resource, resource-level so every count / for_each key moves unchanged):**
  `crm_app.tf`, `crm_web.tf`, `crm_portal.tf`, `crm_data.tf`, `crm_storage.tf`, `crm_mail.tf`, `crm_scrub.tf`,
  `crm_llm.tf` → `modules/environment/`. This covers the api / web / portal services, their ECR repos, log groups,
  secret shells, execution / task / deploy roles and policies, the scrub guardrail + corpus role (`crm_scrub.tf`), the
  Nova Lite grant (`crm_llm.tf`, Infra #632), the DSN secret, the three KMS keys + aliases + key alarms, the four
  buckets (Object Lock, lifecycle, policy), the decrypt-anomaly alarm and the three no-healthy-task alarms.
- **Kept in the root on purpose:**
  - `aws_lb_listener_rule.crm_api` → `alb_rules.tf` (same reason as the Booking rule: the shared listener's order is
    owned and checked there; `alb_rule_order.py --source accounts/aa365` still sees all 10 rules).
  - The CRM edge files `crm_edge.tf`, `crm_agency_edge.tf`, `crm_client_edge.tf` (CloudFront, ACM, Route 53 records,
    the origin secret, the host rules on the shared listener): they belong with DNS and the ALB, a later slice.
  - The MX record and the SES receipt rule of `crm_mail.tf` → new root file `crm_mail_receipt.tf`: the zone and the
    region's one active receipt rule set are shared with the e2e mailbox, and `e2e_mailbox.tf` orders the rules
    (`e2e_cognito_admin.after = crm_ingest`).
  - The CRM task-role grants of `identity_partner.tf` (partner pool, SES send), and `cicd_crm.tf` (bootstrap).
- **Mechanical substitution, one input per root expression.** Every root object the moved code read became
  `var.<input>`, and `environment.tf` passes exactly that expression (frozen as `SLICE_2_INPUTS` in the test).
  New inputs live in `modules/environment/crm_inputs.tf`; the slice-1 inputs (boundary, OIDC provider, IAM gate, VPC,
  ECS, SES, alerts topic) are reused. The listener-rule `depends_on` became `var.crm_*_rule_gate = <rule>[*].arn`
  (list, the rules have `count`), as slice 1 did with `booking_listener_rule_gate`.
- **CRM naming has one definition, in the module** (`crm_inputs.tf` locals `crm_name_prefix`, `crm_tags`; was
  `cicd_crm.tf`). The root reads them and the per-service ports / tags / `crm_oidc_repo_id` back through module
  outputs as root locals of the same names (environment.tf), so `app_security_groups.tf`, the edge files,
  `identity_*.tf`, `e2e_mailbox.tf` and `cicd_crm.tf` did not change shape.
- **CRM settings stay declared next to the code that reads them** (as before the move) and the root declares the same
  14 variables in `crm_variables.tf`, passed through as `var.<same name>`. A test checks both declarations are
  byte-identical, so terraform.tfvars and every `-var` stay valid.
- **The root ecs-tasks assume document is gone**: the CRM roles now use the module's copy (same JSON; slice 1 made it),
  the root copy had no other user.
- **One value-equal generalisation:** `crm_oidc_contexts = ["environment:${var.environment}"]` (was the literal
  `environment:dev`), like slice 1's Booking deploy role. The `scrub-corpus` and `e2e` contexts are GitHub
  environment names, unchanged.
- **The receipt rule's old `depends_on = [aws_s3_bucket_policy.crm, aws_kms_key.crm_ingest]`** is carried by the
  module output `crm_ingest_receipt` (output `depends_on`): the rule reads its bucket from that output.

## Changed

- Moved files above (git sees renames). New: `modules/environment/crm_inputs.tf`, `crm_outputs.tf`;
  `accounts/aa365/crm_variables.tf`, `crm_mail_receipt.tf`.
- `accounts/aa365/environment.tf`: CRM inputs, root locals, the 21 CRM root outputs re-exported with the same names
  and descriptions, 70 moved blocks, header; the root `booking_ecs_tasks_assume` data source removed.
- Root reference rewrites (value-equal): `alb_rules.tf` (+ rule crm_api), `cicd_crm.tf` (naming locals removed),
  `crm_edge.tf`, `crm_agency_edge.tf`, `crm_client_edge.tf` (target groups), `db_migrator.tf` (crm_db secret),
  `identity_partner.tf` (task role id / arn), `outputs_inventory.tf`, `security_access_analyzer_archive.tf`.
- `tools/terraform/crm_key_policy_diff.py` reads the keys at `aws_kms_key.<name>` OR
  `module.environment.aws_kms_key.<name>` (state before / after the apply); a key under both fails closed.
- Paths: `db/connection_budget.json` (crm-api tf_file), `alb-rule-order.yml` and `tf-plan-guard-test.yml` triggers,
  `scripts/pre-push.sh` (alb-rule-order + connection-budget + tf-plan-guard paths, one new self-test case),
  `db/owners.yaml` comment, `docs/runbooks/crm-mail-ingest.md`, `CONTEXT.md`.
- Tests: `test_aa1004_environment_moves.py` (SLICE_2 frozen list; input value equality; settings declared identically
  and passed through; every module variable without a default is passed; the CRM module files read no root object;
  the pieces kept in the root; the CRM deploy context), `test_crm_key_policy_diff.py` (module address, both addresses
  = error), path updates in `test_aa1027_crm_llm.py`, `test_crm_kms_alarm_check.py`, `test_plan_guard.py`,
  `test_crm_edge_live_check.py`, `test_partner_pool_delete_user.py`.

## Tradeoffs

- No `terraform plan` against the real state from a lane (no AWS). Proof offline: `terraform validate`
  (init -backend=false, no cycle across the boundary), `terraform fmt -check`, and a reverse substitution of every
  module file (each `var.<input>` back to the root expression) diffed against `origin/main`: identical except the
  intended edits (the listener rule and the MX / receipt rule left the files, the OIDC context interpolation,
  comments). The real proof is the orchestrator's plan.
- Many inputs (about 30 new): the price of moving the services before identity and the edge. Each later slice that
  moves an owner (identity, edge) deletes its inputs.
- Passing whole maps (`ecosys_tags`, `runbook_suffix`) keeps the moved code unchanged; a narrower input would have
  needed edits in the alarm descriptions.

## Should know

- Expected Dev plan: `Plan: 0 to add, 0 to change, 0 to destroy` plus 70 `has moved to module.environment.…` lines
  (count / for_each resources print one line per instance, so the line count is higher: e.g. 4 buckets, 3 KMS
  aliases). Any `~`, `+`, `-` or `-/+` on a `module.environment.aws_*crm*` or a root `crm_*` address means a value
  changed: stop and compare.
- After the apply records the moves, the nightly CRM key-policy diff reads the keys under `module.environment`
  (this PR teaches the tool both addresses).
- The apply touches no ECS service, task definition or RDS (moves only), so the job-idle scope is not gated.
- Left for later slices: TripPlanner, identity (+ the CRM edge, the receipt rule, `identity_partner.tf` grants),
  observability + security, then the platform module calls of `main.tf`.
