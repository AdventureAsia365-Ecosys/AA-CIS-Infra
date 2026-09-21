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

## Layout

```
accounts/
  aa365/          ← main stack root (acc2 005097885195, us-west-1) — the big one
    main.tf                       (wires all modules for the dev stack)
    versions.tf                   (providers + S3 state backend)
    cicd.tf                       (GitHub Actions OIDC deploy roles for the app repos)
    tripplanner.tf                (TripPlanner OIDC deploy role + TripPlanner-specific resources)
    bedrock_satellite_assume.tf   (cross-account Bedrock assume-role trust)
    dfs_balance.tf, observability.tf, diagnostics.tf, ...
    variables.tf / tripplanner_variables.tf
  acc1-bedrock/   ← acc1 Bedrock invoker role (fallback)
  acc3-bedrock/   ← acc3 Bedrock invoker role (primary) + Bedrock Batch (batch.tf)
modules/          ← reusable building blocks, consumed by the account roots
  vpc, rds, ecs, alb, api_gateway, s3, secrets, waf, lambda, dynamodb, efs,
  elasticache, eventbridge, sqs_sns, step_functions, langfuse, monitoring
envs/             ← dev / staging / prod thin roots (historical multi-env scaffold)
```

The **active dev stack** is `accounts/aa365` — it is the root Terraform actually applies against
today. The `envs/{dev,staging,prod}` roots are the older multi-env scaffold; treat `accounts/aa365`
as the live one unless a task says otherwise.

### Main stack modules (accounts/aa365)

The aa365 root composes the standard modules into the running CIS platform: **VPC → RDS → ECS +
ALB + API Gateway → S3 / Secrets / WAF**, plus **Lambda** (CIS functions + the remaining ACP
`brand_brief_parser`), **EventBridge** (ACPv2 schedules: daily ingest, weekly export, Gate C veto
window — not the dead AA-180 orchestration), **Step Functions**, and observability
(`observability.tf`, `diagnostics.tf`, langfuse/monitoring modules). ECS runs the CIS API service
(`aa-cis-dev-api` on cluster `aa-cis-dev-cluster`).

## State backend

- **S3 backend** for the main stack: bucket `aa-cis-tfstate-005097885195`, key
  `dev/terraform.tfstate`, region `us-west-1`, with DynamoDB lock table
  `aa-cis-tfstate-lock-005097885195`.
- No `profile` is hardcoded in the backend: CI (GitHub Actions OIDC) uses ambient env-var
  credentials; locally you `export AWS_PROFILE=aa365-admin` before running Terraform.
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
  app repos). It owns the RDS instance, not what lives inside it.
- No auto-apply on merge — apply is manual/`workflow_dispatch`, and destructive changes need
  explicit human confirmation.
- Run Terraform from the WSL path (`/home/nghiep/...`), never a Windows UNC path.

## Related documents

- `README.md` (this repo).
- `docs/ecosystem-architecture.md` (root docs repo) — ecosystem-wide account map, Bedrock
  routing, OIDC design, and the App/Infra ownership split.
- `accounts/aa365/versions.tf` — the authoritative state backend + provider config.
- `accounts/aa365/cicd.tf`, `accounts/aa365/tripplanner.tf` — the OIDC deploy roles and their
  corrected trust subjects.
