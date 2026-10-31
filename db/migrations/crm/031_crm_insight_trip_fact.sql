-- migrate: expand
-- Migration crm-031: AA-966 CRM-34 (spec module 17, design v3 S-03, card R "a cell with n < 10 or < 3 agencies is
-- suppressed") — the trip-level insight fact, so a trip's travellers are counted ONCE for every dimension but the
-- destination.
--
-- Owner: AA-Partner (api/migrations/031_crm_insight_trip_fact.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- DB Migrate applies (Migration Copy Guard). Key crm-031.
--
-- Why: crm.v_insight_fact (crm-006) is one row per trip AND destination (up to 12 per trip, trip_destinations_chk). For
-- the destination dimension that is right; for budget band, age band, party size, stage and Lost reason a trip with
-- four destinations would add its party four times, so a cell could cross the k >= 10 threshold on duplicates alone
-- (and its published counts would be wrong). The view below has no destination: one row per agency, month and band
-- combination, with the number of trips in it.
--
-- What: one new view crm.v_insight_trip_fact (security_barrier): tenant_id, month (the start date's month, else the
-- travel month: the crm-006 rule), budget_band, age_band (the lead traveller's band at departure), party_size, the
-- current stage, lost_reason_code, trip_count. Bands and codes only: no trip id, no token, no title, no free text. The
-- GROUP BY also makes it a view nothing can be written through. SELECT to crm_insights (the reader app.ops.console
-- switches to). crm_app gets the schema's default table privileges (crm-001); the view is not updatable, so its DML
-- grants do nothing (an expand file cannot REVOKE: a later contract key may tidy them with the crm-006 REVOKE line).
-- FORCE RLS on crm.trip / crm.trip_party still keeps a read inside the agency of app.tenant_id.
--
-- Class: expand (root ADR 0017 d3): a new view, its comment, a GRANT on it to a nologin role of this owner
-- (owners.yaml), the registration. No existing object changes; crm.v_insight_fact stays as it is (the destination
-- read). The code that reads the view ships in the same PR and raises the readiness requirement to crm-031 (app/db.py).
--
-- Order: after crm-030 (DB Migrate applies expand files in number order and never skips a gap). Runs as crm_owner (DB
-- Migrate switch), one BEGIN … COMMIT block, no role DDL, no DO block. Not re-runnable by itself (a plain CREATE VIEW:
-- the expand lint names only CREATE VIEW as a new object); DB Migrate never applies a registered key again.
-- Rollback: a forward crm- file dropping the view after the code that reads it is reverted (MIG-14); the code before
-- this key never reads it.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

CREATE VIEW crm.v_insight_trip_fact WITH (security_barrier = true) AS
SELECT f.tenant_id, f.month, f.budget_band, f.age_band, f.party_size, f.stage_reached, f.lost_reason_code,
       count(*)::int AS trip_count
  FROM (SELECT t.tenant_id,
               coalesce(date_trunc('month', t.start_date)::date, t.month) AS month,
               t.budget_band,
               (SELECT tp.age_band_at_departure FROM crm.trip_party tp
                 WHERE tp.trip_id = t.trip_id AND tp.role = 'lead' AND tp.deleted_at IS NULL LIMIT 1) AS age_band,
               t.party_adults + cardinality(t.party_child_ages) AS party_size,
               t.stage AS stage_reached,
               t.lost_reason_code
          FROM crm.trip t
         WHERE t.deleted_at IS NULL) f
 GROUP BY f.tenant_id, f.month, f.budget_band, f.age_band, f.party_size, f.stage_reached, f.lost_reason_code;

COMMENT ON VIEW crm.v_insight_trip_fact IS 'AA-966 (crm-031): the trip-level insight fact for crm_insights (spec module 17): trips per agency, month and band combination, no destination (crm.v_insight_fact is the per-destination read), so a trip''s travellers count once in every other dimension; bands and codes only, no trip id, no token; not updatable (GROUP BY).';

GRANT SELECT ON crm.v_insight_trip_fact TO crm_insights;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-031', now(), 'AA-966 CRM-34: crm.v_insight_trip_fact, the trip-level insight fact (trips per agency, month and band combination; no destination) for crm_insights, so AA insights count a trip once outside the destination dimension')
ON CONFLICT (version) DO NOTHING;

COMMIT;
