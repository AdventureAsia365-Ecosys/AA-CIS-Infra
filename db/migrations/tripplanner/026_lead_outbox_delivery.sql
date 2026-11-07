-- Migration tp-026: AA-1038 (R5 slice 3, root ADR 0019 d11) — the outbox carries lead.submitted.v1 rows and their
-- delivery state: a traveller's trip request to ONE agency tenant, kept only until it is delivered.
--
-- Class: contract (root ADR 0017 / 0017a). The file has no directive line on purpose: it changes a CHECK and adds
-- constraints and columns on an existing table, which the expand classifier refuses. Merge order MIG-4: this
-- migration-only PR first; the TripPlanner code PR that writes lead rows follows once this file is applied on Dev. On
-- Dev, AA-CIS-Infra Migration Apply runs it in contract mode once every job table is idle (byte-identical copy
-- db/migrations/tripplanner/026_lead_outbox_delivery.sql), as tp_owner, the live owner of schema tripplanner since
-- tp-013 (XD8). Never run it from a laptop.
--
-- Why. ADR 0019 d11: on an agency tenant's planner (/{slug}/plan), "Send to advisor" becomes a lead.submitted.v1
-- (contract docs/contracts/lead.submitted.v1.openapi.yaml in the root repo) for that tenant, delivered by the route CIS
-- names for it (catalog.v_tenant_tripplanner_v1 lead_channel, CIS 390): the tenant's CRM pulls it over HTTP (the CRM
-- holds no grant on this schema, ADR 0008a), or TripPlanner posts it to the tenant's signed webhook or e-mails it.
-- TripPlanner keeps the lead only until it is delivered (data standards DM-7.1 row tripplanner.outbox): the outbox is
-- already the transactional store of a hand-off with the trip's `sent` event (AA-676) and already has a tenant
-- (tp-025) and a payload redaction marker (tp-021), so a lead is one more event of it, not a new table.
--
-- What (tripplanner.outbox):
--   1. outbox_event_chk allows 'lead.submitted' beside 'inquiry.submitted' (dropped and added again, re-runnable).
--   2. delivery columns, nullable or with a constant default (metadata-only, no rewrite):
--        delivery_channel  text      'crm' | 'webhook' | 'email' for a lead row, NULL for every other event
--                                    (outbox_lead_channel_chk: a lead row has a channel, another row has none);
--        delivered_at      timestamptz  when the CRM acknowledged it, the webhook answered 2xx or the e-mail went;
--        delivery_attempts integer NOT NULL DEFAULT 0  webhook / e-mail tries (the CRM pull is not counted);
--        delivery_error    text      the last failure as a code (^[a-z][a-z0-9_:]{0,63}$), never a message or value.
--   3. outbox_lead_pending_idx (tenant_id, id) WHERE event = 'lead.submitted' AND delivered_at IS NULL AND
--      redacted_at IS NULL: the CRM pull of one tenant (oldest first) and the daily delivery run read only it;
--      outbox_lead_tenant_created_idx (tenant_id, created_at) WHERE event = 'lead.submitted': the per-tenant daily
--      lead cap counts a tenant's leads of the last 24 hours on every send (S272 review).
--   4. column comments; the table comment restated: the owner's redaction and the lead delivery (the TripPlanner
--      Lambdas, role tripplanner) are the only UPDATEs; v_inquiry_outbox (booking) keeps its fixed column list and its
--      event filter, so no lead ever reaches AA-Booking.
--   5. guards, among them: v_inquiry_outbox keeps its column list AND its one filter event = 'inquiry.submitted'
--      (the only thing that keeps a lead's personal data away from role booking, S272 review);
--   6. Register tp-026.
-- The runtime role tripplanner needs UPDATE on the outbox for the delivery columns and the redaction: it holds
-- SELECT, INSERT, UPDATE, DELETE through the tp_owner default privileges (tp-013, restated by tp-021); asserted below.
-- RLS: the tp-025 shadow policy outbox_tenant_shadow already covers every new column (FOR ALL, TO tripplanner).
--
-- Locks: ACCESS EXCLUSIVE on tripplanner.outbox for the length of the file (about ten rows on Dev): the CHECK swap
-- validates the rows, the new CHECK on delivery_channel too, the index build holds SHARE. A send-to-advisor request
-- waits well under a second; past the runner's lock_timeout the file rolls back whole and can be re-run.
-- Re-runnable (test_replay_twice_pg.py): IF NOT EXISTS on the columns and the index, constraints dropped and added
-- again, the same comments, ON CONFLICT DO NOTHING.
-- Undo: a later tp- file (contract): DROP INDEX outbox_lead_pending_idx and outbox_lead_tenant_created_idx, the two
-- lead CHECKs back to event IN ('inquiry.submitted'); then DROP COLUMN delivery_* with `-- migrate: destructive` (DRY
-- RUN first) once no code reads them and no lead row is left.

BEGIN;

DO $$
BEGIN
    IF current_user <> 'tp_owner' THEN
        RAISE EXCEPTION 'tp-026: expected to run as tp_owner (live owner of schema tripplanner), running as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'tripplanner.outbox'::regclass AND attname = 'tenant_id'
                                              AND NOT attisdropped)
       OR NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'tripplanner.outbox'::regclass
                                                  AND attname = 'redacted_at' AND NOT attisdropped) THEN
        RAISE EXCEPTION 'tp-026: apply tp-021 (redacted_at) and tp-025 (tenant_id) first';
    END IF;
END $$;

LOCK TABLE tripplanner.outbox IN ACCESS EXCLUSIVE MODE;

-- 1. the event CHECK

ALTER TABLE tripplanner.outbox DROP CONSTRAINT IF EXISTS outbox_event_chk;
ALTER TABLE tripplanner.outbox
    ADD CONSTRAINT outbox_event_chk CHECK (event IN ('inquiry.submitted', 'lead.submitted'));

-- 2. the delivery columns

ALTER TABLE tripplanner.outbox
    ADD COLUMN IF NOT EXISTS delivery_channel  text,
    ADD COLUMN IF NOT EXISTS delivered_at      timestamptz,
    ADD COLUMN IF NOT EXISTS delivery_attempts integer NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS delivery_error    text;

ALTER TABLE tripplanner.outbox DROP CONSTRAINT IF EXISTS outbox_lead_channel_chk;
ALTER TABLE tripplanner.outbox
    ADD CONSTRAINT outbox_lead_channel_chk CHECK (
        (event = 'lead.submitted') = (delivery_channel IS NOT NULL)
        AND (delivery_channel IS NULL OR delivery_channel IN ('crm', 'webhook', 'email')));
ALTER TABLE tripplanner.outbox DROP CONSTRAINT IF EXISTS outbox_delivery_state_chk;
ALTER TABLE tripplanner.outbox
    ADD CONSTRAINT outbox_delivery_state_chk CHECK (
        delivery_attempts BETWEEN 0 AND 1000
        AND (delivery_error IS NULL OR delivery_error ~ '^[a-z][a-z0-9_:]{0,63}$')
        AND (delivered_at IS NULL OR event = 'lead.submitted'));

-- 3. the pending-lead index

CREATE INDEX IF NOT EXISTS outbox_lead_pending_idx ON tripplanner.outbox (tenant_id, id)
    WHERE event = 'lead.submitted' AND delivered_at IS NULL AND redacted_at IS NULL;
CREATE INDEX IF NOT EXISTS outbox_lead_tenant_created_idx ON tripplanner.outbox (tenant_id, created_at)
    WHERE event = 'lead.submitted';

-- 4. comments

COMMENT ON TABLE tripplanner.outbox IS
    'AA-676 / AA-1038: transactional outbox. inquiry.submitted rows are read by AA-Booking through v_inquiry_outbox '
    '(append-only for it); lead.submitted rows (tp-026, lead.submitted.v1) are delivered to the owning tenant (its CRM '
    'pulls over HTTP, or a signed webhook / an e-mail) and redacted on delivery or after the hold window. The only '
    'UPDATEs are the owner''s redaction (tp_retention_outbox_redact, tp_lead_deliver) and the lead delivery columns.';
COMMENT ON COLUMN tripplanner.outbox.delivery_channel IS
    'tp-026 (AA-1038 R5 slice 3): crm | webhook | email for a lead.submitted row (CIS 390 lead_channel at submit time), '
    'NULL for any other event.';
COMMENT ON COLUMN tripplanner.outbox.delivered_at IS
    'tp-026: when the lead reached the tenant (CRM ack, webhook 2xx, e-mail sent); the payload is redacted then.';
COMMENT ON COLUMN tripplanner.outbox.delivery_attempts IS
    'tp-026: webhook / e-mail delivery tries of a lead row (the CRM pull is not counted).';
COMMENT ON COLUMN tripplanner.outbox.delivery_error IS
    'tp-026: the last delivery failure of a lead row as a code (e.g. webhook_http_500, expired, rejected:<reason>), '
    'never a message or a value.';

-- 5. guards

DO $$
DECLARE
    bad text;
BEGIN
    SELECT string_agg(c, ', ' ORDER BY c) INTO bad
      FROM unnest(ARRAY['outbox_event_chk', 'outbox_lead_channel_chk', 'outbox_delivery_state_chk']) AS c
     WHERE NOT EXISTS (SELECT 1 FROM pg_constraint
                        WHERE conrelid = 'tripplanner.outbox'::regclass AND conname = c AND contype = 'c'
                          AND convalidated);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'tp-026: missing or not validated: %', bad;
    END IF;
    IF NOT pg_catalog.has_table_privilege('tripplanner', 'tripplanner.outbox', 'SELECT, INSERT, UPDATE') THEN
        RAISE EXCEPTION 'tp-026: role tripplanner lacks SELECT, INSERT or UPDATE on tripplanner.outbox';
    END IF;
    IF pg_catalog.has_table_privilege('booking', 'tripplanner.outbox', 'SELECT') THEN
        RAISE EXCEPTION 'tp-026: role booking can read tripplanner.outbox (the view only)';
    END IF;
    IF (SELECT string_agg(a.attname, ',' ORDER BY a.attnum) FROM pg_attribute a
         WHERE a.attrelid = 'tripplanner.v_inquiry_outbox'::regclass AND a.attnum > 0 AND NOT a.attisdropped)
       IS DISTINCT FROM 'id,schema_version,idempotency_key,trip_id,payload,created_at' THEN
        RAISE EXCEPTION 'tp-026: tripplanner.v_inquiry_outbox changed its columns';
    END IF;
    -- The filter, not only the columns: a CREATE OR REPLACE with the same columns and no (or a widened) filter would
    -- hand every lead's personal data to role booking. The whitespace-normalised definition must END with the one
    -- predicate event = 'inquiry.submitted' (no OR, no other condition).
    IF regexp_replace(pg_catalog.pg_get_viewdef('tripplanner.v_inquiry_outbox'::regclass), '\s+', ' ', 'g')
       !~ $re$ WHERE \(?(outbox\.)?event = 'inquiry\.submitted'(::text)?\)?;? ?\Z$re$ THEN
        RAISE EXCEPTION 'tp-026: tripplanner.v_inquiry_outbox no longer filters event = inquiry.submitted only';
    END IF;
    IF EXISTS (SELECT 1 FROM tripplanner.outbox WHERE event <> 'lead.submitted' AND delivery_channel IS NOT NULL) THEN
        RAISE EXCEPTION 'tp-026: a non-lead outbox row has a delivery channel';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('tp-026', now(), 'AA-1038 R5 slice 3: tripplanner.outbox lead.submitted rows (delivery_channel, delivered_at, '
                         'delivery_attempts, delivery_error, outbox_lead_pending_idx, outbox_lead_tenant_created_idx)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
