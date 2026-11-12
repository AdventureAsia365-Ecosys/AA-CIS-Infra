# AA-1092 — web ACL coverage of the public hosts (S278 system audit M24)

## Public hosts and their edge controls (read from the Terraform of `accounts/aa365`, S278)

| Host | Path to the app | Web ACL | Other edge controls |
|---|---|---|---|
| `api-cis.<zone>`, `api-cis-aa365.<zone>` | REST API (CIS stage) → VPC link → NLB → ALB | `aa-cis-dev-waf` on the stage (this change) and on the ALB | stage method throttles (AA-876) |
| `api-booking.<zone>` | REST API (Booking stage) → VPC link → NLB → ALB | `aa-cis-dev-waf` on the stage (this change) and on the ALB | stage method throttles, M2M scopes |
| `api-tripplanner.<zone>` | HTTP API → browse / assembly Lambdas | HTTP APIs take no web ACL (AWS) | edge key, signed tenant assertion, stage throttles, per-IP AI limits in the app |
| `tripplanner.<zone>` | CloudFront → VPC origin → NLB → ALB | `aa-cis-dev-waf` (ALB): rules 2-4 scoped to this host | viewer-IP function, Challenge on the planner |
| CRM partner / agency / client hosts | CloudFront → VPC origin → NLB → ALB | `aa-cis-dev-waf` (ALB): CommonRuleSet, then CloudFrontOriginAllow | per-viewer rate limits in the CRM app (AA-933, `CloudFront-Viewer-Address`) |
| `aa-cis.<zone>`, `booking.<zone>`, apex | ALB :443 | `aa-cis-dev-waf` (ALB): StaffWebRateLimit, GeoBlock | Cognito WORKFORCE on every page |
| `test-wp.<zone>` | ALB :443 | `aa-cis-dev-waf` (ALB) | test site only |
| photos CDN host | CloudFront → S3 (read-only images) | none (static objects) | origin access control, cache |
| `auth.`, `staff-auth.`, partner auth, M2M token domain | Cognito managed login / OAuth endpoints | `aa-identity-dev-pools`: WORKFORCE, EXTERNAL, PARTNER, and M2M (this change) | pre sign-up trigger, MFA (staff) |

Items that are not changed here are tracked in Linear AA-1092.

## Decisions

- **REST stages on** (`waf_protect_rest_api_stages = true`). Both blockers in the variable's note are resolved:
  the apply role has `apigateway:SetWebACL` (cicd_split.tf), and the geo concern is handled by scoping the API hosts
  out of GeoBlock (travellers anywhere load catalogue images from api-cis; partner agencies are not limited to the
  staff country list).
- **NAT egress scoped out of RateLimit1000.** The CRM and the staff web call api-cis / api-booking server to server
  from the NAT instance EIP: one address for every internal caller. A /32 IP set (`internal_egress`) built from the
  EIP output; still inspected by CommonRuleSet.
- **Shapes kept within 2 logical levels** (NOT (staff host OR egress); AND(NOT geo, NOT api host)): under the
  3-level limit `test_waf_statement_depth.py` enforces. A real `terraform plan` ran locally (S272 lesson): valid.
- **M2M pool on the identity ACL.** GlobalRatePerIp covers its token endpoint; the other identity rules are scoped
  to managed login and sign-up paths. No new ACL or rule.
- **Apply role:** `wafv2:*IPSet*` replaces `wafv2:GetIPSet` + `wafv2:ListIPSets` (create/update/delete of the new
  IP set; shorter than before under the inline policy's 10,240-character limit). `cicd.tf` is a bootstrap object.

## Changed

- `modules/waf`: variables `rate_limit_exempt_cidrs`, `geo_exempt_hosts`; IP set `internal_egress`; the scope-downs
  of RateLimit1000 and GeoBlockNonAllowed.
- `accounts/aa365/main.tf` (module inputs), `variables.tf` (note), `terraform.tfvars` (the switch),
  `identity_m2m.tf` (association), `identity.tf` (ACL description), `cicd.tf` (IP set verbs).
- `tools/terraform/tests/test_aa1092_waf_hosts.py`.

## Cost (estimate, list prices, us-west-1)

- No new web ACL and no new rule: 0 USD fixed. IP sets carry no fee.
- Requests inspected: 0.60 USD per million on the two stages and the M2M pool. Dev traffic is well under one
  million requests a month: under 0.60 USD a month. WAF logs keep only acted-on requests (S263).

## Should know

- Apply: this PR changes a bootstrap object (`cicd.tf` WAFv2Manage), so apply it locally with the MFA admin
  profile (or `-target` the apply role's inline policy first), then run one CI Terraform Apply no-op (S274 lesson).
- Local plan (read-only, `-lock=false`, S278): 4 to add (IP set, 2 stage associations, M2M association), the two web
  ACLs updated in place, 0 to destroy. The identity trigger and SES receipt rule updates in a local plan come from
  the local archive hash, not this change.
- After apply, check in the WAF sampled requests of `aa-cis-dev-waf` that api-cis requests show viewer addresses
  (not CloudFront ranges), and that no CRM → CIS / Booking call is blocked (`RateLimit1000` metric stays 0 for the
  NAT address).
