# AA-1036 — R3 slice 2: cut-over and retire of the Content studio service (Infra)

Root ADR 0019 d6 (one agency app) and d7 (a tenant lands on Content). AA-Partner #210 (slice 1) copied the studio into
the agency web (`web/app/(studio)`), so `portal.<zone>/portal*`, `/api/*`, `/tenant-login*`, `/terms`, `/privacy` and
`/assets/*` can be served by the web. This lane does it in two steps, one PR each.

## Decisions

- **Step A (cut-over) retargets, it does not delete.** `crm_agency_studio` and `crm_agency_studio_x` keep their
  priorities (8, 9) and conditions and forward to `module.environment.crm_web_target_group_arn`. Rollback is a one-line
  revert per rule back to `crm_portal_target_group_arn`; the old service `aa-crm-<env>-portal` keeps running during
  step A but receives no traffic. `alb_rule_order.py --source` stays green (same keys, same order, both rules still
  carry the host and the origin secret).
- **`WEB_CONTENT_HOME = "true"` is a plain env entry**, not a variable: there is one agency app now, and a rollback
  reverts this PR as a whole. It reaches the task on the next AA-Partner web deploy (the service ignores
  `task_definition`; Deploy Web Dev copies the family's latest revision, which the apply registers).
- **Step B (retire) deletes the two studio rules** instead of keeping them as copies of the default rule: after step A
  they forward to the same target group as `crm_agency_default` (priority 12), so the paths reach the web either way.
- **Step B removes** (all only used by the studio, checked with `git grep` on main): `crm_portal.tf` as a whole (ECR
  repository `aa-crm-<env>-portal` and its lifecycle policy, secret shell `crm/<env>/portal-sentry-dsn`, execution
  role + inline policy, task role + inline policy, task definition family `aa-crm-<env>-portal`, target group
  `aa-crm-<env>-portal-tg`, ECS service `aa-crm-<env>-portal`, alarm `aa-crm-<env>-portal-no-healthy-task`), the
  security group `sg-crm-portal`, the deploy-role grants on the portal repository / family / service and the
  `iam:PassRole` of its two roles (`crm_app.tf`), the variables `crm_portal_sentry_enabled` and
  `crm_portal_api_key_signin`, the module input `crm_agency_studio_rule_gate` and `crm_portal_security_group_id`, the
  outputs `crm_portal_*`, and the AA-1004 `moved` blocks of the portal resources (the state moved long ago).
- **Kept:** the CRM log group `/ecs/aa-crm-<env>` (shared with the API and the web; the studio wrote stream prefix
  `portal`, those streams expire with the group's 30-day retention), the secret `crm/<env>/web` (the web maps it; the
  studio only read its `session_secret` key), the EXTERNAL `cis-portal` Cognito client (CIS key removal is slice 3).

## Changed (vs. the lane brief)

- The brief names "log group" in the retire list: the studio never had its own log group (it logged to the shared CRM
  group), so nothing is deleted there.
- `crm_portal.tf` mapped `crm/<env>/portal-sentry-dsn` only with `crm_portal_sentry_enabled`, which was never set
  (default false, no tfvars entry): no running task maps it, so deleting the secret shell breaks nothing. The web's
  Sentry DSN is a follow-up (its own secret; the AA-Partner web reads `SENTRY_DSN` once mapped).

## Tradeoffs

- Two PRs instead of one: the cut-over can be verified live (and rolled back) while the old service still exists;
  the retire step then deletes resources nothing routes to.
- ECR `force_delete` stays false: Terraform refuses to delete a repository that still has images, so the repository
  is emptied by hand right before the apply (images are not expired by the lifecycle policy: it keeps the last 10).

## Should know

- Order: Infra A merge + apply -> AA-Partner A merge (Deploy Web Dev picks up `WEB_CONTENT_HOME`, verifies the studio
  paths on the web) -> live check -> AA-Partner B (portal/ and its workflows gone) -> empty the ECR repository -> Infra
  B merge + apply -> deregister the deploy-registered task definition revisions of the family.
- `tools/terraform/crm_edge_live_check.py --agency-direct` checks the cut-over: `/api/healthz` answers the web's
  `{"service": "aa-crm-web", "studio": "merged"}` (the old studio's `aa-partner-portal` is a named failure), `/terms`
  is the web's 308 to `/legal/partner-terms`, `/` is the 307 to `/portal/dashboard`.
- Lesson S248 (AA-933): a rule update and a target-group delete in one apply can race. Step A only updates rules;
  step B deletes the rules and the group together, and after step A no rule references the group, so there is no race
  (the ECS service referencing the group is destroyed first through its dependency).
