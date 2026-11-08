# AA-1046 follow-up: registry and isolation probe after the booking inquiry grant revoke (S273 lane l8)

TripPlanner tp-027 revokes role `booking`'s SELECT on `tripplanner.v_inquiry_outbox` and its USAGE on schema
`tripplanner` (tp-009 grants of the retired inquiry.submitted contract; the owner view's payload carries every
tenant's traveller data and bypasses the tp-025 shadow RLS). This PR keeps the registry and the nightly probe in step.

## Decisions

- **owners.yaml**: the `booking` consumer grant row on `tripplanner.v_inquiry_outbox` goes (no consumer, no contract).
- **isolation_probe.py**: the matching `CONSUMER_GRANTS` row goes, and a `CROSS_APP` row asserts `booking` gets 42501
  on the view through its own login, keyed on `tp-027` (new state key in `VERSION_KEYS` / `KEY_TEXT`). Pending until
  tp-027 is registered, so the cell is order-safe; once registered, a readable view (or a 42P01 after a drop) fails it.
  A cross-app cell, not a consumer cell with a "must be absent" flag: the probe already reads cross-app targets
  through each role's own login, which is the only isolation evidence it accepts.
- **rls_catalogue_rules.py**: byte copy of AA-CIS-App's canonical file, which drops the two rule-g allowlist entries
  (`tripplanner:booking`, `tripplanner.v_inquiry_outbox:booking`).

## Changed

- `db/owners.yaml`, `db/isolation_probe.py` (+ docstring), `db/rls_catalogue_rules.py` (copy), `db/README.md`
  (probe section), `db/tests/test_isolation_probe.py` (today's facts carry booking's live read of the view; the new
  cell is pending today, FAIL when tp-027 is registered and the view is readable or missing, pass on 42501; the
  consumer-lost test picks its grant by object instead of list position).

## Tradeoffs

- Removing the always-expected consumer row before the apply means the probe stops asserting booking HAS the grant
  a little early; nothing reads it (Booking's intake has no handler), so that is the intended direction.

## Should know

- **Merge order**: AA-CIS-App PR (canonical rules) first, because the Migration Copy Guard compares
  `db/rls_catalogue_rules.py` with AA-CIS-App `main`; then this PR; then the Migration Apply of
  `tripplanner/027_revoke_booking_inquiry_grant.sql` (Infra bot copy PR after the TripPlanner migration-only PR). This
  PR must be merged before the apply: until then the probe's always-expected `consumer.contract_grants` cell expects
  booking's grant and would turn red after the revoke.
- The later destructive drop of the view must remove the `CROSS_APP` row in the same PR (a missing view answers
  42P01, not 42501; comment on the row).
