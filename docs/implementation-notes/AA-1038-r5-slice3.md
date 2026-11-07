# AA-1038 R5 slice 3 — the lead channels' infrastructure (AA-CIS-Infra part)

Session S272 (lane l11). Root ADR 0019 d11 (+ the S272 amendment), root contract `lead.submitted.v1`. The app parts
(AA-TripPlanner-Web: outbox, M2M route class, webhook / e-mail delivery, `tp_lead_deliver`; AA-Partner:
`crm_tp_lead_pull`; CIS 390: the lead route view) need this before the CRM, webhook and e-mail channels work on Dev.

## Decisions

- **M2M scope.** New resource server `tripplanner.leads` with the one scope `deliver` in the aa-m2m pool
  (`identity_m2m.tf`), added to the CRM client's `allowed_oauth_scopes` like the earlier receivers. The CRM client is
  the pool's only client (a test checks no other client of the pool exists), so the grant stays least privilege.
- **`TRIPPLANNER_API_URL` from the HTTP API resource.** `lower(trimsuffix(aws_apigatewayv2_api.tripplanner.api_endpoint,
  "/"))` in `crm_app.tf`: the module owns both the API and the CRM task, so no new input, no hand-copied host and no
  account id. The `$default` stage serves at the root, so the origin has no path (the CRM refuses to start on a value
  that is not a lower-case https origin without a path).
- **Webhook master key: generated, never in state.** `ephemeral "random_password"` -> `secret_string_wo` (the Redis
  AUTH pattern of `modules/elasticache`), name `tripplanner/<env>/lead-webhook-key` (the name the app reads,
  `LEAD_WEBHOOK_KEY_SECRET_TEMPLATE`). Rotation = bump `local.tp_lead_webhook_key_version`. Refresh still calls
  GetSecretValue, so the ARN joins `local.tf_plan_secret_arns` (plan role read list and the apply boundary's
  exception); `test_secret_read_guards` requires that.
- **Grants.** `ReadLeadWebhookKeySecret` on the browse + assembly execution role and on the jobs role, nothing else.
  SES: the assembly role already had the shared `ses_send` grant (unused since S238); the jobs role gets the same
  grant (`ses.tf tripplanner_jobs_ses_send`): `ses:SendEmail` / `SendRawEmail` only as `var.ses_from_address` (the
  AA-811 identity, the one the d20 fan-out uses). No new identity, no new paid service.
- **Lambda env.** `TP_LEAD_EMAIL_FROM = var.ses_from_address` on assembly and jobs (not browse). On assembly also
  `TP_LEAD_CRM_PULL_ENABLED = "true"` and `TP_M2M_ISSUER` / `TP_M2M_CRM_CLIENT_ID` from the pool inputs the module
  already had (Booking gets the same pair).

## Changed (vs the brief)

- Added `TP_LEAD_CRM_PULL_ENABLED` and the two `TP_M2M_*` values on the assembly Lambda (not in the brief). Reason:
  Terraform owns the Lambda environment (no `ignore_changes`), so a switch set by hand would be reverted by the next
  apply; the TripPlanner notes make the switch a prerequisite of the CRM channel, in the same apply as the scope and
  the CRM URL. The `TP_M2M_*` values equal the app's code defaults on Dev; wiring them keeps a future prod root right.
- No new variable: the switch is a literal like `REQUIRE_REGISTRATION_BEFORE_HANDOFF` (a new `tripplanner_*` setting
  would have to be declared twice and added to the AA-1004 move test's frozen list).

## Tradeoffs

- **One execution role for browse and assembly** (as since the start): the grants go on that role. Splitting it is a
  larger change (new role, both functions updated) and out of this slice; follow-up in Linear AA-1038.
- **First apply is local.** The new secret's ARN exists only after the create and feeds the apply boundary (a
  bootstrap object CI cannot edit); a CI apply would fail on the boundary update or on the version read-back. One
  local MFA-admin apply from merged `main` does it all; CI plans and applies work after it.
- `execute-api` origin rather than the `api-tripplanner.` custom domain: the custom domain lives in the account root
  behind `custom_domains_enabled`; the module-local API keeps the module self-contained. Switch later if wanted.

## Should know

- Expected plan (accounts/aa365): 4 to add (`aws_cognito_resource_server.tripplanner_leads`,
  `module.environment.aws_secretsmanager_secret.tripplanner_lead_webhook_key`, `..._version.tripplanner_lead_webhook_key`,
  `aws_iam_role_policy.tripplanner_jobs_ses_send`), in-place updates only: `aws_cognito_user_pool_client.m2m_crm`
  (scopes), `module.environment.aws_iam_role_policy.tripplanner_lambda_permissions` and `.tripplanner_jobs_permissions`,
  `module.environment.aws_lambda_function.tripplanner_assembly` and `.tripplanner_jobs` (environment),
  `aws_iam_policy.tf_apply_boundary` and `aws_iam_role_policy.tf_plan` (both bootstrap: the secret list), and
  `module.environment.aws_ecs_task_definition.crm_api` (replace: a new revision, as every container change). 0 to destroy
  apart from that task-definition revision replacement.
- After the apply the CRM's latest task-definition revision carries the `bootstrap` image (S250 lesson): the next
  AA-Partner deploy copies it with the real image. Apply before the CRM code PR deploys, or run Deploy Dev after it.
- Re-plan after the apply (S252 lesson on resource servers): "No changes" expected.
- Secrets register row (root `docs/security/secrets-register.md` + `.yaml`) is in the PR body for the root PR.
