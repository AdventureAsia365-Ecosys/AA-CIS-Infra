-- Migration bk-017: AA-858 — ops overview contract views for the CIS admin console (/admin/overview).
--
-- Owner: AA-Booking (key bk-NNN). A byte-identical copy goes to AA-CIS-Infra db/migrations/booking/017_ops_overview_views.sql
-- and is applied to Dev by the DB Migrate workflow (check, then apply), as bk_owner (the live owner of schema booking
-- since bk-014). Never run it from a laptop. Apply order on Dev: bk-016 (AA-680) first, then this file.
--
-- Why (AA-858; root ADR 0008 §5, S241 admin-console README §6): the CIS admin overview shows a Booking funnel
-- (inquiries -> trip cases -> proposals sent -> confirmed) without reading booking.* tables. Booking, the owner,
-- publishes two aggregate views in its own schema and grants them to the CIS runtime role cis_app (no new contract
-- schema; same pattern as tripplanner.v_inquiry_outbox -> booking). Aggregates only: no id, no name, no e-mail, no
-- payload, no free text. Every other booking.* object stays 42501 for cis_app (isolation probe cell
-- cross.cis_app.booking.customers).
--
-- Readers: cis_app gets USAGE on schema booking + SELECT on the two views (X1: the CIS runtime moves to cis_app at
-- S18). Until then the CIS runtime logs in as the RDS master aa_cis_admin, a member of bk_owner (rl-001), so it already
-- reads these views as their owner's member; nothing extra is granted to it. A view reads its base tables with its
-- owner's (bk_owner's) rights, so cis_app needs nothing on the tables.
--
-- v_ops_funnel_daily (day date, metric text, source_system text, n bigint), long format, UTC days, last 400 days:
--   inquiry_received  booking.inbox_events, contract inquiry.submitted, by received_at; source_system = inbox source
--   inquiry_parked    the same rows whose current status is parked (by received_at)
--   inquiry_failed    the same rows whose current status is failed (by received_at)
--   trip_case_created booking.trip_cases not soft-deleted, by created_at
--   proposal_sent / confirmed / cancelled
--                     the FIRST time a not soft-deleted case reached that status (trip_case_status_history, written by
--                     trigger only), dated at that first time: a case sent twice counts once, a reopened case that is
--                     cancelled again counts once
-- v_ops_case_status (status text, n bigint): not soft-deleted trip cases by current status.
-- Metric names are part of the contract (AA-Ecosys docs/contracts/ops.overview.v1.md): add new names, never rename.
--
-- Re-runnable (the Integration Tests replay every file): CREATE OR REPLACE VIEW keeps the column list; grants repeat.
-- Undo: DROP VIEW booking.v_ops_funnel_daily, booking.v_ops_case_status; REVOKE USAGE ON SCHEMA booking FROM cis_app
-- (a later bk- file, after the CIS reader is gone).

BEGIN;

DO $$
BEGIN
    IF current_user <> 'bk_owner' THEN
        RAISE EXCEPTION 'bk-017: expected to run as bk_owner (live owner of schema booking), running as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cis_app') THEN
        RAISE EXCEPTION 'bk-017: role cis_app is missing (AA-CIS-Infra roles/001, rl-001)';
    END IF;
END $$;

CREATE OR REPLACE VIEW booking.v_ops_funnel_daily AS
SELECT (e.received_at AT TIME ZONE 'UTC')::date AS day,
       'inquiry_received'::text AS metric,
       e.source AS source_system,
       count(*)::bigint AS n
  FROM booking.inbox_events e
 WHERE e.contract = 'inquiry.submitted'
   AND e.received_at >= now() - interval '400 days'
 GROUP BY 1, 3
UNION ALL
SELECT (e.received_at AT TIME ZONE 'UTC')::date,
       ('inquiry_' || e.status)::text,
       e.source,
       count(*)::bigint
  FROM booking.inbox_events e
 WHERE e.contract = 'inquiry.submitted'
   AND e.status IN ('parked', 'failed')
   AND e.received_at >= now() - interval '400 days'
 GROUP BY 1, 2, 3
UNION ALL
SELECT (tc.created_at AT TIME ZONE 'UTC')::date,
       'trip_case_created'::text,
       tc.source_system,
       count(*)::bigint
  FROM booking.trip_cases tc
 WHERE tc.deleted_at IS NULL
   AND tc.created_at >= now() - interval '400 days'
 GROUP BY 1, 3
UNION ALL
SELECT (m.first_at AT TIME ZONE 'UTC')::date,
       m.to_status,
       tc.source_system,
       count(*)::bigint
  FROM (SELECT h.trip_case_id, h.to_status, min(h.changed_at) AS first_at
          FROM booking.trip_case_status_history h
         WHERE h.to_status IN ('proposal_sent', 'confirmed', 'cancelled')
         GROUP BY h.trip_case_id, h.to_status) m
  JOIN booking.trip_cases tc ON tc.id = m.trip_case_id
 WHERE tc.deleted_at IS NULL
   AND m.first_at >= now() - interval '400 days'
 GROUP BY 1, 2, 3;

COMMENT ON VIEW booking.v_ops_funnel_daily IS
    'bk-017 (AA-858): Booking funnel per UTC day and source system, aggregates only, last 400 days. Contract ops.overview.v1, read by AA-CIS-App /admin/overview (role cis_app).';

CREATE OR REPLACE VIEW booking.v_ops_case_status AS
SELECT tc.status, count(*)::bigint AS n
  FROM booking.trip_cases tc
 WHERE tc.deleted_at IS NULL
 GROUP BY tc.status;

COMMENT ON VIEW booking.v_ops_case_status IS
    'bk-017 (AA-858): not soft-deleted trip cases by current status, aggregates only. Contract ops.overview.v1, read by AA-CIS-App /admin/overview (role cis_app).';

-- Role booking: read-only on both views (default privileges FOR ROLE bk_owner gave it DML).
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON booking.v_ops_funnel_daily FROM booking;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON booking.v_ops_case_status FROM booking;

-- The CIS reader (contract grant; AA-CIS-Infra db/owners.yaml booking.consumer_grants).
GRANT USAGE ON SCHEMA booking TO cis_app;
GRANT SELECT ON booking.v_ops_funnel_daily, booking.v_ops_case_status TO cis_app;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-017', now(), 'AA-858: ops overview contract views booking.v_ops_funnel_daily + v_ops_case_status, SELECT to cis_app')
ON CONFLICT (version) DO NOTHING;

COMMIT;
