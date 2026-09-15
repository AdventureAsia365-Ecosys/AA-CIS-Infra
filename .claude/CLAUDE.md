# AA-CIS-Infra — Claude Code Context

## ⚠️ RESTRUCTURE 15/09/2026 — ĐỌC TRƯỚC
- **Workspace gom lại:** repo này giờ ở `~/projects/AA-Ecosys/infra/AA-CIS-Infra` (KHÔNG còn
  `~/projects/aa-cis/AA-CIS-Infra`). Multi-repo, mỗi repo `.git` riêng.
- **Org GitHub đổi tên:** `AdventureAsia365-CIS` → **`AdventureAsia365-Ecosys`** (redirect còn
  chạy). Tên repo giữ nguyên. Remote origin đã trỏ org mới. Lệnh gh: `--repo AdventureAsia365-Ecosys/AA-CIS-Infra`.
- **OIDC transitional (đã apply 15/09/2026):** 2 role trong `accounts/aa365/` (`cicd.tf` →
  `aa-cis-dev-role`; `tripplanner.tf` → `aa-tripplanner-dev-app-deploy`) đã mở rộng `sub` nhận CẢ
  `repo:AdventureAsia365-CIS...` VÀ `repo:AdventureAsia365-Ecosys...` (apply: 0 add/4 change/0 destroy).
  `cicd.tf` dùng dạng phẳng `repo:<org>/*:*`; `tripplanner.tf` dùng `@id`-wildcard (repo
  AA-TripPlanner-Web bật "include repo ID in subject"; org KHÔNG bật — đã xác minh).
  **G5 (chờ vài ngày): gỡ tên org cũ** theo `~/projects/AA-Ecosys/docs/g5-remove-old-trust.md`.
- **CI/CD:** `configure-aws-credentials` đã nâng `@v4`→`@v6` (Node 24) trong terraform-plan/apply.yml.
- **TripPlanner** dùng chung acc2 (Lambda/API GW/S3 trong `accounts/aa365/tripplanner.tf`); repo
  AA-TripPlanner-Web owns Lambda code. Sơ đồ tổng: `~/projects/AA-Ecosys/docs/ecosystem-architecture.md`.

# Updated: 11/09/2026 (AA-587 — corrected stale account/profile, confirmed live root)

## LIVE ROOT — accounts/aa365/
The Terraform root that actually manages live infrastructure is **`accounts/aa365/`**,
NOT the repo-root `main.tf`/`versions.tf` (that root is stale — see "STALE REPO-ROOT" below).
CI workflows (`terraform-plan.yml`/`terraform-apply.yml`) already run with
`working-directory: accounts/aa365` — confirmed via `.github/workflows/*.yml`.

## LIVE STATE
- Account: **005097885195** (aa365, Acc2 — CIS DEV hạ tầng chính) | Region: us-west-1 | Profile: **aa365-admin**
- ECS cluster: aa-cis-dev-cluster | service: aa-cis-dev-api
- RDS: aa-cis-dev-db (PostgreSQL 15)
- ECR: 005097885195.dkr.ecr.us-west-1.amazonaws.com/aa-cis-dev-api
- ALB: aa-cis-dev-alb-281090825.us-west-1.elb.amazonaws.com (**internet-facing** — confirmed AA-585,
  11/09/2026; do not assume "internal ALB" means VPN/VPC-only)

## TERRAFORM BACKEND (accounts/aa365)
```
backend "s3" {
  bucket         = "aa-cis-tfstate-005097885195"
  key            = "dev/terraform.tfstate"
  region         = "us-west-1"
  dynamodb_table = "aa-cis-tfstate-lock-005097885195"
}
```
No hardcoded profile in the backend block — CI (GitHub Actions OIDC) uses ambient credentials.
Local runs: `export AWS_PROFILE=aa365-admin` before `terraform` commands, always from
`accounts/aa365/` (never the repo root).
Always: `terraform plan` before `apply`.

## STALE REPO-ROOT — main.tf / versions.tf / variables.tf / outputs.tf (KHÔNG DÙNG)
The repo-root Terraform files point at S3 state bucket `aa-cis-tfstate-867490540162`, which
**no longer exists** (`NoSuchBucket`, confirmed via `aws s3api head-bucket`, AA-587 11/09/2026) —
it belonged to account 1 (867490540162)'s old, since-destroyed infrastructure (AA-271 cutover).
This root also hardcodes account-1 ARNs throughout (bronze/gold bucket names, ALB ARN, WAF ARN,
ACM cert ARN, ECS task-def ARN, old ALB DNS `...-1114303360...`) — none of it reflects live
infra. No CI workflow, script, or Makefile references it (confirmed via repo-wide grep, AA-587).
Kept as historical reference only (predates the AA-246/AA-271 account-2 cutover) — **do not run
`terraform` from the repo root, do not treat anything in it as live config**. See
`docs/implementation-notes/AA-587.md` for the full investigation.

## ⚠️ Old tech-debt note (AA-22) — DOES NOT APPLY to accounts/aa365
The repo-root's hardcoded `api_task_def_arn` (revision `:21`) was AA-22's known tech debt.
`accounts/aa365/main.tf` already resolves this dynamically
(`arn:aws:ecs:${var.aws_region}:${var.account_id}:task-definition/${local.name_prefix}-api`) —
confirmed AA-587, 11/09/2026. Not an open issue on the live root.

## RESOURCE NAMING
Pattern: aa-cis-{env}-{resource}
Examples: aa-cis-dev-api, aa-cis-dev-db, aa-cis-dev-cluster, aa-cis-dev-redis

## ECR — ALWAYS :latest
NEVER use commit hash as image tag in task definitions.
Always use :latest so ECS pulls correct image after CI push.

## SECRETS (Secrets Manager)
aa-cis/dev/rds          → plain DSN string (postgresql://user:pwd@host/db)
aa-cis/dev/anthropic-key → Anthropic API key (legacy — migrate to Bedrock)
aa-cis/dev/dataforseo   → DataForSEO credentials
aa-cis/dev/admin-secret → Admin panel secret

## COST TARGETS
Phase 1: ~$73-100/month
ECS: REMIND user to stop desired=0 after session — do NOT auto-execute
RDS: REMIND user to stop instance after session — do NOT auto-execute
Lambda: on-demand (no cost when idle)

## WAF IAM — CHICKEN-AND-EGG PATTERN
WAFReadPolicy must be granted manually via CLI BEFORE running Terraform on first deploy.
`accounts/aa365/cicd.tf`'s WAFv2Manage statement — do not remove.
Pattern: grant WAF read manually → terraform apply → policy self-manages thereafter.

## LAMBDA STATE
- aa-cis-dev-acp-s3-campaign-planner: DEPLOYED ✅ (AA-45)
- aa-cis-dev-acp-s4-evaluate: DEPLOYED ✅ (AA-49)
- aa-cis-dev-acp-s4-trigger: DEPLOYED ✅

## OTHER TERRAFORM ROOTS IN THIS REPO (separate, unrelated — do not confuse with the above)
- `accounts/acc1-bedrock/` — account **867490540162** (Acc1), profile `pqnghiep-admin` IS
  correct here. Deliberately kept alive for the Bedrock LLM satellite FALLBACK pattern (AA-296),
  NOT for CIS's main app infra. State bucket `aa-cis-tfstate-acc1-bedrock-867490540162`.
- `accounts/acc3-bedrock/` — account **786888028788** (Acc3), profile `nghiep_aa365`. Bedrock
  satellite CHÍNH. State bucket `aa-cis-tfstate-acc3-bedrock-786888028788`.
- `envs/dev`, `envs/prod`, `envs/staging/` — `.tf` files present but empty (0 bytes); no
  backend config, not active roots. Not investigated further under AA-587 (out of scope), flagged
  here so a future session doesn't mistake them for something live either.

## SSM ONLY
Never use SSH. All container access via:
aws ecs execute-command --cluster aa-cis-dev-cluster --task {TASK_ARN} --container api --interactive --command "/bin/bash" --profile aa365-admin --region us-west-1
