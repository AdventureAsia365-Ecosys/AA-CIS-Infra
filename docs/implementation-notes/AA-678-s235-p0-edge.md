# AA-678 — S235 Phase 0: edge hardening (ALB SG, WAF order, TripPlanner trust, RDS)

Branch `feat/s235-p0-edge-hardening`. Part of the ecosystem blueprint Phase 0 approved in S235.

## Decisions

- **ALB SG closed to the VPC CIDR on :80; :443 removed.** Live check 14/10/2026: no DNS record
  points at the ALB (`api-cis.lumiguides.it.com` -> API GW regional domain `d-p5fej4ddcg`,
  `aa-cis.lumiguides.it.com` -> Vercel), no app/env config contains the ALB hostname, the ECS
  task definitions only carry `REDIS_HOST`. The NLB (`aa-cis-dev-nlb`, scheme `internal`) targets
  the ALB on :80 only. VPC-link (PrivateLink) traffic and NLB health checks reach the ALB from the
  NLB's private IPs, inside `10.2.0.0/16`.
- **CIDR, not the NLB SG id, as source.** The ALB SG lives in `modules/vpc` with inline rules;
  the NLB SG lives in `modules/alb`, which already consumes `module.vpc.sg_alb_id`. Referencing the
  NLB SG from the ALB SG would create a module cycle or require mixing inline and standalone rules.
  The VPC CIDR is what the NLB SG itself uses.
- **WAF rule order: CommonRuleSet (1) -> VpcLinkInternalAllow (2) -> RateLimit (3) -> Geo (4).**
  The VPC allow rule cannot be removed while the ACL sits on the ALB: the ALB only ever sees NLB
  private IPs, so rate would treat all users as 2 IPs and geo would block everything (private IPs
  match no country). Rate + geo only make sense where the client IP is real -> REST API stages.
- **Same web ACL on the CIS (4ylo382khg) and Booking (9z3xnalp59) REST stages**, scope REGIONAL so
  it can be reused. Gated by `var.waf_protect_rest_api_stages` (default false) because the CI role
  has no `apigateway:SetWebACL` (cicd.tf `APIGatewayManage` grants only GET/POST/PUT/PATCH/DELETE
  + Tag/Untag) and cicd.tf is out of scope for this PR.
- **Managed rule overrides to COUNT:** `SizeRestrictions_BODY` (bodies > 8 KB: uploads, large admin
  JSON) and `CrossSiteScripting_BODY` (HTML in tour content). These requests never reached the
  managed rules before (7-day WAF metrics: 224,781 requests allowed by VpcLinkInternalAllow).
- **TripPlanner trust = one exact sub** (`StringEquals`):
  `repo:AdventureAsia365-Ecosys@276539096/AA-TripPlanner-Web@1365222661:ref:refs/heads/main`.
  Only `deploy-lambdas.yml` (job `deploy`, no `environment:`) assumes the role; `ci.yml` has no
  `id-token`.
- **RDS:** `deletion_protection = true`. Backup retention is already 7 days (live and in code), no
  change.

## Changed

- `modules/vpc/main.tf` ALB SG ingress; `modules/waf/*` order + overrides + stage associations;
  `modules/api_gateway/outputs.tf` `stage_arn`; `accounts/aa365/main.tf` + `variables.tf` wiring;
  `accounts/aa365/tripplanner.tf` trust; `modules/rds/main.tf`; comments in `modules/alb/main.tf`
  and `accounts/aa365/booking.tf` (EXPOSURE paragraph).

## Tradeoffs

- ALB stays `internet-facing` (scheme change replaces the ALB, its DNS name, the NLB target and
  the listener rules). With the SG closed it is unreachable from the internet anyway; making it
  internal is a later, separate change.
- The HTTPS listener stays (now unreachable). Deleting it is cleanup, not security.
- Geo allow-list (10 countries) is fine for CIS staff and Vercel (US) but would block Booking
  customers elsewhere: confirm before turning on the stage association.

## Should know

- Local speculative plan (14/10/2026, `-lock=false`, real state): 0 add, 5 change, 0 destroy:
  `aws_iam_role.tripplanner_app_deploy`, `module.rds.aws_db_instance.main`,
  `module.vpc.aws_security_group.alb`, `module.waf.aws_wafv2_web_acl.main` (+ pre-existing
  `aws_lambda_function.dfs_balance_check` source_code_hash noise from the local zip build).
  With `-var waf_protect_rest_api_stages=true`: +2 `aws_wafv2_web_acl_association.rest_api_stage`.
- Rollback = revert the PR and apply: every change is in place (SG rules, web ACL rules, trust
  policy, RDS flag).
