# AA-853 (part 2): migration ownership lint

Issue: "Copy Guard lint: fail a `db/migrations/<owner>/` file that creates or alters objects outside its owner's
schemas (driven by owners.yaml)". Part 1, the nightly drift diff against a replayed DB, is its own PR
(`AA-853-schema-drift.md`).

## Decisions

- **Static lint, no DB.** New module `db/check_migration_ownership.py`, called from `check_migration_files.lint_file`,
  so it runs in the existing Copy Guard job "Migration lint and unique numbers" (PR and nightly) with no new job.
- **Schemas from `run_migration.OWNER_DIRS`**, the runner's mirror of `owners.yaml` `schemas` that
  `test_owners_registry.py` already keeps equal. Reading `owners.yaml` directly would need PyYAML in the lint job,
  which the guards avoid on purpose (standard library only).
- **What counts as "touching"**: DDL (create / alter / drop, `SET SCHEMA` target, indexes / triggers / policies /
  rules by their table), `COMMENT ON`, `GRANT`/`REVOKE … ON`, `ALTER DEFAULT PRIVILEGES … IN SCHEMA`, and data
  writes. The issue says "creates or alters"; grants and writes on another owner's objects break ownership just as
  much (a booking file granting on `catalog.*` or inserting into `shared.job`), so they are findings too.
- **Allowed**: the file's own `INSERT INTO shared.schema_versions` (every owner self-registers there), temporary
  objects (tracked by name, so `DROP VIEW tp013_acl` after `CREATE TEMP VIEW tp013_acl` passes), and every read.
- **Unqualified names**: resolved through the file's own `SET [LOCAL] search_path` (or `set_config('search_path',
  …)`); without one they resolve to `public` on Dev, so an unqualified object is a finding.
- **DO blocks are read** (lexed through `run_migration._role_view`, as the role lint does); function bodies are not
  (they run later, as their caller). Dynamic SQL is out of reach: the CLI prints a note, the Copy Guard does not
  (it would repeat ~40 notes every night for crm-010/012/014).
- **Every file, no "from" number**: every copy on `main` (116 files) already passes, so there is no grandfather
  threshold to maintain.

## Changed

- `db/check_migration_ownership.py` (new), `db/check_migration_files.py` (calls it, errors only).
- `db/tests/test_check_migration_ownership.py` (new): clean cases, one failing case per kind of touch, every copy in
  the repo passes, and the wiring through `check_migration_files.run`.
- `db/tests/test_run_migration.py`: `test_clean_repo_passes_and_lint_errors_fail` placed the CIS-shaped `NO_TX`
  fixture (it touches `shared.*`) under `tripplanner/`; moved to `cis/241_b.sql`. The new lint rightly failed it.
- `.github/workflows/migration-copy-guard.yml`: header comment + `db/check_migration_ownership.py` in the PR paths
  filter (additive).
- `db/README.md`: "Ownership lint" bullet.

## Tradeoffs

- A regex lint over `split_statements` can miss exotic syntax (`CREATE TABLE … PARTITION OF other.parent`,
  `SECURITY LABEL`, `CREATE EVENT TRIGGER`, obfuscated dynamic SQL). The runner's ownership post-check (X1) and the
  nightly drift report are the backstops; the lint is the cheap PR-time gate.

## Should know

- Run over the owners' full histories (local check, not in CI) it finds exactly the known cross-owner files:
  TripPlanner `002_shared_destinations.sql` + `005_destinations_located_by.sql` (`shared.destinations`), CIS
  `122` (drops `public.checkpoint*`), CIS `073`/`158` (unqualified `review_status_enum`), and CIS `001`–`007` from
  before the owner split. None of them has an Infra copy, so CI stays green.
- Proof for the issue's "red on a test migration that touches another owner's schema, green otherwise": the
  unit tests `OtherOwnersFail` / `WiredIntoTheCopyGuardLint` (CI run of the Copy Guard on the PR) plus the green
  nightly over every copy.
