# AA-986 L7b — nightly tour liveness gate (AA-CIS-Infra part)

Linear: AA-986, slice L7b. Authority: root ADR 0015 (Accepted S248) decision 6, audit memo
`docs/audits/2026-10-23-S248-tour-deletion-propagation/memo.md` in the root repo. Root part (data standards row):
root branch `docs/aa986-l7b-tour-liveness-gate`.

## Decisions

- **A new workflow, not a step in DB Schema Dump.** `db-tour-liveness-gate.yml` has its own concurrency group and
  schedule (04:43 UTC). The dump is catalog-only and opens root PRs; mixing a red gate into it would hide the
  reference PR's state, and a shared group could cancel a pending DB Migrate run.
- **Same mechanism as DB Migrate run-script, not a dispatch of DB Migrate.** The workflow runs the runner itself
  (`MIGRATION_MODE=run-script:db/scripts/s248_tour_deletion_probe.py`, the same task env names, no new one), so the
  gate never joins DB Migrate's concurrency group and never shows as a "migration" run. The runner enforces the
  master login and READ_ONLY exactly as for a manual run-script.
- **The verdict is decided outside the task** by `db/tour_liveness_gate.py` from the task log (stdlib only, unit
  tested), not by a non-zero return of the probe: a non-zero `main()` is runner exit 13, the same as a crash.
  Red = task exit ≠ 0, no READ_ONLY line, no / two verdicts, bad JSON, verdict ≠ JSON, violations > 0, errors > 0,
  or no catalog role.
- **ADR 0015 decision 6 checks added to the probe** (`CHECKS`): two active Masters in one group, an active Master over
  a dead source, catalog key not served (split brain against `gold_aa_internal.v_tour_liveness`), latest lifecycle
  event vs the derived state, not-served keys with no event (keep_warn: pre-L2 history), the L4 tombstone vs the
  derived state, and "nothing new after the key stopped being served" for T2 rewrites (L3) and B2B quotes / holds
  (L5).
- **Pending, by object presence**: a check whose object is missing (read from `pg_class`, so the master needs no
  USAGE on the schema; `to_regclass` would raise 42501) reports `expect=pending`. When L4 creates
  `catalog.v_tour_retired` the check turns strict on its own; a view without `source_id` / `state` is an error (red),
  so the L4 PR must align `TOMBSTONE_SQL` instead of the gate passing silently.
- **Pending, by date** for L3 / L5: a refusal in app code leaves no object to detect, so `ENFORCED_SINCE` holds the
  UTC date the slice went live (one-line PR). Before that the checks are keep_warn; after, only rows created after
  both that date and the key's `changed_at` count, so history from before the slice never turns the gate red.
- **The tombstone is read as the catalog role** (`booking`, else the role that read `catalog.v_tour`): the master
  has no grant on `catalog` views. The CIS checks read as the master in the probe's read-only snapshot (the master
  inherits `cis_app` / `cis_owner`; FORCE RLS policies `TO cis_app` apply, as the earlier live run of the probe
  showed on `raw_tours`).
- **Runner hash checked in the task.** The boot command compares the downloaded runner's sha256 with the value the
  workflow computed before exec (the payload's hash was already checked by the runner). The bronze bucket is
  writable by other roles (the CIS task role has `s3:PutObject` on `*`) and the runner reads the master DSN.
- **No account id in the workflow**: the bronze bucket name is built at run time from `sts get-caller-identity`
  and masked (AA-981). The older DB workflows still carry the literal; not changed here.

## Changed

- `db/scripts/s248_tour_deletion_probe.py`: checks, `SCRIPT check` lines, `pending=<n>` on the verdict line, JSON
  `checks` / `pending` / `check_definitions` / `enforced_since`; a check that cannot compare with the catalog adds an
  error (before, `role=-` was silent). Docstring: now the nightly gate; ADR 0015 accepted.
- New: `db/tour_liveness_gate.py`, `.github/workflows/db-tour-liveness-gate.yml`, `db/tests/test_tour_liveness_gate.py`.
- `db/tests/test_runner_modes.py`: the migrator-workflow shape tests cover the new workflow.
- `migration-copy-guard.yml`: PR paths include the gate script and workflow (its job runs `db/tests`).
- Docs: `CONTEXT.md`, `README.md`, `db/README.md` ("Tour liveness gate"), `db/scripts/README.md`.

## Tradeoffs

- The CIS half of the memo probe (atoms, routes, Slate, T2/T8/T9/T11 layers; ran by ECS exec as `cis_app`) is not
  ported. It is ~30 layers over CIS tables; the decision 6 invariants that matter most for the cross-app rule are
  covered here. Porting it is a follow-up slice.
- `catalog.v_tour` and the snapshot are read in separate transactions (milliseconds apart): a state change exactly
  then could give one false red. Accepted for a nightly run.
- The checks compare states only, not reasons (writes outside the service could change a reason without a state).

## Should know

- No live run yet: the workflow only runs from `main` (OIDC `ref` claim + job `if`). The SQL ran on a throwaway
  PostgreSQL 16 (stub schema with CIS 272's view and table copied verbatim): green run, then 4 planted violations
  turned it red; the gate script read both logs correctly.
- After merge: dispatch once by hand (lesson "a workflow must run for real once before it is called done").
- When L3 / L5 deploy: set `ENFORCED_SINCE`; when L4 lands: check the first run shows the tombstone check `zero`.
