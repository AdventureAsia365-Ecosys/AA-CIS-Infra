# AA-910 — second E2E staff address for the Booking staff admin (S250)

Decision (Nghiệp, S250): agents and, later, CI need a signed-in check of the Booking staff admin. A second
dedicated WORKFORCE E2E identity, `e2e-booking@e2e-mail.lumiguides.it.com`, may sign in only with the staff groups
exactly `("booking-admin",)`. Root ADR 0006a A10 and A10a record the exception; this file records how the triggers and the
mailbox implement it.

## Decisions

- **Per-address allow-map, still a code constant.** `workforce.E2E_TEST_STAFF` is a read-only
  `MappingProxyType({address: exact group tuple})` with two entries: the CIS E2E address (`cis-reviewer`, unchanged)
  and the Booking E2E address (`booking-admin`). No Lambda environment variable or Terraform variable can add an
  address or widen a group set. The old names `E2E_TEST_STAFF_EMAIL` / `E2E_TEST_STAFF_GROUPS` stay (CIS docs and
  the parked removal branch refer to them); `E2E_BOOKING_TEST_STAFF_EMAIL` / `_GROUPS` are new.
- **Exact match, refuse instead of strip.** Pre sign-up allows an address of the map for `PreSignUp_AdminCreateUser`
  only. Pre token requires `email_verified` and the staff groups (after the `STAFF_GROUPS` filter) to equal that
  address's tuple; anything else raises `Deny("E2E test account outside its allowed groups")`, logged as
  `workforce_pre_token_denied` (same reason text as before).
- **ASCII-only lookup on the RAW attribute (review fix, S250).** `str.lower()` folds U+212A KELVIN SIGN to ASCII `k`,
  so `e2e-booKing@…` (Kelvin sign) normalised to the map key: a second Cognito user (other username, other sub)
  would have passed as the E2E account, with the canonical address written into its access-token `email` claim.
  `_e2e_groups(raw, normalised)` returns None when the raw `email` attribute has any non-ASCII character. The check
  must look at the raw value: after `lower()` the folded address is already ASCII, so `normalised.isascii()` (the
  first suggested fix) would not catch it (verified: the Kelvin test fails with that variant). Kept out of
  `common.normalise_email`, which the EXTERNAL pool shares. The CIS address was never affected (no folding letter),
  but the guard covers both entries.
- **booking-admin, not a narrower group.** It is the least-privileged Booking group that reads every staff page,
  `/staff` (`staff.admin`) and `/audit-log` (`audit.read`) included (AA-Booking `backend/app/auth/staff.py`).
- **No password, email code only.** The user is created with `AdminCreateUser` + `MessageAction=SUPPRESS`,
  `email_verified=true`, and never gets a password: identity.tf "DELIBERATE DEVIATIONS" (nobody but break-glass may
  hold a usable password) and ADR 0006a A8 (the detective alarm on a caller-set password) both apply to it. The
  sign-in reads the Cognito code from the SES mailbox, like the CIS E2E user. Therefore no Secrets Manager secret.
- **No CIS change.** The address is not in the CIS directory: migration 250's CHECK accepts only the CIS E2E
  address, so the directory cannot create it and a CIS sign-in cannot link a row. CIS also refuses the token earlier,
  403 `no_cis_group` (`api/core/staff_identity.py` rule 2), because the user has no `cis-*` group.

## Changed

- `lambda_src/identity_triggers/workforce.py`: allow-map, docstring; the `workforce_e2e_test_token_issued` line
  now carries `email` (which E2E account got the token).
- `lambda_src/identity_triggers_tests/test_workforce.py`: map guard (exactly two entries, read-only), Booking E2E
  allow / near-miss deny / self sign-up and federated deny / fail-closed / token / every other group set denied /
  CIS E2E cannot borrow booking-admin, and a guard that every map address is a recipient of the SES receipt rule.
  Review fix: non-ASCII look-alikes (Kelvin sign lower and upper case, zero-width space, fullwidth `k`) are denied at
  both triggers with no E2E log line; a test proves the Kelvin fold really happens (so the guard is needed); a
  `STAFF_GROUPS` override without booking-admin denies the Booking E2E token. Mutation-checked: removing the ASCII
  check fails 3 tests.
- `e2e_mailbox.tf`: `e2e_mail_booking_recipient` in the `e2e-cognito` rule recipients (in-place update of the rule)
  and in the `e2e_mailbox` output.
- `.github/workflows/identity-triggers-test.yml`: `e2e_mailbox.tf` in the path filters (the guard test reads it).

## Tradeoffs

- **Observable change for the CIS E2E user:** one extra JSON key (`email`) in its info log line
  `workforce_e2e_test_token_issued`. Allow / deny, deny reasons and token contents are byte-identical. No metric
  filter or alarm parses that event (grep of `accounts/` for `workforce_e2e`).
- **Shared mailbox prefix.** Booking codes land under the same `inbound/` prefix, so the CIS reader role (AA-CIS-App,
  env `e2e`, main) can read a booking-admin code. Accepted for Dev (S250); codes are one-time and expire in minutes,
  objects in 1 day.
- **Reader trust not widened yet.** No AA-Booking CI job exists, so `aa-cis-dev-e2e-mail-reader` still trusts only
  AA-CIS-App and AA-Partner. When the Booking signed-in smoke job lands, add
  `repo:AdventureAsia365-Ecosys@<org id>/AA-Booking@<repo id>:environment:e2e` to its `sub` list (same pattern as
  AA-Partner) in that PR.

## Should know

- All trigger Lambdas share one archive: the plan publishes a new version behind each `live` alias, and updates
  `aws_ses_receipt_rule.e2e_cognito` in place. Apply through the Terraform Apply workflow after merge. Create the
  Cognito user only after the apply (pre sign-up denies the address until then).
- The CIS staff reconcile job (C7, report only) will list the user under `cognito_without_row` (+1 `drift_total`,
  "1 to check" on the CIS Staff page). Expected; it is not in the CIS directory by design.
- **Exposure (review, S250).** booking-admin is full Booking write admin (retention live delete, staff admin, B2B
  admin). Code readers: the reader role (AA-CIS-App and AA-Partner, `e2e`, main), the MFA admin role, and whoever
  controls mail for the sub-domain. AA-Booking therefore refuses every non-safe method from this user (403
  `e2e_read_only`, AA-Booking PR on branch `docs/aa-910-signed-in-smoke-note`), so a leaked code yields admin reads
  only. A10's domain-dependency removal trigger covers this address too (ADR A10a "Exposure").
- Booking auto-provisions a `booking.staff_users` row (`cog:<sub>`, role admin, active) on its first sign-in. It
  shows on Booking `/staff`; Deactivate there is a quick kill switch, `AdminDisableUser` the real one.
- Removal (with the A10 removal at the end of the project): disable + delete the Cognito user, drop its entry from
  `E2E_TEST_STAFF` and the recipient, Terraform Apply. The parked branch `fix/aa-816-remove-e2e-trigger-exception`
  must be rebased over this change.
