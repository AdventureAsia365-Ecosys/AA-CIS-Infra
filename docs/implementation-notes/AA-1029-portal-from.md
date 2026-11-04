# AA-1029 R4: the Content studio Marketplace "from" price, Infra part (S268, lane portal-from)

## Decisions

- Register the new consumer grant of Booking bk-040: `cis_app` gets `USAGE, SELECT` on `booking.v_from_prices`
  (contract price.from.v1) for the CIS pool read behind the Content studio Marketplace. Same shape as the bk-039
  TripPlanner entry: `db/owners.yaml` `booking.consumer_grants` (`expected_from: bk-040`), the isolation probe cell
  `consumer.contract_grants.bk-040` (pending until bk-040 is registered, so merging before the apply never turns the
  nightly probe red) and the `rls_catalogue_rules.py` allowlist key (byte copy of CIS main).

## Changed

- `db/tests/test_isolation_probe.py`: the keyed consumer grant list and a cell test for bk-040.

## Tradeoffs

- None beyond the CIS / Booking choice (see AA-CIS-App and AA-Booking `docs/implementation-notes/AA-1029-portal-from.md`).

## Should know

- Merge after the CIS PR (the copy guard compares `db/rls_catalogue_rules.py` with CIS main) and after the bot copy of
  booking/040 lands; bk-040 is a contract file: Migration Apply applies it once every job table is idle.
