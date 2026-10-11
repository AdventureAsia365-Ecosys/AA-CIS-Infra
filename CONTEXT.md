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
    cicd.tf                       (GitHub Actions OIDC deploy roles for the app repos)
    tripplanner.tf                (TripPlanner OIDC deploy role + TripPlanner-specific resources)
    bedrock_satellite_assume.tf   (cross-account Bedrock assume-role trust)
    cost_explorer_satellite_assume.tf (acc2 → acc1/acc3 Cost Explorer read roles, AA-623)
    dfs_balance.tf                (daily DFS balance alert Lambda + EventBridge schedule, AA-627)
    observability.tf, diagnostics.tf
    variables.tf / tripplanner_variables.tf
  acc1-bedrock/   ← acc1 Bedrock invoker role (fallback) + Cost Explorer reader
  acc3-bedrock/   ← acc3 Bedrock invoker role (primary) + Bedrock Batch (batch.tf)
                    + Cost Explorer reader
modules/          ← reusable building blocks, consumed by the account roots
  vpc, rds, ecs, alb, api_gateway, s3, secrets, waf, dynamodb, efs,
  elasticache, eventbridge, langfuse, monitoring
envs/             ← dev / staging / prod thin roots (historical multi-env scaffold)
```

The **active dev stack** is `accounts/aa365` — it is the root Terraform actually applies against
today. The `envs/{dev,staging,prod}` roots are the older multi-env scaffold; treat `accounts/aa365`
as the live one unless a task says otherwise.

### Main stack modules (accounts/aa365)

The aa365 root composes the standard modules into the running CIS platform: **VPC → RDS → ECS +
ALB + API Gateway → S3 / Secrets / WAF**, plus **EventBridge** (ACPv2 schedules: daily ingest,
weekly export, Gate C veto window — not the dead AA-180 orchestration), the ops-probe Lambda
(`dfs_balance.tf`) and observability
(`observability.tf`, `diagnostics.tf`, langfuse/monitoring modules). ECS runs the CIS API service
(`aa-cis-dev-api` on cluster `aa-cis-dev-cluster`) with `stopTimeout = 90` so in-flight requests
drain on deploy (AA-310, `modules/ecs/main.tf`). The old S3 → Lambda → Step Functions pipeline
(ingestion/seo/validation/content/export Lambdas, the state machine, 6 SQS queues) and the
`authorizer` / `brand-brief-parser` Lambdas were retired in AA-750; the pipeline runs in the API
and the durable job worker.

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

- App repos deploy via **GitHub Actions OIDC**, assuming IAM roles defined in `cicd.tf`
  (CIS app deploy) and `tripplanner.tf` (`aa-tripplanner-dev-app-deploy`).
- **OIDC subject fact (learned AA-588):** the org `AdventureAsia365-Ecosys` has "include repo ID
  in the subject" **enabled**, so the real OIDC subject is
  `repo:AdventureAsia365-Ecosys@<orgid>/<repo>@<repoid>:<ref>`. Trust conditions therefore MUST
  use the wildcard form after the org name — e.g. `repo:AdventureAsia365-Ecosys*/*:*` for CI/CD,
  `repo:AdventureAsia365-Ecosys*/AA-TripPlanner-Web*:*` for TripPlanner. A plain
  `repo:AdventureAsia365-Ecosys/<repo>:*` subject (no wildcard) fails with AccessDenied. AA-588
  dropped the old-org trust and corrected these to the wildcard form.
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
  of a reviewed app migration, applied from `main` by a one-off ECS task (S225). Owners and version
  keys: `AA-Ecosys/docs/database/schema-ownership.md`.
- No auto-apply on merge — apply is manual/`workflow_dispatch`, and destructive changes need
  explicit human confirmation.
- Run Terraform from the WSL path (`/home/nghiep/...`), never a Windows UNC path.

## Related documents

- `README.md` (this repo).
- `docs/ecosystem-architecture.md` (root docs repo) — ecosystem-wide account map, Bedrock
  routing, OIDC design, and the App/Infra ownership split.
- `docs/database/schema-ownership.md` (root docs repo) — owner repo per schema / `shared.*` table.
- `accounts/aa365/versions.tf` — the authoritative state backend + provider config.
- `accounts/aa365/cicd.tf`, `accounts/aa365/tripplanner.tf` — the OIDC deploy roles and their
  corrected trust subjects.
