# AA-911 — staff frontends on ECS (lane l7-aa911-staff-ecs, S271)

Source: root ADR 0019 d23 ("All agency-facing and staff frontends leave Vercel, Dev first": CIS admin + Booking admin
together in ONE Fargate task, two containers, 0.5 vCPU / 1 GB, Spot, behind the shared ALB with the existing REGIONAL
web ACL, no CDN, ~5 USD a month), the S265 tech-lead cost yes, and the AA-911 re-scope comment (S265): once the staff
apps run on ECS with a WORKFORCE callback on their fixed host, retire the CIS -> Booking bridge. App side:
AA-CIS-App and AA-Booking `docs/implementation-notes/AA-911-staff-ecs.md`.

## Decisions

- **One service, one task definition, two containers** (`aa-staff-<env>-web`: `cis-admin` :3000, `booking-admin`
  :3001), two target groups, one `aws_ecs_service` with two `load_balancer` blocks, FARGATE_SPOT only. In
  `modules/environment/staff_web.tf` (AA-1004: the stack a prod root reuses); the edge (cert, host rules, DNS, SG) in the
  root, like the CRM edge.
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
  rate + geo apply per viewer. The admin BFF calls reach the APIs through API Gateway (same ACL on the stage), as from
  Vercel today: no new body-rule exposure.
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

- One task for two apps: half the cost of two services, but one app's crash restarts both (both containers are
  essential) and a deploy of either app rolls both. Accepted for Dev (ADR 0019 d23); production sizing is decided later.
- Two repos write revisions of one family. Each deploy copies the LATEST revision just before registering, so two
  deploys at the same second could drop the other's image; the deploy workflows re-check that their image is the one
  running after the rollout and fail red otherwise (re-run fixes it).
- No HTTP -> HTTPS redirect: :80 stays VPC-only (it carries the API Gateway and CloudFront paths and must not be public).
  A bare `http://aa-cis.` no longer answers after the cut-over; every link and bookmark is https (HSTS is sent).
- Route 53 TTL of `aa-cis.` is 1800 s (parity record): the cut-over and a rollback take up to 30 minutes to reach every
  resolver; `booking.` is 300 s.

## Should know

### Apply order (orchestrator; the bootstrap step needs the tech lead's auto-mode window, MFA)

1. Merge this PR. Local MFA, from `accounts/aa365` on main, targeted:
   `terraform plan -target=aws_iam_role_policy.tf_apply -target=aws_iam_role_policy.cis_app_deploy_staff_web -target='module.environment.aws_ecr_repository.staff_web["cis"]'`
   then `apply` the same targets. Expect 2 policy updates/creates and 1 repository.
2. Terraform Apply workflow (CI): the rest. Read the plan: in-place updates of the HTTPS listener default, the ALB
   security group, the Booking deploy role (new policy); creates for the cert + 2 validation records, the listener
   certificate, 2 listener rules, the SG, 2 secret shells, 1 ECR repo + 2 lifecycle policies, log group, 2 roles + 2
   policies, task definition, 2 target groups, the service, 2 alarms. No destroy. `dns.tf` / `custom_domains.tf`: no
   change while `staff_web_dns_on_ecs = false`.
3. `python3 tools/identity/staff_web_secret.py --apply` (MFA admin).
4. App deploys (each app's Deploy Admin Dev); the first one stops after registering (the other container is still on
   `bootstrap`), the second rolls the task. Then scale `aa-staff-dev-web` to 1.
5. Verify through the ALB without DNS (root runbook `docs/ops/runbooks/staff-web-ecs-cutover.md`), then the cut-over PR
   (`staff_web_dns_on_ecs = true` in terraform.tfvars) + Terraform Apply.

### Cost (D-19, us-west-1)

Fargate Spot ARM64 0.5 vCPU / 1 GB at desired 1 ~ 4.9 USD/month (on demand ~ 16.6); ECR < 0.10; two secrets 0.80; two
alarms 0.20; logs < 0.50. **~ 6.5 USD/month running** (ADR 0019 d23 estimate: ~ 5 USD + ECR/logs). Certificate and
listener rules free; no new ALB, CDN or web ACL. Vercel Hobby costs nothing, so the delta is + ~6.5 USD/month.
