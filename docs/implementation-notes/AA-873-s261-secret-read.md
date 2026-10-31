# Secret read escalation fix (S261, architecture review F1 + F2) — CIS task role, apply boundary, ops key policies

Session S261 (31/10/2026), Claude Code lane l6-iam-escalation. Branch `fix/aa-873-secret-read-escalation`. Refs AA-873.
Source: the S261 architecture review (findings F1 and F2), kept in the private root repo. This repo is public, so this
note records the decisions only; the analysis lives in Linear AA-873.

## Summary

S261 review F1+F2: CIS task role and apply role secret reads narrowed, ops keys behind resource policies; analysis in
Linear AA-873.

- CIS task role: its `DenyMasterAndOtherAppSecrets` list gained three owner prefixes (`modules/ecs/main.tf`).
- Apply role: its boundary denies secret values Terraform does not refresh (`cicd_split.tf`).
- Ops keys: resource policies on the two ecosystem ops secrets (`ops_secret_guard.tf`).
- Review fix (S261): the workload boundary (`DenyEcosystemGuardedSecretValues`) and the apply boundary
  (`DenyEcosystemGuardedSecretPolicyEdits`) guard the `aa-ecosys/*` and `aa-identity/*` prefixes as well, shared
  through `local.ecosystem_guarded_secret_arns`. Both are $0 and both are bootstrap objects that already need the
  local MFA apply.

## Decisions

- **What CIS reads was derived, not assumed:** a grep of AA-CIS-App main plus 30 days of CloudTrail reads by the CIS
  task role (details in Linear AA-873). Nothing CIS reads is denied. Container env secrets come through the EXECUTION
  role and are unaffected.
- **CIS Deny += `aa-crm/*`, `aa-ecosys/*`, `aa-identity/*`.** `aa-llm/*` stays readable: it is CIS's own LLM gateway
  namespace, and no other app uses that prefix.
- **Apply boundary: one Deny with `not_resources = local.tf_plan_secret_arns`** (Sid
  `DenySecretValuesTerraformDoesNotRefresh`), stricter than a prefix list: IAM has no "prefix minus these ARNs" except
  NotResource, and the list is already the plan role's exact read list, so plan and apply roles share one source of
  truth. New prefixes fail closed.
- **`tf_plan_secret_arns` += the EXTERNAL Google / Facebook IdP secret ARNs, conditional on their variables.** They are
  `data "aws_secretsmanager_secret_version"` reads (identity.tf). Both IdPs are off, so the rendered list is
  unchanged (no plan diff on the plan role). Before, identity.tf asked for a hand edit here before turning them on.
- **Ops key resource policies: data source, not import.** `data "aws_secretsmanager_secret" "ops"` (for_each over the
  two names) + `aws_secretsmanager_secret_policy` only. Nothing is imported or recreated; the value never enters
  state. Same Deny pattern as the break-glass secret (identity_alerts.tf); the allowed reader comes from
  `ops_secret_reader_role_arns`.
- **Tests:** `tools/terraform/tests/test_secret_read_guards.py` (offline text checks, 18 tests; the review fix added
  `EcosystemGuardedSecretsTest`: the shared list, both new Denies, and no Terraform read under the two prefixes), run by
  `alb-rule-order.yml` (its trigger now also covers `modules/ecs/**` and `modules/elasticache/**`) and by
  `tf-plan-guard-test.yml` (whole folder). Includes a guard that every secret-version resource / data source in the
  root and modules is in `tf_plan_secret_arns`.

## Changed (vs. the brief)

- Apply boundary deny is "everything but the Terraform read list", not a prefix list (above).
- `aa-crm/*` added to the CIS Deny (not in the brief).
- No `aa-llm/*` entry denied for CIS: every `aa-llm/*` secret is by design a CIS gateway secret.
- Not done: further narrowing of the CIS secret grant (Linear AA-873).

## Tradeoffs

- Strict boundary = a NEW `aws_secretsmanager_secret_version` (or version data source) cannot be created by CI apply
  until its secret ARN is in `tf_plan_secret_arns` AND the boundary is re-applied locally: the provider reads the
  version back after create. Before, only the plan role had that constraint (next PR plan). Accepted: the plan guard
  already forces such changes through a deliberate step (`allow_guarded`), and the TripPlanner traveller secrets
  pattern (container first, local boundary apply, then version) works.
- The resource policy names one role. If the admin role is renamed or a second human admin role appears, the keys
  become unreadable for it until `ops_secret_reader_role_arns` is updated (fail closed; the account root can still
  delete the policy).
- Review fix cost: `aws_secretsmanager_secret_policy.ops` and `.identity_breakglass` are now LOCAL-APPLY ONLY. A CI
  apply that creates or changes either fails with AccessDenied (by design, same as the boundaries). They change
  rarely (a new reader role); the gain is that no main-branch change or apply-role session can reopen them.

## Should know

- **Plan evidence (local, read-only, MFA admin, worktree on origin/main 77ca488, 31/10/2026):**
  `Plan: 2 to add, 2 to change, 0 to destroy.` — `aws_iam_policy.tf_apply_boundary` (update, + 1 statement),
  `module.ecs.aws_iam_role_policy.ecs_task_policy` (update, + 3 Deny ARNs),
  `aws_secretsmanager_secret_policy.ops["github_agent_app"]` and `["linear_api"]` (create). Nothing else;
  no task definition, no service roll. Sizes: boundary 4,543 / 6,144 characters; CIS task role inline policies
  6,686 / 10,240 in total.
- **Both boundaries are bootstrap objects** (`DenyBoundaryPolicyEdits`): a CI apply of either fails with AccessDenied.
  Apply locally with the MFA admin profile, from main after merge. Since the review fix the two ops resource policies
  are local-only too (`DenyEcosystemGuardedSecretPolicyEdits`); only the CIS task role policy would be CI-appliable.
  Run the whole plan once, locally. Order inside one run does not matter for safety: every new statement is a Deny.
- **IAM eventual consistency:** verify denies after >= 5 minutes, N/N times (lessons, AA-860 S19).
- Residual risk on the apply path is tracked in Linear AA-873 (TL-7).
- **Plan after the review fix (expected, not re-run here):** the same 2 to add, with
  `aws_iam_policy.workload_boundary` as a third in-place update (+1 statement). Boundary sizes stay under 6,144.
  Order (local, MFA): one local run of the whole plan; the two boundary updates and the two new resource policies
  land together, nothing is left for CI.
- S261: public-repo trim of security notes; details live in Linear AA-873 and the private root audit.
