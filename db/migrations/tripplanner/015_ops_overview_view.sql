-- Migration tp-015: AA-858 — ops overview contract view for the CIS admin console (/admin/overview).
--
-- Why (AA-858; root ADR 0008 §5, S241 admin-console README §6): the CIS admin overview shows how many travellers use
-- the planner (planners started, trips started, trips edited, sent to an advisor) without reading tripplanner.*
-- tables. TripPlanner, the owner, publishes one aggregate view in its own schema and grants it to the CIS runtime role
-- cis_app (contract rule 5 of AA-Ecosys docs/contracts/README.md: the producer owns the view and grants SELECT in its
-- own migration; same pattern as tp-009 for booking). Aggregates only: no id, no token, no customer, no payload.
-- Every other tripplanner.* object stays 42501 for cis_app (isolation probe cell cross.cis_app.tripplanner.sessions).
--
-- Readers: cis_app gets USAGE on schema tripplanner + SELECT on the view (X1: the CIS runtime moves to cis_app at
-- S18). Until then the CIS runtime logs in as the RDS master aa_cis_admin, a member of tp_owner (rl-001), so it already
-- reads the view as its owner's member; nothing extra is granted to it. The view reads its base tables with its
-- owner's (tp_owner's) rights, so cis_app needs nothing on the tables.
--
-- v_ops_traffic_daily (day date, metric text, n bigint), long format, UTC days, last 400 days:
--   planner_session_started  tripplanner.sessions, by created_at (one per guest planner session)
--   trip_started             tripplanner.trip_drafts, by created_at
--   trip_edited              distinct trips with at least one edit event (trip_events other than 'sent') that day
--   inquiry_sent             tripplanner.outbox rows of event inquiry.submitted, by created_at ("send to advisor")
-- Metric names are part of the contract (AA-Ecosys docs/contracts/ops.overview.v1.md): add new names, never rename.
-- AI searches are not here: they are counted by CIS from shared.llm_call_log (stage tp_search_embed).
--
-- Applied through AA-CIS-Infra DB Migrate from the byte-identical copy db/migrations/tripplanner/015_ops_overview_view.sql,
-- as tp_owner (the live owner of schema tripplanner since tp-013, XD8). Never run it from a laptop. Re-runnable:
-- CREATE OR REPLACE VIEW keeps the column list; grants repeat. The guard raises (it never skips) when cis_app is
-- missing, so a missing grant is never hidden behind a registered key (tp-009's rule).
-- Undo: DROP VIEW tripplanner.v_ops_traffic_daily (a later tp- file, after the CIS reader is gone); keep USAGE while
-- booking reads v_inquiry_outbox.

BEGIN;

DO $$
BEGIN
    IF current_user <> 'tp_owner' THEN
        RAISE EXCEPTION 'tp-015: expected to run as tp_owner (live owner of schema tripplanner), running as %', current_user;
    END IF;
    IF to_regrole('cis_app') IS NULL THEN
        RAISE EXCEPTION 'tp-015: role cis_app is missing (AA-CIS-Infra roles/001, rl-001)';
    END IF;
END $$;

CREATE OR REPLACE VIEW tripplanner.v_ops_traffic_daily AS
SELECT (s.created_at AT TIME ZONE 'UTC')::date AS day,
       'planner_session_started'::text AS metric,
       count(*)::bigint AS n
  FROM tripplanner.sessions s
 WHERE s.created_at >= now() - interval '400 days'
 GROUP BY 1
UNION ALL
SELECT (d.created_at AT TIME ZONE 'UTC')::date, 'trip_started'::text, count(*)::bigint
  FROM tripplanner.trip_drafts d
 WHERE d.created_at >= now() - interval '400 days'
 GROUP BY 1
UNION ALL
SELECT (e.created_at AT TIME ZONE 'UTC')::date, 'trip_edited'::text, count(DISTINCT e.trip_id)::bigint
  FROM tripplanner.trip_events e
 WHERE e.event_type <> 'sent'
   AND e.created_at >= now() - interval '400 days'
 GROUP BY 1
UNION ALL
SELECT (o.created_at AT TIME ZONE 'UTC')::date, 'inquiry_sent'::text, count(*)::bigint
  FROM tripplanner.outbox o
 WHERE o.event = 'inquiry.submitted'
   AND o.created_at >= now() - interval '400 days'
 GROUP BY 1;

COMMENT ON VIEW tripplanner.v_ops_traffic_daily IS
    'tp-015 (AA-858): TripPlanner traffic per UTC day, aggregates only, last 400 days. Contract ops.overview.v1, read by AA-CIS-App /admin/overview (role cis_app).';

-- Runtime role tripplanner: read-only on the view (default privileges FOR ROLE tp_owner gave it DML).
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON tripplanner.v_ops_traffic_daily FROM tripplanner;

-- The CIS reader (contract grant; AA-CIS-Infra db/owners.yaml tripplanner.consumer_grants).
GRANT USAGE ON SCHEMA tripplanner TO cis_app;
GRANT SELECT ON tripplanner.v_ops_traffic_daily TO cis_app;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('tp-015', now(), 'AA-858: ops overview contract view tripplanner.v_ops_traffic_daily, SELECT to cis_app')
ON CONFLICT (version) DO NOTHING;

COMMIT;
