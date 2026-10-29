-- Migration bk-035: AA-1003 R2 — key-level contract view of the inquiry inbox for the CIS TP-03 handoff check.
--
-- Owner: AA-Booking (key bk-NNN). AA-CIS-Infra Migration Sync copies it byte for byte to
-- db/migrations/booking/035_ops_inquiry_inbox_view.sql; it is applied to Dev by the DB Migrate workflow (check, then
-- apply), as bk_owner (the live owner of schema booking since bk-014). Never run it from a laptop.
--
-- Why (AA-1003 R2, AA-CIS-App docs/implementation-notes/AA-1003.md "R2 follow-up requests" item 3): the CIS TP-03
-- report and its hourly check reconcile "inquiries TripPlanner sent" with "inquiries the Booking inbox received". With
-- the day counts of bk-017 (v_ops_funnel_daily) CIS can say how many are missing, parked or failed, not which one,
-- since when, or whether a received inquiry ever became a trip case. Booking, the owner, publishes the key and state
-- of every recent inquiry so CIS can match it with tripplanner.v_ops_inquiry_keys (tp-022) one by one.
--
-- v_ops_inquiry_inbox (source text, idempotency_key text, status text, received_at timestamptz,
-- processed_at timestamptz, has_trip_case boolean): one row per booking.inbox_events row of contract inquiry.submitted
-- received in the last 30 days (the CIS window is 7 UTC days).
--   source         inbox source ('tripplanner', 'cis')
--   idempotency_key the sender's hand-off key (TripPlanner: "<trip id>:<hand-off id>"), internal ids only
--   status         received / processed / parked / failed (inbox_events_status_chk)
--   has_trip_case  a booking.trip_cases row carries the same idempotency_key (the intake writes it, and its no-op
--                  path finds it the same way; trip_cases_idempotency_key_uq makes it an index probe). A case that was
--                  soft-deleted later still counts: the inquiry did become a case.
-- No payload, no error text (pii:free_text), no customer, no case id or code.
--
-- Contract: AA-Ecosys docs/contracts/ops.overview.v1.md, family ops.overview.v1 (key view). Column list append-only.
-- Readers: cis_app gets SELECT on the view (USAGE on schema booking is held since bk-017; repeated here, idempotent).
-- The view reads its base tables with its owner's (bk_owner's) rights, so cis_app needs nothing on them (they stay
-- 42501, isolation probe cell cross.cis_app.booking.customers).
--
-- Class: contract, not expand (root ADR 0017 d3, "What stays manual"): the grant to cis_app is a cross-owner grant
-- (AA-CIS-Infra owners.yaml booking.consumer_grants + the isolation probe), and the expand lint of
-- db/run_migration.py lets an expand file grant only to the owner's own runtime role (booking). The REVOKE of the
-- default DML and the guard (DO block) are contract too. So the Migration Apply pipeline stops at this file and a
-- person dispatches DB Migrate apply for booking/035_ops_inquiry_inbox_view.sql. No readiness key: no Booking code
-- reads the view.
--
-- Re-runnable (the Integration Tests replay every file): CREATE OR REPLACE VIEW keeps the column list; the REVOKE and
-- grants repeat. The guard raises (it never skips) when cis_app is missing.
-- Cost: a range scan of inbox_events_pending_idx / a scan of < 100 rows on Dev, one unique-index probe per row; read
-- hourly by CIS.
-- Undo: DROP VIEW booking.v_ops_inquiry_inbox (a later bk- file, after the CIS reader is gone); keep USAGE on the
-- schema (bk-017 still needs it).

BEGIN;

DO $$
BEGIN
    IF current_user <> 'bk_owner' THEN
        RAISE EXCEPTION 'bk-035: expected to run as bk_owner (live owner of schema booking), running as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cis_app') THEN
        RAISE EXCEPTION 'bk-035: role cis_app is missing (AA-CIS-Infra roles/001, rl-001)';
    END IF;
END $$;

CREATE OR REPLACE VIEW booking.v_ops_inquiry_inbox AS
SELECT e.source,
       e.idempotency_key,
       e.status,
       e.received_at,
       e.processed_at,
       EXISTS (SELECT 1 FROM booking.trip_cases tc WHERE tc.idempotency_key = e.idempotency_key) AS has_trip_case
  FROM booking.inbox_events e
 WHERE e.contract = 'inquiry.submitted'
   AND e.received_at >= now() - interval '30 days';

COMMENT ON VIEW booking.v_ops_inquiry_inbox IS
    'bk-035 (AA-1003): source, hand-off key, status, received / processed time and whether a trip case exists, for each inquiry.submitted inbox row of the last 30 days; keys, states and timestamps only, no payload, error text or customer. Contract ops.overview.v1 (key view), read by AA-CIS-App TP-03 inquiry handoff check (role cis_app).';

-- Role booking: read-only on the view (default privileges FOR ROLE bk_owner gave it DML).
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON booking.v_ops_inquiry_inbox FROM booking;

-- The CIS reader (contract grant; AA-CIS-Infra db/owners.yaml booking.consumer_grants).
GRANT USAGE ON SCHEMA booking TO cis_app;
GRANT SELECT ON booking.v_ops_inquiry_inbox TO cis_app;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-035', now(), 'AA-1003: inquiry inbox key contract view booking.v_ops_inquiry_inbox, SELECT to cis_app')
ON CONFLICT (version) DO NOTHING;

COMMIT;
