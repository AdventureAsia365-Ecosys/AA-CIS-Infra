# AA-1086 lane l16: the pilot rehearsal agency's E2E users (gap G1, S279)

## Decisions

- Two entries in `tools/identity/crm_e2e_users.json`: `pilot-rehearsal-01` / `owner` and `agent`, the roles AA-Partner's
  seed catalogue gives that agency. One list, as for every CRM E2E user: `e2e-users` creates and enrols them in the
  partner pool and writes `crm/dev/e2e-test-crm/pilot-rehearsal-01-<role>`, and `e2e_mailbox.tf` adds their addresses
  to the receipt rule.
- No new secret shell or IAM change: the tool writes the secrets as the admin, like the existing users; the specs read
  the values from the orchestrator's environment.

## Changed

- `tools/identity/crm_e2e_users.json` (+2 users, a comment), `tools/identity/tests/test_crm_dev_identity.py` (+1 test).

## Tradeoffs

- The receipt rule grows by two recipients (Terraform `accounts/aa365`): the partner pool signs in with password and
  authenticator, so the mail is not needed to sign in, but one list keeps the tool and the rule in step.

## Should know

- Live: Terraform apply of `accounts/aa365` (receipt rule recipients only), then
  `crm_dev_identity.py --pool partner e2e-users --apply --write-secrets`; its output carries the two subjects and the
  seeder command for the AA-Partner `python -m app.seed --apply --agency pilot-rehearsal-01 ...` run.
