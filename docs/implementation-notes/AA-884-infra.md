# AA-884 — Infra: byte-identical copy of CIS migration 248

Owner PR: AA-CIS-App `feat/aa884-mig-248-audit-append-only` (CIS PR A). This PR only copies
`api/migrations/248_audit_log_append_only_app_health.sql` to `db/migrations/cis/` for the DB Migrate workflow, like
every earlier CIS copy (#186 for 247).

## Decisions

- Copy only, no edit (Copy Guard compares byte-for-byte with AA-CIS-App main, so this PR merges after CIS PR A).
- No `migrate:` directive: one `BEGIN … COMMIT`, not destructive, no role switch (role lint from 243 passes,
  `run_migration.py --inspect` reports no errors or warnings).

## Changed

- Nothing beyond the plan (plan step S3).

## Tradeoffs

- Apply needs `shared.job` idle: the file ALTERs `shared.job_worker` (the worker heartbeat updates it every few
  seconds; `lock_timeout` 5 s) and adds triggers to `acp_shared.audit_log`.

## Should know

- Order: CIS PR A merged → this PR (Copy Guard green) merged → DB Migrate `mode=check`, `environment=dev` (expect
  "ran as: aa_cis_admin", 248 not registered) → `mode=apply` with jobs idle → DB Schema Dump auto PR in root
  (`docs/architecture/db-schema-reference.md`: six new audit_log columns + CHECK + unique index + 4 triggers, enum
  staff/machine, `shared.job_worker.git_sha`, `shared.cost_explorer_app_snapshot`) → merge it before the next apply.
- After apply, `UPDATE`/`DELETE` on `acp_shared.audit_log` fail with 42501 for every role, including ad-hoc
  ECS-exec scripts. Nothing in production code updates or deletes audit rows (S243 inventory).
- X1 (AA-860): 245 (owner transfer) and the 246 / isolation probes must include `shared.cost_explorer_app_snapshot`,
  `acp_shared.audit_log_chain()`, `acp_shared.audit_log_append_only()` and the new columns.
- Local checks: `python3 db/check_migration_files.py` (ok), `python3 db/run_migration.py --inspect` (no errors),
  `pytest db/tests` 220 passed. The Copy Guard itself needs the CIS file on main, so it can only pass in CI after
  CIS PR A merges.
