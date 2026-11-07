# AA-1038 — R5 hosting slice: TripPlanner frontend on ECS behind CloudFront + a CLOUDFRONT-scope web ACL

Root ADR 0019 d23 and the S265 tech-lead decision (one Fargate Spot task + CloudFront + a CLOUDFRONT-scope WAF, about
13-15 USD/month on Dev; the Fargate and WAF cost yeses are in the AA-1038 description). Companion PRs: root runbook
`docs/ops/runbooks/tripplanner-web-ecs-cutover.md` + secrets register (merged first), AA-TripPlanner-Web image and
`deploy-web-dev.yml` (merged after this apply).

## Decisions

- **Service like the staff admins, edge like the CRM hosts.** `modules/environment/tripplanner_web.tf` copies the
  `staff_web.tf` / `crm_web.tf` shape (IMMUTABLE ECR, secret shell without a version, desired 0 at create,
  `ignore_changes = [desired_count, task_definition]`, ECS Exec off, no task role, one execution role reading only its
  own secrets). The edge copies `crm_agency_edge.tf`: the same VPC origin on the internal NLB, the same origin-verify
  secret, an ALB :80 host rule below `crm_origin_deny`, the us-east-1 wildcard certificate. No new NLB, VPC origin or
  certificate.
- **Size 0.5 vCPU / 1 GB, not 0.25 / 0.5.** The TripPlanner server renders the catalog pages and keeps the ISR cache
  in process; the staff admins' size leaves no headroom. ~ +2.5 USD/month on Spot.
- **Web ACL, three rules (3 USD), first terminating action wins:** `RateLimitPerIp` (3000 / 5 min / viewer IP, 429
  JSON), `RateLimitModelPaths` (100 / 5 min on `/api/browse/search` + `/api/trip/narrate`, 429), `ChallengePlanner`
  (Challenge on a GET with `sec-fetch-dest: document` of a planner page, `/plan`, `/{tenant}/plan` and below, OR a
  model path). The model paths are called only from the planner (AA-TripPlanner-Web `lib/api.ts`), so home,
  destination and tour pages never see an interstitial. A browser solves the silent Challenge when it opens the planner
  and its `fetch()` to a model path carries the `aws-waf-token`; a script without the token gets 202 +
  `x-amzn-waf-action: challenge`. Token immunity 4 h (variable). curl health checks send no `sec-fetch-dest`, so they
  are never challenged.
- **The app must not leave a side door.** A WAF rule sees the path only; the BFF's older spellings of the same calls
  would bypass the Challenge, so the task env `TP_EDGE_GATE=on` makes the BFF refuse them (AA-TripPlanner-Web
  `lib/edgeGate.ts`, 404 `use_protected_path`). `TP_CLIENT_IP_SOURCE=cloudfront`: the app keys its per-IP AI limits on
  `CloudFront-Viewer-Address` (forwarded by `Managed-AllViewerAndCloudFrontHeaders-2022-06`).
- **Caching:** default behaviour `Managed-CachingDisabled` (pages carry the guest cookie on /plan and the BFF answers
  are per traveller; the task's ISR cache serves the pages and the CIS purge notice drops it). Only `/_next/static/*`
  and `/photo-cdn/*` use `Managed-CachingOptimized` (origin Cache-Control: one year, immutable / versioned URLs). No
  custom cache policy, so the apply role needs no new CloudFront grant (PhotosCdnCloudFront covers distributions).
- **DNS:** the `tripplanner.` record moved from `custom_domains.tf` (`vercel_frontend["tripplanner"]`) to
  `aws_route53_record.tripplanner_web[0]` with a moved block (same record, in-place updates only). A CNAME on both sides
  of the switch; `tripplanner_web_dns_on_cloudfront` default false (Vercel target kept as
  `tripplanner_web_vercel_target`); `tripplanner_web_dns_switch_window` default true (TTL 300 -> 60 at the first apply,
  so the window is open long before the switch PR). A precondition refuses the switch without the edge.
- **CIS catalog purge follows the switch:** the CIS api and worker get `TRIPPLANNER_REVALIDATE_URL` =
  `https://tripplanner.<zone>/api/revalidate/catalog` only when the switch is on (`modules/ecs`
  `tripplanner_revalidate_url`, null = the app default, the Vercel host, which is the live host until then). Never "",
  which switches delivery off. It reaches the CIS tasks on the next CIS deploy after the switch apply.
- **Secrets:** `tripplanner/<env>/web` {session_secret, catalog_revalidate_secret, sentry_dsn} filled by
  `tools/identity/tripplanner_web_secret.py` (a new session key: the Vercel copy is a "sensitive" env that cannot be
  read back; the purge key copied from the CIS secret; the web Sentry DSN given on the command line). The edge key
  `tripplanner/<env>/api-key` and the two traveller identity keys (`identity.tf`, each only while it exists) are mapped
  by ARN.
- **ECR create grant:** the apply role may create `aa-booking-*` and `aa-crm-*` repositories only. One more resource ARN
  (`aa-tripplanner-<env>-web`, exact) in `cicd_crm.tf` `CrmEcrRepoManage` (a customer managed policy, its own 6,144
  limit), not in `cicd.tf` (the inline policy is near its 10,240 limit). Bootstrap object: local MFA apply.

## Changed

- New: `modules/environment/tripplanner_web.tf`, `accounts/aa365/tripplanner_web_edge.tf`,
  `tools/identity/tripplanner_web_secret.py` (+ tests), `tools/terraform/tests/test_aa1038_tripplanner_web.py`.
- `accounts/aa365`: `alb_rules.tf` (priority 13), `app_security_groups.tf` (`sg-tp-web`), `environment.tf` (four module
  inputs), `custom_domains.tf` / `custom_domains_variables.tf` (tripplanner. left the Vercel map; listed with the
  frontends), `cicd_crm.tf` (ECR grant), `main.tf` (`tripplanner_revalidate_url` of module ecs).
- `modules/ecs`: `tripplanner_revalidate_url` variable + env on api and worker (empty list while null: no plan change).
- Tests adjusted: `test_aa911_staff_web.py` (the Vercel label parser reads the new variable and ignores
  `description`), `test_aa1004_environment_moves.py` (the AA-1038 module inputs and root-only edge settings).
- `CONTEXT.md`, `tools/identity/README.md`.

## Tradeoffs

- One Spot task: an interruption or a deploy is a short 503 on Dev (circuit breaker + min healthy 100 % keep deploys
  zero-downtime when capacity allows). Prod sizing is a later decision (S265: prod sized later).
- No WAF log group (cost): metrics per rule and sampled requests in the console. Add one (30 days) if the cut-over
  watch needs per-request detail.
- The regional web ACL on the ALB still runs its CommonRuleSet on these requests before `CloudFrontOriginAllow` lets
  them past rate and geo; a false positive there shows as a 403 from the ALB (WAF log `aws-waf-logs-aa-cis-dev`).
- Pages are not cached at CloudFront (the Vercel CDN cached them by `s-maxage`): one small origin hop per page view.

## Should know

### Apply order (orchestrator; step 2 needs the tech lead's MFA window)

1. Root runbook PR merged (secrets register rows). Merge this PR.
2. Local MFA, from `accounts/aa365` on main: `terraform plan -target=aws_iam_policy.tf_apply_crm` then `apply` the same
   target. Expect: 1 in-place update (a new policy version with the extra repository ARN), nothing else.
3. Terraform Apply workflow (CI). Read the plan: creates for the web ACL (us-east-1), the distribution (5-15 min), the
   ALB rule, `sg-tp-web`, ECR repo + lifecycle policy, secret shell, log group, execution role + policy, task
   definition, target group, service, alarm, the deploy role's `app-deploy-web` policy and the CachingOptimized data
   source; `aws_route53_record.vercel_frontend["tripplanner"]` has moved to `aws_route53_record.tripplanner_web[0]`
   with ONE in-place change, ttl 300 -> 60 (the target stays the Vercel name). No destroy; the CIS task definitions
   unchanged (the revalidate URL is null until the switch).
4. `python3 tools/identity/tripplanner_web_secret.py --apply --sentry-dsn "<TripPlanner web DSN>"` (MFA admin).
5. AA-TripPlanner-Web settings, then its PR (runbook section 1).

### Cost (D-19)

Task 0.5 vCPU / 1 GB Fargate Spot ARM64 ~ 5.0 USD; web ACL 5 + 3 rules 3 + requests (0.60 USD per million) ~ 8.1 USD;
Challenge attempts at Dev volume: cents (to read on the first bill); secret 0.40; alarm 0.10; logs < 0.50; ECR < 0.10;
CloudFront inside the always-free tier. **~ 14.5 USD/month running** (S265 estimate 13-15), ~ 9.5 USD/month at desired
0 (the web ACL bills by the month). The issue's cost Done-when reads Cost Explorer for the first days after the move.
