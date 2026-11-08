# AA-1004, lane l9 (S273): organization admin role, Transitional OU, move readiness checks

Agent part of the Billing Transfer plan (S271): the nonprod account (acc2) moves from the reseller's organization into
the AA organization on 01/12/2026; this slice is due before 20/11. Nothing here is applied by the lane.

## Decisions

- **Two-hop admin path, not "trust the management account".** `OrganizationAccountAccessRole` in acc2 trusts only
  the named role `aa-org-member-access` in the management account, which trusts only Identity Center `AA-Admin`
  sessions (`aws:PrincipalArn` ArnLike). Reasons: the static trust inventory (S271 guard G13) never acknowledges an
  account root, by design (`test_iam_trust_inventory.py`); a named role keeps the CI roles and any future permission
  set of the management account out; the AWS-documented `:root` + `aws:PrincipalArn` form would need that guard
  loosened. Cost: a console "switch role" cannot chain two hops; the console path into acc2 after the move is the
  Identity Center assignment (`AA-Admin` on aa-nonprod), the chained role is the CLI / bootstrap path.
- **Organization condition, no external ID.** `aws:PrincipalOrgID` = the AA organization on the acc2 trust. AWS
  positions external IDs against the confused-deputy problem of third parties; both accounts are ours. MFA: enforced by
  Identity Center at every sign-in; `aws:MultiFactorAuthPresent` is absent from Identity Center (SAML) and chained
  sessions, so it cannot be a trust condition.
- **AWS role name kept** (`OrganizationAccountAccessRole`): SCP 2 already exempts exactly that name, and the prod
  account created by the organization gets the same name from AWS.
- **Permissions:** `AdministratorAccess` (convention; it is the bootstrap / break-glass path, e.g. deleting the
  reseller's Identity Center role), plus an inline deny on IAM users, access keys, console passwords and
  service-specific credentials. Exclusive attachment resources so an adopted role loses every other policy.
  1-hour sessions. No `aa-workload-boundary` (it denies IAM and organization writes, the role's whole purpose):
  documented exception to "every new role carries it".
- **No ID in the repo.** The two inputs come from `TF_VAR_org_management_account_id` / `TF_VAR_org_management_org_id`:
  repo secrets `MGMT_ACCOUNT_ID` (exists) and `MGMT_ORG_ID` (new) in the three Terraform workflows, the `aa-mgmt`
  profile locally. With the role enabled a plan without them fails on variable validation (never plans a destroy);
  `prevent_destroy` on top.
- **Transitional OU gets SCP 1 only.** SCP 1 (deny leave / close) is never called by a workload; the rollback stays
  open from the management side (`RemoveAccountFromOrganization` ignores SCPs). SCP 2 is held back: it would block the
  local MFA bootstrap applies of `accounts/aa365/cicd*.tf` (the `aa365-admin` role is not exempt) and the trail edits
  outside the CI apply role. SCP 3 is held back until a region inventory is clean. Existing attachment keys unchanged
  (`<policy>:<ou>`), so the plan only adds one attachment.
- **Adoption switch.** `org_access_adopt_existing_role` imports a pre-existing role of that name (runbook check 1.5);
  the S256 Access Analyzer triage saw no outside trust on such a role, so the default is create.

- **Role disabled in tfvars until the local apply (review fix).** `org_access_role_enabled = false` is committed;
  the tech lead's targeted local apply runs with `-var org_access_role_enabled=true`, then a one-line PR flips the
  tfvars to `true`. Committing `true` first would make every CI apply of `accounts/aa365` plan a role the apply role
  may not write (AccessDenied) for as long as the local apply waits, which can be weeks when the reseller's SCPs hold
  it until the move (runbook check 1.4 / R2). The remaining window (local apply done, flip not merged: CI plans want a
  destroy that `prevent_destroy` refuses) lasts minutes, like the `cicd_db_auto_apply.tf` precedent.
- **Empty string counts as "not set" (review fix).** GitHub passes a missing secret as `""`, not null. Both
  validations treat `null` and `""` alike: allowed while the role is disabled, an error naming the missing secret
  once it is enabled. So the Infra PR's own plan and the nightly drift stay green before `MGMT_ORG_ID` exists; the
  secret is still set before the branch is pushed (live step), and must exist before the flip PR.
- **Broker policy count from plan-time inputs (review fix).** `count` of `aws_iam_role_policy.org_member_access` is
  `length(var.member_accounts) + length(var.org_access_pending_account_ids) > 0`, not the length of the computed
  account list: the ID of an account this root creates (prod) is unknown at plan, and `distinct()` over an unknown
  element makes the whole list unknown ("Invalid count argument" at README §4 apply 5). Reproduced offline with
  `terraform_data` (old form fails, new form plans).

## Changed (vs. the issue / earlier README)

- README §6 used "directly under the root" as the transitional place (no SCP, member could leave). The lane brief asks
  for an OU `Transitional`; accepted: the member-side leave is now denied there, the management-side removal is the
  rollback. `ou = "root"` stays valid for a rollback.
- `org_access_pending_account_ids` (management, tfvars only) lets the path be tested before acc2 joins.
- New repo secret `MGMT_ORG_ID` (Infra) and the root secrets register rows (`MGMT_ACCOUNT_ID`, `MGMT_TFVARS` were
  missing from the register; `MGMT_ORG_ID` planned).

## Tradeoffs

- Creating the role before the move vs. after: before gives the tech lead a tested path on day one; it depends on the
  reseller's SCPs allowing `iam:CreateRole` on that name (runbook 1.4 / R2). If not, the same apply runs while acc2 sits
  in `Transitional`.
- Every local aa365 plan now needs the two `TF_VAR_` values (or fails on validation). Accepted: a silent destroy of
  the organization admin role would be worse; the error message says where to get them.

## Should know

- Applies: management root locally (tech lead, `aa-mgmt`; the CI apply role cannot write IAM roles), then acc2
  targeted locally (`aa365-admin`, `-var org_access_role_enabled=true`, gated on runbook check 1.4), then the one-line
  tfvars flip PR, all in README §6 steps 1-2. CI plans and drift must then show no change.
- acc2's external-access analyzer raises one finding for the new trust: expected, left visible.
- The runbook (`docs/runbooks/org-move-readiness-checks.md`) is read only; `aws iam` reads are hook-blocked for
  subagents, so the orchestrator runs it.
