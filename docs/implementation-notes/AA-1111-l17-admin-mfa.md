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

- **A failed enrolment leaves no usable password** (review fix): when `staff-totp-enroll` stops before TOTP is
  verified and preferred (three refused codes, an unexpected challenge, an error, Ctrl-C), a `finally` step overwrites
  the typed password with a random 64-character one nobody knows (memory only, never printed). MFA is OPTIONAL on the
  pool, so a password alone would sign in with amr ["pwd"], the bypass `identity.tf` forbids. With `--rotate` the old
  TOTP preference is switched back on in the same step. A failed overwrite is a loud warning with the manual
  `admin-disable-user` command.

## Tradeoffs
- A password is set by the tool (the pool's admin-only recovery keeps "forgot password" off); the person chooses it.
- `--rotate` still clears the old TOTP preference before the password sign-in (the reviewer suggested clearing it
  only after the new token is verified). Keeping it on would make the sign-in ask for the old app's code, and rotation
  exists mostly for a lost phone. The failure path restores the preference instead (best effort: if Cognito no longer
  holds the old token the user is left with no TOTP and an unknown password, the safe state, and reruns the tool).

## Should know
- The WAF change (geo rule off for the staff hosts) is a separate PR, merged only after the three switches are on.
