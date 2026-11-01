# Identity Center admin session digest (S263) — the second e-mail after an administrator session

Session S263 (01/11/2026), Claude Code lane sec-activity-digest. Branch `feat/aa-873-admin-session-digest`.
Refs AA-873. Source: tech lead ask in S263, follow-up to the AA-1022 / AA-873 N17 sign-in alert
(`accounts/aa365/security_sso_signin.tf`, Infra #579).

## Decisions

- **Session = one successful `AssumeRoleWithSAML`** on an `AWSReservedSSO_<set>_<hash>` role, `<set>` taken from
  `local.sec_sso_admin_permission_sets` (the same list the sign-in rules use, passed as `ADMIN_PERMISSION_SETS`), so
  the two mails always cover the same permission sets. Failed calls are skipped (no credentials were issued; the
  sign-in alert already mails the error code).
- **Where the events are**: sessions are looked up in us-east-1 (global STS, where all 10 sessions of the last 90
  days landed) and this region; a session's calls in `var.sec_admin_digest_activity_regions` (default us-east-1 +
  us-west-1, as asked). us-east-1 is mandatory (validation) because the global services record there. Other regions
  can be added by variable (one more LookupEvents loop per region, free).
- **Which calls belong to the session**: lookup by `Username` = role session name (console and CLI), then, only when
  that finds none of the session's own access-key calls, by `AccessKeyId` (the key in the `AssumeRoleWithSAML`
  response). A call counts when its identity is the same permission-set role or uses the session's key. Two overlapping
  sessions of one user on one role (console + CLI): access key first, then the credential `creationDate` (within 5 min
  of a session start), then the latest session started before the call.
- **"Over"**: credentials expired (+15 min CloudTrail delivery lag) or no call for 60 min. A session closed by idleness
  stays open in the state until it expires; calls that show up later send one more digest marked "(continued)", only
  for the new calls. Expiry with nothing new closes it without a mail.
- **Mail content**: masked session name (local part), permission set, start / end in UTC and ICT, source IPs with the
  last octet masked (CloudTrail has no country field, so no country is shown; a geo-IP lookup would send IPs to a third
  party), calls per service, DELETE calls first, then other WRITE calls (time, service:eventName, up to three resource
  names, region, errorCode), then read-only calls by count. Caps: 300 write lines and 60 read rows per mail, the rest
  counted (SNS e-mail limit 256 KB); page cap 100 x 50 events per lookup, flagged in the mail when hit.
- **Masking**: one `mask_text()` over every line, independent of where the text came from: ARNs become their resource
  name, e-mail addresses keep only the local part (`name@…`), any 12-digit run becomes `{account}`, any leftover
  `arn:` is dropped. `sec_alert_check.py --digest-preview` checks the live output again with its own regexes.
- **State store: one S3 object in the bronze bucket** (`sec-digest/admin-sessions.json`), not DynamoDB. Both cost
  ~0 USD; S3 needs no new resource and no new CI apply grant (the apply role has no `dynamodb:CreateTable`, so a table
  would need a bootstrap step with the MFA profile). The object holds CloudTrail eventIDs and times only (no user name,
  IP or key), is written only after a mail (a few times a month) and pruned after lookback + 1 day. The bucket is
  versioned; at this write rate the noncurrent copies are negligible, so no lifecycle rule was added.
- **Failure handling**: no Lambda async retries; state is saved after each published mail, so a crash never re-sends a
  mail already sent and the next hourly run picks up the rest. Under 90 s of run time left, remaining sessions are
  deferred to the next run. Errors alarm on the alerts topic (runbook: incident response).
- **Preview mode** (`{"preview": true, "since", "until"}`) for the live check: reads CloudTrail only, builds digests even
  for open sessions, returns them; no publish, no state read or write.

## Changed

- New: `accounts/aa365/security_sso_session_digest.tf`, `lambda_src/sec_admin_session_digest/handler.py`,
  `lambda_src/sec_admin_session_digest_tests/test_handler.py`, `.github/workflows/sec-admin-session-digest-test.yml`,
  `tools/terraform/tests/test_sec_admin_digest.py`.
- `tools/terraform/sec_alert_check.py`: `--digest` (read-only config check), `--digest-preview SINCE UNTIL` (preview
  invoke + leak check), `--digest-only`; `aws()` takes a timeout.
- `.github/workflows/alb-rule-order.yml` runs the new Terraform shape test; `CONTEXT.md` layout entry.

## Tradeoffs

- Hourly + 60 min idle means the digest arrives 1-2 h after the last call of a console session (or right after expiry).
  Shorter idle would split one working session into several mails.
- LookupEvents (free, 90 days, 2 calls/s per region) instead of reading the trail's S3 objects or a CloudWatch Logs
  query: no extra cost and no parsing of gzip files; the price is speed on very large sessions (handled by the 600 s
  timeout, the page cap and deferral).
- Read-only calls are summarised by count, not listed: a local `terraform plan` session makes thousands of them.

## Should know

- First hourly run after apply looks back 36 h: any administrator session in that window gets a digest then (expected,
  not a duplicate).
- The live check is the preview invoke over a past real admin session window, read in the function's log group
  (`/aws/lambda/aa-sec-dev-admin-session-digest`, one JSON line per digest with the masked text).
- Further hardening of who may write the state object: see Linear AA-873.
