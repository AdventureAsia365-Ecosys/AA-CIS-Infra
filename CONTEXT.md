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
  content pipeline, and does NOT own application DB schemas (`acp_*`, `tripplanner.*`,
  `*_aa_internal`) — those live in the app repos' migrations. It owns the RDS instance the
  schemas live *in*, not the schemas themselves.

## Account model

| Account | ID | Role in ecosystem | Managed here |
|---------|----|-------------------|--------------|
| acc1 | 867490540162 | `AA-Bedrock-Invoker`, Bedrock **fallback** | `accounts/acc1-bedrock/` |
| acc2 (aa365) | 005097885195 | **Main dev stack** (VPC/RDS/ECS/ALB/API GW/…) + CI/CD OIDC | `accounts/aa365/` |
| acc3 | 786888028788 | `AA3-Bedrock-Invoker`, Bedrock **primary** | `accounts/acc3-bedrock/` |

Bedrock routing across the ecosystem is **acc3 primary → acc1 fallback**. The cross-account
assume-role wiring that lets the main stack (acc2) and TripPlanner reach Bedrock in acc3/acc1
lives in `accounts/aa365/bedrock_satellite_assume.tf` and the `acc1-bedrock`/`acc3-bedrock` roots.
The satellite invoker roles trust only the ECS task role (`aa-cis-dev-ecs-task-role`), not an
admin session — Claude cannot be called from a local shell.

Cross-account pieces added 15-25/09/2026 (same assume-role pattern as the Bedrock satellite):

- **Cost Explorer read (AA-623)**: acc2 is a **member account**, not the AWS Organizations payer
  (payer `033086823579` is unrelated to acc1/2/3), so there is no consolidated CE call. Each
  account exposes its own read role, assumed by the acc2 ECS task role:
  - acc1 `AA-CostExplorer-Reader` (ExternalId `aa623-satellite-cost-explorer`),
    `accounts/acc1-bedrock/cost_explorer_reader.tf`;
  - acc3 `AA3-CostExplorer-Reader` (ExternalId `aa623-satellite-cost-explorer-acc3`),
    `accounts/acc3-bedrock/cost_explorer_reader.tf`;
  - acc2 calls CE directly (`ce:GetCostAndUsage` on the ECS task role) and gets
    `sts:AssumeRole` on the two roles above via `accounts/aa365/cost_explorer_satellite_assume.tf`.
- **Bedrock Batch Inference (AA-606)**: bronze bucket prefixes `batch-input/s1-rewrite/*` and
  `batch-output/s1-rewrite/*` (`modules/s3`), plus the batch service roles
  `aa-bedrock-batch-inference-role` (acc1) and `aa3-bedrock-batch-inference-role` (acc3,
  `accounts/acc3-bedrock/batch.tf`). IAM is complete, but **AWS has not enabled Batch
  Inference on acc3 yet** (support case 178979743800653, Linear AA-624): job creation fails with
  a `ValidationException` about account authorization, which is an entitlement, not IAM.

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
    tripplanner.tf                (TripPlanner OIDC deploy role + TripPlanner-specific resources)
    booking.tf                    (AA-Booking ECS service, ECR, ALB rule /booking/*, REST API on the
                                   existing VPC link, OIDC deploy role — AA-678)
    bedrock_satellite_assume.tf   (cross-account Bedrock assume-role trust)
    cost_explorer_satellite_assume.tf (acc2 → acc1/acc3 Cost Explorer read roles, AA-623)
    dfs_balance.tf                (ops-probe Lambda: 06:15 UTC schedule POSTs the admin probes, AA-627/720/727;
                                   20:30 UTC schedule POSTs /admin/job-runner/retention/schedule, AA-825;
                                   every 5 min (rate) POSTs /admin/job-runner/rds-role-connections/schedule
                                   → CIS job ops_rds_role_connections publishes AA/RDS, AA-832)
    observability.tf, observability_ecosys.tf (S235 alarms + log retention; RDS alarms per data standard
                                   C4.1 + per-role AA/RDS RoleConnectionLimitPct alarms and the task-role
                                   AA/RDS PutMetricData grant, AA-832), diagnostics.tf
    dns.tf                        (Route 53 public zone lumiguides.it.com + records copied from Namecheap, AA-811)
    ses.tf                        (SES domain identity, DKIM/MAIL FROM/DMARC records, configuration sets,
                                   ses:SendEmail grants for the app roles, reputation alarms — AA-811)
    custom_domains.tf             (AA-818: ACM certs api-booking./api-tripplanner. (us-west-1) and auth./staff-auth.
                                   (us-east-1, provider alias aws.us_east_1) + validation records; API GW custom
                                   domains, alias records and Vercel CNAMEs gated by var.custom_domains_enabled)
    variables.tf / tripplanner_variables.tf / booking_variables.tf
  acc1-bedrock/   ← acc1 Bedrock invoker role (fallback) + Cost Explorer reader
  acc3-bedrock/   ← acc3 Bedrock invoker role (primary) + Bedrock Batch (batch.tf)
                    + Cost Explorer reader
modules/          ← reusable building blocks, consumed by the account roots
  vpc, rds, ecs, alb, api_gateway, s3, secrets, waf, dynamodb, efs,
  elasticache, eventbridge, langfuse, monitoring
```

The **active dev stack** is `accounts/aa365` — it is the root Terraform actually applies against
today. The old `envs/{dev,staging,prod}` scaffold was removed in AA-841 (S238): nothing applied
from it (`envs/dev/main.tf` was empty, staging/prod were 0-byte files) and its
`envs/dev/terraform.tfvars` held plaintext acc1-era credentials. Do not recreate per-env roots
there; a new environment gets its own `accounts/<name>/` root. Only the aa365 root keeps a tracked
`terraform.tfvars` (placeholders for anything secret, see `.gitignore`).

### Main stack modules (accounts/aa365)

The aa365 root composes the standard modules into the running CIS platform: **VPC → RDS → ECS +
ALB + API Gateway → S3 / Secrets / WAF**, plus **EventBridge** (ACPv2 schedules: daily ingest,
weekly export, Gate C veto window — not the dead AA-180 orchestration), the ops-probe Lambda
(`dfs_balance.tf`) and observability
(`observability.tf`, `observability_ecosys.tf`, `diagnostics.tf`, langfuse/monitoring modules).
`observability_ecosys.tf` (S235 Phase 0) covers what is not CIS: NAT status check, Booking target
health / CPU / REST 5XX, TripPlanner Lambda errors + sustained throttles (AA-833: > 5 in 2 of 3
5-minute periods, no OK notification), shared RDS storage + connections,
and 14-day retention on the TripPlanner Lambda and CIS API Gateway execution log groups (imported).
Its resources carry the blueprint tags (`Project = AA-Ecosys`, `App`); TripPlanner and Booking
resources also carry `App`. Provider `default_tags` are unchanged (re-tagging every resource needs
a wider CI-role grant). ECS runs the CIS API service
(`aa-cis-dev-api` on cluster `aa-cis-dev-cluster`) with `stopTimeout = 90` so in-flight requests
drain on deploy (AA-310, `modules/ecs/main.tf`). The old S3 → Lambda → Step Functions pipeline
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

**AA-Booking** (`booking.tf`, AA-678, root ADR 0004) is a separate app on the same cluster, VPC,
ALB and RDS: ECS service `aa-booking-dev-api` (created at `desired_count = 0`, scaled by hand,
`ignore_changes` on count and task definition), ECR `aa-booking-dev-api` (immutable git-SHA tags),
own execution/task roles, secret `booking/dev/database-url` (container only, value set out-of-band).
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

**RDS metrics (AA-832):** the shared CIS task role `aa-cis-dev-ecs-task-role` (api and worker use
the same role) may also `cloudwatch:PutMetricData` only into namespace `AA/RDS`
(`observability_ecosys.tf`, condition `cloudwatch:namespace`); the CIS worker job
`ops_rds_role_connections` publishes per-role connection counts there. That job exists only
because the ops-probe Lambda enqueues it every 5 minutes, so the Infra schedule depends on the CIS
endpoint `POST /admin/job-runner/rds-role-connections/schedule` being deployed first.

The **DFS balance alert** (AA-627) is a small in-VPC Lambda `aa-cis-dev-dfs-balance-check`
triggered daily by EventBridge Scheduler. The schedule must live in the `aa-cis-dev-acp` schedule
group: the CI role's IAM is scoped to `schedule/aa-cis-dev-acp/*`, and a schedule in `default`
makes CI Terraform Plan fail with 403.

## State backend

- **S3 backend** for the main stack: bucket `aa-cis-tfstate-005097885195`, key
  `dev/terraform.tfstate`, region `us-west-1`, with DynamoDB lock table
  `aa-cis-tfstate-lock-005097885195`.
- No `profile` is hardcoded in the aa365 backend: CI (GitHub Actions OIDC) uses ambient env-var
  credentials; locally you `export AWS_PROFILE=aa365-admin` before running Terraform.
- The acc1/acc3 roots are applied only by a human and **must** set `profile` in the backend
  block as well as the provider: `pqnghiep-admin` (acc1, SSO) and `nghiep_aa365` (acc3). The
  provider's `profile` does not apply to backend init; without it Terraform falls back to
  `[default]` (acc2, MFA assume-role) and fails with a confusing MFA error (fixed for acc1 in
  PR #70). Copy the backend block from `acc3-bedrock/versions.tf` when creating a new root.
- Provider pins: Terraform `>= 1.7.0, < 2.0.0`, AWS provider `~> 5.40`.

## CI/CD and OIDC

- App repos deploy via **GitHub Actions OIDC**, assuming IAM roles defined in `cicd_split.tf`
  (`aa-cis-dev-app-deploy` for AA-CIS-App, `aa-cis-infra-tf-plan` / `aa-cis-infra-tf-apply` for this
  repo's own Terraform / DB Migrate / schema-dump workflows), `tripplanner.tf`
  (`aa-tripplanner-dev-app-deploy`) and `booking.tf` (`aa-booking-dev-app-deploy`). Each app repo
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
  `aa-cis-infra-tf-plan` (`pull_request`, read only) and `aa-cis-infra-tf-apply`
  (`environment:prod`, boundary `aa-cis-infra-tf-apply-boundary`). `aa-cis-dev-role` was removed in
  step 3 (S239), together with phase 3 (`tf_apply_require_boundary_on_role_policy_writes = true`:
  role policy writes only on roles that carry the workload boundary). **Every new `aws_iam_role` must set
  `permissions_boundary = aws_iam_policy.workload_boundary.arn`** and keep an `aa-*-dev-*` name, or
  CI apply is denied. Changes to the bootstrap objects (the three roles, both boundaries, the GitHub
  OIDC provider, `local.cicd_managed_policies` / `local.cicd_inline_statements` in `cicd.tf` (the
  apply role's grants), `aa-cis-dev-agent-session`) are applied locally. Step 4
  sets `aa-workload-boundary` on every existing CI-managed workload role (CIS ECS execution/task
  via `modules/ecs` `permissions_boundary_arn`, the ACP scheduler via `modules/eventbridge`, the NAT
  instance role via `modules/vpc`, Booking/TripPlanner roles, DFS balance Lambda + scheduler,
  diagnostics roles); `aa-cis-dev-agent-session` gets it in a local bootstrap apply. With phase 3
  on, a role without the workload boundary cannot have its policies changed by CI apply at all.
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
  - Locally, applying the aa365 stack needs MFA-exported credentials because Terraform will not
    prompt for MFA on its own:
    ```
    export $(aws configure export-credentials --profile aa365-admin --format env | xargs) \
      && unset AWS_PROFILE
    ```
    then `terraform -chdir=accounts/aa365 apply`.
- **prod**: there is no separate prod apply pipeline wired to merges; a `workflow_dispatch` apply
  targets the same dev state and would show "No changes" if the stack is already in sync.

## Boundaries — what this repo does NOT do

- No application code and no content-pipeline logic (that is AA-CIS-App).
- No application DB schema migrations (`acp_*`, `*_aa_internal`, `tripplanner.*` are owned by the
  app repos). It owns the RDS instance, not what lives inside it. It does own the **DB Migrate**
  workflow (`.github/workflows/db-migrate.yml`): `db/migrations/<owner>/` holds byte-identical copies
  of a reviewed app migration, applied from `main` by a one-off ECS task (S225). The
  **Migration Copy Guard** workflow (AA-807) checks each copy byte for byte against the owner
  repo's `main` on every PR and nightly, so the owner's migration-only PR merges first; a second
  job lints every copy and checks numbers are unique per owner. The runner applies safe session
  defaults and `-- migrate:` header directives (no-transaction, destructive → RDS snapshot first).
  **DB Schema Dump** (`db-schema-dump.yml`, AA-807 N1) runs a read-only catalog dump in a one-off ECS
  task nightly and after every apply, and opens a PR on the root repo that regenerates
  `docs/architecture/db-schema-reference.md`. Owners and version keys:
  `AA-Ecosys/docs/database/schema-ownership.md`.
- No auto-apply on merge — apply is manual/`workflow_dispatch`, and destructive changes need
  explicit human confirmation.
- Run Terraform from the WSL path (`/home/nghiep/...`), never a Windows UNC path.

## Related documents

- `README.md` (this repo).
- `docs/ecosystem-architecture.md` (root docs repo) — ecosystem-wide account map, Bedrock
  routing, OIDC design, and the App/Infra ownership split.
- `docs/database/schema-ownership.md` (root docs repo) — owner repo per schema / `shared.*` table.
- `accounts/aa365/versions.tf` — the authoritative state backend + provider config.
- `accounts/aa365/cicd.tf`, `accounts/aa365/tripplanner.tf`, `accounts/aa365/booking.tf` — the OIDC deploy roles and their
  corrected trust subjects.
