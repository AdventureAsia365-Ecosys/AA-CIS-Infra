# AA-993 — Migration Sync without the cron (S258)

Problem: `migration-sync.yml` relied on a `*/10` cron. GitHub runs scheduled workflows best effort; on 2026-10-29 the
cron fired once (11:32Z) in about 6 hours after M3 merged (lesson log S257), and Migration Apply's hourly cron fired
once too. So "app merge → copy PR → ci-bot merge → apply" had a hand step hidden in it: someone dispatching the sync.

## Decisions

- **Doorbell = a ci-bot comment on one labelled Infra issue (`issue_comment`), not `repository_dispatch` /
  `workflow_dispatch`.** Every owner repo gets `migration-sync-wake.yml` (push to `main` touching its migrations
  folder). It mints an `aa-ecosys-ci-bot` token for AA-CIS-Infra with **Issues write only** and comments on the open
  issue labelled `migration-sync-wake`. The sync job runs only when the commenter is exactly `aa-ecosys-ci-bot[bot]`,
  the issue carries the label and is not a PR; the comment text is never read (the sync still pulls the owners'
  `main` anonymously, critic 1). Why not the alternatives:
  - `repository_dispatch` needs Contents write on Infra (ADR 0017 / 0011a reject it: that token could change the
    runner the next auto-apply runs).
  - `workflow_dispatch` needs Actions write on Infra. ci-bot has no Actions permission today (installation
    permissions: contents, issues, metadata, pull requests), so it would need an App permission change (org owner)
    and the key held by every app repo could then dispatch **any** Infra workflow (DB Migrate `run-script` /
    `set-password`, Terraform Apply: both use the `prod` environment, which has no reviewers).
  - Issues write is a permission ci-bot already has: no App change, no new secret. Worst case of a leaked minted
    token: issue / PR comments and labels on Infra (labels are informational: Migration Apply re-checks bytes and
    re-classifies, ADR 0017 d5).
- **Merge pass follows the checks: `workflow_run`** of `Terraform Plan` and `Migration Copy Guard` (the two slow
  required checks) completed on a `bot/migration-copy/**` branch of this repo. `gitleaks` (Secret Scan) runs on
  `pull_request_target`, whose run head branch is `main`, so it cannot be filtered to copy branches; it is the
  fastest check, and the cron backstop covers the rare case it ends last.
- **Concurrency moved to the job.** With `issue_comment` anyone on GitHub can start a run of this public repo's
  workflow (its job is skipped). At workflow level the skipped run would still enter the `migration-sync` group and
  could replace a pending real run; job-level concurrency is evaluated only for a job that runs.
- **The wake-up issue is created by Infra** (scheduled or manual run, `GITHUB_TOKEN`, which already had
  `issues: write` for the class labels), never by the apps: one issue, one label, and the app token stays
  comment-only in practice. No issue open = the app run warns and stays green (the cron still copies).
- **Cron kept as backstop, offset to `4-59/10`** (GitHub drops scheduled runs most at the top of the hour).
- **Lead time tool:** `tools/github/migration_lead_time.py` (read-only `gh api`): app PR merge → copy PR opened →
  copy merged → applied (Migration Apply run on the copy merge commit, apply + probe green; else the first DB Migrate
  success after the copy, marked `manual~`, or exact `shared.schema_versions.applied_at` from `--applied-at`). The
  sync summary now records its trigger.

## Changed

- `.github/workflows/migration-sync.yml`: triggers, job `if`, job concurrency, `Trigger` and `Wake-up issue` steps.
- `db/tests/test_aa993_apply_pending.py`: cron and `if` assertions updated; new `test_sync_wakes_on_events_not_only_the_cron`.
- `CONTEXT.md`, `db/README.md`: trigger text.
- New `tools/github/migration_lead_time.py` + `tools/github/tests/test_migration_lead_time.py` (not wired into a
  workflow; run `python3 -m unittest discover -s tools/github/tests`).

## Tradeoffs

- The app repos already hold the ci-bot private key (environment `release`), which can mint any permission the App
  has on any installed repo; as with kit-sync (ADR 0011a d3), the narrowing in the workflow is the control. This
  change adds no App permission, so a leaked key can do nothing it could not do before.
- A public issue as a doorbell is unusual but auditable: each comment is a timestamped record of a wake-up, which
  the lead-time measurement can use. Closing it is safe (the next scheduled or manual sync reopens one).
- Every Infra PR's `Terraform Plan` / `Copy Guard` completion on a non-copy branch is filtered out at the trigger
  (`branches`), so no extra runs for ordinary PRs.

## Should know

- Needs root ADR 0011a decision 3 and ADR 0017 decision 2 amended (root branch `docs/aa-993-sync-wake-trigger`).
- First run after merge must be a manual or scheduled one to create the issue (RUNBOOK step 2), before any app
  wake-up workflow fires.
- `issue_comment` and `workflow_run` run the workflow file of `main` only: the new triggers work only after merge.
