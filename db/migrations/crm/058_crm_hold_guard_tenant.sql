-- Migration crm-058: AA-1085 — every legal-hold guard reads the holds of the row's own agency (an explicit tenant_id
-- predicate), not of whichever agencies row security happens to let through.
--
-- Owner: AA-Partner (api/migrations/058_crm_hold_guard_tenant.sql). AA-CIS-Infra db/migrations/crm/ holds the byte
-- copy DB Migrate applies (Migration Copy Guard). Key crm-058: crm-057 belongs to another lane of the same wave; if
-- main moves, renumber: file name, this header, the registration below, app/db.py REQUIRED_SCHEMA_VERSIONS and the
-- tests that name it (git grep '058_' and 'crm-058').
--
-- Why: a foreign-key action (ON DELETE CASCADE / SET NULL) runs its query, and the BEFORE triggers it fires, as the
-- table owner with row security off (PostgreSQL's RI queries ignore FORCE ROW LEVEL SECURITY for the owner). The hold
-- guards of crm-010 .. crm-054 read crm.legal_hold through crm.hold_trip / hold_traveler / hold_row, which rely on RLS
-- for the agency: inside a cascade they see every agency's holds, so an agency-wide hold of agency A would refuse a
-- cascade in agency B (and the refusal tells B that a hold exists somewhere). crm-029 / crm-034 / crm-054 worked
-- around it by letting every cascade pass (trigger depth > 1) and crm-056 left crm.partner_commission without a hold
-- guard; both leave the hold rule unenforced on a cascade from a row that has no hold guard of its own.
--
-- What:
--   1. crm.hold_trip_of(tenant, trip), crm.hold_traveler_of(tenant, traveler), crm.hold_row_of(tenant, trip,
--      traveler): the crm-010 hold rule 4a-4d with an explicit tenant_id = p_tenant on every crm row they read
--      (crm.legal_hold, crm.trip_traveler). A NULL tenant matches no hold; the guards below never pass one (they
--      refuse a row without tenant_id). The one-argument functions stay as they are for their callers that run under
--      RLS (crm.erase_held, crm.legal_hold_blocks, the trash pre-check, the redaction job).
--   2. The hold guard trigger functions, replaced with the same rules, each reading holds of OLD.tenant_id only:
--      crm.guard_held_change (crm-010; 35 tables), crm.guard_message (crm-015), crm.guard_held_flight (crm-029),
--      crm.guard_ops_release and crm.guard_supplier_manifest_export (crm-034), crm.guard_held_travel_doc (crm-054).
--      crm.guard_held_flight and crm.guard_held_travel_doc no longer let a cascade pass: a cascade onto a held row is
--      refused like a direct statement (hold rule 4d: a row is held when its trip or traveller is). Every erase
--      crm.erase_subject allows is unchanged: crm.erase_held already refuses an erase that reaches a held row, and the
--      cascades of these tables come from a trip / traveller / party / line row with the same trip and traveller.
--      crm.guard_ops_release and crm.guard_supplier_manifest_export keep their cascade / owner pass (it is about who
--      writes a release, not about holds).
--   3. crm.partner_commission gets the hold guard crm-056 left off for this reason: crm.guard_held_change('trip_id').
--      A partner delete that would cascade onto a commission of a held trip is refused (CRM10); a commission's trip
--      never moves (crm-056 partner_commission_fixed), so the guard acts on a delete or a trash only.
--
-- Behaviour on apply: no refusal changes inside one agency except a cascade onto a held row of crm.traveler_flight,
-- crm.booking_line_voucher, crm.room_assignment, crm.visa_application or crm.partner_commission (refused now, CRM10);
-- a hold of another agency never refuses anything any more. The API maps CRM10 to 409 legal_hold already.
--
-- Class: contract (replaces six existing trigger functions, adds a trigger to crm.partner_commission). MIG-4: this
-- migration-only PR, applied on Dev by Infra Migration Apply once every job table is idle, then the code PR (the
-- readiness raise). DM-7.1: no new table. No crm.erase_subject change.
--
-- Rollback (a NEW forward migration): the crm-010 / crm-015 / crm-029 / crm-034 / crm-054 texts of the six functions;
-- DROP TRIGGER partner_commission_hold_guard ON crm.partner_commission; DROP FUNCTION crm.hold_row_of(uuid, uuid,
-- uuid), crm.hold_traveler_of(uuid, uuid), crm.hold_trip_of(uuid, uuid).
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL. Re-runnable (CREATE OR REPLACE,
-- ON CONFLICT DO NOTHING).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '5min';

-- ── Guard 0: runs as the owner, after crm-056 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-058: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-056') THEN
        RAISE EXCEPTION 'crm-058: crm-056 (AA-1071 partner commission) lands first';
    END IF;
    IF to_regclass('crm.legal_hold') IS NULL OR to_regclass('crm.partner_commission') IS NULL
       OR to_regprocedure('crm.guard_held_change()') IS NULL OR to_regprocedure('crm.guard_message()') IS NULL
       OR to_regprocedure('crm.guard_held_flight()') IS NULL OR to_regprocedure('crm.guard_ops_release()') IS NULL
       OR to_regprocedure('crm.guard_supplier_manifest_export()') IS NULL
       OR to_regprocedure('crm.guard_held_travel_doc()') IS NULL THEN
        RAISE EXCEPTION 'crm-058: crm.legal_hold, crm.partner_commission or a hold guard function is missing';
    END IF;
END $$;

-- ── 1. The hold rule of one agency (crm-010 4a-4d, explicit tenant) ──────────────────────────────
-- 4a + 4c: a held trip of the agency.
CREATE OR REPLACE FUNCTION crm.hold_trip_of(p_tenant uuid, p_trip uuid) RETURNS boolean
    LANGUAGE sql
    STABLE
    SET search_path = pg_catalog, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1 FROM crm.legal_hold h
         WHERE h.tenant_id = p_tenant
           AND h.status = 'active'
           AND (h.scope = 'tenant'
                OR (p_trip IS NOT NULL AND h.scope = 'trip' AND h.subject_id = p_trip)
                OR (p_trip IS NOT NULL AND h.scope = 'traveler'
                    AND h.subject_id IN (SELECT tt.traveler_id FROM crm.trip_traveler tt
                                          WHERE tt.tenant_id = p_tenant AND tt.trip_id = p_trip)))
    );
$$;

-- 4b + 4c: a held traveller of the agency.
CREATE OR REPLACE FUNCTION crm.hold_traveler_of(p_tenant uuid, p_traveler uuid) RETURNS boolean
    LANGUAGE sql
    STABLE
    SET search_path = pg_catalog, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1 FROM crm.legal_hold h
         WHERE h.tenant_id = p_tenant
           AND h.status = 'active'
           AND (h.scope = 'tenant'
                OR (p_traveler IS NOT NULL AND h.scope = 'traveler' AND h.subject_id = p_traveler)
                OR (p_traveler IS NOT NULL AND h.scope = 'trip'
                    AND h.subject_id IN (SELECT tt.trip_id FROM crm.trip_traveler tt
                                          WHERE tt.tenant_id = p_tenant AND tt.traveler_id = p_traveler)))
    );
$$;

-- 4d: a held row of the agency (NULL trip and traveller: the agency hold only).
CREATE OR REPLACE FUNCTION crm.hold_row_of(p_tenant uuid, p_trip uuid, p_traveler uuid) RETURNS boolean
    LANGUAGE sql
    STABLE
    SET search_path = pg_catalog, pg_temp
AS $$
    SELECT crm.hold_trip_of(p_tenant, p_trip) OR crm.hold_traveler_of(p_tenant, p_traveler);
$$;
DO $$
DECLARE
    f text;
BEGIN
    FOREACH f IN ARRAY ARRAY['crm.hold_trip_of(uuid,uuid)', 'crm.hold_traveler_of(uuid,uuid)',
                             'crm.hold_row_of(uuid,uuid,uuid)'] LOOP
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f);
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO crm_app', f);
    END LOOP;
END $$;
COMMENT ON FUNCTION crm.hold_trip_of(uuid, uuid) IS 'AA-1085 (crm-058, hold rule 4a/4c of crm-010 for one agency): the trip is held in agency p_tenant: an active hold of that agency names it, names a traveller on its party (trip_traveler of that agency), or is that agency''s hold. Every read carries tenant_id = p_tenant, so it gives the same answer inside a foreign-key cascade (no row security) as under RLS. A NULL tenant matches nothing (callers refuse it first). Invoker rights.';
COMMENT ON FUNCTION crm.hold_traveler_of(uuid, uuid) IS 'AA-1085 (crm-058, hold rule 4b/4c of crm-010 for one agency): the traveller is held in agency p_tenant: an active hold of that agency names them, names a trip of that agency whose party they are on, or is that agency''s hold. One level. Explicit tenant_id = p_tenant on every read. Invoker rights.';
COMMENT ON FUNCTION crm.hold_row_of(uuid, uuid, uuid) IS 'AA-1085 (crm-058, hold rule 4d of crm-010 for one agency): crm.hold_trip_of OR crm.hold_traveler_of. The function every hold guard trigger calls with the row''s own tenant_id (OLD.tenant_id). Invoker rights.';

-- ── 2a. crm.guard_held_change (crm-010): the holds of OLD.tenant_id ──────────────────────────────
CREATE OR REPLACE FUNCTION crm.guard_held_change() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    o jsonb := to_jsonb(OLD);
    n jsonb;
    c text;
    v_change text;
    v_held boolean;
    v_tenant uuid := (to_jsonb(OLD) ->> 'tenant_id')::uuid;
BEGIN
    IF v_tenant IS NULL THEN
        RAISE EXCEPTION 'crm: hold guard on % without a tenant_id (the hold rule is per agency)', TG_TABLE_NAME;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM crm.legal_hold h WHERE h.tenant_id = v_tenant AND h.status = 'active') THEN
        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;  -- nothing is held in this agency
    END IF;
    IF TG_OP = 'DELETE' THEN
        v_change := 'delete';
    ELSE
        n := to_jsonb(NEW);
        IF o ? 'deleted_at' AND o->'deleted_at' = 'null'::jsonb AND n->'deleted_at' <> 'null'::jsonb THEN
            v_change := 'trash';
        ELSIF TG_NARGS > 0 THEN
            FOREACH c IN ARRAY TG_ARGV LOOP
                IF o->c <> 'null'::jsonb AND (n->c) IS DISTINCT FROM (o->c) THEN
                    v_change := c;
                    EXIT;
                END IF;
            END LOOP;
        END IF;
    END IF;
    IF v_change IS NULL THEN
        RETURN NEW;
    END IF;
    IF TG_TABLE_NAME = 'traveler_relation' THEN
        v_held := crm.hold_traveler_of(v_tenant, (o->>'from_traveler_id')::uuid)
               OR crm.hold_traveler_of(v_tenant, (o->>'to_traveler_id')::uuid);
    ELSE
        v_held := crm.hold_row_of(v_tenant, (o->>'trip_id')::uuid, (o->>'traveler_id')::uuid);
    END IF;
    IF v_held THEN
        RAISE EXCEPTION 'crm: legal_hold (% of a held % row refused)', v_change, TG_TABLE_NAME USING ERRCODE = 'CRM10';
    END IF;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;
COMMENT ON FUNCTION crm.guard_held_change() IS 'AA-942 (crm-010, hold rule 4h), AA-1085 (crm-058: the holds of the row''s own agency, OLD.tenant_id, through crm.hold_row_of / hold_traveler_of; a row without tenant_id is refused): BEFORE DELETE OR UPDATE trigger: CRM10 when the OLD row is held (a relation: either end) and the statement deletes it, trashes it, or moves a guarded column (the trigger arguments) away from a value. The same answer inside a foreign-key cascade (no row security) as under RLS.';

-- ── 2b. crm.guard_message (crm-015): the conversation and the holds of OLD.tenant_id ─────────────
CREATE OR REPLACE FUNCTION crm.guard_message() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_app boolean := current_user::text = 'crm_app';
    v_change text;
    v_trip uuid;
    v_traveler uuid;
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF v_app AND OLD.status <> 'draft_autosaved' THEN
            RAISE EXCEPTION 'crm: message_not_deletable (only a draft is discarded; % messages stay)', OLD.status
                USING ERRCODE = 'CRM28';
        END IF;
        v_change := 'delete';
    ELSE
        IF v_app AND OLD.status <> 'draft_autosaved' AND NEW.status <> 'draft_autosaved'
           AND (NEW.subject_enc IS DISTINCT FROM OLD.subject_enc OR NEW.body_enc IS DISTINCT FROM OLD.body_enc
                OR NEW.body_html_enc IS DISTINCT FROM OLD.body_html_enc OR NEW.from_enc IS DISTINCT FROM OLD.from_enc
                OR NEW.from_bidx IS DISTINCT FROM OLD.from_bidx OR NEW.to_enc IS DISTINCT FROM OLD.to_enc
                OR NEW.attachments IS DISTINCT FROM OLD.attachments OR NEW.direction IS DISTINCT FROM OLD.direction) THEN
            RAISE EXCEPTION 'crm: message_sealed (a % message keeps its content)', OLD.status USING ERRCODE = 'CRM29';
        END IF;
        IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
            v_change := 'trash';
        ELSIF NEW.conversation_id IS DISTINCT FROM OLD.conversation_id THEN
            v_change := 'conversation_id';
        ELSIF NEW.subject_enc IS DISTINCT FROM OLD.subject_enc OR NEW.body_enc IS DISTINCT FROM OLD.body_enc
              OR NEW.body_html_enc IS DISTINCT FROM OLD.body_html_enc OR NEW.attachments IS DISTINCT FROM OLD.attachments THEN
            v_change := 'content';
        END IF;
    END IF;
    -- Hold rule 4h through the conversation: its trip / traveller decide (4d), holds of this agency only.
    IF v_change IS NOT NULL
       AND EXISTS (SELECT 1 FROM crm.legal_hold h WHERE h.tenant_id = OLD.tenant_id AND h.status = 'active') THEN
        SELECT c.trip_id, c.traveler_id INTO v_trip, v_traveler
          FROM crm.conversation c WHERE c.tenant_id = OLD.tenant_id AND c.conversation_id = OLD.conversation_id;
        IF crm.hold_row_of(OLD.tenant_id, v_trip, v_traveler) THEN
            RAISE EXCEPTION 'crm: legal_hold (% of a held message refused)', v_change USING ERRCODE = 'CRM10';
        END IF;
    END IF;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;
COMMENT ON FUNCTION crm.guard_message() IS 'AA-945 (crm-015), AA-1085 (crm-058: the holds of the message''s own agency, OLD.tenant_id): for crm_app, only a draft is deleted (CRM28 message_not_deletable) and a message that is not (and does not become) a draft keeps its content (CRM29 message_sealed); for every role, the hold rule 4h through the conversation''s trip / traveller: no delete, trash, content change or move of a held message (CRM10).';

-- ── 2c. crm.guard_held_flight (crm-029): every depth, the holds of OLD.tenant_id ─────────────────
CREATE OR REPLACE FUNCTION crm.guard_held_flight() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_change text;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_change := 'delete';
    ELSIF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
        v_change := 'trash';
    ELSIF (NEW.trip_id, NEW.traveler_id) IS DISTINCT FROM (OLD.trip_id, OLD.traveler_id) THEN
        v_change := 'trip_id';
    END IF;
    IF v_change IS NOT NULL AND crm.hold_row_of(OLD.tenant_id, OLD.trip_id, OLD.traveler_id) THEN
        RAISE EXCEPTION 'crm: legal_hold (% of a held traveler_flight row refused)', v_change USING ERRCODE = 'CRM10';
    END IF;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;
COMMENT ON FUNCTION crm.guard_held_flight() IS 'AA-953 (crm-029, hold rule 4h for crm.traveler_flight), AA-1085 (crm-058): CRM10 when a statement or a cascade deletes, trashes or moves a flight of a held trip or traveller of its own agency (crm.hold_row_of with OLD.tenant_id: the same answer inside a foreign-key cascade, which runs without row security, as under RLS). Invoker rights.';

-- ── 2d. crm.guard_ops_release (crm-034): the purge check reads the holds of OLD.tenant_id ────────
CREATE OR REPLACE FUNCTION crm.guard_ops_release() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_actor text := COALESCE(NULLIF(current_setting('app.actor', true), ''), '');
    -- The columns a view or a withdrawal may change; everything else must stay as it was.
    v_view_cols text[] := ARRAY['view_count', 'last_viewed_at', 'updated_at'];
    v_withdraw_cols text[] := ARRAY['withdrawn_at', 'withdraw_reason', 'updated_at'];
BEGIN
    -- A cascade from the trip (an erase, trigger depth > 1) passes: the trip's own guard and crm.erase_held ruled.
    IF pg_catalog.pg_trigger_depth() > 1 OR current_user = 'crm_owner' THEN
        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    END IF;
    IF TG_OP = 'INSERT' THEN
        IF v_actor NOT LIKE 'job:%' THEN
            RAISE EXCEPTION 'crm: ops_release_guard (a release is created by the release job only, actor %)', v_actor
                USING ERRCODE = 'CRM45';
        END IF;
        IF NEW.purged_at IS NOT NULL OR NEW.withdrawn_at IS NOT NULL OR NEW.view_count <> 0 THEN
            RAISE EXCEPTION 'crm: ops_release_guard (a new release is live, unviewed and not withdrawn)'
                USING ERRCODE = 'CRM45';
        END IF;
        RETURN NEW;
    END IF;
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'crm: ops_release_guard (a release leaves only with its trip; a purge keeps the receipt row)'
            USING ERRCODE = 'CRM45';
    END IF;
    -- UPDATE
    IF (NEW.ops_release_id, NEW.tenant_id, NEW.trip_id, NEW.created_on, NEW.released_at, NEW.created_at, NEW.created_by)
       IS DISTINCT FROM
       (OLD.ops_release_id, OLD.tenant_id, OLD.trip_id, OLD.created_on, OLD.released_at, OLD.created_at, OLD.created_by)
    THEN
        RAISE EXCEPTION 'crm: ops_release_guard (a release''s trip, reason and release time never change)'
            USING ERRCODE = 'CRM45';
    END IF;
    IF OLD.purged_at IS NOT NULL THEN
        RAISE EXCEPTION 'crm: ops_release_guard (a purged release is a sealed receipt)' USING ERRCODE = 'CRM45';
    END IF;
    IF NEW.payload_version < OLD.payload_version THEN
        RAISE EXCEPTION 'crm: ops_release_guard (payload_version only moves up)' USING ERRCODE = 'CRM45';
    END IF;
    IF NEW.purged_at IS NOT NULL AND crm.hold_row_of(OLD.tenant_id, OLD.trip_id, NULL) THEN
        RAISE EXCEPTION 'crm: legal_hold (purge of a held ops_release refused)' USING ERRCODE = 'CRM10';
    END IF;
    IF v_actor LIKE 'ops:%' THEN
        IF (pg_catalog.to_jsonb(NEW) - v_view_cols) IS DISTINCT FROM (pg_catalog.to_jsonb(OLD) - v_view_cols)
           OR NEW.view_count <> OLD.view_count + 1 THEN
            RAISE EXCEPTION 'crm: ops_release_guard (AA ops only record a view)' USING ERRCODE = 'CRM45';
        END IF;
        RETURN NEW;
    END IF;
    IF v_actor LIKE 'member:%' THEN
        IF OLD.withdrawn_at IS NOT NULL OR NEW.withdrawn_at IS NULL
           OR NEW.withdraw_reason NOT IN ('trip_cancelled', 'agency_withdrawn')
           OR (pg_catalog.to_jsonb(NEW) - v_withdraw_cols) IS DISTINCT FROM (pg_catalog.to_jsonb(OLD) - v_withdraw_cols)
        THEN
            RAISE EXCEPTION 'crm: ops_release_guard (a member only withdraws a live release)' USING ERRCODE = 'CRM45';
        END IF;
        RETURN NEW;
    END IF;
    IF v_actor LIKE 'job:%' THEN
        IF OLD.withdrawn_at IS NOT NULL AND NEW.withdrawn_at IS NULL AND OLD.withdraw_reason <> 'aa_lines_cancelled' THEN
            RAISE EXCEPTION 'crm: ops_release_guard (a cancelled trip or an agency withdrawal is not lifted by a job)'
                USING ERRCODE = 'CRM45';
        END IF;
        RETURN NEW;
    END IF;
    RAISE EXCEPTION 'crm: ops_release_guard (actor % may not change a release)', v_actor USING ERRCODE = 'CRM45';
END;
$$;
COMMENT ON FUNCTION crm.guard_ops_release() IS 'AA-956 (crm-034, SQLSTATE CRM45), AA-1085 (crm-058: the purge hold check reads the holds of the release''s own agency, OLD.tenant_id): who may write crm.ops_release. INSERT: a job actor only (Fix B2: created when an AA line is confirmed, by crm_ops_release_sync). UPDATE: trip, reason and release time fixed; a purged row sealed; payload_version up only; ops:<sub> only records a view (view_count + 1, last_viewed_at); member:<id> only withdraws (C12; the job then purges); job:<kind> refreshes, alerts, withdraws and purges, and lifts only an aa_lines_cancelled withdrawal; a purge of a held trip CRM10. DELETE: refused (the row leaves with its trip by cascade, depth > 1). crm_owner unguarded (migrations, tests). Invoker rights.';

-- ── 2e. crm.guard_supplier_manifest_export (crm-034): the release and the holds of OLD.tenant_id ─
CREATE OR REPLACE FUNCTION crm.guard_supplier_manifest_export() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_actor text := COALESCE(NULLIF(current_setting('app.actor', true), ''), '');
    v_trip uuid;
BEGIN
    IF pg_catalog.pg_trigger_depth() > 1 OR current_user = 'crm_owner' THEN
        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    END IF;
    IF TG_OP = 'INSERT' THEN
        IF v_actor NOT LIKE 'ops:%' THEN
            RAISE EXCEPTION 'crm: ops_release_guard (a supplier manifest is exported by AA ops only, actor %)', v_actor
                USING ERRCODE = 'CRM45';
        END IF;
        RETURN NEW;
    END IF;
    IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'crm: ops_release_guard (a manifest export record never changes)' USING ERRCODE = 'CRM45';
    END IF;
    IF v_actor NOT LIKE 'job:%' THEN
        RAISE EXCEPTION 'crm: ops_release_guard (manifest records leave with the release purge only)'
            USING ERRCODE = 'CRM45';
    END IF;
    SELECT r.trip_id INTO v_trip
      FROM crm.ops_release r WHERE r.tenant_id = OLD.tenant_id AND r.ops_release_id = OLD.ops_release_id;
    IF crm.hold_row_of(OLD.tenant_id, v_trip, NULL) THEN
        RAISE EXCEPTION 'crm: legal_hold (delete of a held supplier_manifest_export row refused)' USING ERRCODE = 'CRM10';
    END IF;
    RETURN OLD;
END;
$$;
COMMENT ON FUNCTION crm.guard_supplier_manifest_export() IS 'AA-956 (crm-034, SQLSTATE CRM45), AA-1085 (crm-058: the release and the holds of the record''s own agency, OLD.tenant_id): a supplier manifest export record is inserted by AA ops (ops:<sub>) only, never updated, and deleted only by a job (the release purge) unless its trip is held (CRM10). A cascade from its release (depth > 1) and crm_owner pass. Invoker rights.';

-- ── 2f. crm.guard_held_travel_doc (crm-054): every depth, the holds of OLD.tenant_id ─────────────
CREATE OR REPLACE FUNCTION crm.guard_held_travel_doc() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_old jsonb;
    v_new jsonb;
    v_change text;
BEGIN
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
       AND crm.hold_row_of(OLD.tenant_id, (v_old ->> 'trip_id')::uuid, (v_old ->> 'traveler_id')::uuid) THEN
        RAISE EXCEPTION 'crm: legal_hold (% of a held % row refused)', v_change, TG_TABLE_NAME USING ERRCODE = 'CRM10';
    END IF;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;
COMMENT ON FUNCTION crm.guard_held_travel_doc() IS 'AA-1070 (crm-054, hold rule 4h for crm.booking_line_voucher, crm.room_assignment, crm.visa_application), AA-1085 (crm-058): CRM10 when a statement or a cascade deletes, trashes or moves a row of a held trip or traveller of its own agency (crm.hold_row_of with OLD.tenant_id and the OLD trip_id / traveler_id, NULL when the table has none: the same answer inside a foreign-key cascade, which runs without row security, as under RLS). Invoker rights.';

-- ── 3. crm.partner_commission: the hold guard crm-056 left off ───────────────────────────────────
CREATE OR REPLACE TRIGGER partner_commission_hold_guard
    BEFORE DELETE OR UPDATE ON crm.partner_commission
    FOR EACH ROW EXECUTE FUNCTION crm.guard_held_change('trip_id');

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-058', now(), 'AA-1085: the legal-hold guards read the holds of the row''s own agency (crm.hold_trip_of, hold_traveler_of, hold_row_of with OLD.tenant_id), also inside a foreign-key cascade; the flight and travel document guards check cascades too; crm.partner_commission gets the hold guard')
ON CONFLICT (version) DO NOTHING;

COMMIT;
