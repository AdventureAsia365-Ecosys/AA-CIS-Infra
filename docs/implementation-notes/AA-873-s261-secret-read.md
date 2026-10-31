# Secret read escalation fix (S261, architecture review F1 + F2) — CIS task role, apply boundary, ops key policies

Session S261 (31/10/2026), Claude Code lane l6-iam-escalation. Branch `fix/aa-873-secret-read-escalation`. Refs AA-873.
Source: root `docs/audits/2026-10-31-S261-architecture-review/README.md` §3.6 F1 (CIS task role reads every secret
outside its Deny list, including the aa-agent GitHub App key) and F2 (Terraform apply role reads every secret value).
This repo is private, so names and the escalation path are written out here; they stay out of the public repos.

## The escalation path that is closed

1. A compromised CIS api/worker task (it ingests supplier files, fetches external URLs and runs LLM output) had
   `secretsmanager:GetSecretValue` on `*` minus the master / migrator / booking / tripplanner / crm Deny.
2. It could read `aa-ecosys/github/aa-agent-app-key` (no resource policy; created with the CLI in S247).
3. That App has write on Contents, Workflows, Actions and PRs in the five repos; the Infra `prod` environment has no
   protection rule, so an App token could dispatch `terraform-apply.yml` on main and run as `aa-cis-infra-tf-apply`,
   which held `SecretsManagerReadWrite` with no boundary limit on secret values (master DSN, every app DSN,
   break-glass login).

After this change: step 2 fails three ways (CIS identity Deny, the secret's resource policy, and the apply role's
boundary for the reverse direction). Step 3 (environment rules, decision TL-7) and the narrow agent role (N7) are
NOT in this change.

### Review fix (S261): the apply role's indirect leg

An independent review found that the first commit only stopped the apply role reading a value itself. With
SecretsManagerReadWrite it could still (1) DeleteResourcePolicy on the App key or the break-glass secret, (2)
PutRolePolicy a GetSecretValue Allow onto any aa-*-dev-* role (the workload boundary allowed it), (3) RunTask or ECS
exec into that role. Variants: rewrite the resource policy to trust another account after pointing the secret at a
KMS key it controls, or ReplicateSecretToRegions to a region where the replica has no policy. Confirmed against the
code: nothing denied those calls. Both suggested fixes are applied (both $0, both bootstrap objects that already need
the local MFA apply):

- **(b) workload boundary `DenyEcosystemGuardedSecretValues`:** GetSecretValue denied on
  `arn:aws:secretsmanager:*:<acct>:secret:aa-ecosys/*` and `aa-identity/*` (`local.ecosystem_guarded_secret_arns`)
  to every bounded role, now and later (CI can only create or write roles that carry this boundary, and cannot edit
  it). Region `*` covers replicas. Who reads these prefixes: only the MFA admin role (as-app.sh, linear_export.py,
  workforce_bootstrap.py), per CloudTrail 01-31/10 and the secrets register; no task definition, Lambda or CI role
  references them (grep of all six repos). The unbounded agent session role is untouched (the apply role cannot
  write or pass it: DenyProtectedRoleWrites).
- **(a) apply boundary `DenyEcosystemGuardedSecretPolicyEdits`:** PutResourcePolicy, DeleteResourcePolicy and
  ReplicateSecretToRegions denied on the same two prefixes. (b) alone would not stop a cross-account grant through a
  rewritten resource policy; (a) alone would not cover an aa-ecosys/* or aa-identity/* secret created later without
  a resource policy. UpdateSecret stays allowed (tags / description of the break-glass container from CI).
- Headers corrected: `ops_secret_guard.tf` (the old "removing the policy gives nothing to the apply role" claim was
  wrong; it now lists the layers) and `identity_alerts.tf` (the CI apply no longer needs PutResourcePolicy).

## Decisions

- **What CIS reads was derived, not assumed.** (a) `git grep` of AA-CIS-App `origin/main` (1b6e9448) for
  `get_secret_value` / secret names: `aa-cis/<env>/{rds-app-user, rds-cis-app, admin-secret-preview,
  booking-jwt-signing-key, gdrive-photo-reader, geoapify, typesafe, sentry-dsn-api, tripplanner-revalidate-hmac,
  e2e-tenant/*}`, `acp/{cms,social}/*` and `aa-llm/<env>/*` (LLM gateway `shared/llm_client/connections.py`; the
  connection registry CHECKs `^aa-llm/<env>/<name>$`, migration 304/317). (b) CloudTrail `lookup-events
  EventName=GetSecretValue` 01/10-31/10/2026 (25,058 events, read-only): after the X1 S19 Deny (19/10) the
  `aa-cis-dev-ecs-task-role` read only `aa-cis/dev/*`, `acp/*` and one `aa-llm/dev/anthropic-direct`
  (ResourceNotFound, 30/10: the gateway probing a connection whose secret does not exist yet). It never read
  `aa-ecosys/*`, `aa-identity/*` or `aa-crm/*`. Container env secrets (openai-key, dataforseo, jwt-secret,
  redis-auth, admin-secret) come through the EXECUTION role and are unaffected.
- **CIS Deny += `aa-crm/*`, `aa-ecosys/*`, `aa-identity/*`.** `aa-llm/*` stays readable: it is CIS's own gateway
  namespace (every live and planned LLM connection secret), and no other app uses that prefix (grep of Booking,
  Partner, TripPlanner, Infra). There are no `aa-llm/*` secrets live today.
- **Apply boundary: one Deny with `not_resources = local.tf_plan_secret_arns`** (Sid
  `DenySecretValuesTerraformDoesNotRefresh`), stricter than the brief's prefix list (master, booking/*, tripplanner/*,
  crm/*, aa-identity/*, aa-ecosys/*). Reasons: IAM has no "prefix minus these ARNs" except NotResource, and the
  tripplanner exceptions force NotResource anyway; the list is already the plan role's exact read list, so plan and
  apply roles now share one source of truth; CloudTrail shows the apply role read nothing else after the AA-878
  removed blocks (19/10): DB Migrate, the probes and schema dump read DSNs from their ECS task roles, not from the
  workflow's role. New prefixes fail closed.
- **`tf_plan_secret_arns` += the EXTERNAL Google / Facebook IdP secret ARNs, conditional on their variables.** They are
  `data "aws_secretsmanager_secret_version"` reads (identity.tf). Both IdPs are off, so the rendered list is
  unchanged (no plan diff on the plan role). Before, identity.tf asked for a hand edit here before turning them on.
- **Ops key resource policies: data source, not import.** `data "aws_secretsmanager_secret" "ops"` (for_each over the
  two names) + `aws_secretsmanager_secret_policy` only. Nothing is imported or recreated; the value never enters
  state. Same Deny pattern as the break-glass secret (identity_alerts.tf), reader = `local.id_breakglass_admin_role_arn`
  (`nghiep-admin-8h-session`, the role aa365-admin / default assume; CloudTrail: the only principal that read either
  key in 30 days: 3,977 App key reads, 81 Linear key reads). Denied actions: Get/PutSecretValue (the break-glass
  pair) + UpdateSecret, RotateSecret, ReplicateSecretToRegions (value changes or copies out of the policy's reach).
  DescribeSecret, GetResourcePolicy (plan refresh) and PutResourcePolicy (CI apply writes the policy) stay open.
- **Tests:** `tools/terraform/tests/test_secret_read_guards.py` (offline text checks, 18 tests; the review fix added
  `EcosystemGuardedSecretsTest`: the shared list, both new Denies, and no Terraform read under the two prefixes), run by
  `alb-rule-order.yml` (its trigger now also covers `modules/ecs/**` and `modules/elasticache/**`) and by
  `tf-plan-guard-test.yml` (whole folder). Includes a guard that every secret-version resource / data source in the
  root and modules is in `tf_plan_secret_arns`.

## Changed (vs. the brief)

- Apply boundary deny is "everything but the Terraform read list", not a prefix list (above).
- `aa-crm/*` added to the CIS Deny (not in the brief; the CRM M2M client secret, never read by CIS).
- No `aa-llm/*` entry denied for CIS: every `aa-llm/*` secret is by design a CIS gateway secret.
- Not done (out of scope): narrowing the CIS `GetSecretValue` Allow from `*` to an ARN allow-list (F1 step 3,
  before go-live); denying the E2E staff credentials `aa-cis/dev/e2e-test-*` to the CIS role (an ECS-exec script,
  `scripts/create_staff_user.py --password-from-secret`, still reads one through this role: 19/10).

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
- No EventBridge alert on these keys: the App key is read ~130 times a day by as-app.sh; an alert on every read is
  noise. A rule on reads by any other principal (denied attempts) is a cheap follow-up.

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
- **Residual, by design: the apply role keeps the master DSN through DB Migrate.** It may PassRole the DB migrator
  task role (bounded, but its identity policy reads the master and `aa-cis/<env>/db-migrator`) and run the DB Migrate
  task, so a main-branch change or an apply-role session can still reach the master database through that task.
  That is the job DB Migrate exists for; closing it needs GitHub environment protection on Infra `prod` (TL-7) and a
  separate migrate role, not a boundary Deny. The same holds for every other app DSN a bounded role reads (the apply
  role can write that role's policy and run it): the new Denies protect only the ecosystem ops and identity secrets,
  which no workload needs.
- **Plan after the review fix (expected, not re-run here):** the same 2 to add, with
  `aws_iam_policy.workload_boundary` as a third in-place update (+1 statement). Boundary sizes stay under 6,144.
  Order (local, MFA): one local run of the whole plan; the two boundary updates and the two new resource policies
  land together, nothing is left for CI.
- Not touched: GitHub environment rules on Infra `prod` (TL-7, pending the tech lead), the agent's own role (N7).
