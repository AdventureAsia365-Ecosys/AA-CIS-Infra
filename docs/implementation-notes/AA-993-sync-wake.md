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
    token: issues, issue / PR comments and **labels on Infra PRs**. Labels are not all informational: the class labels
    (`migration:*`, `out-of-order`) are, since Migration Apply re-checks bytes and re-classifies (ADR 0017 d5), but
    `secret-scan.yml` (`pull_request_target`, runs on `labeled` / `unlabeled`) takes the label
    `secret-scan-baseline-reviewed` as the reviewer override of the required `gitleaks` check: added to a PR that
    changes the gitleaks baseline or a guarded workflow, it makes that run scan with the PR's own copies. A minted
    Issues-write token could add it. Acceptable, because it is no new reach: the same ci-bot key can already mint
    Contents and Pull requests write on Infra (the Migration Sync token), which is more; the label counts only on the
    run that adding it starts (any later push, reopen or label removes it); and ci-bot itself merges only a PR that
    adds one byte-identical copy file with every required check green, which never needs the label. Any other PR
    still needs a person (or the orchestrating agent) to merge it.
- **Merge pass follows the checks: `workflow_run`** of `Terraform Plan` and `Migration Copy Guard` (the two slow
  required checks) completed on a `bot/migration-copy/**` branch of this repo. `gitleaks` (Secret Scan) runs on
  `pull_request_target`, whose run head branch is `main`, so it cannot be filtered to copy branches; it is the
  fastest check, and the cron backstop covers the rare case it ends last.
- **Concurrency moved to the job.** With `issue_comment` anyone on GitHub can start a run of this public repo's
  workflow (its job is skipped). At workflow level the skipped run would still enter the `migration-sync` group and
  could replace a pending real run; job-level concurrency is evaluated only for a job that runs.
- **Noise accepted:** every comment on any Infra issue or PR, by anyone, now starts a Migration Sync run whose job is
  skipped (a grey entry in the Actions list, no runner minutes). The gate is the job `if` (ci-bot login with the
  `[bot]` suffix, the label, not a PR).
- **Wake-up issue step right after the trigger line**, before clone / plan / mint / merge: a later step failing on
  the first manual run after the merge still leaves the doorbell in place.
- **The wake-up issue is created by Infra** (scheduled or manual run, `GITHUB_TOKEN`, which already had
  `issues: write` for the class labels), never by the apps: one issue, one label, and the app token stays
  comment-only in practice. No issue open = the app run warns and stays green (the cron still copies).
- **Cron kept as backstop, offset to `4-59/10`** (GitHub drops scheduled runs most at the top of the hour).
- **Lead time tool:** `tools/github/migration_lead_time.py` (read-only `gh api`): app PR merge → copy PR opened →
  copy merged → applied. Applied = the first Migration Apply run created at or after the copy merge whose apply job
  succeeded: the push run on the merge commit first, then a later cron / push / manual run (marked `via <event>
  run`: when the push run only listed, e.g. auto-apply was off, the next run applies every pending file). `how` is
  `auto+probe` only with the blocking Isolation probe green, else `auto (probe <conclusion>)` / `auto (no probe)`.
  No Migration Apply apply: the first DB Migrate success after the copy (`manual~`), or exact
  `shared.schema_versions.applied_at` from `--applied-at`. `no_hand_step` counts only a ci-bot copy applied
  `auto+probe` by a push or cron run (a dispatched run is a hand step). The script does not read run summaries; the
  sync's `Trigger` step line is for people.

## Changed

- `.github/workflows/migration-sync.yml`: triggers, job `if`, job concurrency, `Trigger` and `Wake-up issue` steps
  (the latter right after `Trigger`, review fix).
- `db/tests/test_aa993_apply_pending.py`: cron and `if` assertions updated; new
  `test_sync_wakes_on_events_not_only_the_cron` (also pins the wake-up issue step before the clone step).
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

- The owner workflows mint the token in their environment `release`. CIS, Booking and TripPlanner restrict it to
  `main`; AA-Partner's had no deployment branch policy on 2026-10-29: set it to `main` before the Partner wake-up PR
  merges (RUNBOOK step 3 precondition). The workflow's job-level ref check is no substitute.
- The owner workflows post the comment with a plain REST call (`gh api`, POST `repos/<Infra>/issues/<n>/comments`),
  the most predictable call for an Issues-write-only token.
- Root PR #328 (ADR 0017 d7 text) still says "with the */10 sync cron"; reword it when #328 is finalised after the
  bk-034 proof (both touch the ADR files: rebase expected).

- Needs root ADR 0011a decision 3 and ADR 0017 decision 2 amended (root branch `docs/aa-993-sync-wake-trigger`).
- First run after merge must be a manual or scheduled one to create the issue (RUNBOOK step 2), before any app
  wake-up workflow fires.
- `issue_comment` and `workflow_run` run the workflow file of `main` only: the new triggers work only after merge.
