# AA-1111 slice S2 — staff web hosts leave the WAF geo rule (lane l17, S285)

Tech lead decision S285: drop the WAF geo rule for the staff hosts once administrator MFA is enforced.

## Decisions
- **Merge only after the three MFA switches are on** (CIS `cis.platform.admin_mfa_required`, CRM
  `crm.platform.admin_mfa_required`, Booking `staff_admin_mfa_required`; runbook `docs/runbooks/staff-admin-mfa.md`
  section D). Until then the geo list is the only extra guard of an administrator session signed in with an e-mail code.
- **How**: the staff web hosts (`local.staff_web_hosts`: CIS admin, Booking admin) join `geo_exempt_hosts` (the AA-1092
  scope-out of the API hosts). No new rule, no module change; GeoBlockNonAllowed keeps the country list for every other
  host on the ACL (apex redirect, the test WordPress host).
- The CRM web (agency host `portal.`) is on CloudFront with no geo restriction already; the Cognito managed login host
  has its own identity ACL without a geo rule. Neither changes.

## Changed
- One in-place update of the regional web ACL (the geo exemption regex gains two hosts). 0 USD.

## Tradeoffs
- Staff hosts are reachable from any country (VPN on or off). CommonRuleSet, the per-IP rate rules and StaffWebRateLimit
  still apply; the apps require Cognito sign-in on every page and TOTP for administrators.

## Should know
- Roll back: revert this PR and Terraform Apply Dev (the geo rule covers the staff hosts again).
