# db/ — migrations applied to the shared RDS (acc2)

RDS is VPC-private, so migrations are applied by the **DB Migrate** workflow
(`.github/workflows/db-migrate.yml`): it starts a one-off ECS Fargate task from the CIS api task
definition, which downloads `run_migration.py` and the SQL via presigned S3 URLs and runs it
with the task's own `DATABASE_URL`.

```
db/migrations/<owner>/<NNN>_<name>.sql   # owner = cis | tripplanner | booking
```

## Flow
1. PR adds the SQL here (human review = the approval).
2. Merge to `main`.
3. Run **DB Migrate** on `main` with `mode=check` (prints whether the version is registered),
   then `mode=apply`. The job fails unless the task exits 0 and the version is in
   `shared.schema_versions` afterwards. Re-running `apply` is a no-op.
4. Regenerate `AA-Ecosys/docs/architecture/db-schema-reference.md` after structural changes.

## Rules
- Every file self-registers: `INSERT INTO shared.schema_versions ... ON CONFLICT DO NOTHING`,
  inside its own `BEGIN; ... COMMIT;`.
- CIS migrations keep an identical copy in `AA-CIS-App/api/migrations/` (numbering + the
  integration tests build their schema from it). Apply the migration **before** merging app
  code that depends on it.
- Destructive changes follow the DRY RUN procedure (`skill/aa-cis-schema/references/destructive-ops.md`).
