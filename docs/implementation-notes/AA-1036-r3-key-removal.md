# AA-1036 R3 slice 3 — no tenant API keys (AA-CIS-Infra part)

Root ADR 0019 d6. The caller inventory and the CIS side: AA-CIS-App `docs/implementation-notes/AA-1036-r3-key-removal.md`.

## Decisions

- **The Lambda authorizer is already gone.** AA-750 removed the tenant-key TOKEN authorizer and its Lambda from
  Terraform (`modules/api_gateway/main.tf` header); no `aws_api_gateway_authorizer` / authorizer `aws_lambda_function`
  exists in any root. Only its source code was left in AA-CIS-App (`api/lambda_authorizer/`), removed by the CIS PR.
  So this PR's plan has **no destroy**.
- **The CIS task role loses the S237 grant** on `aa-cis/dev/e2e-tenant/*` (DescribeSecret + PutSecretValue): the
  only writer, CIS `services/acp_shared/e2e_tenant_key_sync.py`, is deleted. Plan: one in-place update of the CIS
  task role's inline policy (`module.ecs...aws_iam_role_policy` of the task role), nothing else.
- **The `/auth/tenant-login` API Gateway resource stays** (AA-876 `login_paths`). CIS answers 410 for any body; the
  resource keeps an old caller on that answer under the tight login throttle. Removing it would move the path onto
  `{auth_proxy+}` (same 410) and churn the deployment for nothing.

## Changed

- `modules/ecs/main.tf`: the `aa-cis/dev/e2e-tenant/*` statement removed (comment left in its place).
- `modules/api_gateway/main.tf`: comment on why the tenant-login resource stays.

## Tradeoffs

- The four secrets `aa-cis/dev/e2e-tenant/{atlas-hearth,terra-family,trail-pulse,wildkind-travel}` are not managed by
  Terraform (hand-made, S237); their deletion is a live step after the CIS deploy (root secrets register marks them
  orphan-delete), not a Terraform destroy.

## Should know

- Apply after the CIS code PR is deployed (the old CIS image would log a sync failure on a key rotation without the
  grant; harmless, but the order keeps the logs clean).
- Expected plan: `~ update in-place` of the CIS task role policy only; `0 to add, 1 to change, 0 to destroy`.
