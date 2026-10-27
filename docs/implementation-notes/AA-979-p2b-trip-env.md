# AA-979 P2b §4.3: `CIS_API_URL` on the CRM web task (Infra side of the `/trip` slice)

Session S254, agent Claude Code. Branch `feat/aa-979-web-cis-api-url`. Runbook: root
`docs/audits/2026-10-26-S252-aa979-p2b/RUNBOOK.md` §4.3. App side: AA-Partner `feat/aa-979-trip-slice` (the
client-host page `web/app/trip/[tourId]`), AA-CIS-App `feat/aa-979-trip-redirect` (the admin-host 307).

## Decisions

- **One env line in `crm_web.tf`**: `CIS_API_URL = var.crm_cis_api_url`, the CIS API origin the CRM API already uses
  for the membership feed (`crm_app.tf`, validated https origin). No new variable: both CRM tasks talk to the same
  public CIS API.
- No change to `TRIP_PAGE_BASE_URL` on the CIS api task here: CIS ships with a code default (the admin host, which
  forwards with a 307), and touching `module.ecs` task definitions has its own risks (S250 lesson on template
  revisions and runtime flags). A later, separate change.

## Changed

- `accounts/aa365/crm_web.tf`: `crm_web_env` gains `CIS_API_URL`.
- `CONTEXT.md`: the `crm_web.tf` entry lists `CIS_API_URL` in the web env (review follow-up).

## Tradeoffs

- Reusing `crm_cis_api_url` couples the two CRM tasks to one CIS origin; they are the same API, so splitting it would
  only add a variable to keep in step.

## Should know

- Plan: 1 to change or replace on the web task definition (`aws_ecs_task_definition.crm_web`, new revision with the
  `bootstrap` image); the service ignores `task_definition`, so nothing rolls by itself. The next AA-Partner Deploy
  Web Dev copies the latest revision (with the env) and swaps the image. Order: apply this -> deploy the web (merge of
  the Partner trip PR, or a dispatch) -> `curl -sI https://go-dev.lumiguides.it.com/trip/<id>` 200.
- Rollback: harmless to keep; the web ignores the env without the trip page code.
