# AA-852 — X1 S7: Infra copy of TripPlanner tp-013 (branch `feat/x1-s7-copy-tp013`)

Plan: `AA-Ecosys/docs/audits/2026-10-17-S241-x1/x1-plan.md` §5 S7/S8. Owner file and full notes:
AA-TripPlanner-Web `migrations/013_x1_tp_owner.sql`, `docs/implementation-notes/AA-852.md`.

## Decisions
- **Not a standalone PR** (review S241): this branch is folded into the **S8 train PR** (`roles/001` +
  copies `cis/243`, `booking/014`, `tripplanner/013`), or kept as a draft until the TripPlanner PR is on
  `main` and the rl-001 + 243 copies are in the same PR. A copy merged alone starts no migration freeze,
  and a TripPlanner PR written under the old rules could land between its merge and the apply.
- **`db/owners.yaml`**: `tripplanner.owner_role_today: tp_owner`, in its own commit so the train can drop
  it if the apply slips. It describes the state from the tp-013 apply on (minutes after the train merges);
  nothing reads the field to pick a role (the runner reads the live schema owner, XD8).

## Changed
- The copy follows the TripPlanner review fixes (raw-ACL snapshot, guard 2 over every owned kind the
  runner's post-check scans). Byte-identical (`cmp`).

## Tradeoffs
- `owner_role_today` in the train rather than a follow-up after the apply: one PR fewer and it cannot be
  forgotten; cost: wrong for the minutes between the train merge and the tp-013 apply.

## Should know
- **Train PR body, dispatch order:** DB Migrate `check` then `apply` for `roles/001_x1_owner_roles.sql` →
  `cis/243_x1_owner_role_grants.sql` → `booking/014_x1_bk_owner.sql` → `tripplanner/013_x1_tp_owner.sql`.
  tp-013 guard 1 refuses (nothing changed) if rl-001 or 243 is missing.
- **Freeze:** announce the TripPlanner + Booking migration freeze when the train merges; lift it only after
  the S9 probe `tp-014` apply prints `ran as: tp_owner`.
- **Pre-apply read-only check** (extended statistics, collation, operator, opclass/opfamily, text search,
  conversion in `tripplanner` must be 0): query in the TripPlanner notes, section "S8 train".
- **After the apply:** the DB Schema Dump PR shows owner `tp_owner` on all 16 objects plus the six
  `FOR ROLE tp_owner` default-privilege rows.
- **Rollback:** branch `feat/x1-s7-tp013-undo`, `db/migrations/roles/003_x1_tp_owner_undo.sql` (rl-003),
  unmerged; see `docs/implementation-notes/AA-852-s7-tp013-undo.md` there.
- Checks on this branch: `python3 -m unittest discover -s db/tests` 124 OK; `check_migration_files.py`
  47 files, 0 problems; `--inspect` on the copy clean. Copy Guard stays red until the TripPlanner PR merges.
