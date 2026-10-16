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
