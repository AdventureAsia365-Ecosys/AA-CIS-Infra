-- Migration tp-009: AA-681 — AA-Booking may read the inquiry.submitted outbox view.
--
-- Contract rules (AA-Ecosys docs/contracts/README.md): the producer owns the view and grants SELECT
-- on it to the consumer role in its own migration (rule 5), WITHOUT an IF EXISTS(role) guard — a
-- guarded no-op would still register tp-009 and hide a missing grant. Role `booking` exists since
-- AA-Booking bk-001 (AA-678); if it does not, this file fails loudly and is not registered.
--
-- `booking` gets USAGE on schema tripplanner and SELECT on tripplanner.v_inquiry_outbox only — not
-- on tripplanner.outbox or any other table. The view runs with its owner's rights, so no grant on
-- the table is needed. AA-Booking pulls with its bk_inquiry_pull job and keeps its own inbox
-- (booking.inbox_events); it never writes here (ADR 0001 decision 6).
--
-- Applied through AA-CIS-Infra DB Migrate (owner `tripplanner`), key tp-009. Re-running is a no-op.

BEGIN;

GRANT USAGE ON SCHEMA tripplanner TO booking;
GRANT SELECT ON tripplanner.v_inquiry_outbox TO booking;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('tp-009', now(), 'AA-681: grant role booking USAGE on schema tripplanner + SELECT on v_inquiry_outbox (inquiry.submitted pull consumer)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
