# AA-CIS-Infra — Terraform for the AA_Ecosys AWS accounts

Owns the AWS resources of the ecosystem ("apps own code, Infra owns resources"): VPC, RDS, ECS,
ALB, API Gateway, WAF, S3, Secrets Manager, Lambdas, EventBridge, IAM/OIDC deploy roles, alarms,
and the cross-account Bedrock / Cost Explorer roles. It also owns the **DB Migrate** workflow that
applies reviewed app migrations to the shared RDS.

- **Details (layout, accounts, OIDC facts, boundaries):** [`CONTEXT.md`](CONTEXT.md).
- **Ecosystem:** `AA-Ecosys/docs/ecosystem-architecture.md`, ADRs in `AA-Ecosys/docs/adr/`,
  schema owners in `AA-Ecosys/docs/database/schema-ownership.md`.

## Accounts and roots

| Root | Account | What | Applied by |
|---|---|---|---|
| `accounts/aa365/` | acc2 `005097885195`, us-west-1 | **Live stack**: CIS (ECS api + worker, RDS, ALB, API GW, WAF, S3, ops-probe Lambda, alarms) and TripPlanner (2 Lambdas, HTTP API, artifacts, OIDC role) | CI workflow `Terraform Apply Prod` |
| `accounts/acc3-bedrock/` | acc3 `786888028788` | Bedrock invoker role (primary), Bedrock Batch, Cost Explorer reader | a human, locally (profile `nghiep_aa365`) |
| `accounts/acc1-bedrock/` | acc1 `867490540162` | Bedrock invoker role (fallback), Cost Explorer reader | a human, locally (profile `pqnghiep-admin`) |
| repo-root `main.tf.bak*` | — | historical, **not live** — do not run Terraform there (`envs/*` removed in AA-841) | — |

```
accounts/aa365/   main.tf, cicd.tf, tripplanner.tf, booking.tf, observability.tf, observability_ecosys.tf, dfs_balance.tf, … (+ lambda_src/)
modules/          vpc, rds, ecs, alb, api_gateway, s3, secrets, waf, eventbridge, monitoring, …
db/               run_migration.py + migrations/<owner>/ copies applied by DB Migrate,
                  check_migration_copies.py + check_migration_files.py (+ tests/) for the guards,
                  schema_dump.py + gen_schema_reference.py for the schema reference
.github/workflows terraform-plan.yml (PR), terraform-apply.yml (manual), db-migrate.yml (manual),
                  migration-copy-guard.yml (PR on db/migrations/**, nightly),
                  db-schema-dump.yml (nightly, manual, after each DB Migrate apply),
                  secret-scan.yml (PR, manual; gitleaks with .gitleaks.toml + .gitleaksignore)
```

## How a change is applied

1. PR → **Terraform Plan** runs in CI (required). Read the plan; say in the PR what it should show.
2. Merge after review (human approval).
3. Run **Terraform Apply Prod** (`workflow_dispatch` on `main`); check `Apply complete! …` matches
   the plan.

Locally (acc2 needs MFA-exported credentials):

```bash
export $(aws configure export-credentials --profile aa365-admin --format env | xargs) && unset AWS_PROFILE
terraform -chdir=accounts/aa365 init && terraform -chdir=accounts/aa365 plan
```

Run Terraform from the WSL path, never a Windows UNC path. State: S3
`aa-cis-tfstate-005097885195` / `dev/terraform.tfstate`, lock table `aa-cis-tfstate-lock-005097885195`.

## DB Migrate (shared RDS)

RDS is private, so `db-migrate.yml` starts a one-off Fargate task from the CIS api task definition
and runs one SQL file with the task's own `DATABASE_URL`:

1. A **migration-file-only** PR merges to the owner repo's `main` first (no code that reads the
   new objects yet).
2. An Infra PR adds a byte-identical copy in `db/migrations/<owner>/` (`cis`, `tripplanner`,
   `booking`) — `cp`, not an editor. **Migration Copy Guard** (AA-807) fails the PR if the file
   is not on the owner's `main` yet, differs by one byte, or does not register its own key.
3. After the Infra PR merges: run **DB Migrate** on `main` with `mode=check`, then `mode=apply`.
   The job fails unless the version (`NNN`, `tp-NNN`, `bk-NNN`) is registered in
   `shared.schema_versions` afterwards. Re-running `apply` is a no-op. The runner sets
   `lock_timeout 5s` / `statement_timeout 15min` / `application_name db-migrate`; a file can
   override the timeouts and use `-- migrate: no-transaction` or `-- migrate: destructive` (RDS
   snapshot first) in its header.
4. Merge the app PR that needs the migration.
5. After the apply, **DB Schema Dump** runs by itself and opens/updates the root PR that
   regenerates `AA-Ecosys/docs/architecture/db-schema-reference.md` (also nightly).

Details: [`db/README.md`](db/README.md).

## CI secrets and variables

Names only. GitHub secrets: `AWS_ROLE_ARN` (OIDC role assumed by CI), `AWS_REGION`,
`TF_STATE_BUCKET`, `TF_VAR_DB_PASSWORD`, `ROOT_REPO_DOCS_TOKEN` (DB Schema Dump: fine-grained token
on AdventureAsia365-Ecosys/AA-Ecosys only, Contents + Pull requests read/write). Terraform inputs for `accounts/aa365` are in
`variables.tf` / `tripplanner_variables.tf` / `booking_variables.tf` and `terraform.tfvars` (no secret values in git —
secrets are referenced by ARN).

## Secret scan

**Secret Scan** (`.github/workflows/secret-scan.yml`, AA-841) runs gitleaks on every PR against the
lines the PR's commits add, with the default rules plus two repo rules in `.gitleaks.toml` (a DSN
with an embedded password; a plaintext password / API key / token in `.tf` / `.tfvars` / `.hcl`).
It fails on any finding; values are redacted in the log. It does not scan old history (no history
rewrite under AA-841), so a PR that only deletes a file passes.

Never commit a real `terraform.tfvars`: `.gitignore` ignores every tfvars except
`accounts/aa365/terraform.tfvars`, whose secret-shaped variables stay `REPLACE_ME` placeholders.

Run it locally before pushing (Docker, same pinned image as CI; `--redact` keeps values out of
the terminal):

```bash
IMG=ghcr.io/gitleaks/gitleaks:v8.28.0
# The commits on this branch that main does not have (what the PR check sees)
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD:/repo" -w /repo $IMG git /repo --log-opts="origin/main..HEAD" -c /repo/.gitleaks.toml -i /repo/.gitleaksignore --redact --verbose --no-banner
# The whole working tree, untracked files included
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD:/repo" -w /repo $IMG dir /repo -c /repo/.gitleaks.toml -i /repo/.gitleaksignore --redact --verbose --no-banner
```

Run from a normal clone: in a `git worktree`, `.git` is a file pointing outside the mount, so the
`git` form needs the main repo's `.git` mounted at the same path (the `dir` form works anywhere).

False positive: prefer a narrow allowlist entry in `.gitleaks.toml` (a placeholder regex or a
path) for a class of values; add the printed fingerprint to `.gitleaksignore` (with a comment) for
one finding. A real secret is never ignored: drop it from the branch and rotate it.

## Rules

- `terraform plan` before every apply; destructive changes need explicit human confirmation.
- ECR images: task definitions use `:latest`; Deploy Dev pins the built image per revision.
- Never start/stop the environment (ECS desired count, RDS, NAT) without Nghiệp asking.
- Container access through SSM (`aws ecs execute-command`), never SSH.
