# AA-1185 lane l9-sweep2 (S296): default execute-api endpoints off, docs lint in error mode, test-site exception gone

Follow-up of the S295 sweep (`AA-1185.md`), from the S296 live check of the Done-when items.

## Decisions

- **One root switch, `api_default_endpoints_disabled` (default true)** in `custom_domains_variables.tf`, passed to
  `modules/api_gateway` (CIS REST API) and `modules/environment` (Booking REST API, TripPlanner HTTP API). Booking and
  TripPlanner get `api_default_endpoints_disabled && custom_domains_enabled`: their custom domains exist only with
  `custom_domains_enabled`, so turning that off never leaves them unreachable. The CIS custom domain is not gated.
  Rollback = set the variable to false and apply (no code revert).
- **REST redeploy through the existing trigger hashes.** API Gateway applies `disableExecuteApiEndpoint` to a REST API
  only when a stage is updated (AWS docs "Disable the default endpoint for REST APIs"). The flag joins the
  `redeployment` trigger of `aws_api_gateway_deployment.this` (CIS) and `.booking`: the apply creates a new deployment
  (create_before_destroy) and moves the stage to it, the same path every route change already takes (AA-432 trap).
- **TripPlanner needs no redeployment**: its `$default` stage has `auto_deploy = true`, which applies an API setting
  change by itself (AWS docs "Disable the default endpoint for HTTP APIs"). A test pins `auto_deploy = true`.
- **Base URL outputs** (`booking_api_base_url`, `tripplanner_api_base_url`) return the custom domain while the endpoint
  is off; no Terraform consumer reads them (grep), the root generated inventory shows them.
- **AWS Health from us-east-1 (item 4)**: already in place. `aa-sec-dev-global-forward` gained
  `{ source = ["aws.health"], "detail-type" = ["AWS Health Event"] }` in the S295 sweep (#1047), and the live rule
  pattern in us-east-1 carries that branch (read-only `describe-rule` in this lane, 27/11). This lane adds only the guard: an offline test and live check cases in `sec_alert_check.py`
  (`health.*` on the root-region rule, `forward.health.*` on the global forward). Cost unchanged (0 USD; custom events
  at 1 USD per million, a handful a month).

## Changed

- `modules/api_gateway/main.tf`, `modules/environment/booking.tf`, `modules/environment/tripplanner.tf`: the setting,
  the two triggers, the two outputs. New variables in both modules (required, no default: the caller states it).
- `.github/workflows/docs-lint.yml`: resource-ID lint on pages in `--mode error` (every kind fails, as the root);
  `.claude/` agent files `--mode warn` without `--block`. 0 findings on the 16 pages it checks (journals, the onboarding
  account map and generated pages are out of scope by the tool's rules).
- `tools/docs/check_docs_text.py`: docstring only (the error/warn split), byte-identical to the root copy (same text in
  the root PR of this lane).
- `.trivyignore`: the CVE line of the WordPress sidecar removed (header kept, "no entry today"); the root register row
  goes in the root PR. `tools/terraform/tests/test_aa1060_test_wp.py` now asserts the entry is gone.
- `CONTEXT.md`: Booking routing paragraph (custom domain, not execute-api) and a short "default endpoints off" note.

## Tradeoffs

- A variable instead of a literal `true`: one line to roll back if a forgotten caller appears; the variable is a
  security switch, not a threshold, so it does not need an admin setting.
- Not changed: `modules/api_gateway/outputs.tf` `api_gateway_url` still names the default URL (unused; description
  says it answers 403). Deleting it would change the module interface for no gain.

## Should know

- Callers searched (27/11): every repo (apps, Infra, root tools and workflows), GitHub Actions variables of the six
  repos, the env of every Lambda in us-west-1 and of every live ECS task definition (8 services). No caller of a
  default endpoint remains; the only hits are journals (audits, implementation notes, exported Linear issues),
  two stale doc lines in AA-Booking (`CONTEXT.md` BOOKING_API_URL default, `docs/ui-spec.md` base URL) and the root ADR
  0004 history. CI smoke, deploy gates and post-deploy verify use `api-cis.` / `api-booking.` / the partner host.
- Expected plan (dev): `module.api_gateway.aws_api_gateway_rest_api.this` and
  `module.environment.aws_api_gateway_rest_api.booking` update in place (`disable_execute_api_endpoint`),
  `module.environment.aws_apigatewayv2_api.tripplanner` update in place, the two `aws_api_gateway_deployment`
  replaced (create before destroy), the two stages update in place (`deployment_id`). Nothing else.
- After the apply: default URLs `https://<id>.execute-api.us-west-1.amazonaws.com/dev/health` (CIS),
  `.../dev/booking/health` (Booking) answer 403, `https://<id>.execute-api.us-west-1.amazonaws.com/browse/countries`
  (TripPlanner) 404; custom domains unchanged.
