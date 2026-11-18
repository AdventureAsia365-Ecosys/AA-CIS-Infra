-- Migration tp-034: AA-1126 (S284, lane L16 redesign) — TripPlanner's AI notice events in its own outbox, and the
-- contract view CIS pulls them from.
--
-- Class: contract (root ADR 0017 / 0017a). The file has no directive line on purpose: it ALTERs a CHECK constraint of
-- an existing table (tripplanner.outbox), adds a CHECK to it, and REVOKEs the default runtime grants on a new view.
-- Merge order MIG-4: this migration-only PR first; the AA-TripPlanner-Web code PR (backend/shared/tenant_sessions.py
-- and spend_bell.py write these events) and the AA-CIS-App code PR (the relay that reads the view) follow once this
-- file is applied on Dev. On Dev, AA-CIS-Infra Migration Apply runs it in contract mode once every job table is idle
-- (byte-identical copy db/migrations/tripplanner/034_ai_notice_events.sql), as tp_owner, the live owner of schema
-- tripplanner since tp-013 (XD8). Never run it from a laptop.
--
-- Why. Two TripPlanner AI events must reach a CIS bell (AA-1126 slices L2 and L4, root audit
-- docs/audits/2026-11-17-S283-session/ai-caps-gap.md):
--   L2  an agency's monthly AI sessions (plan key tp.ai_sessions) are used up: the agency's Content studio bell says
--       so, with an Upgrade link;
--   L4  under the prod spend rules a spend, AI budget or AI sessions read failed and the AI went on without that
--       check: the CIS admin bell says so, once per check and UTC day.
-- The first design (CIS 447 as opened in S283) let the tripplanner role INSERT into shared.notifications. CIS 274
-- (the tenant notification policies) and CIS 351 (tripplanner holds INSERT on shared.llm_call_log and nothing else on
-- schema shared) forbid exactly that, and data standards DM-5.4 says cross-app lineage runs only through contracts
-- (a producer outbox and a contract view the consumer reads; a write into another app only through its HTTP API).
-- So TripPlanner records the event in its own outbox, the producer side of every TripPlanner contract, and CIS pulls
-- it through an owner view, the same shape as the views CIS already reads (tp-015 / tp-020 / tp-022 v_ops_*, tp-030
-- v_tenant_erasure_report_v1), and writes its own notification row as CIS.
--
-- What:
--   1. guards: the file runs as tp_owner; tp-028 forced row-level security on tripplanner.outbox; tp-026's outbox
--      CHECKs exist.
--   2. outbox_event_chk allows two more events beside inquiry.submitted and lead.submitted (dropped and added again,
--      re-runnable; every existing row passes):
--        ai.allowance_used  one row per tenant and UTC month (idempotency_key 'ai.allowance_used:<tenant>:<YYYY-MM>',
--                           aggregate_id = the tenant), payload {kind, month, resets_at};
--        ai.spend_degraded  one row per check and UTC day (idempotency_key 'ai.spend_degraded:<check>:<YYYY-MM-DD>',
--                           aggregate_id = the tenant bound when it happened), payload {check, stage, day}.
--      The writer uses INSERT ... ON CONFLICT (idempotency_key) DO NOTHING (the tenant policy of tp-028 applies: the
--      row is the bound tenant's). The tp-026 delivery CHECKs already keep these rows without a channel and
--      undelivered.
--   3. outbox_ai_notice_chk: an ai.* row carries an idempotency key of its own event's shape and a payload object with
--      no 'customer' key, so the view below can never expose a traveller's personal data.
--   4. tripplanner.v_ai_notices_v1 (id, tenant_id, event, notice_key, payload, created_at): the ai.* rows of the
--      outbox. An owner view (no security_invoker): it reads the outbox through tp-028's outbox_owner_read policy,
--      every row while the reader binds no TripPlanner tenant (cis_app binds none). SELECT to cis_app only; every
--      default privilege of the runtime role on it is revoked (the runtime role writes the outbox itself, under its
--      tenant policy).
--   5. comments, guards, registration.
--
-- Retention and erasure: unchanged rows of an existing table. The rows are kept like every outbox row (data
-- standards DM-7.1 row tripplanner.outbox; no personal data in them, the CHECK above), a tenant's rows are deleted at
-- offboarding (tp-030 erase_tenant deletes every outbox row of the tenant) and its backup copies them (tenant_backup).
--
-- Locks: ACCESS EXCLUSIVE on tripplanner.outbox for the constraint swap (a handful of rows; lock_timeout 5s), none
-- elsewhere. Re-runnable (test_replay_twice_pg.py): DROP CONSTRAINT IF EXISTS + ADD, CREATE OR REPLACE VIEW (same
-- columns), repeated grants / revokes / comments, ON CONFLICT DO NOTHING.
-- Undo: a later tp- file: DROP VIEW tripplanner.v_ai_notices_v1 and DROP CONSTRAINT outbox_ai_notice_chk, then
-- outbox_event_chk back to the two lead events once no ai.* row is left (contract), after the CIS relay and the
-- TripPlanner writers are reverted.

BEGIN;
SET LOCAL lock_timeout = '5s';

-- 1. guards before any change

DO $$
BEGIN
    IF current_user <> 'tp_owner' THEN
        RAISE EXCEPTION 'tp-034: expected to run as tp_owner (live owner of schema tripplanner), running as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = to_regclass('tripplanner.outbox')
                                             AND c.relrowsecurity AND c.relforcerowsecurity) THEN
        RAISE EXCEPTION 'tp-034: tp-028 (FORCE row-level security on tripplanner.outbox) is not applied';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'tripplanner' AND tablename = 'outbox'
                                               AND policyname = 'outbox_owner_read') THEN
        RAISE EXCEPTION 'tp-034: the tp-028 policy outbox_owner_read is missing (the view reads through it)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'tripplanner.outbox'::regclass
                                                 AND conname = 'outbox_lead_channel_chk') THEN
        RAISE EXCEPTION 'tp-034: tp-026 (outbox_lead_channel_chk) is not applied';
    END IF;
END $$;

-- 2. the two AI notice events

ALTER TABLE tripplanner.outbox DROP CONSTRAINT IF EXISTS outbox_event_chk;
ALTER TABLE tripplanner.outbox
    ADD CONSTRAINT outbox_event_chk
    CHECK (event IN ('inquiry.submitted', 'lead.submitted', 'ai.allowance_used', 'ai.spend_degraded'));

-- 3. their key shape and a payload without personal data

ALTER TABLE tripplanner.outbox DROP CONSTRAINT IF EXISTS outbox_ai_notice_chk;
ALTER TABLE tripplanner.outbox
    ADD CONSTRAINT outbox_ai_notice_chk
    CHECK (event NOT IN ('ai.allowance_used', 'ai.spend_degraded')
           OR (idempotency_key ~ ('^' || replace(event, '.', '\.') || ':[a-z0-9_:-]{1,120}$')
               AND jsonb_typeof(payload) = 'object'
               AND NOT payload ? 'customer'));

-- 4. the contract view CIS pulls

CREATE OR REPLACE VIEW tripplanner.v_ai_notices_v1 AS
SELECT o.id, o.tenant_id, o.event, o.idempotency_key AS notice_key, o.payload, o.created_at
  FROM tripplanner.outbox o
 WHERE o.event IN ('ai.allowance_used', 'ai.spend_degraded');

REVOKE ALL ON tripplanner.v_ai_notices_v1 FROM tripplanner;
GRANT SELECT ON tripplanner.v_ai_notices_v1 TO cis_app;

-- 5. comments

COMMENT ON CONSTRAINT outbox_ai_notice_chk ON tripplanner.outbox IS
    'tp-034 (AA-1126): an ai.* row has an idempotency key ''<event>:<key>'' and a payload object without a customer key (no personal data; it is read by CIS through v_ai_notices_v1).';
COMMENT ON VIEW tripplanner.v_ai_notices_v1 IS
    'tp-034 (AA-1126): TripPlanner''s AI notice events for CIS (ai.allowance_used: an agency''s monthly AI sessions are used up; ai.spend_degraded: a spend check degraded under the prod spend rules). CIS pulls them and writes its own shared.notifications rows. Owner view over tripplanner.outbox (policy outbox_owner_read); no personal data. SELECT to cis_app only (not the runtime role).';

-- 6. guards

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'tripplanner.outbox'::regclass
                                                 AND conname = 'outbox_event_chk' AND convalidated
                                                 AND pg_get_constraintdef(oid) LIKE '%ai.spend_degraded%')
       OR NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'tripplanner.outbox'::regclass
                                                    AND conname = 'outbox_ai_notice_chk' AND convalidated) THEN
        RAISE EXCEPTION 'tp-034: outbox_event_chk / outbox_ai_notice_chk missing or not validated';
    END IF;
    IF has_table_privilege('tripplanner', 'tripplanner.v_ai_notices_v1', 'SELECT')
       OR has_table_privilege('tripplanner', 'tripplanner.v_ai_notices_v1', 'INSERT')
       OR has_table_privilege('tripplanner', 'tripplanner.v_ai_notices_v1', 'UPDATE')
       OR has_table_privilege('tripplanner', 'tripplanner.v_ai_notices_v1', 'DELETE')
       OR NOT has_table_privilege('cis_app', 'tripplanner.v_ai_notices_v1', 'SELECT')
       OR has_table_privilege('cis_app', 'tripplanner.v_ai_notices_v1', 'INSERT')
       OR has_table_privilege('cis_app', 'tripplanner.outbox', 'SELECT') THEN
        RAISE EXCEPTION 'tp-034: unexpected grants on tripplanner.v_ai_notices_v1 or tripplanner.outbox';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('tp-034', now(), 'AA-1126: the AI notice events in tripplanner.outbox (ai.allowance_used, ai.spend_degraded) '
                         'and tripplanner.v_ai_notices_v1, the contract view CIS pulls them from')
ON CONFLICT (version) DO NOTHING;

COMMIT;
