# AA-1111 slice S2 — WORKFORCE TOTP for administrators (lane l17, S285)

Tech lead decisions: admin MFA = TOTP (S283); drop the WAF geo rule of the staff hosts once admin MFA is enforced
(S285). The apps (CIS, Booking, AA-Partner) check the access token's `amr` behind their own switch (root ADR 0006c).

## Decisions
- **Pool unchanged**: the WORKFORCE pool already had MFA OPTIONAL with TOTP on and no SMS. The PR adds a postcondition
  that keeps exactly that (never ON: it would force desk roles and the Dev E2E accounts onto TOTP; never SMS: paid, and
  removing it later forces a new pool) and rewrites the comment ("TOTP is for break-glass only" is no longer true).
  The plan is "No changes".
- **Enrolment through the bootstrap tool**: managed login offers TOTP set-up only when MFA is required, and the app
  clients do not hold the `aws.cognito.signin.user.admin` scope (ADR 0006), so a person cannot enrol from the admin
  page. `staff-totp-enroll` signs in on the staff client with a password the person types (USER_AUTH), calls
  AssociateSoftwareToken / VerifySoftwareToken with that access token, then sets TOTP preferred with the admin API.
  The setup key is shown once on stderr through a separate reveal channel; the person runs the tool in their own
  terminal (never an agent).
- **Never disabled**: unlike break-glass, the staff user is only revoked and signed out at the end (`close_out(...,
  disable=False)`).
- **`staff-totp-check`** proves the `amr` claim on this pool (the Cognito "authentication levels" feature is rolling
  out per pool) before any switch goes on.

## Changed
- `sign_in` can answer SOFTWARE_TOKEN_MFA with a typed code (`totp_code`), besides the stored break-glass seed.
- `SAFE_CLAIMS` prints `amr` and `acr`.

## Tradeoffs
- A password is set by the tool (the pool's admin-only recovery keeps "forgot password" off); the person chooses it.

## Should know
- The WAF change (geo rule off for the staff hosts) is a separate PR, merged only after the three switches are on.
