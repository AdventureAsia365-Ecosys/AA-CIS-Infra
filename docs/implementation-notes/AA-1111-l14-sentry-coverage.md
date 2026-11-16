# AA-1111 — lane l14 Sentry coverage: AA-Partner API and web (Infra)

S282 observability hygiene. The AA-Partner API (with its in-process crm.job worker) and the AA-Partner web send no
event to Sentry today. Both apps already initialise the SDK when `SENTRY_DSN` is set; the gap is here: the API flag
`crm_sentry_enabled` was never turned on (its secret shell `crm/dev/sentry-dsn` has no value), and the web task maps
no `SENTRY_DSN` at all (the studio's old route was retired with the studio in AA-1036).

Two PRs:

1. `feat/aa-1111-crm-web-sentry-dsn` (this file): the web flag, the tool command that writes its key, tests, runbook.
   Default off, so the apply after merge changes nothing live.
2. `chore/aa-1111-enable-crm-sentry-dev`: `crm_sentry_enabled = true` and `crm_web_sentry_enabled = true` in
   `accounts/aa365/terraform.tfvars`. Apply only after the orchestrator has written both DSN values.

## Decisions

- The web's server DSN is a new key `sentry_dsn` of the existing JSON secret `crm/<env>/web`, not a new secret
  shell. The execution role already reads that secret, so there is no IAM change, no new resource and no cost; the
  TripPlanner web uses the same shape (`tripplanner/<env>/web:sentry_dsn`).
- `crm_web_sentry_enabled` (default `false`) mirrors `crm_sentry_enabled`: the `SENTRY_DSN` entry is appended to the
  task's `secrets` only while the flag is on, because ECS refuses to start a task whose secret lacks a mapped key.
- `crm_dev_identity.py web-sentry-dsn [--sentry-dsn DSN] [--apply]` writes the key the same way the other
  `crm/<env>/web` commands do: DRY RUN by default, every other key kept, value never printed, `https://` only (or
  `''` = off). Without `--sentry-dsn` it reports on/off, so the orchestrator can check the key without reading it.
- No `SENTRY_ENVIRONMENT` mapping: AA-Partner `web/instrumentation.ts` uses `ENVIRONMENT`, which the task already has.

## Changed

- The task brief named the key and the flag; nothing else was asked. The tool command and the README runbook were
  added so the orchestrator has a no-print way to write the key (the brief said the orchestrator writes it).
- The secret's Terraform `description` is left unchanged on purpose (an edit would plan an in-place update for a
  doc-only change); the file header lists the new key.

## Tradeoffs

- One JSON secret for every web value versus a separate `crm/<env>/web-sentry-dsn` shell: the JSON key needs no IAM
  edit and no new $0.40/month secret; the cost is that the key must be written before the flag is applied.
- The enable step is a separate PR so that a merge of the code PR can never start a task that lacks the key.

## Should know

- Order (README "Runbook: Sentry for the AA-Partner API and web"): Sentry projects + keys -> API DSN into
  `crm/dev/sentry-dsn` -> `web-sentry-dsn --apply` -> `WEB_PUBLIC_SENTRY_DSN` GitHub variable -> merge the tfvars PR
  -> Terraform Apply -> AA-Partner Deploy Dev and Deploy Web Dev.
- The services ignore `task_definition`, so the apply restarts nothing; the next deploy copies the latest revision.
- AA-Partner needs no code change: `web/instrumentation.ts` reads `SENTRY_DSN` at run time (not inlined, it is not a
  `NEXT_PUBLIC_` name) and `api/app/observability/sentry.py` reads `SENTRY_DSN` and logs `sentry_enabled`. The
  comment in `web/instrumentation.ts` still names the retired `crm_portal_sentry_enabled` route (follow-up).
- Tests: `tools/identity/tests/test_crm_dev_identity.py` (the command, and that `crm_web.tf` maps the same key
  behind the flag) and `tools/terraform/tests/test_aa1004_environment_moves.py` (the setting is declared identically
  in the root and the module and passed through).
