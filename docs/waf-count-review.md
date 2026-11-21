# Runbook — review WAF CommonRuleSet counts before enforcing

`aa-cis-dev-waf` runs `AWSManagedRulesCommonRuleSet` in COUNT (`var.waf_common_rules_count_only =
true`, count window started 14/10/2026). Do not flip it to `false` until the counts have been
reviewed. Nothing here changes the web ACL.

## 1. How much was counted

CloudWatch metric `AWS/WAFV2` `CountedRequests`, rule = the group's metric name. Hourly sums over
the window (adjust the dates):

```
aws cloudwatch get-metric-statistics --namespace AWS/WAFV2 --metric-name CountedRequests --dimensions Name=WebACL,Value=aa-cis-dev-waf Name=Region,Value=us-west-1 Name=Rule,Value=AWSManagedRulesCommonRuleSet --start-time 2026-10-14T00:00:00Z --end-time 2026-10-16T00:00:00Z --period 3600 --statistics Sum --profile aa365-admin --region us-west-1
```

Compare with `AllowedRequests` (same dimensions, `Rule=ALL`) to get the share of traffic that
would have been blocked.

## 2. Which sub-rules and which requests

Log group `aws-waf-logs-aa-cis-dev` (30-day retention). With the group overridden to COUNT, the
match is in the rule-group entry, not in `terminatingRuleMatchDetails`. CloudWatch Logs Insights
query (console, or `aws logs start-query` + `aws logs get-query-results`):

```
fields @timestamp, httpRequest.clientIp, httpRequest.country, httpRequest.httpMethod, httpRequest.uri, ruleGroupList.0.terminatingRule.ruleId as subRule
| filter ruleGroupList.0.ruleGroupId like /AWSManagedRulesCommonRuleSet/ and ispresent(ruleGroupList.0.terminatingRule.ruleId)
| stats count(*) as hits by subRule, httpRequest.httpMethod, httpRequest.uri
| sort hits desc
| limit 50
```

The labels `awswaf:managed:aws:core-rule-set:<SubRule>` in the `labels` field name the same
sub-rules.

## 3. Decide

- Matches only on scanner traffic (unknown paths, foreign IPs) → safe to enforce.
- Matches on real app traffic (typical: `SizeRestrictions_BODY` on large admin/portal uploads,
  `CrossSiteScripting_BODY` on HTML content saves, `NoUserAgent_HEADER` from server-to-server
  calls) → make sure that sub-rule is in the module's `managed_rule_count_overrides` list
  (`modules/waf/variables.tf`; those stay COUNT after the group is enforced) first.
- Then set `waf_common_rules_count_only = false` in a PR, plan, apply, and watch `BlockedRequests`
  plus the app's 4xx for a day.

## Result of the review (AA-806, S239, 16/10/2026)

- Count window 14/10 02:00Z .. 16/10 04:01Z: about 70.7k requests in `aws-waf-logs-aa-cis-dev`,
  **0** CommonRuleSet matches. The 138 earlier matches (14/10 00:33-01:56Z, NoUserAgent_HEADER and
  UserAgent_BadBots_HEADER) were scanners hitting the ALB directly before its SG was narrowed to the
  VPC CIDR, while the group still blocked. Dev has no real users, so no real write was over 8 KB.
- Pre-flip test with large real content writes (bodies 9.9-19.9 KB, random non-existent ids so the
  app answers 404 and nothing changes): every body over 8 KB matched `SizeRestrictions_BODY`
  (in the override list); every body whose first 8 KB holds a relative `../` link (HTML `href`/`src`
  or markdown) matched **`GenericLFI_BODY`** (not in the list, so it would have blocked). Typical
  HTML did not match `CrossSiteScripting_BODY`. Evidence: root repo
  `docs/audits/2026-10-16-S239-in-progress-audit/aa806-waf/`.
- Decision: `GenericLFI_BODY` added to `managed_rule_count_overrides`, then
  `waf_common_rules_count_only = false`. After the apply, repeat the test script and check that
  `BlockedRequests` for `AWSManagedRulesCommonRuleSet` stays 0 for app traffic.

### Re-run the pre-flip test

The scripts live in the audit folder above (`scripts/`). They read the e2e admin, tenant and Booking
staff credentials from Secrets Manager at run time, never print them, and only PATCH random ids.

## CloudFrontViewerRateLimit (AA-1165): count window, flip, change the limit

Rule `CloudFrontViewerRateLimit` of `aa-cis-dev-waf` limits each viewer on the CloudFront path of the CRM hosts
(partner, agency with the Academy alias, client) to `crm_edge_rate_limit` requests per 5 minutes (default 5000,
`accounts/aa365/crm_edge.tf`). The key is the header `x-aa-viewer-ip`, which the distributions' viewer-request
functions write from the viewer's own address. TripPlanner traffic (its own rules) and our NAT egress are scoped out.
It started in COUNT (`crm_edge_rate_count_only = true` in `accounts/aa365/terraform.tfvars`).

1. Normal use stays under the limit: browse the agency host for a few minutes, then read the rule's counts (0 is the
   expected answer for one person):

   ```
   aws cloudwatch get-metric-statistics --namespace AWS/WAFV2 --metric-name CountedRequests --dimensions Name=WebACL,Value=aa-cis-dev-waf Name=Region,Value=us-west-1 Name=Rule,Value=CloudFrontViewerRateLimit --start-time <UTC start> --end-time <UTC end> --period 300 --statistics Sum --profile aa365-admin --region us-west-1
   ```

2. A burst from one address past the limit is counted (COUNT) or refused with 429 (BLOCK). Two things make a naive
   burst prove nothing:
   - The CRM API limits its public routes itself (AA-Partner `app.ratelimit`, `crm.rate.public_per_minute`, 60 a
     minute per viewer by default), and `/crm/health` is one of them. Most of a burst is answered 429 by the app
     whether or not this rule exists, so a tally of status codes alone looks like a pass. Tell the two answers apart
     by the body: the WAF answers `{"error":"rate_limited"}`, the app `{"detail":"rate_limited"}`.
   - AWS WAF evaluates rate rules with a delay of up to about a minute. A burst that ends a few seconds after it
     crosses the limit may see no WAF answer at all. Go well past the limit and keep it up for at least 2 to 3
     minutes.

   Burst on the CRM API health path of the partner host (only `/crm` and `/crm/*` reach the origin there, every
   other path is a 301 at the edge), 18000 requests with 20 in parallel (about 3 minutes at about 100 requests a
   second), and tally the status code with the first JSON key of the body:

   ```
   seq 18000 | xargs -P 20 -I{} sh -c 'echo "$(curl -s -w " %{http_code}" https://partner-dev.lumiguides.it.com/crm/health)"' | sed -E 's/^\{"([a-z_]+)".* ([0-9]{3})$/\2 \1/' | sort | uniq -c
   ```

   (Each line is written by one `echo`, so the 20 parallel calls cannot interleave inside a line.) Read the tally: `200 status` = served, `429 detail` = the app's own limiter, `429 error` = this WAF rule. In COUNT
   expect `200 status` and `429 detail` lines only; in BLOCK expect a non-zero `429 error` line. If the run took less
   than 2 minutes, run it again at once (the 5-minute window still holds the first run's count).

   The required evidence is the rule's own metric, not the tally: a non-zero sum of `CountedRequests` (COUNT) or
   `BlockedRequests` (BLOCK) for `Rule=CloudFrontViewerRateLimit` over the burst minutes (period 60; the metric can
   take a few minutes to appear):

   ```
   aws cloudwatch get-metric-statistics --namespace AWS/WAFV2 --metric-name CountedRequests --dimensions Name=WebACL,Value=aa-cis-dev-waf Name=Region,Value=us-west-1 Name=Rule,Value=CloudFrontViewerRateLimit --start-time <UTC burst start> --end-time <UTC burst end + 5 min> --period 60 --statistics Sum --profile aa365-admin --region us-west-1
   ```

   (`--metric-name BlockedRequests` for BLOCK.) Then wait out the 5-minute window before using the CRM from that
   address again.
3. To flip to BLOCK: a PR that removes the `crm_edge_rate_count_only = true` line from `terraform.tfvars` (the
   variable defaults to `false`), plan, apply, repeat step 2 and expect a non-zero `429 error` line in the tally
   (the WAF body `{"error":"rate_limited"}`; `429 detail` lines are the app and do not count) plus a non-zero
   `BlockedRequests` sum for `Rule=CloudFrontViewerRateLimit`.
4. To change the limit: set `crm_edge_rate_limit = <n>` in `terraform.tfvars` (a whole number of at least 100), plan,
   apply. The value in force is published read-only in the root output `platform_limits` (`waf` group).

5. Alarm: `aa-cis-dev-crm-edge-rate-blocked` sends to the alerts topic when the rule blocks at least
   `crm_edge_rate_alarm_threshold` requests in 5 minutes (default 1, `accounts/aa365/crm_edge.tf`; 0.10 USD/month).
   Change the threshold in `terraform.tfvars`, plan, apply.

The WAF log (`aws-waf-logs-aa-cis-dev`, only requests a rule acted on) records each counted or blocked request with
`CloudFrontViewerRateLimit` as the matching rule.
