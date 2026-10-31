# AA-CIS-Infra — Claude Code Context

Updated 19/10/2026 (S243, AA-889). Short, current rules only. History lives in git, Linear and the
AA-Ecosys session logs, not here.

**Read [`CONTEXT.md`](../CONTEXT.md) before any change** — layout, accounts, every module, OIDC roles,
how a change is applied and the boundaries ("apps own code, Infra owns resources"). The ecosystem view
is `AA-Ecosys/docs/ecosystem-architecture.md`; data rules are `AA-Ecosys/docs/architecture/data-standards/`.
This repo is **public** for now (root ADR 0014 amendment), like the app repos. Account IDs and resource
names are accepted here, but never write step-by-step privilege paths, which principal can read which
secret, or a statement that a protection is missing: put one line pointing to the Linear issue and keep
the detail in Linear or a private root audit.

## Where things are

- Workspace: `~/projects/AA-Ecosys/infra/AA-CIS-Infra` (own `.git`, org `AdventureAsia365-Ecosys`,
  default branch `main`).
- **Live root: `accounts/aa365/`** (acc2). CI runs plan/apply there. The old repo-root Terraform was
  removed in AA-587; the `main.tf.bak*` files left at the root are history (cleanup: AA-890). `envs/` was
  removed in AA-841 — do not recreate it.
- Other roots, applied by a human locally with MFA: `accounts/acc3-bedrock/` (acc3, the only Bedrock
  satellite + Batch + Cost Explorer reader). `accounts/acc1-bedrock/` (acc1) is **retired (AA-998)**:
  nothing in aa365 grants access to it; its only remaining step is a human `terraform destroy`.

| Account | ID | Region | Profile | Holds |
|---|---|---|---|---|
| acc2 | 005097885195 | us-west-1 | `aa365-admin` | all app infrastructure (only account with infra) |
| acc3 | 786888028788 | us-west-1 | `nghiep_aa365` | Bedrock satellite (the only one) |
| acc1 | 867490540162 | us-west-1 | `pqnghiep-admin` | retired (AA-998): resources destroyed 28/10/2026, root folder removed |

Always check first: `aws sts get-caller-identity --profile aa365-admin --region us-west-1`.

## Live state (pointers, not numbers — checked 19/10/2026)

- ECS cluster `aa-cis-dev-cluster`, services `aa-cis-dev-api`, `aa-cis-dev-worker`, `aa-booking-dev-api`.
  Current revisions: `aws ecs describe-services --cluster aa-cis-dev-cluster --services aa-cis-dev-api aa-cis-dev-worker aa-booking-dev-api --profile aa365-admin --region us-west-1 --query 'services[].[serviceName,taskDefinition]' --output text`.
- RDS `aa-cis-dev-db` (PostgreSQL 15, `db.t4g.small`, parameter group `aa-cis-dev-pg15`), shared by all three apps.
- ALB `aa-cis-dev-alb` is **internet-facing** (AA-585); APIs enter through API Gateway + the VPC link NLB.
  Look IDs and DNS names up (CLI or Terraform outputs); do not paste them into docs.
- State backend for `accounts/aa365`: S3 bucket `aa-cis-tfstate-005097885195`, key `dev/terraform.tfstate`,
  S3 lockfile locking only (`use_lockfile`; the DynamoDB lock table is retired, AA-846); Terraform pinned
  exactly to the CI version (`required_version`); no profile in the backend block (CI uses OIDC).
- Secrets: names, owners and readers are in `AA-Ecosys/docs/security/secrets-register.md` (AA-878). Never
  read a secret value; never list secret values in a doc.

## ECR — immutable, one tag per git SHA

Both repositories (`aa-cis-dev-api`, `aa-booking-dev-api`) are **IMMUTABLE** (AA-869). CIS deploys tag
`dev-<git sha>`, Booking tags the git SHA; each deploy registers a task-definition revision pinned to that
tag and the api and worker run the same SHA. The `:latest` in the Terraform task definitions is only a
placeholder (services ignore `task_definition`); never push or deploy `:latest`.

## How changes land

- Branch → PR → required CI (Terraform Plan, guards, gitleaks) → squash merge to `main`.
- **Merge rights (S241 D-13, data standards DM-11.5, v1.1 wording pending N-1):** in the dev phase the
  orchestrating agent merges its own PRs after green CI, infra and IAM included, after an agent review for
  risky changes; subagents never merge. From the first prod environment or paying tenant, Nghiệp approves
  every Terraform/IAM PR before merge.
- **Apply is deliberate, never on merge:** `terraform-apply.yml` (manual dispatch, `environment: prod`,
  role `aa-cis-infra-tf-apply`) or locally from `accounts/aa365/` with MFA credentials
  (`export $(aws configure export-credentials --profile aa365-admin --format env | xargs) && unset AWS_PROFILE`).
  `terraform plan` before every apply; read the plan for destroys.
- Bootstrap objects (CI roles, both permission boundaries, the OIDC provider, `local.cicd_managed_policies` /
  `local.cicd_inline_statements` in `cicd.tf`, the agent session role) are applied locally; CI apply cannot
  change them. Every new `aws_iam_role` sets `permissions_boundary = aws_iam_policy.workload_boundary.arn`.
- Migrations: byte-identical copies in `db/migrations/<owner>/`, applied by **DB Migrate**; the registry
  of owners, prefixes and roles is `db/owners.yaml`. The schema reference is regenerated by
  **DB Schema Dump** (nightly and after each apply).

## Cost and logs

- State the monthly cost of any new AWS resource in the PR before applying it (D-19); prefer zero-cost options.
- Every new CloudWatch log group sets `retention_in_days`: **365** for security/audit logs, **30** for
  application logs (S241 D-09, AA-872, data standards Part B §7).
- Tags: use the existing `Environment` / `App` tags; do not add an `Env` tag.
- Do not start, stop or scale ECS, RDS or the NAT instance unless Nghiệp asks.

## Access

SSM only, never SSH. Container access with ECS Exec (sessions are logged for 365 days; never print env
or secret values), one line:
`aws ecs execute-command --cluster aa-cis-dev-cluster --task <TASK_ARN> --container api --interactive --command "/bin/bash" --profile aa365-admin --region us-west-1`
Scripts against the DB use the S3-mediated pattern in `AA-Ecosys/skill/aa-cis-schema/`.
