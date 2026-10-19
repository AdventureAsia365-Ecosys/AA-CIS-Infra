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
- **Read-only scripts** declare one top-level `READ_ONLY = True`. The runner then opens the session with
  `default_transaction_read_only = on` (any write fails with SQLSTATE 25006) and the idle check only
  reports (no wait, no exit 7). The shape check refuses a READ_ONLY file with a string literal
  that mentions `transaction_read_only` or `READ WRITE` (docstrings and comments are not checked). It is still the master login: the flag is a declaration the
  session enforces, not a sandbox, so the review still reads the whole file.
- **Time limit:** the workflow waits 30 minutes for the task (3 × the ECS waiter). A script that runs longer
  keeps running after the job ends red with "still RUNNING"; split long work (e.g. one sampler snapshot per
  dispatch) instead of looping inside one run.
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
   run proceed and is logged. A `READ_ONLY = True` script skips the wait (report only).
5. The script's output is in the job log (every page of the task's CloudWatch stream
   `migrate/migrate/<task id>`). If the script raises, the error line is redacted for the master DSN.
   A successful run dispatches DB Schema Dump and DB Isolation Probe, as an apply does.

Exit codes of the task: 0 ok · 2 sha256 mismatch · 7 busy · 8 not the master · 10 bad path or shape ·
13 the script raised or returned non-zero.

**After X1 S22** the task's `DATABASE_URL` becomes `db_migrator`; run-script (like set-password) then
needs the runner to open its own master connection from `aa-cis/dev/rds` (plan S22 runner change). Until
that change lands both modes exit 8 under the `db_migrator` login.

`x1_connection_snapshot.py` (X1 S15, AA-860, read-only): one snapshot of client sessions per role /
`application_name` / state, each login role's `rolconnlimit` and `max_connections`, for the `cis_app` limit
decision before S18; dispatch it 2–3 times (busy and idle).

`x1_photo_itinerary_parity.py` (X1 S15, AA-860, read-only): per country, distinct (tour, destination) pairs of
the old photo-sync itinerary read (`tripplanner.*`) vs the new one (`geo.*`), with overlap; counts only.

`session_info.py` is a read-only smoke test (prints `session_user`, database, server version and the
session settings): use it to check the mode after a change to the runner or the migrator task definition.
