# AA-1003 R2 — consumer grants of the TP-03 inquiry key views

## Decisions

- `db/owners.yaml` `consumer_grants`, `db/isolation_probe.py` `CONSUMER_GRANTS` and the rule `g` allow-list name
  `tripplanner.v_ops_inquiry_keys` (tp-022, AA-TripPlanner-Web) and `booking.v_ops_inquiry_inbox` (bk-035,
  AA-Booking), both `SELECT` to `cis_app`, each with `expected_from`: the probe cells
  `consumer.contract_grants.tp-022` / `.bk-035` stay `pending` until the key is registered, so this PR may merge
  before the DB Migrate applies.
- Both owner files are **contract** files (cross-owner grant, root ADR 0017 "What stays manual"): Migration Sync
  copies them, Migration Apply stops at them, a person dispatches DB Migrate apply.

## Should know

- `db/rls_catalogue_rules.py` is a byte copy of AA-CIS-App `tests/integration/rls_catalogue_rules.py`: the Migration
  Copy Guard compares it with CIS `main`, so merge this PR after the CIS change (branch
  `feat/aa1003-r2-contract-key-views`, after CIS #1162) is on `main`.
- Local run: `db/tests` all green except `test_schema_reference.py::CodeSpanTest::test_code_span_wraps_backticks_and_url_like_text`,
  which fails the same way on `main` in this environment.
