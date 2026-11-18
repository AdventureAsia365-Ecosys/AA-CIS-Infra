# AA-1111 — security headers at the edge (S284, lane l5-aa1111-headers)

Source: the S283 ZAP baseline triage (root `docs/audits/2026-11-17-S283-access-review/zap-baseline.md`). The apps
send the headers on their own responses (AA-CIS-App, AA-Booking, AA-Partner, AA-TripPlanner-Web PRs of the same
wave); this PR covers the answers the edge gives itself.

## Decisions

- **HSTS where it belongs.** Every host is served by an app that sets HSTS itself (Next.js admins, CRM web,
  TripPlanner, FastAPI APIs), so HSTS stays in the apps. The edge only adds it to the responses no app sees:
  the WAF block answers and the API Gateway gateway responses. No CloudFront response-headers policy: the
  CloudFront hosts (CRM web, TripPlanner) already pass the app's headers.
- **WAF**: the five block actions (RateLimit1000, GeoBlockNonAllowed, StaffWebRateLimit, the two TripPlanner rate
  rules) answer a custom response with `local.security_response_headers`. The S283 run counted the WAF 403s of
  `aa-cis.` and `booking.` (Server `awselb/2.0`, no HSTS / CSP / Permissions-Policy) as the admins' pages.
  403 stays the status of the three plain blocks; the body is empty (it was AWS's default 403 text).
- **API Gateway**: `DEFAULT_4XX` and `DEFAULT_5XX` gateway responses on both REST APIs with HSTS + `nosniff` and the
  documented default template `{"message":$context.error.messageString}` (a gateway response without a template
  answers an empty body). Both deployments hash them and depend on them (AA-432 trap).
- **HSTS value** = the apps' value (two years, sub-domains, no preload).

## Changed

- Nothing else in the ACL: priorities, statements and scopes unchanged (test_waf_statement_depth, the AA-1038 and
  AA-1092 tests still pass).

## Tradeoffs

- The ALB's `Server: awselb/2.0` on a WAF block cannot be removed (no ALB option); accepted (cosmetic, ZAP Low).
- A CSP on a WAF block is `default-src 'none'`: the answer has no page to render.

## Should know

- Plan expectation: in-place update of the web ACL (5 rule actions), 4 new `aws_api_gateway_gateway_response`, a new
  deployment of each REST API (create_before_destroy) and the stage pointing at it. No replacement, no cost.
- After apply: `curl -sI https://api-cis.lumiguides.it.com/nope` (gateway 403) shows `strict-transport-security` and
  `x-content-type-options: nosniff`; the same on `https://api-booking.lumiguides.it.com/nope`.
- Static test: `tools/terraform/tests/test_aa1111_security_headers.py`.
