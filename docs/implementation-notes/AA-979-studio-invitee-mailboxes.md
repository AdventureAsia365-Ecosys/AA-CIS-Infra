# AA-979 — two Content studio invitee mailboxes for the phase 2 re-enrolment E2E

Session S252, agent Claude Code. Branch `chore/e2e-studio-invitee-mailboxes`. Pairs with root ADR 0006a A10b-1 and
the AA-CIS-App branch `feat/a10b-studio-invites-synthetic` (the Dev-only E2E CIS admin may invite on synthetic tenants).

## Decisions

- **Own list, own address shape.** `crm_e2e_users.json` gains `studio_invitees: [{role: viewer}, {role: editor}]`,
  mail `e2e-test-studio-<role>@e2e-mail.<zone>`. Not `"invitee": true` CRM entries: a studio invitee is a CIS tenant
  member with no CRM agency, and the CRM entries are validated against the CRM roles (owner / agent / assistant) and
  the seeder catalogue.
- **Same rule and prefix as the CRM invitee** (`e2e-cognito`, `inbound/`): the invitation mail and nothing else
  lands there; the A10b admin rule and prefix `inbound-admin/` are untouched.
- **`invitee-reset --invitee crm|studio-viewer|studio-editor`**, default `crm` (unchanged behaviour). One studio role per
  run, so resetting the editor before its run keeps the viewer's account and saved credentials (phase 2 step 6 reuse).

## Changed

- `tools/identity/crm_e2e_users.json`, `crm_dev_identity.py` (`StudioInvitee`, `load_studio_invitees`,
  `invitee_emails`, the `--invitee` option), `README.md` row.
- `accounts/aa365/e2e_mailbox.tf`: `local.e2e_studio_invitee_recipients` added to the `e2e-cognito` recipients;
  header comment.
- Tests: `tools/identity/tests/test_crm_dev_identity.py` (studio list, tf wiring, reset per role, default unchanged,
  bad entries); `identity_triggers_tests/test_workforce.py` (WORKFORCE still denies a studio invitee address).

## Tradeoffs

- The CI reader role can read these invitation mails too (same `inbound/` prefix), like the CRM invitee's; the claim
  link is one-time and the tenant is synthetic. Accepted for Dev as for AA-939.

## Should know

- Terraform: one in-place update of `aws_ses_receipt_rule.e2e_cognito` (two recipients added). Cost $0 (a few mails
  a month, 1-day expiry). Apply through Terraform Apply after merge; no bootstrap grant needed (the apply role already
  manages receipt rules).
