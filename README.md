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

```
accounts/aa365/   main.tf, cicd.tf, tripplanner.tf, booking.tf, observability.tf, observability_ecosys.tf, dfs_balance.tf, … (+ lambda_src/)
modules/          vpc, rds, ecs, alb, api_gateway, s3, secrets, waf, eventbridge, monitoring, …
db/               run_migration.py + migrations/<owner>/ copies applied by DB Migrate,
                  check_migration_copies.py + check_migration_files.py (+ tests/) for the guards,
                  schema_dump.py + gen_schema_reference.py for the schema reference, gen_erd.py for the ERD,
                  check_erd_drift.py for design-vs-live ERD drift,
                  tour_liveness_gate.py for the nightly tour liveness gate (AA-986)
.github/workflows terraform-plan.yml (PR), terraform-apply.yml (manual), db-migrate.yml (manual),
                  migration-copy-guard.yml (PR on db/migrations/**, nightly),
                  db-schema-dump.yml (nightly, manual, after each DB Migrate apply),
                  db-isolation-probe.yml (nightly, manual, after each DB Migrate apply),
                  db-tour-liveness-gate.yml (nightly 04:43 UTC, manual; AA-986 tour liveness gate),
                  secret-scan.yml (PR; gitleaks with .gitleaks.toml + .gitleaksignore),
                  secret-scan-history.yml (nightly, push to main, manual; full history + working tree),
                  docs-lint.yml (PR on Markdown, weekly freshness report; tools/docs/README.md)
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
`aa-cis-tfstate-005097885195` / `dev/terraform.tfstate`, locked by the S3 lockfile
(`use_lockfile`; the DynamoDB lock table is retired, AA-846). Terraform is pinned to exactly the CI
version (`required_version` in `accounts/aa365/versions.tf`); after the backend change a local checkout
needs `terraform init -reconfigure` once.

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
   snapshot first) in its header. Apply waits (3 x 20 s) and then refuses with exit 7 while any
   owner job table (`shared.job`, `booking.job`, …) has a queued/running row of a non-exempt kind
   or a `shared.rerun_wave` is open (AA-751); `check` shows the same report. Input
   `override_busy_jobs=<reason>` (Nghiệp only) applies anyway.
4. Merge the app PR that needs the migration.
5. After the apply, **DB Schema Dump** runs by itself and opens/updates the root PR that
   regenerates `AA-Ecosys/docs/architecture/db-schema-reference.md` (also nightly).

Details: [`db/README.md`](db/README.md).

## CI secrets and variables

Names only. GitHub secrets: `AWS_ROLE_ARN` (OIDC role assumed by CI), `AWS_REGION`,
`TF_STATE_BUCKET`, `TF_VAR_DB_PASSWORD`, `AA_CI_BOT_PRIVATE_KEY` with the variable `AA_CI_BOT_APP_ID` (GitHub
App `aa-ecosys-ci-bot`, root ADR 0011: DB Schema Dump and Docs Gen mint a short-lived token on
AdventureAsia365-Ecosys/AA-Ecosys only, Contents + Pull requests write, in jobs that run on `main` only; the Migration
Copy Guard retention-rows job mints a Contents-read token). Terraform inputs for `accounts/aa365` are in
`variables.tf` / `tripplanner_variables.tf` / `booking_variables.tf` and `terraform.tfvars` (no secret values in git —
secrets are referenced by ARN).

## Secret scan

**Secret Scan** (`.github/workflows/secret-scan.yml`, PR check) and **Secret Scan (full history)**
(`.github/workflows/secret-scan-history.yml`) run gitleaks with the gitleaks v8.30.1 default rules (copied into
`.gitleaks.toml` without gitleaks' global path allowlist, which skipped text files such as `.svg` or `node_modules/`)
plus three repo rules in
`.gitleaks.toml` (byte-identical to the root repo and the four app repos, plus two Infra-only allowlist entries at
the end) (a DSN with an embedded password; a plaintext
password / API key / token in `.tf` / `.tfvars` / `.hcl`; a credential-named key — `*password`, `*passwd`,
`*pwd`, `*secret`, `*api_key`, `*_token` — with a literal value in `*.tfvars`, `*.tfvars.json`,
`.env*`, `*.json`, `*.yaml`, inline maps included). Values are redacted in the log.

- **gitleaks** (every PR, AA-841): the lines the PR's commits add, plus a squash preview (the PR merged into the base as
  one commit: what the squash merge writes, so a value split across commits is seen whole). A PR that only deletes a
  file passes. It runs on `pull_request_target`: GitHub always runs the base branch's copy of the workflow and the
  PR head is only read as data, so a PR cannot change the check that judges it (a change to the workflow takes
  effect after its merge). It fails when another workflow has a job named `gitleaks` (the required check is
  matched by name).
  The rules and the baseline are read from the PR's **base** commit, so a PR cannot add a secret and its
  ignore line together. A PR that changes `.gitleaks.toml`, `.gitleaksignore`, either secret scan workflow,
  `.github/CODEOWNERS` or any `.gitattributes`, changes a workflow that grants checks or statuses write (or
  one yq cannot read) or adds an inline `gitleaks:allow`
  comment, fails until a reviewer adds the label `secret-scan-baseline-reviewed`
  after the last push (then the PR's own copies are used); any later push, reopen or label change removes
  the label. The files are in CODEOWNERS. Merge commits are read as remerge diffs (what the merge adds
  beyond git's automatic merge), renamed files whole and every file as text (NUL bytes included; UTF-16 files
  are transcoded to UTF-8; no path allowlist); an octopus merge or a git error
  fails the check. For a false positive prefer a narrow allowlist in `.gitleaks.toml`: a commit
  fingerprint does not survive the squash merge (header of `.gitleaksignore`).
- **gitleaks full history** (`secret-scan-history.yml`: nightly, every push to `main`, on demand; AA-981): every commit of every
  branch and tag, plus the head of every pull request (`refs/pull/*/head`, closed PRs included: GitHub
  keeps them public after the branch is deleted). Historical findings are pinned by commit fingerprint in
  `.gitleaksignore`; anything else turns the job red. A new real finding is rotated first, then pinned. On demand the job
  **gitleaks working tree** also scans the chosen ref's files. The history workflow has no job named
  `gitleaks`, so a manual run on a PR branch cannot leave a skipped `gitleaks` check on the PR head.

A red result from any of them means the value is public already (GitHub keeps PR heads and pushed commits after a
force-push or a deleted branch): rotate it, even if it was force-pushed away.

GitHub secret scanning and push protection are on for this repo as well (S248).

Never commit a real `terraform.tfvars`: `.gitignore` ignores every tfvars except
`accounts/aa365/terraform.tfvars`, whose secret-shaped variables stay `REPLACE_ME` placeholders.

Run it locally before pushing (Docker, same pinned image as CI; `--redact` keeps values out of
the terminal):

```bash
IMG=ghcr.io/gitleaks/gitleaks:v8.30.1
# Read every file as text, like CI (a NUL byte or a .gitattributes binary / -diff would hide lines)
printf '* diff\n' >> .git/info/attributes
# The commits on this branch that main does not have (what the PR check sees)
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD:/repo" -w /repo $IMG git /repo --log-opts="--diff-merges=remerge --no-renames origin/main..HEAD" -c /repo/.gitleaks.toml -i /repo/.gitleaksignore --redact --verbose --no-banner
# Squash preview: this branch's final tree as one commit on the merge base (what the squash merge writes)
sq=$(git -c user.name=ci -c user.email=ci@localhost commit-tree "HEAD^{tree}" -p "$(git merge-base origin/main HEAD)" -m squash-preview)
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD:/repo" -w /repo $IMG git /repo --log-opts="--no-renames -1 $sq" -c /repo/.gitleaks.toml -i /repo/.gitleaksignore --redact --verbose --no-banner
# The full history of every local branch (the nightly job also scans every PR head: use a
# `git clone --mirror` of the repo to include them)
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD:/repo" -w /repo $IMG git /repo --log-opts="--all --full-history --diff-filter=uxdb --diff-merges=remerge --no-renames" -c /repo/.gitleaks.toml -i /repo/.gitleaksignore --redact --verbose --no-banner
# The whole working tree, untracked files included
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD:/repo" -w /repo $IMG dir . -c /repo/.gitleaks.toml -i /repo/.gitleaksignore --redact --verbose --no-banner
```

Look for `ERR` lines too: gitleaks exits 0 when git fails. Run from a normal clone: in a `git worktree`, `.git` is a file pointing outside the mount, so the
`git` form needs the main repo's `.git` mounted at the same path (the `dir` form works anywhere).

False positive: prefer a narrow allowlist entry in `.gitleaks.toml` (a placeholder regex or a
path) for a class of values; add the printed fingerprint to `.gitleaksignore` (with a comment) for
one finding. A real secret is never ignored: drop it from the branch and rotate it.

## Rules

- `terraform plan` before every apply; destructive changes need explicit human confirmation.
- ECR images: both repositories are IMMUTABLE (AA-869). The `:latest` in the Terraform task definitions is a
  placeholder only (services ignore `task_definition`); every Deploy Dev registers a revision pinned to the
  git-SHA tag (`dev-<sha>` for CIS). Never push or deploy `:latest`.
- Never start/stop the environment (ECS desired count, RDS, NAT) without Nghiệp asking.
- Container access through SSM (`aws ecs execute-command`), never SSH.
