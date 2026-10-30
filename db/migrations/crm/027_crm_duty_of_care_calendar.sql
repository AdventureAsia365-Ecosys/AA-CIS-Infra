-- Migration crm-027: AA-961 CRM-30 duty of care + calendar (design v3 R37 "Where are my clients + incident flag", R15
-- calendar; final §5 group I `incident_flag`; F9 Travelling "an AA incident shows a banner") — the AA incident flags a
-- departure carries (from the Booking event feed `departure.incident` / `departure.incident_cleared`, booking.b2b.v1
-- 1.1) and one ICS calendar feed per agency member (a signed, revocable subscription URL; no Google / Microsoft calendar
-- write in this slice: bring-your-own sync comes later, errata S247).
--
-- Owner: AA-Partner (api/migrations/027_crm_duty_of_care_calendar.sql). AA-CIS-Infra db/migrations/crm/ holds the byte
-- copy DB Migrate applies (Migration Copy Guard). Key crm-027. crm.erase_subject below is the crm-026 text with two
-- tables added to its agency scope (item 3); a later key that replaces it starts from THIS text. crm.erase_held,
-- crm.lifecycle_purge_expired and crm.trip_delete_blockers are unchanged.
--
-- What (DM-7: root data standards Part B §7; crm.incident_flag already has a row, crm.calendar_feed joins the agency
-- configuration row in the root PR merged before the Infra copy):
--   1. crm.incident_flag (base template): one AA incident on a departure as Booking reported it: departure_id (Booking's
--      id, the same shape as crm.booking_line.departure_id), incident_code (the contract's fixed list: weather, road,
--      health, political, supplier, other; never free text, never traveller data), status open -> cleared, raised_at
--      (the event's occurred_at) / cleared_at, and the Booking event ids that opened and cleared it. One open flag per
--      departure. Ids, codes and times only: no personal data. Written only by a job / platform actor
--      (crm.guard_incident_flag, SQLSTATE CRM41): an agency member never raises or clears an AA incident. The affected
--      trips are not stored: they are the agency's live trips with a booking line on the departure, read at view time
--      (so a line added after the flag is covered, and an agency without one sees nothing).
--   2. crm.calendar_feed (base template): one ICS subscription of one member: the SHA-256 of a random token (the token
--      is in the URL only, shown once), scope mine | agency, status active -> revoked (revoked_at, revoked_by),
--      expires_at (at most 400 days), last_fetched_at / fetch_count. One active feed per member. SELECT-only policy
--      calendar_feed_token_lookup TO crm_app keyed on app.calendar_feed_hash (hex), live feeds only: set only by
--      app.tenancy.calendar_feed_tx(), the client_link_token_lookup pattern of crm-012. crm.guard_calendar_feed
--      (SQLSTATE CRM42): the token, member, scope, expiry and agency of a row never change; a member creates only
--      their own feed; only that member or an owner revokes it; the feed's own fetch (actor calendar_feed:<id>)
--      touches only last_fetched_at / fetch_count of its own row.
--   3. crm.erase_subject (the crm-026 text): the agency scope also deletes incident_flag and calendar_feed (before the
--      members). No trip or traveller scope change: neither table names a trip or a traveller.
--   4. RLS (ENABLE + FORCE, tenant_isolation TO the CRM roles), crm_app SELECT + INSERT + UPDATE (no DELETE, no
--      TRUNCATE), no reader grant (AI, insights and support never see either table); status moves in
--      crm.status_transition.
--   SQLSTATE: CRM41 incident_flag_source, CRM42 calendar_feed_guard (CRM43 is the next key).
--
-- Class: contract (ADR 0017 §3: a replaced crm.erase_subject), so no `-- migrate: expand` header: MIG-4 order, this
-- file's PR first, the Infra copy, a manual DB Migrate apply, then the code PR (adds crm-027 to
-- REQUIRED_SCHEMA_VERSIONS).
--
-- Order: after crm-026 (AA-967 portability); Guard 0 refuses to run before it is registered (erase_subject builds on its
-- text).
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL. Idempotent (IF NOT EXISTS, DROP …
-- IF EXISTS, CREATE OR REPLACE, ON CONFLICT DO NOTHING). Rollback: a forward crm- file (MIG-14); the code before AA-961
-- never reads the new tables, and the two new erase steps only matter once rows exist, so it runs unchanged on this
-- schema.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '15min';

-- ── Guard 0: runs as the owner, after crm-026 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-027: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-026') THEN
        RAISE EXCEPTION 'crm-027: crm-026 (AA-967 portability) lands first';
    END IF;
    IF to_regclass('crm.member') IS NULL OR to_regclass('crm.export_job') IS NULL
       OR to_regprocedure('crm.erase_rows(text,text,uuid,uuid,boolean,text)') IS NULL
       OR to_regprocedure('crm.enforce_status_transition()') IS NULL
       OR to_regprocedure('crm.set_updated_at()') IS NULL
       OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint WHERE conrelid = 'crm.member'::regclass
                        AND conname = 'member_tenant_member_uq')
       OR position('''export_job'', ''data_request''' IN (SELECT prosrc FROM pg_catalog.pg_proc
                    WHERE oid = 'crm.erase_subject(text,uuid,uuid,boolean)'::regprocedure)) = 0 THEN
        RAISE EXCEPTION 'crm-027: crm.member (crm-008 same-agency key), crm.export_job or the crm-026 erase_subject text missing';
    END IF;
END $$;

-- ── 1. crm.incident_flag ─────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.incident_flag (
    incident_flag_id  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id         UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                      REFERENCES crm.tenant (tenant_id),
    departure_id      TEXT NOT NULL,
    incident_code     TEXT NOT NULL,
    status            TEXT NOT NULL DEFAULT 'open',
    raised_at         TIMESTAMPTZ NOT NULL,
    raised_event_id   TEXT NOT NULL,
    cleared_at        TIMESTAMPTZ,
    cleared_event_id  TEXT,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by        TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at        TIMESTAMPTZ,
    deleted_by        TEXT,
    purge_after       TIMESTAMPTZ,
    -- booking_line_refs_chk (crm-014) shape: the same departure id joins the agency's lines.
    CONSTRAINT incident_flag_departure_chk CHECK (departure_id ~ '^[A-Za-z0-9:_.-]{1,80}$'),
    CONSTRAINT incident_flag_code_chk CHECK (
        incident_code IN ('weather', 'road', 'health', 'political', 'supplier', 'other')
    ),
    CONSTRAINT incident_flag_status_chk CHECK (status IN ('open', 'cleared')),
    CONSTRAINT incident_flag_events_chk CHECK (
        raised_event_id ~ '^[A-Za-z0-9:_.-]{1,64}$'
        AND (cleared_event_id IS NULL OR cleared_event_id ~ '^[A-Za-z0-9:_.-]{1,64}$')
    ),
    CONSTRAINT incident_flag_cleared_chk CHECK (
        (status = 'cleared') = (cleared_at IS NOT NULL)
        AND (cleared_event_id IS NULL OR cleared_at IS NOT NULL)
        AND (cleared_at IS NULL OR cleared_at >= raised_at - interval '1 day')
    ),
    CONSTRAINT incident_flag_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS incident_flag_open_uq ON crm.incident_flag (tenant_id, departure_id)
    WHERE status = 'open' AND deleted_at IS NULL;
-- A replayed Booking event never opens a second flag (the feed also dedupes on crm.inbox_events).
CREATE UNIQUE INDEX IF NOT EXISTS incident_flag_raised_event_uq ON crm.incident_flag (tenant_id, raised_event_id);
CREATE INDEX IF NOT EXISTS incident_flag_departure_idx ON crm.incident_flag (tenant_id, departure_id, raised_at DESC);
COMMENT ON TABLE crm.incident_flag IS 'AA-961 (crm-027; design v3 R37, final §5 group I): an AA incident on a departure as AA-Booking reported it in the booking.b2b.v1 event feed (departure.incident opens, departure.incident_cleared clears; Booking sends departure events only to agencies with a live hold or line on the departure). Ids, codes and times only. The affected trips are read at view time (the agency''s live trips with a booking line on departure_id). Written by job / platform actors only (crm.guard_incident_flag, CRM41). Kept until the agency offboards (crm.erase_subject agency scope).';
COMMENT ON COLUMN crm.incident_flag.departure_id IS 'Booking''s departure id (booking.b2b.v1 Event.departure_id; same shape as crm.booking_line.departure_id)';
COMMENT ON COLUMN crm.incident_flag.incident_code IS 'booking.b2b.v1 Event.incident_code (a fixed list; never free text, never traveller data)';
COMMENT ON COLUMN crm.incident_flag.raised_at IS 'the departure.incident event''s occurred_at (Booking''s clock)';

CREATE OR REPLACE FUNCTION crm.guard_incident_flag() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_actor text := COALESCE(current_setting('app.actor', true), '');
BEGIN
    -- AA raises and clears incidents (the Booking feed job, or AA staff); an agency member never does.
    IF v_actor NOT LIKE 'job:%' AND v_actor NOT LIKE 'platform:%' AND v_actor NOT LIKE 'seed:%' THEN
        RAISE EXCEPTION 'crm: incident_flag_source (an AA incident is written by the Booking feed only, actor %)',
            NULLIF(v_actor, '') USING ERRCODE = 'CRM41';
    END IF;
    IF TG_OP = 'UPDATE' AND (NEW.tenant_id, NEW.departure_id, NEW.incident_code, NEW.raised_at, NEW.raised_event_id)
                            IS DISTINCT FROM
                            (OLD.tenant_id, OLD.departure_id, OLD.incident_code, OLD.raised_at, OLD.raised_event_id) THEN
        RAISE EXCEPTION 'crm: incident_flag_source (a raised incident keeps its departure, code and event)'
            USING ERRCODE = 'CRM41';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION crm.guard_incident_flag() FROM PUBLIC;
CREATE OR REPLACE TRIGGER incident_flag_guard
    BEFORE INSERT OR UPDATE ON crm.incident_flag
    FOR EACH ROW EXECUTE FUNCTION crm.guard_incident_flag();

-- ── 2. crm.calendar_feed ─────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.calendar_feed (
    calendar_feed_id  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id         UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                      REFERENCES crm.tenant (tenant_id),
    member_id         UUID NOT NULL,
    token_hash        BYTEA NOT NULL,
    scope             TEXT NOT NULL DEFAULT 'mine',
    status            TEXT NOT NULL DEFAULT 'active',
    expires_at        TIMESTAMPTZ NOT NULL DEFAULT now() + interval '365 days',
    revoked_at        TIMESTAMPTZ,
    revoked_by        TEXT,
    last_fetched_at   TIMESTAMPTZ,
    fetch_count       INTEGER NOT NULL DEFAULT 0,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by        TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at        TIMESTAMPTZ,
    deleted_by        TEXT,
    purge_after       TIMESTAMPTZ,
    CONSTRAINT calendar_feed_member_fk FOREIGN KEY (tenant_id, member_id) REFERENCES crm.member (tenant_id, member_id),
    CONSTRAINT calendar_feed_token_uq UNIQUE (token_hash),
    CONSTRAINT calendar_feed_token_chk CHECK (octet_length(token_hash) = 32),
    CONSTRAINT calendar_feed_scope_chk CHECK (scope IN ('mine', 'agency')),
    CONSTRAINT calendar_feed_status_chk CHECK (status IN ('active', 'revoked')),
    CONSTRAINT calendar_feed_revoked_chk CHECK (
        (status = 'revoked') = (revoked_at IS NOT NULL) AND (revoked_at IS NULL) = (revoked_by IS NULL)
    ),
    CONSTRAINT calendar_feed_expiry_chk CHECK (expires_at > created_at AND expires_at <= created_at + interval '400 days'),
    CONSTRAINT calendar_feed_fetch_chk CHECK (fetch_count >= 0),
    CONSTRAINT calendar_feed_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS calendar_feed_active_uq ON crm.calendar_feed (tenant_id, member_id)
    WHERE status = 'active' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS calendar_feed_member_idx ON crm.calendar_feed (tenant_id, member_id, created_at DESC);
COMMENT ON TABLE crm.calendar_feed IS 'AA-961 (crm-027; design v3 R15, CRM-30): one ICS calendar subscription of one agency member (departures, returns, payment and invoice due dates, signing deadlines, tasks and calls; no client names in the feed). Only the SHA-256 of the random token is stored; the URL is shown once. calendar_feed_token_lookup finds one live row by its hash (app.tenancy.calendar_feed_tx). Revoking stops the subscription (the URL answers 404). crm.guard_calendar_feed (CRM42). crm_app never deletes one; erased with the agency (crm.erase_subject).';
COMMENT ON COLUMN crm.calendar_feed.token_hash IS 'conf:credential; SHA-256 of the feed token (never the token)';
COMMENT ON COLUMN crm.calendar_feed.scope IS 'mine = the member''s own trips, tasks and calls; agency = the whole agency';

DROP POLICY IF EXISTS calendar_feed_token_lookup ON crm.calendar_feed;
CREATE POLICY calendar_feed_token_lookup ON crm.calendar_feed
    FOR SELECT TO crm_app
    USING (
        token_hash = decode(NULLIF(current_setting('app.calendar_feed_hash', true), ''), 'hex')
        AND status = 'active'
        AND expires_at > now()
        AND deleted_at IS NULL
    );
COMMENT ON POLICY calendar_feed_token_lookup ON crm.calendar_feed IS 'AA-961 (crm-027): the one live feed (active, not expired or trashed) whose token hash the public ICS route was called with, only while app.calendar_feed_hash is set (app.tenancy.calendar_feed_tx). SELECT only; the client_link_token_lookup pattern (crm-012).';

CREATE OR REPLACE FUNCTION crm.guard_calendar_feed() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_actor text := COALESCE(current_setting('app.actor', true), '');
    v_role text := COALESCE(current_setting('app.member_role', true), '');
BEGIN
    IF v_actor = '' THEN
        RAISE EXCEPTION 'crm: calendar_feed_guard (no actor)' USING ERRCODE = 'CRM42';
    END IF;
    IF TG_OP = 'INSERT' THEN
        -- A member subscribes for themselves only (the token reaches only the person who asked for it).
        IF v_actor LIKE 'member:%' AND v_actor <> 'member:' || NEW.member_id::text THEN
            RAISE EXCEPTION 'crm: calendar_feed_guard (a member creates only their own feed)' USING ERRCODE = 'CRM42';
        END IF;
        IF v_actor NOT LIKE 'member:%' AND v_actor NOT LIKE 'seed:%' THEN
            RAISE EXCEPTION 'crm: calendar_feed_guard (feeds are created by their member)' USING ERRCODE = 'CRM42';
        END IF;
        RETURN NEW;
    END IF;
    IF (NEW.tenant_id, NEW.member_id, NEW.token_hash, NEW.scope, NEW.expires_at, NEW.created_at, NEW.created_by)
       IS DISTINCT FROM
       (OLD.tenant_id, OLD.member_id, OLD.token_hash, OLD.scope, OLD.expires_at, OLD.created_at, OLD.created_by) THEN
        RAISE EXCEPTION 'crm: calendar_feed_guard (token, member, scope and expiry are fixed; make a new feed)'
            USING ERRCODE = 'CRM42';
    END IF;
    IF v_actor LIKE 'calendar_feed:%' THEN
        -- The subscription's own fetch: only its counters, only on its own row.
        IF v_actor <> 'calendar_feed:' || OLD.calendar_feed_id::text
           OR (NEW.status, NEW.revoked_at, NEW.revoked_by, NEW.deleted_at, NEW.deleted_by, NEW.purge_after)
              IS DISTINCT FROM
              (OLD.status, OLD.revoked_at, OLD.revoked_by, OLD.deleted_at, OLD.deleted_by, OLD.purge_after) THEN
            RAISE EXCEPTION 'crm: calendar_feed_guard (a fetch only counts itself)' USING ERRCODE = 'CRM42';
        END IF;
    ELSIF v_actor LIKE 'member:%' THEN
        IF v_actor <> 'member:' || OLD.member_id::text AND v_role <> 'owner' THEN
            RAISE EXCEPTION 'crm: calendar_feed_guard (only the member or an owner changes a feed)'
                USING ERRCODE = 'CRM42';
        END IF;
        IF (NEW.last_fetched_at, NEW.fetch_count) IS DISTINCT FROM (OLD.last_fetched_at, OLD.fetch_count) THEN
            RAISE EXCEPTION 'crm: calendar_feed_guard (the fetch counters belong to the feed)' USING ERRCODE = 'CRM42';
        END IF;
    ELSIF v_actor NOT LIKE 'platform:%' AND v_actor NOT LIKE 'job:%' AND v_actor NOT LIKE 'seed:%' THEN
        RAISE EXCEPTION 'crm: calendar_feed_guard (actor % may not change a feed)', v_actor USING ERRCODE = 'CRM42';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION crm.guard_calendar_feed() FROM PUBLIC;
CREATE OR REPLACE TRIGGER calendar_feed_guard
    BEFORE INSERT OR UPDATE ON crm.calendar_feed
    FOR EACH ROW EXECUTE FUNCTION crm.guard_calendar_feed();

-- ── 4. Status moves, RLS, grants, triggers ───────────────────────────────────────────────────────
INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('incident_flag', 'open', 'cleared'),
    ('calendar_feed', 'active', 'revoked')
ON CONFLICT DO NOTHING;

DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['incident_flag', 'calendar_feed'] LOOP
        EXECUTE format('ALTER TABLE crm.%I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE crm.%I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON crm.%I', t);
        EXECUTE format(
            'CREATE POLICY tenant_isolation ON crm.%I '
            'TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser '
            'USING (tenant_id = NULLIF(current_setting(''app.tenant_id'', true), '''')::uuid) '
            'WITH CHECK (tenant_id = NULLIF(current_setting(''app.tenant_id'', true), '''')::uuid)', t);
        EXECUTE format(
            'CREATE OR REPLACE TRIGGER %I BEFORE UPDATE ON crm.%I FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at()',
            t || '_set_updated_at', t);
        EXECUTE format(
            'CREATE OR REPLACE TRIGGER %I BEFORE UPDATE OF status ON crm.%I '
            'FOR EACH ROW EXECUTE FUNCTION crm.enforce_status_transition()', t || '_status_transition', t);
        -- crm_app reads and writes; it never deletes or truncates. No reader role is granted anything.
        EXECUTE format('REVOKE DELETE, TRUNCATE ON crm.%I FROM crm_app', t);
        EXECUTE format('GRANT SELECT, INSERT, UPDATE ON crm.%I TO crm_app', t);
    END LOOP;
END $$;

-- ── 3. crm.erase_subject: the crm-026 text, agency scope + incident_flag, calendar_feed ──────────
CREATE OR REPLACE FUNCTION crm.erase_subject(p_scope text, p_subject uuid, p_profile_token uuid DEFAULT NULL,
                                             p_dry_run boolean DEFAULT true) RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_tenant uuid := NULLIF(current_setting('app.tenant_id', true), '')::uuid;
    v_actor text := COALESCE(current_setting('app.actor', true), '');
    v_counts jsonb := '{}'::jsonb;
    v_blockers text[];
    v_status text;
    v_has_token boolean;
    v_step text[];
    v_left text[] := '{}';
    r record;
    -- Tables an agency erase keeps: the agency row (status offboarded), the destroyed key rows, the audit and its
    -- export registry and chain (crm-007: they leave with the partition drops / the archive), the erasure receipts,
    -- the lifecycle counts and the holds (ids and codes only), and (crm-026, AA-967) the portability export records
    -- and the data-request log (ids, codes, hashes and dates only; the offboarding code deletes the export objects).
    c_keep CONSTANT text[] := ARRAY['tenant', 'tenant_key', 'audit_event', 'audit_export_tenant',
                                    'audit_export_manifest', 'erasure_request', 'lifecycle_run', 'legal_hold',
                                    'export_job', 'data_request'];
BEGIN
    IF v_tenant IS NULL THEN
        RAISE EXCEPTION 'crm: erase_subject needs app.tenant_id' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF p_dry_run IS NULL OR p_subject IS NULL THEN
        RAISE EXCEPTION 'crm: erase_subject needs a subject and dry_run true or false'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF p_scope NOT IN ('trip', 'traveler', 'task', 'note', 'document', 'relation', 'booking_line', 'agency_supplier',
                       'conversation', 'tenant') THEN
        RAISE EXCEPTION 'crm: erase_subject scope % is unknown', p_scope USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- Hold rule 4g: serialise with hold placement. SHARE conflicts with the ROW EXCLUSIVE of an INSERT / UPDATE on
    -- crm.legal_hold: a hold placed now waits until this transaction ends; a hold being placed makes this wait, then
    -- the check below (a new snapshot: this function is VOLATILE) sees it.
    LOCK TABLE crm.legal_hold IN SHARE MODE;

    -- The subject must exist in this agency (FORCE RLS: crm_owner sees app.tenant_id's rows only).
    IF p_scope = 'trip' THEN
        -- FOR UPDATE: a row that would reference the subject (FOR KEY SHARE of its foreign key) waits until this erase
        -- ends, so nothing is attached to it between the hold check and the deletes (the hold guard triggers catch
        -- any other change).
        PERFORM 1 FROM crm.trip WHERE trip_id = p_subject FOR UPDATE;
    ELSIF p_scope = 'traveler' THEN
        SELECT profile_token_enc IS NOT NULL INTO v_has_token FROM crm.traveler WHERE traveler_id = p_subject
           FOR UPDATE;
    ELSIF p_scope = 'task' THEN
        PERFORM 1 FROM crm.task WHERE task_id = p_subject;
    ELSIF p_scope = 'note' THEN
        PERFORM 1 FROM crm.note WHERE note_id = p_subject;
    ELSIF p_scope = 'document' THEN
        PERFORM 1 FROM crm.document WHERE document_id = p_subject;
    ELSIF p_scope = 'relation' THEN
        PERFORM 1 FROM crm.traveler_relation WHERE relation_id = p_subject;
    ELSIF p_scope = 'booking_line' THEN
        PERFORM 1 FROM crm.booking_line WHERE booking_line_id = p_subject FOR UPDATE;
    ELSIF p_scope = 'agency_supplier' THEN
        SELECT kind INTO v_status FROM crm.agency_supplier WHERE agency_supplier_id = p_subject FOR UPDATE;
    ELSIF p_scope = 'conversation' THEN
        PERFORM 1 FROM crm.conversation WHERE conversation_id = p_subject FOR UPDATE;
    ELSE
        IF p_subject <> v_tenant THEN
            RAISE EXCEPTION 'crm: subject_not_found (a tenant erase names the agency of app.tenant_id)'
                USING ERRCODE = 'CRM13';
        END IF;
        SELECT status INTO v_status FROM crm.tenant WHERE tenant_id = v_tenant;
    END IF;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'crm: subject_not_found (% %)', p_scope, p_subject USING ERRCODE = 'CRM13';
    END IF;

    -- Hold rule 4e: any held row among those this erase would delete or update refuses it, dry run included.
    IF crm.erase_held(p_scope, p_subject, p_profile_token) THEN
        RAISE EXCEPTION 'crm: legal_hold (an active legal hold reaches a row the erase of % % would change)',
            p_scope, p_subject USING ERRCODE = 'CRM10';
    END IF;

    IF p_scope = 'trip' THEN
        v_blockers := crm.trip_delete_blockers(p_subject);
        IF cardinality(v_blockers) > 0 THEN
            RAISE EXCEPTION 'crm: delete_blocked %', array_to_string(v_blockers, ',') USING ERRCODE = 'CRM11';
        END IF;
    ELSIF p_scope = 'traveler' THEN
        IF EXISTS (SELECT 1 FROM crm.trip_traveler tt JOIN crm.trip t ON t.trip_id = tt.trip_id
                    WHERE tt.traveler_id = p_subject AND t.deleted_at IS NULL) THEN
            RAISE EXCEPTION 'crm: traveler_on_trip (delete or erase the client''s live trips first)'
                USING ERRCODE = 'CRM12';
        END IF;
        IF v_has_token AND p_profile_token IS NULL THEN
            RAISE EXCEPTION 'crm: profile_token_required' USING ERRCODE = 'CRM15';
        END IF;
        -- Consistency guard (the database cannot open the encrypted pointer; the caller decrypted it from this row,
        -- bound by its AAD): every party row of the token is the F2 twin of one of the traveller's own party rows
        -- (same trip, same role).
        IF p_profile_token IS NOT NULL AND EXISTS (
            SELECT 1 FROM crm.trip_party p
             WHERE p.traveler_token = p_profile_token
               AND NOT EXISTS (SELECT 1 FROM crm.trip_traveler tt
                                WHERE tt.trip_id = p.trip_id AND tt.traveler_id = p_subject AND tt.role = p.role)) THEN
            RAISE EXCEPTION 'crm: profile_token_mismatch' USING ERRCODE = 'CRM15';
        END IF;
    ELSIF p_scope = 'agency_supplier' THEN
        -- crm-014: the built-in Adventure Asia row leaves only with the agency; a supplier lines still name stays.
        IF v_status = 'aa' THEN
            RAISE EXCEPTION 'crm: aa_supplier_builtin (the Adventure Asia row leaves with the agency only)'
                USING ERRCODE = 'CRM22';
        END IF;
        IF EXISTS (SELECT 1 FROM crm.booking_line l WHERE l.agency_supplier_id = p_subject) THEN
            RAISE EXCEPTION 'crm: supplier_in_use (booking lines name this supplier)' USING ERRCODE = 'CRM27';
        END IF;
    ELSIF p_scope = 'tenant' AND NOT p_dry_run AND v_status <> 'offboarding' THEN
        -- A dry run (the counts the owner sees before confirming) works on an active agency.
        RAISE EXCEPTION 'crm: tenant_not_offboarding (status %)', v_status USING ERRCODE = 'CRM14';
    END IF;

    IF NOT p_dry_run THEN
        PERFORM set_config('app.erasing', 'on', true);
    END IF;

    IF p_scope = 'trip' THEN
        -- crm-012: the trip's submissions let go of the trip and of its links first, then the links and slots go.
        -- crm-014: the trip's line money, then its lines. crm-015: the messages of its conversations, then those.
        -- crm-016: signatures, codes, portal access, payments, schedule rows and proposals before the links.
        -- crm-017: the trip's AA requests (the outage queue) before its lines.
        -- crm-019: the builder rows (picks, rules, options, blocks, days) before the proposals.
        -- crm-021: the trip's metric events (they name its proposals) first.
        -- crm-022: the version's prep packs before the proposals.
        -- crm-023: the dispatch attempts of the trip's dispatch rows before those rows.
        -- crm-024: the refund requests (they name payments) before the payments, the invoice lines and invoices after
        -- them (payments name invoices) and before the schedule rows and proposals.
        -- crm-025: the signed evidence (terms_acceptance, signature_event) has no key on the trip and stays (DM-7
        -- claim-period exception); the receipt counts it (*_kept). crm.lifecycle_purge_expired deletes it later.
        v_counts := jsonb_build_object(
            'terms_acceptance_kept', (SELECT count(*) FROM crm.terms_acceptance WHERE trip_id = p_subject),
            'signature_event_kept', (SELECT count(*) FROM crm.signature_event WHERE trip_id = p_subject));
        FOREACH v_step SLICE 1 IN ARRAY ARRAY[
            ['metric_event', 'trip_id = $1', ''],
            ['signature_request', 'trip_id = $1', ''],
            ['otp_challenge', 'trip_id = $1', ''],
            ['traveler_access', 'trip_id = $1', ''],
            ['refund_request', 'trip_id = $1', ''],
            ['payment', 'trip_id = $1', ''],
            ['invoice_line', 'trip_id = $1', ''],
            ['invoice', 'trip_id = $1', ''],
            ['payment_schedule', 'trip_id = $1', ''],
            ['selection', 'trip_id = $1', ''],
            ['option_rule', 'trip_id = $1', ''],
            ['option', 'trip_id = $1', ''],
            ['option_block', 'trip_id = $1', ''],
            ['proposal_day', 'trip_id = $1', ''],
            ['prep_pack_selection', 'trip_id = $1', ''],
            ['proposal', 'trip_id = $1', ''],
            ['form_submission', 'trip_id = $1', 'trip_id = NULL, client_link_id = NULL'],
            ['client_link', 'trip_id = $1', ''],
            ['meeting_slot', 'trip_id = $1', ''],
            ['dispatch_attempt', 'dispatch_id IN (SELECT q.dispatch_id FROM crm.dispatch_queue q '
                                 'WHERE q.trip_id = $1)', ''],
            ['dispatch_queue', 'trip_id = $1', ''],
            ['message', 'conversation_id IN (SELECT c.conversation_id FROM crm.conversation c WHERE c.trip_id = $1)', ''],
            ['conversation', 'trip_id = $1', ''],
            ['trip_commitment', 'trip_id = $1', ''],
            ['aa_request', 'trip_id = $1', ''],
            ['booking_line_money', 'booking_line_id IN (SELECT l.booking_line_id FROM crm.booking_line l '
                                   'WHERE l.trip_id = $1)', ''],
            ['booking_line', 'trip_id = $1', ''],
            ['document', 'trip_id = $1', ''],
            ['note', 'trip_id = $1', ''],
            ['task', 'trip_id = $1', ''],
            ['trip_stage_history', 'trip_id = $1', ''],
            ['trip_party', 'trip_id = $1', ''],
            ['trip_traveler', 'trip_id = $1', ''],
            ['trip', 'trip_id = $1', '']
        ] LOOP
            v_counts := v_counts || jsonb_build_object(
                v_step[1] || CASE WHEN v_step[3] <> '' THEN '_unlinked' ELSE '' END,
                crm.erase_rows(v_step[1], v_step[2], p_subject, NULL, p_dry_run, NULLIF(v_step[3], '')));
        END LOOP;
    ELSIF p_scope = 'traveler' THEN
        -- crm-012: their call slots (also those their submissions booked) before the submissions, their links after.
        -- crm-015: the messages of their conversations, then those. crm-016: the name they typed to accept a proposal
        -- (the proposal's link names them; before their links go), their signatures, codes and portal access.
        -- crm-023: the dispatch attempts of their dispatch rows before those rows.
        -- crm-025: also the signatures they signed as a guardian (their access signed them); the signed evidence
        -- (terms_acceptance, signature_event) stays (DM-7 claim-period exception) and the receipt counts it.
        v_counts := jsonb_build_object(
            'terms_acceptance_kept', (SELECT count(*) FROM crm.terms_acceptance WHERE traveler_id = p_subject),
            'signature_event_kept', (SELECT count(*) FROM crm.signature_event
                                      WHERE traveler_id = p_subject OR signer_traveler_id = p_subject));
        FOREACH v_step SLICE 1 IN ARRAY ARRAY[
            ['proposal', 'accepted_name_enc IS NOT NULL AND link_id IN (SELECT l.link_id FROM crm.client_link l '
                         'WHERE l.traveler_id = $1)', 'accepted_name_enc = NULL, accepted_name_erased_at = now()'],
            ['signature_request', 'traveler_id = $1 OR signer_traveler_id = $1', ''],
            ['otp_challenge', 'traveler_id = $1', ''],
            ['traveler_access', 'traveler_id = $1', ''],
            ['meeting_slot', 'traveler_id = $1 OR form_submission_id IN (SELECT s.submission_id '
                             'FROM crm.form_submission s WHERE s.traveler_id = $1)', ''],
            ['dispatch_attempt', 'dispatch_id IN (SELECT q.dispatch_id FROM crm.dispatch_queue q '
                                 'WHERE q.traveler_id = $1)', ''],
            ['dispatch_queue', 'traveler_id = $1', ''],
            ['message', 'conversation_id IN (SELECT c.conversation_id FROM crm.conversation c '
                        'WHERE c.traveler_id = $1)', ''],
            ['conversation', 'traveler_id = $1', ''],
            ['traveler_health', 'traveler_id = $1', ''],
            ['document', 'traveler_id = $1', ''],
            ['note', 'traveler_id = $1', ''],
            ['traveler_relation', 'from_traveler_id = $1 OR to_traveler_id = $1', ''],
            ['trip_traveler', 'traveler_id = $1', ''],
            ['trip_party', 'traveler_token = $2', ''],
            ['profile_history', 'traveler_token = $2', ''],
            ['traveler_profile', 'traveler_token = $2', ''],
            ['consent', 'traveler_id = $1', ''],
            ['form_submission', 'traveler_id = $1', ''],
            ['client_link', 'traveler_id = $1', ''],
            ['traveler', 'referrer_traveler_id = $1', 'referrer_traveler_id = NULL'],
            ['traveler', 'traveler_id = $1', '']
        ] LOOP
            v_counts := v_counts || jsonb_build_object(
                v_step[1] || CASE WHEN v_step[3] = '' THEN '' WHEN v_step[1] = 'proposal' THEN '_acceptance_name_erased'
                                  ELSE '_referrer_unlinked' END,
                crm.erase_rows(v_step[1], v_step[2], p_subject, p_profile_token, p_dry_run, NULLIF(v_step[3], '')));
        END LOOP;
    ELSIF p_scope IN ('task', 'note', 'document') THEN
        v_counts := jsonb_build_object(p_scope,
            crm.erase_rows(p_scope, p_scope || '_id = $1', p_subject, NULL, p_dry_run));
    ELSIF p_scope = 'relation' THEN
        v_counts := jsonb_build_object('traveler_relation',
            crm.erase_rows('traveler_relation', 'relation_id = $1', p_subject, NULL, p_dry_run));
    ELSIF p_scope = 'booking_line' THEN
        -- crm-014: the trash purge of a planning line: its money, then the line. crm-017: its AA requests first (an
        -- agency line has none; an AA line never reaches the trash, the guard refuses it).
        v_counts := jsonb_build_object(
            'aa_request', crm.erase_rows('aa_request', 'booking_line_id = $1', p_subject, NULL, p_dry_run),
            'booking_line_money', crm.erase_rows('booking_line_money', 'booking_line_id = $1', p_subject, NULL, p_dry_run),
            'booking_line', crm.erase_rows('booking_line', 'booking_line_id = $1', p_subject, NULL, p_dry_run));
    ELSIF p_scope = 'agency_supplier' THEN
        v_counts := jsonb_build_object('agency_supplier',
            crm.erase_rows('agency_supplier', 'agency_supplier_id = $1', p_subject, NULL, p_dry_run));
    ELSIF p_scope = 'conversation' THEN
        -- crm-015: the trash purge of a conversation (an Unmatched one the agent deleted): its messages, then it. Kept
        -- attachments are documents of the trip / traveller and stay with them.
        v_counts := jsonb_build_object(
            'message', crm.erase_rows('message', 'conversation_id = $1', p_subject, NULL, p_dry_run),
            'conversation', crm.erase_rows('conversation', 'conversation_id = $1', p_subject, NULL, p_dry_run));
    ELSE
        -- The whole agency. Memberships are deleted as a platform action (crm-008 guard_member_write lets only an
        -- unscoped or platform context delete a member); the caller's actor is restored afterwards.
        PERFORM set_config('app.actor', 'platform:crm_offboarding', true);
        -- crm-013: the agency's CIS membership feed records (ids and codes) go first.
        -- crm-014: line money, lines and suppliers before the trips; the FX overrides before the members (set_by).
        -- crm-015: messages and conversations before the trips and travellers; saved replies, imports, the forward-in
        -- address and the mailboxes before the credentials and the members.
        -- crm-016: signatures, codes, portal access, payments, schedule rows, proposals and agreement versions first.
        -- crm-017: the Booking feed records and cursor, then the AA requests before the lines.
        -- crm-019: the builder rows before the proposals. crm-021: the metric events before the proposals and members.
        -- crm-022: the prep packs before the proposals; the message templates with the agency's mail settings.
        -- crm-023: the dispatch attempts before the dispatch rows.
        -- crm-024: refund requests, payments, invoice lines, invoices before the schedule rows; the payment methods and
        -- the invoice number sequence with the agency's settings.
        -- crm-025: the signed evidence (terms_acceptance, signature_event) leaves with the agency, before the
        -- signatures and the agreement versions.
        -- crm-027: the AA incident flags with the Booking feed records; the calendar feeds before the members.
        FOREACH v_step SLICE 1 IN ARRAY ARRAY[
            ['membership_inbox', ''], ['inbox_events', ''], ['booking_feed_state', ''], ['incident_flag', ''],
            ['metric_event', ''],
            ['terms_acceptance', ''], ['signature_event', ''], ['signature_request', ''], ['otp_challenge', ''], ['traveler_access', ''],
            ['refund_request', ''], ['payment', ''], ['invoice_line', ''], ['invoice', ''],
            ['payment_schedule', ''], ['selection', ''], ['option_rule', ''], ['option', ''], ['option_block', ''],
            ['proposal_day', ''], ['prep_pack_selection', ''], ['proposal', ''], ['agreement_doc', ''],
            ['dispatch_attempt', ''], ['dispatch_queue', ''], ['message', ''], ['conversation', ''],
            ['trip_commitment', ''], ['aa_request', ''], ['booking_line_money', ''], ['booking_line', ''],
            ['agency_supplier', ''], ['document', ''], ['traveler_health', ''],
            ['note', ''], ['task', ''], ['trip_stage_history', ''], ['trip_party', ''], ['trip_traveler', ''],
            ['traveler_relation', ''], ['consent', ''], ['meeting_slot', ''], ['form_submission', ''],
            ['client_link', ''], ['profile_history', ''],
            ['traveler_profile', ''], ['placeholder_map', 'optional'], ['llm_call', ''], ['trip', ''],
            ['traveler', 'unlink'], ['traveler', ''], ['intake_form', ''], ['form_definition', ''],
            ['saved_reply', ''], ['message_template', ''], ['mail_import', ''], ['ingest_address', ''], ['channel_account', ''],
            ['integration_credential', ''], ['fx_rate_override', ''], ['calendar_feed', ''],
            ['payment_provider_account', ''], ['invoice_sequence', ''], ['tenant_settings', ''],
            ['member_invitation', 'optional'], ['owner_recovery_request', 'optional'],
            ['tenant_entitlement', 'optional'], ['member', '']
        ] LOOP
            CONTINUE WHEN v_step[2] = 'optional' AND to_regclass('crm.' || v_step[1]) IS NULL;
            IF v_step[2] = 'unlink' THEN
                v_counts := v_counts || jsonb_build_object('traveler_referrer_unlinked',
                    crm.erase_rows('traveler', 'referrer_traveler_id IS NOT NULL', p_subject, NULL, p_dry_run,
                                   'referrer_traveler_id = NULL'));
            ELSE
                v_counts := v_counts || jsonb_build_object(v_step[1],
                    crm.erase_rows(v_step[1], 'true', p_subject, NULL, p_dry_run));
            END IF;
        END LOOP;
        PERFORM set_config('app.actor', v_actor, true);
        -- Nothing of the agency may be left in a tenant table outside the keep list: a table added later that this
        -- function does not know fails the erase (rolled back) instead of keeping personal data silently.
        IF NOT p_dry_run THEN
            FOR r IN SELECT c.relname::text AS name
                       FROM pg_catalog.pg_class c
                       JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped
                      WHERE c.relnamespace = 'crm'::regnamespace AND c.relkind IN ('r', 'p') AND NOT c.relispartition
                        AND c.relname <> ALL (c_keep) AND c.relname NOT LIKE 'audit_event%'
                      ORDER BY 1 LOOP
                IF NOT (SELECT relforcerowsecurity FROM pg_catalog.pg_class WHERE oid = ('crm.' || quote_ident(r.name))::regclass) THEN
                    v_left := v_left || r.name;  -- without FORCE RLS the owner would see every agency: refuse
                ELSE
                    EXECUTE format('SELECT EXISTS (SELECT 1 FROM crm.%I)', r.name) INTO v_has_token;
                    IF v_has_token THEN
                        v_left := v_left || r.name;
                    END IF;
                END IF;
            END LOOP;
            IF cardinality(v_left) > 0 THEN
                RAISE EXCEPTION 'crm: erase_incomplete (rows left in %)', array_to_string(v_left, ', ')
                    USING ERRCODE = 'CRM16';
            END IF;
        END IF;
    END IF;

    IF NOT p_dry_run THEN
        PERFORM set_config('app.erasing', '', true);
    END IF;
    RETURN jsonb_build_object('scope', p_scope, 'dry_run', p_dry_run, 'counts', v_counts);
END;
$$;
REVOKE ALL ON FUNCTION crm.erase_subject(text, uuid, uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.erase_subject(text, uuid, uuid, boolean) TO crm_eraser;

COMMENT ON FUNCTION crm.erase_subject(text, uuid, uuid, boolean) IS 'AA-942 (crm-010, design §4.10, Fix B16), extended by AA-943 (crm-012) to client_link and meeting_slot, by AA-978 (crm-013) to membership_inbox (agency scope), by AA-944 (crm-014) to the ledger (trip and agency scopes: booking_line_money, booking_line; agency scope: agency_supplier, fx_rate_override; new scopes booking_line and agency_supplier for the trash purge), by AA-945 (crm-015) to mail (trip, traveller and agency scopes: message, conversation; agency scope: saved_reply, mail_import, ingest_address, channel_account; new scope conversation for the trash purge), by AA-946 (crm-016) to the lifecycle tables (trip and agency scopes: signature_request, otp_challenge, traveler_access, payment, payment_schedule, proposal; traveller scope: signature_request, otp_challenge, traveler_access, and the typed acceptance name of the proposals their links carried (accepted_name_enc := NULL); agency scope: agreement_doc) by AA-947 (crm-017) to the AA lines (trip, booking_line and agency scopes: aa_request; agency scope: inbox_events, booking_feed_state) by AA-949 (crm-019) to the proposal builder (trip and agency scopes: selection, option_rule, option, option_block, proposal_day) by AA-950 (crm-021) to crm.metric_event (trip and agency scopes) by AA-951 (crm-022) to crm.prep_pack_selection (trip and agency scopes) and crm.message_template (agency scope) by AA-993 G4b (crm-023) to crm.dispatch_attempt (trip, traveller and agency scopes, before crm.dispatch_queue) and by AA-952 (crm-024) to the invoices and payments (trip and agency scopes: crm.refund_request before crm.payment, crm.invoice_line and crm.invoice after it and before crm.payment_schedule; agency scope: crm.payment_provider_account, crm.invoice_sequence) and by AA-955 (crm-025) to the signed evidence (agency scope: crm.terms_acceptance, crm.signature_event; trip and traveller scopes KEEP them, DM-7 claim-period exception, and count them as terms_acceptance_kept / signature_event_kept; traveller scope also erases the signatures the traveller signed as a guardian) and by AA-967 (crm-026) to the keep list of the agency scope (crm.export_job, crm.data_request: receipts without personal data) and by AA-961 (crm-027) to the agency scope (crm.incident_flag, crm.calendar_feed): the only hard-delete path of agency data. Scopes trip, traveler (needs the decrypted F2 profile token), task, note, document, relation, booking_line, agency_supplier, conversation, tenant (status offboarding, except a dry run; every tenant table except the keep list). Used by the trash purge and by erasure / offboarding (which skip the trash). Refuses: CRM10 legal_hold (the hold rule: any held row among those the erase would delete or update, crm.erase_held), CRM11 delete_blocked, CRM12 traveler_on_trip, CRM13 subject_not_found, CRM14 tenant_not_offboarding, CRM15 profile token, CRM16 erase_incomplete, CRM22 the Adventure Asia supplier row, CRM27 a supplier lines name. Never touches audit_event. Takes LOCK TABLE crm.legal_hold IN SHARE MODE first (serialised with hold placement). EXECUTE: crm_eraser only (SET LOCAL ROLE inside the lifecycle context).';

-- ── Guard 1: the shape this file promises ────────────────────────────────────────────────────────
DO $$
DECLARE
    t text;
    r text;
    p text;
    v_src text;
BEGIN
    FOREACH t IN ARRAY ARRAY['incident_flag', 'calendar_feed'] LOOP
        IF NOT (SELECT relrowsecurity AND relforcerowsecurity FROM pg_catalog.pg_class
                 WHERE oid = ('crm.' || t)::regclass) THEN
            RAISE EXCEPTION 'crm-027: crm.% must have ENABLE + FORCE row level security', t;
        END IF;
        FOREACH r IN ARRAY ARRAY['crm_ai_reader', 'crm_insights', 'crm_support_reader', 'crm_eraser'] LOOP
            FOREACH p IN ARRAY ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'] LOOP
                IF pg_catalog.has_table_privilege(r, 'crm.' || t, p) THEN
                    RAISE EXCEPTION 'crm-027: reader % may % on crm.%', r, p, t;
                END IF;
            END LOOP;
        END LOOP;
        IF pg_catalog.has_table_privilege('crm_app', 'crm.' || t, 'TRUNCATE')
           OR pg_catalog.has_table_privilege('crm_app', 'crm.' || t, 'DELETE')
           OR NOT pg_catalog.has_table_privilege('crm_app', 'crm.' || t, 'INSERT')
           OR NOT pg_catalog.has_table_privilege('crm_app', 'crm.' || t, 'UPDATE') THEN
            RAISE EXCEPTION 'crm-027: crm_app must have SELECT, INSERT, UPDATE and no DELETE / TRUNCATE on crm.%', t;
        END IF;
    END LOOP;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_policy pol JOIN pg_catalog.pg_class c ON c.oid = pol.polrelid
               WHERE c.relnamespace = 'crm'::regnamespace AND 0 = ANY (pol.polroles)) THEN
        RAISE EXCEPTION 'crm-027: a crm policy applies TO PUBLIC (catalogue rule b); name the CRM roles';
    END IF;
    IF pg_catalog.has_function_privilege('crm_app', 'crm.erase_subject(text,uuid,uuid,boolean)', 'EXECUTE')
       OR NOT pg_catalog.has_function_privilege('crm_eraser', 'crm.erase_subject(text,uuid,uuid,boolean)', 'EXECUTE')
       OR pg_catalog.has_function_privilege('public', 'crm.erase_subject(text,uuid,uuid,boolean)', 'EXECUTE') THEN
        RAISE EXCEPTION 'crm-027: crm.erase_subject must be executable by crm_eraser only';
    END IF;
    SELECT prosrc INTO v_src FROM pg_catalog.pg_proc WHERE oid = 'crm.erase_subject(text,uuid,uuid,boolean)'::regprocedure;
    -- Every table an earlier key taught erase_subject (the crm-026 text kept whole), and this key's two.
    FOREACH t IN ARRAY ARRAY['terms_acceptance', 'signature_event', 'refund_request', 'invoice_line', 'invoice',
                             'payment_provider_account', 'invoice_sequence', 'dispatch_attempt', 'dispatch_queue',
                             'prep_pack_selection', 'message_template', 'metric_event', 'selection', 'option_rule',
                             'option', 'option_block', 'proposal_day', 'aa_request', 'inbox_events',
                             'booking_feed_state', 'signature_request', 'otp_challenge', 'traveler_access', 'payment',
                             'payment_schedule', 'proposal', 'agreement_doc', 'message', 'conversation',
                             'saved_reply', 'mail_import', 'ingest_address', 'channel_account', 'booking_line_money',
                             'booking_line', 'agency_supplier', 'fx_rate_override', 'membership_inbox', 'client_link',
                             'meeting_slot', 'export_job', 'data_request', 'incident_flag', 'calendar_feed'] LOOP
        IF position(quote_literal(t) IN v_src) = 0 THEN
            RAISE EXCEPTION 'crm-027: crm.erase_subject does not name crm.%', t;
        END IF;
    END LOOP;
    IF position('accepted_name_erased_at' IN v_src) = 0 OR position('signature_event_kept' IN v_src) = 0 THEN
        RAISE EXCEPTION 'crm-027: crm.erase_subject lost the crm-016 typed acceptance name or the crm-025 kept evidence step';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_policy WHERE polrelid = 'crm.calendar_feed'::regclass
                    AND polname = 'calendar_feed_token_lookup' AND polcmd = 'r') THEN
        RAISE EXCEPTION 'crm-027: crm.calendar_feed needs the SELECT-only calendar_feed_token_lookup policy';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-027', now(), 'AA-961 CRM-30 duty of care + calendar: crm.incident_flag (AA incidents on a departure from the Booking feed, ids and codes only, job / platform writers only), crm.calendar_feed (one revocable ICS subscription per member, token hash + calendar_feed_token_lookup), erase_subject agency scope + the two tables')
ON CONFLICT (version) DO NOTHING;

COMMIT;
