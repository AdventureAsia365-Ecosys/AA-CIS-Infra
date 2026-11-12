-- migrate: expand
-- Migration crm-060: AA-1070 item crm-13 (S275 study of a tour and travel app, root docs/research/2026-11-10-odoo-tour-
-- travel-plugin-comparison.md row 16; behaviour only, no plugin code) — the guided flow when Adventure Asia cancels a
-- departure: one case per agency trip hit by it.
--
-- Owner: AA-Partner (api/migrations/060_crm_aa_cancel_case.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- DB Migrate applies (Migration Copy Guard). Key crm-060: crm-059 (AA-1070 item crm-35, another lane of the same
-- wave) comes first; if main moves, renumber: file name, this header, the registration below, app/db.py
-- REQUIRED_SCHEMA_VERSIONS and the tests that name it (git grep '060_' and 'crm-060').
--
-- What (DM-7.1: root data standards Part B §7 row added with this key):
--   1. crm.aa_cancel_case (base template): one agency trip with a live Adventure Asia line (or a live proposal option)
--      on a departure the Booking feed says AA cancelled (booking.b2b.v1 departure.cancelled). Opened by the feed job
--      (job:crm_booking_sync) once per (trip, departure): a replayed or repeated event opens nothing new (the unique
--      key). resolution NULL (open) -> requoted (the agent re-quoted the same AA tour on another departure:
--      proposal_id names the new builder version, rebook_trip_id the new trip when the old one was already booked) |
--      cancelled (the trip was cancelled, the traveller charge forced to 0). No status column (and so no
--      crm.status_transition rows, which would make this file contract): the API only moves it forward (NULL ->
--      requoted | cancelled, requoted -> cancelled when the re-quoted trip is cancelled after all). The pipeline filter "AA cancelled", the trip card badge
--      and the trip page's guided card read it. Ids, codes and times only: no personal data, no money.
--      proposal_id / rebook_trip_id are snapshot references without a foreign key (the new version or trip follows
--      its own lifecycle; erasing it never changes the case).
--   2. Erasure without a replaced crm.erase_subject: the only foreign key cascades from crm.trip, a row the erase
--      already deletes (tests/integration/test_crm010_schema.py CASCADE_ERASED lists it). Hold rule 4h: crm-054's
--      crm.guard_held_travel_doc() (a direct delete, trash or move of a held trip's row is refused, CRM10).
--   3. RLS (ENABLE + FORCE, tenant_isolation TO the CRM roles); crm_app keeps the default DML of crm-001; no reader
--      grant (AI context, insights and support never read it).
--
-- Class: expand (root ADR 0017 d3): one new table with its constraints, indexes, triggers, policy and comments; the
-- foreign key is from the new table only; no change to an existing object, no DO block, no CREATE OR REPLACE. Not
-- re-runnable by itself (plain CREATE POLICY / TRIGGER); DB Migrate never applies a registered key again and the test
-- conftest skips it. Ships as a migration-only PR (batch crm 059-060 with the inclusions lane), applied before the code
-- PR.
--
-- Rollback (a forward crm- file, after the code that reads it is reverted): DROP TABLE crm.aa_cancel_case.
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

CREATE TABLE IF NOT EXISTS crm.aa_cancel_case (
    aa_cancel_case_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id         UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                      REFERENCES crm.tenant (tenant_id),
    trip_id           UUID NOT NULL,
    departure_id      TEXT NOT NULL,
    resolution        TEXT,
    opened_event_id   TEXT NOT NULL,
    opened_at         TIMESTAMPTZ NOT NULL,
    resolved_at       TIMESTAMPTZ,
    resolved_by       TEXT,
    proposal_id       UUID,
    rebook_trip_id    UUID,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by        TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at        TIMESTAMPTZ,
    deleted_by        TEXT,
    purge_after       TIMESTAMPTZ,
    CONSTRAINT aa_cancel_case_tenant_id_uq UNIQUE (tenant_id, aa_cancel_case_id),
    CONSTRAINT aa_cancel_case_trip_departure_uq UNIQUE (tenant_id, trip_id, departure_id),
    CONSTRAINT aa_cancel_case_trip_fk FOREIGN KEY (tenant_id, trip_id)
        REFERENCES crm.trip (tenant_id, trip_id) ON DELETE CASCADE,
    CONSTRAINT aa_cancel_case_resolution_chk CHECK (resolution IS NULL OR resolution IN ('requoted', 'cancelled')),
    CONSTRAINT aa_cancel_case_values_chk CHECK (
        departure_id ~ '^[A-Za-z0-9:_.-]{1,80}$'
        AND opened_event_id ~ '^[A-Za-z0-9:_.-]{1,64}$'
        AND (resolved_by IS NULL OR (char_length(resolved_by) BETWEEN 1 AND 128 AND resolved_by !~ '[[:cntrl:]]'))
    ),
    CONSTRAINT aa_cancel_case_resolved_chk CHECK (
        ((resolution IS NULL) = (resolved_at IS NULL))
        AND ((resolved_at IS NULL) = (resolved_by IS NULL))
        AND (resolution IS DISTINCT FROM 'requoted' OR proposal_id IS NOT NULL)
        AND (rebook_trip_id IS NULL OR proposal_id IS NOT NULL)
        AND (rebook_trip_id IS DISTINCT FROM trip_id)
    ),
    CONSTRAINT aa_cancel_case_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE INDEX IF NOT EXISTS aa_cancel_case_active_idx ON crm.aa_cancel_case (tenant_id, trip_id)
    WHERE (resolution IS NULL OR resolution = 'requoted') AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS aa_cancel_case_rebook_idx ON crm.aa_cancel_case (tenant_id, rebook_trip_id)
    WHERE rebook_trip_id IS NOT NULL;
ALTER TABLE crm.aa_cancel_case ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.aa_cancel_case FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON crm.aa_cancel_case
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
CREATE TRIGGER aa_cancel_case_set_updated_at
    BEFORE UPDATE ON crm.aa_cancel_case
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
CREATE TRIGGER aa_cancel_case_hold_guard
    BEFORE DELETE OR UPDATE ON crm.aa_cancel_case
    FOR EACH ROW EXECUTE FUNCTION crm.guard_held_travel_doc();
COMMENT ON TABLE crm.aa_cancel_case IS 'AA-1070 (crm-060, item crm-13): one agency trip with a live AA line or proposal option on a departure Adventure Asia cancelled (Booking feed departure.cancelled). Opened once per trip and departure by job:crm_booking_sync (a replayed event opens nothing); resolution NULL (open) -> requoted (a new builder version on another departure: proposal_id; a booked trip gets a new trip: rebook_trip_id) | cancelled (the trip cancelled with the traveller charge forced to 0). The pipeline "AA cancelled" filter, the card badge and the trip page''s guided card read it. Ids, codes and times only. Cascades from the trip. No reader grant.';
COMMENT ON COLUMN crm.aa_cancel_case.departure_id IS 'the AA departure (booking.b2b.v1 Departure.departure_id) the feed said AA cancelled';
COMMENT ON COLUMN crm.aa_cancel_case.resolution IS 'NULL = open (the agent has not acted) | requoted (re-quoted on another departure) | cancelled (the trip was cancelled); only moved forward by the API';
COMMENT ON COLUMN crm.aa_cancel_case.opened_event_id IS 'the Booking feed event id that opened the case (booking.b2b.v1 Event.event_id)';
COMMENT ON COLUMN crm.aa_cancel_case.proposal_id IS 'the builder version the re-quote made (snapshot reference, no foreign key)';
COMMENT ON COLUMN crm.aa_cancel_case.rebook_trip_id IS 'the new trip a re-quote of a booked trip made (snapshot reference, no foreign key)';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-060', now(), 'AA-1070 item crm-13: crm.aa_cancel_case (one trip hit by a departure AA cancelled: resolution NULL -> requoted | cancelled); hold guard crm.guard_held_travel_doc (CRM10); cascades from crm.trip, no erase_subject change')
ON CONFLICT (version) DO NOTHING;

COMMIT;
