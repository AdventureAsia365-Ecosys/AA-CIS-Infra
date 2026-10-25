# AA-Partner forward-in mail (CRM-17) — runbook

Terraform: `accounts/aa365/crm_mail.tf` (AA-945). App: AA-Partner `api/app/mail/ingest.py` (job `crm_mail_ingest`,
queued by the worker hook `MailIngestScan` only while `raw/` holds objects).

```
agency mailbox --(auto-forward / BCC)--> <slug>-<16 hex>@crm-in.lumiguides.it.com
  MX crm-in.lumiguides.it.com -> inbound-smtp.us-west-1.amazonaws.com
  -> active rule set aa-cis-dev-e2e, rule aa-crm-dev-ingest (AFTER e2e-cognito; spam/virus scan; TLS required)
  -> s3://aa-crm-dev-ingest-<account>/raw/<SES message id>   (bucket-default SSE-KMS, expires after 1 day)
  <- crm_mail_ingest (AA-Partner task role): parse, re-encrypt under the agency mail DEK, thread, delete from raw/
```

## Rules that must not be broken

- **One active receipt rule set per region.** Never create or activate a second set: it switches off the CIS /
  Booking / CRM Cognito E2E mailbox (`e2e_mailbox.tf`). New rules join `aa-cis-dev-e2e` with an explicit `after`.
- `aa-crm-dev-ingest` stays **after** `e2e-cognito`. The two rules have disjoint recipients (`e2e-mail.` vs `crm-in.`).
- The rule name must match `crm_storage.tf` `crm_ses_rule_arns` (bucket policy) and the ingest key policy statement
  `SesReceiptEncrypt` (`crm_data.tf`). Renaming the rule without both breaks every delivery.
- The S3 action has **no** `kms_key_arn` (SES client-side encryption needs the S3 Encryption Client, which boto3 lacks).

## After the first apply (read-only checks, single-line commands)

1. The rule and its order:
   `aws ses describe-receipt-rule-set --rule-set-name aa-cis-dev-e2e --profile aa365-admin --region us-west-1 --query 'Rules[].Name'`
   expect `["e2e-cognito", "aa-crm-dev-ingest"]`.
2. `aws ses describe-active-receipt-rule-set --profile aa365-admin --region us-west-1 --query 'Metadata.Name'` is still
   `aa-cis-dev-e2e`.
3. `dig +short MX crm-in.lumiguides.it.com` answers `10 inbound-smtp.us-west-1.amazonaws.com.`
4. **SSE-KMS check.** SES writes `raw/AMAZON_SES_SETUP_NOTIFICATION` when the rule is created. It proves SES can put
   an object under the bucket default key with the `SesReceiptEncrypt` SourceArn condition:
   `aws s3api list-objects-v2 --bucket <ingest bucket> --prefix raw/ --profile aa365-admin --region us-west-1 --query 'Contents[].Key'`
   The app removes the notice on its next run, so check right after the apply, or look for `setup_notice_count` in
   the first `crm_mail_ingest` job result. If the notice never appears and CloudTrail shows a KMS `AccessDenied` for
   `ses.amazonaws.com`, add a key-policy statement for the SES service principal keyed on
   `kms:ViaService = s3.us-west-1.amazonaws.com` + `aws:SourceAccount`, apply, and send a test mail.
5. The CIS Cognito E2E still passes (it uses the same rule set).

## Live end-to-end check (plan step S7, after the AA-Partner deploy)

- `GET /crm/v1/mailbox/ingest-address` for the synthetic agency, then send one mail with `[ref:<trip mail_token>]` in
  the subject (`aws sesv2 send-email ...` on one line, From a verified address): it appears on that trip.
- Mail to `nobody-xyz123@crm-in.lumiguides.it.com`: no row in any agency, `raw/` empty after the next run, and the
  `MailIngestDropped` metric (namespace `AA/Jobs/Crm`) counts it.
- Revoked-token hold: revoke the test Gmail grant at Google, send from the trip: the message shows held with
  "Reconnect" and the owners get one alert; reconnect: it is sent.

## Poison objects

A raw object the app cannot parse is removed at once (`unparsable_count`). One it can parse but cannot store (a
database or key error) stays for the next run and counts `failed_count`; once it is **1 hour** old the app drops it
(`failed_permanent_count` + `MailIngestDropped`). The job pages past failing objects, so they never block new mail.
While a failing object waits, the scan queues one `crm_mail_ingest` job per minute, which keeps `crm.job` busy for the
deploy gate and DB Migrate (DM-11.4) for up to an hour. Read the job's error class first; if the gate cannot wait,
the orchestrator removes that one key from `raw/` by hand (the mail is lost).

## OAuth secret (send-as through Gmail / Microsoft 365)

1. Google Cloud OAuth client: consent screen in Testing, scope `gmail.send`, redirect
   `https://partner-dev.lumiguides.it.com/connect/mail/callback`, a test user.
2. Entra app registration: delegated `Mail.Send` + `offline_access`, the same redirect.
3. Put `{"google_client_id", "google_client_secret", "ms_client_id", "ms_client_secret"}` into `crm/dev/mail-oauth`
   (Secrets Manager; the shell exists, Terraform never holds the values).
4. Only then set `crm_mail_oauth_enabled = true` and apply: a task whose `valueFrom` secret has no value fails to start.

Microsoft rotates the refresh token on every refresh (90-day lifetime); the app seals the new one on each send and
nightly check, so an active mailbox does not expire.

## Cost

About $0.65/month on Dev: SES receiving ~$0.01, the per-minute `ListObjectsV2` ~$0.22, the secret $0.40.
