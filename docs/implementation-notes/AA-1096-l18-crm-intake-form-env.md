# AA-1096 lane L4 (S279, review fix): the CRM per-form quota env var leaves the task definition

## Decisions

- Remove `RATE_LIMIT_INTAKE_FORM_PER_HOUR` (200) from the `crm_api` task definition now instead of in lane L6. The CRM
  reads it as an emergency override of the admin-editable setting `crm.rate.intake_form_per_hour` (AA-Partner crm-064),
  and an override in force wins over every agency's own value, so a per-agency quota would have been approved and
  done nothing. The setting's seed and the app's code default are both 200, so the effective value does not change.
- The other env vars of settings (`RATE_LIMIT_PUBLIC_PER_MINUTE`, `RATE_LIMIT_INTAKE_PER_MINUTE`, `CRM_LLM_MAX_TOKENS`)
  stay until lane L6: their settings are platform-only, so the override hides no agency value.

## Changed

- `modules/environment/crm_app.tf` (one env entry and its comment), `tools/terraform/tests/test_aa1096_crm_intake_form_env.py`.

## Tradeoffs

- One Terraform apply for one env var. The alternative (keep it until L6) left the per-agency quota inert for a release;
  the AA-Partner service refuses an agency value while the override is in force (409 `env_override_active`), so the
  order of the two PRs is safe either way.

## Should know

- The service ignores task-definition changes (`ignore_changes`); the next AA-Partner deploy copies the family's latest
  revision, so the change reaches the running task on the deploy after the apply.
