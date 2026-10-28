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

`x1_245_cis_owner_objects.py` (X1 S21, AA-860, read-only): before the CIS 245 apply (after rl-002), lists every
object 245 will move to `cis_owner` (the migration's own step-4 query, verbatim; `db/tests/test_x1_245_cis_owner_objects.py`
compares them once `db/migrations/cis/245_x1_cis_owner.sql` is copied) and every condition one of 245's guards would
refuse (`SCRIPT refuse …`, a third owner, a SECURITY DEFINER routine, the FORCE set, default ACL rows, rl-002's shape),
ending with `SCRIPT summary move=<n> refuse=<n> ok=<t|f>`. Compare its `move` lines with the 245 apply's NOTICE lines.

`dm65_consent_capture.py` (DM-6.5, AA-886, read-only): the consent capture check. Per app and source, how many
customers have `contact_consent` true/false and a `contact_consent_at` (`SCRIPT coverage`), rows whose value and time
disagree (`SCRIPT integrity`), whether each `tripplanner.customers` row reached the Booking master with the same value,
time and `source = 'tripplanner_lead'` (`SCRIPT chain`), and the trail of a live test inquiry sent with an
`aa886-consent-test…@example.com` address through `tripplanner.customers` → `booking.inbox_events` → `booking.customers`
(`SCRIPT test_inquiry`). Prints ids, booleans, timestamps and counts only; e-mail is a filter, never printed. The query
text and its run steps live in the root repo, `docs/legal/consent-capture-query.md`; keep the two identical.

`session_info.py` is a read-only smoke test (prints `session_user`, database, server version and the
session settings): use it to check the mode after a change to the runner or the migrator task definition.

`aa680_link_staff_cognito.py` (AA-680, one-time): links bridge-era `booking.staff_users` rows to their Cognito
WORKFORCE identity from `shared.admin_users.cognito_iss / cognito_sub` (needs AA-Booking bk-016). Merged with
`READ_ONLY = True` = DRY RUN (prints the mapping); a one-line follow-up PR sets `READ_ONLY = False` to apply.
Idempotent; never rebinds or merges rows. Notes: `docs/implementation-notes/AA-680-backfill.md`.

`aa680_staff_users_readonly_check.py` (AA-680 staff half, read-only evidence): shows that Booking holds no
`booking.staff_users` row for the "E2E Cognito" WORKFORCE user (CIS reviewer, no `booking-*` group) that the CIS
Cognito E2E gets refused by Booking (`no_booking_role`), matching by CIS id, Cognito identity, `cog:<sub>` key or
e-mail; and lists every Booking staff row (key kind, role, active, linked, CIS username, last seen; subs cut to 8
characters, no e-mail). Ends with `SCRIPT verdict e2e_has_no_booking_row=true|false`; returns 1 only when a Booking
row matches the E2E identity. Dispatch after the E2E run. Notes: `docs/implementation-notes/AA-680-s245.md`.

`aa816_clear_breakglass_password.py` (AA-816 checklist B6, decision N-B, one-time): sets `password_hash` NULL on
the CIS break-glass row of `shared.admin_users` (root ADR 0006a A4) and writes one `acp_shared.audit_log` row
(`staff.legacy_password_cleared`) in the same transaction. Refuses unless exactly one row matches the break-glass
username / e-mail and it has both. Merged as apply (`READ_ONLY = False`); `READ_ONLY = True` is a DRY RUN.
Idempotent (`already_null`, writes nothing). Prints booleans and the audit row id only. Notes:
`docs/implementation-notes/AA-816-breakglass-hash.md`.

`aa805_ai_guards_read.py` (AA-805, read-only): the DB half of the TripPlanner AI Phase 0 closing evidence. Prints
`tripplanner.llm_spend_daily` for the last 3 UTC days next to the `shared.llm_call_log` totals of the same online stages
and today's sum against the 5.0 USD default cap; the `tripplanner.narration_cache` summary (rows, hits, rows hit,
fresh rows); whether every destination the 30-query labelled search set returned live (725 ids, hard-coded) has an
embedded component of an active, non-deleted AA-tenant tour, with a negative control (inactive-only destinations
exist and none was returned); and up to 5 component ids per kind whose tour day has no AA master text (inputs for the
live narration-cache test). Ends with `SCRIPT verdict search_no_inactive=PASS|FAIL`. Notes:
`docs/implementation-notes/AA-805-s245.md`.

`aa847_places_probe.py` (AA-847, read-only): the places L4 / `PLACES_SOURCE=cis` flip evidence. Pass 1 as
`tripplanner` (`SET LOCAL ROLE`; `SCRIPT refuse what=set_role` and exit 13 when refused): every TripPlanner browse
reader, legacy vs cis, with the readers' exact SQL (the `READERS` block, generated from the TripPlanner source by root
`docs/audits/2026-10-21-S246-aa847/gen_probe_sql.py`; `--check` re-generates and diffs it) for Laos and Vietnam,
`SCRIPT timing` / `SCRIPT parity` (target max(1.5 × legacy, 200 ms)) and, for the slowest call of each reader,
`EXPLAIN (ANALYZE, BUFFERS)` top nodes and where each consumer filter landed (`SCRIPT qual … pushed=t|f`); a
fingerprint (row count + md5 of the ordered rows) of every `catalog.*` view (equal before / after a catalog view
migration); the AA-847 defect tours (HCM Trail, Kuang Si). Pass 2 as the master: the flip gate (`SCRIPT coverage …
missing_in_cis_live`, frozen keys mapped to source_id through `raw_tours`, AA-731 orphans counted as not live),
`geo.tour_build` per country (cost quote input), environment (pgvector, an index-ordered top-k EXPLAIN, tripplanner's
privileges in `silver_aa_internal` / `acp_contract`, cross-app `destination_id` references, last ANALYZE,
`pg_stat_statements`). Pass 3 as `tripplanner`: does each component's tour-day text name it (AA-819; frozen and cis).
Time budget ~20 minutes (`SCRIPT truncated <section>`), samples capped; ends with `SCRIPT done`. Read the output with
`gh api repos/AdventureAsia365-Ecosys/AA-CIS-Infra/actions/jobs/<id>/logs | grep -o 'SCRIPT .*'` (log lines carry a timestamp prefix).
After TripPlanner slice 6c the regenerated block also carries the assembly twins (`SCRIPT timing reader=assembly_*`,
parity per call) and the cis search becomes the top-k over `catalog.v_component_embedding` (`search` = top-k,
`search_exact` = the exact fallback); before 6c those readers are listed in `READERS_ABSENT`.
Since the S246 gate diagnosis (probe fixes): the timings run `REPEATS` = 3 times and parity is judged on the
**median** (`SCRIPT parity … runs=3 cis_runs=a/b/c legacy_runs=a/b/c`); the cis `routes_single` / `routes_chain` calls
run under `plan_cache_mode=force_custom_plan` as TripPlanner's `proposals()` does (`set_config(…, true)` and the
session value restored right after, never `SET LOCAL` across savepoints); `SCRIPT calls reader=routes_single` prints
every call's ms, and `routes_single_auto` (run 1, not scored) is the same cis read left at the session plan cache
mode, where a jump from call 6 on is a generic cached plan; `SCRIPT generic_plan` compares the `PREPARE`d read's
generic and custom plans (`EXPLAIN EXECUTE`, days 21, slack 3). The step-18 structural check is `SCRIPT env_topk` /
`env_topk_summary` in pass 1, as `tripplanner` with TripPlanner's `ef_search` / `iterative_scan`: the generated
`TOPK_SQL_CIS` EXPLAINed natural and with `enable_sort=off`, with `uses_hnsw_*`, the liveness probe path,
`join_filter_source_id`, a `Seq Scan raw_tours` loops>1 flag and `verdict_full` / `verdict_pre258`. `SCRIPT plan_flag
… flag=seq_scan_raw_tours` marks any EXPLAIN whose liveness probe re-scans `raw_tours`. The env line prints `jit`.
A run the budget cut short stays out of the medians (`partial=<n>` on the timing and parity lines). The search
readers' `ef_search` / `iterative_scan` end with the search block (a rolled-back savepoint), so routes and assembly run
at the session values as in TripPlanner; HNSW counts only as `tour_place_embedding_hnsw` by name.

`aa847_component_id_map_fill.py` (AA-847, merged READ_ONLY = dry run): fills `tripplanner.component_id_map` (tp-017),
frozen `itinerary_components.id` → `catalog.v_tour_component.component_id`. Pass 1 as `tripplanner`: live sources and
catalog components; pass 2 as the master: the frozen components, old version tour ids → source ids through
`raw_tours` (AA tenant named), `geo.name_norm` of every name. Rules: (source, day, name_norm, activity), then (source,
day, destination); `SCRIPT match` / `match_total` per country with `not_live` (orphans) and `no_source` apart,
`SCRIPT unmatched` (capped). The apply is a one-line follow-up PR (`READ_ONLY = False`, dispatched in the flip window,
after the last place build): pass 3 inserts as `tripplanner`, `ON CONFLICT (old_id) DO NOTHING`
(`SCRIPT apply inserted=<n>`). Exit 1 when the switch is refused or tp-017 is not applied.

`aa712_frozen_tables_dry_run.py` (AA-712 X4, read-only): the DRY RUN (skill `aa-cis-schema`
`references/destructive-ops.md`, step 1) before TripPlanner tp-018 drops its eight frozen place tables
(`itinerary_components`, `tour_day`, `tour_stop`, `tour_graph_*`, `tour_leg`, `tour_junction`) and before CIS 270
revokes the remaining `tripplanner` grants on CIS objects. Per table: exact rows, size, the last write time where the
table has one (against tp-018's cutoff 2026-10-16 00:00 UTC), the pg_stat read / write counters and who holds grants;
`pg_stat_statements` statements naming each table (count, calls, roles); every view / foreign key outside the eight
that depends on them; how many trip events and drafts still carry pre-flip ids (`component_id_map`); the
`tripplanner` grants 270 revokes with their grantor (`by_owner=t` = cis_owner's REVOKE removes them). Ends with
`SCRIPT verdict drop_ready=… revoke_ready=… reasons=…`. Counts, names and timestamps only. Dispatch it twice some
minutes apart to see whether a read counter moves. Notes: AA-CIS-App / AA-TripPlanner-Web
`docs/implementation-notes/AA-712-x4.md`.

**Obsolete since TripPlanner tp-018 (AA-712 X4, frozen place tables dropped):** `x1_photo_itinerary_parity.py`,
`aa847_component_id_map_fill.py` and the legacy half of `aa847_places_probe.py` read
`tripplanner.itinerary_components` / `tour_stop` / `tour_leg` / `tour_junction` and `shared.destinations`; they fail
once tp-018 is applied. They stay as the record of the flip evidence; do not dispatch them again (the probe's `cis`
half lives on in the TripPlanner tests over the catalog views). Remove them in a later cleanup together with their
tests.

`aa973_b2b_seed.py` (AA-973, S248, Dev only; merged `READ_ONLY = True` = DRY RUN): synthetic supply for the
booking.b2b.v1 live check — two inactive seed staff rows (contract maker / checker), a `SYNTHETIC S248` supplier,
hotel, room type and activity service, a USD contract (draft by the maker, published by the checker) with one rate per
item, the commercial row of one catalog tour with no plan yet (first `catalog.v_tour` row by `source_id`), its day-1
components and two 2-seat departures. Writes as `bk_owner` in one transaction; reads `catalog.v_tour` as `booking`, else
`tripplanner`. Idempotent (`SCRIPT summary steps=0` on a re-run). Reports whether the synthetic partner (tenant
`…c972`), an approved `b2b` rule and the B2B settings are in place (`SCRIPT readiness`, `SCRIPT verdict ready=…`) and
prints the ids the live check needs (`SCRIPT verify …`). Apply = one-line PR `READ_ONLY = False`; cleanup = one-line PR
`ACTION = "cleanup"` (retires everything it wrote, children first: components, departures, plan, contract → expired,
supply → inactive). Notes: `docs/implementation-notes/AA-973.md`.

`aa974_b2b_verify_seed.py` (AA-974, S248, Dev only; merged `READ_ONLY = True` = DRY RUN): builds on the AA-973 seed
(refuses without it) for the booking.b2b.v1 commercial-rules live check — one synthetic approved VND rate
(`booking.fx_rates` VND 25000 per USD, buffer 0, `as_of` today UTC, source `SYNTHETIC S248 AA-974`, written by the
AA-973 seed maker and approved by the seed checker in `booking.policy_approvals`, bk-007 maker-checker) and three
4-seat departures of the seed plan at +28 / +35 / +42 days (extend + cancel, the per-proposal and the per-departure
re-hold loops). Writes as `bk_owner` in one transaction under the AA-973 seed's advisory lock and its own. A VND rate
already in force from another source is used as it is. Idempotent (`SCRIPT summary steps=0`). Reports bk-021, partner,
`b2b` rule, the four B2B settings and the cancellation policy in force with its tiers (`SCRIPT readiness`), prints the
FX row and departures with the fee % the check expects (`SCRIPT verify`) and `SCRIPT verdict ready=…`. Apply = one-line
PR `READ_ONLY = False`. No cleanup action: FX rows are append-only (a later real VND row supersedes it); the departures
go with the AA-973 seed cleanup. Notes: `docs/implementation-notes/AA-974.md`.

`aa682_s1_live_check.py` (AA-682 S1, S252, Dev only; merged `MODE = "dry_run"`): the supplier-bookings live check
(Booking bk-026; the agent's Dev staff sessions are read-only, so the writes are SQL as `bk_owner`). One transaction: a
`SYNTHETIC S252 AA-682` supplier (room type + service), a synthetic customer (`…@example.invalid`), a B2C trip case at
`confirmed` with an approved V1 of two supply items, two supplier bookings generated → requested (the case moves to
`supplier_confirming` as the system) → confirmed; savepoint checks that the database refuses an illegal edge, a second
live booking of one item, B2C `pre_departure` and a money status; `SCRIPT verify what=b2c … supply=booked`. With a
confirmed hold of the AA-973 seed partner whose line is still `on_request`, it also links, requests and confirms a
supplier booking for it and accepts the line (`line.confirmed` in `booking.outbox`); else `SCRIPT skip what=b2b`.
`dry_run` rolls everything back after the checks; apply = one-line PR `MODE = "apply"` (commits only when the verdict is
ok; idempotent per UTC day). Refuses without bk-026. Notes: AA-Booking `docs/implementation-notes/AA-682.md`.

`aa991_freshness_probe.py` (AA-991, S251, read-only): the downstream freshness probe. Inside one read-only snapshot
it switches to `cis_app` and counts, per layer, the links that did not follow a tour's atoms (`SCRIPT metric name=…
gate=stale|info n=… aged=… sample=…`; aged = the tour changed more than 24 h before the run), the catalogue size and
the visibility floor (`SCRIPT totals …`), the pipeline jobs queued or running (`SCRIPT jobs …`), then
`SCRIPT verdict stale=<n> stale_aged=<n> errors=<n> list=…` and the same `SCRIPT json[i/n] <part>|` framing as the
liveness probe. main() always returns 0; the nightly **DB Freshness Probe** runs it and `db/freshness_gate.py` decides
(report mode until AA-988/989/990 close; metrics and the S251 baseline in `db/README.md`). Ids only (at most 5 per
metric, anything not id-shaped printed as `masked`); a failed metric logs its exception class and SQLSTATE, the
server message only for class 42.

`s248_tour_deletion_probe.py` (AA-986, S248, read-only): the cross-app half of the tour-deletion propagation probe
(root repo audit `docs/audits/2026-10-23-S248-tour-deletion-propagation/`; the CIS half runs by ECS exec as
`cis_app`). Buckets the AA master tenant's `silver_aa_internal.raw_tours` versions by the live rule
(`source_status = 'active' AND deleted_at IS NULL`, grouped by `source_key`): `group_dead`, `trashed_versions`,
`superseded_versions`, `lifecycle_retired` / `lifecycle_phasing_out` (context only) and `live_source_not_in_catalog`.
For each bucket it counts what still references the tour: the real `catalog.v_tour` (read as `booking`, else
`tripplanner`; `SCRIPT catalog role=-` when neither can, and the catalog layer and `global` lines are skipped),
`booking.trip_plans` (sellable), components, upcoming departures (unsold, and sold = with a confirmed hold), open B2B
quotes, active and confirmed holds, open and closed trip cases, and `tripplanner.trip_drafts` (draft / sent). Each layer carries `expect=zero|keep_warn|info`;
`SCRIPT verdict violations=<n> errors=<n> list=… pending=<n>` lists the `zero` layers and checks with hits, and
`SCRIPT json[i/n] <part>|` lines hold everything (parts of at most 8000 characters, joined in order; the closing `|`
shows a part cut short). `SCRIPT check …` lines are the ADR 0015 decision 6 invariants (L2 Masters, lifecycle record and
all-superseded groups, L4 tombstone, L3 / L5 "nothing new after the key stopped being served"; `pending` until their
slice lands, an error once the slice is in `LANDED` and its object is missing). `SCRIPT visibility …` is the floor
that turns a login hidden from the FORCE RLS rows into an error instead of a silent pass. main() always returns 0; since AA-986 L7b the nightly **DB Tour Liveness Gate** runs it and fails on the
verdict (`db/README.md`, "Tour liveness gate"). Prints counts, ids and keys only (at most 5 per line, anything not
id-shaped printed as `masked`); a failed layer logs its exception class and SQLSTATE, with the server message only for
class 42. The `expect` values follow ADR 0015 (Q4: sold Booking items kept and flagged; Q9: `lifecycle_stage` is
context): one constant each to change.

`s249_drill_*.py` (AA-829, S249 restore drill + single-schema restore rehearsal, docs/ops/runbooks/restore-rds-pitr.md
and restore-schema.md): `s249_drill_rehearsal_setup.py` (WRITE, synthetic) creates the throw-away schema `drill_s249`
with 100 rows, waits 2 minutes and deletes 40 (prints T1/T2 for the PITR restore point); `s249_drill_compare.py`
(read-only) compares the PITR copy `aa-cis-dev-db-drill-20261023` with live per schema; `s249_drill_schema_restore.py`
(WRITE) copies the 40 missing rows back from the copy in one transaction and refuses any other count;
`s249_drill_cleanup.py` (WRITE) drops `drill_s249`. The copy's host is derived from `db.dev.internal` in the task,
so no endpoint is written here. One-off: delete these four files once the drill record is in `docs/ops/drills/`.

`aa990_reader_checks.py` (AA-990, S252, read-only): do the readers outside CIS follow the S1 v2 rewrite? Saved
TripPlanner pins (`add_component` events through `tripplanner.component_id_map`) that no longer resolve to a
`geo.tour_place` row (`dangling`) or sit on replaced atoms, and the CRM AA catalog cache per served state (live
`catalog.v_tour.content_hash` matches, tours not cached yet, pass state). Counts and timestamps only; always returns 0.

`aa990_component_id_backfill.py` (AA-990, S252, one-time): re-points TripPlanner saved pins whose component a CIS
place rebuild dropped BEFORE CIS 285 (since 285 every rebuild writes `geo.component_redirect` and TripPlanner follows
it). Resolves each pin the way TripPlanner does (`component_id_map` first, else `geo.component_redirect`, ≤ 5 hops,
cycle-safe); for a chain that ends without a `geo.tour_place` row it recovers the old place by recomputing the uuid5
component ids from every atom of the tour (soft-deleted ones included; a field the versions disagree on is left
unknown, never the first row's value), else from the `trip_drafts` projection, then picks the current component of the
same place (destination → card → spelling + country → link name, nearest day; a generic name such as "Night Market" by
spelling / link name only in the same locality, else unmatched `generic_no_locality`). INSERT only, as `tripplanner`
(the AA-847 path; tp-017 keeps the map insert-only): one row per chain end. Merged with `READ_ONLY = True` = DRY RUN
(counts: dangling by origin, timing, snapshot availability, recovery source, rule, unmatched reason, planned inserts,
expected dangling after); a one-line PR sets `READ_ONLY = False` to apply, which prints `SCRIPT restore op=insert …`
lines (component ids only) as the undo. Idempotent.

`aa990_reader_checks.py` also prints `pins_chain` / `tp_pins_served_chain`: the same pin checks resolved the
TripPlanner way (chain over both sources); compare them with the one-hop `pins` / `tp_pins_served` baseline.

`aa838_capacity_probe.py` (AA-838, S255, monthly C8 capacity review; read-only, `READ_ONLY = True`): database size and
cache hit, size per schema, top tables (heap / index / toast, estimated rows, dead tuples), unused indexes, ledger row
counts and age against the C5.4 / DM-7 retention windows, job durations per kind (30 days), connections per role and
`application_name`, locks, `pg_stat_statements` top statements per role and the C1.2 SLI approximations
(`mean + 2 x stddev`). Prints `PROBE ` lines: aggregates, object names and normalised statement text only (constants
are `$n`), never row values; never calls `pg_stat_statements_reset()` (C4.3a). Through run-script it sees every
role's statement text (master); the same file also runs by S3-mediated ECS exec as `cis_app` (other roles' text
hidden). `PROBE_TOP` (default 20) and `PROBE_QTEXT` (default 160) size the output. Report: root
`docs/audits/2026-10-28-S255-aa838-capacity/`.

`aa850_dead_table_dry_run.py` (AA-850, S255; read-only DRY RUN, step 1 of `skill/aa-cis-schema/references/
destructive-ops.md`, data standards DM-3.8 / DM-3.9): Dead Table Registry census (rows, size, last write, scan and
write counters, vacuum/analyze times per table) and wave-1 quarantine readiness (existence, dependent views /
functions / triggers / policies / FKs, grants, `pg_stat_statements` calls per role, tenant rows), ending with
`SCRIPT verdict quarantine_ready=<true|false> reasons=<...>`. Counts, names, timestamps and roles only. Dispatch it
twice: T0, then T1 >= 14 days later or right before the quarantine migration; the wave-1 counters must not move
between the two (same `stats_reset`). The ECS-exec fallback sets the session read-only with `SET SESSION
CHARACTERISTICS AS TRANSACTION READ ONLY` (the runner's shape check refuses a literal naming
`default_transaction_read_only`). Wave 1 is done: CIS 294 quarantined the ten objects and CIS 296 drops them (the
14-day wait and the T1 run waived by Nghiệp, S255), so the script's wave-1 list now reports them missing; edit the
list for the next wave.
