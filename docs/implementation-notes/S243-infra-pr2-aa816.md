# S243 Infra PR-2 — AA-816 I-B (A8 AdminCreateUser alarm) + I-C (break-glass email-code probe)

Lane AA-816, S243 plan steps I-B and I-C. The critic's wave 1 B2 split puts I-A (daily reconcile trigger) in
Infra PR-1 and these two here. AA-680 S0 was the same A8 alarm under another name and was dropped (critic
finding 3). This file is new on purpose: `AA-816.md` and the other lanes' notes are not edited.

## Decisions

- **A8 rule name** `aa-identity-dev-workforce-admincreateuser-password` (critic finding 3 keeps this name).
  The `aa-identity-dev-` prefix matters. The CI apply role's `EventBridgeIdentityRuleManage` (cicd_split.tf)
  covers `rule/aa-identity-*`, and the alerts topic statement `AllowIdentityEventBridgeRules` covers
  `rule/aa-identity-dev-*`. So there is no new grant, no bootstrap and no local MFA apply.
- **The pattern is wider than the plan's "temporaryPassword present or RESEND".** The `$or` has three branches
  under `requestParameters`, after `userPoolId = WORKFORCE pool`:
  - a. `temporaryPassword` exists;
  - b. `messageAction` is anything-but `SUPPRESS`: RESEND, plus any value AWS adds later;
  - c. `messageAction` is absent. Cognito then sends its own invite with a temporary password it generated.
    That needs the mailbox, but it breaks the "SUPPRESS is mandatory" rule in the identity.tf header.

  Every legitimate WORKFORCE create sends `SUPPRESS` and no password: the CIS directory, and tools/identity
  `create-staff`, `breakglass-init` and `--trigger-refusal-test`. So the extra branches add no noise.
- **No `errorCode` filter.** A denied AdminCreateUser on this pool is worth an e-mail too.
- **State `ENABLED`** (set explicitly). AdminCreateUser is a write management event. The read-only state is
  only needed for the GetSecretValue rule.
- **SNS message:** principal, IP, time, messageAction and temporaryPassword (CloudTrail masks the value, so it
  shows `HIDDEN_DUE_TO_SECURITY_REASONS` or nothing), then errorCode and a runbook line. CloudTrail masks the
  username too, so the runbook says to find the user by `UserCreateDate`.
- **Probe clients:** `breakglass` and `cis-admin`. A mailbox holder would use the cis-admin managed login.
  `booking-staff` is left out because it is not in the plan. Add it to `OTP_PROBE_CLIENTS` if wanted.
- **The second call is skipped when the first one already lists EMAIL_OTP.** The finding is already proven,
  and calling InitiateAuth with `PREFERRED_CHALLENGE=EMAIL_OTP` sends a real code e-mail to admin@. JSON:
  `"prefer_email_otp": {"skipped": ...}`.
- **Enabled at start:** if the user is already enabled, it is left enabled, with no sign-out and no disable,
  and a warning is printed. This covers the case where someone is in the middle of a break-glass sign-in.
  When the user was disabled at the start, the `finally` block runs global sign-out and then disable. It reuses
  `close_out`, so each step is attempted even if the other fails.
- **Exit codes:**
  - 0 = EMAIL_OTP not offered on any client;
  - 1 = EMAIL_OTP offered (the finding), inconclusive (a no-preference call errored with no challenge), or
    tokens issued (cannot happen without a credential, handled anyway);
  - 2 = cleanup incomplete, via the new `CleanupIncomplete(ToolError)` with `exit_code = 2`. `main()` now
    returns `exc.exit_code`, and every other ToolError still exits 1.
- **Output:** stdout carries one JSON document. Progress, the account preamble (for this command only) and
  the close-out lines go to stderr. The stderr `Output` shares the redactor set, so Session strings and client
  secrets stay masked.
- **No Secrets Manager client:** `_aws_clients` returns `sm=None` for any command in
  `NO_SECRETS_MANAGER_COMMANDS = ("breakglass-otp-probe",)`. The signature `(args, out)` is unchanged, so the
  existing monkeypatches still work.

## Changed

- `accounts/aa365/identity_alerts.tf`: section 4. Adds `aws_cloudwatch_event_rule.identity_workforce_admincreateuser_password`
  and `aws_cloudwatch_event_target.identity_workforce_admincreateuser_password` (target `alerts-sns` on
  `aws_sns_topic.alerts`, input transformer). The header lists item 4.
- `tools/identity/workforce_bootstrap.py`:
  - new subcommand `breakglass-otp-probe [--email]`, with `_otp_probe_call` and `_email_otp_offered`;
  - new `OTP_PROBE_CLIENTS`, `NO_SECRETS_MANAGER_COMMANDS` and `CleanupIncomplete`;
  - `_aws_clients` skips the SM client for the probe;
  - `main` returns the ToolError's exit code;
  - docstring updated.
- `tools/identity/tests/test_workforce_bootstrap.py`: 9 new tests.
  - Not offered → 0, and the user is disabled again.
  - Offered → 1, and the second call is skipped.
  - Enable error → disable still runs and the error is re-raised.
  - InitiateAuth errors → inconclusive, and disable runs.
  - An already-enabled user is left untouched.
  - Unknown user → nothing changed.
  - Out-of-domain address refused.
  - main: no `secretsmanager` client, and a failed disable exits 2.
  - breakglass-verify still gets an SM client.

  Every InitiateAuth stub uses exact `expected_params`: USERNAME + SECRET_HASH (+ PREFERRED_CHALLENGE), so a
  PASSWORD would fail the test. `respond_to_auth_challenge`, `admin_respond_to_auth_challenge`,
  `admin_initiate_auth` and `admin_set_user_password` are trapped.
- `tools/identity/README.md`: a command row, an expectations line (confirm `Enabled=false`) and the tests text.
- `CONTEXT.md`: the identity_alerts.tf and tools/identity lines, and the alerts topic policy sentence.

## Tradeoffs

- A wider A8 pattern (no-SUPPRESS / any non-SUPPRESS action) against the plan's literal two conditions. It
  costs nothing and catches policy drift: a code change that drops SUPPRESS would mail temporary passwords.
  It could fire on a future legitimate flow that does not use SUPPRESS. None exists, and ADR 0006a A3 says
  SUPPRESS always.
- **CloudTrail shape not proven for `temporaryPassword`.** No event in the last 90 days carries a temporary
  password, so the shape could not be read live. The other sensitive fields keep their key with a masked
  value, so `exists: true` should match. If AWS dropped the key instead, branch (a) would miss. A RESEND or a
  create without SUPPRESS would still match (b) or (c). Only "SUPPRESS + caller-set TemporaryPassword" depends
  on (a). The optional live test (below) settles it.
- Skipping the preferred call saves one real code e-mail. The cost is that the JSON does not show what
  Cognito returns for an explicit EMAIL_OTP preference once EMAIL_OTP is already listed. That detail adds
  nothing to the finding.
- The probe needs a Cognito write (enable/disable) on the break-glass user, which opens a short enabled
  window. The window is seconds long, and a sign-in still needs the password + TOTP (or the mailbox, which is
  exactly what the probe tests).

## Should know

- **Live read-only checks done 19/10/2026** (profile aa365-admin, 005097885195, us-west-1):
  - trail `aa-cis-dev-trail`: home us-west-1, single-region, `IsLogging=true`, one selector with
    ReadWriteType All + management events;
  - CloudTrail → EventBridge works in us-west-1: the existing rule `aa-identity-dev-breakglass-secret-access`
    has MatchedEvents=1 and Invocations=1 on 18/10;
  - topic `aa-cis-dev-acp-alerts` policy = `__default_statement_ID` + `AllowIdentityEventBridgeRules`
    (events.amazonaws.com, `ArnLike aws:SourceArn rule/aa-identity-dev-*`), with one confirmed e-mail
    subscription;
  - the 3 real AdminCreateUser events from 18/10 (CIS task role ×1, admin tool ×2) have
    `messageAction: SUPPRESS`, no `temporaryPassword` key, and username/userAttributes
    `HIDDEN_DUE_TO_SECURITY_REASONS`;
  - `aws events test-event-pattern` with the rendered pattern (pool `us-west-1_bCcFvbSOS`):

    | Event | Result |
    |---|---|
    | the 3 real events | false |
    | SUPPRESS + temporaryPassword (masked) | true |
    | RESEND | true |
    | no messageAction | true |
    | RESEND on another pool | false |
- **CI apply role permission not checked live.** The subagent guardrail blocks `aws iam`. From the code, Sid
  `EventBridgeIdentityRuleManage` (applied in S242, see AA-854 notes) covers `rule/aa-identity-*`. The live
  rule `aa-identity-dev-breakglass-secret-access` (state ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS) was
  created through that grant. The main session can confirm with
  `aws iam simulate-principal-policy --policy-source-arn arn:aws:iam::005097885195:role/aa-cis-infra-tf-apply --action-names events:PutRule events:PutTargets events:TagResource --resource-arns arn:aws:events:us-west-1:005097885195:rule/aa-identity-dev-workforce-admincreateuser-password --profile aa365-admin`.
  Expect `allowed`. If the result is not `allowed`, the missing grant is that Sid (bootstrap, local MFA
  targeted apply of `aws_iam_role_policy.tf_apply`).
- **Expected plan:** `+2` (rule + target), nothing changed or destroyed by this PR. If PR-1 is not applied
  yet, its changes show too, so apply PR-1 first.
- **Running the probe:**
  - Run it from the merged main checkout. The command and the post-check are in the README.
  - It is a Cognito write, so auto mode may need a toggle.
  - It must not overlap the N2 managed-login break-glass test (critic: both enable/disable admin@).
- **If `email_otp_offered=true`:** one code e-mail goes to admin@adventure.asia. Bring the fix options to
  Nghiệp (plan I-C-run): Required MFA is not an option (it breaks EMAIL_OTP for staff); remove the e-mail
  from the break-glass user; or rely on disabled-at-rest + token alarm.
- flake8 (max-line-length 120) on tools/identity: no new findings. The 4 remaining hits (E128, E203, 2×E501)
  were there before this change.
