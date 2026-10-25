# AA-816 A10b — Dev-only E2E CIS admin address (S252)

Decision (S252, orchestrator under Nghiệp's standing approval; root ADR 0006a A10b): the orchestrating agent signs
itself in to the CIS admin as an **admin** to screenshot the admin-only pages (`/admin/content-quality`,
`/admin/writing-memory`) and to produce the AA-916 WM-07 sample (admin sentence actions through the UI on synthetic Dev
tenants). The A10 account `e2e@` is a reviewer only. A third WORKFORCE E2E address,
`e2e-cis-admin@e2e-mail.lumiguides.it.com`, may sign in only with the staff groups exactly `("cis-admin",)` and only on
dev. This file records how the triggers and the mailbox implement it; the CIS side (migration 283, directory scope,
environment guard, read-only cap with the sentence-apply allow-list) is in AA-CIS-App
`docs/implementation-notes/AA-816-e2e-cis-admin.md`.

## Decisions

- **A separate dev-only map, switched by an exact env flag.** `workforce.E2E_DEV_ONLY_TEST_STAFF` is a read-only
  `MappingProxyType({E2E_CIS_ADMIN_TEST_STAFF_EMAIL: ("cis-admin",)})`, consulted by `_e2e_groups` only when
  `os.environ.get("E2E_DEV_ONLY_STAFF_ENABLED") == "true"` (read per call, no strip / lower; missing, empty, `True`,
  ` true`, `1` are all off). `E2E_TEST_STAFF` (A10, A10a) is unchanged and always on. The flag can only switch ON an
  entry whose address and groups are code constants: no configuration adds an address or widens a group set.
- **Terraform sets the flag, a precondition refuses it outside dev.** `identity.tf` `id_workforce_env` gets
  `E2E_DEV_ONLY_STAFF_ENABLED = var.environment == "dev" ? "true" : "false"` (WORKFORCE triggers only, not the
  EXTERNAL env). `aws_lambda_function.identity_trigger` has a `lifecycle.precondition`: `var.environment == "dev" ||
  lookup(each.value.env, "E2E_DEV_ONLY_STAFF_ENABLED", "false") != "true"`, against a future hand-edited env map.
- **Same refusal rules as A10 / A10a.** Pre sign-up allows the address for `PreSignUp_AdminCreateUser` only; pre token
  requires `email_verified` and the staff groups (after the `STAFF_GROUPS` filter) to equal `("cis-admin",)`; any
  other set (with `booking-*` or `crm-*`, another `cis-*`, empty) is refused, never stripped. The ASCII-only raw
  lookup covers the new map too. `e2e@` / `e2e-booking@` cannot borrow `cis-admin` (the map is per address).
- **Own SES rule and prefix.** `aws_ses_receipt_rule.e2e_cognito_admin` (`count` on dev): recipient the admin address
  only, `scan_enabled`, `tls_policy = "Require"`, S3 action to `inbound-admin/`. The address is never added to
  `e2e_cognito` (its codes must never land in `inbound/`, which the CI reader role reads).
- **Rule order: appended at the end** (`after = aws_ses_receipt_rule.crm_ingest.name`). Inserting after `e2e-cognito`
  would move `aa-crm-dev-ingest`, whose own `after = e2e-cognito` would then plan a perpetual diff. Recipients are
  disjoint from both other rules, so order has no functional effect.
- **Bucket policy.** `AllowSesPutFromE2eRule` unchanged (`inbound/*` <- rule `e2e-cognito` only). New, dev only
  (dynamic): `AllowSesPutFromE2eAdminRule` (`inbound-admin/*` <- rule `e2e-cognito-admin` only, same SourceAccount /
  SourceArn pairing, so neither rule writes into the other's prefix). New, unconditional:
  `DenyAdminPrefixReadsExceptMfaAdmin` (object reads on `inbound-admin/*` denied to `*` unless `aws:PrincipalArn` is
  the MFA admin role). `DenyObjectReadsExceptReaderAndAdmin` and `DenyInsecureTransport` unchanged.
- **Reader identity policy unchanged** (`inbound/*` only; the string `inbound/` does not match `inbound-admin/…`); a
  comment now says the admin prefix is out of scope on purpose. The bucket Deny covers it even if that policy is ever
  widened.
- **Lifecycle unchanged**: `expire-e2e-mail-1d` has `filter {}`, so `inbound-admin/` objects expire after 1 day too.
- **Output** `e2e_mailbox` gains `admin_recipient` and `admin_prefix` (null outside dev).

## Changed (vs. the design)

- Nothing functional. The design asked to add `identity.tf` to the identity-triggers workflow path filter "if
  absent": it was already there, so the workflow is unchanged.
- Plan effect is wider than "2 workforce Lambda versions": the four trigger Lambdas share one `archive_file`, so a
  change to `workforce.py` publishes a new version of all four (the two EXTERNAL ones with unchanged code and env)
  and moves their `live` aliases. Expected; nothing else in the external path changes.

## Tradeoffs

- **Env flag vs. a Terraform-rendered address.** Rendering the address from Terraform would let configuration add an
  address; the flag only switches a code constant, so the trust boundary stays the reviewed Python.
- **Unconditional Deny statement.** Kept on every environment: harmless while the prefix is empty, and it reserves the
  prefix name so no later rule can quietly route admin codes somewhere the reader can read.
- **Codes readable by the MFA admin role only.** No CI job can sign in as the admin (the reader role cannot read the
  prefix); the evidence run is local, by the orchestrator, under the 8 h MFA session.

## Should know

- **Apply order:** the copy `db/migrations/cis/283_admin_users_e2e_cis_admin_email.sql` fails the Migration Copy Guard
  until CIS PR-1 (migration only) is on AA-CIS-App `main`; merge that first, then re-run this PR's checks.
- **Plan must show only:** the four identity trigger Lambdas (new version; env change on the two WORKFORCE ones) and
  their `live` aliases, one new `aws_ses_receipt_rule.e2e_cognito_admin[0]`, `aws_s3_bucket_policy.e2e_mail` in place,
  the `e2e_mailbox` output. Anything else = stop.
- **No IAM change for the apply role:** `SESReceiptRuleManage` (`cicd_split.tf`, `ses:*ReceiptRule*`) covers the new
  rule; S3 bucket policy writes are already covered.
- **Removal (end of project code, with A10 / A10a):** drop `E2E_CIS_ADMIN_*`, `E2E_DEV_ONLY_TEST_STAFF`,
  `_dev_only_e2e_enabled` and its constants, the `E2E_DEV_ONLY_STAFF_ENABLED` env and the precondition, the receipt rule
  `e2e_cognito_admin`, the two bucket statements, the output keys and their guard tests; Terraform Apply.
- **Detection:** `workforce_e2e_test_token_issued` carries `email`, so every admin sign-in is traceable in the
  WORKFORCE pre-token log group.
