-- Migration crm-065: AA-1086 follow-up (S279 rehearsal REH-10-portal) — an agency member shows or hides a confirmed
-- Adventure Asia line to the trip's travellers: crm.guard_booking_line section a lets crm_app change that one column.
--
-- Owner: AA-Partner (api/migrations/065_crm_aa_line_traveller_visibility.sql). AA-CIS-Infra db/migrations/crm/ holds
-- the byte copy Migration Apply runs (Migration Copy Guard). Key crm-065 = crm main max + 1 (crm-064 is the highest);
-- if main moves, renumber: file name, this header, Guard 0 and the registration below, app/db.py
-- REQUIRED_SCHEMA_VERSIONS and the tests that name it (git grep '065_' and 'crm-065').
--
-- Why: the traveller portal lists only the trip's lines shown to travellers (crm.booking_line.visible_to_travelers,
-- AA-953 R22) and a traveller voucher is released only for such a line (AA-1070 crm-20). Tech lead decision
-- (13/11/2026): a confirmed AA line is shown to travellers by default; the AA-Partner code sets the flag when the
-- Booking sync confirms an AA line (app/booking/sync.py, on the move to confirmed only). The agency must still be able
-- to hide one (and show it again): crm-014 guard 3a (CRM24 aa_line_read_only) refused every member write to an AA
-- line, that column included.
--
-- What: CREATE OR REPLACE crm.guard_booking_line() (same trigger, same owner, same grants). Section a now lets a
-- crm_app session that is not a job: / platform: actor UPDATE an AA line when the line is confirmed and live before and
-- after, and the row differs only in visible_to_travelers (updated_at aside: crm.set_updated_at writes it); any other
-- member write to an AA line is still CRM24. Sections b-f are crm-014's, unchanged (a cancelled line is still forced
-- hidden, R22). The API (app/ledger/lines.py update_line) accepts only visible_to_travelers on an AA line, from
-- the roles that edit the trip, and audits the change. No backfill: no line changes on apply (an AA line confirmed
-- before the code stays as it is until the agency shows it, or the tech lead runs a reviewed DB Migrate run-script
-- with a DRY RUN first).
--
-- Class: contract (replaces an existing trigger function; no '-- migrate:' directive). MIG-4: this migration-only PR,
-- then the code PR (readiness crm-065). No new table (no DM-7.1 row), no crm.erase_subject change, no data written.
--
-- Rollback: re-run crm-014 section 3 (the function without the visibility exception); a line a member showed or hid
-- keeps its flag.
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL. Re-runnable (CREATE OR REPLACE,
-- ON CONFLICT DO NOTHING).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Guard 0: runs as the owner, after crm-064 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-065: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-064') THEN
        RAISE EXCEPTION 'crm-065: crm-064 (AA-1096 settings registry) lands first';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.schema_versions
                WHERE version = 'crm-065' AND description NOT LIKE 'AA-1086: a member shows or hides%') THEN
        RAISE EXCEPTION 'crm-065: the key crm-065 is already held by another migration (not AA-1086): renumber one';
    END IF;
END $$;

-- ── 1. The booking line guard, section a narrowed (crm-014 section 3 otherwise) ──────────────────
CREATE OR REPLACE FUNCTION crm.guard_booking_line() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_app boolean := current_user::text = 'crm_app';
    v_feed boolean := COALESCE(current_setting('app.actor', true), '') ~ '^(job|platform):';
    v_kind text;
    v_unique boolean;
    v_level text;
    v_rekey boolean;
    v_visibility boolean := false;
BEGIN
    -- a. AA lines are the Booking feed's (CRM-19): read-only for members, except (crm-065, AA-1086) the one member
    -- choice on a confirmed AA line: shown to or hidden from the trip's travellers. Only that column (and updated_at,
    -- which crm.set_updated_at writes) may differ between OLD and NEW; the line stays confirmed and an AA line.
    IF v_app AND NOT v_feed AND TG_OP = 'UPDATE' THEN
        v_visibility := COALESCE(OLD.supplier_kind = 'aa' AND NEW.supplier_kind = 'aa' AND OLD.status = 'confirmed'
                                 AND NEW.status = 'confirmed' AND OLD.deleted_at IS NULL AND NEW.deleted_at IS NULL
                                 AND to_jsonb(NEW) - ARRAY['visible_to_travelers', 'updated_at']
                                     = to_jsonb(OLD) - ARRAY['visible_to_travelers', 'updated_at'], false);
    END IF;
    IF v_app AND NOT v_feed AND NOT v_visibility
       AND ((TG_OP <> 'INSERT' AND OLD.supplier_kind = 'aa') OR (TG_OP <> 'DELETE' AND NEW.supplier_kind = 'aa')) THEN
        RAISE EXCEPTION 'crm: aa_line_read_only (Adventure Asia lines come from the Booking feed)'
            USING ERRCODE = 'CRM24';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    -- b. The supplier's kind matches.
    SELECT s.kind, s.confirmation_unique INTO v_kind, v_unique
      FROM crm.agency_supplier s
     WHERE s.tenant_id = NEW.tenant_id AND s.agency_supplier_id = NEW.agency_supplier_id;
    IF v_kind IS NOT NULL AND (v_kind = 'aa') <> (NEW.supplier_kind = 'aa') THEN
        RAISE EXCEPTION 'crm: supplier_kind_mismatch (an aa line names the Adventure Asia supplier, an agency line an own one)'
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.status = 'confirmed' AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM 'confirmed') THEN
        -- c. An agency line is confirmed only through crm.booking_line_confirm (runs as crm_owner, freezes the money).
        IF v_app AND NEW.supplier_kind = 'agency' THEN
            RAISE EXCEPTION 'crm: line_not_editable (confirm an agency line through crm.booking_line_confirm)'
                USING ERRCODE = 'CRM26';
        END IF;
    END IF;
    -- d. confirmed_at: NULL until the line is confirmed, then set once.
    IF TG_OP = 'UPDATE' AND OLD.confirmed_at IS NOT NULL THEN
        NEW.confirmed_at := OLD.confirmed_at;
    ELSIF NEW.status = 'confirmed' THEN
        NEW.confirmed_at := COALESCE(NEW.confirmed_at, now());
    ELSE
        NEW.confirmed_at := NULL;
    END IF;
    IF NEW.status = 'cancelled' THEN
        NEW.visible_to_travelers := false;  -- R22
    END IF;
    -- e. Only a planning line goes to the trash (a confirmed one is cancelled first).
    IF TG_OP = 'UPDATE' AND OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL AND OLD.status <> 'planning' THEN
        RAISE EXCEPTION 'crm: line_not_editable (only a planning line goes to the trash; cancel a % line)', OLD.status
            USING ERRCODE = 'CRM26';
    END IF;
    SELECT COALESCE((SELECT ts.booking_validation_level FROM crm.tenant_settings ts WHERE ts.tenant_id = NEW.tenant_id),
                    'basic')
      INTO v_level;
    -- d'. A confirmed agency line keeps the number its level asked for at confirm (R18 is not undone by an edit).
    IF TG_OP = 'UPDATE' AND OLD.status = 'confirmed' AND NEW.status = 'confirmed' AND NEW.supplier_kind = 'agency'
       AND OLD.confirmation_no IS NOT NULL AND NEW.confirmation_no IS NULL AND v_level <> 'off' THEN
        RAISE EXCEPTION 'crm: line_incomplete:confirmation_no (a confirmed line keeps its confirmation number)'
            USING ERRCODE = 'CRM23';
    END IF;
    -- f. The strict duplicate key (card R). Computed (and the un-keyed lines scanned) only when the line becomes
    -- confirmed or its number or supplier changes: any other edit keeps the stored key, so lines confirmed with one
    -- number before the agency went strict stay editable (title, dates, visibility).
    v_rekey := TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM NEW.status
               OR OLD.confirmation_no IS DISTINCT FROM NEW.confirmation_no
               OR OLD.agency_supplier_id IS DISTINCT FROM NEW.agency_supplier_id
               OR OLD.supplier_kind IS DISTINCT FROM NEW.supplier_kind;
    IF NEW.supplier_kind = 'agency' AND NEW.status = 'confirmed' AND NEW.confirmation_no IS NOT NULL
       AND (v_level = 'strict' OR COALESCE(v_unique, false)) AND NOT v_rekey THEN
        NEW.conf_unique_key := OLD.conf_unique_key;
    ELSIF NEW.supplier_kind = 'agency' AND NEW.status = 'confirmed' AND NEW.confirmation_no IS NOT NULL
       AND (v_level = 'strict' OR COALESCE(v_unique, false)) THEN
        NEW.conf_unique_key := upper(regexp_replace(NEW.confirmation_no, '[^[:alnum:]]+', '', 'g'));
        -- A line confirmed before the agency went strict (or the supplier became confirmation_unique) has no key; it
        -- still counts. It is committed, so this read sees it; two new confirms racing each other meet in the UNIQUE.
        IF EXISTS (SELECT 1 FROM crm.booking_line o
                    WHERE o.tenant_id = NEW.tenant_id AND o.agency_supplier_id = NEW.agency_supplier_id
                      AND o.booking_line_id <> NEW.booking_line_id AND o.status = 'confirmed'
                      AND o.supplier_kind = 'agency' AND o.conf_unique_key IS NULL AND o.confirmation_no IS NOT NULL
                      AND upper(regexp_replace(o.confirmation_no, '[^[:alnum:]]+', '', 'g')) = NEW.conf_unique_key) THEN
            RAISE EXCEPTION 'crm: duplicate_confirmation_no (a confirmed line of this supplier has this number)'
                USING ERRCODE = 'unique_violation', CONSTRAINT = 'booking_line_conf_uq';
        END IF;
    ELSE
        NEW.conf_unique_key := NULL;
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION crm.guard_booking_line() FROM PUBLIC;
COMMENT ON FUNCTION crm.guard_booking_line() IS 'AA-944 (crm-014, file header item 3a-3f) + AA-1086 (crm-065): aa lines only from a job: / platform: actor (CRM24 aa_line_read_only), except a member UPDATE of a confirmed live aa line that changes only visible_to_travelers; the supplier''s kind matches; an agency line is confirmed only through crm.booking_line_confirm (CRM26); confirmed_at NULL until confirmed, then set once; a confirmed agency line keeps its confirmation_no unless the level is off (CRM23); a cancelled line is hidden from travellers; only a planning line is trashed (CRM26); conf_unique_key for the strict duplicate check, recomputed only when the line becomes confirmed or its number or supplier changes.';

-- ── 2. Self-check ────────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF position('v_visibility' IN (SELECT prosrc FROM pg_catalog.pg_proc
                                    WHERE oid = 'crm.guard_booking_line()'::regprocedure)) = 0 THEN
        RAISE EXCEPTION 'crm-065: crm.guard_booking_line has no visibility exception';
    END IF;
    IF pg_catalog.has_function_privilege('public', 'crm.guard_booking_line()', 'EXECUTE') THEN
        RAISE EXCEPTION 'crm-065: crm.guard_booking_line() is executable by PUBLIC (SEC-4)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger
                    WHERE tgname = 'booking_line_guard' AND tgrelid = 'crm.booking_line'::regclass
                      AND tgfoid = 'crm.guard_booking_line()'::regprocedure) THEN
        RAISE EXCEPTION 'crm-065: trigger booking_line_guard does not run crm.guard_booking_line()';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-065', now(), 'AA-1086: a member shows or hides a confirmed AA line to travellers (crm.guard_booking_line section a)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
