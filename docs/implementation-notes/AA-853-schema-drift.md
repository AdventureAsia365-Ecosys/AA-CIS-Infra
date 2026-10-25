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

## S251 (25/10/2026): faithful roles and owners, order fixes, honest attribution

Input: nightly run 40168418702 on main (#379, #380 repaired by #382): replay 333 files, 174 ok, 20 partly, 139 failed;
202 unmanaged (3693 objects), 22 missing, 30 changed, 247 "explained by a replay gap", 910 privilege differences.
Typical failures: `crm-014: must run as crm_owner … runs as aa_cis_admin`, `migration 279: roles cis_app, aa_app_user
and catalog_owner must exist`. (This section lives in `AA-853-schema-drift.md`, the AA-853 notes file of part 1; there
is no `AA-853.md`.)

### Decisions

- **Root cause of the role / owner cascade, traced file by file**: CIS 225 creates `catalog_owner` but fails in the
  replay (no `acp_contract`: lost ACP lineage), so rl-001 (`GRANT … catalog_owner`) fails, so no bk_owner / tp_owner /
  cis_app / cis_owner / db_migrator / crm_owner, so every X1 file and every crm file after it fails. On top,
  CIS 245 (the CIS ownership transfer) fails (244 needs `acp_contract`), so from 246 on every CIS file is refused by
  `resolve_role` (anchor `shared` still owned by the master) and crm files lack the 269 grant on `shared`.
- **Role gap fill** (`role_creators`, `roles_to_fill`, `fill_roles`): before each file, a live role whose FIRST
  creating file comes earlier and failed is created by the master with its live attributes (LOGIN/NOLOGIN, INHERIT,
  CREATEROLE/CREATEDB, CONNECTION LIMIT; never a password). Only the role: the creating file's grants and objects stay
  a gap and keep explaining their findings. Creating files are read through run_migration's `_role_view` (comments
  out, DO bodies in): `CREATE ROLE x` in a comment no longer counts (rl-004's header made `crm_ai_reader` look
  migration-made), and rl-004's `format('CREATE ROLE %I')` loop now counts for the live names in its strings, so the
  bootstrap-from-live list is down to the one role made by hand (`tripplanner`).
- **Owner gap fill** (`transfer_files`, `fill_ownership`): when a dir's X1 transfer file (first file with `ALTER SCHEMA
  <anchor> OWNER TO`: CIS 245, bk-014, tp-013) fails, the replay applies its ownership effect the way it does it
  (master's objects only; schemas to their live owner; relations / routines / enums the master owns to the anchor's
  live owner; third owners like `catalog_owner` keep theirs). The rule is 245's, not "copy every live owner", so
  owner differences stay visible in `privileges`. Grants, default privileges and 245's checks are NOT redone.
  Statements are run one by one and a refused one is reported, never fatal (a crash would empty the whole report).
- **Order fixes are owner decisions with evidence, not a heuristic**: `replay_order` in
  `db/schema_drift_decisions.json`. tp-001…tp-006 were registered by tp-007 (2026-10-11) with `applied_at = now()`;
  CIS 198 (2026-10-01) has an FK to `shared.destinations`, which only tp-002 creates, so they ran earlier. Each is
  placed at the first registry row after its first commit in AA-TripPlanner-Web (tp-002 before tp-001, per tp-001's
  header). `backfilled` lists every back-registered row (061, 143, tp-001…006); 043-050 (registered by 143) need no
  move today.
- **Attribution made strict** (`ddl_targets`, `schema_drift._explained_by`): "explained by a replay gap" now needs the
  failed file's DDL to make that difference (creates / alters / drops the object; names the column, index,
  constraint, policy or trigger in a DDL statement on its relation; recreates the view; format()-built DDL of that
  kind on an object it names). Before, any mention counted: a failed file that put an index on `raw_tours` "explained"
  the hand-made `raw_tours` column types. Files that only name a finding are `mentioned_by`; the finding counts as
  `unexplained`. New counts: `unexplained`, `unmanaged_unexplained`, `only_mentioned_by_replay_gap`; the section lists
  unexplained findings first and names the root gaps.
- **`gap_roots`**: from each failed file's first error, the object it needed and the files that CREATE it; `root` =
  no file in any repo creates it before the first file that needs it (lost history), else a cascade.
- **No baseline, no allow-list in this PR.** The remaining gaps all trace to the AA-ACP-App lineage (repo deleted;
  AA-ACP-Core, archived, has no SQL: checked its tree; AA-CIS-App history has no DDL for those objects). A baseline
  would have to reconstruct tables later dropped on Dev (acp_runs, blog_drafts, …) from the columns later files touch:
  that is an owner decision with invented DDL, not a replay fix. Tried locally (not committed): a baseline of only the
  four lost schemas takes unmanaged 157 → 141; the next roots are tables (list below).

### Changed

- `db/replay_migrations.py`: role gap fill, owner gap fill, `replay_order` + `backfilled`, `ddl_targets` per failed
  file (`ddl` in results), `gap_roots`, role attributes with CONNECTION LIMIT, docstring (PostgreSQL 15 only).
- `db/schema_drift.py`: kind-aware `_explained_by` (falls back to mentions for an old results file), `mentioned_by`,
  the new counts, root gaps and fills line, unexplained-first ordering, summary line.
- `db/schema_drift_decisions.json`: `replay_order` (4 entries, TripPlanner back-registration) and its `about` text.
- `.github/workflows/db-schema-dump.yml`: the PR body line also prints the unexplained counts (no step change: the
  replay CLI is unchanged and reads `replay_order` from the default decisions file).
- `db/tests/test_schema_drift.py`: 19 tests (roles in comments / DO / format loops, first creator, fill set, attributes,
  transfer detection, order fixes and bad entries, backfill list, DDL targets and words, dynamic DDL, gap roots,
  strict vs mention attribution, recreated views, rendering). `db/README.md` drift paragraph.

### Results (local, PostgreSQL 15.17 PGDG + pgvector 0.8.7, live dump of run 40168418702, owner repos at main)

| | before (main) | after |
|---|---|---|
| replay ok / partly / failed | 174 / 20 / 139 | 215 / 19 / 99 |
| roles, booking, tripplanner, crm files ok | 0/4, 18/24, 11/19, 0/15 | 4/4, 24/24, 19/19, 15/15 |
| unmanaged findings (objects) | 202 (3693) | 157 (1571) |
| missing / changed | 22 / 30 | 15 / 27 |
| privilege differences | 910 | 507 |
| not explained by a replay gap (strict) | n/a (1 under the old any-mention rule) | 26, of them unmanaged 7 |

The local run on main reproduced the CI numbers exactly (174/20/139, 202, 247, 30, 22, 910), so the comparison holds.
Every remaining failure is a CIS file. Root gaps (no file creates them before they are needed): schemas `acp_shared`
(before 095), `acp_silver_s3`, `acp_silver_s4`; tables `acp_shared.acp_runs`, `acp_shared.acp_output_rules`,
`acp_silver_s2.visibility_reports`, `gold_aa_internal.tenant_tour_versions`; behind them (seen with the schemas-only
trial baseline) `acp_shared.audit_log`'s schema, `acp_shared.acp_run_context`, `acp_hitl_requests`, `acp_stage_runs`,
`acp_silver_s4.blog_drafts`, `social_content`. The cascade: 041 (needs blog_drafts) → no
`published_tours.content_embedding` → 078 fails → no `acp_contract` / `acp_deliver` → 225 (catalog), 226 (geo), 244 →
245 and on.

Drift on Dev that no replay gap explains (to decide; likely origin):
- unmanaged `public.checkpoint_migrations` (+2): LangGraph `PostgresSaver.setup()` run by the app (CIS S2 LangGraph
  agent, AA-43), runtime DDL outside migrations.
- unmanaged `shared.pipeline_runs.llm_model / llm_provider / step_name`, `shared.tenant_brand_rules.created_at`: no file
  adds them; ALTER by hand on Dev (or an older 003 / 005 than the repo's).
- unmanaged index `shared.tenant_brand_rules uq_tenant_brand_name_version` + missing `uq_brand_rules_tenant_brand_version`:
  044 was edited after it ran (143's header confirms Dev has the first name).
- unmanaged index `generated_content idx_generated_content_metadata_gin` (jsonb_path_ops) + missing
  `idx_generated_content_metadata_brand_rule`: 048 edited after it ran, or the index replaced by hand.
- missing schemas `bronze`, `gold`, `ops`, `silver` (+48 objects): CIS 001's v1 layer; 003 drops `silver_%` / `gold_%`
  only (the `_` wildcard needs a character), Dev has none of them: dropped by hand, or 001 as it ran differed
  (v1.0…v3.0 were registered together).
- missing `acp_shared.unknown_ledger` (+16): 095 creates it, no file drops it: dropped by hand.
- changed `tenants.is_canary / skip_hitl` (058 says NOT NULL, Dev nullable), `tenant_brand_rules.brand_name` (043 adds it
  nullable, Dev NOT NULL): hand ALTERs or edited files.
- changed `raw_tours.duration / group_size / period / price_raw / sku / tour_id_external` (and `country`, which 279 was
  still credited with because its DDL names `shared.country`): `text` on Dev, `varchar(n)` in 003; the
  `v_pipeline_summary.country`, `chk_raw_tours_country` and `raw_tours_review_status_check` differences are only the
  casts that follow from it.

### Tradeoffs

- Fills make later files run, at the price of objects the failed file would also have made staying absent (still
  reported, and explained). The alternative (stop at the first failure) reports nothing useful.
- Strict attribution moves 25 findings from "explained" to "unexplained": more to decide, but none hidden. The
  format()-built DDL rule is broader than the static one (kind-bound, by name); it can still over-credit a failed
  file (the `raw_tours.country` case), never under-report a finding that has no failed file at all.
- PostgreSQL 16 was tried (16.15 + pgvector 0.8.7): rl-001 / rl-002 refuse (`aa_cis_admin must not be a member of
  aa_app_user or catalog_owner`: from 16 a CREATEROLE creator holds ADMIN on what it creates) and the owner fill
  gets `must be able to SET ROLE`; 64 files differ. The replay stays PostgreSQL 15, as RDS and the workflow image.

### Should know

- Nothing changes on Dev or in AWS; no migration key. The fingerprint changes once (new attribution), so the first
  nightly after merge opens the root reference PR.
- Done-when of AA-853 (one green nightly with 0 unmanaged) still needs: (1) an owner decision on the ACP lineage
  (a `db/replay_baseline/` file of the lost schemas and tables, or `decisions` entries "lost lineage, keep" per
  object), (2) decisions or migrations for the unexplained unmanaged findings above (8 after the review fixes below).
- Local run: `.tmp/` in the worktree (PGDG 15.17 + pgvector debs extracted, venv with asyncpg 0.30.0), cluster on
  port 55853 with trust auth, owner repos cloned at main (AA-CIS-App b9eab70, AA-Booking 55b8679,
  AA-TripPlanner-Web 63f0aad, AA-Partner 923e206).

### S251 review fixes (independent review of 929ef7f)

Decisions:
- **Owner fill does what 245 does, not what Dev has now.** Every schema of the dir goes to the anchor schema's live
  owner (`cis_owner` for all 12 CIS schemas, as 245 item 3), not to each schema's own live owner: copying live state
  would hide a later owner change of one schema. Objects move in the 11 runtime schemas only
  (`TRANSFER_SKIP_OBJECTS = {"cis": {"catalog"}}`, 245 item 4), with 245's own catalog query (`OWNED_OBJECTS_SQL`):
  relations and standalone composite types, enum / domain / range types, routines, statistics, collations,
  conversions, text search dictionaries and configurations, extension members left out. The skip list lives in
  `replay_migrations.py`, not on `run_migration.OwnerDir`: it describes one historic file, and DB Migrate's own code
  should not change for a report. Statement building is pure (`transfer_scope`, `ownership_statements`) and tested.
- **Version guard.** `prepare()` reads `server_version_num`; `check_server_version` refuses any major but 15 and
  `main()` exits 1 with the reason (`REPLAY refused: …`). The workflow step is `continue-on-error`, so an image bump
  shows as a failed drift step, never as silently different counts. The results' `notes` record the version.
- **Dynamic CREATE ROLE is read precisely.** Only the literal arguments of a `format('CREATE ROLE %I', …)` call, or
  the literals of the `ARRAY[…]` a `FOREACH` loop passes to it, count (`_dynamic_role_names`). Before, every literal of
  the file equal to a live role counted: rl-004 also names `crm_app`, `crm_owner` and `aa_cis_admin`.
- **Fewer connections.** `fill_roles` keeps a `seen` set of creator roles found on the server and connects only when a
  due role was not seen yet (before: once per file after the first creator, about 300 connects).
- **Column findings need column DDL.** `ddl_targets` adds `columns` (`column_targets`: CREATE TABLE column lists, and
  the column of each ALTER TABLE add / alter / drop / rename action). A failed file explains a column finding only
  when it sets that column; the old bag of words of every statement on the table stays for indexes, constraints,
  policies and triggers, and for results files without `columns`. Fixes the known over-credit: 279's
  `UPDATE OF country` trigger no longer explains `raw_tours.country`.
- **replay_order reasons** now say the placement before 149 / 179 / 180 / 181 is the earliest point (a lower bound);
  only "before 2026-10-01" (CIS 198's FK) is proven.
- Docstring line over 120 characters rewrapped (ruff E501 now clean on the three files). The notes stay in this file
  (`AA-853-schema-drift.md`), the existing AA-853 notes file; there is no `AA-853.md`.

Results after the fixes (same local setup and live dump; `.tmp/final2/`):

| | 929ef7f | after review fixes |
|---|---|---|
| replay ok / partly / failed | 215 / 19 / 99 | 215 / 19 / 99 |
| owner fill after cis/245 | 79 statements, 0 refused | 79 statements, 0 refused |
| role fill | catalog_owner before booking/004 | same |
| unmanaged findings (objects) | 157 (1571) | 157 (1571) |
| missing / changed | 15 / 27 | 15 / 27 |
| explained by a replay gap | 173 | 171 |
| not explained (unmanaged) | 26 (7) | 28 (8) |
| privilege differences | 507 | 507 |

The two findings that moved to "not explained" are real: `raw_tours.country` (the 279 over-credit) and unmanaged
`silver_aa_internal.raw_sources.file_hash`, which no migration adds (123 only registers its unique index, "already
live via manual DDL"; the column itself was added by hand). Two more findings lost a second, wrong explainer
(`shared.destinations.geo_precision` keeps 226, `shared.tenants.cancelled_at` keeps 042). A PostgreSQL 16.15 server
is now refused with exit 1. Unit tests: 666 (16 new).


## S251 (part 2): replay baseline, legacy order, CIS 282 (branch fix/aa-853-replay-baseline, stacked on #383)

Orchestrator decisions D1 (baseline for the lost lineage) and D2 (Dev is the truth: CIS migration 282), taken under
Nghiệp's S251 blanket approval. This section covers the Infra side; CIS 282 has its own notes in AA-CIS-App
`docs/implementation-notes/AA-853.md`.

### Decisions

- **Baseline placement: right before the first replayed file that needs the object, not at "start".** That is the
  latest point the evidence fixes; "start" would claim that 001-018 (grant loops, 003's schema rebuild, 008's RLS
  loop) acted on objects nobody can show existed then, and `gold_aa_internal.tenant_tour_versions` cannot exist before
  003 creates its schema. The ACP lineage is one file before CIS 020 (the first file that touches any of it);
  tenant_tour_versions one before 107. `before` now takes a registry key OR an owner file rel (`cis/020_x.sql`), since
  the first needing files are unregistered legacy files.
- **Shape per object (SPEC in `db/gen_replay_baseline.py`, generated from the live dump, regenerable, `--check`):**
  live objects = live columns / NOT NULL / CHECK / FK / indexes MINUS what a surviving later CIS file adds (037, 107,
  109, 175), with the pre-change CHECK where the later file's text says what it was (108: tenant_tour_versions status
  without `ai_generated`); the primary key comes from the dump's primary index (`ADD CONSTRAINT … PRIMARY KEY USING
  INDEX`; the dump keeps only CHECK / FK constraints). Tables Dev later dropped (121): only what later files need
  (`acp_runs.run_id`, `acp_hitl_requests.hitl_id`, both as PKs because FKs name them); a table no later file needs a
  column of (`visibility_reports`, `content_calendars`, `blog_drafts`) is created with NO column, honestly empty.
  Defaults are not in the dump: only the two later files rely on are written (`rule_id`, `run_id`:
  `gen_random_uuid()`, 020 inserts without a key). Assumptions written into the file per object: the exact
  expressions of the live-only policies `output_rules_rls` / `tenant_tour_versions_isolation` (229's header names
  them and drops them), blog_drafts' key / FK to acp_hitl_requests (never named by a file: left out),
  `acp_gold_output.published_content` (121 drops it with IF EXISTS: not created, only its schema).
- **Recorded hand DDL is baseline too (beyond D1's lost lineage, same mechanism, same guard).** With the lineage in,
  the replay stopped at guards that check Dev states no migration makes: 239 needs RLS + `tenant_isolation` on
  `shared.pipeline_runs` (008's header: "S7 applied RLS only on shared.pipeline_runs"; the repo's 004 cannot have run
  as written: uuid = text), 244 refuses the tables AA-603 dropped by hand, 123 indexes `raw_sources.file_hash`
  ("already live via manual DDL"). Replaying them at the point the evidence gives is faithful; doing it only in 282
  (at the end) leaves 239 / 244 / 245 failed and ~30 policy findings. Files: `001_s7_pipeline_runs_rls` (before 008),
  `004_raw_sources_file_hash` (before 123), `005_g3_drop_unknown_ledger` (before 153; root repo
  `docs/archive/2026/audit-cis-g3-execute.sql`, 16/09/2026), `006_aa603_drop_n7n8_tables` (before 160;
  `docs/archive/2026/aa603-drop-n7n8-tables.sql`, 21/09/2026). 282 codifies the same end state for a files-only DB.
- **Never applied to a real DB, three locks:** (1) every baseline file opens, before its BEGIN, with a guard that
  RAISEs unless `current_setting('aa_replay.baseline', true) = 'on'` AND `application_name = 'db-replay'`; only
  `replay_migrations.run_item` sends that SET, only for baseline files (`baseline_statements`), and `add_baseline`
  refuses a file without the guard; (2) `run_migration.lint` refuses any SQL carrying the marker
  `aa-853-replay-baseline`, whatever its path (DB Migrate check and apply both lint first); (3) DB Migrate's path rule
  (`^(cis|…|roles)/NNN_x.sql$` under `db/migrations/`) cannot select `db/replay_baseline/`. Tests:
  `db/tests/test_replay_baseline.py`. Local proof on PostgreSQL 15: the G3 file under `application_name` db-migrate
  or db-replay without the setting, and with the setting but db-migrate, RAISEs; only db-replay + setting applies.
- **The replay's master gets BYPASSRLS.** On RDS the master reads FORCE RLS tables unfiltered through rds_superuser
  (AA-817 probe v2; 239's and 244's guards refuse to run otherwise, 245's header); plain PostgreSQL has no such role
  and BYPASSRLS is not inherited, so it is set on `aa_cis_admin` itself. Files that read `rolbypassrls` of the
  runner (229/237/241/262/265/266 "privileged") then pass via that instead of via ownership: same outcome.
- **Order fixes (decisions `replay_order`, with evidence):** 043-050 (back-registered by 143 on 2026-09-04; 104 of
  2026-08-15 reads 043's `brand_name`) before 051, the first registry row after their first commits (2026-05-27..29);
  `replay_order` gains `files` for unregistered legacy files: 019_social_content + 021 (header dates 21/05/2026; 021
  alters 030's audit_log) before 032, 062-064 (dated 2026-06-04; name order put them after 143's 050, i.e. after 121
  dropped what they alter) before 058. Lower bounds, like the TripPlanner entries.
- **Owner decisions (`decisions`):** `public.checkpoint_migrations` unmanaged, keep (LangGraph bookkeeping, kept on
  purpose by 122); schemas `bronze`, `gold`, `ops`, `silver` missing, keep-dropped (001's v1 layer, gone on Dev; in a
  DB Migrate-built DB they are the master's and 282, running as cis_owner, leaves them with a NOTICE; a master-run
  roles/ file for an empty unused layer is not worth it).

### Changed

- New: `db/gen_replay_baseline.py`, `db/replay_baseline/001…006_*.sql` (generated), `db/tests/test_replay_baseline.py`
  (16 tests), `db/migrations/cis/282_schema_drift_reconcile.sql` (byte copy of AA-CIS-App's).
- `db/replay_migrations.py`: `BASELINE_SETTING`, `baseline_statements` (baseline sent whole after the SET),
  `_position` (key or file anchor) for `add_baseline` and `apply_order_fixes` (`files`), guard check in
  `add_baseline`, master BYPASSRLS, docstring. `db/run_migration.py`: `BASELINE_MARKER` + lint refusal.
- `db/schema_drift_decisions.json`: 6 `baseline` entries, 3 more `replay_order` entries, 5 `decisions`, `about`.
- `db/tests/test_schema_drift.py`: guarded fixture, `files` entries valid. `db/README.md`, copy-guard paths filter.

### Results (local, PostgreSQL 15.17 + pgvector, live dump of run 40168418702, owner repos at main)

| | #383 (c53bd21) | this branch, live as is (282 pending) | this branch + 282 applied (282 registered in a copy of the dump) |
|---|---|---|---|
| replay files ok / partly / failed | 215 / 19 / 99 | 334 / 5 / 0 (339, 6 baseline) | 335 / 5 / 0 (340) |
| role / owner gap fills | 1 role, 79 owner statements | none needed | none needed |
| gap roots | 22 | 0 | 0 |
| unmanaged findings (objects) / open | 157 (1571) / 157 | 8 (10) / 7 | **1 (3) / 0** (checkpoint_migrations, decided keep) |
| missing / changed | 15 / 27 | 6 / 32 | 4 (decided) / **0** |
| explained by a replay gap | 171 | 0 | 0 |
| privilege differences (informational) | 507 | 18 | 18 |

"Live as is" is what the first nightly after merging this PR shows: the 7 open unmanaged and 32 changed findings are
exactly D2's hand drift, which 282 removes once DB Migrate applies it. The 5 partly files are 001 (v1 enum seed), 004 /
006 (uuid = text: the repo versions cannot have run as written; S7's effect is the baseline), 005 (role `app_user`,
made by hand and gone), 007 (seed without `slug`): they produce no finding. The 18 privilege differences are the hand
grants of the hand-made `tripplanner` role on its own schema and the owners of the 4 decided v1 schemas (informational).

### Should know

- Done-when (one green nightly with 0 unmanaged) needs, in order: merge #383, merge this PR, merge the CIS 282 PR,
  DB Migrate `check` then `apply` cis/282 (destructive header: DB Migrate takes its snapshot; on Dev the file is a
  no-op, its preflight in the header shows it), then one nightly (or a dispatch of DB Schema Dump with publish=true).
- The first nightly after this PR (before 282) changes the drift fingerprint and opens the root reference PR.
- `gen_replay_baseline.py --check schema.json` re-renders from a dump: the header carries the dump's generated_at, so
  a newer dump differs by that line only; regenerate (and review the diff) when SPEC changes.
- Not verifiable from the dump: column defaults of the hand-made columns (`tenant_brand_rules.created_at`,
  `pipeline_runs.llm_*` / `step_name`, `raw_sources.file_hash`); 282 adds them without a default. A read-only check of
  `information_schema.columns.column_default` on Dev would settle it (not done: subagent, no ECS exec).
