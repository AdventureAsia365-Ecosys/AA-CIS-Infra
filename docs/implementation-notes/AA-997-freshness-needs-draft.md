# AA-997 / AA-991 follow-up (S262 lane w1d): the probe reads `needs_draft` card rows

Companion of AA-CIS-App `fix/aa-991-needs-draft-rows`. The DB Freshness Probe was red four nights:
`place_card_links_missing` = 111 active place atoms in 12 tours. Every one of them was a group that the $0 card relink
after `a3_atomize` (AA-989, `max_places=0`) left for a paid draft, with no `atom_place_card` row at all. The CIS fix now
writes a row with `card_id` NULL and `miss_reason = 'needs_draft'` for such atoms, and links the ones whose replaced
predecessor carried exactly one card.

## Decisions
- **`place_card_links_missing` (stale) keeps "no row at all".** A `needs_draft` row is a row, so its atom is not
  missing: the relink ran and recorded it. It still catches a relink that did not run.
- **The "carded before" test ignores `needs_draft` rows** (`k.miss_reason IS DISTINCT FROM 'needs_draft'`). A tour
  whose only rows are "waiting for a draft" was never carded, so its other atoms are not a lost link.
- **New info metric `place_card_needs_draft`.** It counts active place atoms with `card_id` NULL and
  `miss_reason = 'needs_draft'`. Baseline `None` (first run).
- **`active_place_atoms_card_miss` (info) excludes `needs_draft`.** It keeps meaning "a resolved miss".
  Card coverage is now: linked + resolved miss (`active_place_atoms_card_miss`) + waiting
  (`place_card_needs_draft`) + no row (`active_place_atoms_without_card_link`) = `totals.active_place_atoms`.
- `NEEDS_DRAFT` mirrors AA-CIS-App `services/acp_shared/place_cards.py` `NEEDS_DRAFT`. A rename there must change it here.

## Changed
- `db/scripts/aa991_freshness_probe.py`: `NEEDS_DRAFT`, the `place_card_links_missing` EXISTS clause, the new
  metric, `active_place_atoms_card_miss`, `ORDER`, and the docstring.
- `db/freshness_gate.py`: BASELINE entry `place_card_needs_draft: None`. The gate turns red when a BASELINE metric is
  missing from the JSON, so the probe and the gate ship together in this PR.
- `db/tests/test_aa991_freshness_probe.py`: SQL assertions.
- `db/tests/test_aa991_freshness_probe_pg.py`: the seed adds `a71` (linked) and `a72` (`needs_draft`) in T7 and `a6`
  (`needs_draft`, T3's only row). Expected values:
  - `place_card_links_missing` stays (1, 1) `a3`. Without the EXISTS filter, T3 would count as carded and `a5` would
    be counted too; verified by reverting the filter, which fails 2 tests.
  - `place_card_needs_draft` (2, 1): `a6` (T3, inside the window) and `a72` (aged).
  - `active_place_atoms_without_card_link` (5, 3) → (2, 1): `a3`, `a5`.
- `db/README.md`: the metric table.

## Tradeoffs
- No ENFORCE change and no stale gate on `needs_draft`. Waiting for a paid draft is a cost decision (the paid-run
  rule), not staleness.
- Before the CIS PR is deployed and the 12 tours are relinked, the probe stays red: their atoms still have no row.

## Should know
- Expected after the CIS deploy + `relink.py APPLY=1`: `place_card_links_missing` 0, `place_card_needs_draft` ≈ 106
  (111 minus the ~5 carried over), `active_place_atoms_card_miss` unchanged.
- Local PG test: PostgreSQL 16 binaries in a scratch dir (TCP only, `-k ''`), asyncpg from the CIS venv:
  `AA991_TEST_PG_DSN=postgresql://postgres@127.0.0.1:55491/postgres python -m unittest db.tests.test_aa991_freshness_probe_pg`
  → 6 OK. `python3 -m unittest discover -s db/tests -p 'test_aa991*'` → 41 OK (6 skipped without a DSN).
