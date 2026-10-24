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

- **Review round (S250)**: an independent review found the search_path hole and statements the first version let
  through; all are fixed in a second commit:
  - *search_path*: PostgreSQL puts a CREATE in the first schema of the path but resolves any other name to the first
    schema of the path that holds it. A non-CREATE unqualified name is now a finding when the active path names a
    schema outside the owner's, unless the file created that name earlier (tracked per name). `RESET search_path`
    / `RESET ALL` / `SET search_path TO DEFAULT` clear the path. Quoted values (`SET search_path = 'booking'`,
    `'booking, catalog'`) are read from the statement text (top-level literals are blanked in the code view).
  - *new touches*: top-level `SELECT … INTO <table>` (a DO-body `SELECT … INTO` is a PL/pgSQL variable and is
    skipped), `ATTACH`/`DETACH PARTITION`, `CREATE EXTENSION … SCHEMA s`.
  - *no-boundary statements*: global `ALTER DEFAULT PRIVILEGES` (no `IN SCHEMA`) and `REASSIGN OWNED BY` pass only
    when every role named is the dir's own owner role (`OWNER_ROLES`, a mirror of owners.yaml `owner_role` +
    `view_owner_roles`, tested against `isolation_probe.OWNERS`); a missing `FOR ROLE` fails (it would be the
    running role, the master on a legacy file). `DROP OWNED BY` always fails: it also revokes what other owners
    granted to the role. crm-001's `ALTER DEFAULT PRIVILEGES FOR ROLE crm_owner REVOKE EXECUTE ON FUNCTIONS FROM
    PUBLIC` is the one current copy of this shape and passes.
  - *false positives fixed*: `CREATE SCHEMA AUTHORIZATION r` (schema named r), `ALTER TABLE / MATERIALIZED VIEW ALL
    IN TABLESPACE`.
  - `CREATE EXTENSION` without `SCHEMA` is not a finding: CIS 226 / 234 install `vector` / `pg_stat_statements` that
    way (into the default schema); extensions move to `roles/` by convention, not by this lint.

## Changed

- `db/check_migration_ownership.py` (new), `db/check_migration_files.py` (calls it, errors only).
- `db/tests/test_check_migration_ownership.py` (new): clean cases, one failing case per kind of touch, every copy in
  the repo passes, the wiring through `check_migration_files.run`; review round: the search_path cases (a path
  naming another owner's schema, a name the file created, quoted values, RESET / DEFAULT), the new statements, and
  `OWNER_ROLES` against `isolation_probe.OWNERS`.
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

- **Scope of the enforcement**: a static lint at copy time. It does not read function bodies or dynamic SQL, so
  MIG-6 is "linted at copy time", not proven; the X1 owner-role switch of DB Migrate (a file runs as the owner role,
  which holds no rights on other owners' objects) is the runtime boundary, and the drift report the after-the-fact
  check.

- Run over the owners' full histories (local check, not in CI) it finds exactly the known cross-owner files:
  TripPlanner `002_shared_destinations.sql` + `005_destinations_located_by.sql` (`shared.destinations`), CIS
  `122` (drops `public.checkpoint*`), CIS `073`/`158` (unqualified `review_status_enum`), and CIS `001`–`007` from
  before the owner split. None of them has an Infra copy, so CI stays green.
- Proof for the issue's "red on a test migration that touches another owner's schema, green otherwise": the
  unit tests `OtherOwnersFail` / `WiredIntoTheCopyGuardLint` (CI run of the Copy Guard on the PR) plus the green
  nightly over every copy.
