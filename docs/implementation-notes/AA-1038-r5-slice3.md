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
- **First apply is local, never through the Terraform Apply workflow.** Two walls: the plan adds an
  `aws_secretsmanager_secret_version` (a guarded type: `tools/terraform/plan_guard.py` refuses the workflow unless
  `allow_guarded` is set), and it edits `aws_iam_policy.tf_apply_boundary` (a bootstrap object,
  `DenyBoundaryPolicyEdits`: the CI apply role gets AccessDenied). With `allow_guarded` a CI apply would stop partway
  (secret and resource server created, boundary edit denied). One local MFA-admin apply from merged `main` does it
  all; CI plans and applies work after it. See "Ship steps" below.
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
- Secrets register rows: the root PR of this lane (branch `docs/aa-1038-lead-webhook-key-register`) adds the rows
  below to root `docs/security/secrets-register.yaml` and `.md`, so the register drift check
  (`tools/secrets/register_check.py`) finds the live secret after the apply.

## Ship steps (orchestrator)

**Warning: once this PR is merged, every CI Terraform Apply of `accounts/aa365` from `main` is blocked (plan guard on
the secret version, then AccessDenied on the boundary) until step 1 is done. Do step 1 right after the merge.**

1. Right after the merge, from a clean checkout of merged `main`: init and apply `accounts/aa365` locally with the
   MFA admin profile (`aa365-admin`, credentials exported as the root CLAUDE.md says, never a bare
   `export $(...)`). Never through the Terraform Apply workflow, never with `allow_guarded`. Check the plan matches
   "Expected plan" above before confirming.
2. Re-plan with `-detailed-exitcode`: "No changes" expected (exit 0).
3. Run AA-Partner Deploy Dev so the CRM's latest task-definition revision carries the real image and
   `TRIPPLANNER_API_URL` (the apply leaves the `bootstrap` image on the new revision, S250 lesson).
4. Read-only live checks: `describe-secret` of `tripplanner/dev/lead-webhook-key` (exists, no rotation);
   `describe-resource-server` on the aa-m2m pool, identifier `tripplanner.leads` (scope `deliver`); the CRM client's
   `AllowedOAuthScopes` lists `tripplanner.leads/deliver`; `get-function-configuration` of the TP assembly and jobs
   Lambdas shows `TP_LEAD_EMAIL_FROM` (assembly also `TP_LEAD_CRM_PULL_ENABLED=true`, `TP_M2M_ISSUER`,
   `TP_M2M_CRM_CLIENT_ID`); the CRM service rollout COMPLETED with `TRIPPLANNER_API_URL` in its container env.

## Secrets register rows (root)

YAML (`docs/security/secrets-register.yaml`, after `tripplanner/dev/cognito-signup-proof-key`):

```yaml
  - name: tripplanner/dev/lead-webhook-key
    store: "secretsmanager:acc2"
    owner_app: tripplanner
    owner: nghiep
    consumers:
      - "TP assembly Lambda (inline lead delivery) and jobs Lambda (tp_lead_deliver), read by name tripplanner/<ENVIRONMENT>/lead-webhook-key (AA-TripPlanner-Web backend/assembly/leads.py)"
      - "grant ReadLeadWebhookKeySecret (AA-CIS-Infra modules/environment/tripplanner.tf, tripplanner_jobs.tf)"
      - "Terraform refresh (tf-plan / tf-apply roles, local.tf_plan_secret_arns)"
    managed_by: "terraform aws_secretsmanager_secret.tripplanner_lead_webhook_key + write-only version from ephemeral random_password (never in state)"
    rotation: "bump local.tp_lead_webhook_key_version (re-issue derived agency keys)"
    last_changed: TBD-M0
    status: keep
    notes: "AA-1038 (S272). Master key of the TripPlanner lead webhook channel; per-agency webhook signing keys are derived from it. Created by the first local apply of AA-CIS-Infra (AA-1038 R5 slice 3)."
```

MD (`docs/security/secrets-register.md`, Secrets Manager table, after the `tripplanner/dev/cognito-signup-proof-key`
row), same fields in the table's column order:

```markdown
| `tripplanner/dev/lead-webhook-key` | tripplanner | TP assembly Lambda (inline lead delivery) and jobs Lambda (tp_lead_deliver), read by name tripplanner/<ENVIRONMENT>/lead-webhook-key (AA-TripPlanner-Web backend/assembly/leads.py); grant ReadLeadWebhookKeySecret (AA-CIS-Infra modules/environment/tripplanner.tf, tripplanner_jobs.tf); Terraform refresh (tf-plan / tf-apply roles, local.tf_plan_secret_arns) | terraform aws_secretsmanager_secret.tripplanner_lead_webhook_key + write-only version from ephemeral random_password (never in state) | bump local.tp_lead_webhook_key_version (re-issue derived agency keys) | TBD-M0 | **keep** | AA-1038 (S272). Master key of the TripPlanner lead webhook channel; per-agency webhook signing keys are derived from it. Created by the first local apply of AA-CIS-Infra (AA-1038 R5 slice 3). |
```
