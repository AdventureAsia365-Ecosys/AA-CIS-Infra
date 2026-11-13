# AA-1096 lane L6 (S279, l28): the Infra threshold clean-up

Root audit `docs/audits/2026-11-13-S279-session/thresholds-audit/` (row L6 of section 6, section 4 "edge resources").

## Decisions

- **Env vars of settings leave Terraform now, the code override stays.** Each app's settings reader (CIS
  `shared/settings/reader.py`, AA-Partner `app/platform_settings/reader.py`) serves a definition's `env_override` env
  var FIRST. While Terraform sets that env var, the admin page's value is never served (CIS shows the
  "overridden by env" badge; AA-Partner refuses an agency value with 409 `env_override_active`). "Env vars stay for one
  release as an emergency override" (tech lead S279) is read as: the app keeps honouring the env var for one release,
  so an operator can still set it by hand in an emergency; Terraform no longer sets it. Every value removed equals the
  seeded setting default, so the effective value does not change on the apply.
- Checked on each app's origin/main before dropping (13/11/2026):
  - CIS `T7_BLOG_MIN_SEED_WORDS` (worker): not read any more (`services/acp_shared/blog_seed.py`; setting
    `cis.t7.blog_min_seed_words` seeded 600, CIS 407, no env override). Variable `t7_blog_min_seed_words` removed.
  - CIS `T2_JUDGE_GATE`, `T3_BACKGROUND_FACTS` (worker): not read any more (`judge_node.py`, `t2_repair.py`; settings
    `cis.quality_modes.t2_judge_gate` = brand_fit and `.t3_background_facts` = on, CIS 412). CIS 412 says lane L6
    removes them. `T2_JUDGE_ANCHORS` is still an env switch of the app (`judge_node.py` reads it): kept.
  - CIS `ERASURE_TENANT_RETENTION_DAYS` (api + worker): still an env override of `cis.erasure.tenant_retention_days`
    (seed 30). Now emitted only when the variable is set: the root sets 0 only while `local.erasure_drill` is on, so
    the drill keeps working and the setting is served otherwise. The variable becomes nullable, default null.
  - CRM `RATE_LIMIT_PUBLIC_PER_MINUTE` (60), `RATE_LIMIT_INTAKE_PER_MINUTE` (5), `CRM_LLM_MAX_TOKENS` (800): env
    overrides of `crm.rate.public_per_minute`, `crm.rate.intake_per_minute`, `crm.ai.draft_reply_max_tokens`
    (crm-064 seeds 60 / 5 / 800); the limiters (`app/main.py`) and the gateway (`app/llm/gateway.py`) read the
    settings. Infra #820 already dropped `RATE_LIMIT_INTAKE_FORM_PER_HOUR`; not redone.
  - TripPlanner `TP_DAILY_SPEND_CAP_USD` (browse + assembly) and `REQUIRE_REGISTRATION_BEFORE_HANDOFF` (assembly):
    fallback only (`backend/shared/settings.py`, `backend/shared/app_profile.py`): the view
    `catalog.v_app_settings_v1` and the app profile (`default_daily_budget_usd` = 5.0 since CIS 414) win; the fallback
    without the env var is the code default (5.0 / true), the same values. Variable `tripplanner_daily_spend_cap_usd`
    removed from the root and the environment module.
  - Booking bk-056: Terraform sets none of its settings (no env var of `booking.pricing_policy` on the task). Nothing
    to remove.
  - Kept on purpose (audit section 4 / tech lead Q7): `ERASURE_APPLY_ENABLED`, `SEGMENT_GC_MODE`, the CRM dry-run
    floors (`JOB_RETENTION_DRY_RUN`, `LIFECYCLE_DRY_RUN`, `AUDIT_RETENTION_DRY_RUN`, `PARTNER_ACCOUNT_CLEANUP_DRY_RUN`),
    `RATE_LIMIT_XFF_HOPS` (network topology), the writer switches (no setting yet; lane L2 owns them).
- **Literals become variables, same values:** root `waf_rate_limit` (1000), `cis_api_*_throttle_*` (50/100, 20/40,
  300/600), root + module `booking_throttle_rate_limit` / `_burst_limit` (20/40), root + module `crm_slo` (2 %, 20
  requests, 1.5 s, 3 periods, 2 breaching). The WAF rule keeps its name `RateLimit1000` (a rename rewrites the ACL and
  its metric name; nothing gains from it).
- **Dead config removed:** the four API Gateway usage plans (starter, growth, business, internal; no API key, no
  method with `api_key_required`, no reader in any of the five app repos or the root repo) and `SF_BATCH_THRESHOLD`
  (no reader in any repo; the CIS README already calls it unused) with its module variable.
- **Read-only view:** root output `platform_limits` (edge, budget and alarm values; numbers, country codes and
  booleans only, no ID or ARN). `tools/docs/gen_docs.py` renders it as the section "Edge, budget and alarm limits" of
  the generated `alarms.md` (OPS-07). That page is staff tier on the CIS admin `/admin/docs` reader (the inventory
  page ARCH-03 is owner only), so an administrator reads the values through the existing docs-gen -> root PR -> Docs
  sync -> `/admin/docs` path. A Platform > Infra page in the CIS admin does not exist and would need new plumbing (an
  API that reads the output): follow-up.
- **acc1 guard: unchanged.** No decision recorded for this lane; the acc1 alert-only budget is lane L10's
  (`accounts/acc1-bedrock/cost_guard.tf`).

## Changed

- `modules/ecs/main.tf`, `modules/ecs/variables.tf`, `accounts/aa365/main.tf`: env removals, erasure env optional,
  `sf_batch_threshold` and `t7_blog_min_seed_words` gone, WAF and CIS API Gateway values from variables.
- `accounts/aa365/variables.tf`: `waf_rate_limit`, `cis_api_*_throttle_*`.
- `modules/environment/crm_app.tf`, `crm_llm.tf`, `crm_slo.tf`, `crm_inputs.tf`; `booking.tf`, `booking_variables.tf`;
  `tripplanner.tf`, `tripplanner_variables.tf`; `accounts/aa365/crm_variables.tf`, `booking_variables.tf`,
  `tripplanner_variables.tf`, `environment.tf`.
- `modules/api_gateway/main.tf`: usage plans removed.
- `accounts/aa365/outputs_platform_limits.tf`: the output. `tools/docs/gen_docs.py`: the alarms page section.
- Tests: `tools/terraform/tests/test_aa1096_l6_infra_cleanup.py` (new), `test_aa1081_blog_min_seed.py` (now asserts
  the env is gone), `test_aa1027_crm_llm.py`, `test_aa1096_crm_intake_form_env.py`, `test_aa1004_environment_moves.py`,
  `tools/docs/tests/test_gen_docs.py`.

## Tradeoffs

- Dropping the env vars now instead of "after one release": while Terraform sets them the admin page cannot change
  the value at all, which is the gap the issue closes. The code override stays, so the emergency path is unchanged
  (set the env var on the task by hand or in a Terraform PR).
- Individual number variables (like the TripPlanner throttles) instead of one object for the CIS throttles: a tfvars
  override of one value does not have to restate the others. `crm_slo` is one object because its five numbers are one
  SLO definition kept in step with AA-Partner `docs/operations/slo.md`.
- The view rides on `alarms.md` instead of a new generated page: a new page needs a new catalog id in the root
  `docs/README.md`; the alarm page is already the monitoring catalog and staff tier.

## Should know

- The CIS and CRM task-definition changes register new revisions; the services ignore `task_definition`, so they
  reach the running tasks on the next CIS Deploy Dev / AA-Partner Deploy Dev (each copies the family's latest
  revision). After the apply, diff the env names of the newest revision against the running one (lesson S250): the
  only differences must be the removed names.
- The TripPlanner Lambda env changes apply in place (UpdateFunctionConfiguration), no new version of the code.
- The four usage plans are destroyed; the apply role holds `apigateway:DELETE` (`cicd.tf` APIGatewayManage).
