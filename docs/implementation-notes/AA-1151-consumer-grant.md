# AA-1151 — consumer grant of the place add-ons view

## Decisions

- `db/owners.yaml` (booking `consumer_grants`) and `db/isolation_probe.py` `CONSUMER_GRANTS` name
  `booking.v_place_addons` (Booking bk-068, contract `supply.place_addons.v1`), `USAGE, SELECT` to `tripplanner`, with
  `expected_from` `bk-068`: the probe cell `consumer.contract_grants.bk-068` stays `pending` until bk-068 is
  registered, so this PR may merge before the apply (as the bk-039 / bk-062 rows did).
- The offer tables (`booking.addon_offers`, `booking.addon_offer_places`) are not granted to any other app: the view is
  the only door (no net, price or supplier identity).

## Should know

- bk-068 is a contract file: the bot copies it (`db/migrations/booking/068_addon_offers.sql`) once the Booking
  migration PR merges; Migration Apply applies it once every job table is idle (root ADR 0017a). After the apply the
  nightly probe (or a manual DB Isolation Probe run) should show `consumer.contract_grants.bk-068` = pass.
- bk-067 belongs to another S289 lane; the number of this file follows the Booking main at ship.
