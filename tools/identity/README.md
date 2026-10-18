# tools/identity — WORKFORCE bootstrap tool (AA-854, root ADR 0006)

`workforce_bootstrap.py` is run by hand by an AWS admin (profile `aa365-admin`, MFA). CI only runs its
tests (`.github/workflows/identity-triggers-test.yml`, job `workforce-bootstrap-tests`). It uses the
standard library and boto3 only. Run it with any Python that has boto3, for example the CIS venv:

```bash
PY=/home/nghiep/projects/AA-Ecosys/apps/AA-CIS-App/.venv/bin/python
T=/home/nghiep/projects/AA-Ecosys/infra/AA-CIS-Infra/tools/identity/workforce_bootstrap.py
```

The tool first checks that the credentials are for account 005097885195 (`--expect-account`).
It reuses the AWS CLI assume-role cache, so one MFA prompt covers both the tool and `aws`.

| Command | What it does | Plan step |
|---|---|---|
| `$PY $T create-staff --email someone@adventure.asia --groups cis-admin,booking-admin [--name "..."]` | AdminCreateUser with `MessageAction=SUPPRESS` and `email_verified=true`, then AdminAddUserToGroup. It never sets a password. A re-run adds the groups to the existing user. Addresses outside `@adventure.asia` and unknown groups are refused before any AWS call. | A3 |
| `$PY $T create-staff --email x@example.com --groups cis-admin --trigger-refusal-test` | Skips the client-side domain check only (the address must be outside `@adventure.asia`) and never adds groups. Prints `trigger: refused server-side (UserLambdaValidationException): ...` and exits 0 when the pre sign-up trigger refuses. If Cognito accepts the user instead, the tool disables it, prints the `admin-delete-user` command and exits 1. Client-side refusals always start with `refused client-side:`, so they cannot be mistaken for the trigger's. | A5 |
| `$PY $T breakglass-init` | Creates the break-glass user (`admin@adventure.asia`, decision D1) or rotates it, adds it to cis-admin and booking-admin, sets a random permanent password, signs in on `aa-workforce-dev-breakglass`, enrols and verifies TOTP, and stores `{username, password, totp_seed, created_at}` in `aa-identity/dev/breakglass`. First it checks that the secret exists (DescribeSecret, metadata only), so a missing secret fails before the user is touched. A `finally` block then revokes the refresh token, signs the user out everywhere and **disables** the user. | A2 |
| `$PY $T breakglass-verify` | Reads the secret, enables the user, waits for a fresh TOTP window, signs in with password + TOTP, prints the access-token claim summary, then revokes, signs out and **disables** the user (`finally`). | A2 |
| `$PY $T authorize-url` | Spike: prints the managed-login authorize URL for `cis-admin` with `http://localhost:3000/api/auth/callback/cognito`, PKCE S256. The verifier and state go to `.tmp-session/identity-spike/pkce-pending.json` (mode 0600). | A3 |
| `$PY $T exchange-code` | Spike: paste the callback URL from the browser (prompted, so it stays out of shell history). The tool checks the state and the redirect URI, exchanges the code with the client secret (read with DescribeUserPoolClient, kept in memory), prints the non-secret claims of the access and ID tokens, then revokes the refresh token. The pending file is deleted. | A3 |

## What to expect

- Break-glass sign-in (init and verify) fires the alarm `aa-identity-dev-breakglass-token-issued`
  (ALARM, then OK). Reading or writing the secret fires the I1 CloudTrail alert. Both are expected;
  note each run in the session log.
- Output is status lines, claim summaries and the secret's `VersionId`. Passwords, TOTP seeds and codes,
  client secrets, authorization codes and tokens are never printed. Errors print as one line, with no
  traceback.
- A re-run of `breakglass-init` rotates both the password and the TOTP seed: it clears the old TOTP
  preference first, so it never needs the old secret value.
- **Fail closed.** If any cleanup step (revoke, global sign-out, disable) fails, the command exits 1,
  prints `cleanup INCOMPLETE` with the `admin-disable-user` command to run by hand, and does not print
  `done`/`OK`, even when the main work succeeded.
- If `breakglass-init` fails after the new password is set but before the secret is written, it warns
  `break-glass credentials NOT stored`: the previous password is already invalid, so re-run `breakglass-init`.

## Tests

```bash
cd /home/nghiep/projects/AA-Ecosys/infra/AA-CIS-Infra
$PY -m pytest -p no:cacheprovider -q tools/identity/tests
```

The tests cover the RFC 6238 vectors, botocore Stubber checks (SUPPRESS and `email_verified` always sent,
out-of-domain addresses refused before any call, the user disabled even when a step fails) and a
capsys check that no secret value reaches stdout or stderr. They make no AWS calls.

`scripts/` is gitignored in this repo, so this tool lives in `tools/`. Check with `git ls-files tools/identity`.
