# AA-1038 R5 slice 2 — consumer grant of the TripPlanner tenant view

## Decisions

- `db/owners.yaml` (cis `consumer_grants`) and `db/isolation_probe.py` `CONSUMER_GRANTS` name
  `catalog.v_tenant_tripplanner_v1` (CIS 379, contract `tenant.entitlements.v1` 1.4), `USAGE, SELECT` to
  `tripplanner`, with `expected_from` `379`: the probe cell `consumer.contract_grants.379` stays `pending` until CIS 379
  is registered, so this PR may merge before the apply. The `catalog.* (schema + views)` wildcard row already covers
  the grant for rule g; the named row adds the per-object probe check (as bk-039's `booking.v_from_prices` did).
- `db/tests/test_owners_registry.py`: the "single named object" pattern now allows digits after the first letter
  (`v_tenant_tripplanner_v1`); no existing contract row changes class.
- `db/rls_catalogue_rules.py`: byte copy of AA-CIS-App `tests/integration/rls_catalogue_rules.py` with the rule a
  allowlist entry `shared.tenant_tripplanner_site` (a CIS control-plane table with `tenant_id`, RLS off on purpose).

## Should know

- Merge after the AA-CIS-App PR that adds 379 is on CIS `main`: the Migration Copy Guard compares
  `db/rls_catalogue_rules.py` with CIS `main` byte for byte.
- CIS 379 is a contract file: the bot copies it (`db/migrations/cis/379_…`), Migration Apply applies it once every job
  table is idle (root ADR 0017a). After the apply the nightly probe (or a manual DB Isolation Probe run) should show
  `consumer.contract_grants.379` = pass.
- Local run: `db/tests` green except `test_schema_reference.py::CodeSpanTest::test_code_span_wraps_backticks_and_url_like_text`,
  which fails the same way on `main` in this environment.
