# AA-1111 — the WAF_FILTERED gateway responses converge (S295)

Source: the independent review of Infra #1041 (partner pool password policy). Its Terraform Plan (dev) showed
`2 to add, 6 to change, 2 to destroy`: both API Gateway deployments replaced, both stages redeployed and
`status_code = "403" -> null` on both `WAF_FILTERED` gateway responses, none of it from #1041.

## Decisions

- **Diagnosis: a perpetual diff, not unapplied main.** Terraform Apply Dev run 45664830207 ran on main `0d3965e5`
  (#1040, the main tip) on 25/11 17:26 UTC and succeeded (`4 added, 2 changed, 2 destroyed`). The #1041 plan then shows
  the deployments that apply created (`0vq59x`, `bkm4hp`, `created_date` 25/11 17:28) being replaced again, and the
  nightly Terraform Drift run 45851344473 (26/11) fails on `accounts/aa365` with `plan not empty (6 change(s))`.
  Read-only `aws apigateway get-gateway-response --response-type WAF_FILTERED` on both REST APIs returns
  `statusCode: "403"`, `responseParameters: {}`.
- **Two causes, both fixed.**
  1. `status_code` was left out. AWS stores the type's default (403) anyway, the provider reads it back, and the
     attribute is not computed, so every plan wants `403 -> null` and every apply puts the same 403 back. Fix: set
     `status_code = "403"` (the AWS default for `WAF_FILTERED`, so the live answer does not change).
  2. The redeployment hash read `response_parameters`, which these responses do not set. When the response is created
     its planned value is null; once read back from AWS it is `{}`, so the hash changed on the first plan after the
     apply (`1568…` -> `3e08…` for CIS, `6162…` -> `5fae…` for Booking). Fix: hash only attributes set in config
     (`status_code`, `response_templates`). The DEFAULT_4XX/5XX responses set `response_parameters`, so their hash
     stays as is.
- **No `response_parameters = {}` in config.** The existing guard asserts the WAF_FILTERED responses carry no header
  parameters at all (the WAF's own headers are the only ones); dropping the attribute from the hash is enough.

## Changed

- `modules/api_gateway/main.tf`, `modules/environment/booking.tf`: `status_code = "403"` on the WAF_FILTERED responses;
  the deployment triggers hash `status_code` + `response_templates` for them instead of `response_parameters` +
  `response_templates`.
- `tools/terraform/tests/test_aa1111_security_headers.py`: asserts the pinned 403, the hash includes `status_code` and
  does not include the unset `response_parameters`.

## Tradeoffs

- The new hash expression changes the redeployment hash once more, so the first apply after this merge replaces both
  deployments and updates both stages one last time (same routes, same answers: a no-op for callers). Converging
  without that redeploy would need `ignore_changes` on the trigger, which would hide real changes.

## Should know

- Expected plan of this PR (dev): `module.api_gateway.aws_api_gateway_deployment.this` and
  `module.environment.aws_api_gateway_deployment.booking` must be replaced (trigger hash), `aws_api_gateway_stage.dev`
  and `aws_api_gateway_stage.booking` updated in place (`deployment_id`): `2 to add, 2 to change, 2 to destroy`. The two
  gateway responses show no change (state 403 = config 403). After apply, a second plan shows none of these.
- Apply this before #1041 (partner pool password policy) so that PR's plan shows only the Cognito pool change and the
  no-op re-read of `aws_iam_role_policy.cis_ecs_task_partner_pool_read`.
- Verified offline: `terraform fmt -check`, `terraform validate` (`accounts/aa365`, `-backend=false`), plan guard tests
  (`tools/terraform/tests`, `tools/finops/tests`). No plan was run against real state from a workstation.
- After apply: `curl -s -o /dev/null -D - -H 'User-Agent:' https://api-cis.lumiguides.it.com/health` still shows one
  `strict-transport-security` line and status 403.
