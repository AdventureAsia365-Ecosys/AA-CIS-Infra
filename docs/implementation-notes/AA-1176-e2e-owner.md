# AA-1176 — Dev-only E2E owner (root ADR 0006a A10h), AA-CIS-Infra part

Tech lead decision S288: the orchestrating agent signs in as "an admin like me" (never the business owner) for the
owner-only live checks: staff view-as in CIS and Booking, Platform › Compliance › Refresh, Staff › Add, a Booking sale
exception on a synthetic plan. One new WORKFORCE address, `e2e-owner@e2e-mail.lumiguides.it.com`. The app sides are in
AA-CIS-App, AA-Booking and AA-Partner `docs/implementation-notes/AA-1176-e2e-owner.md`.

## Decisions
- **Trigger entry.** `workforce.E2E_OWNER_TEST_STAFF_EMAIL` / `_GROUPS = ("booking-admin", "cis-admin")`, one entry in
  `E2E_DEV_ONLY_TEST_STAFF`, no extra group set. The tech lead's real set is `cis-admin, booking-admin,
  crm-platform-admin` (root access review S283 §5 W2); the E2E owner mirrors it without the CRM platform group (the
  Refresh evidence only needs a `cis-admin` OPS reader in the CRM). The pre token trigger refuses any other set.
- **No `identity.tf` change.** The Dev-only flag `E2E_DEV_ONLY_STAFF_ENABLED` (`var.environment == "dev"`) and the
  `lifecycle.precondition` on `aws_lambda_function.identity_trigger` (A10b) already gate every entry of the map; a test
  pins the new entry inside that map, not in the always-on `E2E_TEST_STAFF`.
- **Mailbox.** `local.e2e_mail_owner_recipient` appended to `aws_ses_receipt_rule.e2e_cognito_admin` (prefix
  `inbound-admin/`, object reads denied to everyone but the MFA admin role by `DenyAdminPrefixReadsExceptMfaAdmin`).
  Never on `e2e_cognito` (CI-readable `inbound/`). No bucket statement changes: same prefix. That read being MFA-admin
  only is what lets CIS, Booking and the CRM exempt this administrator from their MFA switches.
- **Cognito user.** `tools/identity/crm_dev_identity.py e2e-owner [--apply]`: AdminCreateUser with SUPPRESS,
  `email_verified`, no password, name "E2E owner", then the two groups; refuses any other group and any env but dev.
- **Directory row + owner marker: a master run-script, not a migration seed.** `db/scripts/aa1176_e2e_owner_row.py`
  (clone of the S287 `aa1155_custom_maker_grants.py` pattern), merged with `READ_ONLY = True`. A seed would put an owner
  row on every future environment; the script runs on Dev only, by hand, reviewed. It inserts the row when missing
  (Staff page shape), upserts the Booking `admin` grant, sets `is_owner` with an UPDATE that repeats the CIS 473 scope
  (admin, no custom role, no password, not the business owner, active), audits each write (actor
  `script:db-migrate-aa1176`, `source: db-script:aa1176`, `e2e_owner: true`), and refuses two rows, a business owner,
  another role, a custom role, a password, a disabled row (a person re-enables it) or a CRM role. `REMOVE = True` is the
  removal mode (marker off, row disabled, grant deleted, audited). It refuses to run before CIS 473 is applied.

## Changed
- `accounts/aa365/lambda_src/identity_triggers/workforce.py` (+ docstring A10h) and its tests.
- `accounts/aa365/e2e_mailbox.tf` (one local, the admin rule's recipients, header comment) and its tests.
- `tools/identity/crm_dev_identity.py` (`e2e-owner`), its tests and `tools/identity/README.md`.
- `db/scripts/aa1176_e2e_owner_row.py`, `db/tests/test_aa1176_e2e_owner_row.py`.
- `CONTEXT.md` (mailbox line).

## Tradeoffs
- An owner-level identity exempt from the MFA switches is the real widening. It holds because: the token exists only on
  Dev (flag + precondition, and CIS / Booking / CRM each refuse it outside dev), its groups are exact, its code is
  readable only by the MFA admin role, and the row can never be the business owner (CHECK + code).
- The run-script does not disable the Cognito user in REMOVE mode (no Cognito access from the migrator task): the CIS
  Staff page Disable does both at once and is the first removal step.

## Should know — expected Terraform plan (Terraform Plan on main, then Apply)
Only these changes; anything else: stop.
- the 4 identity trigger Lambdas get a new version (one `archive_file` hash change) and their 4 `live` aliases move;
- `aws_ses_receipt_rule.e2e_cognito_admin[0]` updated in place: one more recipient.
Verify after apply:
`aws ses describe-receipt-rule --rule-set-name aa-cis-dev-e2e --rule-name e2e-cognito-admin --profile aa365-admin --region us-west-1`
(the recipient list holds `e2e-owner@…`; `e2e-cognito` does not).

## Should know — live order
1. CIS 473 applied (Infra copy PR → Migration Apply → `bot/db-schema-reference` PR merged).
2. CIS, Booking and Partner code PRs merged and deployed (their refusals and exemptions live) BEFORE step 3.
3. This PR merged, Terraform Plan read, Terraform Apply.
4. `crm_dev_identity.py e2e-owner --env dev` dry run, then `--apply` (exported credentials, `--profile ""`,
   `</dev/null`; check the account first).
5. DB Migrate `mode=run-script script=aa1176_e2e_owner_row` (DRY RUN), review, one-line PR `READ_ONLY = False`,
   dispatch again: expect `is_owner` true, business owner false, Booking grant admin, audit rows, identity not linked.
6. CIS sign-in first (AA-CIS-App `tests/e2e/admin-evidence/owner-live.spec.ts`, `E2EOWNER=1`), then Booking.

## Removal
- At once: a CIS owner disables the row on Platform › Staff (AdminDisableUser + global sign-out); or the run-script's
  REMOVE mode.
- With the A10 family (AA-1054): the trigger entry, the recipient, the tool command, the run-script, the app constants
  and guards, the row (DRY RUN procedure) and the Cognito user, a CIS migration restoring the 462 CHECK, Terraform
  Apply.
