# AA-852 — X1 step S2: DB isolation probe workflow (U-16)

Plan: `AA-Ecosys/docs/audits/2026-10-17-S241-x1/x1-plan.md` §5 S2 (revision 2). One PR, no apply, no
AWS write: `db/isolation_probe.py` + `.github/workflows/db-isolation-probe.yml` (dispatch, nightly
04:13 UTC, dispatched by DB Migrate after every apply). Verify after merge = the first dispatch is green
with the pending cells listed.

## Decisions
- **Each role through its own login (plan + review A10).** The probe reads the DSN secret of every
  runtime role (`owners.yaml` new field `runtime_secrets`) and logs in as it: `aa_app_user`, `booking`,
  `tripplanner`, `cis_app` (secret `aa-cis/dev/rds-cis-app`, from S11/S17), and the **CIS runtime** =
  the secret the running api task definition injects as its database URL (read by the workflow with
  `describe-task-definition`, ARN only, passed to the task). Every cross-app read, RLS count and the
  tenant matrix run through those logins. The task's own login (master until S22) reads the catalog
  only; the probe never grants itself a role and never uses `SET ROLE`.
- **State keys are live, not PR numbers (B8):** `shared.schema_versions` rows (`rl-001`, `243`,
  `bk-014`, `tp-013`, `244`, `rl-002`, `245`), the api's database secret name (= `aa-cis/dev/rds-cis-app`
  → S18), the content of `aa-cis/dev/rds-cis-app` (a DSN whose user is `cis_app` → S17), the catalog
  login (≠ master → S22). Status per cell: `pass`, `FAIL`, `pending` (key false, may fail), `ready`
  (key false, already passes: informational). The plan's "fails when a pending cell already passes"
  rule is implemented for cells **without** a key (`pending_without_key`); no cell uses it today.
- **Cells beyond the plan's literal list** (same intent, cheap): `aa_app_user` → `booking.customers`,
  `tripplanner.sessions` (42501; the tenant pool is a CIS runtime role too); owner roles `bk_owner`,
  `tp_owner` (rl-001) and `cis_owner` (rl-002) NOLOGIN / no SUPERUSER / no BYPASSRLS; one login cell
  per role; the membership chain also rejects the master itself.
- **Ownership cell:** objects of the owner's `owners.yaml` schemas (schema, relations except indexes,
  functions, non-array non-row types; extension members left out) not owned by `owner_role`; the
  `view_owner_roles` (`catalog_owner`) are accepted **on views/matviews only** (stricter than the
  runner's post-check, which accepts them on anything a file creates).
- **Tenant matrix (aa817 shape):** for every RLS table of the CIS schemas, as `aa_app_user`, GUC
  `unset`, `''`, a forged random uuid, and each tenant of `shared.tenants`. Cross-tenant row = a non-NULL
  `tenant_id` that is neither the GUC tenant nor a constant tenant id found in a permissive SELECT/ALL
  policy reaching `aa_app_user` (`TO aa_app_user` or `TO public`: the AA master catalog, CIS 239).
  NULL `tenant_id` rows (platform `facts`) are not tenant rows. A table without `tenant_id`
  (`angle_gate_option`, RLS through its parent) counts every visible row as foreign under
  unset/empty/forged. `42501` (no SELECT for the pool) is "no access", not an error. Tenants are
  labelled `master`/`t1`/`t2`… in order of `created_at`; ids never leave the task.
- **CIS runtime `tenant_tour_versions` cell:** runtime count (no GUC) must equal a reference count by
  the catalog login taken just before **or** just after it (two short transactions), so a row inserted
  in between does not fail the cell.
- **Sessions:** master sessions other than the probe's own (`application_name = db-isolation-probe`)
  are `pending` + a workflow `::warning::` until S22, then a failure. `db_migrator` sessions < limit − 1
  (key rl-002).
- **Read-only and lock-safe:** `default_transaction_read_only`, READ ONLY transactions always rolled
  back, `statement_timeout 30s`, `lock_timeout 3s`; every user-table read runs in a savepoint that is
  rolled back, which releases its ACCESS SHARE lock at once, so a migration's ALTER never queues behind
  the probe.
- **No new env var (rule: underscore env vars are Nghiệp's hand edits).** The task gets one JSON
  argument (`sys.argv`), the runner command reads the presigned URL from `sys.argv[1]`; the only env var
  read in the task is the existing database URL of the task definition. The workflow reuses the
  existing names of the schema-dump workflow (`AWS_REGION`, `CLUSTER`, `SERVICE`, `BUCKET`, `LOG_GROUP`,
  `TASK_ARN`) and new shell variables without underscores (`APITD`, `RUNTD`, `CISSECRET`, `CONFIG`,
  `TASKID`, `TOKEN`).
- **Output through the task log, not S3:** `PROBE header|cell|matrix|summary` lines (each well under
  the 16 KB log-line split; the matrix is one record per table), paginated `get-log-events`, joined by
  jq into `probe.json` (artifact, 30 days) and a step-summary table. So the probe needs no S3 write
  (the S11 migrator task role's "probe-output prefix" is not needed; harmless if granted).
- **Registry mirror:** `owners.yaml` gains `owner_transfer_key` (`245`, `bk-014`, `tp-013`) and
  `runtime_secrets` (required for schema owners) and the optional `cis.rls_enable_only_allowlist: []`;
  `test_owners_registry.py` checks the shapes and that `isolation_probe.py` mirrors them.

- **Review round (S241), five fixes:**
  - **Runtime grants (new cells).** The failure X1 most likely causes is a runtime role losing a grant,
    not a cross-app read. `runtime_grants.<owner>`: as catalog facts (`has_*_privilege`, nothing runs
    as the role), the runtime role of `runtime_privileges` (`booking`, `tripplanner`, `cis_app` over
    the 11 CIS schemas without `catalog`) has USAGE on each schema, SELECT on every relation, USAGE on
    every sequence that is not an identity sequence (INSERT needs no right on those), EXECUTE on every
    function that is not a trigger function (a trigger fires without EXECUTE). The baseline is SELECT,
    not DML: Booking narrows some tables on purpose (`audit_logs` INSERT+SELECT, `countries` SELECT;
    dump 16/10). `default_acl.<owner>`: `pg_default_acl` rows FOR ROLE <live owner of the anchor
    schema> IN SCHEMA s grant the runtime role the `owners.yaml` table / sequence / function sets, and
    no FOR ROLE master row is left in the owner's schemas once the live owner is not the master (a
    bk-014 that forgets the restated rows or keeps the master's fails here instead of 42501 on the next
    bk-015+ table). Keyed like the ownership cells; `cis_app` from `244`. `consumer.contract_grants`
    (always expected): the contract consumer grants on a single object (`booking` → USAGE+SELECT
    `tripplanner.v_inquiry_outbox`, EXECUTE `geo.name_norm(text)`; `tripplanner` → INSERT
    `shared.llm_call_log`, EXECUTE `geo.name_norm(text)`); the `catalog.*` wildcard rows are left out
    because the helper view `catalog._tour_day_text` is (rightly) granted to nobody. All mirrored in
    `owners.yaml` (`runtime_privileges`, `runtime_privileges_from`, contract `consumer_grants`) and
    checked by `test_owners_registry`.
  - **CREATEROLE.** Runtime role attributes now require no SUPERUSER, BYPASSRLS, **CREATEROLE**,
    CREATEDB, REPLICATION (`ROLE_SQL` reads `rolcreatedb`, `rolreplication`); same for the owner-role
    cells. On PG 15 a CREATEROLE role can grant itself any non-superuser role. The CIS runtime cell is
    now `pending` until S18 (the master has CREATEROLE/CREATEDB), not `ready`.
  - **Ownership keyed on the live owner.** New state keys `<owner>_transferred` = transfer key
    registered **and** anchor schema (`booking`, `tripplanner`, `shared`) owned by the owner role (the
    fact the runner's XD8 switch reads; read with `ANCHOR_SQL`, unreadable = exit 2 like the registry).
    After a planned rollback (roles/ undo file, registry rows stay) the cells go back to `pending`.
  - **cis_app password window.** `login.cis_app` and `cross.cis_app.*` are expected only when the DSN is
    in the secret **and** the role carries the `x1:password-set` comment (`shobj_description`), which
    DB Migrate `mode=set-password` must write (`COMMENT ON ROLE cis_app IS 'x1:password-set <UTC> …'`,
    X1 plan S12, recorded there). Between Nghiệp's Console edit and set-password the login fails with
    28P01: `pending` + `warn` (workflow `::warning::`), not red. A comment needs no new env var and no
    registry key (a `rl-pw-*` row would mix a credential event into the migration registry).

## Changed
- New: `db/isolation_probe.py`, `.github/workflows/db-isolation-probe.yml`, `db/tests/test_isolation_probe.py`
  (27 tests), this note.
- Review round: `db/isolation_probe.py` (cells above, `ANCHOR_SQL`, `RUNTIME_MISSING_SQL`,
  `DEFAULT_ACL_SQL`, `CONSUMER_SQL`, `PASSWORD_MARKER`, state keys), `db/owners.yaml`
  (`runtime_privileges`, `runtime_privileges_from`), tests (34 probe tests, registry mirror),
  `db/README.md`, workflow header comment.
- `db/owners.yaml` (3 fields + header line), `db/tests/test_owners_registry.py` (keys + probe mirror test),
  `.github/workflows/db-migrate.yml` (dispatch the probe after an apply, `continue-on-error`, like the dump;
  header + permissions comment), `.github/workflows/migration-copy-guard.yml` (PR paths: the probe and its
  workflow, so its unit tests gate the PR), `db/README.md` (Isolation probe section, flow step 4, mirrors).

## Tradeoffs
- Cron 04:13 vs the dump's 03:43 (plan): the two never overlap `db_migrator` sessions after S22.
- The CIS runtime cells read the **running** api revision (service's `taskDefinition`), not LATEST: a
  registered-but-not-deployed `cis_app` revision does not flip them (S18 risk "unplanned cutover" is
  then visible as pending, not red).
- The ownership cell counts every object of every CIS schema before 245 (pending, ~170 names, 10 shown).

## Should know
- **Local proof (throwaway PostgreSQL 16.15, not RDS 15.17):** stand-in of the Dev shape (master =
  non-superuser CREATEROLE member of a stand-in `rds_superuser` with `pg_read_all_data`; `aa_app_user`,
  `booking`, `tripplanner`, `catalog_owner`; FORCE `published_tours` with master-read policies,
  ENABLE-only `tenant_tour_versions`, platform `facts`, parent-RLS `angle_gate_option`, a
  `catalog_owner` view). Driven through the same `python3 -c "…exec(urlopen(sys.argv[1]))…" <url> <cfg>`
  path the task uses. Results:
  - today's state: exit 0 — 23 pass, 23 pending, 2 ready, 0 FAIL (48 cells);
  - a `USING (true)` SELECT policy for `aa_app_user` on `tenant_tour_versions` → tenant cell FAIL (exit 1);
  - rl-001 effect → `cis_app`/owner-role/registry cells flip to expected and pass; cis_app secret
    `REPLACE_ME` → login pending; a cis_app DSN while the role is missing → login FAIL;
  - 243 + bk-014 with `booking.set_updated_at()` left on the master → `ownership.booking` FAIL, after
    the fix pass;
  - api switched to `rds-cis-app` **before** 244 → CIS runtime cross-app/role cells pass, the
    `tenant_tour_versions` cell FAILs (runtime 0 rows vs 3: the plan's ENABLE-only risk), 244 policies
    → pass; 244 registered with one ENABLE-only table lacking a `cis_app` policy → RLS cell FAIL;
  - catalog login `db_migrator` (S22) with a master `cis-api` session open → sessions cell FAIL; the
    same with the master as catalog login → `pending` + `warn`;
  - no probe session left afterwards; no row value, DSN or tenant id in the output.
  Local pg_hba was `trust`, so password checks were not exercised.
- **Local proof of the review round (PG 16.15 throwaway, stand-in schemas `shared`, `geo`, `booking`,
  `tripplanner`, `gold_aa_internal`, `catalog`; default privileges and grants as the dump):** today's
  state exit 0 (55 cells: 31 pass, 16 pending, 8 ready, 0 FAIL; Booking/TP runtime-grant and
  default-privilege cells `ready`, consumer cell `pass`); bk-014 stand-in without restated default
  privileges → `default_acl.booking` FAIL (4 findings: no FOR ROLE bk_owner rows, master rows left);
  restated, then a table created by the master in the transferred schema → `ownership.booking` and
  `runtime_grants.booking` FAIL, a table created by `bk_owner` → covered; objects handed back to the
  master with `bk-014` still registered → all three `pending`/`ready`, exit 0; `cis_app` DSN without
  the marker → login cells `ready` (not expected), with `COMMENT ON ROLE cis_app IS 'x1:password-set …'`
  → `pass`. The 28P01 path itself is unit-tested only (local auth is trust).
- **Unverified on Dev (needs merge + dispatch, not done here):** the first real dispatch. Cells that
  are expected today and could surface real findings: `role.booking.owns_nothing` /
  `role.tripplanner.owns_nothing` (objects owned by a runtime role outside the dump's schemas), the
  tenant matrix on the 16 live RLS tables, the Booking/TripPlanner DSN formats (plain `postgresql://`
  or `+asyncpg` and JSON are handled; a placeholder is reported, not crashed on). A red first run is
  then a finding to fix, not a probe bug. Also expected today and not in the dump: CREATEROLE /
  CREATEDB / REPLICATION of `aa_app_user`, `booking`, `tripplanner` (the dump's Roles table shows only
  login, superuser, bypassrls, limit; none of their creating migrations names those attributes, so
  they should be off) and the consumer grants (the dump shows all four).
- **S12 change for this workflow:** run-task from `aa-cis-dev-db-migrate` (container `migrate`, log
  stream `migrate/migrate/<id>`), `RUNTD` and the container/stream names are the only lines to change;
  the CIS runtime key keeps reading the api service. The migrator task role then needs GetSecretValue on
  the 5 runtime secrets + whatever the api injects (plan S11 list covers them).
- **Nothing for Nghiệp to edit by hand in this step:** no new env var, no secret value. The probe reads
  `aa-cis/dev/rds-cis-app`; until S11 creates it the cis_app cells are `pending` ("secret not found").
- Root docs (U-16 status, C2.x probe mention) are left for the S23 root PR.
