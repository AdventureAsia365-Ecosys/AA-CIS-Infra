---
id: ARCH-06-infra
title: "AA-CIS-Infra — Repo Context"
description: What AA-CIS-Infra owns (Terraform for every AWS resource of the ecosystem, DB Migrate, schema dump), its boundaries with the app repos and its working rules; read it before changing infrastructure.
type: explanation
status: active
owner: nghiep
audience: [engineer, devops, agent]
applies_to: [aa-cis-infra, ecosystem]
last_reviewed: 2026-10-23
review_every_days: 90
related: [ARCH-01, ARCH-05, ARCH-08, docs/adr/README.md]
---

# AA-CIS-Infra — Repo Context

Terraform infrastructure-as-code for the whole Adventure Asia (AA) ecosystem. This repo owns the
AWS resources that the application repos run on. The governing rule across the ecosystem is
**"App owns code, Infra owns resources"**: AA-CIS-App and AA-TripPlanner-Web ship application
code and their own DB migrations; everything cloud-side — VPC, RDS, ECS, ALB, API Gateway, S3,
Secrets, Lambda plumbing, OIDC deploy roles, cross-account Bedrock trust — is defined here.

> Scope of this file: describe the whole repo accurately — its layout, the multi-account model,
> the state backend, and how a change gets applied. It is not a per-module reference; each module
> documents itself in its own `variables.tf`/`outputs.tf`.

## What it is (role in the AA ecosystem)

- **The single source of truth for AWS resources.** No application repo provisions its own
  infrastructure; they consume roles/endpoints/resources defined here.
- **Multi-account.** It manages three AWS accounts, each with its own root config and (where it
  has state) its own state file, so a change in one account cannot corrupt another.
- **Boundary with the app repos**: this repo does NOT contain application logic, does NOT run the
  content pipeline, and does NOT own application DB schemas (`acp_*`, `tripplanner.*`, `booking.*`, `crm.*`,
  `*_aa_internal`) — those live in the app repos' migrations. It owns the RDS instance the
  schemas live *in*, not the schemas themselves.

## Account model

| Account | ID | Role in ecosystem | Managed here |
|---------|----|-------------------|--------------|
| acc1 | 867490540162 | **Retired (AA-998)**: former Bedrock fallback; no grant from acc2, root destroyed and removed 28/10/2026 | (root removed) |
| acc2 (aa365) | 005097885195 | **Main dev stack** (VPC/RDS/ECS/ALB/API GW/…) + CI/CD OIDC | `accounts/aa365/` |
| acc3 | 786888028788 | `AA3-Bedrock-Invoker`, the **only** LLM satellite | `accounts/acc3-bedrock/` |

Bedrock routing across the ecosystem is **acc3 only** (acc2 native models stay on acc2). AA-998
(S255) retired acc1 and accepted the loss of the cross-account LLM fallback: an acc3 failure moves to
the next model on the same account, or the job retries. The cross-account assume-role wiring that
lets the main stack (acc2) and TripPlanner reach Bedrock in acc3 lives in
`accounts/aa365/bedrock_satellite_assume.tf` (caller side) and the `acc3-bedrock` root (trust side).
`accounts/acc1-bedrock/` was destroyed on 28/10/2026 (7 resources, state bucket deleted) and removed from the repo (AA-998).
The satellite invoker roles trust only the ECS task role (`aa-cis-dev-ecs-task-role`), not an
admin session — Claude cannot be called from a local shell.

Cross-account pieces added 15-25/09/2026 (same assume-role pattern as the Bedrock satellite):

- **Cost Explorer read (AA-623)**: acc2 is a **member account**, not the AWS Organizations payer
  (payer `033086823579` is unrelated to acc2/acc3), so there is no consolidated CE call. Each
  account exposes its own read role, assumed by the acc2 ECS task role (the acc1
  `AA-CostExplorer-Reader` grant was removed by AA-998):
  - acc3 `AA3-CostExplorer-Reader` (ExternalId `aa623-satellite-cost-explorer-acc3`),
    `accounts/acc3-bedrock/cost_explorer_reader.tf`;
  - acc2 calls CE directly (`ce:GetCostAndUsage` on the ECS task role) and gets
    `sts:AssumeRole` on the acc3 role above via `accounts/aa365/cost_explorer_satellite_assume.tf`.
- **Bedrock Batch Inference (AA-606)**: bronze bucket prefixes `batch-input/s1-rewrite/*` and
  `batch-output/s1-rewrite/*` (`modules/s3`), plus the batch service role
  `aa3-bedrock-batch-inference-role` (acc3, `accounts/acc3-bedrock/batch.tf`); the acc1 role's
  bucket-policy statements were removed by AA-998. IAM is complete, but **AWS has not enabled Batch
  Inference on acc3 yet** (support case 178979743800653, Linear AA-624): job creation fails with
  a `ValidationException` about account authorization, which is an entitlement, not IAM.
- **Spend guards per account (AA-896)**: acc2 has the account budget (`var.total_monthly_budget_usd`, 300 USD
  since S255, ACTUAL 80 %/100 % + FORECASTED 100 %) and per-App budgets (cis, tripplanner, booking,
  crm since AA-932, identity since S255, shared; their sum must fit the account budget, a precondition checks it)
  (`accounts/aa365/observability.tf`) and an IMMEDIATE anomaly subscription to the alerts topic
  (`accounts/aa365/cost_anomaly.tf`). An `App`-tag anomaly monitor is not possible on acc2: AWS allows
  cost-allocation-tag monitors only in the management (payer) account. acc3, where almost all LLM spend
  lands, has its own monthly budget (credits excluded), a DAILY anomaly e-mail on the AWS-created services
  monitor (`accounts/acc3-bedrock/cost_guard.tf`) and, since S255, an IMMEDIATE subscription (impact >= 15 USD)
  to its own SNS topic `aa3-cost-alerts` with an e-mail subscriber (`accounts/acc3-bedrock/cost_anomaly_immediate.tf`). acc1 (retired, AA-998) keeps only hand-made console budgets of its owner; it is outside the ecosystem.

## Layout

```
accounts/
  aa365/          ← main stack root (acc2 005097885195, us-west-1) — the big one
    main.tf                       (wires all modules for the dev stack)
    versions.tf                   (providers + S3 state backend)
    cicd.tf                       (GitHub Actions OIDC provider + the apply role's grant lists;
                                   legacy shared CI role aa-cis-dev-role retired in AA-806 step 3)
    cicd_split.tf                 (AA-806: aa-cis-dev-app-deploy, aa-cis-infra-tf-plan/-apply,
                                   permissions boundaries; bootstrap, applied by a human)
    cicd_db_auto_apply.tf         (AA-993 I1, root ADR 0017 d6: aa-cis-infra-db-auto-apply, trusted only for
                                   environment:dev-db-auto + ref main; RunTask/Register/Deregister of the migrator
                                   family, PassRole on the two migrator roles, S3 prefix db-auto-apply/, log read.
                                   Bootstrap (outside aa-*-dev-*), applied by a human. GitHub side (environment,
                                   ruleset on main): tools/github/db_auto_apply_gate.sh; proof:
                                   db-auto-apply-role-check.yml)
    tripplanner.tf                (TripPlanner OIDC deploy role + TripPlanner-specific resources.
                                   AA-878: no secret value in the Lambda env; the edge key is read by
                                   name tripplanner/<ENVIRONMENT>/api-key (grant ReadApiKeySecret);
                                   the Mapbox secret is forgotten via a removed block, not deleted.
                                   AA-712 X4: no PLACES_SOURCE any more (TripPlanner reads only the catalog views).
                                   AA-871: secret shell tripplanner/<env>/sentry-dsn (no version), read by
                                   name at cold start, grant ReadSentryDsnSecret; no DSN in the Lambda env)
    booking.tf                    (AA-Booking ECS service, ECR, ALB rule /booking/*, REST API on the
                                   existing VPC link, OIDC deploy role — AA-678; AA-871: secret shell
                                   booking/<env>/sentry-dsn (no version, execution-role read) mapped to
                                   SENTRY_DSN + SENTRY_REQUIRED only when var.booking_sentry_enabled)
    booking_media.tf              (AA-835: bucket aa-booking-<env>-supply-media-<account> for supplier photos,
                                   SSE-S3, versioned (noncurrent 30 d), TLS only, CIS task role denied writes;
                                   Booking task role Put/Get on supply-media/*; env SUPPLY_MEDIA_BUCKET)
    booking_ops_docs.tf           (AA-682: bucket aa-booking-<env>-ops-docs-<account> for operations documents
                                   (vouchers, payment evidence, bills; PII), SSE-S3 (no CMK), versioned
                                   (noncurrent 30 d), TLS only, object verbs denied to every principal but the
                                   Booking task role; Booking task role Put/Get on ops-docs/*; env OPS_DOCS_BUCKET)
    bedrock_satellite_assume.tf   (cross-account Bedrock assume-role trust)
    cost_explorer_satellite_assume.tf (acc2 → acc3 Cost Explorer read role, AA-623; acc1 removed, AA-998)
    dfs_balance.tf                (ops-probe Lambda: 06:15 UTC schedule POSTs the admin probes, AA-627/720/727,
                                   plus the daily staff directory reconcile enqueue, AA-816;
                                   20:30 UTC schedule POSTs /admin/job-runner/retention/schedule, AA-825;
                                   21:00 UTC schedule POSTs /admin/photos/sync/schedule (one photo_sync
                                   job per country per UTC day), AA-844;
                                   AA-871: every-5-min booking_uptime schedule, event {"health":"booking"}
                                   = GET var.booking_health_url (no secret), raises when unhealthy ->
                                   alarm aa-booking-dev-uptime on the function's Errors;
                                   the AA-832 every-5-min schedule was removed in AA-751. AA-878: the
                                   admin secret is read only by ARN at run time (event secret_id), no
                                   env copy, no Terraform data source; no secret_id or a failed read =
                                   fail closed, no API call. lambda_src/dfs_balance_check + _tests,
                                   .github/workflows/ops-probe-test.yml)
    rds_snapshot_expiry.tf        (AA-869, DM-7.5: daily 22:00 UTC Lambda that expires manual
                                   aa-cis-dev-db snapshots after 30 d unless keep-* / aa:retain=keep /
                                   aa:retain-until; keeps and reports snapshots of a deleted or
                                   re-created instance (final snapshot); DRY_RUN default "true", max 3
                                   deletions per run; lambda_src/rds_snapshot_expiry + _tests,
                                   .github/workflows/rds-snapshot-expiry-test.yml)
    identity.tf, identity_variables.tf (AA-703, root ADR 0006: Cognito pools aa-workforce-dev /
                                   aa-external-dev, app clients (WORKFORCE also has the Preview-only
                                   cis-admin-preview / booking-staff-preview, capped at viewer by the
                                   APIs, AA-911 D-1), groups, trigger Lambdas in
                                   lambda_src/identity_triggers + tests; SES (ses.tf identity) on,
                                   EXTERNAL native sign-up, WAF and custom domains gated by
                                   variables, default off — AA-854; Dev tfvars turn the WAF and
                                   traveller native sign-up on (AA-908; the TripPlanner BFF's passwordless
                                   SignUp, accepted by the pre sign-up trigger only with the BFF's HMAC
                                   proof, key tripplanner/dev/cognito-signup-proof-key): one web ACL on the WORKFORCE, EXTERNAL and PARTNER pools,
                                   per-IP limits on the sign-up/sign-in API calls and on managed-login form
                                   posts (not /oauth2/*), the TripPlanner BFF's API calls (header value =
                                   secret tripplanner/dev/cognito-bff-key) counted per traveller address
                                   (X-AA-Traveller-IP) instead, alarm
                                   aa-identity-dev-waf-blocked; managed login branding: one style
                                   per WORKFORCE and per EXTERNAL client, for_each over each client
                                   resource — a managed-login-v2 client without a style answers 403
                                   on /login; tools/terraform/managed_login_branding.py in
                                   managed-login-branding.yml fails CI on a gap, AA-935 S249)
    identity_m2m.tf               (AA-972, root ADR 0006b d7: M2M pool aa-m2m-dev, resource servers
                                   booking.b2b (read/quote/hold/book), AA-976 cis.catalog (read) and
                                   AA-978 cis.tenant (read), client-credentials client aa-m2m-dev-crm
                                   (AA-Partner -> Booking B2B, -> CIS catalog.http.v1 and -> CIS
                                   tenant.membership.v1; each receiver checks only its own scope),
                                   prefix domain for the token endpoint, secret container
                                   aa-crm/dev/m2m-booking-client (value written after apply, never by
                                   Terraform; crm_app.tf injects it as M2M_CLIENT, AA-978); booking.tf passes
                                   COGNITO_M2M_ISSUER / COGNITO_M2M_CRM_CLIENT_ID. CIS needs no env var: it
                                   keeps the Dev issuer and CRM client id as code constants with an env
                                   override, api/core/m2m_auth.py)
    identity_partner.tf           (AA-939, root ADR 0006b d1/d5/d6: PARTNER pool aa-partner-dev — agency
                                   people, admin-create only, MFA required (TOTP; passkeys when the provider
                                   supports the factor configuration), client partner-web + managed login style,
                                   prefix domain + custom domain partner-auth. on its own us-east-1 cert; the CRM
                                   task role's pool allow-list (AdminCreateUser, ListUsers, AdminDisableUser,
                                   AdminUserGlobalSignOut) + ses_send; alerts: pool config change outside
                                   Terraform, admin calls outside the invitation model. crm_web.tf
                                   crm_partner_signin_enabled switches the CRM web from cis-portal to partner-web
                                   (keep it true: since AA-979 P2b the CRM API no longer gets the EXTERNAL issuer /
                                   cis-portal client id, so /crm/v1 refuses cis-portal tokens).
                                   identity.tf adds the crm-platform-admin / crm-ops / crm-support groups and the
                                   crm-staff WORKFORCE client)
    identity_iam.tf               (AA-816: CIS task role (api + worker) allow-list on the WORKFORCE pool
                                   only — create/group/disable/enable/global sign-out + ListUsers*;
                                   no AdminGetUser / AdminSetUserPassword / attribute writes, ADR 0006)
    identity_alerts.tf             (AA-854 I1: break-glass secret resource policy — Get/PutSecretValue
                                   only for the MFA admin role; EventBridge rule on CloudTrail
                                   management events incl. read-only -> SNS alerts topic; the
                                   alerts topic policy = AWS default statement + events.amazonaws.com;
                                   AA-816 S243: root ADR 0006a A8 rule on CloudTrail AdminCreateUser on
                                   the WORKFORCE pool with a temporary password / RESEND / no SUPPRESS)
    security_baseline.tf          (AA-873 PR 1, S255: account S3 Block Public Access (4 flags); IAM Access Analyzer
                                   aa-sec-<env>-external-access (ACCOUNT, external access only; no paid unused-access
                                   analyzer) + rule on ACTIVE findings; EventBridge rules aa-sec-<env>-* on CloudTrail
                                   events -> SNS alerts: trail tamper (any principal), security-group change and IAM
                                   change (not by the CI apply role), root activity (all management events); a us-east-1
                                   rule forwards IAM write calls and root events (global services) to the us-west-1
                                   default bus through role aa-sec-<env>-events-forwarder. Topic policy statement
                                   AllowSecurityEventBridgeRules (identity_alerts.tf). 0 USD/month)
    security_cloudtrail.tf        (AA-873 PR 2, S255: KMS key alias/aa-cis-<env>-cloudtrail (rotation, App=shared,
                                   CloudTrail GenerateDataKey for this trail only, no account-wide decrypt), trail
                                   bucket versioning + Object Lock GOVERNANCE 365 days on the existing bucket (no
                                   replacement: provider probe). observability.tf: aws_cloudtrail.main multi-region +
                                   kms_key_id; bucket lifecycle = noncurrent 400 d + multipart cleanup (the old Deep
                                   Archive rule never ran: files < 128 KB). ~1.25 USD/month)
    security_guardduty.tf         (AA-873 PR 3, S255: GuardDuty detector behind var.guardduty_enabled (default false;
                                   ~15-20 USD/month when on): features RDS_LOGIN_EVENTS + S3_DATA_EVENTS on, EBS malware /
                                   EKS audit / Lambda network / Runtime Monitoring explicitly off; rule
                                   aa-sec-<env>-guardduty-finding (severity >= 4) -> SNS alerts)
    cicd_sec.tf                   (AA-873, bootstrap: customer managed policy aa-cis-infra-tf-apply-sec on the apply
                                   role — Access Analyzer, events rules aa-sec-* (both regions), the Access Analyzer /
                                   GuardDuty service-linked roles, GuardDuty detector + features, KMS create/admin only
                                   for keys tagged App=shared (no PutKeyPolicy / deletion / crypto), aliases
                                   alias/aa-cis-<env>-*; plus sqs:* moved unchanged from AmazonSQSFullAccess, whose
                                   managed slot it takes (the role stays at 10). Applied locally with MFA)
    observability.tf, observability_ecosys.tf (S235 alarms + log retention; RDS alarms per data standard
                                   C4.1 + per-role AA/RDS RoleConnectionLimitPct alarms, AA-832; job
                                   backlog alarms per owner AA/Jobs/CIS + AA/Jobs/Booking and the
                                   task-role PutMetricData grants, AA-751; every alarm e-mails on
                                   ALARM only, no ok_actions), diagnostics.tf
    dns.tf                        (Route 53 public zone lumiguides.it.com + records copied from Namecheap, AA-811)
    db_dns.tf                     (AA-829: private zone <env>.internal on the VPC, CNAME db.<env>.internal -> RDS,
                                   TTL 60; every DSN secret names it; var.db_dns_target_override repoints it)
    ses.tf                        (SES domain identity, DKIM/MAIL FROM/DMARC records, configuration sets,
                                   ses:SendEmail grants for the app roles, reputation alarms — AA-811)
    e2e_mailbox.tf                (AA-816 I5: SES inbound for the Cognito E2E: MX e2e-mail.lumiguides.it.com,
                                   the region's single ACTIVE receipt rule set aa-cis-dev-e2e (rule e2e-cognito,
                                   fixed recipients: the CIS staff E2E e2e@, the Booking staff E2E e2e-booking@
                                   (AA-910), the CRM e2e users and AA-908's two e2e travellers) -> S3 aa-cis-dev-e2e-mail-<acct>/inbound/ (1-day expiry), and
                                   the read-only GitHub OIDC role aa-cis-dev-e2e-mail-reader (AA-CIS-App, env e2e,
                                   main). A10b (AA-816, S252, dev only): rule e2e-cognito-admin (recipient
                                   e2e-cis-admin@, after aa-crm-dev-ingest) -> inbound-admin/, object reads there denied
                                   to every principal except the MFA admin role (the reader role included). Any future
                                   SES receiving in us-west-1 adds rules to this set)
    docs_reader.tf                (AA-898: GitHub OIDC role aa-cis-<env>-docs-sync, trusted only by the root repo
                                   AA-Ecosys on refs/heads/master (immutable subject), ListBucket on docs-reader/ +
                                   Put/Delete on docs-reader/* of the bronze bucket: the root "Docs sync" workflow uploads
                                   the /admin/docs bundle (manifest.json + pages/<repo>/<path>.md); the CIS task role reads
                                   it (modules/ecs ReadDocsReader, DenyDocsReaderWrites); noncurrent versions expire after
                                   7 days (modules/s3). < $0.10/month)
    custom_domains.tf             (AA-818: ACM certs api-booking./api-tripplanner. (us-west-1) and auth./staff-auth.
                                   (us-east-1, provider alias aws.us_east_1) + validation records; API GW custom
                                   domains, alias records and Vercel CNAMEs gated by var.custom_domains_enabled;
                                   Vercel hosts in var.custom_domain_vercel_hosts: tripplanner. (aa-tripplanner),
                                   booking. (aa-booking-admin), portal. (aa-cis-portal, CIS tenant portal, AA-885),
                                   booking-preview. (aa-booking-admin) and aa-cis-preview. (aa-cis-frontend): the
                                   fixed staff Preview sign-in hosts, the only callbacks of the two
                                   *-preview app clients (AA-911);
                                   aa-cis. is a static record in dns.tf)
    photos_cdn.tf                 (AA-844, edge: CloudFront img.lumiguides.it.com in front of the bronze
                                   bucket's photos/ prefix — ACM cert us-east-1 + validation record always;
                                   validation wait, distribution (origin_path /photos, OAC SigV4, cache key
                                   path + ?v=, TTL 1 d..1 y, nosniff+HSTS headers policy, no Cache-Control
                                   override, PriceClass_100, no logs/WAF) and A/AAAA aliases gated by
                                   var.photos_cdn_enabled && var.custom_domains_enabled. modules/s3 adds one
                                   bronze bucket-policy statement AllowPhotosCdnRead (GetObject photos/* for
                                   that distribution only, no ListBucket). The CIS /content/photos/{id}
                                   302 points here; output photos_cdn)
    alb_rules.tf                  (AA-931, v2.2 V3: the one priority map for the shared ALB :80 listener rules +
                                   the X-AA-Origin header name; order = CloudFront host rules < "any
                                   X-AA-Origin -> 403" < API Gateway path rules < default; checked by
                                   tools/terraform/alb_rule_order.py in alb-rule-order.yml)
    cicd_crm.tf                   (AA-931, bootstrap: customer managed policy aa-cis-infra-tf-apply-crm on the
                                   apply role — CloudFront VPC origins / origin request policies / functions,
                                   SetSecurityGroups on the shared ALB+NLB, ECR aa-crm-<env>-*, KMS create/admin
                                   only for keys tagged App=crm (no PutKeyPolicy, ScheduleKeyDeletion,
                                   DisableKey, CreateGrant or crypto use), EventBridge rules aa-crm-*, SES
                                   contact lists; plus the CRM naming contract)
    crm_edge.tf                   (AA-931 CRM-03 AA-Partner edge, gated by var.crm_edge_enabled &&
                                   custom_domains_enabled: CloudFront partner-dev.lumiguides.it.com -> VPC origin
                                   on the existing internal NLB -> ALB :80; rule crm_partner_default (Host +
                                   secret X-AA-Origin, any path crm_api does not take) -> the CRM web target group
                                   (AA-935; was a fixed 404 JSON); rule "any X-AA-Origin -> 403"; ACM us-east-1 + alias records.
                                   The AA-931 hello spike service aa-crm-dev-spike was removed in AA-933 (S248
                                   d16); live check tools/terraform/crm_edge_live_check.py)
    crm_agency_edge.tf            (AA-979 CRM-P2b, the AGENCY host portal.lumiguides.it.com, CRM + Content studio:
                                   its own CloudFront distribution on the same VPC origin and X-AA-Origin secret, a
                                   WILDCARD ACM us-east-1 certificate (the Vercel CNAME's CAA forbids a portal.-only
                                   one before the flip), ALB rules crm_agency_api (/crm, /crm/*) -> CRM API,
                                   crm_agency_studio (/portal*, /api/*, /tenant-login*) and crm_agency_studio_x
                                   (/terms, /privacy, /assets/*) -> Content studio, crm_agency_default -> CRM web; the
                                   portal. CNAME (moved from custom_domains.tf vercel_frontend["portal"], TTL 60 in
                                   the window) whose target is the ONE cutover switch var.crm_agency_live: false =
                                   Vercel aa-cis-portal (rollback target), true = this distribution; no ECS deploy)
    crm_portal.tf                 (AA-979 CRM-P2b, the Content studio runtime: ECR aa-crm-<env>-portal (IMMUTABLE),
                                   secret shell crm/<env>/portal-sentry-dsn (mapped with crm_portal_sentry_enabled),
                                   execution role (portal repo, CRM log group stream prefix portal, reads crm/<env>/web
                                   for the shared session key only + the Sentry DSN), task role (ECS Exec only), task
                                   definition Fargate ARM64 port 3000 (API_URL = CIS API, PORTAL_HOSTS,
                                   PORTAL_PUBLIC_ORIGIN, PORTAL_API_KEY_SIGNIN), target group aa-crm-<env>-portal-tg
                                   (/healthz), service aa-crm-<env>-portal (desired 0, FARGATE_SPOT), three alarms;
                                   security group sg-crm-portal (ALB -> 3000, egress 443 only); deployed by the CRM
                                   deploy role (crm_app.tf))
    crm_client_edge.tf            (AA-936 CRM-08, the AA-Partner CLIENT host go-dev.lumiguides.it.com: its own
                                   CloudFront distribution + ACM us-east-1 + alias records on the same VPC origin
                                   and X-AA-Origin secret; ALB rules crm_client_public (Host + secret +
                                   /crm/public/*) -> the CRM API (public inquiry form) and crm_client_default
                                   (Host + secret) -> the CRM web; feeds WEB_CLIENT_HOSTS and INTAKE_PAGE_ORIGINS)
    crm_data.tf                   (AA-932 CRM-04, data side of AA-Partner: secret shell crm/<env>/database-url (crm_app
                                   DSN, Console + DB Migrate set-password); KMS keys alias/crm-<env>/{data,ingest,seal}
                                   (data, ingest symmetric with rotation; seal RSA_3072 SIGN_VERIFY), App=crm. Key policy:
                                   account root for administrative verbs only (IAM decides: CI apply via cicd_crm.tf,
                                   PutKeyPolicy only by the MFA admin), crypto only by aa-crm-<env>-ecs-task-role
                                   (data: context {tenant_id, purpose}; S3 SSE-KMS on aa-crm-<env>-* buckets; ingest also
                                   SES receipt rules aa-crm-<env>-*; seal Sign/Verify), explicit Deny of crypto to every
                                   other non-service principal (break-glass aa-crm-<env>-breakglass excepted), CreateGrant
                                   only for AWS resources. Alarms aa-crm-<env>-kms-key-admin (policy/grant/deletion/
                                   disable/alias) and -kms-foreign-use (crypto by anyone but the task role / AWS
                                   services) -> SNS alerts; live check tools/terraform/crm_kms_alarm_check.py)
    crm_storage.tf                (AA-932 CRM-04 rest: buckets aa-crm-<env>-{audit-c,audit-g,documents,ingest}-<account>,
                                   SSE-KMS + S3 Bucket Keys (audit + ingest: ingest key; documents: data key), BPA,
                                   BucketOwnerEnforced, TLS only, PutObject naming another key/algorithm denied. audit-c:
                                   Object Lock 365 days, GOVERNANCE on Dev (COMPLIANCE only via
                                   var.crm_audit_compliance_enabled, refused on Dev by a precondition and by plan_guard);
                                   audit-g: GOVERNANCE 7 years; lifecycle expires a version 1 day after its retention.
                                   documents: versioned, replaced versions 7 days, exports/ 7 days (+1 day noncurrent). ingest: 1-day expiry,
                                   SES PutObject only from rules aa-crm-<env>-*. No task-role object grants yet (CRM-09/12/17).
                                   KMS Decrypt-rate anomaly alarm: EventBridge (Decrypt on the 3 keys) -> log group
                                   /aws/events/aa-crm-<env>-kms-decrypt (365 d) -> metric AA/Crm/Kms DecryptCalls ->
                                   alarm aa-crm-<env>-kms-decrypt-anomaly (band 3, 2 of 3 x 5 min). The nightly
                                   key-policy diff is .github/workflows/crm-key-policy-diff.yml +
                                   tools/terraform/crm_key_policy_diff.py (plan role, read-only: live GetKeyPolicy vs state))
    crm_app.tf                    (AA-933 CRM-05, AA-Partner API runtime: ECR aa-crm-<env>-api (IMMUTABLE, git-SHA
                                   tags), log group /ecs/aa-crm-<env>, secret shell crm/<env>/sentry-dsn, execution
                                   role (this repo, this log group, the two crm/ secrets and, AA-978, the
                                   M2M client secret aa-crm/<env>/m2m-booking-client), task role
                                   aa-crm-<env>-ecs-task-role (the name the crm_data.tf key policies trust; ECS Exec +
                                   PutMetricData AA/Jobs/Crm only), task definition Fargate ARM64 with the route-class
                                   identity env and, AA-978, CIS_API_URL (var.crm_cis_api_url) + secret M2M_CLIENT
                                   for the CIS membership feed (crm_membership_pull), AA-947, BOOKING_API_URL
                                   (var.crm_booking_api_url) for booking.b2b.v1 (crm_booking_sync, same M2M_CLIENT),
                                   target group aa-crm-<env>-api-tg (/crm/health), ALB rule crm_api
                                   (partner host + X-AA-Origin + /crm, /crm/*; above crm_partner_default), service
                                   aa-crm-<env>-api (desired 0, ignore_changes count + task definition), GitHub OIDC
                                   deploy role aa-crm-<env>-app-deploy (immutable subject, var.crm_github_repo_id),
                                   target-group / CPU alarms; security group sg-crm-api in app_security_groups.tf,
                                   job backlog alarms AA/Jobs/Crm in observability_ecosys.tf)
    crm_web.tf                    (AA-935 CRM-07, AA-Partner CRM web runtime: ECR aa-crm-<env>-web (IMMUTABLE), secret
                                   shell crm/<env>/web {cognito_client_secret, session_secret} written by
                                   tools/identity/crm_dev_identity.py web-secret (never by Terraform), own execution role
                                   (web repo, CRM log group stream prefix web, that secret only; never the DSN) and task
                                   role (ECS Exec only), task definition Fargate ARM64 port 3000 (env: public origin,
                                   partner/client hosts, CRM_API_ORIGIN = the public partner host, the EXTERNAL
                                   cis-portal client until AA-939, CONTENT_STUDIO_URL, CIS_API_URL = var.crm_cis_api_url
                                   for the client-host trip page's CIS GET /v1/trip/{id}, AA-979 P2b), target group
                                   aa-crm-<env>-web-tg
                                   (/healthz) behind crm_partner_default, service aa-crm-<env>-web (desired 0,
                                   FARGATE_SPOT), two target-group alarms; security group sg-crm-web (ALB -> 3000, not
                                   admitted by RDS); the API deploy role also deploys it (crm_app.tf). The cis-portal
                                   client lists the partner host's /auth/callback and /signed-out (identity_variables.tf);
                                   the e2e mailbox rule takes the CRM e2e users of tools/identity/crm_e2e_users.json)
    crm_scrub.tf                  (AA-938 CRM-10, AA-Partner F3 scrubber pass 3, all behind
                                   var.crm_scrub_guardrail_enabled (default false): Bedrock guardrail aa-crm-<env>-scrub
                                   in acc2 (every PII entity on action NONE = detect only; no URL / AGE, no regex, no
                                   content / topic / word filters) + a published version (description = hash of the
                                   entity list, skip_destroy); inline policy aa-crm-<env>-ecs-task-scrub
                                   (bedrock:ApplyGuardrail on that guardrail only) on the CRM task role; GitHub OIDC role
                                   aa-crm-<env>-scrub-corpus (environment scrub-corpus only, ApplyGuardrail only) for
                                   AA-Partner's "Scrub corpus" workflow; task env SCRUB_GUARDRAIL_ID / _VERSION / _REGION
                                   via local.crm_scrub_env in crm_app.tf. Needs the MFA bootstrap apply of cicd_crm.tf
                                   CrmBedrockGuardrail* first. ~ $0.75/month)
    variables.tf / tripplanner_variables.tf / booking_variables.tf
  acc3-bedrock/   ← acc3 Bedrock invoker role (the only satellite) + Bedrock Batch (batch.tf)
                    + Cost Explorer reader + spend guards (cost_guard.tf: monthly budget,
                    daily anomaly e-mail; cost_anomaly_immediate.tf: SNS topic aa3-cost-alerts +
                    IMMEDIATE anomaly subscription >= 15 USD; AA-896)
modules/          ← reusable building blocks, consumed by the account roots
  vpc, rds, ecs, alb, api_gateway, s3, secrets, waf, dynamodb, efs,
  elasticache, eventbridge, langfuse, monitoring
tools/
  github/         ← db_auto_apply_gate.sh + infra-main-ruleset.json (AA-993 I1): environment dev-db-auto (main only),
                    its AWS_ROLE_ARN secret and the ruleset on main (PR required, no direct push or force push, required
                    checks Terraform Plan / gitleaks / the Migration Copy Guard jobs (copies, lint, Expand classify since
                    AA-993 M2b), org-admin bypass only through
                    a PR). Run with Nghiệp's gh login (the GitHub Apps have no Administration permission, ADR 0011).
  identity/       ← workforce_bootstrap.py (AA-854): admin-run, MFA, stdlib + boto3. create-staff
                    (AdminCreateUser SUPPRESS + groups), breakglass-init / -verify (password + TOTP
                    into aa-identity/dev/breakglass, user left DISABLED), breakglass-otp-probe
                    (AA-816: is EMAIL_OTP offered to break-glass; no secret read, no token, Enabled
                    state restored), PKCE spike helpers; tests
                    in tools/identity/tests (job in identity-triggers-test.yml). Tracked on purpose:
                    scripts/ is gitignored, so hand-run tools that must be kept go in tools/.
  contracts/      ← check_contract_copies.py (AA-826, X7): consumer contract-copy hash guard. Pins the
                    sha256 of each root-repo docs/contracts/*.json in contract_copies.json and checks every
                    registered app-repo copy against its pin (red on a modified, missing or unregistered
                    copy); --workspace also proves the pins against the canonical files (the root repo is
                    private, CI cannot read it). Tests in tools/contracts/tests (contract-copy-guard.yml:
                    PR + nightly).
  secrets/        ← register_check.py (AA-878): metadata-only drift check of the root repo's
                    docs/security/secrets-register.yaml against Secrets Manager list-secrets, GitHub
                    secret lists, Vercel env names and Lambda env keys collected beforehand; never
                    reads a value. Tests in tools/secrets/tests (secrets-register-check-test.yml).
  docs/           ← docs lint (AA-888), vendored byte for byte from AA-Ecosys tools/docs: front-matter
                    (schema copy in docs/templates/), ADR index, single-line AWS CLI, resource IDs
                    (VPC IDs fail, account IDs/ARNs warn), offline links; job in docs-lint.yml, which
                    also writes the weekly freshness report. README there says how to keep copies equal.
                    Plus gen_docs.py (AA-893, Infra-only, not part of the vendored set): renders the root
                    repo's docs/generated/ pages (alarm catalog with runbook links, network, inventory, IAM
                    roles) from the accounts/aa365 state JSON (or a plan JSON); `check-source` guards that
                    every alarm and SNS-notifying EventBridge rule carries a runbook suffix. Tests in
                    tools/docs/tests (docs-gen-test.yml); run by docs-gen.yml.
                    Plus gen_env_config.py (AA-894 scope 5): the env-config register (APP-03), env var
                    NAMES of every ECS service, Lambda function and Vercel project (AWS CLI read-only,
                    --query projects names only; Vercel API or the checked-in names-only snapshot
                    env_config_vercel.json); never a value.
```

The **active dev stack** is `accounts/aa365` — it is the root Terraform actually applies against
today. The old `envs/{dev,staging,prod}` scaffold was removed in AA-841 (S238): nothing applied
from it (`envs/dev/main.tf` was empty, staging/prod were 0-byte files) and its
`envs/dev/terraform.tfvars` held plaintext acc1-era credentials. Do not recreate per-env roots
there; a new environment gets its own `accounts/<name>/` root. Only the aa365 root keeps a tracked
`terraform.tfvars` (placeholders for anything secret, see `.gitignore`).

### Main stack modules (accounts/aa365)

The aa365 root composes the standard modules into the running CIS platform: **VPC → RDS → ECS +
ALB + API Gateway → S3 / Secrets / WAF**, plus **EventBridge** (`modules/eventbridge`: the ACP bus, its DLQ and the
`aa-cis-dev-acp` schedule group that holds the `accounts/aa365` schedules; the three ACPv2 schedules daily ingest,
weekly export and Gate C veto window fired into a bus with no rule and were removed in AA-989), the ops-probe Lambda
(`dfs_balance.tf`) and observability
(`observability.tf`, `observability_ecosys.tf`, `diagnostics.tf`, langfuse/monitoring modules).
`observability_ecosys.tf` (S235 Phase 0) covers what is not CIS: NAT status check, Booking target
health / CPU / REST 5XX, TripPlanner Lambda errors + sustained throttles (AA-833: > 5 in 2 of 3
5-minute periods), shared RDS storage + connections, job backlog per owner (AA-751),
and 30-day retention (application class, S241 D-09 / AA-872; it was 14 days before AA-872) on the TripPlanner
Lambda and CIS API Gateway execution log groups (imported).
Its resources carry the blueprint tags (`Project = AA-Ecosys`, `App`); TripPlanner and Booking
resources also carry `App`. Provider `default_tags` are unchanged (re-tagging every resource needs
a wider CI-role grant). ECS runs the CIS API service
(`aa-cis-dev-api` on cluster `aa-cis-dev-cluster`) with `stopTimeout = 90` so in-flight requests
drain on deploy (AA-310, `modules/ecs/main.tf`). The CIS api and worker `DATABASE_URL` is the DSN of
the runtime role `cis_app` (`secret_rds_arn` → `aws_secretsmanager_secret.rds_cis_app`, X1 S18), and the CIS task
role has an explicit Deny on `GetSecretValue` for the master, `db-migrator`, `booking/*`, `tripplanner/*` and `crm/*` (AA-932) secrets
(`DenyMasterAndOtherAppSecrets`, X1 S19), so ECS-exec scripts run as `cis_app` too. A Terraform Apply that touches
`aws_ecs_service`, `aws_ecs_task_definition` or `aws_lambda_function` rolls services and has no job guard: run the
manual idle gate first (root `skill/aa-ship`, X1 plan standing rules). Env on the CIS task definitions comes only
from `modules/ecs/main.tf` (e.g. AA-847 `PLACE_SHAPES_ENABLED` from `place_shapes_enabled`; AA-839
`ERASURE_APPLY_ENABLED` / `ERASURE_TENANT_RETENTION_DAYS` from `local.erasure_drill` in `accounts/aa365`); CIS Deploy Dev copies
the latest revision and swaps the image, so a Terraform env change ships with the next CIS deploy. The reverse also
holds: an env set by hand on a running revision is lost when any apply touching `module.ecs` registers a new
template revision, so every runtime switch lives in the module (AA-645 `S1_WRITER_V2` from `s1_writer_v2_enabled`,
added after the S250 near miss; AA-905 / AA-989 `PLACE_PIPELINE_AUTO` from `place_pipeline_auto`, on since S252); after such an apply, diff the env names of the newest revision against the running
one before the next deploy. Redis (AA-874 S5): api and worker get `REDIS_HOST` = the TLS primary endpoint of
`aws_elasticache_replication_group.main` (`aa-cis-dev-cache`, Valkey, AUTH + TLS + at-rest), `REDIS_TLS=true`,
`REDIS_CLUSTER_ID` = its member node and the secret `REDIS_AUTH_TOKEN` (`aa-cis/dev/redis-auth`, write-only, never
in state). The old S3 → Lambda → Step Functions pipeline
(ingestion/seo/validation/content/export Lambdas, the state machine, 6 SQS queues) and the
`authorizer` / `brand-brief-parser` Lambdas were retired in AA-750; the pipeline runs in the API
and the durable job worker.

**Edge (S235 Phase 0):** the only way in is API Gateway REST (CIS `4ylo382khg`, Booking
`9z3xnalp59`) → VPC link → internal NLB → ALB :80. The ALB is still `internet-facing`, but its SG
admits only :80 from the VPC CIDR (NLB), so it cannot be called directly. The REGIONAL web ACL
`aa-cis-dev-waf` evaluates CommonRuleSet (enforced since AA-806 S239; `SizeRestrictions_BODY`,
`CrossSiteScripting_BODY` and `GenericLFI_BODY` stay COUNT; credential headers redacted in the WAF log)
→ VpcLinkInternalAllow → RateLimit → GeoBlock; rate and
geo only bite on REST API stages (`var.waf_protect_rest_api_stages`, needs `apigateway:SetWebACL`
on the CI role). RDS `aa-cis-dev-db` has deletion protection on.

**Edge, second path (AA-931, CRM-03):** CloudFront (AA-Partner, `partner-dev.`) → CloudFront VPC origin on the
same internal NLB → ALB :80. CloudFront adds the secret header `X-AA-Origin` to every origin request. VPC-origin
traffic keeps a CloudFront source address end to end (an NLB with an `alb` target group preserves the client IP),
so the NLB group admits the `com.amazonaws.global.cloudfront.origin-facing` prefix list and a second ALB group
(`aa-cis-dev-sg-alb-from-nlb`) admits the NLB group; the ALB group itself stays VPC-only (the ALB is still
internet-facing). WAF rule `CloudFrontOriginAllow` (priority 3, exact secret) lets these requests past rate + geo,
which would otherwise judge the CloudFront edge instead of the viewer; `x-aa-origin` is redacted in the WAF log.
ALB rules (`alb_rules.tf`): partner host + secret → partner target group; client host `go-dev.` + secret →
`/crm/public/*` to the CRM API, everything else to the CRM web (AA-936, its own distribution); any `X-AA-Origin` → 403, before the
Booking rule and the CIS default. CloudFront bypasses API Gateway throttling: the AA-Partner app rate-limits on
`CloudFront-Viewer-Address` (AA-933); the CloudFront WAF comes at Go-real (W8).

**AA-Booking** (`booking.tf`, AA-678, root ADR 0004) is a separate app on the same cluster, VPC,
ALB and RDS: ECS service `aa-booking-dev-api` (created at `desired_count = 0`, scaled by hand,
`ignore_changes` on count and task definition), ECR `aa-booking-dev-api` (immutable git-SHA tags),
own execution/task roles, secret `booking/dev/database-url` (container only, value set out-of-band),
supplier-photo bucket `aa-booking-dev-supply-media-<account>` (`booking_media.tf`, AA-835; CIS reads it to copy
rights-cleared photos, never writes), operations-document bucket `aa-booking-dev-ops-docs-<account>`
(`booking_ops_docs.tf`, AA-682; PII, only the Booking task role touches its objects).
Routing: its own REST API `aa-booking-dev-api` on the existing VPC link → NLB → ALB HTTP listener
rule `/booking`, `/booking/*` (priority 100) → target group `aa-booking-dev-api-tg` (health
`/booking/health`). That listener rule is the only object attached to a CIS resource. Dev uses
the execute-api URL (output `booking_api_base_url`); both CIS custom domains use an empty base
path, so a `booking` mapping cannot be added there, and the ACM cert has no Booking name yet.

**DNS + email (AA-811, S237):** `lumiguides.it.com` is a Route 53 public hosted zone in this root
(`dns.tf`, `prevent_destroy`; the CI apply role has no `route53:DeleteHostedZone`). It is served
only after Nghiep switches the nameservers at Namecheap (output `lumiguides_zone_name_servers`),
after a record-by-record parity check (root `docs/audits/2026-10-14-S237-lane-backlog/dns-parity.md`).
Every new `*.lumiguides.it.com` record goes into this zone, not into the Namecheap panel. SES
(`ses.tf`) uses the apex as domain identity, sender `no-reply@lumiguides.it.com`, MAIL FROM
`bounce.lumiguides.it.com`, configuration sets `aa-email-dev-{workforce,external,transactional}`
(Cognito pools use the first two, apps the third). The CIS task role, the Booking task role and the
TripPlanner Lambda exec role may `ses:SendEmail` only as that From address (`ses:FromAddress`) and
only through the transactional set. The account is in the SES sandbox until the production-access
request (console, human) is granted.

**Private DB hostname (AA-829, S248):** `db_dns.tf` adds a private hosted zone `<env>.internal`
associated with the one VPC and a CNAME `db.<env>.internal` (TTL 60) to the RDS endpoint address
(`module.rds` output `db_address`). Every DSN secret names this host, not the RDS endpoint, so a restore or
replacement of the instance changes one record (`var.db_dns_target_override` for an instance outside
Terraform). It resolves only inside the VPC. Clients connect with sslmode/ssl `require` (no certificate
hostname check); a client on `verify-full` must keep the RDS endpoint name. `set-password` still requires the
role secret and the master secret to name the same host, so the secrets move together.

**RDS + job metrics (AA-832, AA-751):** the CIS api process publishes AA/RDS per-role connection
counts and AA/Jobs/CIS backlog metrics every 5 minutes from an in-process sampler
(`api/core/ops_metrics_sampler.py` in AA-CIS-App; api only, not the worker). The shared CIS task role
`aa-cis-dev-ecs-task-role` (api and worker use the same role) may `cloudwatch:PutMetricData` only
into those two namespaces (`observability_ecosys.tf` `cis_ecs_task_put_metric_aa_rds`, condition
`cloudwatch:namespace`). AA-Booking publishes AA/Jobs/Booking from `JobMetricsSampler`
(`backend/app/jobs/metrics.py`, runs only while its worker is enabled); its task role may write
only that namespace (`booking_ecs_task_put_metric_jobs`). Each owner has three alarms:
`<prefix>-jobs-queue-age` (starved due job > 15 min, capacity-aware), `-jobs-overdue-running`
(a running attempt > 2 x the kind's expected seconds) and `-jobs-sampling-stopped` (no sample for
45 min, missing = breaching; the Booking one also fires while Booking is scaled to 0 or its worker
is off). The AA-832 chain (Scheduler every 5 min → ops-probe Lambda → admin POST → `shared.job` →
worker) is gone. **Alarm notifications:** every alarm on `aws_sns_topic.alerts` has
`alarm_actions` only (no `ok_actions`, AA-751): e-mail on a transition into ALARM, recovery in the
console / alarm history. Exception: the 14 `aa-identity-dev-*` alarms (identity.tf, AA-854) already
have `ok_actions` per S241 D-20 (e-mail on OK too), which the other alarms adopt in the D-20 lane. **Alerts topic policy:** `aws_sns_topic.alerts` has exactly one
`aws_sns_topic_policy` — `aws_sns_topic_policy.alerts` in `identity_alerts.tf` (AWS default statement
for same-account publishers + EventBridge from `rule/aa-identity-dev-*`, which sends the break-glass
secret access alerts and the A8 AdminCreateUser alert). A new service publisher adds a statement there; never add a second
`aws_sns_topic_policy` for this topic (they overwrite each other).

The **DFS balance alert** (AA-627) is a small in-VPC Lambda `aa-cis-dev-dfs-balance-check`
triggered daily by EventBridge Scheduler. The schedule must live in the `aa-cis-dev-acp` schedule
group: the CI role's IAM is scoped to `schedule/aa-cis-dev-acp/*`, and a schedule in `default`
makes CI Terraform Plan fail with 403.

## State backend

- **S3 backend** for the main stack: bucket `aa-cis-tfstate-005097885195`, key
  `dev/terraform.tfstate`, region `us-west-1`, locked with the S3 native lockfile
  (`use_lockfile = true`, object `<key>.tflock`). The DynamoDB lock table
  `aa-cis-tfstate-lock-005097885195` is no longer used (AA-846, S245); its IAM grants and the
  table itself are removed in separate steps.
- No `profile` is hardcoded in the aa365 backend: CI (GitHub Actions OIDC) uses ambient env-var
  credentials; locally you `export AWS_PROFILE=aa365-admin` before running Terraform.
- The acc1/acc3 roots are applied only by a human and **must** set `profile` in the backend
  block as well as the provider: `pqnghiep-admin` (acc1, SSO) and `nghiep_aa365` (acc3). The
  provider's `profile` does not apply to backend init; without it Terraform falls back to
  `[default]` (acc2, MFA assume-role) and fails with a confusing MFA error (fixed for acc1 in
  PR #70). Copy the backend block from `acc3-bedrock/versions.tf` when creating a new root.
- Version pins: the aa365 root pins Terraform exactly (`required_version = "1.15.5"`, the same
  version as `terraform_version` in `terraform-plan.yml` and `terraform-apply.yml`; bump all three
  in one PR) and AWS provider `~> 6.69`. The acc1/acc3 roots (applied by a human only) keep
  `>= 1.7.0, < 2.0.0`.

## CI/CD and OIDC

- App repos deploy via **GitHub Actions OIDC**, assuming IAM roles defined in `cicd_split.tf`
  (`aa-cis-dev-app-deploy` for AA-CIS-App, `aa-cis-infra-tf-plan` / `aa-cis-infra-tf-apply` for this
  repo's own Terraform / DB Migrate / schema-dump workflows), `tripplanner.tf`
  (`aa-tripplanner-dev-app-deploy`), `booking.tf` (`aa-booking-dev-app-deploy`) and `crm_app.tf`
  (`aa-crm-dev-app-deploy`, AA-Partner, AA-933), plus `crm_scrub.tf` (`aa-crm-dev-scrub-corpus`, AA-Partner
  "Scrub corpus" workflow, environment `scrub-corpus`, AA-938), and `docs_reader.tf` (`aa-cis-dev-docs-sync`, the root repo's
  "Docs sync" workflow on `master`, AA-898). Each app repo
  and each job type gets its **own** role. The old shared `aa-cis-dev-role` is retired (AA-806
  step 3); the apply boundary denies every write on that name so it cannot come back.
- **OIDC subject fact (learned AA-588, re-verified AA-678):** the repos have GitHub's immutable
  subject claim **on** (`use_immutable_subject: true` from
  `GET /repos/{owner}/{repo}/actions/oidc/customization/sub`), so the real OIDC subject is
  `repo:AdventureAsia365-Ecosys@<orgid>/<repo>@<repoid>:<context>`. A plain
  `repo:AdventureAsia365-Ecosys/<repo>:*` subject fails with AccessDenied.
  - The three CIS roles trust AA-CIS-App / AA-CIS-Infra by their exact immutable prefix
    (org id `276539096`, repo ids `1212291079` / `1212290412`, `local.oidc_sub_cis_app` /
    `local.oidc_sub_cis_infra` in `cicd_split.tf`), each with one exact context. Before AA-678 the
    legacy `aa-cis-dev-role` trusted every org repo (`repo:AdventureAsia365-Ecosys*/*:*`).
  - `aa-tripplanner-dev-app-deploy` trusts one exact subject (S235 Phase 0, `StringEquals`):
    `repo:AdventureAsia365-Ecosys@276539096/AA-TripPlanner-Web@1365222661:ref:refs/heads/main`
    (only `deploy-lambdas.yml` on main assumes it). Before S235 it used the name-wildcard form
    `repo:AdventureAsia365-Ecosys*/AA-TripPlanner-Web*:*`.
  - `aa-booking-dev-app-deploy` trusts only AA-Booking, contexts `environment:dev` and
    `ref:refs/heads/main`. Until `booking_github_repo_id` is set it accepts the immutable form with
    any repo id plus the plain form, both pinned to the exact repo name; once set, only the
    immutable subject with that id (fail closed). Its policy is scoped to the Booking ECR repo,
    task family `aa-booking-dev-api` and service `aa-booking-dev-api` (it cannot register a CIS
    task-definition revision or update a CIS service).
- **AA-806 role split** (`cicd_split.tf`, cut-over plan `docs/ci-role-split.md`):
  `aa-cis-dev-app-deploy` (AA-CIS-App, `environment:dev`, CIS ECR/task families/services only),
  `aa-cis-infra-tf-plan` (`pull_request`, plus `ref:refs/heads/main` for docs-gen.yml since AA-893;
  read only) and `aa-cis-infra-tf-apply`
  (`environment:prod`, boundary `aa-cis-infra-tf-apply-boundary`). `aa-cis-dev-role` was removed in
  step 3 (S239), together with phase 3 (`tf_apply_require_boundary_on_role_policy_writes = true`:
  role policy writes only on roles that carry the workload boundary). **Every new `aws_iam_role` must set
  `permissions_boundary = aws_iam_policy.workload_boundary.arn`** and keep an `aa-*-dev-*` name, or
  CI apply is denied. Changes to the bootstrap objects (the three roles, both boundaries, the GitHub
  OIDC provider, `local.cicd_managed_policies` / `local.cicd_inline_statements` in `cicd.tf` (the
  apply role's grants), `aa-cis-dev-agent-session`, `cicd_crm.tf`) are applied locally.
  AA-931 (`cicd_crm.tf`): the apply role holds 9 AWS managed policies (`AWSStepFunctionsFullAccess` dropped, no
  Step Functions resource since AA-750) plus the customer managed `aa-cis-infra-tf-apply-crm`; the apply boundary
  denies, on KMS keys tagged `App=crm`, every crypto use plus `CreateGrant` / `PutKeyPolicy` /
  `ScheduleKeyDeletion` / `DisableKey`, and on `aa-crm-<env>-audit-*` objects governance bypass, retention /
  legal-hold changes and deletes. CRM key-policy changes therefore stay local MFA applies. Step 4
  sets `aa-workload-boundary` on every existing CI-managed workload role (CIS ECS execution/task
  via `modules/ecs` `permissions_boundary_arn`, the ACP scheduler via `modules/eventbridge`, the NAT
  instance role via `modules/vpc`, Booking/TripPlanner roles, DFS balance Lambda + scheduler,
  diagnostics roles); `aa-cis-dev-agent-session` gets it in a local bootstrap apply. With phase 3
  on, a role without the workload boundary cannot have its policies changed by CI apply at all.
- **CIS REST API throttling** (AA-876, `modules/api_gateway`, values in `accounts/aa365/main.tf`): stage default
  `*/*` 50 rps / burst 100, applied **per method** (each method its own bucket, shared by all callers of it).
  `POST /auth/admin-login` and `POST /auth/tenant-login` are explicit resources (they win over `{auth_proxy+}`)
  with their own override 20 / 40 (3x the busiest second in 14 days of execution logs, 21/10/2026); every other
  `/auth/*` route (verify-admin, verify-tenant, booking-token, refresh) stays on the stage default on purpose: a
  bucket is global to all callers, so a tight cap on `{auth_proxy+}` would let one client cut every BFF off
  session verification (no per-IP rule while the WAF is off). `/content/{content_proxy+}` has a higher override
  300 / 600 (TripPlanner cover `<img>` bursts; busiest second 100). `/catalog/{catalog_proxy+}` (AA-976, ANY,
  NONE at the gateway, HTTP_PROXY to `/catalog/{catalog_proxy}`; the CIS app verifies the M2M token) serves
  `catalog.http.v1` to the partner CRM on the stage default. `/tenant/membership/{membership_proxy+}` (AA-978, same
  shape, HTTP_PROXY to `/tenant/membership/{membership_proxy}`; only this subtree of `/tenant`) serves
  `tenant.membership.v1` (scope `cis.tenant/read`) to the CRM worker on the stage default. Per-IP login limits and per-user backoff are in
  the CIS app (`api/core/login_throttle.py`). The login and content overrides keep detailed metrics off where they
  would be new (~0.30 USD per metric-month). The WAF on the REST stages stays deferred (S241: on when customer
  sign-up opens); reusing the existing ALB web ACL would cost ~0.60 USD per million requests inspected, no new ACL
  or rule fee. Any new resource/method/integration must also go into `aws_api_gateway_deployment.this`
  `depends_on` and `triggers` (AA-432/AA-465/AA-583/AA-876).
- **TripPlanner HTTP API throttling** (AA-806, Dev placeholders): generous stage default 500 rps /
  burst 1000 **per route** (`default_route_settings`; each route gets its own bucket, it is not one
  stage-wide cap; must stay generous because the map fetches one tile per 1-degree cell in a single
  burst). Tight limits only on the LLM-cost routes, each a dedicated route on the same Lambda:
  `POST /trip/{trip_id}/narrate` 2 rps / burst 5 and `GET /browse/search` 10 rps / burst 20
  (`tripplanner_variables.tf`). A new LLM-backed path needs its own route + `route_settings`. HTTP APIs
  cannot carry a WAF web ACL, so this is the only edge cap. WAF count review runbook:
  `docs/waf-count-review.md`.
- This repo has **branch protection** (CI Terraform Plan among the required checks). Terraform
  Plan runs on PRs; PRs are merged after CI passes. There is no auto-merge on this repo.

## How a change gets applied

- **Plan** runs in CI on every PR (required check).
- **Apply** is done deliberately, not on merge:
  - `terraform-apply.yml` is `workflow_dispatch` only (manual trigger), against the same
    `accounts/aa365` root and `dev/terraform.tfstate` state.
  - **Plan guard (AA-846):** between plan and apply, `tools/terraform/plan_guard.py` reads
    `terraform show -json tfplan` and refuses the apply (the run goes red, nothing is applied) when
    the plan changes an `aws_secretsmanager_secret_version`, a `random_password` or an
    `aws_db_instance` with any action other than no-op/read (forget and import included), or (AA-932) creates an
    Object Lock configuration in COMPLIANCE mode, changes / deletes / imports any Object Lock configuration, or
    deletes a bucket with Object Lock enabled (a GOVERNANCE create passes). An
    intended change is dispatched with `allow_guarded=true` plus a non-empty `allow_reason`, which
    is written to the job summary. `guard_selftest=true` runs only the guard, on the committed
    fixture `tools/terraform/tests/fixtures/plan_guarded.json`, with no AWS step; the expected
    result is a red run at "Plan guard". Tests: `tf-plan-guard-test.yml`. The guard covers the CI
    apply only; a local admin apply is not guarded, so read the plan.
  - Locally, applying the aa365 stack needs MFA-exported credentials because Terraform will not
    prompt for MFA on its own:
    ```
    export $(aws configure export-credentials --profile aa365-admin --format env | xargs) && unset AWS_PROFILE
    ```
    then `terraform -chdir=accounts/aa365 apply`.
- **prod**: there is no separate prod apply pipeline wired to merges; a `workflow_dispatch` apply
  targets the same dev state and would show "No changes" if the stack is already in sync.

## Boundaries — what this repo does NOT do

- No application code and no content-pipeline logic (that is AA-CIS-App).
- No application DB schema migrations (`acp_*`, `*_aa_internal`, `tripplanner.*` are owned by the
  app repos). It owns the RDS instance, not what lives inside it. The one exception is the Infra-native
  `db/migrations/roles/` dir (key `rl-NNN`, X1): role bootstrap and attributes (`rl-001` owner roles + `cis_app`,
  `rl-002` `cis_owner` + `db_migrator`), extensions, the `public.*` leftovers and the prepared X1 undo files; it always
  runs as the RDS master, and no owner dir may create a role or an extension. **Connection budget (AA-879, U-61,
  data standards C2.3c):** `db/connection_budget.json` is the machine-readable C2.2 table; the **Connection Budget**
  workflow (`db/check_connection_budget.py`, on every PR touching ECS/RDS/Lambda Terraform or role files, and
  nightly) parses the process counts from Terraform, the `CONNECTION LIMIT`s from the role files and
  `local.rds_max_connections`, checks each pool `max_size` against the app's `main`, and fails when a role's pools
  exceed its limit or the total exceeds 75 % of `max_connections` (an accepted overage needs a reason, an
  `accept_up_to` cap and an expiry ≤ 60 days). Change a pool, process count, limit or instance class → update the
  manifest and the root C2.2 table together. It does own the **DB Migrate**
  workflow (`.github/workflows/db-migrate.yml`): `db/migrations/<owner>/` holds byte-identical copies
  of a reviewed app migration, applied from `main` by a one-off ECS task (S225). The
  **Migration Copy Guard** workflow (AA-807) checks each copy byte for byte against the owner
  repo's `main` on every PR and nightly, so the owner's migration-only PR merges first; a second
  job lints every copy and checks numbers are unique per owner; its ownership lint (AA-853,
  `db/check_migration_ownership.py`) fails an owner-dir copy that creates, alters, grants on or writes to an object
  outside its owner's schemas (`db/owners.yaml`); it is static (function bodies and dynamic SQL unread), the X1
  owner-role switch stays the runtime boundary. The runner applies safe session
  defaults and `-- migrate:` header directives (no-transaction, destructive → RDS snapshot first;
  the snapshot carries `aa:retain-until` = +30 d and is expired by `rds_snapshot_expiry.tf`, AA-869),
  and `apply` refuses (exit 7) while any owner job table is busy or a rerun wave is open (AA-751,
  ADR 0003a decision 5; exempt kinds and the `override_busy_jobs` input in `db/README.md`).
  An `-- migrate: expand` file (AA-993 Phase E, root ADR 0017) is linted as additive-only, size-checked (exit 15),
  skips the idle wait, and since M2b is diffed against the catalog inside its own transaction (`expand_snapshot` /
  `expand_findings` in `db/run_migration.py`): a change to an existing object rolls back with exit 14; `check`
  rehearses it. The Copy Guard's **Expand classify** job runs the same post-check on a replayed PostgreSQL 15
  (`db/expand_check.py --classify`, replay order from the latest DB Schema Dump artifact) for every copy a PR changes.
  **DB Schema Dump** (`db-schema-dump.yml`, AA-807 N1) runs a read-only catalog dump in a one-off ECS
  task nightly and after every apply, and opens a PR on the root repo that regenerates
  `docs/architecture/db-schema-reference.md` and the generated ERD pages `docs/architecture/erd/` (`db/gen_erd.py`,
  AA-894; plus `erd.json` in the run artifact and at `s3://<bronze>/data-model/erd/latest.json`, with the model before the last structural change at `previous.json`: the input of the CIS admin view `/admin/data-model`, AA-894 scope 2; the CIS task role may read exactly those two objects (`modules/ecs` `ReadErdModel`) and is denied `db-schema-dump/*`) and reports drift between the hand-written design ERDs
  (`docs/architecture/erd/design/`) and the live model (`db/check_erd_drift.py`). It also runs the X2 RLS catalogue guard (`db/rls_catalogue_rules.py`,
  a byte copy of AA-CIS-App's CI guard rules kept equal by the Copy Guard's `CODE_COPIES`) and writes the result in
  the file's *RLS catalogue guard (X2)* section; violations are warnings there and blocking in CIS CI. Since AA-853 it
  also replays every applied migration (owner repos' folders, live `shared.schema_versions` order) into a throw-away
  pgvector/PostgreSQL 15 container (`db/replay_migrations.py`, in its own `drift` job with no AWS role, no
  environment and no secrets) and diffs that catalog with the live one (`db/schema_drift.py`): the file's *Schema
  drift* section lists unmanaged / missing / changed objects and the owner decisions of
  `db/schema_drift_decisions.json` (report only; the root PR is opened by a third `publish` job, App token only). Owners and version keys:
  `AA-Ecosys/docs/database/schema-ownership.md`. DB Migrate, the dump and the isolation probe run from the
  migrator task definition (`accounts/aa365/db_migrator.tf`) and log in as **`db_migrator`** since X1 S22
  (AA-860); the RDS master is break-glass plus three automated uses (`roles/` files, `set-password`,
  `run-script`), whose DSN the runner reads in the task (`db/README.md`, `db/owners.yaml` `master_secret`).
  Every owner file runs as the live owner of its dir's anchor schema (`cis_owner`, `bk_owner`, `tp_owner`); the
  nightly DB Isolation Probe cell `sessions.master_break_glass_only` flags any other master session.
  **DB Tour Liveness Gate** (`db-tour-liveness-gate.yml`, AA-986 L7b, root ADR 0015 decision 6; nightly 04:43 UTC and
  manual) runs `db/scripts/s248_tour_deletion_probe.py` through the same run-script path (migrator task, master login,
  READ_ONLY) and `db/tour_liveness_gate.py` fails the run on any violation (a derivative of a tour that is no longer
  served still live in the catalog, AA-Booking or TripPlanner; two active Masters in a group; an active Master over a
  dead source; the lifecycle record or, from L4, the tombstone disagreeing with the derived served state) or any layer
  that failed to run; an all-superseded group that had a Master but carries no `retired` record; or a visibility
  floor error, when the login sees no AA rows through FORCE RLS). Checks of later slices report `pending` until their
  object exists (L4) or `ENFORCED_SINCE` in the script names the date the slice went live (L3, L5); a slice in
  `LANDED` (L2 today) whose object goes missing is red, never pending. The CIS and tenant layers of the S248 memo
  probe are not in the gate yet (follow-up slice under AA-986). **DB Freshness Probe** (`db-freshness-probe.yml`,
  AA-991; nightly 05:13 UTC and manual) runs `db/scripts/aa991_freshness_probe.py` the same way, reads as `cis_app`, and
  counts per layer the links that did not follow a tour's atoms (segments, ranking, routes by parity with route
  detection, `geo.tour_place`, place-card links, T8 angle requests, SEO context) plus, since the S252 propagation
  audit, dead segment member rows (stale) and place-build / place-card coverage (info); `db/freshness_gate.py` is report-only
  (`ENFORCE = False`, red only when the probe itself fails) until AA-988/989/990 close, then red on stale links of tours
  changed more than 24 h ago. The S251 baseline is in `db/README.md`. The CIS
  migration freeze and the `catalog.*` view freeze (XD9) ended with CIS 246 (S22, 19/10/2026).
- **Docs Gen** (`docs-gen.yml`, AA-893) reads the `accounts/aa365` state with the read-only plan role
  (`terraform show -json`, no plan, no lock) nightly and after every Terraform Apply that changed
  something (dispatched by Terraform Apply's separate `docs-gen-dispatch` job, the only job there with
  `actions: write`; the apply job itself keeps `id-token` + `contents: read`), renders `tools/docs/gen_docs.py`'s four pages and opens a PR on the root repo
  (`docs/generated/{alarms,network,inventory,iam-roles}.md`, branch `bot/generated-infra-docs`) when a page
  changed. A missing or broken alarm runbook link fails the run after the PR is updated. The root
  outputs in `accounts/aa365/outputs_inventory.tf` (VPC, subnets, security groups, NAT, RDS, ECS, load
  balancers, API Gateway, photos CDN) are listed on the inventory page; look IDs up there or with `terraform output`.
  The same run renders `docs/generated/env-config.md` (AA-894, `tools/docs/gen_env_config.py`): the env var names
  of every ECS service (primary deployment's task definition, secrets by Secrets Manager name), Lambda function and
  Vercel project, read live with the same read-only role (`ReadOnlyAccess`), names only. Vercel comes from the API
  when the repo secret `VERCEL_TOKEN` exists, else from the checked-in snapshot `tools/docs/env_config_vercel.json`
  (refresh with `gen_env_config.py vercel-snapshot --cli`). A failure there turns the run red at the end without
  holding back the Terraform pages.
- No auto-apply on merge — apply is manual/`workflow_dispatch`, and destructive changes need
  explicit human confirmation.
- Run Terraform from the WSL path (`/home/nghiep/...`), never a Windows UNC path.

## Related documents

- `README.md` (this repo).
- `docs/ecosystem-architecture.md` (root docs repo) — ecosystem-wide account map, Bedrock
  routing, OIDC design, and the App/Infra ownership split.
- `docs/database/schema-ownership.md` (root docs repo) — owner repo per schema / `shared.*` table.
- `docs/architecture/diagrams/infra.svg` (root docs repo) — architecture diagram with AWS icons of what the two
  Terraform roots create, drawn from `infra.py`; catalog page `docs/architecture/diagrams/README.md` (shown in the CIS
  admin at `/admin/docs?path=docs/architecture/diagrams/README.md`), checked against the live state on 2026-10-28.
- `accounts/aa365/versions.tf` — the authoritative state backend + provider config.
- `accounts/aa365/cicd.tf`, `accounts/aa365/tripplanner.tf`, `accounts/aa365/booking.tf` — the OIDC deploy roles and their
  corrected trust subjects.
