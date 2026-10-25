# AA-853 (part 1): schema drift against a replayed DB

Issue: "Extend the nightly workflow: build a scratch postgres from all owner migrations, diff it against the live
catalog, report unmanaged objects in the root schema-reference PR." Part 2 (the Copy Guard ownership lint) is its own
PR (`AA-853-ownership-lint.md`).

## Decisions

- **Replay on the GitHub runner, not in AWS.** A throw-away `pgvector/pgvector:0.8.1-pg15` container (RDS is 15.17,
  vector 0.8.1) started with `docker run` inside a step, not a job `services:` block: a failed image pull in a
  service container fails the whole job before any step, which would take the live dump down with it. Cost: $0.
- **Report only.** The drift job and its steps are `continue-on-error`; a failed replay leaves master's drift
  section as it is (review round) and the dump, the ERD upload and the root PR run as today.
- **No AWS credential in the replay.** Since the review round the replay has its own job without id-token, environment
  or secrets (first version: same job, `env -u AWS_*`); the owner repos are cloned anonymously (all four are public; an Actions token of this repo gets 404 on another repo's contents, root
  lessons S248).
- **Order = live `shared.schema_versions` (applied_at, version).** Cross-owner dependencies (rl-001 before CIS 243,
  CIS 269 before crm-001, …) only replay in the order Dev saw. Versions that are not file keys (CIS `v1.0`…`v3.0`)
  map through the file name their description starts with. Owner files without a registry row and numbered below
  the owner's head (19 CIS legacy files) are replayed right after the file before them and flagged; files above
  the head are pending (not on Dev) and skipped.
- **Files run with run_migration.py's own role logic** (`resolve_role`, `run_switched` with its ownership
  post-check): master login (`aa_cis_admin`, CREATEROLE CREATEDB, not a superuser, member of a stand-in
  `rds_superuser`), `db_migrator` login from the CIS 246 registry row on (the X1 S22 cutover). One BEGIN … COMMIT
  file is sent whole like DB Migrate; legacy and other-shaped files run statement by statement and go on after an
  error, like the `psql -f` they were applied with.
- **Role bootstrap from the live dump**: every live role no migration creates with a literal `CREATE ROLE`
  (today `tripplanner` and the three crm NOLOGIN roles rl-004 makes in a loop), created by the master as on Dev.
  Extensions: created by the superuser from the live list (RDS lets its master do it).
- **Same dumper on both sides**: `schema_dump.collect` on the scratch DB, so the diff compares like with like.
- **Diff classes**: unmanaged / missing / changed for structure; owners and grants as an informational
  `privileges` list (they also move with the replay's role bootstrap, so they are not "drift" by default).
  Children fold into their relation, relations into an unmanaged / missing schema.
- **Attribution**: a failed or partial replay file keeps the `schema.name` it mentions; a finding lists those files
  as `explained_by`, so "drift on Dev" and "gap in the replay" are told apart.
- **Owner decisions in `db/schema_drift_decisions.json`** (JSON: the drift code stays standard library):
  `decisions` (finding id or glob → decision, ref) close a finding; `baseline` adds SQL files under
  `db/replay_baseline/` to the replay before a registry key, for history no repo holds any more.
- **Own fingerprint**: `<!-- drift-fingerprint -->` in the reference; the publish step opens the root PR when it
  changes, without touching the schema fingerprint (statistics-only nights still open nothing).

- **Review round (S250)**, independent review findings applied in a second commit:
  - *Three jobs*: `dump` (environment prod, id-token: the ECS dump, render, erd.json upload, unchanged 45 min cap),
    `drift` (no environment, no id-token, no secrets, `contents: read`; job and steps `continue-on-error`; replay step
    capped at 15 min, job at 25) and `publish` (App token only, no AWS: renders the reference, opens the root PR,
    runs the design ERD check). Files move as this run's artifacts (`db-schema-dump-<id>`, `db-schema-drift-<id>`).
    The replay runs owner SQL as a superuser in a container; it now shares a runner with nothing worth stealing,
    and the dump job's time budget no longer includes it.
  - *Image pinned by digest*: `pgvector/pgvector@sha256:94aee7e8…` (the image index of `0.8.1-pg15`, checked on
    Docker Hub and the registry on 25/10/2026).
  - *No flapping*: when the drift job fails, `gen_schema_reference.py --keep-drift-from root/<reference>` copies
    master's drift section and marker unchanged, so a failed night neither strips the section nor makes the next good
    night open a PR just to restore it.
  - *Fingerprint without replay noise*: findings with `explained_by` are left out of the drift fingerprint (they stay
    in the section and the counts), so an owner editing an old file that then fails differently opens no PR until
    the AA-ACP-Core baseline lands.
  - *Report only, said everywhere*: the section and the PR body say a finding fails nothing; fail-on-unmanaged (the
    MIG-5 wording) waits for the baseline file and the owner decisions.

## Changed

- New: `db/replay_migrations.py`, `db/schema_drift.py`, `db/schema_drift_decisions.json` (empty lists),
  `db/tests/test_schema_drift.py` (19 tests: order, legacy placement, pending, role bootstrap, attribution, baseline
  placement, diff classes and folding, decisions, fingerprint stability, reference section).
- `db/gen_schema_reference.py`: `--drift FILE` adds the section and marker; without it the output is byte-identical.
  Review round: `--keep-drift-from FILE` carries an existing reference's section over (`drift_section_of`).
- Review round tests: the fingerprint leaves out gap-explained findings; a failed drift run keeps master's section
  byte for byte, and a missing master file gives no section.
- `.github/workflows/db-schema-dump.yml`: asyncpg pin, two report-only steps, artifact files, drift fingerprint in the
  publish decision and the PR body. `migration-copy-guard.yml`: the new files in its paths filter (its unit-test
  step runs `db/tests`).
- `db/README.md` section, `CONTEXT.md` DB Schema Dump paragraph.

## Tradeoffs

- The first nightly reports a lot. Local run on PostgreSQL 15.17 + pgvector against the live dump of 24/10 20:23 UTC
  (330 files): 174 ok, 20 partly, 136 failed; 188 unmanaged findings (3391 objects with children), 22 missing,
  30 changed; 233 findings explained by a replay gap; only 1 unmanaged finding is not explained
  (`public.checkpoint_migrations`). The root cause of almost every gap is history no repo holds: the `acp_*`
  schemas and their first tables (`acp_shared.acp_runs`, `acp_run_context`, `acp_silver_s4.blog_drafts`,
  `social_content`, `acp_shared.audit_log`, …) came from the AA-ACP-Core lineage, and AA-ACP-Core (archived) has no SQL.
  Without them CIS 225 fails (no `acp_contract`), so `catalog_owner` never exists, rl-001 fails, and the X1 chain
  (243–246, bk-014, tp-013, rl-002/003/004, every crm- file) cascades. Fixing that is an owner decision, not code.
- `missing` already shows real history: schemas `bronze`, `gold`, `ops`, `silver` (CIS 001/002, dropped on Dev by
  hand), `acp_shared.unknown_ledger`, the tripplanner `tour_*` graph tables. `changed` shows real hand edits: the
  `tenant_isolation` policies on Dev use `NULLIF(current_setting(…), '')` where the files have the bare cast,
  `raw_tours` text columns that the files declare `varchar(n)`, CHECK lists widened on Dev.
- Comments, column defaults, roles and memberships are not compared (the dump has no defaults; roles are bootstrapped
  from live). Extensions are created before the replay, so they never show as drift.

## Should know

- Nothing changes on Dev, in AWS or in the ECS task: the new code runs on the runner only. No migration key.
- PR CI cannot run the replay (the dump job is `main`-only, `environment: prod`); the unit tests run in the Copy
  Guard. After merge: dispatch **DB Schema Dump** on `main` once (`publish=true`) and read the step summary and the
  root PR's drift section; the drift steps are allowed to fail without failing the run.
- Local run needs a FRESH PostgreSQL 15 with pgvector (roles are cluster-wide). Verified here with PGDG
  `postgresql-15_15.17` + `postgresql-15-pgvector` extracted to a scratch dir (no root), port 55853.
- Proposed next owner decisions (not taken in this PR): (1) a `db/replay_baseline/` file for the AA-ACP-Core
  lineage of `acp_*`, written from the live catalog with `pg_dump --schema-only` of those objects (run-script on
  Dev), placed `before` CIS `027`; (2) `decisions` for `public.checkpoint_migrations` (LangGraph leftover, drop or
  keep) and the `missing` legacy schemas; (3) migrations for the `changed` policy / CHECK edits made on Dev.
  Done-when of AA-853 ("0 unmanaged, or each listed with an owner decision") follows those decisions.
