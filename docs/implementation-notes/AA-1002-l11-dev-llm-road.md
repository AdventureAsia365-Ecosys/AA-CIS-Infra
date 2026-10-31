# AA-1002 — lane l11 (S261): the Dev LLM road on the Anthropic API, without the key

Tech lead decision (S261): build the road now, add the key later. Script `db/scripts/aa1002_dev_anthropic_road.py`
(DB Migrate `mode=run-script`), tests `db/tests/test_aa1002_dev_anthropic_road.py` (fake connection, CI) and
`db/tests/test_aa1002_dev_anthropic_road_pg.py` (real PostgreSQL 16, local only). Runbook update: root
`docs/ops/runbooks/llm-anthropic-api-key.md` ("Dev road prepared (S261)"), separate root PR.

## Decisions

- **A run-script, not a CIS migration.** The change is Dev data (a stage policy for synthetic data, C7.1a), not
  something every environment should replay; a migration would also open tenant stages in CI and in a future prod.
  The CIS migration path stays for the prod decision (blueprint section 4).
- **The stage list is derived, not written down.** A stage is opened when its route (primary and fallbacks; the shadow is left out, S261 review)
  names an Anthropic catalog model the gateway can send to `anthropic-direct`: vendor `anthropic`, not a legacy key,
  `api_style` converse / anthropic_messages (`vendor_route._CALLABLE["anthropic"]`), catalog row enabled, an enabled
  `anthropic-direct` deployment (or one the script adds). The two code facts (legacy keys, api styles) are constants
  mirrored from `shared/llm_client/catalog.py` / `vendor_route.py`.
- **Tenant T-stages are opened too** (Dev holds synthetic data only) but printed in their own `group=tenant` lines.
  `tp_*` stages are TripPlanner's: its client reads neither scopes nor deployments until slice S8, so they are reported
  and never changed.
- **Missing deployments are added with migration 306's rule** (same wire-id regexes, priority 100, origin `seed`), only
  for models a CIS route names; priority becomes acc3's + 1 if acc3 is at 100 or more, so the row always sits behind
  Bedrock. A disabled `anthropic-direct` deployment is an admin choice: reported, not re-enabled.
- **Budget: monthly, 150 USD.** S10 enforces only `llm_provider_connection.monthly_budget_usd` on the call path; there
  is no daily per-connection budget, and the provider-wide daily caps in `shared.spend_budget` are read only by jobs
  that load a run budget for that provider (none loads `anthropic`). 5 USD/day x 30 = 150 USD/month, set only when the
  value is NULL (an admin's value is kept; 0 is reported because it means "no spend at all"). It is still editable on
  the Connections tab. The Anthropic console workspace spend limit is the second fence (tech lead step 1).
- **Dev check from the data.** The DB Migrate task has no environment variable; the gateway's own environment marker is
  the `<env>` segment of `aa-llm/<env>/<name>` secret names (CHECKs + `connections.SECRET_NAME_RE`). The script
  refuses unless `anthropic-direct` names `aa-llm/dev/anthropic-direct` and every `aa-llm/` secret / usage-secret name
  is under `aa-llm/dev/`; also without migration 311.
- **No audit_log row.** The trail is the reviewed PR, the DB Migrate run log (`SCRIPT widen` / `insert` / `budget`
  lines are also the undo list) and `updated_by = script:aa1002_dev_anthropic_road` on every written row.
- **Not READ_ONLY**, so the runner's idle check waits for the job tables like any write script.

## Changed (vs. the lane brief)

- "Daily budget" became the S10 monthly budget (see Decisions). No `spend_budget` row is written (it would not act).
- The script also names, per opened stage, any OTHER `vendor_direct` deployment the widening allows (e.g. an OpenAI
  API last resort in the same route), so the tech lead sees the full effect.

## Tradeoffs

- Deriving from live data means the dry run is the only place the final list is seen; that is why the merged MODE is
  `dry_run` and the apply is a one-line follow-up PR after the output is read.
- Widening only stages with a real API road keeps the policy narrow, at the price of a re-run after a route change.

## Should know

- **Expected on Dev (from the 29/10 route snapshot; the dry run is the authority):** only the stages whose route names
  a Converse Claude model get a road — `s1_generate` and `supply_content_writer` (both on `sonnet-5-5`). Every other
  writer / validate stage (A3 checks, T2 / T8 / T9 writers, TripPlanner) uses the legacy keys `haiku` / `sonnet`,
  which the gateway never sends to an Anthropic connection, so they print as `SCRIPT gap`. Giving them the road is a
  model choice for the tech lead: add a Converse model (e.g. `sonnet-5-5` / `haiku-5-5`) to their route in the admin
  (as the last fallback keeps today's primary), then re-run this script's apply. Judge stages route on GPT models.
- Reachability after the key: acc3 refuses at account level, its circuit opens (S4, access_denied: open at once), so
  an opened stage goes straight to the `anthropic-direct` row behind it.
- The api / worker read the new scopes and the budget within 5 minutes (stage / registry caches; budget 60 s).
- The CIS task role needs no IAM change to read `aa-llm/dev/anthropic-direct` (CONTEXT.md, Secrets section).
- Local PG test: `initdb` + `pg_ctl -o "-p 55492 -k '' -c listen_addresses=127.0.0.1"`, then
  `AA1002_TEST_PG_DSN="postgresql://postgres@127.0.0.1:55492/postgres?sslmode=disable"` (3 passed). Unit: 23 passed,
  mutation-checked (opening `tp_*` stages, dropping the legacy-key rule both fail).

## Review follow-up (orchestrator, S261)

- The shadow model no longer counts: widening a stage for its shadow alone would make its A/B shadow calls paid
  API calls while its primary route still has no road.
- A stage whose widening would also reach a vendor_direct deployment on an **enabled** connection (today
  `openai-direct`, which has a key) is **held** (`SCRIPT held`, not widened): that is paid traffic outside AWS before
  the Anthropic key exists. The tech lead decides those stages; the post-apply guard skips held stages.
- Tests: 25 (two new: shadow-only stage, held stage; one: widening when the other vendor connection is off).
