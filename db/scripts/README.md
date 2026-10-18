# db/scripts/ — master-level scripts run by DB Migrate `mode=run-script` (X1 S12)

RDS is VPC-private. CIS-scope one-off work keeps the S3-mediated ECS-exec pattern in the api container
(after X1 S18 it runs as `cis_app`). Anything that needs the RDS master — `booking.*` / `tripplanner.*`
data, role or catalog work, a fix across owners — goes through a **reviewed file here**, run by the
**DB Migrate** workflow (`.github/workflows/db-migrate.yml`), not through ECS exec. X1 S19 removes the
CIS task role's access to the master secret, so from then on this is the only master path besides a
migration (plan XD5).

A migration changes the schema and registers a `shared.schema_versions` key; a script here does not
register anything. If the change should exist in every environment, or should replay in CI, it is a
migration in its owner repo, not a script.

## Contract
- Path `db/scripts/<name>.py`, `<name>` = lower case letters, digits, underscores.
- A top-level `async def main(conn)` with exactly one argument. The runner awaits it with an asyncpg
  connection logged in as the master (`aa_cis_admin`), session settings `lock_timeout = '5s'`,
  `statement_timeout = '15min'`, `application_name = 'db-migrate'`. Return `None` or `0` for success;
  any other value or an exception fails the run (exit 13).
- The connection is in autocommit. Use `async with conn.transaction():` for anything that must be
  atomic; a script may `SET LOCAL lock_timeout = …` inside its own transaction.
- Standard library + what the CIS api image has (asyncpg, boto3). No app imports. The task role reads
  only the DSN secrets listed in `accounts/aa365/db_migrator.tf` and may put only `db-schema-dump/*`
  in the bronze bucket: a script cannot call Bedrock, read other secrets or write elsewhere.
- Print aggregate counts, ids and statuses only: no secret, DSN, password or customer row values (the
  task log is readable in the Actions run). A line prefix such as `SCRIPT ` keeps the output easy to grep.
- Destructive data changes follow the DRY RUN procedure (`skill/aa-cis-schema/references/destructive-ops.md`):
  a dry-run script first (counts only), then the change as a separate reviewed script or a flag in the
  same PR. `run-script` takes **no RDS snapshot**; take one by hand before an irreversible change.
- Script that calls an LLM: not here (workspace rule: adhoc LLM scripts go through `LLMClient` and
  `shared.llm_call_log`, which the migrator task cannot reach).

## Flow
1. PR adds the file here (human review = the approval). CI: the DB Migrate "Validate input" step and
   `python3 db/run_migration.py --inspect-script db/scripts/<name>.py` check the shape.
2. Merge to `main`.
3. Dispatch **DB Migrate** on `main`: `mode=run-script`, `script=db/scripts/<name>.py`
   (`migration` and `role` empty). The workflow folds it into the task's `MIGRATION_MODE` value
   (`run-script:db/scripts/<name>.py`), uploads the file next to the runner (presigned URL + sha256,
   like a migration) and runs the migrator task.
4. Before `main(conn)` the runner checks that it is logged in as the master (exit 8 otherwise) and runs
   the same **idle check** as `apply`: every owner job table and open `shared.rerun_wave`, 3 re-checks
   20 s apart, then exit 7 while anything is busy. `override_busy_jobs=<reason>` (Nghiệp only) lets one
   run proceed and is logged.
5. The script's output is in the job log (and the task's CloudWatch stream `migrate/migrate/<task id>`).
   A successful run dispatches DB Schema Dump and DB Isolation Probe, as an apply does.

Exit codes of the task: 0 ok · 2 sha256 mismatch · 7 busy · 8 not the master · 10 bad path or shape ·
13 the script raised or returned non-zero.

`session_info.py` is a read-only smoke test (prints `session_user`, database, server version and the
session settings): use it to check the mode after a change to the runner or the migrator task definition.
