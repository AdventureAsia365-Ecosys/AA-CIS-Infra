# AA-1032 (parts 1 and 5, Infra half): Dev auto-applies contract migrations when idle

Lane `ship-autoapply`, S263. Root half: root repo branch `docs/aa-1032-contract-auto-apply` (ADR 0017a, skill
`aa-ship`, runbook `db-migrate.md`, `tools/workflows/lane.js`).

## Decisions

- **Contract mode lives in the existing Migration Apply, not a new workflow.** The task already holds the apply lock,
  walks each owner in key order, stops at the first failure and never past a gap. A contract file is now an `apply`
  step when the bundle says `"contract": true`; it goes through `apply_file` exactly like a DB Migrate `apply` of a
  contract file, so it gets DB Migrate's all-job-tables-idle wait (3 x 20 s over `shared.job`, `booking.job`,
  `crm.job` and open `shared.rerun_wave`), the default timeouts, the role switch and the ownership post-check. The
  idle override and the snapshot never reach the task (the task strips them, as before).
- **Busy = deferred, not failed.** Exit 7 for a contract file is recorded as `deferred` (status, class, reason), the
  owner stops there, the run stays green, the hourly schedule retries. Same handling as the existing Q5 hot-table
  deferral.
- **Environment check in three places.** The workflow sets `TARGET_ENV: dev` (its cluster, service and bucket are the
  dev ones) and computes `contract` in the gate step; `apply_pending.contract_mode` accepts `--contract` only for an
  environment in `run_migration.CONTRACT_AUTO_ENVIRONMENTS`; the task's `read_bundle_contract` refuses (exit 10) a
  contract bundle whose `environment` is not in that tuple. The tuple mirrors `db/owners.yaml`
  `contract_auto_apply_environments: [dev]` (registry test).
- **Kill switch, default on.** Repo variable `DB_AUTO_APPLY_CONTRACT`: unset or anything but `false` = on (the tech
  lead asked for it now; no variable to set by hand). `false` = contract files go back to manual DB Migrate, noted on
  their copy PR. `DB_AUTO_APPLY` (and the public repo + ruleset gate of ADR 0017 d8) still gates everything.
- **Evidence for a contract file.** Bytes equal to the owner's `main` (unchanged) AND the classify replay applied it
  cleanly (`applied` = `ok`/`here`: `replay_migrations.run_item` with the role switch and the ownership post-check)
  AND a clean lint. The expand rehearsal's own `error` is ignored for a header-less file (it rehearses the file as if
  it were expand, with the 30 s timeout).
- **Destructive is its own stop kind** (`destructive`) in both modes, with its own copy-PR note (DRY RUN, snapshot).
  Before, a destructive file stopped as `contract`.
- **A header-less DELETE is its own stop kind** (`delete`, review fix pass). Lint only WARNS about a `DELETE` without
  `-- migrate: destructive` (MIG-12), and nobody reads a warning on an automatic run, so in contract mode a contract
  file with a `DELETE` statement (plain or in a CTE; `run_migration.deletes_rows`) is a stop with its own copy-PR
  note, and its copy PR body says "manual DB Migrate apply needed" instead of "Dev applies it". Scoped to the
  `DELETE` statement, not "any warning": `DELETE` is the only warning lint emits today; a future advisory warning
  should not silently turn into a stop. Expand files are unchanged (the expand lint already refuses writes to
  existing tables).
- **Migration Sync fix (the "auto-merge contract copy PRs" part).** The merge pass already merged every class; it
  refused copy PRs whose head commit carried a cancelled duplicate `gitleaks` run next to a green one (two PR events),
  which is why #578, #583, #589 and others were merged by hand. `merge_check` now judges the latest run per (name,
  app id), as GitHub does (`latest_runs`). This also closes lesson "Bot đọc check run theo tên phải lấy lần MỚI NHẤT"
  (S258 #510).

## Changed

- `db/run_migration.py`: `STOP_DESTRUCTIVE`, `STOP_DELETE`, `deletes_rows`, `CONTRACT_AUTO_ENVIRONMENTS`, `AutoStep.cls`, `plan_pending(...,
  contract=False)`, `read_bundle_contract`, contract mode in `run_apply_pending` (log line, result `contract`, row
  `class`, deferral reason).
- `db/apply_pending.py`: `--environment`, `--contract`, `contract_mode`, `contract_evidence`, contract verdicts,
  STOP_NOTES (contract text, destructive, refused-classify wording), Class in the plan and result tables.
- `db/migration_sync.py`: `latest_runs`; contract copy PR body says Dev applies it.
- `.github/workflows/migration-apply.yml`: header, `TARGET_ENV`, `DB_AUTO_APPLY_CONTRACT`, gate output `contract`,
  `--environment` / `--contract` on both plan steps, summary line. `.github/workflows/migration-sync.yml`: header.
- `db/owners.yaml`: `contract_auto_apply_environments: [dev]`.
- Tests: `db/tests/test_aa1032_contract_auto_apply.py` (28, incl. the `delete` stop in plan, task, runner and copy PR body), `test_owners_registry.py` (mirror),
  `test_aa993_migration_sync.py` (contract body wording).
- Docs: `db/README.md`, `CONTEXT.md`.

## Tradeoffs

- A contract file deferred by busy job tables waits for the hourly run (or the next push to `main`); a wave that keeps
  `shared.job` busy for hours delays it. Accepted: Dev, and the same rule DB Migrate applies. A person can still run
  DB Migrate with an override (tech lead only).
- Failure isolation stays per owner (the other owners still run), as ADR 0017 d5. Owners are applied cis, booking,
  tripplanner, crm in one task.
- No new IAM: the narrow role already runs the migrator task; the task's login (`db_migrator`) is the one DB Migrate
  uses for contract files.

## Should know

- Live proof (Done-when): the next contract copy (CIS 331 or later; CIS 330 is an expand file) must show a Migration
  Apply run with `apply ... (contract)` and `MIGRATE auto-result` status `applied`, class `contract`, and no DB Migrate
  run for that file.
- MIG-4's order (migration-only PR, then the code PR with the readiness raise) still holds for contract files: the app
  preflight still refuses a readiness raise to a non-expand file. Only the manual DB Migrate step is gone on Dev.
- Copy PRs merged before this change carry "Manual DB Migrate apply needed" notes; they are history.
