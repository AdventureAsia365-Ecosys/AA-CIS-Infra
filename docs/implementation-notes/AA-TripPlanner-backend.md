# AA-TripPlanner backend — Terraform change report

**Purpose of this doc:** AA-TripPlanner-AI is a *new, standalone B2C product*,
separate from AA-CIS. Its backend runs in the **same acc2 (005097885195)**
infrastructure, so its Terraform lives in this repo. This report states
**exactly** what was added and — just as importantly — **what was NOT touched**,
so reviewers can tell the TripPlanner surface apart from AA-CIS at a glance.

> TL;DR: All additions are new, `tripplanner*`-prefixed resources in
> **isolated files**. No existing AA-CIS resource is modified. The only edits
> to *existing* files are **two additive trust statements** on the acc3/acc1
> Bedrock invoker roles (new `Statement` elements, existing ones untouched).

---

## 1. Files added / changed

| File | Root | Change | Touches CIS resources? |
|------|------|--------|------------------------|
| `accounts/aa365/tripplanner.tf` | aa365 (acc2) | **NEW file** — all TripPlanner resources | No — only *reads* `module.vpc.*` / `module.rds` outputs |
| `accounts/aa365/tripplanner_variables.tf` | aa365 (acc2) | **NEW file** — TripPlanner-only vars | No |
| `accounts/acc3-bedrock/main.tf` | acc3-bedrock | **EDIT** — +1 trust statement on `AA3-Bedrock-Invoker` | No — adds a new `Statement` element; the CIS ECS statement is byte-for-byte unchanged |
| `accounts/acc1-bedrock/bedrock_invoker_import.tf` | acc1-bedrock | **EDIT** — +1 trust statement on `AA-Bedrock-Invoker` | No — same, additive only |

## 2. What `tripplanner.tf` creates (all NEW, all `aa-tripplanner-dev-*`)

- `aws_secretsmanager_secret.tripplanner_db` — `tripplanner/dev/database-url`.
  Placeholder value, real DSN set out-of-band (`ignore_changes`).
- `aws_iam_role.tripplanner_lambda_exec` — `aa-tripplanner-dev-lambda-exec`,
  the exec role shared by both Lambdas. VPC-access managed policy +
  an inline policy granting:
  - `secretsmanager:GetSecretValue` on the DB secret only,
  - CloudWatch Logs,
  - `bedrock:InvokeModel` on the **acc2 Cohere Embed v4** inference profile
    (direct embeddings — acc2 CAN invoke Cohere),
  - `sts:AssumeRole` on the two satellite invoker roles (Claude — acc2 CANNOT
    invoke Claude, so it assumes acc3/acc1). This mirrors
    `accounts/aa365/bedrock_satellite_assume.tf`, which grants the *ECS task
    role* the same assume — TripPlanner just needs the parallel grant on its
    own Lambda role.
- `aws_s3_bucket.tripplanner_artifacts` (+ versioning / public-access-block /
  SSE) — `aa-tripplanner-dev-lambda-artifacts-<account_id>`. Holds the Lambda
  deployment zips. **Split ownership:** Terraform seeds a 209-byte placeholder
  zip (committed at `accounts/aa365/artifacts/placeholder.zip`) so the Lambdas
  can be created on first apply; the **AA-TripPlanner-Web** repo's deploy
  workflow builds the real zips and pushes them via `lambda:UpdateFunctionCode`
  (Terraform `ignore_changes` the Lambda code attrs so it never reverts them).
- `aws_iam_role.tripplanner_app_deploy` — least-privilege GitHub OIDC role
  assumed ONLY by `repo:AdventureAsia365-Ecosys/AA-TripPlanner-Web:*` (org renamed
  from AdventureAsia365-CIS; OIDC trust accepts both during transition), allowed to
  `s3:PutObject` on the artifacts bucket + `lambda:UpdateFunctionCode` on the
  two Lambdas. Separate from the broad `aa-cis-dev-role` CI/CD role.
- `aws_lambda_function.tripplanner_browse` — `-browse`, handler
  `backend.browse.handler.handler`. Stateless read path.
- `aws_lambda_function.tripplanner_assembly` — `-assembly`, handler
  `backend.assembly.handler.handler`. Stateful; calls Bedrock.
  Two separate Lambdas is a hard product boundary (browse = cacheable read;
  assembly = per-visitor state + LLM), not merged for convenience.
- **API Gateway (HTTP API v2)** `aa-tripplanner-dev-api` in front of the two
  Lambdas (`AWS_PROXY`, payload format 2.0): `ANY /browse/{proxy+}` -> browse,
  `ANY /trip/{proxy+}` -> assembly, `$default` auto-deploy stage, + Lambda
  invoke permissions. Same "API Gateway in front of the compute" pattern as
  AA-CIS (which fronts ECS via a REST API + VPC Link) — TripPlanner fronts
  Lambda via an HTTP API. Chosen over public Lambda Function URLs because the
  org SCP blocks unauthenticated Function URLs (verified 403 AccessDenied at
  the org edge). Output: `tripplanner_api_base_url`,
  `tripplanner_lambda_exec_role_arn`.

Both Lambdas attach to the existing VPC via `module.vpc.private_subnet_ids` +
`module.vpc.sg_app_id` so they can reach the shared RDS. **No new
VPC/subnet/SG/RDS is created** — those are read-only references.

## 3. Bedrock model access — mirrors AA-CIS/ACPv2 exactly

- **Embeddings (Cohere Embed v4):** direct `bedrock:InvokeModel` on acc2. No
  satellite. acc2 can invoke Cohere.
- **Claude (compose/renarrate):** satellite assume-role, **acc3 primary /
  acc1 fallback** — same accounts and same ExternalIds AA-CIS uses:
  - acc3 role `AA3-Bedrock-Invoker`, ExternalId `aa296-satellite-bedrock-acc3`
  - acc1 role `AA-Bedrock-Invoker`, ExternalId `aa296-satellite-bedrock`
  - Note: the two roles have **different names**, so the app passes a
    per-account role name (see AA-TripPlanner-Web `bedrock_satellite.py`).

## 4. CI/CD — how each change gets applied

- `accounts/aa365/*` is covered by the **existing** workflows
  (`terraform-plan.yml` on PR to main, `terraform-apply.yml` via
  `workflow_dispatch`, both hardcode `working-directory: accounts/aa365`).
  **No workflow change was needed** — this is why the TripPlanner resources
  live inside the aa365 root rather than a new root.
- `accounts/acc3-bedrock` and `accounts/acc1-bedrock` are **separate roots**
  with their own apply process (human-run, MFA) — the aa365 workflows do NOT
  cover them. Their two additive trust statements must be applied by a human
  against each account, same as prior AA-397/AA-302 changes.

## 5. Explicitly NOT changed

- No existing AA-CIS resource (VPC/RDS/ECS/ALB/S3/secrets/Lambda) is created,
  modified, or destroyed by this change.
- No workflow file changed.
- The existing `AllowAcc2ECSTaskRoleAssume` trust statements on both invoker
  roles are unchanged (verify in the diff: only a new sibling statement is
  added).

## 6. Follow-ups (not in this change)

- Deploy flow: (1) `terraform apply` creates the Lambdas from the committed
  placeholder zip; (2) the AA-TripPlanner-Web `deploy-lambdas` workflow assumes
  `tripplanner_app_deploy` via OIDC, builds the real zips
  (`backend/package_lambdas.sh`), uploads them to the artifacts bucket, and
  runs `lambda:UpdateFunctionCode`. No build artifact ever lives in this repo.
- API Gateway auth is `NONE` at the edge for MVP dev (the BFF is the only
  caller) — add a JWT/authorizer before real use.
- CloudFront in front of the browse read routes is a later change.
