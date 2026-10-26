# Data coverage (AA-992) — AA-CIS-Infra bookkeeping

The CIS admin page `/admin/data-coverage` reads five new owner contract views as `cis_app` (family
`ops.data_coverage.v1`): TripPlanner tp-020 (`tripplanner.v_ops_data_totals`, `v_ops_pin_components`,
`v_ops_component_id_map`) and Booking bk-025 (`booking.v_ops_data_totals`, `v_ops_trip_plan_keys`). The CRM part goes
over HTTP (`crm.ops.v1` 1.3): nothing here for schema `crm`.

## Decisions

- Byte-identical copies `db/migrations/tripplanner/020_ops_data_coverage_views.sql` and
  `db/migrations/booking/025_ops_data_coverage_views.sql` (`run_migration.py --inspect`: no error, no warning).
- `db/owners.yaml` `consumer_grants`: 5 rows, `status: contract`, `expected_from: tp-020 / bk-025`.
- `db/isolation_probe.py` `CONSUMER_GRANTS`: the same 5 cells, keyed on tp-020 / bk-025 (pending until registered,
  never FAIL before the apply; `CONSUMER_GRANT_KEYS`, `VERSION_KEYS`, `KEY_TEXT` follow automatically).
- `db/rls_catalogue_rules.py`: byte copy of AA-CIS-App `tests/integration/rls_catalogue_rules.py` with the 5 rule-g
  allow-list keys (critic B7: the CIS canonical file lands first).
- The design's tp-020 had two views; the build has three (`v_ops_component_id_map` added so CIS can walk the AA-990
  id-map + redirect chain), so the counts are 5 grants, not 4.

## Changed

- The four files above + `db/tests/test_isolation_probe.py` (key tuple, generic pending check, a bk-025 / tp-020 cell
  test).

## Tradeoffs

- No new `owner_grants` and no role change: `cis_app` exists since rl-001 and holds USAGE on both schemas since
  bk-017 / tp-015.

## Should know

- Merge order: TripPlanner and Booking PRs (the owners' files), AA-CIS-App rule-g PR, then this PR (Migration Copy
  Guard compares against the owners' main and the CIS canonical rules file). Then DB Migrate `check` → `apply`
  (tripplanner, booking; every job table idle), then the `bot/db-schema-reference` PR.
- `db/tests`: 747 passed; `test_schema_reference.py::CodeSpanTest::test_code_span_wraps_backticks_and_url_like_text`
  fails locally on main too (unrelated to this change).
- Fix round 2: the tripplanner copy re-taken byte-identical after tp-020 gained the UUID shape filter on the pins
  view and the `pin_events_invalid_id` totals metric (no grant or probe change: same three views); branch rebased on
  `origin/main` (crm-020 copy, Content studio edge).
