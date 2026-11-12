# AA-1094 — consumer grant of the TripPlanner tenant tour view

## Decisions

- `db/owners.yaml` (cis `consumer_grants`) and `db/isolation_probe.py` `CONSUMER_GRANTS` name
  `catalog.v_tenant_tour_v1` (CIS 403, contract `catalog.tenant_tour.v1`), `USAGE, SELECT` to `tripplanner`, with
  `expected_from` `403`: the probe cell `consumer.contract_grants.403` stays `pending` until CIS 403 is registered, so
  this PR may merge before the apply (as the 379 row did). The `catalog.* (schema + views)` wildcard row already covers
  the grant for rule g.
- No change to `db/rls_catalogue_rules.py`: CIS 403's policy on `gold_aa_internal.tenant_tour_versions`
  (`catalog_owner_tenant_text_read`, SELECT TO `catalog_owner`) has a status condition, not `true` (rule t), and
  `catalog_owner` is a CIS role (rule g).

## Should know

- CIS 403 is a contract file: the bot copies it (`db/migrations/cis/403_…`) once the AA-CIS-App migration PR merges;
  Migration Apply applies it once every job table is idle (root ADR 0017a). After the apply the nightly probe (or a
  manual DB Isolation Probe run) should show `consumer.contract_grants.403` = pass.
