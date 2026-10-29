-- Migration tp-022: AA-1003 R2 — key-level contract view of the inquiry outbox for the CIS TP-03 handoff check.
--
-- Why (AA-1003 R2, AA-CIS-App docs/implementation-notes/AA-1003.md "R2 follow-up requests" item 3): the CIS TP-03
-- report and its hourly check reconcile "inquiries TripPlanner sent" with "inquiries the Booking inbox received". With
-- the day counts of tp-015 (v_ops_traffic_daily.inquiry_sent) CIS can only say how many are missing, not which one or
-- since when. TripPlanner, the owner, publishes the key of every recent hand-off so CIS can match it one by one with
-- booking.v_ops_inquiry_inbox (bk-035): "key older than 15 minutes with no inbox row" is an exact, aged gap.
--
-- v_ops_inquiry_keys (idempotency_key text, created_at timestamptz): one row per tripplanner.outbox row of event
-- inquiry.submitted created in the last 30 days (the CIS window is 7 UTC days). idempotency_key is the hand-off key
-- TripPlanner writes and AA-Booking dedupes on (booking.inbox_events.idempotency_key): "<trip id>:<hand-off id>",
-- internal ids only. No payload, no customer, no contact, no aggregate column: the view never reads outbox.payload.
--
-- Contract: AA-Ecosys docs/contracts/ops.overview.v1.md, family ops.overview.v1 (key view). Column list append-only.
-- Readers: cis_app gets SELECT on the view (USAGE on schema tripplanner is held since tp-015; repeated here,
-- idempotent). The view reads tripplanner.outbox with its owner's (tp_owner's) rights, so cis_app needs nothing on the
-- table (it stays 42501, isolation probe cell cross.cis_app.tripplanner.sessions).
--
-- Class: contract, not expand (root ADR 0017 d3, "What stays manual"): the grant to cis_app is a cross-owner grant
-- (AA-CIS-Infra owners.yaml tripplanner.consumer_grants + the isolation probe), and the expand lint of
-- db/run_migration.py lets an expand file grant only to the owner's own runtime roles (tripplanner). The REVOKE of the
-- default DML and the guard (DO block) are contract too. So the Migration Apply pipeline stops at this file and a
-- person dispatches DB Migrate apply for tripplanner/022_ops_inquiry_keys_view.sql.
--
-- Applied through AA-CIS-Infra DB Migrate from the byte-identical copy db/migrations/tripplanner/022_ops_inquiry_keys_view.sql
-- (pulled by Migration Sync), as tp_owner (the live owner of schema tripplanner since tp-013, XD8). Never run it
-- from a laptop. Re-runnable: CREATE OR REPLACE VIEW keeps the column list; the REVOKE and grants repeat. The guard
-- raises (it never skips) when cis_app is missing.
-- Cost: an index range scan of outbox_redact_due_idx / a scan of a table of < 100 rows on Dev; read hourly by CIS.
-- Undo: DROP VIEW tripplanner.v_ops_inquiry_keys (a later tp- file, after the CIS reader is gone); keep USAGE on the
-- schema (tp-015 still needs it).

BEGIN;

DO $$
BEGIN
    IF current_user <> 'tp_owner' THEN
        RAISE EXCEPTION 'tp-022: expected to run as tp_owner (live owner of schema tripplanner), running as %', current_user;
    END IF;
    IF to_regrole('cis_app') IS NULL THEN
        RAISE EXCEPTION 'tp-022: role cis_app is missing (AA-CIS-Infra roles/001, rl-001)';
    END IF;
END $$;

CREATE OR REPLACE VIEW tripplanner.v_ops_inquiry_keys AS
SELECT o.idempotency_key, o.created_at
  FROM tripplanner.outbox o
 WHERE o.event = 'inquiry.submitted'
   AND o.created_at >= now() - interval '30 days';

COMMENT ON VIEW tripplanner.v_ops_inquiry_keys IS
    'tp-022 (AA-1003): hand-off key and time of each inquiry.submitted outbox row of the last 30 days; keys and timestamps only, no payload or contact. Contract ops.overview.v1 (key view), read by AA-CIS-App TP-03 inquiry handoff check (role cis_app).';

-- Runtime role tripplanner: read-only on the view (default privileges FOR ROLE tp_owner gave it DML).
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON tripplanner.v_ops_inquiry_keys FROM tripplanner;

-- The CIS reader (contract grant; AA-CIS-Infra db/owners.yaml tripplanner.consumer_grants).
GRANT USAGE ON SCHEMA tripplanner TO cis_app;
GRANT SELECT ON tripplanner.v_ops_inquiry_keys TO cis_app;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('tp-022', now(), 'AA-1003: inquiry key contract view tripplanner.v_ops_inquiry_keys, SELECT to cis_app')
ON CONFLICT (version) DO NOTHING;

COMMIT;
