# AA-1038 — TripPlanner web WAF rules move into the ALB web ACL (S272 follow-up, lane l16)

Tech-lead decision 08/11/2026 (cost): no Bot Control, no CLOUDFRONT web ACL of its own. The edge applied by Infra
#722 + #725 had a CLOUDFRONT-scope web ACL `aa-tripplanner-dev-web` (5 USD/month fixed + 3 rules). Its output
`waf_integration_url` stayed empty: AWS WAF returns `ApplicationIntegrationURL` (challenge.js) only for a web ACL that
uses a paid intelligent-threat managed group (Bot Control, ATP, ACFP), so the planner's background token design could
not work.

## Decisions

- **Three rules in the existing regional web ACL `aa-<env>-waf` (modules/waf, input `tripplanner_web`)**, renamed
  with a `TripPlanner` prefix because the ACL is shared: `TripPlannerRateLimitPerIp` (3000 / 5 min),
  `TripPlannerRateLimitModelPaths` (100 / 5 min on `/api/browse/search` + `/api/trip/narrate` + `/api/trip/send`,
  see the send bullet below), both 429 JSON
  `{"error":"rate_limited"}`; `TripPlannerChallengePlanner` (Challenge on a GET `sec-fetch-dest: document` of
  `/plan`, `/{tenant}/plan` and below, OR a protected path). Same limits, same paths, same URL_DECODE + NORMALIZE_PATH on
  every path match (the dot-segment note stays in `tripplanner_web_edge.tf`).
- **Scope: Host `tripplanner.<zone>` (regex, LOWERCASE, optional `:443`, like the staff rule) AND the exact origin
  secret `X-AA-Origin`.** The secret makes "came through our CloudFront" part of every rule, so a request sent straight
  at the internet-facing ALB with a TripPlanner Host is never counted or challenged, and no other host (CIS, Booking,
  CRM, portal, staff, the API Gateway path, whose Host API Gateway rewrites to the NLB name) is touched. The module
  creates the rules only when `origin_verify_header` is set too (`local.tp_on`).
- **Order: after CommonRuleSet, before both allow rules.** `CloudFrontOriginAllow` ends the evaluation for every
  CloudFront request, so the TripPlanner rules must come before it; they also come before `VpcLinkInternalAllow`
  because the AA-931 spike kept both cases open (VPC-origin traffic with a CloudFront source, or NATed to a VPC
  address). Priorities moved to one map `local.rule_priorities` (like `alb_rules.tf`): 1 Common, 2-4 TripPlanner,
  5 VpcLinkInternalAllow (was 2), 6 CloudFrontOriginAllow (was 3), 7 RateLimit1000 (was 4), 8 GeoBlockNonAllowed
  (was 5), 9 StaffWebRateLimit (was 6). Only the numbers change for the old rules; their relative order is the same,
  so nothing changes for any other host. A test refuses a literal rule priority.
- **Viewer address: a CloudFront viewer-request function, not X-Forwarded-For.** At the ALB the source address is
  CloudFront's. AWS WAF's forwarded-IP rate key takes the FIRST address of a header, and CloudFront appends the viewer
  to whatever X-Forwarded-For the viewer sent, so XFF would let a script pick its own key per request.
  `CloudFront-Viewer-Address` carries a port (`ip:port`), not a valid key. The function
  `aa-tripplanner-<env>-web-viewer-ip` writes `x-aa-viewer-ip` = `event.viewer.ip` on every request (over any value
  the viewer sent), on all three behaviours (a cache miss of a chunk or a photo reaches the ALB too). Same feature as
  `crm_edge.tf` (CloudFront Functions, already in use, apply grant `cloudfront:*Function*` in place). Fallback MATCH:
  an invalid value is counted under the fallback, never skipped.
- **Challenge at ALB scope uses the ALB web ACL's token.** The token is issued for the request's host
  (`tripplanner.<zone>`, the Host CloudFront forwards with `AllViewerAndCloudFrontHeaders`), so no `token_domains`
  change. The token lifetime (`tripplanner_web_challenge_immunity_s`, 4 h) is set on the rule's own
  `challenge_config`, so the ACL default (300 s) stays as it is for every other host. Provider 6.69 accepts the
  rule-level block (`terraform validate`).
- **No new WAF log:** the ACL already logs the requests a rule acted on (BLOCK / CHALLENGE / ...), 30 days.
- **Send to advisor is a protected path too (review S272, fix pass).** On Vercel BotID guarded `POST /api/trip/send`
  (it stores a traveller's contact and delivers it to an agency); the ECS image builds BotID off, so the first version
  of these rules left it with only the 3000 / 5 min per-IP rule and the Lambda's limits. `local.tp_web_model_paths`
  became `local.tp_web_protected_paths` = the two model paths + `/api/trip/send` (module input `protected_paths`),
  used by rule 3 (100 / 5 min per viewer) and rule 4 (Challenge). The rule names stay (no rule is added, no WCU
  change worth noting: one more path match per rule). The app's edge gate answers the older spelling
  `POST /api/trip {op:"send"}` 404 `use_protected_path` (AA-TripPlanner-Web), so a lead passes only through the
  challenged path. A challenged send in the planner keeps the form and asks the traveller to reload the page (no
  automatic reload: it would lose what they typed).

## Changed

- `modules/waf`: `variable "tripplanner_web"` (object, default null), `local.tp_on`, `local.tp_host_regex`,
  `local.rule_priorities`, the ACL-level `custom_response_body` `rate_limited` (only with the rules), the three rules,
  outputs `web_acl_name` and `tripplanner_web_rule_names`; the other rules take their number from the map.
- `accounts/aa365/tripplanner_web_edge.tf`: `aws_wafv2_web_acl.tripplanner_web` and the distribution's `web_acl_id`
  removed; `aws_cloudfront_function.tripplanner_web_viewer_ip` (+ `cloudfront_functions/tripplanner_web_viewer_ip.js`)
  on the three behaviours; output `waf_integration_url` removed, `web_acl_name` now the ALB ACL, `waf_rules` added;
  header comment, variable descriptions and cost.
- `accounts/aa365/main.tf`: module `waf` gets `tripplanner_web` (null while the edge is off).
- Tests: `test_aa1038_tripplanner_web.py` section 3 rewritten (no CLOUDFRONT ACL / integration URL, order, scope,
  forwarded-IP key, rule-level token lifetime, the function on every behaviour, the function run with node when
  available, path normalization); `CONTEXT.md`; `AA-1038-hosting.md` marks the superseded bullets.

## Tradeoffs

- The rate rules now see only the requests that reach the ALB (CloudFront serves cached chunks and photos itself);
  3000 / 5 min per viewer is looser in practice than at the CloudFront scope. Pages, BFF calls and cache misses are
  what costs the task anything, so the limit is kept.
- One CloudFront Function invocation per viewer request: free under 2M a month (shared with the CRM partner
  function), 0.10 USD per million after.
- The old CloudFront ACL saw the viewer address natively; the header is as good only while every behaviour runs the
  function (a test guards the three associations).
- Renumbering the old rules is an in-place `UpdateWebACL` (AWS replaces the rule list in one call); no window where
  a rule is missing.

## Should know

- **Expected plan** (Terraform Apply workflow, CI role; no bootstrap step): 1 to add
  (`aws_cloudfront_function.tripplanner_web_viewer_ip[0]`), 2 to change in place (`module.waf.aws_wafv2_web_acl.main`:
  three rules added, priorities of five renumbered, one custom response body; `aws_cloudfront_distribution.tripplanner_web[0]`:
  `web_acl_id` removed, three function associations added), 1 to destroy (`aws_wafv2_web_acl.tripplanner_web[0]`, the
  CLOUDFRONT ACL in us-east-1). The destroy runs after the distribution update (Terraform orders the dependency), so
  DeleteWebACL never meets an associated ACL. Nothing else.
- WCU (est.): the three rules ~ 200 (regex 3 + LOWERCASE 10 per host match, 2 per exact header match, 22 per path
  match with two transformations, 30 for CONTAINS), the ACL ~ 940 in all, under the 1500 included in the price.
- After apply: `aws wafv2 get-web-acl` on `aa-cis-dev-waf` shows the 9 rules in order; with the task at 0 the
  checks through the distribution (`--resolve`) show `/api/browse/search` and `POST /api/trip/send` 202 +
  `x-amzn-waf-action: challenge` without a token (the WAF answers before the ALB rule), and `/plan` with
  `sec-fetch-dest: document` the same (202 only: with no token a working rule never answers 200).
- **Cost (D-19):** 3 rules x 1 USD + requests 0.60 USD/M (Dev: cents) + Challenge attempts (cents) + function 0 =
  ~ 3.1 USD/month for the edge, ~ 9.5 USD/month with the task running (was ~ 14.5); saves the web ACL's 5 USD fee.
  No new paid feature: WAF rules, Challenge and CloudFront Functions were all in use.
- Companion PRs: root runbook `docs/ops/runbooks/tripplanner-web-ecs-cutover.md` (merged after this one), then
  AA-TripPlanner-Web (full page loads into the planner, no `TP_WAF_INTEGRATION_URL`).
