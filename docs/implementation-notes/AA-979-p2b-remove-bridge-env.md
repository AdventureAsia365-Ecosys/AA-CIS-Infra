# AA-979 P2b §4.4: drop the EXTERNAL cis-portal bridge env from the CRM API task

Session S254, agent Claude Code. Branch `feat/aa-979-remove-cis-portal-bridge-env`. Runbook: root
`docs/audits/2026-10-26-S252-aa979-p2b/RUNBOOK.md` §4.4. App half: AA-Partner `feat/aa-979-remove-cis-portal-bridge`.

## Decisions

- `crm_identity_env` (`crm_app.tf`) no longer passes `COGNITO_EXTERNAL_ISSUER` / `COGNITO_CIS_PORTAL_CLIENT_ID`. The
  EXTERNAL pool, its `cis-portal` client and that client's callback URLs on the partner host stay: the pool serves
  TripPlanner / Booking travellers, and the callback list is P2b clean-up material (design §4.5), not this change.
- `crm_partner_signin_enabled` stays as a variable; its description now says `false` is no longer a working rollback
  (the API would refuse the web's cis-portal tokens). Review follow-up: its default is now `true` and a `validation`
  block refuses `false`, so a root or workspace that leaves out the tfvars line cannot point the CRM web at the
  cis-portal client by accident. Dev's `terraform.tfvars` already sets `true`, so the plan is unchanged by this.

## Changed

- `accounts/aa365/crm_app.tf`: two env entries removed, comment updated.
- `accounts/aa365/crm_web.tf`: `crm_partner_signin_enabled` description, default `true`, validation refusing `false`.
- `CONTEXT.md`: the crm_web / identity_partner line.

## Tradeoffs

- Keeping the toggle (instead of deleting the cis-portal branch of `crm_web.tf`) keeps this PR to the env lines the
  runbook names; removing the toggle belongs with the cis-portal callback clean-up.

## Should know

- **Order: AA-Partner first.** Apply this only after the AA-Partner bridge removal is deployed (that code ignores the two
  env names; the old code would still start without them, but the bridge must be gone in code first).
- Plan: 1 to change or replace on `aws_ecs_task_definition` of the CRM API (new revision, `bootstrap` image); the
  service ignores `task_definition`. The next AA-Partner Deploy Dev copies the latest revision, so run it (or dispatch
  it) after apply, then compare the env names of the running revision with the new one (S250 lesson) and check that
  the two names are gone.
- Live: a `cis-portal` token on `/crm/v1/memberships` -> 401 (already true once the Partner code is deployed).
- Follow-up: `tools/identity/crm_dev_identity.py` still defaults to `--pool external`.
