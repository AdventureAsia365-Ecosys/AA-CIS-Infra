# AA-939 follow-up (S263): AdminDeleteUser for the partner-account clean-up

## Decisions
- The CRM task role's partner-pool allow-list (`identity_partner.tf`, `crm_ecs_task_partner_pool`) gains
  `cognito-idp:AdminDeleteUser`, on the partner pool ARN only (root ADR 0006b amendment A1). The app uses it only
  for accounts that never signed in (`FORCE_CHANGE_PASSWORD`) and that no member, live invitation or Content studio
  invitation needs (AA-Partner `app/members/accounts.py`, job `crm_partner_accounts`).
- The partner admin-bypass alert keeps watching `AdminDeleteUser`, but like `AdminCreateUser` it now excludes the CRM
  task role's session issuer only. A person, the e2e identity tool (`crm_dev_identity.py invitee-reset`), any other
  role or a static key still alerts.
- `PARTNER_ACCOUNT_CLEANUP_DRY_RUN = "false"` on the Dev task definition (`crm_app.tf`): the tech lead asked for the
  clean-up (S263). The app default is `true` (counts only); the variable is the kill switch.

## Changed
- `identity_partner.tf`: allow-list + comment, alert rule pattern + description + mail text.
- `crm_app.tf`: one environment variable and its comment.
- `tools/terraform/tests/test_partner_pool_delete_user.py` (new) pins the allow-list, the alert exception and the
  staff-pool Deny of `identity_iam.tf` (untouched); `tf-plan-guard-test.yml` now also triggers on those two files.

## Tradeoffs
- IAM cannot limit `AdminDeleteUser` to `FORCE_CHANGE_PASSWORD` users. The guarantee is in the app (the directory
  re-reads the status right before the delete and refuses anything else) plus the audit; worst case with a
  compromised CRM API is denial of service (accounts deleted), never a takeover (no password, attribute or MFA write).
- Excluding the CRM role from the delete alert removes mail noise for the daily clean-up; the app's audit is the
  detective control for those deletes.

## Should know
- The task definition change reaches the running task on the next CRM deploy after the apply.
- No post-apply probe script pinned the old allow-list; the new offline test is the pin.
