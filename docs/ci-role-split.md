# CI role split — cut-over plan (AA-806)

`aa-cis-dev-role` (`accounts/aa365/cicd.tf`) is assumed by AA-CIS-App and AA-CIS-Infra for three
jobs that need very different rights. AA-806 adds one role per job (`accounts/aa365/cicd_split.tf`)
and retires the shared role in a later step.

| Role | Caller (OIDC sub context) | Rights |
|---|---|---|
| `aa-cis-dev-app-deploy` | AA-CIS-App `deploy-dev.yml`, `eval-regression.yml` (`environment:dev`) | push to `aa-cis-dev-*` ECR repos; register revisions of `aa-cis-dev-api` / `aa-cis-dev-worker`; update / describe those two services; list / describe / exec tasks in `aa-cis-dev-cluster`; PassRole on the CIS ECS execution + task roles only. Carries the workload boundary. |
| `aa-cis-infra-tf-plan` | AA-CIS-Infra `terraform-plan.yml` (`pull_request`) | `ReadOnlyAccess` + state lock table + `GetSecretValue` on `aa-cis/dev/*`, `tripplanner/dev/*`, `booking/dev/*` (values Terraform refreshes; they are in the state file anyway). |
| `aa-cis-infra-tf-apply` | AA-CIS-Infra `terraform-apply.yml`, `db-migrate.yml` (`environment:prod`) | the same managed policies and inline statements as `aa-cis-dev-role`, except that IAM role writes / PassRole / TagRole are scoped to `role/aa-*-dev-*` (+ the legacy `aa-cis-nat-instance-role`), plus `apigateway:SetWebACL`. Capped by `aa-cis-infra-tf-apply-boundary`. |

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
  - `CreateRole` / `PutRolePermissionsBoundary` only with `aa-workload-boundary`;
  - no `DeleteRolePermissionsBoundary`, no edits to either boundary policy;
  - no users, access keys, groups, account or organization changes; no `sts:AssumeRole`.
  - Phase 3 switch `var.tf_apply_require_boundary_on_role_policy_writes` also requires the workload
    boundary on `Put/Delete/Attach/DetachRolePolicy`.

Consequence for every later PR: **a new `aws_iam_role` must set
`permissions_boundary = aws_iam_policy.workload_boundary.arn`**, or the CI apply fails with
AccessDenied on `iam:CreateRole`. The same applies when a change forces an existing role to be
replaced.

The three roles and the two boundary policies are bootstrap objects: the apply role cannot change
them. Changes to `cicd_split.tf` are applied locally by Nghiệp with the MFA admin profile.

## Steps

1. **Bootstrap (this PR).** Merge after CI Plan is green (CI still uses `aa-cis-dev-role`; plan
   shows only creates plus the `IAMPolicyRead` statement on `aa-cis-dev-role` and the TripPlanner
   throttle). Apply **locally with the admin profile**, not via `terraform-apply.yml`: the old role
   has no `iam:CreatePolicy` and no `iam:TagRole` for the new names, so a CI apply fails.
   ```
   export $(aws configure export-credentials --profile aa365-admin --format env | xargs) && unset AWS_PROFILE
   terraform -chdir=accounts/aa365 plan -out=aa806.tfplan
   terraform -chdir=accounts/aa365 apply aa806.tfplan
   ```
   Check the plan: no destroy, no change to any existing role except `aa-cis-dev-role`'s inline
   policy (+ `IAMPolicyRead`).
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
   Until this step the apply role can still edit the policies of those roles; the `sts:AssumeRole`
   deny is what stops it from using such an edit to escalate.

## Residual risk until step 4

The apply role can rewrite the inline policy or trust of an existing `aa-*-dev-*` role that has no
boundary. It cannot assume that role itself, but a changed trust could let another principal in.
The apply role only runs from the `prod` environment (main + reviewer), so this needs a reviewed,
merged Terraform change.
