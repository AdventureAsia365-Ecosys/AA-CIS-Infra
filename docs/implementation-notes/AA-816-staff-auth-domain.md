# AA-816 — staff sign-in on staff-auth.lumiguides.it.com + AA managed login branding (S242)

Why: Chrome Safe Browsing flagged lumiguides.it.com as deceptive right after staff sign-in went
live. `aa-cis.lumiguides.it.com/api/auth/signin/cognito` redirected to
`aa365-staff-auth-dev.auth.us-west-1.amazoncognito.com` with the default AWS look, which looks
like the classic phishing pattern (unknown domain, no brand). Fix: serve managed login on our own
domain and make it look like the Adventure Asia product.

## Decisions

- **Apex A record → Vercel anycast IP `76.76.21.21`** (`dns.tf` `aws_route53_record.apex`,
  variable `dns_apex_a_records`). Cognito refuses a custom domain unless the parent name has an A
  record (any value; SOA is not enough), and the apex had none. Options weighed:
  - Vercel IP + attach `lumiguides.it.com` to the `aa-cis-frontend` Vercel project with a redirect
    to `aa-cis.lumiguides.it.com`: **$0**, real HTTPS redirect (what a visitor or a Safe Browsing
    reviewer sees on the bare domain), one record. Chosen.
  - Alias to the CIS ALB: rejected (internet-exposed ALB bypasses the API GW WAF).
  - S3 website redirect bucket: ~$0 but HTTP only (port 443 refused on the bare domain).
  - CloudFront + CloudFront Function + new apex ACM cert: $0 within free tier, HTTPS, no human
    step, but 5+ resources and a slow distribution for a redirect. Revisit only if Vercel is dropped.
- **Human step BEFORE apply:** attach the apex in Vercel first. An A record to Vercel that no
  project claims is the same takeover risk as an unclaimed Vercel CNAME (already documented on
  `custom_domain_vercel_hosts`): another Vercel account could serve its own page on our apex. If the
  Vercel domain panel shows a different apex IP (e.g. its newer range), set `dns_apex_a_records`.
- **Same switch for EXTERNAL.** `identity_custom_domains_enabled` covers both pools, so
  `auth.lumiguides.it.com` is created too (no live users). EXTERNAL clients still have **no
  branding style** (checked read-only: none of the 3 has one), so their managed login pages will not
  render until one is added; it needs its own header SVG without "Staff". Follow-up, not here.
- **Certificate wiring:** `local.id_custom_domain_cert_arn` = the variable if set, else
  `aws_acm_certificate_validation.auth[0].certificate_arn` (waits for ISSUED) when
  `custom_domains_enabled`, else `aws_acm_certificate.auth.arn`. No hardcoded ARN. The precondition
  "enabled needs the ARN variable" became meaningless and was removed.
- **DNS for the custom domains:** Route 53 alias A records from the domain resource's own
  `cloudfront_distribution` / `cloudfront_distribution_zone_id` (Z2FDTNDATAQYW2). A only, no AAAA
  (Cognito docs show A; the Cognito-managed distribution's IPv6 setting is not ours to see).
- **IAM:** AWS documents that creating a custom domain needs `cloudfront:UpdateDistribution` on the
  caller. Added statement `CognitoCustomDomainCloudFront` to the CI apply role's inline policy
  (`cicd_split.tf`, bootstrap grant). Policy grows to 8,882 of 10,240 chars. The custom domains
  `depends_on` the apex record and `time_sleep.wait_for_iam_propagation` (the existing gate that
  re-sleeps whenever that policy changes).
- **Branding:** `aws_cognito_managed_login_branding.workforce` for the 3 WORKFORCE clients, settings
  = `jsonencode(local.id_branding_settings_workforce)` (design spec, light mode only like `/login`),
  4 LIGHT assets from `accounts/aa365/assets/identity/`: `aa-form-logo.png` (official logo, copied
  from the CIS frontend `public/assets/adventure-asia-logo.png`), `aa-header-logo.svg` (mark +
  "Adventure Asia" + "Staff sign-in": Cognito has no text/title/font setting),
  `aa-footer-logo.svg`, `aa-favicon.svg`. `use_cognito_provided_values` is left out (conflicts with
  `settings`).
- **Import, then replace.** The 3 styles the CLI workaround created are adopted with `import`
  blocks (ID `<pool_id>,<branding_id>`, confirmed by the plan). The provider marks the `asset` set
  as RequiresReplace and the imported styles have no assets, so the plan is "imported, must be
  replaced": Terraform deletes and recreates each style (new `managed_login_branding_id`). Importing
  still matters: a plain create would fail because Cognito allows one style per client.
- Output `identity_branding_commands` (CLI workaround) removed; new output
  `identity_workforce_branding_ids`. `identity_managed_login_base_urls.workforce` now reads
  `https://staff-auth.lumiguides.it.com`; `.external` deliberately stays on the prefix URL until
  EXTERNAL has a style (pages on `auth.` would not render). Issuers unchanged (pool endpoint).
  Prefix domains kept.

## Review round (S242): applied / rejected

- Applied (medium): the replace deletes each style before creating the new one, and the payload has
  never been sent to Cognito, so a rejection would leave all 3 WORKFORCE clients (breakglass too)
  unstyled. No Terraform-side fix exists (one style per client rules out create_before_destroy), so
  the runbook gains a pre-validation step on an EXTERNAL client and the rollback commands (below).
  The payload file is extracted from the saved plan, so it is identical to what apply sends.
- Applied (low): import blocks + `id_branding_existing_workforce` marked for removal in a follow-up
  PR after the first apply (the IDs stop existing once replaced).
- Applied (low): `identity_managed_login_base_urls.external` kept on the prefix URL.
- Applied (low): footer no longer prints "adventure.asia" (a brand domain shown on a different
  domain is an impersonation signal): "© Adventure Asia · Internal staff access only".
- Applied (low): header and footer text outlined to SVG paths (Fahkwang SemiBold 22 px for
  "Adventure Asia", Poppins Regular 14/13 px) with fontTools from the Google Fonts OFL files; an SVG
  rendered as an image cannot load web fonts. Header viewBox widened 280 -> 296 (the real Fahkwang
  run is 180 px wide), footer 420 -> 288. Rendered with cairosvg and checked visually.
- Applied (low): Sid comment on `CognitoCustomDomainCloudFront` now says why `Resource "*"` is
  accepted (AWS-owned distribution, no ARN to scope to; no distributions in this repo).
- Applied (low): negative-cache wording: min(SOA TTL 900, SOA minimum) is about 15 min on Route 53,
  not a day.
- Rejected: none.

## Changed

- `dns.tf` + `ses_variables.tf`: apex A record + `dns_apex_a_records`.
- `identity_variables.tf`: `identity_custom_domains_enabled` default `true`; certificate variable is
  now an optional override.
- `identity.tf`: header comments, cert local, custom domains depends_on, alias records, branding
  locals/import/resource, outputs.
- `cicd_split.tf`: `CognitoCustomDomainCloudFront` statement.
- `custom_domains.tf`: comments only (where the apex record and cert consumer live).
- `assets/identity/*`: 4 files, ~41 KB total (header/footer text outlined to paths, see review).

## Plan (read-only, -lock=false, 18/10/2026)

`Plan: 3 to import, 9 to add, 5 to change, 4 to destroy.` Saved in
`AA-Ecosys/.tmp-session/s242/staffauth-plan.txt`.

- import 3 + replace 3: `aws_cognito_managed_login_branding.workforce[*]` (destroy+create).
- add: `aws_route53_record.apex`, `aws_cognito_user_pool_domain.{workforce,external}_custom[0]`,
  `aws_route53_record.identity_custom_domain["workforce"|"external"]`.
- change: `aws_iam_role_policy.tf_apply` (+1 statement). Ripple of that by design (AA-402 gate):
  `time_sleep.wait_for_iam_propagation` replaced (4th destroy), and the 4 `module.eventbridge`
  resources re-tagged with the new `_iam_gate` id (scheduler policy shows "known after apply"
  because its data source re-reads; content unchanged).
- **No change to user pools or app clients** (callback/logout URLs stay on aa-cis.).

## Tradeoffs

- Replace instead of in-place for the styles: each WORKFORCE client is unstyled for a few seconds
  during apply (managed login returns an error page in that window). Acceptable on Dev.
- Vercel apex needs a human step but gives HTTPS; CloudFront would avoid it at the cost of five
  more resources.
- White text on gold primary button (2.5:1) kept for brand parity with adventure.asia and `/login`;
  switch `primaryButton.lightMode.*.textColor` to `1f2933ff` if accessibility wins.

## Should know (apply runbook)

1. Nghiệp: Vercel → `aa-cis-frontend` → Settings → Domains → add `lumiguides.it.com`, redirect to
   `aa-cis.lumiguides.it.com`. (Vercel shows "Invalid configuration" until the A record exists.)
2. **Pre-validate the branding payload** on the EXTERNAL `tripplanner` client (pool
   `us-west-1_nKOvHan0W`, client `2fqmuij0lf47qpf1phjfcgseds`; no style, no users). The payload
   `AA-Ecosys/.tmp-session/s242/aa816-branding-prevalidate.json` was extracted from the saved plan
   (settings + the 4 assets exactly as apply sends them). Regenerate it whenever the plan is re-run
   with other settings/assets (`terraform show -json <plan>` ->
   `aws_cognito_managed_login_branding.workforce["cis-admin"].change.after`).
   - `aws cognito-idp create-managed-login-branding --cli-input-json file:///home/nghiep/projects/AA-Ecosys/.tmp-session/s242/aa816-branding-prevalidate.json --profile aa365-admin --region us-west-1`
   - Success: note the `ManagedLoginBrandingId`, optionally open the EXTERNAL prefix domain's
     `/login?client_id=2fqmuij0lf47qpf1phjfcgseds&response_type=code&redirect_uri=<a registered callback>`
     to eyeball the look, then delete it (EXTERNAL needs its own non-"Staff" header later):
     `aws cognito-idp delete-managed-login-branding --user-pool-id us-west-1_nKOvHan0W --managed-login-branding-id <id> --profile aa365-admin --region us-west-1`
   - Rejected: fix the setting (radius 24 -> 16; favicon without ICO -> add a FAVICON_ICO asset and
     `["ICO","SVG"]`), re-plan, regenerate the payload, repeat. Do not apply until it passes.
3. Local MFA apply (bootstrap grant in `cicd_split.tf`; CI cannot change its own policy).
4. If CreateUserPoolDomain fails with "unable to resolve the A record of the parent domain": a
   resolver may hold a negative answer for the apex (min(SOA TTL 900, SOA minimum), about 15 min on
   Route 53). Wait ~15 min and re-run the apply; everything else will already be in place.
5. **Rollback if apply leaves a WORKFORCE client without a style** (the removed
   `identity_branding_commands` output held these; pool `us-west-1_bCcFvbSOS`):
   - `aws cognito-idp create-managed-login-branding --user-pool-id us-west-1_bCcFvbSOS --client-id 3oqkumijh04cp81k3nlnub6qtv --use-cognito-provided-values --profile aa365-admin --region us-west-1` (cis-admin)
   - `aws cognito-idp create-managed-login-branding --user-pool-id us-west-1_bCcFvbSOS --client-id 5ifl9dgkr8a5outnmsjc8v1kt3 --use-cognito-provided-values --profile aa365-admin --region us-west-1` (booking-staff)
   - `aws cognito-idp create-managed-login-branding --user-pool-id us-west-1_bCcFvbSOS --client-id 2g3f3ncfuqdiuu1o5b70o4h0lq --use-cognito-provided-values --profile aa365-admin --region us-west-1` (breakglass)
   Then drop the affected `aws_cognito_managed_login_branding.workforce[...]` from state (or import
   the new ID) before the next plan.
6. The custom domain can take up to ~1 hour before CloudFront serves it. Verify:
   `curl -sI https://staff-auth.lumiguides.it.com/.well-known/openid-configuration` (Cognito serves
   that endpoint on the custom domain only), then a real sign-in from aa-cis.
7. Only after that, switch the CIS frontend hosted domain to `https://staff-auth.lumiguides.it.com`
   (separate CIS PR). The prefix domain keeps working meanwhile, so the order is safe.
8. Re-plan: expect `No changes` (import blocks are skipped once the resources are in state).

## Follow-ups (not in this PR)

- Remove the 3 import blocks + `id_branding_existing_workforce` after the first apply.
- EXTERNAL managed login style (own header SVG without "Staff"), then switch
  `identity_managed_login_base_urls.external` to `auth.`.
- Long term: move the admin sign-in under `adventure.asia` (e.g. `admin.adventure.asia`) to remove
  the brand/domain mismatch entirely (business decision).
