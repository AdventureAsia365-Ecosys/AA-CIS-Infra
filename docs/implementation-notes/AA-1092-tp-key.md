# AA-1092 — the TripPlanner tenant assertion key (Infra part)

S278 system audit M19. App part: AA-TripPlanner-Web `docs/implementation-notes/AA-1092.md`.

## Decisions

- **Secret shell, filled by a tool.** `tripplanner/<env>/tenant-assertion-key` has no `secret_version`: Terraform and
  the plan role never read the key, and its ARN stays off `local.tf_plan_secret_arns` (no bootstrap edit of the apply
  boundary). `tools/identity/tripplanner_assertion_key.py` fills it (DRY RUN unless `--apply`, account guard, never
  prints a value) and rotates it (`--rotate`, previous kept for `--grace-hours`, at most 7 days).
- **Shape:** JSON `{current, previous, previous_until, edge_derived_until}`, epoch seconds. The first fill writes
  `current` and `edge_derived_until = now + 24 h`, so the web task that still signs with the pre-AA-1092 key keeps
  working until its deploy picks up the new mapping.
- **Readers:** the browse + assembly execution role (one role, both Lambdas verify assertions); the web execution role
  (task env `TP_TENANT_ASSERTION_KEY` = the JSON field `current` only). Not the jobs role. The CIS task role is denied
  `tripplanner/*` already.
- **No gate variable.** The web service ignores `task_definition`; the new revision is used only by the next
  TripPlanner web deploy, which the rollout runs after the fill.

## Changed

- `modules/environment/tripplanner.tf`: the secret shell; statement `ReadTenantAssertionKeySecret` on the Lambda role.
- `modules/environment/tripplanner_web.tf`: the `TP_TENANT_ASSERTION_KEY` mapping; the ARN on the execution role list.
- `tools/identity/tripplanner_assertion_key.py` + `tools/identity/tests/test_tripplanner_assertion_key.py`.
- `tools/terraform/tests/test_aa1092_tenant_assertion_key.py` (shell only, readers, mapping).

## Tradeoffs

- A tool-filled JSON instead of a write-only `random_password` version (the lead webhook key pattern): rotation needs
  the old value kept as `previous` for a grace window, which a write-only Terraform value cannot compose.

## Should know

- Local plan (read-only, `-lock=false`, S278): 2 to add (the secret, the web task revision), 2 policy updates, the
  task definition replaced (new revision). The identity trigger and SES receipt rule updates in a local plan are the
  local archive hash, not this change.
- Order (review round 2: the Lambdas must know the key before any web task signs with it):
  1. AA-TripPlanner-Web **backend PR** merged and Deploy Lambdas + Post-deploy verify green (the Lambdas read the
     secret; while it is a shell they keep the pre-AA-1092 edge-derived key, so this step is safe on its own).
  2. CI Terraform Apply of this PR (shell, grants, web task mapping).
  3. `tripplanner_assertion_key.py --apply` (MFA admin). The output carries `deploy_not_before` = write + 10 minutes.
  4. Wait until `deploy_not_before` (`LAMBDA_SECRET_CACHE_S`, the Lambdas' secret cache `API_KEY_CACHE_SECONDS`).
  5. AA-TripPlanner-Web **web PR** merged; Deploy Web Dev copies the revision that maps `TP_TENANT_ASSERTION_KEY`.
  A web deploy before the fill fails to start its task (circuit breaker rolls back), so no other TripPlanner web
  deploy should run between steps 2 and 3. A web task that signs with the new key while a warm Lambda still holds
  the shell would get 401 until that Lambda's cache expires; the Lambdas re-read the secret once on a signature miss
  (throttled to one read per 30 s per container), but the wait in step 4 is the rule.
- Rotation: `--rotate --apply`, wait until `deploy_not_before` (10 minutes), then force a new deployment of
  `aa-tripplanner-<env>-web` before `grace_until`.
- Cost: one secret, 0.40 USD per month (estimate, list price); Lambda reads cached 10 minutes.
