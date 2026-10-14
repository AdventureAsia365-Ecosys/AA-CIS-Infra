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
