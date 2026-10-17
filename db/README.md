# db/ — migrations applied to the shared RDS (acc2)

RDS is VPC-private, so migrations are applied by the **DB Migrate** workflow
(`.github/workflows/db-migrate.yml`): it starts a one-off ECS Fargate task from the CIS api task
definition, which downloads `run_migration.py` and the SQL via presigned S3 URLs and runs it
with the task's own `DATABASE_URL`.

```
db/migrations/<owner>/<NNN>_<name>.sql   # owner = cis | tripplanner | booking | roles
db/owners.yaml                           # owner registry (X1, DM-1.2)
```

Version key registered in `shared.schema_versions`: `cis` → `NNN`, `tripplanner` → `tp-NNN`,
`booking` → `bk-NNN`, `roles` → `rl-NNN` (ownership rules: `AA-Ecosys/docs/database/schema-ownership.md`).

## Owner registry (`owners.yaml`, X1 plan S1)
One entry per migration dir: repo, path, key prefix, anchor schema, schemas, owner role (target and
today), runtime roles, job table, job-kind prefix, idle-exempt kinds, allowed `SET LOCAL ROLE`
targets, the first file number the role lint applies to, and the allowed consumer grants (input for
the X2 grant guard, not enforced yet). `roles/` is the Infra-native dir: role bootstrap (roles,
attributes, memberships, connection limits), `CREATE/ALTER/DROP EXTENSION`, `public.*` leftovers and
the prepared undo files of the X1 ownership transfers; it always runs as the RDS master.

The runner, the copy guard and the workflow keep their own constants (standard library only, the ECS
task gets just the runner and the SQL); `db/tests/test_owners_registry.py` fails when any of
`run_migration.py` (`MASTER_ROLE`, `OWNER_DIRS`, `IDLE_EXEMPT_KINDS`), `check_migration_copies.py`
(`OWNERS`, `PATH_RE`) or `db-migrate.yml` (dir regex, key prefixes, `environment` choices) disagrees
with `owners.yaml`. Change them in the same PR.

## Flow
0. The owner repo merges a **migration-file-only** PR to its `main` first (S237 D8). Code that
   reads the new objects comes in a later PR, after the apply.
1. PR adds the SQL here as a byte-identical copy (`cp` the owner file; human review = the
   approval). A `roles/` file is written here (Infra-native): the guard checks only its path and its
   `rl-NNN` registration. **Migration Copy Guard** (`.github/workflows/migration-copy-guard.yml`, AA-807)
   compares each added/changed file with the owner's `main` through the GitHub API and fails on:
   a path DB Migrate would refuse, a missing or wrongly prefixed `shared.schema_versions` key, a
   file not on the owner's `main` yet ("merge the migration-only PR in the owner repo first"), or
   any byte difference. It also runs nightly over every copy. Local run:
   `GH_TOKEN=$(gh auth token) python3 db/check_migration_copies.py db/migrations/cis/228_x.sql`
   (or `--all`; without a token GitHub allows 60 anonymous requests/hour); tests:
   `python3 -m unittest discover -s db/tests`.
2. Merge to `main`.
3. Run **DB Migrate** on `main` with `mode=check` and `environment=dev` (prints the role the file
   runs as, whether the version is registered, the latest key of the same owner and the idle state
   of every job table, see "Role per file" and "Idle check" below),
   then `mode=apply`. The job fails unless the task exits 0 and
   the version is in `shared.schema_versions` afterwards. Re-running `apply` is a no-op.
4. **DB Schema Dump** (`.github/workflows/db-schema-dump.yml`) is dispatched by a successful apply
   (and runs nightly): it regenerates `AA-Ecosys/docs/architecture/db-schema-reference.md` and
   opens/updates the root PR `bot/db-schema-reference` when the structure changed. Merge it by hand.

## Runner safety (AA-807 N5, `run_migration.py`)
Every DB Migrate session runs with `lock_timeout = '5s'`, `statement_timeout = '15min'`,
`application_name = 'db-migrate'`. Directives go in the file's **leading comment block**, one per
line (a directive after the first statement is an error):

```sql
-- Migration 241: AA-xxx — covering index for …
-- migrate: no-transaction          -- statements run one by one, outside a transaction
-- migrate: lock_timeout=30s        -- override (us, ms, s, min, h, d)
-- migrate: statement_timeout=1h    -- override
-- migrate: destructive             -- DB Migrate takes an RDS snapshot before apply
```

- **no-transaction** (MIG-10): for `CREATE INDEX CONCURRENTLY`, `REINDEX CONCURRENTLY`, `VACUUM`.
  No `BEGIN`/`COMMIT` in the file, every statement idempotent (`IF NOT EXISTS`), and the
  `shared.schema_versions` INSERT is the **last** statement, so a failed run is retried. A failed
  `CONCURRENTLY` build leaves an INVALID index (the schema reference flags it): drop it before the
  retry.
- **destructive** (MIG-12): required for `DROP TABLE` / `DROP SCHEMA` / `DROP MATERIALIZED VIEW`,
  `ALTER TABLE … DROP [COLUMN]` and `TRUNCATE`. On `mode=apply`, DB Migrate creates the manual
  snapshot `db-migrate-<version>-<run id>-<attempt>` of `aa-cis-dev-db`, waits until it is available and
  passes its id to the task; the runner refuses a destructive apply without it (exit 5). The DRY
  RUN procedure still applies. Delete the snapshot by hand once the contract is confirmed.
- **Lint** (same code in CI, in the DB Migrate "Validate input" step and in the task): unknown or
  misplaced directives, `CONCURRENTLY` (except `REFRESH MATERIALIZED VIEW CONCURRENTLY`) or `VACUUM`
  without no-transaction, destructive statements without the
  header and transaction control in a no-transaction file are errors; `DELETE` without the header
  is a warning. Local: `python3 db/run_migration.py --inspect db/migrations/cis/241_x.sql`.
- **Role lint** (X1, owner files numbered at or above `role_lint_from`: CIS 243, bk-014, tp-013;
  applied files never re-run and 225/229/235/237/239/241 use the pre-X1 patterns): no `RESET ROLE`
  (it returns to the login role, which after X1 S22 is `db_migrator`), no `SET ROLE` / `SET SESSION
  ROLE` / `ALTER FUNCTION … SET role` (only `SET LOCAL ROLE`; `"role"` quoted counts), no SESSION
  AUTHORIZATION in any form, no `set_config('role', …)` and no `set_config()` whose name is not a
  plain literal (`E''`/`U&''` literals are read), no role switch or role DDL in dynamic SQL (`EXECUTE`:
  each string piece of the statement, the pieces joined, `format()` filled in, and half-keyword pieces
  like `'RESET ' || 'ROLE'` are refused), no `CREATE/ALTER/DROP EXTENSION` or `ROLE` and no role
  membership `GRANT r TO x` / `REVOKE r FROM x` (all → `roles/`). `SET LOCAL ROLE` only to the dir's
  `set_local_roles`: `cis/` `catalog_owner`, `cis_owner` (the way back), `cis_app` (guard blocks);
  `booking/`, `tripplanner/` none. Checked in DO blocks and function bodies too; comments and ordinary
  string literals are ignored. No `DEFERRABLE` / `INITIALLY DEFERRED` constraint trigger and no
  `SET CONSTRAINTS … DEFERRED` (they postpone work to COMMIT, after the post-check); these two are
  also looked for inside string literals (`'…'` function and DO bodies, dynamic SQL). Deliberately
  obfuscated SQL (`chr()`, `reverse()`) is out of a lint's reach: the ownership post-check is the
  backstop.
- **Switch shape** (same files): one `BEGIN … COMMIT` block (no inner `COMMIT`/`ROLLBACK`/`PREPARE
  TRANSACTION`, no `COMMIT AND CHAIN`), or a `-- migrate: no-transaction` file whose last statement
  is a plain literal registration: `INSERT INTO shared.schema_versions [(version, …)] VALUES (…)
  [ON CONFLICT [(version)] DO NOTHING]` with string/number literals, `NULL`, `DEFAULT`, `now()` or
  `CURRENT_TIMESTAMP` only (no function call, subquery or cast). Such a file may run under the role
  switch, which needs that shape; the lint fails the PR instead of exit 8 at apply.
- **Unique numbers** (MIG-3): `db/check_migration_files.py` fails when two files in one owner dir
  share a number, `roles/` included (CI job "Migration lint and unique numbers").
- Exit codes: 2 sha256 mismatch, 3 not registered, 4 lint error, 5 destructive without snapshot,
  6 PostgreSQL error (lock or statement timeout prints a hint), 7 apply refused because a job
  table is busy or a rerun wave is open, 8 role refused, 9 ownership post-check failed (or the
  check after COMMIT found something that ran at COMMIT).

## Role per file (X1 plan S1, XD8)
Before each file (check and apply) the task reads the **live owner of the dir's anchor schema**
(`cis/` → `shared`, `booking/` → `booking`, `tripplanner/` → `tripplanner`) and logs
`MIGRATE ran as: <role> — <why>` (also in the job summary).

- Owner = login role (today, for every dir): no switch, the file is sent exactly as before.
- Owner ≠ login role (after bk-014 / tp-013 / CIS 245 commit): the login role must be a member of the
  owner, and on apply the owner must be able to register the version (USAGE on `shared`, INSERT on
  `shared.schema_versions`, CIS 243), else exit 8 before anything runs. The file must be one
  `BEGIN … COMMIT` block (else exit 8; the lint already refuses other shapes above the heads). The
  runner sends the file's `BEGIN`, takes a **snapshot** of every owned object and of the role catalog
  (as the login role), `SET LOCAL ROLE <owner>`, the body (its registration runs as the owner), then
  — still as the owner — **settles** the work queued for COMMIT: `SET CONSTRAINTS ALL IMMEDIATE` fires
  pending deferred trigger events (deferrable constraint triggers, deferred FK / unique checks), in a
  savepoint, repeated while a round writes (a fired trigger can re-defer; > 10 rounds → exit 9), and
  `CLOSE ALL` drops cursors (a `WITH HOLD` cursor's query runs at COMMIT). Then `RESET ROLE`, pins
  `search_path` to `pg_catalog, pg_temp`, takes the snapshot again and runs the **ownership
  post-check**, then the file's `COMMIT`. Any hit → `ROLLBACK`, exit 9, with the names:
  - an object created or re-owned during the file whose owner is not the owner it ran as (or the
    dir's `view_owner_roles`, `catalog_owner` for `cis/`) — any schema but `pg_catalog`,
    `information_schema`, `pg_toast` and temp schemas, every catalog with an owner (relations incl.
    sequences/views/matviews, functions/procedures, types, schemas, operators and their classes and
    families, collations, conversions, text search, extended statistics, default privileges,
    extensions, languages, FDWs/servers, publications, event triggers, large objects, databases);
  - an object the login role owns in an `owners.yaml` schema whose schema the login role no longer
    owns (a transferred owner), even from before the file;
  - any added, changed or removed role, role membership or role setting (`roles/` only).
  The snapshot compares (kind, oid, owner), so subtransactions, schema creation, a transfer back to
  the login role and catalog shadowing through `search_path` do not hide anything. A concurrent DDL
  by another session during the file can trip it too (rolled back; re-run).
  A no-transaction file runs statement by statement under a session `SET ROLE <owner>`, all but its
  **last** statement (the registration, a plain literal INSERT by the lint, checked again at run time
  for files below the head, exit 8). The registration runs in the runner's own transaction: `BEGIN`,
  `SET LOCAL ROLE <owner>`, pinned `search_path`, the INSERT, settle, `RESET ROLE`, post-check, then
  `COMMIT` — a hit → `ROLLBACK`, exit 9, the earlier statements stay committed (no transaction), the
  version is **not** registered, so the file is retried once the objects are fixed.
  Both paths take the snapshot once more **after COMMIT**: anything that still ran at COMMIT shows up
  there → exit 9 with "ownership check after COMMIT" (the file is committed and registered; clean up by
  hand). With the settle step nothing of the file is left to run at COMMIT; this is the backstop.
- `roles/` files run only when the login role is the master (`master_role`), else exit 8.
- The idle check and the `shared.schema_versions` reads run as the login role.

So the very next file after an ownership transfer runs as the new owner, with no runner change and
no window in which the login role creates objects no default privilege covers. The undo of a transfer
is a `roles/` file (`rl-NNN`), because a file in the transferred dir would run as the new owner.

## Idle check (AA-751, ADR 0003a decision 5, data standards C6.3b)
DB Migrate `apply` waits until **every** owner job table is idle. On both modes the task logs
one line per object, after the `before:` line:

```
MIGRATE idle: shared.job running=0 queued=0
MIGRATE busy: booking.job running=0 queued=1 due=1 kinds=[bk_x6_probe:queued=1]
MIGRATE busy: shared.rerun_wave open=1
MIGRATE ERROR: refusing apply — busy: booking.job (queued=1). Wait until every job table is idle, or re-dispatch with override_busy_jobs=<reason> (Nghiệp only)
```

- **Which tables:** every `<schema>.job` with a `status` column, read from the catalog
  (`shared.job` CIS, `booking.job` Booking, a future `tripplanner.job` without a code change), plus
  `shared.rerun_wave` rows with `status = 'open'`. `shared.job` or `booking.job` missing, or no
  `shared.rerun_wave`, is a WARNING, not busy. A table the runner cannot read counts as busy.
- **Busy** = any queued row (any `run_after`; `due` counts the ones already claimable) or running
  row of a kind that is not exempt, or an open wave. Same meaning as the deploy gate.
- **Exempt kinds** (`IDLE_EXEMPT_KINDS` in `run_migration.py`, per owner): `booking.job`
  `bk_inquiry_pull` (always queued at +60 s, Booking `intake.RECURRING` in
  `backend/app/inquiry/intake.py`; a Booking `DEPLOY_GATE_EXEMPT` registry arrives with B4). It runs
  short transactions, so a running one is safe too; `shared.job` has none since AA-751 (S240): the
  every-5-minutes `ops_rds_role_connections` kind was removed when the CIS api started publishing
  its metrics in process (CIS registry `deploy_gate_exempt` lists nothing). `lock_timeout 5s` is
  the backstop. Daily retention kinds are not exempt. The list mirrors the owners' registries until X1 (`owners.yaml`):
  change it together with them.
- **check** only reports and exits 0. **apply** (once the version is known to be unapplied, so an
  already-applied file still skips) re-checks 3 times, 20 s apart, and exits **7** while anything
  is still busy. Run `check` first: a destructive apply takes its RDS snapshot before the task
  starts, so a refusal wastes one snapshot.
- **Override:** the workflow input `override_busy_jobs` (one line, at most 200 characters, a
  reason; Nghiệp only, dispatch stays behind `environment: prod`) reaches the task as
  `MIGRATION_IDLE_OVERRIDE`. The run then logs `MIGRATE WARNING: idle check OVERRIDDEN (<reason>)`
  with the busy list and applies without waiting. The reason is also in the job summary.

## Schema reference (AA-807 N1)
`schema_dump.py` runs in a one-off ECS task like the runner, read-only (`default_transaction_read_only`
+ one `REPEATABLE READ READ ONLY` transaction, `statement_timeout 60s`, `lock_timeout 10s`). It
dumps catalog metadata (no row values): columns, indexes, CHECK/FK constraints, RLS policies,
table and column grants, owners, default privileges, roles + memberships (allow-listed settings
only), functions, extensions, enums, sizes, `pg_stat_user_tables` activity and sessions per
`application_name`, plus `shared.schema_versions`, plus the orphan counts of cross-app soft keys (data standards
DM-4.2, AA-830: `SOFT_KEY_CHECKS`, aggregate counts only, each check skipped as `not_applicable` until its owner's
migration is applied; first check `booking.trip_case_legs (source_system, source_id)` against `catalog.v_tour`,
bk-011). Orphans raise a workflow warning, never a failure. JSON goes to
`s3://aa-cis-bronze-005097885195/db-schema-dump/<run id>/schema.json` (and `latest.json`) and the
run artifact. `gen_schema_reference.py` renders the Markdown; its `schema-fingerprint` (hash of the
dump without row counts, sizes and counters) decides whether the root PR is opened or updated, so
statistics alone never open a PR. Local render: `python3 db/gen_schema_reference.py schema.json
--out /tmp/ref.md`. The workflow needs the secret `ROOT_REPO_DOCS_TOKEN` (see its header).

## Rules
- Every file self-registers: `INSERT INTO shared.schema_versions ... ON CONFLICT DO NOTHING`,
  inside its own `BEGIN; ... COMMIT;`.
- The owner repo keeps the identical original (`AA-CIS-App/api/migrations/`,
  `AA-TripPlanner-Web/migrations/`, `AA-Booking/migrations/`); this folder holds the copy the
  workflow applies, checked byte for byte against the owner's `main`. Infra itself
  owns no schema: its only own SQL is `roles/` (roles, extensions, undo files of X1 transfers, DM-1.7).
  Apply the migration **before** merging app code that depends on it.
- Destructive changes follow the DRY RUN procedure (`skill/aa-cis-schema/references/destructive-ops.md`).
