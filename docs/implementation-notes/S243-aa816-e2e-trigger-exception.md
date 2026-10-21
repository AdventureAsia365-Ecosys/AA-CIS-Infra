# AA-816 — temporary E2E test address in the WORKFORCE triggers (S243)

Decision (Nghiệp, 19/10/2026, option B): the Cognito email-code E2E staff user is `e2e@e2e-mail.lumiguides.it.com`,
the SES inbound test mailbox itself (`e2e_mailbox.tf`), instead of a company address forwarded to it. Temporary:
removed when the E2E work is finished. Root ADR 0006a records it; CIS holds the same rule (migration 250,
`staff_directory.E2E_TEST_STAFF_EMAIL`).

## Decisions

- **Code constant, not a Lambda env var.** `workforce.E2E_TEST_STAFF_EMAIL` / `E2E_TEST_STAFF_GROUPS`. An env var
  would let a Terraform variable widen the exception without touching reviewed code; no `identity.tf` change.
- **Pre sign-up:** the exact address (after lower-casing) is allowed for `PreSignUp_AdminCreateUser` only; self
  sign-up and federated sources stay denied. `ALLOWED_EMAIL_DOMAIN` unset still denies everything.
- **Pre token:** the address must still be verified, and its staff groups (after the STAFF_GROUPS filter) must be
  exactly `["cis-reviewer"]`. Any other staff group (cis-admin, cis-content, any booking-*) DENIES the token
  instead of stripping it: a wider group means the directory rule was bypassed. Each issue logs
  `workforce_e2e_test_token_issued` (no alarm; it is expected on every E2E run).

## Changed

- `accounts/aa365/lambda_src/identity_triggers/workforce.py` (+ docstring), tests in `test_workforce.py`.

## Should know

- All four trigger Lambdas share one archive, so the Terraform plan publishes a new version behind each `live`
  alias (code change in the WORKFORCE module only). Apply via the Terraform Apply workflow after merge.
- Removal: delete the constant, the two branches and the tests, then Terraform Apply; do it after the E2E user is
  deleted from the pool.
- **Removed (root ADR 0006a A10, `docs/implementation-notes/AA-816-a10-removal.md`).** The constant, both branches and
  the E2E tests are gone (#215 reverted in `workforce.py`); the tests now deny the address at
  `PreSignUp_AdminCreateUser` and at pre token. The E2E user is the ordinary reviewer `e2e-cognito@adventure.asia`.
