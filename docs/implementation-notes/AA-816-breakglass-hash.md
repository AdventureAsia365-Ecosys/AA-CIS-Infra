# AA-816 checklist B6 (N-B) — clear the break-glass row's legacy password hash (S244)

Script: `db/scripts/aa816_clear_breakglass_password.py`, run once by DB Migrate `mode=run-script` (as the RDS
master). Plan: root `docs/audits/2026-10-19-S244-aa816-cutover/cutover-prep.md`, checklist B6, decision N-B
(Nghiệp, S244: reviewed run-script, one row, audited in the same transaction). Design: root ADR 0006a A4
("Directory row: break-glass needs an active `admin_users` row (role `admin`, `password_hash` NULL)").

## Decisions

- **Which row.** The same rule as the CIS staff directory's `is_breakglass()` (AA-CIS-App
  `api/services/staff_directory.py`): `lower(btrim(username)) = 'admin'` OR `lower(btrim(email))` in
  {`admin@adventure.asia`, `breakglass@adventure.asia`}. The constants are copied (a db/scripts file may not import
  app code). The script refuses unless exactly ONE row matches, and that row is both: username `admin` AND an
  email from that set. So a second row carrying a break-glass address, a renamed row or a row without an email
  stops the run with nothing written (exit 13, `SCRIPT REFUSED <reason>`).
- **Not refused, only reported:** `is_active`, `role_is_admin`, `is_owner`, `linked` (cognito_sub set). The plan
  runs B6 after B3 (the managed-login sign-in links the row by email), but clearing the hash does not depend on
  the link: a NULL hash only closes the legacy login (C1 answers 401 for NULL). The report lets the reviewer see
  the row is the expected one (active admin, not an owner).
- **Audit row** in `acp_shared.audit_log`, same shape as the staff directory writer (`write_audit_log`):
  `tenant_id` NULL, `resource_type = 'admin_user'`, `resource_id` = the row id, `actor_type`/`http_method`/`route`/
  `status` NULL. `action = 'staff.legacy_password_cleared'` (a new `staff.*` value next to `staff.disabled` etc.;
  the directory UI never writes the break-glass row, so no existing action fits). `actor = 'script:aa816_clear_
  breakglass_password'`, the convention of the other run-script that writes audit rows (`aa680_link_staff_cognito`,
  `script:<name>`), instead of the `x1-runscript:…` form suggested in the brief. `details`:
  `{"has_password": {"before": true, "after": false}, "username": "admin", "via": "db-migrate run-script",
  "issue": "AA-816", "step": "B6 / N-B"}` — never the hash.
- **Order inside the transaction:** lock the candidate rows (`FOR UPDATE`), check, `UPDATE … WHERE id = $1 AND
  password_hash IS NOT NULL` (expects `UPDATE 1`), re-read `password_hash IS NOT NULL` for the "after" boolean,
  then the audit INSERT `RETURNING id` **last** (the audit chain trigger takes a transaction-scoped lock; QRY-4 in
  `write_audit_log`'s docstring). `SET LOCAL lock_timeout = '5s'`.
- **Idempotent:** a row that already has a NULL hash prints `outcome=already_null` and writes nothing (no UPDATE,
  no audit row). A concurrent change between the read and the UPDATE (`UPDATE 0`) raises inside the transaction,
  so it rolls back and the run fails rather than writing an audit row for a change that did not happen.
- **Mode:** merged as `READ_ONLY = False` (apply). The file also supports `READ_ONLY = True` (DRY RUN: same
  checks and the same report, `outcome=would_clear`, no lock, no write) and a local `--apply` CLI like
  `aa680_link_staff_cognito.py`.

## Changed

- New file `db/scripts/aa816_clear_breakglass_password.py`, test `db/tests/test_aa816_clear_breakglass_password.py`,
  one paragraph in `db/scripts/README.md`. No runner, workflow or Terraform change.

## Tradeoffs

- **Apply as merged vs DRY RUN first** (db/scripts/README: destructive changes follow the DRY RUN procedure, "a
  dry-run script first, then the change as a separate reviewed script or a flag in the same PR"). One field of one
  row is changed, the script itself refuses on anything but the exact break-glass row, and the target state is what
  ADR 0006a A4 already requires. A dry-run dispatch would print the same booleans the apply prints before it
  writes. So it ships as apply; flip to `READ_ONLY = True` in this PR if the reviewer wants the DRY RUN dispatch
  first (one more PR to flip back).
- **No RDS snapshot.** The only thing lost is the hash of a password the plan retires (B7 rotates the break-glass
  password; the legacy login is being closed). Restoring it would be the wrong fix; a rollback, if ever needed, is a
  new password through the normal tools, not this hash.
- **Refuse on email mismatch** (stricter than `is_breakglass`, which accepts username OR email): costs a follow-up
  PR if the row's email is unexpected, but never clears the hash of a row that is only half like the break-glass one.

## Should know

- Runs as the master, so `acp_shared.audit_log`'s append-only triggers (CIS 248) do not matter here: the script
  only INSERTs. The chain columns are set by the BEFORE INSERT trigger.
- Prints only: `SCRIPT … mode=…`, then one `SCRIPT report {...}` JSON line with `candidates`, `row_found`,
  `outcome`, `had_hash_before`, `has_hash_after`, `is_active`, `role_is_admin`, `is_owner`, `linked`,
  `audit_row_id`. No hash, no email, no DSN.
- Verify after the run (checklist B6): the report shows `outcome=cleared`, `had_hash_before=true`,
  `has_hash_after=false` and an `audit_row_id`. A second dispatch shows `outcome=already_null`, `audit_row_id=null`.
- Tested (S244) against a throwaway local PostgreSQL 16 with the two tables shaped as in the schema reference:
  DRY RUN → `would_clear`; apply → `cleared` + 1 audit row (other rows untouched); apply again → `already_null`, no
  new audit row; a second row with a break-glass e-mail → `REFUSED … found 2`, exit 1, nothing written. Unit tests
  with a fake connection in `db/tests/test_aa816_clear_breakglass_password.py`.
- After X1 S22 (task `DATABASE_URL` = `db_migrator`) run-script exits 8 until the runner change lands; run it
  before S22 or after that change.
