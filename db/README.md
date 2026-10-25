# db/ — migrations applied to the shared RDS (acc2)

RDS is VPC-private, so migrations are applied by the **DB Migrate** workflow
(`.github/workflows/db-migrate.yml`): it starts a one-off ECS Fargate task from the **migrator task
definition** `aa-cis-dev-db-migrate` (X1 S12; `accounts/aa365/db_migrator.tf`), which downloads
`run_migration.py` and the SQL via presigned S3 URLs and runs it with the task's own `DATABASE_URL`:
**`db_migrator`** since X1 S22 (`aa-cis/dev/db-migrator`; the master DSN before). `db_migrator` runs every
owner-dir file as the live owner of its anchor schema (`cis_owner`, `bk_owner`, `tp_owner`, `crm_owner`). The RDS master
is kept for three things only, and the runner reads its DSN itself, in the task, from `aa-cis/dev/rds`
(`owners.yaml` `master_secret`; the migrator **task** role may read it, the execution role no longer injects
it): `roles/` files (role bootstrap, extensions, undo files), `mode=set-password` (`ALTER ROLE … PASSWORD`
needs CREATEROLE) and `mode=run-script`. Those runs log `master login: in-task DSN from aa-cis/dev/rds`.

Migrator task (DB Migrate, DB Schema Dump, DB Isolation Probe, DB Tour Liveness Gate): `.github/scripts/migrator-task.sh prepare`
registers a revision of the family copied from its latest ACTIVE revision with only the image replaced by
the image the CIS api service runs now (roles, secret, logs, cpu/memory unchanged); the task runs in the
api service's subnets with the security group `aa-cis-dev-sg-db-migrate`, container `migrate`, log stream
`migrate/migrate/<task id>`; the last step deregisters the revision (`if: always()`).

Two more DB Migrate modes (X1 S12): **`set-password`** (input `role`: `cis_app` or `db_migrator`,
`owners.yaml` `password_roles`) sets the role's password from the DSN Nghiệp wrote in its secret: the
task reads the secret itself, sends only a SCRAM-SHA-256 verifier, test-connects and marks the role
`x1:password-set …` (plan XD2; nothing secret is logged). **`run-script`** (input `script`) runs a reviewed
`db/scripts/<name>.py` as the master after the apply idle check: `db/scripts/README.md`.

```
db/migrations/<owner>/<NNN>_<name>.sql   # owner = cis | tripplanner | booking | crm | roles
db/owners.yaml                           # owner registry (X1, DM-1.2)
```

Version key registered in `shared.schema_versions`: `cis` → `NNN`, `tripplanner` → `tp-NNN`,
`booking` → `bk-NNN`, `crm` → `crm-NNN` (partner CRM, AA-Partner, AA-932), `roles` → `rl-NNN` (ownership rules: `AA-Ecosys/docs/database/schema-ownership.md`).

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
(`OWNERS`, `PATH_RE`), `db-migrate.yml` (dir regex, key prefixes, `environment` choices) or
`isolation_probe.py` (`OWNERS`: schemas, anchor schema, owner role, `owner_transfer_key`,
`runtime_secrets`, view owners, `runtime_privileges[_from]`; `CONSUMER_GRANTS`;
`RLS_ENABLE_ONLY_ALLOWLIST`) disagrees with `owners.yaml`. Change them in the same PR.

### Adding an owner (ADR 0008 playbook, AA-826 dry run)
Proven by the never-merged branch `test/add-owner-dry-run` (fake owner `dryrun`, prefix `dr-`): with only the
`owners.yaml` entry, the registry test, the roles test and the DB Migrate validate-step test go red and name every
mirror below; with the mirrors they are green. In order:
1. **AA-CIS-App first:** `tests/integration/rls_catalogue_rules.py` `SCHEMA_OWNERS` (the owner's schemas) and
   `ROLE_OWNERS` (owner + runtime roles). `db/rls_catalogue_rules.py` here is its byte copy (Copy Guard
   `CODE_COPIES`), so the Infra PR copies it after the CIS PR merges.
2. **Infra PR:** the `owners.yaml` entry; `migrator_member_of` + the owner role; `password_roles` + the runtime role
   (DB Migrate `mode=set-password`); then the mirrors: `run_migration.py` (`OWNER_DIRS`, `IDLE_EXEMPT_KINDS` when the
   owner has a job table, `PASSWORD_ROLES`), `check_migration_copies.py` (`OWNERS`, `PATH_RE`), `db-migrate.yml`
   (dir regex, key-prefix `case`, set-password role regex), `isolation_probe.py` (`OWNERS`, `VERSION_KEYS` with the
   transfer key, `KEY_TEXT` for the key and `<owner>_transferred`), the copied `rls_catalogue_rules.py`, and
   `check_retention_rows.py` `RETENTION_OWNERS` (a new app's tables need DM-7 rows from day one, AA-929).
3. **Role bootstrap** in the same PR, rendered from `db/templates/new_owner_roles.sql.tmpl`:
   ```
   python3 db/templates/render_new_owner_roles.py --number NNN --owner <dir> --owner-role <app>_owner --runtime-role <app>_app --schema <anchor> --key-prefix <xx-> --conn-limit <n> --issue AA-NNN > db/migrations/roles/NNN_<app>_roles.sql
   ```
   It creates
   the owner role (NOLOGIN), the runtime role (LOGIN, CONNECTION LIMIT, no password) and the **empty anchor schema
   owned by the owner role**, so the owner's first file already runs as the owner role (live-owner switch, XD8).
   Without it the runner finds no anchor schema and runs that file as the DB Migrate login, which would then own
   the objects it creates. Apply it (DB Migrate `apply roles/NNN_…`) before the owner's first file.
4. Nghiệp writes the runtime role's DSN secret by hand, then DB Migrate `mode=set-password`.

### Owner `crm` (partner CRM, AA-932)
The first owner added through the playbook above. AA-Partner owns `crm` (ADR 0010, root ADR 0008a): owner role
`crm_owner` (NOLOGIN), runtime `crm_app` (LOGIN, CONNECTION LIMIT 6, NOINHERIT; pool 3 in `connection_budget.json`),
four NOLOGIN roles `crm_app` reaches only by `SET LOCAL ROLE` (`crm_ai_reader`, `crm_insights`, `crm_support_reader`,
`crm_eraser`; `owners.yaml` `nologin_roles`), key `crm-NNN`, job table `crm.job`, kinds `crm_*`. Born under its owner
role, so there is no ownership transfer: `owner_transfer_key` is `crm-001`. Apply order on Dev:
`roles/003_crm_roles.sql` (rl-003) → `roles/004_crm_nologin_roles.sql` (rl-004) → CIS 269 (crm_owner may register
`crm-` keys) → `crm/001_crm_schema_job.sql` (crm-001, copy of AA-Partner `api/migrations/001_crm_schema_job.sql`,
which must be on AA-Partner `main` first) → Nghiệp writes the `crm_app` DSN in `crm/dev/database-url` → DB Migrate
`mode=set-password` role `crm_app`. No cross-schema grant in either direction (ADR 0008a decision 1): the isolation
probe asserts 42501 for `crm_app` on `booking.*`, `tripplanner.*`, `shared.*` and for every AA app role on `crm.job`.

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
   The same apply also dispatches **DB Isolation Probe** (see "Isolation probe" below).

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
  RUN procedure still applies. The snapshot is tagged `aa:retain-until` = today + 30 days (UTC); the
  daily `rds-snapshot-expiry` Lambda (`accounts/aa365/rds_snapshot_expiry.tf`, AA-869) deletes it
  after that date (once its `DRY_RUN` is `false`). Do not delete it by hand: it is the undo path for
  30 days. To keep it longer, move `aa:retain-until` forward or tag `aa:retain=keep`.
- **Lint** (same code in CI, in the DB Migrate "Validate input" step and in the task): unknown or
  misplaced directives, `CONCURRENTLY` (except `REFRESH MATERIALIZED VIEW CONCURRENTLY`) or `VACUUM`
  without no-transaction, destructive statements without the
  header and transaction control in a no-transaction file are errors; `DELETE` without the header
  is a warning. Local: `python3 db/run_migration.py --inspect db/migrations/cis/241_x.sql`.
- **Role lint** (X1, owner files numbered at or above `role_lint_from`: CIS 243, bk-014, tp-013, crm-001;
  applied files never re-run and 225/229/235/237/239/241 use the pre-X1 patterns): no `RESET ROLE`
  (it returns to the login role, which after X1 S22 is `db_migrator`), no `SET ROLE` / `SET SESSION
  ROLE` / `ALTER FUNCTION … SET role` (only `SET LOCAL ROLE`; `"role"` quoted counts), no SESSION
  AUTHORIZATION in any form, no `set_config('role', …)` and no `set_config()` whose name is not a
  plain literal (`E''`/`U&''` literals are read), no role switch or role DDL in dynamic SQL (`EXECUTE`:
  each string piece of the statement, the pieces joined, `format()` filled in, and half-keyword pieces
  like `'RESET ' || 'ROLE'` are refused), no `CREATE/ALTER/DROP EXTENSION` or `ROLE` and no role
  membership `GRANT r TO x` / `REVOKE r FROM x` (all → `roles/`). `SET LOCAL ROLE` only to the dir's
  `set_local_roles`: `cis/` `catalog_owner`, `cis_owner` (the way back), `cis_app` (guard blocks);
  `booking/`, `tripplanner/`, `crm/` none. Checked in DO blocks and function bodies too; comments and ordinary
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
- **PII class lint** (data standards DM-6.1, v1.3, AA-929): the same job fails a copy whose
  `COMMENT ON COLUMN … IS 'pii:<class>…'` / `'conf:<class>…'` names a class that is not in
  `gen_schema_reference.TAG_CLASSES` (`contact`, `name`, `address`, `profile`, `online_id`, `free_text`,
  `travel`, `payment`, `government_id`, `health`, `emergency_contact`; `conf:commercial`, `conf:credential`).
  A comment that names a tag without starting with one is a warning. Not in `run_migration.py` (the
  task gets the runner alone), so DB Migrate itself does not repeat it.
- **Ownership lint** (data standards DM-1.2 / DM-8.1, AA-853, `db/check_migration_ownership.py`): the same job
  fails an owner-dir copy that creates, alters, drops, comments on, grants on or writes to an object outside its
  owner's schemas (`owners.yaml` `schemas`, mirrored by `run_migration.OWNER_DIRS`). Read per statement and inside
  DO blocks: CREATE/ALTER/DROP of schemas, relations, functions, types, indexes / triggers / policies / rules (their
  table), `SET SCHEMA`, `COMMENT ON`, `GRANT`/`REVOKE … ON`, `ALTER DEFAULT PRIVILEGES … IN SCHEMA`, and the writes
  `INSERT`/`UPDATE`/`DELETE`/`MERGE`/`TRUNCATE`/`COPY … FROM`/`REFRESH MATERIALIZED VIEW`, top-level
  `SELECT … INTO <table>`, `ATTACH`/`DETACH PARTITION` and `CREATE EXTENSION … SCHEMA`. Global
  `ALTER DEFAULT PRIVILEGES` (no `IN SCHEMA`) and `REASSIGN OWNED BY` pass only for the dir's own owner role;
  `DROP OWNED BY` always fails (all three belong in `roles/`). Allowed: the file's own
  `INSERT INTO shared.schema_versions`, temporary objects, and every read (views over another owner, `REFERENCES`,
  function calls). An unqualified name resolves through the file's own `SET [LOCAL] search_path` (`RESET` clears
  it), else it is a finding (it would land in `public`). As in PostgreSQL only a CREATE lands in the first schema of
  the path; any other unqualified name is a finding when the path also names another owner's schema, unless the file
  created that name itself. This is a static lint at copy time: function bodies and dynamic SQL (`EXECUTE`) are
  not read, and the X1 owner-role switch of DB Migrate stays the runtime boundary; the CLI
  (`python3 db/check_migration_ownership.py FILE`) prints a note for each DO block with dynamic SQL. `roles/` is not
  checked. Every copy on `main` passes; on the owners' full history it finds the known cases (TripPlanner
  `002_shared_destinations.sql` / `005`, CIS `122`'s `public.*` drops, CIS `001`–`007` before the owner split).
- **Retention rows** (DM-7.1, AA-929): `db/check_retention_rows.py` (CI job "Retention rows for new-app
  tables") fails when a table created by a copy in a new-app dir (`RETENTION_OWNERS`, today `crm`) has no
  row in the retention table of data standards Part B §7, read from the root repo's `master` with a
  Contents-read token of the GitHub App `aa-ecosys-ci-bot`. Merge the root row first, then the Infra copy. The cis/booking/tripplanner
  dirs are grandfathered (DM-7.1); a new app's dir is added to `RETENTION_OWNERS` with its
  `owners.yaml` entry.
- Exit codes: 2 sha256 mismatch, 3 not registered, 4 lint error, 5 destructive without snapshot,
  6 PostgreSQL error (lock or statement timeout prints a hint), 7 apply refused because a job
  table is busy or a rerun wave is open, 8 role refused, 9 ownership post-check failed (or the
  check after COMMIT found something that ran at COMMIT).

## Role per file (X1 plan S1, XD8)
Before each file (check and apply) the task reads the **live owner of the dir's anchor schema**
(`cis/` → `shared`, `booking/` → `booking`, `tripplanner/` → `tripplanner`, `crm/` → `crm`) and logs
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
- `roles/` files run only when the login role is the master (`master_role`), else exit 8. Since X1 S22
  the task's login is `db_migrator`, so the runner opens the master session from `master_secret` first
  (unreadable, empty or failing secret → exit 8, nothing ran).
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
  `crm.job` `crm_heartbeat` (AA-932: the AA-Partner worker's always-queued liveness kind, so no CRM job blocks a
  CIS / Booking / TripPlanner apply; AA-933 registers it under this name) and `crm_membership_pull` (AA-978: the
  CIS membership feed pull, re-queued every 20 s, short transactions; in AA-Partner `DEPLOY_GATE_EXEMPT`);
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
--out /tmp/ref.md`.

Column tags (data standards DM-6.1, AA-877): the dump keeps each column's raw comment (`comment`, no parsing in the
ECS task); `gen_schema_reference.parse_tag` reads its leading `pii:<class>` / `conf:<class>` tag plus any further tags
named in the text (`also`; forms `'<tag>; text'`, `'<tag> — text'`, bare `'<tag>'`). An older dump without `comment`
still renders (no tags). The reference renders the tag after the column
(`email text · pii:contact`) and a section *Personal and confidential data tags (DM-6.1)*: counts per schema and
tag, every tagged column, findings (unknown class, a tag not at the start) and the **untagged candidates** of
`booking` and `tripplanner` (column name contains a token of `PII_CANDIDATE_TOKENS`, not on `PII_ALLOWLIST`, both in
`gen_schema_reference.py`). The free comment text stays in `schema.json` only; the fingerprint hashes the tags and
the candidate outcome, so rewording an untagged comment opens no PR, while a new tag or an allowlist change does. The tagged-columns table is the input of the
AA-Ecosys RoPA generator (`tools/data/gen_pii_inventory.py` → `docs/legal/register.md` section (a)).

Generated ERD (AA-894 part 1): `gen_erd.py` renders, from the same JSON, one Mermaid `erDiagram` page per schema
plus an index (root `docs/architecture/erd/<schema>.md`, `README.md`; catalog `APP-04-erd*`, `generated: true`) and
`erd.json` (schemas, tables, columns with full types, PK, unique keys, FKs, DM-6.1 tags, owner app and role; no row
data, no comment text, no grants). The pages hold nothing volatile, so they change only with the structure, and the
root PR is opened when the reference fingerprint moved **or** an ERD page differs from master. Primary keys come
from the `is_primary` index definition (the dump keeps only CHECK and FK constraints); schemas over 20 tables or
150 columns show key columns only. The publish step replaces only pages whose front matter names this workflow
as `generator`, so hand-written files under `docs/architecture/erd/design/` are never touched. `erd.json` is in the
run artifact; with the repo variable `ERD_S3_UPLOAD=true` (default off) it also goes to
`s3://<bronze>/db-schema-dump/erd/latest.json` (and `previous.json` keeps the model before the last change).
Local render: `python3 db/gen_erd.py schema.json --out-dir /tmp/erd --json /tmp/erd.json`. Mermaid ER keywords
(`one`, `many`, `to`, `u`, `erDiagram`, ...) are quoted as table names and a column named `pk`, `fk` or `uk` is
written `pk_` (the attribute-key words); `erd.json` keeps the real names.

Schema drift against a replay (AA-853, data standards MIG-5; report only): after the dump job, a separate `drift` job
(no environment, no id-token, no secrets; the replay capped at 15 min) starts a throw-away
`pgvector/pgvector:0.8.1-pg15` container (pinned by its image index digest) on the runner, clones the owner repos (public, anonymous, `main`) and runs
`db/replay_migrations.py`: role bootstrap (the master `aa_cis_admin` as RDS has it, LOGIN CREATEROLE CREATEDB, not a
superuser, in a stand-in `rds_superuser`; live roles no migration creates, made by the master; the live extensions,
made by the superuser), then every applied file in live `shared.schema_versions` order with `run_migration.py`'s own
role logic (master login, `db_migrator` from the X1 S22 cutover, the live-owner switch with its ownership post-check;
legacy files without a registry row and owner-decided baseline files run like `psql -f`, one statement at a time),
then `schema_dump.collect` on the result. Gap fills (S251) keep one lost file from failing everything after it:
a live role whose creating file failed is created (live attributes, no password) before the next file; a failed X1
ownership transfer (CIS 245, bk-014, tp-013) is followed by its ownership effect (schemas and the master's objects to
the live owner), so later files still run as the owner like on Dev; back-registered registry rows (`backfill: …`)
are moved by `replay_order` decisions to where the evidence says they ran. Every fill is listed in `replay.notes`;
the failed file's other effects stay a gap. PostgreSQL 15 only (16 changed CREATEROLE: rl-001 / rl-002 refuse). No AWS credential or token exists in that job. `db/schema_drift.py` diffs the two dumps
(schemas, relations, columns, indexes, CHECK/FK constraints, policies, triggers, functions, enums; owners and grants
separately, informational): **unmanaged** (on Dev, no migration makes it), **missing**, **changed**; children fold into
their relation, each finding names the failed replay files whose DDL would have made it (`explained_by`; files that
only name it are `mentioned_by` and do not explain it: `unexplained` counts what is drift on Dev to decide), the root
gaps (`replay.gap_roots`: objects failed files needed that no file in any repo creates) and its owner decision
from `db/schema_drift_decisions.json` (`decisions`: finding id or glob, decision, ref; `replay_order`: back-registered
files moved before a registry key, with the evidence; `baseline`: SQL files under
`db/replay_baseline/` run as the master before a registry key, for history no repo holds any more, such as the
AA-ACP-Core lineage of `acp_*`). `gen_schema_reference.py --drift drift.json` renders the *Schema drift* section and
a `drift-fingerprint` marker (in the `publish` job, which holds the App token and no AWS credential); a changed drift
fingerprint opens the root PR like a structural change. Findings a replay gap explains (`explained_by`) are left out of
the fingerprint, so replay noise alone opens no PR (they stay in the section). The drift job and its steps are
`continue-on-error`: a failed replay never blocks the dump, the reference or the PR, and the publish job then carries
master's drift section and marker over unchanged (`--keep-drift-from`), so the section never flaps. Nothing fails
on a finding: fail-on-unmanaged (MIG-5) waits for the baseline file and the owner decisions. `drift.json`,
`replay-results.json`, `replay-schema.json` and `replay.log` are in the run's `db-schema-drift-<run id>` artifact. Local run (a FRESH PostgreSQL 15
with pgvector; roles are cluster-wide):
`python3 db/replay_migrations.py --live schema.json --admin-dsn postgresql://postgres:x@localhost:5432/postgres --source roles=db/migrations/roles --source cis=../../apps/AA-CIS-App/api/migrations --source booking=../../apps/AA-Booking/migrations --source tripplanner=../../apps/AA-TripPlanner-Web/migrations --source crm=../../apps/AA-Partner/api/migrations --out results.json --dump replay.json`
then `python3 db/schema_drift.py schema.json replay.json --replay-results results.json --out drift.json`.

Design ERD drift (AA-894 scope 3): `check_erd_drift.py` compares the hand-written design pages of the root repo
(`docs/architecture/erd/design/<schema>.md`, marker `<!-- erd-design schema=<s> enforce=<bool> implied-fk=<col>:<table> -->`)
with `erd.json`: tables missing or extra, primary keys that differ, FK edges missing or extra (an edge is the child
table, its FK columns and the parent; the design writes the FK columns as the relationship label). The DB Schema Dump
runs it after the root PR step and writes the report to the step summary. A schema with no relations is "not live
yet" and passes; drift fails the step only when the design page says `enforce=true`. Local run:
`python3 db/check_erd_drift.py /tmp/erd.json ../../docs/architecture/erd/design` (from the workspace checkout).

The workflow needs the GitHub App `aa-ecosys-ci-bot`: repo variable `AA_CI_BOT_APP_ID` and repo secret
`AA_CI_BOT_PRIVATE_KEY` (see its header).

## Isolation probe (X1 plan S2, U-16)
**DB Isolation Probe** (`.github/workflows/db-isolation-probe.yml`, nightly 04:13 UTC, manual, and
dispatched by DB Migrate after every apply) runs `isolation_probe.py` in a one-off ECS task like the
dump (the migrator task definition `aa-cis-dev-db-migrate`, X1 S12). Read-only: READ ONLY transactions, rolled back, every probe
statement in a savepoint (locks released at once), counts and names only, tenants labelled
`master`/`t1`/…, never by id. Its configuration is one JSON argument (no new env var).

- **Isolation evidence only from the role under test:** it logs in as `aa_app_user`, `booking`,
  `tripplanner`, `cis_app` (from X1 S17) and the CIS runtime (the secret the running api task
  definition injects) **with each role's own DSN secret** (`owners.yaml` `runtime_secrets`). The task's
  own database login (master until X1 S22, then `db_migrator`) reads only the catalog: it is a member
  of owner roles (and `db_migrator` of `catalog_owner`), so its rows are never tenant evidence.
- **Cells:** runtime role attributes (LOGIN; no SUPERUSER, BYPASSRLS, CREATEROLE — on PG 15 a CREATEROLE
  role can grant itself any owner role —, CREATEDB, REPLICATION), membership chain (no `rds_superuser`,
  `pg_read_all_data`,
  `pg_write_all_data`, master, `*_owner`), owned objects, connection limit; owner roles NOLOGIN;
  logins; cross-app reads raise 42501 (`booking` → `tripplanner.sessions`, `shared.tenants`;
  `tripplanner` → `booking.customers`; `aa_app_user`, `cis_app`, CIS runtime → `booking.customers`,
  `tripplanner.sessions`); every object of each owner's schemas owned by its `owner_role` (view owners
  on views only); **runtime grants** — each runtime role (`runtime_privileges`) has USAGE on its
  schemas, SELECT on every relation, USAGE on every non-identity sequence, EXECUTE on every non-trigger
  function — and **default privileges** FOR ROLE <live owner of the anchor schema> in each schema
  granting it the listed table / sequence / function privileges, with no FOR ROLE master row left once
  transferred (the failure an owner transfer most likely causes: a runtime role without a grant on the
  next object, 42501 after deploy); contract consumer grants on single objects (`booking` →
  `tripplanner.v_inquiry_outbox`, `geo.name_norm`, `tripplanner` → `shared.llm_call_log` INSERT);
  `bk_owner`/`tp_owner` registry grants; `cis_app` cannot write
  `shared.schema_versions`; every ENABLE-without-FORCE CIS table has a permissive policy `TO cis_app`
  (or `rls_enable_only_allowlist`); `aa_app_user` tenant matrix (GUC unset / empty / forged / each
  tenant: 0 cross-tenant rows; the tenant column is `tenant_id`, else `owner_scope` (`tour_atoms`), and
  `quarter_plan_version` / `angle_gate_option` are judged by their plan / request (`PARENT_SCOPED`; an RLS table
  with neither is an error of the cell under a real tenant, never a silent pass); rows a pool policy shares with every
  tenant only for the AA master tenant id or `'platform'` (`SHARED_SCOPE_CONSTANTS`, `::uuid` or `::text`
  literal), never another tenant's id); the CIS runtime sees every `tenant_tour_versions` row without a GUC;
  `db_migrator` sessions below its limit − 1; no master session but break-glass.
- **Pending cells keyed to live state:** a cell that cannot pass before a later X1 step is `pending`
  until its key is true — a `shared.schema_versions` row (`rl-001`, `243`, `244`, `rl-002`); for the
  ownership, runtime-grant and default-privilege cells the transfer **in force**: `bk-014` / `tp-013` /
  `245` registered **and** the anchor schema (`booking`, `tripplanner`, `shared`) owned by the owner
  role — the fact DB Migrate's role switch reads, so a planned rollback (a `roles/` undo file; registry
  rows are never deleted) puts the cells back to pending instead of failing every night; `cis_app`
  grants from `244`; the running api task definition's database secret (`aa-cis/dev/rds-cis-app`,
  S18); a `cis_app` DSN in `aa-cis/dev/rds-cis-app` **and** the `x1:password-set` comment that DB
  Migrate `mode=set-password` (S12) writes on the role (between Nghiệp's Console edit and set-password
  the login fails with 28P01: pending + a workflow warning, not red); or a catalog login other than the
  master (S22). A pending cell that already passes is `ready`. Once its key is true a failure fails the job.
- **Output:** `PROBE header|cell|matrix|summary` lines in the task log → `probe.json` (artifact, 30
  days) and a step-summary table. Task exit 0 = no failing cell, 1 = a failing cell, 2 = could not run.
  Local dry run against a throwaway PostgreSQL: `python3 db/isolation_probe.py '{"dsn_file":
  "dsns.json", "ssl": "disable", "cis_runtime_secret": "<arn or name>"}'` (`dsns.json` maps secret
  names and `catalog` to DSNs).

## Tour liveness gate (AA-986 L7b, root ADR 0015 decision 6)
**DB Tour Liveness Gate** (`.github/workflows/db-tour-liveness-gate.yml`, nightly 04:43 UTC, manual) is the
regression gate of the tour liveness rule: when a tour is no longer served, nothing derived from it stays live. It
runs `scripts/s248_tour_deletion_probe.py` exactly as DB Migrate `mode=run-script` does (migrator task, the runner
`run_migration.py`, master login read in the task, `READ_ONLY`: `default_transaction_read_only=on`, idle check
report-only); the boot command also checks the runner's sha256. Then `tour_liveness_gate.py` reads the task log and
fails the job when the task did not exit 0, the run was not READ_ONLY, the probe printed no verdict,
`SCRIPT verdict violations>0` or `errors>0`, no catalog role (`booking`, `tripplanner`) could read
`catalog.v_tour`, a `SCRIPT json[i/n]` part is missing or cut short, or a check of a landed slice reports `pending`.
The probe's JSON is printed in parts of at most 8000 characters (`SCRIPT json[i/n] <part>|`; a container log line
over ~16 KB is split into several CloudWatch events) and the gate joins them. The step summary lists the violations, the layers that failed to run (exception class + SQLSTATE,
the server message only for class 42), every ADR 0015 check and the keep_warn hits; `task.log` + `gate.json` are the
artifact (30 days).

What the probe checks (details in its docstring and `db/scripts/README.md`):
- **Layers** per bucket of the AA master tenant's sources (dead groups, trashed and superseded versions, live sources
  not in the catalog): `catalog.v_tour`, AA-Booking plans / departures / B2B quotes and holds / trip cases,
  TripPlanner drafts; `expect` = `zero` (a violation), `keep_warn` (kept by design and reported: sold departures,
  confirmed holds, open trip cases, open drafts) or `info`.
- **Checks** (ADR 0015 decision 6), `SCRIPT check …` lines:

| check | slice | expect |
|---|---|---|
| `masters_active_in_one_group`, `master_active_over_dead_source` | L2 | zero |
| `catalog_key_not_served` (catalog serves a key `gold_aa_internal.v_tour_liveness` says is not served) | L2 | zero |
| `served_key_not_in_catalog` | L2 | info |
| `lifecycle_record_contradicts_state` (latest `tour_lifecycle_event` vs the derived state) | L2 | zero |
| `superseded_orphan_without_retired` (all-superseded group that had a Master, no lifecycle event; ADR 0015 decision 6) | L2 | zero |
| `not_served_without_record` (other reasons: state changed before L2 or outside the service) | L2 | keep_warn |
| `tombstone_disagrees_with_state` (`catalog.v_tour_retired` vs the derived state, keys with an event) | L4 | zero |
| `t2_rewrite_after_not_served` | L3 | keep_warn until `ENFORCED_SINCE["L3"]`, then zero |
| `b2b_quotes_after_not_served`, `b2b_holds_after_not_served` | L5 | keep_warn until `ENFORCED_SINCE["L5"]`, then zero |

- **Pending until the slice lands, then strict on its own:** a check whose object does not exist yet (read from
  `pg_class`, no privilege needed) prints `expect=pending` and never counts (`SCRIPT verdict … pending=<n>`).
  `LANDED` in the probe names the slices live on Dev (`{"L2"}` today): a missing object of a landed slice is an
  **error** (red), never pending, so a later migration that drops or renames `gold_aa_internal.v_tour_liveness` or
  `tour_lifecycle_event` turns the night red; the gate also fails when a landed slice's check reports `pending`.
  After the L4 deploy a one-line PR adds `"L4"` to `LANDED`. When L4
  creates `catalog.v_tour_retired` the tombstone check runs at once, read as the catalog role; a view without the
  columns `source_id` and `state` is an error (red), not a silent pass: the L4 PR updates `TOMBSTONE_SQL` if it
  picks other names. The "nothing new after the key stopped being served" checks need a refusal in the app, which
  no object shows, so they turn strict by a one-line PR: `ENFORCED_SINCE["L3"|"L5"] = "<YYYY-MM-DD>"` (the UTC date
  the slice went live on Dev); only rows created after that date and after the key's last state change count.
- **Visibility floor.** `raw_tours` and `published_tours` are FORCE RLS; the master login sees AA rows only through
  its `cis_owner` / `cis_app` membership, and without it every read returns 0 rows with no error, which would make
  every `zero` check pass. The probe records an error (red) when the login sees no AA source version, no active
  Master while `catalog.v_tour` lists tours, fewer source groups than `v_tour_liveness` (an owner-rights view) has
  keys, or fewer served keys than the catalog lists (`SCRIPT visibility …`, JSON `visibility`).
- Changing an answer of ADR 0015 = changing one `expect` value in the script's `LAYERS` / `CHECKS`.
- **Not covered yet (follow-up slice under AA-986):** the CIS and tenant layers of the S248 memo probe (atoms,
  ranking / routes, T2 copies, Slate, T8 angles, T9 pieces, T11 posts, warnings). They need a `cis_app` session
  (tenant RLS), not the master; until they are ported a green night says nothing about them. Today they are covered
  by the CIS lifecycle service's own tests and the L1 view condition.

A red night: read the summary table, find the key or id in the sample (ids and keys only), and fix the writer that
leaked (CIS `services/tour_lifecycle`, AA-Booking, TripPlanner), never the probe, unless the rule itself changed.
The master session lasts seconds and is the run-script use the isolation probe's `sessions.master_break_glass_only`
allows for; the nightly times keep the two apart. Cost: one Fargate task of about two minutes a night (under
$0.10 a month).

## Rules
- Every file self-registers: `INSERT INTO shared.schema_versions ... ON CONFLICT DO NOTHING`,
  inside its own `BEGIN; ... COMMIT;`.
- The owner repo keeps the identical original (`AA-CIS-App/api/migrations/`,
  `AA-TripPlanner-Web/migrations/`, `AA-Booking/migrations/`); this folder holds the copy the
  workflow applies, checked byte for byte against the owner's `main`. Infra itself
  owns no schema: its only own SQL is `roles/` (roles, extensions, undo files of X1 transfers, DM-1.7).
  Apply the migration **before** merging app code that depends on it.
- Destructive changes follow the DRY RUN procedure (`skill/aa-cis-schema/references/destructive-ops.md`).
