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
| `$PY $T breakglass-otp-probe` | Root ADR 0006a A4 check (AA-816): does Cognito offer `EMAIL_OTP` (an e-mail code) as a first factor to the TOTP-enrolled break-glass user? Enables the user if it is disabled, then for each of `aa-workforce-dev-breakglass` and `aa-workforce-dev-cis-admin` calls InitiateAuth `USER_AUTH` with **USERNAME + SECRET_HASH only** (client secret read with DescribeUserPoolClient, kept in memory): once with no preference, then with `PREFERRED_CHALLENGE=EMAIL_OTP` unless EMAIL_OTP was already listed. It never sends a password, never answers a challenge, never creates a Secrets Manager client (so no I1 secret alert) and so never gets a token (no token alarm). A `finally` block puts the user back: global sign-out + **disable** if it was disabled at the start; a user that was already enabled is left enabled (with a warning). stdout is one JSON document (`verdict`, per client `no_preference` / `prefer_email_otp` with `challenge`, `available_challenges`, `error`), progress goes to stderr. Exit **0** = EMAIL_OTP not offered on any client, **1** = offered (the finding; Cognito then sends one code e-mail to the mailbox) or inconclusive, **2** = cleanup incomplete (run the printed `admin-disable-user`). Never run it while a break-glass sign-in test is running. | A4 |
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
- **Fail closed.** If any cleanup step (revoke, global sign-out, disable) fails, the command exits 1
  (`breakglass-otp-probe`: exit 2), prints `cleanup INCOMPLETE` with the `admin-disable-user` command to
  run by hand, and does not print `done`/`OK`, even when the main work succeeded.
- `breakglass-otp-probe` raises neither break-glass alert. After it, confirm the user is disabled:
  `aws cognito-idp admin-get-user --user-pool-id us-west-1_bCcFvbSOS --username admin@adventure.asia --profile aa365-admin --region us-west-1 --query Enabled`
  (AdminGetUser counts as one MAU; the tool itself uses ListUsers).
- If `breakglass-init` fails after the new password is set but before the secret is written, it warns
  `break-glass credentials NOT stored`: the previous password is already invalid, so re-run `breakglass-init`.

## Tests

```bash
cd /home/nghiep/projects/AA-Ecosys/infra/AA-CIS-Infra
$PY -m pytest -p no:cacheprovider -q tools/identity/tests
```

The tests cover the RFC 6238 vectors, botocore Stubber checks (SUPPRESS and `email_verified` always sent,
out-of-domain addresses refused before any call, the user disabled even when a step fails; for
`breakglass-otp-probe`: exact InitiateAuth parameters with no PASSWORD, RespondToAuthChallenge trapped,
no Secrets Manager client created, an enabled user left enabled, exit 2 on a failed disable) and a
capsys check that no secret value reaches stdout or stderr. They make no AWS calls.

`scripts/` is gitignored in this repo, so this tool lives in `tools/`. Check with `git ls-files tools/identity`.

## crm_dev_identity.py — AA-Partner (CRM) Dev identity (AA-935)

Same rules as above (admin with MFA, stdlib + boto3, account guard, values never printed). DRY RUN unless `--apply`.
Pools and clients are found by name (`aa-<pool>-<env>`; clients `aa-external-<env>-cis-portal`,
`aa-partner-<env>-partner-web`). `--pool external` (default) or `--pool partner` (AA-939, root ADR 0006b: the partner
pool, MFA required).

| Command | What it does |
|---|---|
| `$PY tools/identity/crm_dev_identity.py e2e-users [--apply] [--write-secrets]` | The e2e users of the synthetic CRM agencies (`crm_e2e_users.json`, same agency keys and roles as AA-Partner `api/app/seed/catalogue.py`) in the EXTERNAL pool: `e2e-test-crm-<agency>-<role>@e2e-mail.lumiguides.it.com`, AdminCreateUser with `MessageAction=SUPPRESS` and `email_verified=true`, no password (e-mail code sign-in; the codes land in the e2e mailbox bucket, `e2e_mailbox.tf`). Re-runs create only the missing users. Prints each user's `sub`, the seeder argument `--member <agency>:<role>:<sub>` and the full `python -m app.seed --apply ...` command to run in the CRM API container (ECS Exec). `--write-secrets` stores `{email, sub, agency, role, pool}` in `crm/dev/e2e-test-crm/<agency>-<role>`. |
| `$PY tools/identity/crm_dev_identity.py --pool partner e2e-users --apply --write-secrets` | AA-939: the same users in the partner pool. A new user is created with SUPPRESS and a random temporary password, then enrolled through the partner-web client the way a person signs in the first time (USER_AUTH + PASSWORD, a random permanent password, TOTP enrolment), and `{email, sub, agency, role, pool, password, totp_secret}` is stored in its secret (`--write-secrets` is required: the values exist nowhere else). Existing users keep their stored values. Entries with `"invitee": true` are skipped. Expect one partner-pool "admin bypass" alert mail per run (identity_partner.tf). The E2E environment secrets `E2ECRMPASSWORD` / `E2ECRMTOTP` are copied from the owner's secret. |
| `$PY tools/identity/crm_dev_identity.py --pool partner invitee-reset [--apply]` | AA-939: deletes the partner-pool account of the `"invitee": true` address so the one-off timed E2E "invite -> active < 5 min" (AA-Partner `e2e/tests/invite.spec.ts`) starts from no account. |
| `$PY tools/identity/crm_dev_identity.py web-secret [--apply] [--rotate-session]` | Writes `crm/dev/web` (the `crm_web.tf` secret shell) = `{cognito_client_secret, session_secret}`: the client secret read from the `cis-portal` client (or, with `--pool partner`, the `partner-web` client: run it right after `crm_partner_signin_enabled = true` is applied, then deploy the web), the session secret random and kept on re-runs unless `--rotate-session` (signs every CRM web user out). Run it before the first web task starts. |
