-- migrate: expand
-- Migration crm-054: AA-1070 (S275 study of a tour and travel app, root docs/research/2026-11-10-odoo-tour-travel-
-- plugin-comparison.md, items crm-22, crm-20, crm-17 and crm-16; behaviour only, no plugin code) — the tables of the
-- departure roster, the traveller vouchers, the rooming list and the visa tracker.
--
-- Owner: AA-Partner (api/migrations/054_crm_travel_ops.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy DB
-- Migrate applies (Migration Copy Guard). Key crm-054: crm-053 is the highest on main; if main moves, renumber: file
-- name, this header, the registration below, crm-055's Guard 0, app/db.py REQUIRED_SCHEMA_VERSIONS and the tests that
-- name it (git grep '054_' and 'crm-054').
--
-- What (DM-7.1: root data standards Part B §7 rows added with this key):
--   1. crm.aa_departure_state (base template): what the Booking feed said about one AA departure the agency has
--      lines on: departure_status scheduled | guaranteed | cancelled, guaranteed_at / cancelled_at, min_to_operate
--      (NULL until Booking sends it; contract booking.b2b.v1 1.x has no field for it yet), the last event id and time.
--      One row per (agency, departure). Written by the feed job only (guard crm.guard_aa_departure_state, SQLSTATE
--      CRM53); members read it (the departure roster, the Home "today" tiles). Ids, codes and times only, no personal
--      data. Cascades from the agency's crm.booking_feed_state row (the feed that writes it; the agency erase deletes
--      that row).
--   2. crm.booking_line_voucher (base template): the voucher details of one booking line the agency adds for its
--      travellers (pickup place, drop-off place, service time, the supplier's PNR / booking reference, a note). The
--      text values are personal enough to seal (a pickup can be a home address, a PNR opens a booking): each one is
--      under the tenant vault DEK (AAD = booking_line_voucher id). One live row per line; an Adventure Asia line may
--      carry the agency's own note too (its confirmation comes from Booking). Cascades from its line and its trip.
--   3. crm.room_assignment (base template): who shares which room on a trip (the rooming list): room_no 1..50,
--      room_type single | double | twin | triple | quad | family, bed_pref double_bed | twin_beds | extra_bed | cot
--      (optional). One live row per (trip, traveller). The API checks the rooms against the accepted proposal's
--      room_config and the room type's capacity. Cascades from the trip, the traveller and their trip_traveler row.
--   4. crm.visa_template (base template): the agency's own visa guidance per country and visa type (BYO
--      responsibility: AA gives no visa advice, root ADR 0019 b6 and the AI boundary of AA-820): processing days,
--      fee + currency (both or neither), the document list (a JSON array of 1..200 character strings, at most 30),
--      the official https URL, active. One live template per (country, visa type). Cascades from the agency's
--      crm.tenant_settings row. Commercial guidance, no personal data.
--   5. crm.visa_application (base template): one traveller's visa for one country on one trip: visa type, status
--      to_do -> collecting -> submitted -> approved | refused (refused -> collecting: apply again), not_needed,
--      cancelled (the crm.status_transition rows come with crm-055, a contract file), the deadline, submitted_on,
--      decided_on, and the granted visa's number and validity under the tenant vault DEK (pii:government_id). The
--      template it was made from is a snapshot reference without a foreign key (editing or deleting a template never
--      changes an application). One live application per (trip, traveller, country). Cascades from the trip, the
--      traveller and their trip_traveler row.
--   6. crm.visa_checklist_item (base template): the documents one application needs (copied from the template, or
--      added by the agent), done by the agent or the traveller in the portal. Cascades from its application.
--   7. Erasure without a replaced crm.erase_subject: every foreign key of the new tables cascades from a row the erase
--      already deletes (tests/integration/test_crm010_schema.py CASCADE_ERASED lists each table with its parents).
--      Hold rule 4h: crm.guard_held_travel_doc() on the trip-scoped tables (a direct delete, trash or move of a row of
--      a held trip or traveller is refused, CRM10; a cascade passes, as crm-029's flight guard).
--   8. RLS (ENABLE + FORCE, tenant_isolation TO the CRM roles) on every table; crm_app keeps the default DML of
--      crm-001; no reader grant (AI context, insights and support never read them).
--
-- Class: expand (root ADR 0017 d3): six new tables and two new trigger functions with their constraints, indexes,
-- triggers, policies and comments; foreign keys from the new tables only; no change to an existing object, no DO
-- block, no CREATE OR REPLACE. Not re-runnable by itself (plain CREATE POLICY / TRIGGER / FUNCTION); DB Migrate never
-- applies a registered key again and the test conftest skips it. Ships in the migration-only PR with crm-055 (batch
-- crm 054-055), applied before the code PR.
--
-- Rollback (a forward crm- file, after the code that reads them is reverted): DROP TABLE crm.visa_checklist_item,
-- crm.visa_application, crm.visa_template, crm.room_assignment, crm.booking_line_voucher, crm.aa_departure_state;
-- DROP FUNCTION crm.guard_aa_departure_state(), crm.guard_held_travel_doc().
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

-- ── 1. crm.aa_departure_state ────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.aa_departure_state (
    aa_departure_state_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id             UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                          REFERENCES crm.tenant (tenant_id),
    departure_id          TEXT NOT NULL,
    departure_status      TEXT NOT NULL DEFAULT 'scheduled',
    min_to_operate        SMALLINT,
    guaranteed_at         TIMESTAMPTZ,
    cancelled_at          TIMESTAMPTZ,
    last_event_id         TEXT NOT NULL,
    last_event_at         TIMESTAMPTZ NOT NULL,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by            TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at            TIMESTAMPTZ,
    deleted_by            TEXT,
    purge_after           TIMESTAMPTZ,
    CONSTRAINT aa_departure_state_tenant_id_uq UNIQUE (tenant_id, aa_departure_state_id),
    CONSTRAINT aa_departure_state_departure_uq UNIQUE (tenant_id, departure_id),
    CONSTRAINT aa_departure_state_feed_fk FOREIGN KEY (tenant_id)
        REFERENCES crm.booking_feed_state (tenant_id) ON DELETE CASCADE,
    CONSTRAINT aa_departure_state_status_chk CHECK (departure_status IN ('scheduled', 'guaranteed', 'cancelled')),
    CONSTRAINT aa_departure_state_values_chk CHECK (
        departure_id ~ '^[A-Za-z0-9:_.-]{1,80}$'
        AND last_event_id ~ '^[A-Za-z0-9:_.-]{1,64}$'
        AND (min_to_operate IS NULL OR min_to_operate BETWEEN 1 AND 500)
        AND (departure_status <> 'guaranteed' OR guaranteed_at IS NOT NULL)
        AND (departure_status <> 'cancelled' OR cancelled_at IS NOT NULL)
    ),
    CONSTRAINT aa_departure_state_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
ALTER TABLE crm.aa_departure_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.aa_departure_state FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON crm.aa_departure_state
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
CREATE TRIGGER aa_departure_state_set_updated_at
    BEFORE UPDATE ON crm.aa_departure_state
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
-- CRM53 (crm-052 used CRM52): the departure state is the Booking feed's. A crm_app session writes it only as a job,
-- platform or seed actor; a member (or a client link) never does. A cascade (trigger depth > 1) passes.
CREATE FUNCTION crm.guard_aa_departure_state() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF pg_catalog.pg_trigger_depth() > 1 OR current_user::text <> 'crm_app'
       OR COALESCE(current_setting('app.actor', true), '') ~ '^(job|platform|seed):' THEN
        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    END IF;
    RAISE EXCEPTION 'crm: departure_state_feed_only (the AA departure state comes from the Booking feed)'
        USING ERRCODE = 'CRM53';
END;
$$;
COMMENT ON FUNCTION crm.guard_aa_departure_state() IS 'AA-1070 (crm-054): CRM53 departure_state_feed_only when a crm_app session that is not a job:, platform: or seed: actor inserts, updates or deletes crm.aa_departure_state (the Booking feed writes it). A cascade (trigger depth > 1) and crm_owner pass. Invoker rights.';
CREATE TRIGGER aa_departure_state_guard
    BEFORE INSERT OR UPDATE OR DELETE ON crm.aa_departure_state
    FOR EACH ROW EXECUTE FUNCTION crm.guard_aa_departure_state();
COMMENT ON TABLE crm.aa_departure_state IS 'AA-1070 (crm-054, item crm-22): what the Booking feed (booking.b2b.v1 departure.guaranteed / departure.cancelled) said about one AA departure the agency has lines on: departure_status, guaranteed_at, cancelled_at, min_to_operate (NULL until the contract carries it), the last event id and time. One row per agency and departure, written by job:crm_booking_sync only (guard CRM53). Ids, codes and times, no personal data. Cascades from the agency''s crm.booking_feed_state row.';
COMMENT ON COLUMN crm.aa_departure_state.departure_status IS 'scheduled (no guarantee yet) | guaranteed (AA runs it whatever the pax count) | cancelled (AA cancelled the departure)';
COMMENT ON COLUMN crm.aa_departure_state.min_to_operate IS 'the minimum travellers AA needs to run the departure, when Booking sends it (booking.b2b.v1 1.x does not yet): NULL = not known';

-- ── 2. crm.booking_line_voucher ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.booking_line_voucher (
    booking_line_voucher_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id               UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                            REFERENCES crm.tenant (tenant_id),
    booking_line_id         UUID NOT NULL,
    trip_id                 UUID NOT NULL,
    pickup_enc              BYTEA,
    dropoff_enc             BYTEA,
    service_time            TIME,
    pnr_enc                 BYTEA,
    note_enc                BYTEA,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by              TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at              TIMESTAMPTZ,
    deleted_by              TEXT,
    purge_after             TIMESTAMPTZ,
    CONSTRAINT booking_line_voucher_tenant_id_uq UNIQUE (tenant_id, booking_line_voucher_id),
    CONSTRAINT booking_line_voucher_line_fk FOREIGN KEY (tenant_id, booking_line_id)
        REFERENCES crm.booking_line (tenant_id, booking_line_id) ON DELETE CASCADE,
    CONSTRAINT booking_line_voucher_trip_fk FOREIGN KEY (tenant_id, trip_id)
        REFERENCES crm.trip (tenant_id, trip_id) ON DELETE CASCADE,
    CONSTRAINT booking_line_voucher_enc_chk CHECK (
        COALESCE(octet_length(pickup_enc), 30) >= 30 AND COALESCE(octet_length(dropoff_enc), 30) >= 30
        AND COALESCE(octet_length(pnr_enc), 30) >= 30 AND COALESCE(octet_length(note_enc), 30) >= 30
    ),
    CONSTRAINT booking_line_voucher_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS booking_line_voucher_live_uq ON crm.booking_line_voucher (tenant_id, booking_line_id)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS booking_line_voucher_trip_idx ON crm.booking_line_voucher (tenant_id, trip_id);
ALTER TABLE crm.booking_line_voucher ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.booking_line_voucher FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON crm.booking_line_voucher
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
CREATE TRIGGER booking_line_voucher_set_updated_at
    BEFORE UPDATE ON crm.booking_line_voucher
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
COMMENT ON TABLE crm.booking_line_voucher IS 'AA-1070 (crm-054, item crm-20): the voucher details the agency adds to one booking line for its travellers: pickup and drop-off place, service time, the supplier''s PNR / booking reference and a note, each text under the tenant vault DEK (AAD = tenant, booking_line_voucher, column, id). One live row per line. Cascades from its line and its trip. No reader grant.';
COMMENT ON COLUMN crm.booking_line_voucher.pickup_enc IS 'pii:travel; where the service picks the travellers up (a hotel, an airport, maybe a home address), sealed';
COMMENT ON COLUMN crm.booking_line_voucher.dropoff_enc IS 'pii:travel; where the service drops the travellers, sealed';
COMMENT ON COLUMN crm.booking_line_voucher.service_time IS 'pii:travel; the local time the service starts on its service day (booking_line.service_from)';
COMMENT ON COLUMN crm.booking_line_voucher.pnr_enc IS 'pii:travel; the supplier''s booking reference / airline PNR (opens the booking at the supplier), sealed';
COMMENT ON COLUMN crm.booking_line_voucher.note_enc IS 'pii:free_text; the agency''s note printed on the voucher, sealed';

-- ── Hold rule 4h for the trip-scoped tables of this key ──────────────────────────────────────────
-- crm-029's crm.guard_held_flight rule for any table with trip_id (and traveler_id when it has one): a direct
-- delete, trash or move of a row of a held trip or traveller is refused (CRM10); a cascade (trigger depth > 1) from
-- the trip / traveller / party row passes (that row's guard and crm.erase_held ruled).
CREATE FUNCTION crm.guard_held_travel_doc() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_old jsonb;
    v_new jsonb;
    v_change text;
BEGIN
    IF pg_catalog.pg_trigger_depth() > 1 THEN
        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    END IF;
    v_old := to_jsonb(OLD);
    IF TG_OP = 'DELETE' THEN
        v_change := 'delete';
    ELSE
        v_new := to_jsonb(NEW);
        IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
            v_change := 'trash';
        ELSIF (v_new ->> 'trip_id', v_new ->> 'traveler_id') IS DISTINCT FROM (v_old ->> 'trip_id', v_old ->> 'traveler_id') THEN
            v_change := 'move';
        END IF;
    END IF;
    IF v_change IS NOT NULL
       AND crm.hold_row((v_old ->> 'trip_id')::uuid, (v_old ->> 'traveler_id')::uuid) THEN
        RAISE EXCEPTION 'crm: legal_hold (% of a held % row refused)', v_change, TG_TABLE_NAME USING ERRCODE = 'CRM10';
    END IF;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;
COMMENT ON FUNCTION crm.guard_held_travel_doc() IS 'AA-1070 (crm-054, hold rule 4h for crm.booking_line_voucher, crm.room_assignment, crm.visa_application): CRM10 when a direct statement deletes, trashes or moves a row of a held trip or traveller (crm.hold_row of the OLD trip_id and traveler_id, NULL when the table has none). A cascade (trigger depth > 1) passes, as crm-029''s crm.guard_held_flight. Invoker rights.';
CREATE TRIGGER booking_line_voucher_hold_guard
    BEFORE DELETE OR UPDATE ON crm.booking_line_voucher
    FOR EACH ROW EXECUTE FUNCTION crm.guard_held_travel_doc();

-- ── 3. crm.room_assignment ───────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.room_assignment (
    room_assignment_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id          UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                       REFERENCES crm.tenant (tenant_id),
    trip_id            UUID NOT NULL,
    traveler_id        UUID NOT NULL,
    room_no            SMALLINT NOT NULL,
    room_type          TEXT NOT NULL,
    bed_pref           TEXT,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by         TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at         TIMESTAMPTZ,
    deleted_by         TEXT,
    purge_after        TIMESTAMPTZ,
    CONSTRAINT room_assignment_tenant_id_uq UNIQUE (tenant_id, room_assignment_id),
    CONSTRAINT room_assignment_trip_fk FOREIGN KEY (tenant_id, trip_id)
        REFERENCES crm.trip (tenant_id, trip_id) ON DELETE CASCADE,
    CONSTRAINT room_assignment_traveler_fk FOREIGN KEY (tenant_id, traveler_id)
        REFERENCES crm.traveler (tenant_id, traveler_id) ON DELETE CASCADE,
    CONSTRAINT room_assignment_party_fk FOREIGN KEY (trip_id, traveler_id)
        REFERENCES crm.trip_traveler (trip_id, traveler_id) ON DELETE CASCADE,
    CONSTRAINT room_assignment_values_chk CHECK (
        room_no BETWEEN 1 AND 50
        AND room_type IN ('single', 'double', 'twin', 'triple', 'quad', 'family')
        AND (bed_pref IS NULL OR bed_pref IN ('double_bed', 'twin_beds', 'extra_bed', 'cot'))
    ),
    CONSTRAINT room_assignment_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS room_assignment_live_uq ON crm.room_assignment (tenant_id, trip_id, traveler_id)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS room_assignment_traveler_idx ON crm.room_assignment (traveler_id);
ALTER TABLE crm.room_assignment ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.room_assignment FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON crm.room_assignment
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
CREATE TRIGGER room_assignment_set_updated_at
    BEFORE UPDATE ON crm.room_assignment
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
CREATE TRIGGER room_assignment_hold_guard
    BEFORE DELETE OR UPDATE ON crm.room_assignment
    FOR EACH ROW EXECUTE FUNCTION crm.guard_held_travel_doc();
COMMENT ON TABLE crm.room_assignment IS 'AA-1070 (crm-054, item crm-17): the rooming list of a trip: which room (room_no 1..50, room_type, an optional bed preference) each traveller sleeps in. Edited by the agent and by the lead traveller in the portal; the API checks it against the accepted proposal''s room_config. Goes into the ops release payload (codes and the room number only), the departure manifest and the vouchers. One live row per trip and traveller. Every foreign key cascades (trip, traveller, trip_traveler). No reader grant.';
COMMENT ON COLUMN crm.room_assignment.room_no IS 'pii:travel; the room number within the trip (travellers with the same number share the room)';
COMMENT ON COLUMN crm.room_assignment.room_type IS 'single | double | twin | triple | quad | family (capacity 1, 2, 2, 3, 4, 6; the API checks it)';
COMMENT ON COLUMN crm.room_assignment.bed_pref IS 'pii:travel; double_bed | twin_beds | extra_bed | cot (optional)';

-- ── 4. crm.visa_template ─────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.visa_template (
    visa_template_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                     REFERENCES crm.tenant (tenant_id),
    country          CHARACTER(2) NOT NULL,
    visa_type        TEXT NOT NULL,
    processing_days  SMALLINT,
    fee              NUMERIC(14,2),
    fee_currency     CHARACTER(3),
    documents        JSONB NOT NULL DEFAULT '[]'::jsonb,
    official_url     TEXT,
    active           BOOLEAN NOT NULL DEFAULT true,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by       TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at       TIMESTAMPTZ,
    deleted_by       TEXT,
    purge_after      TIMESTAMPTZ,
    CONSTRAINT visa_template_tenant_id_uq UNIQUE (tenant_id, visa_template_id),
    CONSTRAINT visa_template_settings_fk FOREIGN KEY (tenant_id)
        REFERENCES crm.tenant_settings (tenant_id) ON DELETE CASCADE,
    CONSTRAINT visa_template_values_chk CHECK (
        country ~ '^[A-Z]{2}$'
        AND visa_type IN ('evisa', 'visa_on_arrival', 'embassy', 'visa_exempt', 'transit', 'other')
        AND (processing_days IS NULL OR processing_days BETWEEN 0 AND 365)
        AND (fee IS NULL) = (fee_currency IS NULL)
        AND (fee IS NULL OR (fee >= 0 AND fee <= 99999999.99))
        AND (fee_currency IS NULL OR fee_currency ~ '^[A-Z]{3}$')
        AND jsonb_typeof(documents) = 'array' AND jsonb_array_length(documents) <= 30
        AND octet_length(documents::text) <= 8000
        AND (official_url IS NULL OR (official_url ~ '^https://[^[:space:][:cntrl:]]+$' AND char_length(official_url) <= 500))
    ),
    CONSTRAINT visa_template_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS visa_template_live_uq ON crm.visa_template (tenant_id, country, visa_type)
    WHERE deleted_at IS NULL;
ALTER TABLE crm.visa_template ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.visa_template FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON crm.visa_template
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
CREATE TRIGGER visa_template_set_updated_at
    BEFORE UPDATE ON crm.visa_template
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
COMMENT ON TABLE crm.visa_template IS 'AA-1070 (crm-054, item crm-16): the agency''s own visa guidance for one country (ISO 3166-1 alpha-2) and visa type: processing days, fee + currency, the document list (JSON array of strings), the official https URL. Maintained by the agency (its own responsibility; AA gives no visa advice). One live template per country and type. Commercial guidance, no personal data. Cascades from the agency''s tenant_settings row.';
COMMENT ON COLUMN crm.visa_template.documents IS 'the documents a traveller collects for this visa: a JSON array of at most 30 strings of 1..200 characters (the API checks the strings); copied into each application''s checklist';

-- ── 5. crm.visa_application ──────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.visa_application (
    visa_application_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                        REFERENCES crm.tenant (tenant_id),
    trip_id             UUID NOT NULL,
    traveler_id         UUID NOT NULL,
    visa_template_id    UUID,
    country             CHARACTER(2) NOT NULL,
    visa_type           TEXT NOT NULL,
    status              TEXT NOT NULL DEFAULT 'to_do',
    deadline            DATE,
    submitted_on        DATE,
    decided_on          DATE,
    visa_no_enc         BYTEA,
    valid_from_enc      BYTEA,
    valid_until_enc     BYTEA,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by          TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at          TIMESTAMPTZ,
    deleted_by          TEXT,
    purge_after         TIMESTAMPTZ,
    CONSTRAINT visa_application_tenant_id_uq UNIQUE (tenant_id, visa_application_id),
    CONSTRAINT visa_application_trip_fk FOREIGN KEY (tenant_id, trip_id)
        REFERENCES crm.trip (tenant_id, trip_id) ON DELETE CASCADE,
    CONSTRAINT visa_application_traveler_fk FOREIGN KEY (tenant_id, traveler_id)
        REFERENCES crm.traveler (tenant_id, traveler_id) ON DELETE CASCADE,
    CONSTRAINT visa_application_party_fk FOREIGN KEY (trip_id, traveler_id)
        REFERENCES crm.trip_traveler (trip_id, traveler_id) ON DELETE CASCADE,
    CONSTRAINT visa_application_status_chk CHECK (
        status IN ('to_do', 'collecting', 'submitted', 'approved', 'refused', 'not_needed', 'cancelled')
    ),
    CONSTRAINT visa_application_values_chk CHECK (
        country ~ '^[A-Z]{2}$'
        AND visa_type IN ('evisa', 'visa_on_arrival', 'embassy', 'visa_exempt', 'transit', 'other')
        AND (decided_on IS NULL OR submitted_on IS NULL OR decided_on >= submitted_on)
        AND (status NOT IN ('submitted', 'approved', 'refused') OR submitted_on IS NOT NULL)
        AND (status NOT IN ('approved', 'refused') OR decided_on IS NOT NULL)
        AND (visa_no_enc IS NULL OR status = 'approved')
        AND COALESCE(octet_length(visa_no_enc), 30) >= 30 AND COALESCE(octet_length(valid_from_enc), 30) >= 30
        AND COALESCE(octet_length(valid_until_enc), 30) >= 30
    ),
    CONSTRAINT visa_application_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS visa_application_live_uq
    ON crm.visa_application (tenant_id, trip_id, traveler_id, country) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS visa_application_traveler_idx ON crm.visa_application (traveler_id);
-- The tick reads the open applications whose deadline passed.
CREATE INDEX IF NOT EXISTS visa_application_deadline_idx ON crm.visa_application (tenant_id, deadline)
    WHERE deleted_at IS NULL AND status IN ('to_do', 'collecting');
ALTER TABLE crm.visa_application ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.visa_application FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON crm.visa_application
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
CREATE TRIGGER visa_application_set_updated_at
    BEFORE UPDATE ON crm.visa_application
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
CREATE TRIGGER visa_application_status_transition
    BEFORE UPDATE OF status ON crm.visa_application
    FOR EACH ROW EXECUTE FUNCTION crm.enforce_status_transition();
CREATE TRIGGER visa_application_hold_guard
    BEFORE DELETE OR UPDATE ON crm.visa_application
    FOR EACH ROW EXECUTE FUNCTION crm.guard_held_travel_doc();
COMMENT ON TABLE crm.visa_application IS 'AA-1070 (crm-054, item crm-16): one traveller''s visa for one country on one trip: type, status (to_do -> collecting -> submitted -> approved | refused, not_needed, cancelled; crm.status_transition rows from crm-055), deadline, submitted / decided days, and the granted visa''s number and validity sealed under the tenant vault DEK. visa_template_id is a snapshot reference without a foreign key. One live application per trip, traveller and country. Every foreign key cascades (trip, traveller, trip_traveler). No reader grant.';
COMMENT ON COLUMN crm.visa_application.country IS 'pii:travel; the country the visa is for (ISO 3166-1 alpha-2)';
COMMENT ON COLUMN crm.visa_application.deadline IS 'pii:travel; the day the documents must be ready (an overdue open application opens a task)';
COMMENT ON COLUMN crm.visa_application.submitted_on IS 'pii:travel; the day the application went to the authority';
COMMENT ON COLUMN crm.visa_application.decided_on IS 'pii:travel; the day the authority decided (approved or refused)';
COMMENT ON COLUMN crm.visa_application.visa_no_enc IS 'pii:government_id; the granted visa''s number, sealed (AAD = tenant, visa_application, visa_no_enc, id); only on an approved application';
COMMENT ON COLUMN crm.visa_application.valid_from_enc IS 'pii:government_id; the first day the visa is valid (ISO date), sealed';
COMMENT ON COLUMN crm.visa_application.valid_until_enc IS 'pii:government_id; the last day the visa is valid (ISO date), sealed';
COMMENT ON COLUMN crm.visa_application.visa_template_id IS 'the crm.visa_template the application was made from (a snapshot reference, no foreign key); NULL = made by hand';

-- ── 6. crm.visa_checklist_item ───────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.visa_checklist_item (
    visa_checklist_item_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id              UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                           REFERENCES crm.tenant (tenant_id),
    visa_application_id    UUID NOT NULL,
    label                  TEXT NOT NULL,
    sort                   SMALLINT NOT NULL DEFAULT 0,
    done                   BOOLEAN NOT NULL DEFAULT false,
    done_at                TIMESTAMPTZ,
    done_by_kind           TEXT,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by             TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at             TIMESTAMPTZ,
    deleted_by             TEXT,
    purge_after            TIMESTAMPTZ,
    CONSTRAINT visa_checklist_item_tenant_id_uq UNIQUE (tenant_id, visa_checklist_item_id),
    CONSTRAINT visa_checklist_item_application_fk FOREIGN KEY (tenant_id, visa_application_id)
        REFERENCES crm.visa_application (tenant_id, visa_application_id) ON DELETE CASCADE,
    CONSTRAINT visa_checklist_item_values_chk CHECK (
        char_length(btrim(label)) BETWEEN 1 AND 200 AND label !~ '[[:cntrl:]]'
        AND sort BETWEEN 0 AND 100
        AND (done = (done_at IS NOT NULL)) AND (done = (done_by_kind IS NOT NULL))
        AND (done_by_kind IS NULL OR done_by_kind IN ('member', 'traveler'))
    ),
    CONSTRAINT visa_checklist_item_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE INDEX IF NOT EXISTS visa_checklist_item_application_idx
    ON crm.visa_checklist_item (tenant_id, visa_application_id, sort);
ALTER TABLE crm.visa_checklist_item ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.visa_checklist_item FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON crm.visa_checklist_item
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
CREATE TRIGGER visa_checklist_item_set_updated_at
    BEFORE UPDATE ON crm.visa_checklist_item
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
COMMENT ON TABLE crm.visa_checklist_item IS 'AA-1070 (crm-054, item crm-16): one document a visa application needs (label from the agency''s template or added by the agent), ticked done by the agent or the traveller in the portal. Agency wording, not personal data. Cascades from its application. No reader grant.';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-054', now(), 'AA-1070: travel ops tables: crm.aa_departure_state (Booking feed departure status), crm.booking_line_voucher (sealed voucher details), crm.room_assignment (rooming list), crm.visa_template, crm.visa_application, crm.visa_checklist_item; guards crm.guard_aa_departure_state (CRM53), crm.guard_held_travel_doc (CRM10)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
