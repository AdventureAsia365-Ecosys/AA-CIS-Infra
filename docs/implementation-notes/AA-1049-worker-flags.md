# AA-1049 — W3 worker switches in Terraform (T2 linear orchestrator, T9 SEO builder)

Lane: worker flags (S275). The CIS code ships both switches default off; this change turns them on for the Dev
worker after the trials the tech lead asked for (decision: trial-then-on for both).

## Decisions

- **Nullable variables, no env while null.** `t2_orchestrator` (linear | graph) and `t9_seo_builder` (on | off) in
  `modules/ecs/variables.tf`, `default = null`, same pattern as `tripplanner_revalidate_url`: a module call that does
  not set them renders the task definitions exactly as before. Not the `t9_faq_llm_filter` pattern, which defaults to
  `off` and always writes the env.
- **Validation as a conditional** (`var.x == null ? true : contains([...], var.x)`), not `||` with `coalesce`: an
  empty string would pass `coalesce` (it skips "") and write an empty env value. Checked with `terraform plan` on a
  scratch config: null, linear/graph, on/off pass; "", "on" for t2, "linear" for t9 and "Linear" are refused.
- **Worker only.** Both writers run as jobs on the worker (`services/jobs/t2_rewrite_job.py`, the T9 blog write), so
  one local `aa1049_w3_env` goes into the worker container's environment only. The api task definition has neither.
- **Live root:** `accounts/aa365/main.tf` sets `t2_orchestrator = "linear"`, `t9_seo_builder = "on"`. The ecs module
  is instantiated only there (`modules/environment` does not call it), so there is no second call site.
- **`T9_REGRESSION_GUARD_MODE` stays unset** (tech lead: keep off); the test asserts it appears nowhere.

## Changed

- `modules/ecs/variables.tf`: two variables.
- `modules/ecs/main.tf`: local `aa1049_w3_env` + worker environment list.
- `accounts/aa365/main.tf`: both values on, with the trial evidence and the rollback in a comment.
- `tools/terraform/tests/test_aa1049_worker_flags.py`: offline structure test (runs in Terraform Plan Guard Tests).

## Tradeoffs

- `graph` / `off` are accepted besides null so a rollback can be explicit; null is the cleaner rollback (no env).
- The linear path also needs `T2_INTERIM` not off (app default on); nothing in Terraform sets `T2_INTERIM`, so no
  change is needed for it.

## Should know

- The task definition change reaches the running worker only through a new revision: Terraform apply registers the
  template revision; CIS deploy-dev copies the latest revision, so the env also survives the next app deploy.
- Rollback: set both to null (or "graph" / "off"), apply, then CIS deploy-dev.
