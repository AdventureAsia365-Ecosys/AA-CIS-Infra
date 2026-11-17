# AA-1111: provider account guards on the aa365 and acc3 roots (lane l3 of S283)

Scope item "`allowed_account_ids` on the aa365 and acc3 Terraform roots" of AA-1111 (S282 audit, R34). The other
AA-1111 items (workforce admin second factor, access review, ZAP baseline, fork-PR setting) are not in this PR.

## Decisions

- **aa365 guards with the existing `var.account_id`.** Every ARN of the root is already built from it and the plan,
  apply and drift workflows read it from the tracked `terraform.tfvars`, so the guard adds no account ID to this
  public repo and needs no new CI secret or `TF_VAR_*`. A separate, untracked variable would duplicate the value and
  turn a missing secret into a red required check for no extra safety: the risk the guard closes is wrong
  *credentials* (AA-517: a `default` profile that pointed at acc1), not a wrong variable.
- **All four aa365 providers** (default, `us_east_1`, `us_east_2`, `us_west_2`) get the guard: the aliased ones write
  real resources (ACM certificate, EventBridge forward rules).
- **`account_id` gets a 12-digit validation** on aa365 (acc1 and acc3 have one). Validation is not in the plan
  output, so it changes nothing applied.
- **acc3 copies the acc1 pattern** (`accounts/acc1-bedrock/versions.tf`): no bucket and no profile in the backend
  block (both through `-backend-config` at init), `account_id` and `aws_profile` as required variables from an
  untracked `terraform.tfvars`, `allowed_account_ids = [var.account_id]` on the provider. The bucket keeps its name;
  only where the name comes from changes, so no state moves.
- **A repo-wide test** (`tools/terraform/tests/test_aa1111_account_guards.py`) holds every `provider "aws"` block in
  `accounts/*/*.tf` to `allowed_account_ids = [var.<name>]`, so a new root or a new aliased provider cannot skip it.

## Changed

- `accounts/aa365/versions.tf`, `accounts/aa365/variables.tf`, `accounts/acc3-bedrock/versions.tf`,
  `accounts/acc3-bedrock/cost_anomaly_immediate.tf` (comment only), `README.md` (acc3 row), `CONTEXT.md` (state
  backend notes).
- The acc3 ARN literals in `main.tf` / `batch.tf` / `cost_explorer_reader.tf` still name acc3's ID (public since
  AA-397). Rewriting them through `var.account_id` is a plan-neutral follow-up, left out to keep this PR to the guard.

## Tradeoffs

- The aa365 guard compares against a value that lives in the same repo as the root. That is enough for its purpose
  (credentials of the wrong account stop the run before any call) and costs nothing in CI.
- acc3 now needs one `init -reconfigure` with `-backend-config` on a checkout initialised before this change, and an
  untracked `terraform.tfvars`. Same one-time cost the acc1 root has.

## Should know

- **CI/workflow env:** nothing new. The aa365 value comes from `accounts/aa365/terraform.tfvars` (auto-loaded by
  `terraform-plan.yml`, `terraform-apply.yml`, `terraform-drift.yml`). acc3 is not planned in CI (a human applies it
  locally); its two variables come from the untracked `accounts/acc3-bedrock/terraform.tfvars`.
- Expected plans: aa365 and acc3 both `0 to add, 0 to change, 0 to destroy` (a provider argument and a variable
  validation produce no resource diff).
- acc3 local steps before its plan (one-line commands, WSL2; P = acc3 profile of the root account map):
  `A=$(aws sts get-caller-identity --profile $P --query Account --output text)`, then
  `printf 'account_id  = "%s"\naws_profile = "%s"\n' "$A" "$P" > accounts/acc3-bedrock/terraform.tfvars`, then
  `terraform -chdir=accounts/acc3-bedrock init -reconfigure -backend-config="bucket=aa-cis-tfstate-acc3-bedrock-$A" -backend-config="profile=$P"`.
