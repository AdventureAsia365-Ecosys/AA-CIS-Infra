# AA-911: bridge-era Booking staff rows (link or deactivate)

Branch `feat/aa-911-bridge-staff-rows`, separate from the callback + DNS PR (`AA-911.md` on that branch). Run after
AA-Booking B2 (bridge verifier removed) is deployed.

## Decisions

- **New one-file script `db/scripts/aa911_bridge_staff_rows.py`** instead of re-running the aa680 link script:
  the aa680 script only links and skips the rest, and Done-when line 4 needs every remaining active unlinked row
  turned off. `ROWS_SQL` and the link rules are copied from aa680 (run-script uploads one file, no imports).
- **Decision per non-`cog:` row:** inactive → no-op; `e2e-*` username → deactivate (linked or not: the E2E user
  must never hold Booking access, ADR 0006a A10); linked to its CIS identity → no-op; linked to another identity →
  reported (`linked_other`), not touched; otherwise link when the CIS row is active, has `cognito_sub` and no other
  row holds the identity, else deactivate with a reason (`no_cis_user`, `cis_inactive`, `cis_not_linked`,
  `cog_row_exists`, `identity_taken`).
- **Guard:** an active unlinked row whose CIS username is not one of the three known on 20/10/2026 (S245 run
  39349316013), or is NULL, fails the run before any write. A person nobody listed must be looked at first.
- **Audit:** `booking.audit_logs` row per write, the aa680 convention: `actor_type='system'`,
  `actor_ref='script:aa911_bridge_staff_rows'`, `entity_type='staff_user'`, `entity_id = cis_user_id::uuid`,
  before / after jsonb, `entity_label` = Booking name, else CIS display name / username. Actions
  `staff.identity_linked` and `staff.deactivated`.
- **Verdict:** `SCRIPT verdict active_unlinked=<n>` over ALL rows (a `cog:` row always has an identity by
  `staff_users_cognito_key_chk`); after apply it is computed inside the same transaction.
- `aa680_staff_users_readonly_check.py` prints the same verdict line, so the Done-when evidence can come from
  either read-only run.

## Changed

- Plan said "deactivate when the row is active" for the non-link case; the script also deactivates a CIS-inactive
  user's row (`cis_inactive`, e.g. `e2e-claude-code-2`, already covered by the e2e rule) instead of linking it.
- `LINK_SQL` also requires `active` (a row deactivated between read and write is not linked).

## Tradeoffs

- Deactivate, never delete: FKs reference `cis_user_id` (trip cases, audit). The row keeps its history.
- A real person whose CIS row has no Cognito identity is deactivated, not linked; on their first Cognito sign-in
  Booking creates a fresh `cog:` row (role from the `booking-*` group). History stays on the old row.

## Should know

- Order: B2 deployed → merge this PR (READ_ONLY) → DB Migrate `mode=run-script` DRY RUN → review the mapping →
  one-line PR `READ_ONLY = False` → dispatch again (idle check on every job table) → rerun READ_ONLY (or the aa680
  check) for `active_unlinked=0`.
- Tests: `python3 -m unittest db.tests.test_aa911_bridge_staff_rows db.tests.test_aa680_staff_users_readonly_check`;
  `python3 db/run_migration.py --inspect-script db/scripts/aa911_bridge_staff_rows.py` → `{"errors": []}`.
