-- migrate: expand
-- Migration crm-029: AA-953 CRM-24a Module 11 portal per person (design v3 M11, R22, R33; data-privacy-integrations
-- §2.3 group B `traveler_flight`) — the structured arrival and departure flights a traveller (or their agent) gives in
-- Stage 3, so the itinerary shows the landing day in local time (an overnight flight lands on the next day) and the
-- ops hand-off (CRM-26) and the T-48 h "confirm arrival flight" task (R44 step 1) can read them without free text.
--
-- Owner: AA-Partner (api/migrations/029_crm_traveler_flight.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- DB Migrate applies (Migration Copy Guard). Key crm-029, after crm-028 (AA-952 invoice claims, an expand file on
-- main); renumber if main moves again: file name, this header, the registration below, app/db.py
-- REQUIRED_SCHEMA_VERSIONS.
--
-- What (DM-7: crm.traveler_flight already has its row in root data standards Part B §7, the F1 vault group: kept until
-- the agency deletes the traveller or offboards):
--   1. crm.traveler_flight (base template): one flight per (trip, traveller, direction arrival | departure):
--      flight_no_enc (the flight number under the tenant vault DEK, AAD = traveler_flight id; pii:travel), the airport
--      (IATA code: the landing airport of an arrival, the take-off airport of a departure), sched_local (the scheduled
--      local time AT that airport, without a zone) and tz (the airport's IANA zone, the proposal_day_tz_chk shape of
--      crm-019), who entered it (traveler | member). One live row per (trip, traveller, direction).
--   2. Erasure without a replaced crm.erase_subject: every foreign key of the table cascades. A trip erase deletes its
--      trip_traveler and trip rows, a traveller erase their trip_traveler and traveler rows, an agency erase every
--      trip and traveller, so the flights leave with them, and the agency erase's "nothing left" check finds none.
--      A held trip or traveller is never erased (crm.erase_held refuses first; the parent rows' hold guards refuse a
--      direct delete), so the cascade needs no hold check of its own.
--      tests/integration/test_crm010_schema.py lists the table as cascade-erased and checks the three ON DELETE
--      CASCADE keys, so a later key that replaces crm.erase_subject may name it but never has to.
--   3. RLS (ENABLE + FORCE, tenant_isolation TO the CRM roles); crm_app gets the default DML of crm-001; no reader
--      grant (AI, insights and support never see a flight, design §5.2); the updated_at trigger; the hold guard
--      crm.guard_held_flight (hold rule 4h; not crm.guard_held_change, which a cascade would run without the agency's
--      RLS: see the function's comment).
--   4. crm.otp_challenge.sent_to_bidx (new nullable column): the blind index of the address a portal code went to.
--      Fix E4 lets one address reach two travellers (a companion without an address of their own is reached through
--      the lead's), so a session must stay bound to the address that proved it: the API accepts a session only while
--      that address still reaches the traveller it acts as (a companion given their own address, or a lead whose
--      address the agency changed, ends the sessions the old address proved). NULL (a code issued before this
--      column) never opens a session. The row's 24-hour retention (crm-016) and erasure (crm.erase_subject deletes
--      the traveller's and the trip's otp_challenge rows) are unchanged; the table is never exported.
--
-- Class: expand (root ADR 0017 d3): one new table and one new trigger function, with their constraints, indexes,
-- triggers, policy and comments, and foreign keys from the table (the RI triggers they add on crm.trip, crm.traveler
-- and crm.trip_traveler are allowed); one new nullable column without a default on crm.otp_challenge (not a hot
-- table; no code reads it with SELECT * / RETURNING *); no other change to an existing object, no DO block. Not re-runnable (no DROP / OR
-- REPLACE in an expand file): DB Migrate never applies a registered file twice, and the test conftest skips it. The code PR that reads it carries this file and raises
-- REQUIRED_SCHEMA_VERSIONS to crm-029 (expand: one PR). crm-028 is expand too, so the auto-apply takes both in order.
--
-- Rollback (a forward crm- file, after the code that reads it is reverted): DROP TABLE crm.traveler_flight; DROP
-- FUNCTION crm.guard_held_flight(); ALTER TABLE crm.otp_challenge DROP COLUMN sent_to_bidx.
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

CREATE TABLE IF NOT EXISTS crm.traveler_flight (
    traveler_flight_id  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                        REFERENCES crm.tenant (tenant_id),
    trip_id             UUID NOT NULL,
    traveler_id         UUID NOT NULL,
    direction           TEXT NOT NULL,
    flight_no_enc       BYTEA NOT NULL,
    airport_iata        TEXT NOT NULL,
    sched_local         TIMESTAMP NOT NULL,
    tz                  TEXT NOT NULL,
    entered_by_kind     TEXT NOT NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by          TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at          TIMESTAMPTZ,
    deleted_by          TEXT,
    purge_after         TIMESTAMPTZ,
    CONSTRAINT traveler_flight_tenant_id_uq UNIQUE (tenant_id, traveler_flight_id),
    CONSTRAINT traveler_flight_trip_fk FOREIGN KEY (tenant_id, trip_id)
        REFERENCES crm.trip (tenant_id, trip_id) ON DELETE CASCADE,
    CONSTRAINT traveler_flight_traveler_fk FOREIGN KEY (tenant_id, traveler_id)
        REFERENCES crm.traveler (tenant_id, traveler_id) ON DELETE CASCADE,
    CONSTRAINT traveler_flight_party_fk FOREIGN KEY (trip_id, traveler_id)
        REFERENCES crm.trip_traveler (trip_id, traveler_id) ON DELETE CASCADE,
    CONSTRAINT traveler_flight_direction_chk CHECK (direction IN ('arrival', 'departure')),
    CONSTRAINT traveler_flight_enc_chk CHECK (octet_length(flight_no_enc) >= 30),
    CONSTRAINT traveler_flight_airport_chk CHECK (airport_iata ~ '^[A-Z]{3}$'),
    -- crm-019 proposal_day_tz_chk: an IANA zone name (the API checks it against the zone database too).
    CONSTRAINT traveler_flight_tz_chk CHECK (tz = 'UTC' OR tz ~ '^[A-Z][A-Za-z_]+(/[A-Za-z0-9_+-]+){1,2}$'),
    CONSTRAINT traveler_flight_sched_chk CHECK (
        sched_local >= TIMESTAMP '2000-01-01 00:00' AND sched_local < TIMESTAMP '2100-01-01 00:00'
    ),
    CONSTRAINT traveler_flight_entered_by_chk CHECK (entered_by_kind IN ('traveler', 'member')),
    CONSTRAINT traveler_flight_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS traveler_flight_live_uq ON crm.traveler_flight (tenant_id, trip_id, traveler_id, direction)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS traveler_flight_traveler_idx ON crm.traveler_flight (traveler_id);
-- The ops hand-off and the T-48 h task read the arrivals of a day.
CREATE INDEX IF NOT EXISTS traveler_flight_sched_idx ON crm.traveler_flight (tenant_id, direction, sched_local)
    WHERE deleted_at IS NULL;

ALTER TABLE crm.traveler_flight ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.traveler_flight FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON crm.traveler_flight
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);

CREATE TRIGGER traveler_flight_set_updated_at
    BEFORE UPDATE ON crm.traveler_flight
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
-- The hold rule (crm-010 4h) for this table. Not crm.guard_held_change: a cascade (RI action) runs as the table owner
-- without FORCE RLS, so that function would read every agency's legal holds and refuse an erase in one agency because
-- another agency holds something. A cascade (trigger depth > 1) comes from deleting the trip / traveller / party row,
-- whose own hold guard and crm.erase_held already ruled; a direct statement (depth 1, RLS on) is checked here.
CREATE FUNCTION crm.guard_held_flight() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_change text;
BEGIN
    IF pg_catalog.pg_trigger_depth() > 1 THEN
        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    END IF;
    IF TG_OP = 'DELETE' THEN
        v_change := 'delete';
    ELSIF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
        v_change := 'trash';
    ELSIF (NEW.trip_id, NEW.traveler_id) IS DISTINCT FROM (OLD.trip_id, OLD.traveler_id) THEN
        v_change := 'trip_id';
    END IF;
    IF v_change IS NOT NULL AND crm.hold_row(OLD.trip_id, OLD.traveler_id) THEN
        RAISE EXCEPTION 'crm: legal_hold (% of a held traveler_flight row refused)', v_change USING ERRCODE = 'CRM10';
    END IF;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;
COMMENT ON FUNCTION crm.guard_held_flight() IS 'AA-953 (crm-029, hold rule 4h for crm.traveler_flight): CRM10 when a direct statement deletes, trashes or moves a flight of a held trip or traveller (crm.hold_row). A cascade from its trip / traveller / party row (trigger depth > 1) passes: that row''s guard and crm.erase_held ruled, and an RI action would read other agencies'' holds (no FORCE RLS for the owner). Invoker rights.';
CREATE TRIGGER traveler_flight_hold_guard
    BEFORE DELETE OR UPDATE ON crm.traveler_flight
    FOR EACH ROW EXECUTE FUNCTION crm.guard_held_flight();

COMMENT ON TABLE crm.traveler_flight IS 'AA-953 (crm-029; design v3 R33, R44, data-privacy-integrations §2.3 group B): the arrival and departure flight of one traveller on one trip, written in the client portal (Stage 3) or by the agent. The flight number is under the tenant vault DEK; the airport, the scheduled local time and its IANA zone are plain so the ops hand-off and the T-48 h task can query them. One live row per trip, traveller and direction. Every foreign key cascades: the flights leave with their trip, traveller or party row (erasure included). No reader role is granted it.';
COMMENT ON COLUMN crm.traveler_flight.flight_no_enc IS 'pii:travel; the flight number (carrier code + number, e.g. VN611), AES-256-GCM under the tenant vault DEK, AAD = tenant, traveler_flight, flight_no_enc, id';
COMMENT ON COLUMN crm.traveler_flight.airport_iata IS 'pii:travel; the IATA code of the landing airport (arrival) or the take-off airport (departure)';
COMMENT ON COLUMN crm.traveler_flight.sched_local IS 'pii:travel; the scheduled local time at airport_iata, without a zone (the zone is tz): an overnight flight lands on its own local date';
COMMENT ON COLUMN crm.traveler_flight.tz IS 'the IANA zone of airport_iata (sched_local AT TIME ZONE tz is the instant)';
COMMENT ON COLUMN crm.traveler_flight.entered_by_kind IS 'traveler (the client portal) | member (an agent)';

-- 4. The address a portal code went to (a session's proof, app/portal/public.py _signed_in).
ALTER TABLE crm.otp_challenge ADD COLUMN IF NOT EXISTS sent_to_bidx BYTEA;
COMMENT ON COLUMN crm.otp_challenge.sent_to_bidx IS 'pii:contact; the blind index (crm.traveler.email_bidx) of the address the code went to: the traveller''s own, or the lead''s for a companion without an address of their own (AA-953 Fix E4). A portal session acts as a traveller only while that address still reaches them; NULL never opens a session';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-029', now(), 'AA-953 CRM-24a portal per person: crm.traveler_flight (structured arrival / departure flights per trip and traveller, flight number under the vault DEK, local time + IANA zone; cascading keys, no erase_subject change); crm.otp_challenge.sent_to_bidx (a portal session bound to the address its code went to)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
