# CI role split — cut-over plan (AA-806)

`aa-cis-dev-role` (`accounts/aa365/cicd.tf`) is assumed by AA-CIS-App and AA-CIS-Infra for three
jobs that need very different rights. AA-806 adds one role per job (`accounts/aa365/cicd_split.tf`)
and retires the shared role in a later step.

| Role | Caller (OIDC sub context) | Rights |
|---|---|---|
| `aa-cis-dev-app-deploy` | AA-CIS-App `deploy-dev.yml`, `eval-regression.yml` (`environment:dev`) | push to `aa-cis-dev-*` ECR repos; register revisions of `aa-cis-dev-api` / `aa-cis-dev-worker`; update / describe those two services; list / describe / exec tasks in `aa-cis-dev-cluster`; PassRole on the CIS ECS execution + task roles only. Carries the workload boundary. |
| `aa-cis-infra-tf-plan` | AA-CIS-Infra `terraform-plan.yml` (`pull_request`) | `ReadOnlyAccess` + state lock table + `GetSecretValue` on exactly the secrets Terraform refreshes (`local.tf_plan_secret_arns`: the three `tripplanner/dev/*` secret versions, the two ACP secrets, the admin secret). |
| `aa-cis-infra-tf-apply` | AA-CIS-Infra `terraform-apply.yml`, `db-migrate.yml` (`environment:prod`) | the same managed policies and inline statements as `aa-cis-dev-role`, except that IAM role writes / PassRole / TagRole are scoped to `role/aa-*-dev-*` (+ the legacy `aa-cis-nat-instance-role`), OIDC provider rights are read only, plus `apigateway:SetWebACL`. Capped by `aa-cis-infra-tf-apply-boundary`. |

All three trust the GitHub OIDC provider with `StringEquals` on one exact immutable subject
(org id `276539096`, repo ids `1212291079` App / `1212290412` Infra), same pinning as #95/#99.
A sub carries either the environment or the ref, never both, so "main only" for the `dev` and
`prod` environments is enforced by each environment's deployment-branch rule in the repo settings.

## Boundaries

- `aa-workload-boundary` — for workload and app-deploy roles: allows everything except IAM writes
  (PassRole stays allowed) and `account:*` / `organizations:*`.
- `aa-cis-infra-tf-apply-boundary` — on the apply role:
  - no role create/change/tag/pass outside `aa-*-dev-*` (+ NAT role), so the `aa-cis-infra-tf-*`
    roles and other systems' roles are out of reach;
  - inside the pattern, no write or PassRole at all on `aa-cis-dev-app-deploy` and
    `aa-cis-dev-agent-session`; on the legacy `aa-cis-dev-role` only `DeleteRole` /
    `DetachRolePolicy` / `DeleteRolePolicy` (step 3), never PassRole or a trust/policy edit;
  - no OIDC or SAML provider writes (the GitHub OIDC provider is a bootstrap object);
  - `CreateRole` / `PutRolePermissionsBoundary` only with `aa-workload-boundary`;
  - no `DeleteRolePermissionsBoundary`, no edits to either boundary policy;
  - no users, access keys, groups, account or organization changes; no `sts:AssumeRole`.
  - Phase 3 switch `var.tf_apply_require_boundary_on_role_policy_writes` also requires the workload
    boundary on `Put/Delete/Attach/DetachRolePolicy`.

Consequence for every later PR: **a new `aws_iam_role` must set
`permissions_boundary = aws_iam_policy.workload_boundary.arn`**, or the CI apply fails with
AccessDenied on `iam:CreateRole`. The same applies when a change forces an existing role to be
replaced.

Bootstrap objects — the apply role cannot change them, so changes are applied locally by Nghiệp
with the MFA admin profile: the three new roles, both boundary policies, the GitHub OIDC provider,
`aa-cis-dev-agent-session`, and `aa-cis-dev-role` (until step 3 removes it; note that
`local.cicd_inline_statements` feeds both the legacy role and the apply role, so editing it is a
local apply too), plus the plan role's secret list (`local.tf_plan_secret_arns` — a new
`aws_secretsmanager_secret_version` has to be added there or the next plan fails on refresh).

## Steps

1. **Bootstrap (this PR).** Merge after CI Plan is green (CI still uses `aa-cis-dev-role`). Apply **locally with the admin profile**, not via `terraform-apply.yml`: the old role
   has no `iam:CreatePolicy` and no `iam:TagRole` for the new names, so a CI apply fails.
   ```
   export $(aws configure export-credentials --profile aa365-admin --format env | xargs) && unset AWS_PROFILE
   terraform -chdir=accounts/aa365 plan -out=aa806.tfplan
   terraform -chdir=accounts/aa365 apply aa806.tfplan
   ```
   Expected plan — anything else, and any destroy of a real resource, means stop:
   - **create** everything in `cicd_split.tf`: `aws_iam_policy.workload_boundary`,
     `aws_iam_policy.tf_apply_boundary`, `aws_iam_role.cis_app_deploy` + `aws_iam_role_policy.cis_app_deploy`,
     `aws_iam_role.tf_plan` + `aws_iam_role_policy_attachment.tf_plan_readonly` +
     `aws_iam_role_policy.tf_plan`, `aws_iam_role.tf_apply` + the 10
     `aws_iam_role_policy_attachment.tf_apply_managed[...]` + `aws_iam_role_policy.tf_apply`;
   - **create** `aws_apigatewayv2_route.tripplanner_narrate`;
   - **update in place** `aws_iam_role_policy.cicd_inline` (+ `IAMPolicyRead`) and
     `aws_apigatewayv2_stage.tripplanner` (throttle settings);
   - **replace** `time_sleep.wait_for_iam_propagation` (its trigger hashes `cicd_inline.policy`;
     a 15 s sleep, no real resource).
2. **Switch the workflows** (secrets only, no code change needed if the names stay):
   - AA-CIS-Infra: `terraform-plan.yml` reads `secrets.AWS_ROLE_ARN` with no environment, so it uses
     the repo-level secret → set it to `aa-cis-infra-tf-plan`. `terraform-apply.yml` and
     `db-migrate.yml` run in `prod` → add an environment-level `AWS_ROLE_ARN` on `prod` =
     `aa-cis-infra-tf-apply` (an environment secret overrides the repo secret of the same name).
   - AA-CIS-App: set `AWS_ROLE_ARN` in the `dev` environment (or repo level, whichever exists today)
     to `aa-cis-dev-app-deploy`.
   - Prove each path once: a no-op Infra PR (plan green), `terraform-apply.yml` dispatch ("No
     changes"), `db-migrate.yml` in `check` mode, an App deploy (rollout COMPLETED, api + worker on
     one SHA) and, if needed, `eval-regression.yml` (costs LLM money — only with Nghiệp's OK).
   - Rollback: point the secret back at `aa-cis-dev-role` (still present and trusted).
3. **Retire `aa-cis-dev-role`** in a separate PR once step 2 has run green for a few days: remove
   `aws_iam_role.cicd`, its attachments and inline policy, and the `time_sleep` trigger that hashes
   it (`observability.tf`; re-point it at `aws_iam_role_policy.tf_apply`). Keep the
   `local.cicd_inline_statements` list (the apply role uses it). CloudTrail check before removing:
   no `AssumeRoleWithWebIdentity` on `aa-cis-dev-role` since the switch.
4. **Boundary on existing roles** (separate PR): add
   `permissions_boundary = aws_iam_policy.workload_boundary.arn` to every `aa-*-dev-*` workload role
   (ECS task/execution, Lambda exec, scheduler, flow logs, API GW CloudWatch, Booking/TripPlanner
   deploy roles, agent session). Then set `tf_apply_require_boundary_on_role_policy_writes = true`.
   Only steps 3 + 4 together close the escalation path below.

## Residual risk until step 4

**The apply role can still escalate through IAM.** Every `aa-*-dev-*` workload role except the
bootstrap ones has no boundary yet, and the apply role may rewrite its inline policy, attachments
or trust, then `iam:PassRole` it to something it can start (it has `AWSLambda_FullAccess` /
`AmazonECS_FullAccess`; DB Migrate already runs ECS tasks with command overrides). Example: put
`iam:*` on `aa-cis-dev-ecs-task-role`, run a task with it, and that task can remove the apply
role's boundary. The `sts:AssumeRole` deny does not stop this — no AssumeRole call is involved.
What the boundary does close now: the legacy role, the app deploy and agent session roles, the
`aa-cis-infra-tf-*` roles, the boundary policies, the OIDC provider, users/keys and other systems'
roles.

The mitigation until then is procedural: the apply role only runs from the `prod` environment
(main + required reviewer), so this needs a reviewed, merged Terraform change. Review every IAM
policy/trust diff in a PR with that in mind.

After steps 3 + 4 + phase 3: every role the apply role can write or pass carries the workload
boundary (no IAM writes), and policy writes on unbounded roles are denied. `UpdateAssumeRolePolicy`
and `PassRole` cannot be conditioned on `iam:PermissionsBoundary` (AWS does not set that key for
them), so they stay name-scoped only; with every role bounded, re-trusting or passing one yields at
most workload-boundary rights.

## Residual risk — plan role

`aa-cis-infra-tf-plan` is assumed by `pull_request` runs, and a PR can edit
`terraform-plan.yml` itself, so any collaborator with push access to a branch of AA-CIS-Infra can
run arbitrary AWS calls as the plan role: read everything `ReadOnlyAccess` covers (including S3
objects such as the Terraform state, which holds the TripPlanner API key and other values) and the
secret values in `local.tf_plan_secret_arns` (including the admin secret). This is the same
exposure as today's `aa-cis-dev-role` (which is far broader) and is not a regression. It is narrowed
to the secrets Terraform actually reads — the RDS DSN, JWT and OpenAI secrets are no longer
readable from a PR. Further hardening, if wanted: run plan only after a label / from a protected
environment, or move state-only secrets out of the state file.
