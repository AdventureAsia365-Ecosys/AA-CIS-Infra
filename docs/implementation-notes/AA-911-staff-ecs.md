# AA-911 — staff frontends on ECS (lane l7-aa911-staff-ecs, S271)

Source: root ADR 0019 d23 ("All agency-facing and staff frontends leave Vercel, Dev first": CIS admin + Booking admin
together in ONE Fargate task, two containers, 0.5 vCPU / 1 GB, Spot, behind the shared ALB with the existing REGIONAL
web ACL, no CDN, ~5 USD a month), the S265 tech-lead cost yes, and the AA-911 re-scope comment (S265): once the staff
apps run on ECS with a WORKFORCE callback on their fixed host, retire the CIS -> Booking bridge. App side:
AA-CIS-App and AA-Booking `docs/implementation-notes/AA-911-staff-ecs.md`.

## Decisions

- **One service per app (S271 fix pass, amends ADR 0019 d23's "one task, two containers")**: `aa-cis-<env>-admin`
  (`cis-admin` :3000) and `aa-booking-<env>-admin` (`booking-admin` :3001), each its own family, execution role, log
  group, target group and service, 0.25 vCPU / 0.5 GB, FARGATE_SPOT only. Reason (reviewer, major): keep the per-app secret
  isolation of AA-873 (details on the Linear issue); each deploy role registers and passes only its own family and role. It also
  removes the two-repo race on one family and the "copy the latest revision" trap (a Terraform revision on
  `bootstrap` for both containers). Same cost (Fargate bills per vCPU and per GB). In
  `modules/environment/staff_web.tf` (AA-1004: the stack a prod root reuses); the edge (cert, host rules, DNS, SG) in
  the root, like the CRM edge.
- **ECS Exec off, no task role**: an exec session reads the task env (the app's secrets), and the apps call no AWS API.
  Debug from the logs.
- **Same host names as today** (`aa-cis.` and `booking.`), not new ECS host names. Nothing that links to the staff
  apps changes (Cognito callbacks, CRM / Booking / CIS cross-links, E2E base URLs, bookmarks). Before the cut-over the
  ECS hosts are verified by resolving the name to the ALB on the test client only (`curl --resolve`, Chromium
  `--host-resolver-rules`); the Cognito callback is the same name, so a full sign-in works there.
- **Cut-over = one variable** (`staff_web_dns_on_ecs`, default false) that changes the two existing CNAME records in
  place (Vercel target -> ALB DNS name). In place, not destroy + create, so Route 53 never sees a CNAME and an A record
  for the same name in one apply. Rollback = false again.
- **ALB :443 opened to browsers** (`modules/vpc` dynamic ingress, `0.0.0.0/0`) and **the HTTPS listener default turned
  into a fixed 404** (`modules/alb`). Before, the listener forwarded to the CIS API target group, unused only because
  the group admitted no :443. Now only the two host rules reach a target; the API stays behind API Gateway.
- **WAF:** the ALB's web ACL (modules/waf) already sees every request; for direct HTTPS it sees the real client IP, so
  rate + geo apply per viewer. The staff hosts are scoped out of `RateLimit1000` (API-sized, 1000 / 5 min) and counted
  by a new rule `StaffWebRateLimit` (priority 6, `var.staff_web_rate_limit` = 5000 / 5 min per IP): a Next.js page with
  its static chunks, RSC navigations and prefetches is many requests, and an office NAT IP is shared. Static chunks are
  NOT excluded from the count: "host is staff AND path is not /_next/static/" needs an and+not nesting deeper than the
  provider allows inside a rate rule's scope-down, so the limit is set with them counted. **Geo is kept for the staff
  hosts on purpose** (same allowed list as every viewer); a VPN exit outside it is blocked. The runbook makes "staff
  blocked by the WAF" a rollback trigger and reads both metrics after the switch. The admin BFF calls reach the APIs
  through API Gateway (same ACL on the stage), as from Vercel today: no new body-rule exposure.
- **Certificate = wildcard `*.<zone>` + apex** (S271 fix pass, reviewer blocking): `aa-cis.` and `booking.` CNAME to
  Vercel until the flip and the CAA lookup follows the CNAME to a set without Amazon (live `dig CAA` 06/11), so a
  certificate naming them would fail CAA_ERROR (crm_agency_edge.tf critic C1). No own validation record: ACM gives
  `*.<zone>` and `<zone>` one record per account, which `crm_agency_acm_validation` already holds; the provider's
  `validation_record_fqdns` check fails at once if the token ever differed.
- **TTL window** (`staff_web_dns_switch_window`, true in terraform.tfvars from the first apply): `aa-cis.` (parity
  1800 s) and `booking.` (300 s) at 60 s, so the flip and a rollback reach resolvers in a minute (CRM P2b precedent).
  Off again at the Vercel retirement.
- **Apex** (`staff_web_apex_on_alb`, default false): the apex A record becomes an ALB alias with a :443 host rule that
  redirects to `aa-cis.`. Must be on before the `aa-cis-frontend` Vercel project, which claims the apex, is retired.
- **Secrets by name only:** shells `aa-cis/<env>/admin-web` and `booking/<env>/admin-web` without a Terraform version,
  filled by `tools/identity/staff_web_secret.py` from DescribeUserPoolClient (crm_web.tf precedent). ADMIN_SECRET of the
  CIS BFF maps the existing `aa-cis/<env>/admin-secret` (the Production value on Vercel is a copy of it).
- **Deploy grants:** Booking's role gets an extra inline policy in the module (CI-appliable). The CIS deploy role is a
  bootstrap object (`tf_apply_protected_role_arns`), so its grant `cis_app_deploy_staff_web` is a local MFA apply. It
  reads the module's locals-only `staff_web_deploy_scope` output so it can be applied alone with `-target`.
- **ECR:** `aa-booking-<env>-admin` is created by CI (BookingEcrRepoManage). `aa-cis-<env>-admin` is created by the
  bootstrap apply: CI may only configure `aa-cis-<env>-*` repos, and `CisEcrRepoConfigure` now lists the admin repo too.
  No new statement: the apply role's inline policy is near its 10,240-character limit (cicd_sec.tf). Same bootstrap
  change: `BookingAlbListenerRuleManage` (listeners of the shared ALB only) also allows Add/RemoveListenerCertificates
  for the staff certificate; no managed policy of the apply role grants them.
- **Health:** `/api/healthz` on both apps (outside both apps' proxy matchers), same path in the container check and the
  target groups.

## Changed

- `modules/alb/main.tf`: HTTPS default `forward api` -> fixed 404 (in-place ModifyListener).
- `modules/vpc`: `alb_public_https_cidrs` (default empty) gates one :443 ingress on the ALB group.
- New: `modules/environment/staff_web.tf`, `accounts/aa365/staff_web_edge.tf`, `tools/identity/staff_web_secret.py`
  (+ tests), `tools/terraform/tests/test_aa911_staff_web.py`.
- `alb_rules.tf` (`alb_https_rule_priorities`, two host rules), `app_security_groups.tf` (`sg-staff-web`),
  `cicd.tf` (CisEcrRepoConfigure + admin repo), `cicd_split.tf` (`cis_app_deploy_staff_web`), `dns.tf` /
  `custom_domains.tf` (cut-over switch), `environment.tf` / `main.tf` wiring.

## Tradeoffs

- Two services instead of one task: the same Fargate cost (2 x 0.25 vCPU / 0.5 GB = 1 x 0.5 / 1; the first draft's
  "half the cost" was wrong), two ENIs, two alarms. 512 MB per Next.js server is the CRM web's size (crm_web.tf).
  Each app now crashes and deploys alone.
- Each deploy copies ITS family's latest revision and swaps only the image: env, secrets and size from Terraform
  flow in on the app's next deploy; a failed rollout of one app can no longer poison the other's.
- No HTTP -> HTTPS redirect: :80 stays VPC-only (it carries the API Gateway and CloudFront paths and must not be public).
  A bare `http://aa-cis.` no longer answers after the cut-over; every link and bookmark is https (HSTS is sent).
- Route 53 TTL of `aa-cis.` is 1800 s (parity record): the cut-over and a rollback take up to 30 minutes to reach every
  resolver; `booking.` is 300 s.

## Should know

### Apply order (orchestrator; the bootstrap step needs the tech lead's auto-mode window, MFA)

1. Merge this PR. Local MFA, from `accounts/aa365` on main, targeted:
   `terraform plan -target=aws_iam_role_policy.tf_apply -target=aws_iam_role_policy.cis_app_deploy_staff_web -target='module.environment.aws_ecr_repository.staff_web["cis"]'`
   (the CIS repo is now named `aa-cis-<env>-admin`, unchanged; the grant names family `aa-cis-<env>-admin`)
   then `apply` the same targets. Expect 2 policy updates/creates and 1 repository.
2. Terraform Apply workflow (CI): the rest. Read the plan: in-place updates of the HTTPS listener default, the ALB
   security group, the Booking deploy role (new policy), the web ACL (scope-down + `StaffWebRateLimit`), the TTL of
   `aa-cis.` and `booking.` (-> 60, switch window); creates for the cert (no validation record), the listener
   certificate, 3 listener rules, the SG, 2 secret shells, 1 ECR repo + 2 lifecycle policies, 2 log groups, 2 roles + 2
   policies, 2 task definitions, 2 target groups, 2 services, 2 alarms. No destroy. The two CNAME values and the apex
   do not change while `staff_web_dns_on_ecs` / `staff_web_apex_on_alb` are false.
3. `python3 tools/identity/staff_web_secret.py --apply` (MFA admin).
4. App deploys (each app's Deploy Admin Dev, independent of each other). Then scale `aa-cis-dev-admin` and
   `aa-booking-dev-admin` to 1 and re-run each deploy (it verifies through the ALB).
5. Verify through the ALB without DNS (root runbook `docs/ops/runbooks/staff-web-ecs-cutover.md`), then the cut-over PR
   (`staff_web_dns_on_ecs = true` in terraform.tfvars) + Terraform Apply.

### Cost (D-19, us-west-1)

Fargate Spot ARM64, two tasks of 0.25 vCPU / 0.5 GB at desired 1 ~ 2.45 USD/month each, ~ 4.9 USD/month for both (on
demand ~ 16.6); ECR < 0.10; two secrets 0.80; two alarms 0.20; logs < 0.50; one WAF rule 1.00. **~ 7.5 USD/month
running** (ADR 0019 d23 estimate: ~ 5 USD + ECR/logs). Certificate and
listener rules free; no new ALB, CDN or web ACL. Vercel Hobby costs nothing, so the delta is + ~6.5 USD/month.

### S271 fix pass (independent review)

- Accepted and fixed: wildcard certificate (CAA), one service per app (secret isolation + deploy race + latest-revision
  trap), staff host rate rule, 60 s TTL window and emergency rollback, apex re-point before the Vercel retirement, cost
  sentence.
- Residual, outside this slice: one older deploy-role grant, noted on the AA-911 Linear issue (S271 review).
