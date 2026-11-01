# AA-1032 — Implementation notes (Infra, lane: ship tools)

## Decisions

- `db-migrate.yml` gets a `run-name`: `DB Migrate <mode> <migration><role><script>` (only one of the three inputs is
  set per mode, the "Validate input" step enforces that). The root tool `tools/github/ship_copy_apply.py` (and
  `dbmig.sh`, now a wrapper over it) matches the run it dispatched by this title. In S263 a helper read "the latest
  DB Migrate run" after dispatching and reported another file's run.

## Changed

- Only the run title. Inputs, jobs, concurrency and permissions are unchanged; the job name already carried the same
  values.

## Tradeoffs

- Without the title the root tool still works (local lock + "one new run since the dispatch", refusing to guess
  between two), so this PR can merge in any order with the root PR.

## Should know

- The title format is mirrored in `run_title()` of the root `tools/github/ship_copy_apply.py`: change both together.
