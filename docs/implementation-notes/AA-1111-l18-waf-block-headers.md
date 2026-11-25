# AA-1111 — security headers on the managed WAF blocks (S294, lane l18-waf-block-headers)

Source: the S294 ZAP re-run (root `docs/audits/2026-11-25-S294-session/zap-baseline.md`, "Update after the
security-headers lane"). ZAP's first requests carry no User-Agent; the CommonRuleSet sub-rule `NoUserAgent_HEADER`
blocks them and the ALB answers its own bare 403 (no HSTS, CSP or Permissions-Policy, `Server: awselb/2.0`). The S284
change (`AA-1111-headers.md`) covered the rules this module defines, not the managed group.

## Decisions

- **Rule action overrides, not a label rule.** Each of the 22 CommonRuleSet sub-rules gets a `rule_action_override`:
  COUNT for `var.managed_rule_count_overrides` (unchanged), else BLOCK with the custom response. BLOCK is the
  sub-rule's own action, so no match and no count/block decision changes, the terminating rule in the WAF log stays
  `AWSManagedRulesCommonRuleSet`, no WCU is added and no rule is added (0 USD). The alternative (group rules to COUNT
  + one label-match rule that blocks) costs a rule fee of 1 USD a month and moves the terminating rule.
- **The sub-rule list is pinned** (`local.common_rule_set_rules`), read live with `describe-managed-rule-group` on
  25/11/2026 (default version `Version_1.23`, 22 rules, all Block) and equal to the AWS developer guide list. A count
  override name not in the list is appended (COUNT). A sub-rule AWS adds in a later version still blocks, with the
  plain 403, until it is added to the list and the test.
- **Four headers, not six.** AWS WAF allows 100 custom response headers per web ACL (default quota, adjustable for
  free). The Dev ACL now answers 25 custom responses (19 managed blocks, the two TripPlanner 429s, the CloudFront viewer
  429, RateLimit1000, GeoBlockNonAllowed, StaffWebRateLimit): 25 x 4 = 100. The set is HSTS (the apps' value),
  `nosniff`, CSP `default-src 'none'; frame-ancestors 'none'` and the apps' Permissions-Policy. `X-Frame-Options` left
  the set: CSP `frame-ancestors` supersedes it in every current browser and ZAP's anti-clickjacking rule accepts it.
  `Referrer-Policy` is moot on a text/plain body with no link.
- **One static body** `blocked` ("Request blocked.", text/plain) on every 403 of the ACL (managed blocks and the three
  plain rules, which answered an empty body since S284).
- **Plan-time guard.** A `precondition` on the web ACL fails the plan when the header count passes
  `var.custom_response_header_quota` (default 100), instead of UpdateWebACL failing mid-apply.

## Changed

- `modules/waf/main.tf`: header set, `common_rule_set_rules` / overrides / quota locals, the `blocked` body, the
  overrides of the managed group, the body key on the three 403 rules, the precondition.
- `modules/waf/variables.tf`: `custom_response_header_quota` (an AWS quota mirrored in Terraform, not an app threshold:
  no admin setting applies).
- Priorities, statements, scopes and the group-level `common_rules_count_only` switch unchanged (checked in the plan
  JSON: every rule equal before and after except its action / overrides).

## Tradeoffs

- Headroom is zero on Dev: the next block rule of this ACL needs the quota raised first (Service Quotas, free), then
  the variable. The precondition says so at plan time.
- Overrides depend on the sub-rule names; the alternative label rule would cover future sub-rules but costs money and
  changes the logs.
- The ALB's `Server: awselb/2.0` on a response it builds from a WAF block cannot be removed (no ALB option): accepted.

## Should know

- Local targeted plan (read-only, `-lock=false`, 25/11/2026): `module.waf.aws_wafv2_web_acl.main` updated in place,
  7 rules change (CommonRuleSet, the two TripPlanner rate rules, CloudFrontViewerRateLimit, RateLimit1000,
  GeoBlockNonAllowed, StaffWebRateLimit), one body added; no replacement. 25 custom responses, 100 headers.
- If the apply fails with `WAFLimitsExceededException`, AWS counts the quota differently than assumed: the ACL stays
  as it was (UpdateWebACL is atomic); raise the quota or drop Permissions-Policy from the set.
- After apply: `curl -s -o /dev/null -D - -H 'User-Agent:' https://aa-cis.lumiguides.it.com/robots.txt` shows 403 with
  `strict-transport-security`, `x-content-type-options`, `content-security-policy`, `permissions-policy`.
- Static test: `tools/terraform/tests/test_aa1111_security_headers.py`.
