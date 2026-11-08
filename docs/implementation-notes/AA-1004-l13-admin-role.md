# AA-1004 lane l13 (S273): the MFA admin role in Terraform

The tech lead's CLI profiles `aa365-admin` and `default` assumed a role made by hand on 09/07/2026
(`nghiep-admin-8h-session`), outside Terraform. This lane replaces it with `nghiep-admin-12h` in
`accounts/aa365/admin_role.tf` and moves every policy that names "the MFA admin role" onto one list.

## Decisions

- **Same shape as the hand-made role.** Trust: the IAM user `nghiep-admin` of this account, `sts:AssumeRole`
  only, `aws:MultiFactorAuthPresent = true`. Max session 43200 s (12 h). Managed policies `AdministratorAccess`,
  `job-function/Billing`, `AWSBillingConductorFullAccess`; no inline policy. Values come from the lane brief
  (S273 inventory); `find_role_refs.sh` (orchestrator, read-only) prints the parity line for both roles so the
  orchestrator can compare them before the switch.
- **The trust names the user ARN, not `:root`.** Same-account trust that names the principal directly is enough
  on its own; a `:root` trust would also need an identity policy on the user (lesson AA-730, S226).
- **Role name = `var.identity_breakglass_admin_role_name`** (default changed to `nghiep-admin-12h`). The variable
  already feeds every admin exception, so the role and the policies cannot drift apart.
- **One list, `local.id_admin_role_arns`** (`identity_alerts.tf`): the Terraform role first, then
  `var.identity_admin_role_legacy_names`. The break-glass secret policy, the two ops secret policies
  (`ops_secret_guard.tf`) and both E2E mail bucket statements use it. PR 1 keeps the hand-made name in the legacy
  list so the profile switch cannot lock anyone out; PR 2 removes the variable.
- **No permissions boundary, prevent_destroy.** It is the account administrator; the workload boundary would cut
  it down. `prevent_destroy` makes any plan that deletes or replaces it fail.
- **Tags:** `merge(local.shared_tags, { Component = "security", Issue = "AA-1004" })`, like the other security
  resources of the root (S271 standard; `default_tags` give the other six keys).
- **Old role deleted by CLI, not import-then-destroy** (PR 2 runbook): importing a role only to destroy it adds a
  state write and needs `prevent_destroy` off for that address. Detach the three policies, check no instance
  profile and no inline policy, then `delete-role`, all single-line commands.
- **`crm_kms_alarm_check.py`**: the sample admin principal is now a constant `ADMIN_ROLE = "nghiep-admin-12h"`;
  a test pins it to the variable default. The KMS rules match any role except the CRM task role, so the live
  check does not depend on the name; only the sample changes.

## Changed

- New `accounts/aa365/admin_role.tf`; `identity_variables.tf` (new default, two new variables);
  `identity_alerts.tf`, `ops_secret_guard.tf`, `e2e_mailbox.tf` use `local.id_admin_role_arns`.
- Tests: new `tools/terraform/tests/test_aa1004_admin_role.py` (run by `alb-rule-order.yml`), updated
  `test_secret_read_guards.py`, `test_crm_kms_alarm_check.py`, `lambda_src/identity_triggers_tests/test_workforce.py`.
- `CONTEXT.md`: file entry for `admin_role.tf`; the admin role added to the list of local-apply bootstrap objects.
- Root repo (separate PR): ADR 0006a, `docs/security/baseline.md`, skills that said 8 h.

## Tradeoffs

- The policies name the role by ARN string, not `aws_iam_role.admin.arn`: no dependency edge, so a targeted apply
  of the policies works on its own, and a Deny condition with a not-yet-existing ARN is valid.
- Live AWS reads were not possible from the lane (hook). Parity with the hand-made role rests on the brief until
  the orchestrator runs `find_role_refs.sh`.

## Should know

- **LOCAL-APPLY ONLY.** The CI apply role cannot create a role without the workload boundary or outside
  `aa-*-dev-*`, and cannot edit the `aa-ecosys/*` / `aa-identity/*` secret policies. Apply PR 1 locally (targeted)
  **before** merge, so a later CI apply dispatch sees no change for these addresses.
- Expected targeted plan: 4 to add (role + 3 attachments), 4 to change in place (break-glass secret policy, two
  ops secret policies, E2E mail bucket policy), 0 to destroy.
- The profile switch changes `role_arn` (and `duration_seconds 43200`) on `aa365-admin` and `default`; the next
  CLI call asks for a fresh MFA code (new cache key).
- Root `.claude/CLAUDE.md` and the private global CLAUDE.md also say "8h STS cache"; the lane does not edit
  CLAUDE.md files, the orchestrator / tech lead does (wording in the lane result).

## PR 2: clean-up after the switch

Merged only after `aws sts get-caller-identity --profile aa365-admin` and `--profile default` both return an
`assumed-role/nghiep-admin-12h/...` ARN.

- `var.identity_admin_role_legacy_names` removed; `local.id_admin_role_arns = [local.id_breakglass_admin_role_arn]`.
  The test `test_no_legacy_admin_role_left` keeps the old name out of the root.
- The hand-made role is not in Terraform state, so nothing is imported. It is deleted with single-line CLI after the
  targeted local apply of the four policies, never before the profile switch. The commands are in the PR body
  (orchestrator runbook): detach the three managed policies, check that no inline policy and no instance profile
  is left, delete the role, then run the read-only inventory again (only `match=no`, old role `not found`).
