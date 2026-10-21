# AA-816 — remove the temporary E2E staff exception, Infra side (root ADR 0006a A10)

Scope: the A10 part of AA-816 only (S2, the API legacy flag, stays open with AA-911). The CIS side is AA-CIS-App
`docs/implementation-notes/AA-816-a10-removal.md` (PR-A1 test-only switch of the E2E user, PR-A2 code + migration
252). This repo has two PRs:

- **I1a** (`fix/aa-816-remove-e2e-trigger-exception`, this branch): trigger revert, delete script (DRY RUN), the
  aa680 constant, the `e2e_mailbox.tf` comments. It does not depend on CIS 252 and merges right after H3/H4.
- **I1b** (later, after CIS PR-A2 is merged): `db/migrations/cis/252_admin_users_e2e_exception_removed.sql`, a
  byte-identical copy (Copy Guard compares against CIS main).

## Decisions

- **Revert, not rewrite.** The `workforce.py` hunks of #215 are reverted as they were (constants, the pre sign-up
  branch, the pre token branch, the docstring paragraph). Nothing else touched those lines after #215.
- **Negative tests replace the E2E tests.** The exact old address and its case/whitespace variants are denied at
  `PreSignUp_AdminCreateUser` (logged reason "admin-created user outside the staff domain") and at pre token for
  both token sources ("email outside the staff domain"), even with exactly `cis-reviewer`. The new E2E user
  `e2e-cognito@adventure.asia` is an ordinary reviewer and gets a token like any staff member.
- **No preventive pin on the new account.** A trigger rule "this address may only be cis-reviewer" would bring the
  special case back. The guard is detective (the CIS E2E spec fails if the account is ever more than a reviewer) plus
  the ADR policy line. A preventive guard is Nghiệp's call (open question).
- **`tls_policy` stays `Require`.** The mail now arrives through the adventure.asia forwarder (MailChannels). If the
  H1 test send shows the relay without TLS, `Optional` is Nghiệp's call (a weaker rule; codes are single-use).
- **Delete script: guards from the catalog, not a fixed list.** `aa816_delete_e2e_test_staff.py` reads every FK onto
  `shared.admin_users` from `pg_constraint` at run time and counts rows for the target id; a new FK added later is
  picked up. A key with ON DELETE CASCADE / SET NULL / SET DEFAULT on a table whose row security could hide rows
  from the master session is refused (its count could be wrong and the delete would change uncounted rows). Today
  `generated_content.reviewed_by` and `raw_tours.reviewed_by` are RLS + FORCE but NO ACTION, so a hidden reference
  would make the DELETE itself fail; `staff_app_grant` is CASCADE but has no RLS.
- **Row guards:** exactly one row with `lower(btrim(email))` = the old address; inactive (H3 done), reviewer, not an
  owner, no password hash, 0 `staff_app_grant` rows. The Cognito link (`cognito_sub`) is reported, not refused: the
  user did sign in, and the script cannot see Cognito. H4 (delete the Cognito user) is checked by the orchestrator
  with `list-users`.
- **Apply transaction:** `SET LOCAL lock_timeout 5s` → `SELECT … FOR UPDATE OF a` → re-check every guard → `DELETE`
  (repeats the guards in its WHERE) with `DELETE 1` asserted → re-count the address (0) → the `staff.deleted` audit
  row LAST (the `audit_log_chain` BEFORE INSERT trigger takes a lock; same order as #224). Any failure rolls back.
- **Audit rows are kept.** `acp_shared.audit_log` has no FK to the row and is append-only (triggers); the script
  reports how many rows name it (`audit_rows_kept`).
- **No RDS snapshot (destructive-ops step 2, written decision).** One test row; the audit `details.restore`
  (username, role, created_at, owner/password flags) is the restore record. Restore = re-insert from it, only
  together with migration 250, the old code and the old trigger.
- **Merged as DRY RUN** (`READ_ONLY = True`, the runner then opens a read-only session). The apply is a one-line
  follow-up PR `READ_ONLY = False` (the aa680_link pattern), after Nghiệp sees the DRY RUN counts.
- **aa680 check:** `E2E_EMAIL` is now `e2e-cognito@adventure.asia`, so the read-only Booking evidence follows the new
  user.

## Changed

- `accounts/aa365/lambda_src/identity_triggers/workforce.py`: #215 reverted.
- `accounts/aa365/lambda_src/identity_triggers_tests/test_workforce.py`: the E2E block replaced by negative tests.
- `accounts/aa365/e2e_mailbox.tf`: comments only (header history line; the `tls_policy` comment no longer says
  "no forwarder any more"). No resource change.
- `db/scripts/aa816_delete_e2e_test_staff.py` (new) + `db/tests/test_aa816_delete_e2e_test_staff.py` (new) +
  `db/scripts/README.md` entry.
- `db/scripts/aa680_staff_users_readonly_check.py`: `E2E_EMAIL` and its comment.
- `docs/implementation-notes/S243-aa816-e2e-trigger-exception.md` and `S243-aa816-e2e-mailbox.md`: closing notes.

## Tradeoffs

- **Detective, not preventive.** Without the trigger pin, an owner could widen the E2E account; the next E2E run
  fails, but until then a CI-readable mailbox holds codes for a wider account. Accepted to keep no special case in
  production code; the ADR policy line says never give this account another role.
- **The RLS refusal rule is conservative.** It may refuse a future CASCADE key on an RLS table even when nothing
  references the row; then the script needs a reviewed change, which is the right default for a delete.

## Should know

- **Order (keep H4, I1a Apply and the delete close together):**
  1. H3 disable the old row on the Staff page (never re-enable or sync it: `enable_staff` does not re-validate the
     e-mail and `sync_staff` would recreate the Cognito user while the triggers still accept it).
  2. H4 delete the old Cognito user (MFA), verify `list-users --filter 'email = "e2e@e2e-mail.lumiguides.it.com"'`
     is empty.
  3. Merge I1a, Terraform Plan then Apply from main (lesson 44: never from a worktree). Expect only the four
     identity-trigger Lambda versions and their `live` aliases (one shared archive).
  4. DB Migrate `mode=run-script`, `script=db/scripts/aa816_delete_e2e_test_staff.py` (DRY RUN): expect
     `outcome=would_delete`, `candidates=1`, every reference 0. Show Nghiệp.
  5. Flip PR `READ_ONLY = False`, merge, dispatch again (job tables idle; not near the 06:15 UTC reconcile; not
     within minutes of the H2 invite job). Evidence: `deleted=1`, `remaining_rows=0`, `audit_row_id`.
  6. After CIS PR-A2 is merged: I1b (the 252 copy), DB Migrate `check` then `apply`
     `cis/252_admin_users_e2e_exception_removed.sql`; 252 RAISEs if step 5 did not happen (intended).
  7. Run `aa680_staff_users_readonly_check.py` after the next E2E run: `e2e_has_no_booking_row=true`.
- **Local runs:**
  - `python3 -m pytest -p no:cacheprovider lambda_src/identity_triggers_tests` (from `accounts/aa365`): 73 passed.
  - `python3 -m unittest discover -s db/tests -p "test_aa816_delete*.py"`: 19 passed; aa680 check tests: 5 passed.
  - `python3 db/run_migration.py --inspect-script db/scripts/aa816_delete_e2e_test_staff.py`: no errors.
  - The script against a local Postgres 16 with every CIS migration, inside a rolled-back transaction (CHECK
    dropped to insert the old row): DRY RUN `would_delete` with the four live FKs at 0, apply `deleted=1` +
    `staff.deleted` audit row, and a refusal when the row has a grant.
  - `terraform fmt -check accounts/aa365/e2e_mailbox.tf`: clean.
