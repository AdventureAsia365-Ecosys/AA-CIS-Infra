# AA-852 — X1 S7 rollback: `roles/003_x1_tp_owner_undo.sql` (rl-003), PREPARED, NOT MERGED

Plan: `AA-Ecosys/docs/audits/2026-10-17-S241-x1/x1-plan.md` §5 S7 "Rollback: prepared (unmerged) roles/
undo file, key rl-0xx", review S241 point 1. Branch `feat/x1-s7-tp013-undo` from Infra `main` (eef43c0).
Open a PR for it only if tp-013 has to be undone.

## Decisions
- **roles/ file, run as the master.** After tp-013 the runner runs `tripplanner/` files as `tp_owner`
  (XD8), which is not a member of `aa_cis_admin`, so it cannot give objects back. `roles/` always runs as
  the master (member of `tp_owner` via rl-001). After it commits, the schema owner is the master again
  and the runner runs the next `tripplanner/` file as the master, automatically.
- **Key rl-003**: rl-001 = role bootstrap (S3), rl-002 reserved for S20 (`cis_owner`, `db_migrator`).
  Renumber to the next free roles/ number (file name + key) if 003 is taken when it is needed. Never
  `tp-014` (S9 probe key).
- **Mirror of tp-013**: (1) `FOR ROLE aa_cis_admin IN SCHEMA tripplanner` default privileges restored
  (tables DML, sequences USAGE/SELECT → `tripplanner`), (2) the `FOR ROLE tp_owner` rows revoked, (3)
  schema, 15 tables (owned sequences, indexes, row types follow) and `v_inquiry_outbox` back to
  `aa_cis_admin`. Explicit statements, `-- migrate: lock_timeout=5s`.
- **Guards**: guard 1 — session and current user are the master, `tp_owner` exists with the master a
  member, `tripplanner`/`booking` exist, tp-013 registered, schema owned by `tp_owner` (or the master: a
  re-run), and no object of any kind in `tripplanner` owned by a third role. Guard 2 — every kind the DB
  Migrate post-check scans owned by `aa_cis_admin`; raw ACLs (`aclexplode` of `nspacl`, `relacl` /
  `acldefault`, `attacl`) equal the snapshot with `tp_owner` read as `aa_cis_admin`; `has_*_privilege`
  of `tripplanner`/`booking` unchanged; default ACL exactly the six `aa_cis_admin` rows.

## Changed
- Nothing outside the new file and this note.

## Tradeoffs
- A real number (003) instead of a `0NN` template (the S6 Booking undo is kept as a template in the root
  audit folder): the file can run through `check_migration_files.py` / `--inspect` now; cost: a rename if
  003 is taken by the time it is needed.

## Should know
- **Valid only before any object created by tp-014 or later** (the S9 probe tp-014 creates none). Guard 2
  names any such object; add its `ALTER … OWNER TO aa_cis_admin` and re-run.
- **After an apply (by hand, same session):** tp-013 stays registered (a re-transfer is a new tp-NNN);
  the S2 probe cell "tripplanner owned by tp_owner" is keyed on tp-013 and turns red (re-key or waive);
  `db/owners.yaml` `owner_role_today` back to `aa_cis_admin`; TripPlanner `migration_lint.py`
  `migration_role()` and CONTEXT.md back to the master. The 243 grants to `tp_owner` stay (harmless).
- **Checked locally** (throwaway PostgreSQL 16.15, NOSUPERUSER master stand-in, tp-001…013 replayed from
  AA-TripPlanner-Web `feat/x1-s7-tp013` @ 2b620a5): applies after tp-013 → every object owned by
  `aa_cis_admin`, default ACL = the six master rows, a column grant to a third role comes back with grantor
  `aa_cis_admin`, `tripplanner` keeps DML, `booking` reads the view, a table the master creates afterwards
  is usable by `tripplanner`, re-run no-op, `rl-003` registered once; refuses a table owned by a third
  role (guard 1) and an unlisted `tp_owner` table (guard 2). Not run on PostgreSQL 15 (no PG 15 locally).
- **Lint:** `python3 db/run_migration.py --inspect db/migrations/roles/003_x1_tp_owner_undo.sql` → no
  errors, no warnings; `python3 db/check_migration_files.py` → 47 files, 0 problems;
  `check_registration('roles', '003', …)` → ok; `python3 -m unittest discover -s db/tests` → OK.
