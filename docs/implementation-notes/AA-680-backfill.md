# AA-680 backfill — link bridge-era Booking staff rows to Cognito (+ bk-016 copy)

Session S243 (Claude Code builder). Part of AA-680 Booking Phase 2 (root ADR 0006 / 0006a). The Booking side is in
AA-Booking `docs/implementation-notes/AA-680.md` (bk-016, the identity link, the PR-4 retirement checklist).

## What this PR holds

- `db/migrations/booking/016_staff_cognito_identity.sql`: byte-identical copy of AA-Booking
  `migrations/016_staff_cognito_identity.sql` (bk-016: `booking.staff_users.cognito_iss / cognito_sub`, pair check,
  `cog:` key check, unique identity index). Same flow as the bk-008 … bk-015 copies (#115 … #179): merge the
  migration-only AA-Booking PR first, then this copy (Copy Guard is red until then), then DB Migrate check → apply.
  No `owners.yaml` change (Booking dir, key prefix and roles are unchanged; DB Migrate runs it as `bk_owner`).
- `db/scripts/aa680_link_staff_cognito.py`: the one-time backfill, DB Migrate `mode=run-script`.
- `db/tests/test_aa680_link_staff_cognito.py`: stdlib unit tests (fake connection) incl. the runner's shape check.

## Decisions

- **Why a run-script and not a migration**: it moves data between two owners' schemas (reads CIS
  `shared.admin_users`, writes `booking.staff_users`). A Booking migration may not read `shared.admin_users` (the
  migration guard allows only `shared.schema_versions`, and `bk_owner` has no grant on it); a CIS migration may not
  write `booking.*`. db/scripts/README.md: "a fix across owners" is exactly what run-script is for. It runs as the RDS
  master `aa_cis_admin`, which owns `shared.admin_users` and inherits `bk_owner` (rl-001) for `booking.staff_users`.
- **DRY RUN by default = `READ_ONLY = True`** (the runner then opens the session with
  `default_transaction_read_only = on`, so the DRY RUN cannot write even by mistake, and the idle check only reports).
  run-script takes no arguments, so the apply is a **one-line follow-up PR** `READ_ONLY = False` after the DRY RUN
  output was reviewed (README: "the change as a separate reviewed script or a flag in the same PR"). The `--apply`
  flag exists only for local runs (`python3 db/scripts/aa680_link_staff_cognito.py <DSN> [--apply]`).
- **What is linked**: only rows keyed by a CIS id (not `cog:`), whose CIS row has `cognito_sub`, whose Booking row is
  unlinked, and whose identity no other Booking row holds. `email` / `name` are filled from the CIS row only when the
  Booking row has none (bridge tokens carried no e-mail). Role and `active` are never touched: Booking sets the role
  from the `booking-*` group on the next Cognito sign-in.
- **Never rebinds, never merges.** A `cog:` row already holding the identity (the person signed in with Cognito before
  the backfill) is reported `conflict_cog_row_exists` and skipped: merging would re-point ~30 FKs. Other skips:
  `no_cis_user`, `cis_not_linked`, `conflict_linked_other`, `conflict_identity_taken`, `already_linked`.
- **One transaction for the apply**, `SELECT … FOR UPDATE OF s`, `lock_timeout` 5 s; the UPDATE re-checks "still
  unlinked" (`changed_concurrently` otherwise). One `booking.audit_logs` row per link (`actor_type = system`,
  `actor_ref = script:aa680_link_staff_cognito`, action `staff.identity_linked`).
- **Output**: one `SCRIPT row {…}` JSON line per bridge-era row (id, CIS username, outcome, Booking role / active, CIS
  active, first 8 chars of the sub, whether e-mail / name get filled) and `SCRIPT counts {…}`. No e-mail, password or
  DSN (README output rule).

## Changed (vs. the task text)

- "--apply to write" is the `READ_ONLY` flip for the DB Migrate run (the runner passes no arguments); `--apply` is kept
  for local runs.

## Tradeoffs

- A follow-up PR for the apply costs one more Infra merge, but keeps the reviewed DRY RUN and the write as two
  separate, visible steps (destructive-ops procedure), and the merged default can never write.

## Should know

- Order on Dev: AA-Booking bk-016 PR merged → this PR merged → DB Migrate `check` then `apply`
  `booking/016_staff_cognito_identity.sql` (DB Schema Dump PR follows) → DB Migrate `mode=run-script`
  `script=db/scripts/aa680_link_staff_cognito.py` (DRY RUN; read the rows) → follow-up PR `READ_ONLY = False` → merge →
  run-script again (apply; the idle check waits for idle job tables) → run it once more read-only or apply to see
  `already_linked` → then merge the AA-Booking code PR.
- Before the DRY RUN, Nghiệp's CIS staff rows must have `cognito_sub` (set by the CIS staff directory when the Cognito
  user was created / linked). `cis_not_linked` rows can be linked later by re-running the script, as long as the
  person has not signed in to Booking with Cognito in between.
- The script reads `shared.admin_users` as the master; after X1 S22 run-script needs the runner's own master
  connection (README), unchanged here.
- Verified locally (PostgreSQL 16, Booking migrations incl. bk-016, a stub `shared.admin_users`): DRY RUN in a
  `default_transaction_read_only` session (no write; apply in that session → `ReadOnlySQLTransactionError`), apply
  (2 linked, 1 `cis_not_linked`, 1 `conflict_cog_row_exists`, audit rows written), re-run → `already_linked`.
