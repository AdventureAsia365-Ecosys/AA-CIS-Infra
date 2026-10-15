# db/ — migrations applied to the shared RDS (acc2)

RDS is VPC-private, so migrations are applied by the **DB Migrate** workflow
(`.github/workflows/db-migrate.yml`): it starts a one-off ECS Fargate task from the CIS api task
definition, which downloads `run_migration.py` and the SQL via presigned S3 URLs and runs it
with the task's own `DATABASE_URL`.

```
db/migrations/<owner>/<NNN>_<name>.sql   # owner = cis | tripplanner | booking
```

Version key registered in `shared.schema_versions`: `cis` → `NNN`, `tripplanner` → `tp-NNN`,
`booking` → `bk-NNN` (ownership rules: `AA-Ecosys/docs/database/schema-ownership.md`).

## Flow
0. The owner repo merges a **migration-file-only** PR to its `main` first (S237 D8). Code that
   reads the new objects comes in a later PR, after the apply.
1. PR adds the SQL here as a byte-identical copy (`cp` the owner file; human review = the
   approval). **Migration Copy Guard** (`.github/workflows/migration-copy-guard.yml`, AA-807)
   compares each added/changed file with the owner's `main` through the GitHub API and fails on:
   a path DB Migrate would refuse, a missing or wrongly prefixed `shared.schema_versions` key, a
   file not on the owner's `main` yet ("merge the migration-only PR in the owner repo first"), or
   any byte difference. It also runs nightly over every copy. Local run:
   `GH_TOKEN=$(gh auth token) python3 db/check_migration_copies.py db/migrations/cis/228_x.sql`
   (or `--all`; without a token GitHub allows 60 anonymous requests/hour); tests:
   `python3 -m unittest discover -s db/tests`.
2. Merge to `main`.
3. Run **DB Migrate** on `main` with `mode=check` (prints whether the version is registered and
   the latest key of the same owner), then `mode=apply`. The job fails unless the task exits 0 and
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
  snapshot `db-migrate-<version>-<run id>` of `aa-cis-dev-db`, waits until it is available and
  passes its id to the task; the runner refuses a destructive apply without it (exit 5). The DRY
  RUN procedure still applies. Delete the snapshot by hand once the contract is confirmed.
- **Lint** (same code in CI, in the DB Migrate "Validate input" step and in the task): unknown or
  misplaced directives, `CONCURRENTLY` without no-transaction, destructive statements without the
  header and transaction control in a no-transaction file are errors; `DELETE` without the header
  is a warning. Local: `python3 db/run_migration.py --inspect db/migrations/cis/241_x.sql`.
- **Unique numbers** (MIG-3): `db/check_migration_files.py` fails when two files in one owner dir
  share a number (CI job "Migration lint and unique numbers").
- Exit codes: 2 sha256 mismatch, 3 not registered, 4 lint error, 5 destructive without snapshot,
  6 PostgreSQL error (lock or statement timeout prints a hint).

## Schema reference (AA-807 N1)
`schema_dump.py` runs in a one-off ECS task like the runner, read-only (`default_transaction_read_only`
+ one `REPEATABLE READ READ ONLY` transaction, `statement_timeout 60s`, `lock_timeout 10s`). It
dumps catalog metadata only (no row data): columns, indexes, CHECK/FK constraints, RLS policies,
table and column grants, owners, default privileges, roles + memberships (allow-listed settings
only), functions, extensions, enums, sizes, `pg_stat_user_tables` activity and sessions per
`application_name`, plus `shared.schema_versions`. JSON goes to
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
  owns no schema. Apply the migration **before** merging app
  code that depends on it.
- Destructive changes follow the DRY RUN procedure (`skill/aa-cis-schema/references/destructive-ops.md`).
