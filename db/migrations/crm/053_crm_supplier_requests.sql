-- Migration crm-053: AA-1069 (S275 study of a tour and travel app, root docs/research/2026-11-10-odoo-tour-travel-
-- plugin-comparison.md, item crm-24; behaviour only, no plugin code) — supplier booking requests grouped per supplier:
-- an agency line can be "requested" from its supplier (one e-mail per supplier from the agency's own mailbox, threaded
-- on the trip), and the supplier's confirmation number then confirms it through crm.booking_line_confirm.
--
-- Owner: AA-Partner (api/migrations/053_crm_supplier_requests.sql). AA-CIS-Infra db/migrations/crm/ holds the byte
-- copy DB Migrate applies (Migration Copy Guard). Key crm-053: crm-052 (the service catalogue, expand) comes first; if
-- main moves, renumber: file name, this header, Guard 0 and the registration below, app/db.py
-- REQUIRED_SCHEMA_VERSIONS and the tests that name it (git grep '053_' and 'crm-053').
--
-- What:
--   1. crm.booking_line: status + 'requested' (planning -> requested -> confirmed | planning | cancelled; the
--      crm.status_transition rows), requested_at (when the request went to the supplier; set while requested, kept
--      after the confirm as history, cleared when the line goes back to planning), request_ref (the crm.message id of
--      the request e-mail, [A-Za-z0-9:_.-]{1,80}). Agency lines only (an AA line follows Booking): CHECK
--      booking_line_request_chk.
--   2. crm.booking_line_confirm: the crm-014 text, but a requested line is confirmed too (the supplier answered with
--      its number). Nothing else changes (level check, FX freeze, strict duplicate key, return shape).
--   3. crm.conversation.agency_supplier_id: an e-mail conversation of a trip with one own supplier (the supplier
--      request thread). Such a conversation has a trip, no client and channel email (CHECK
--      conversation_supplier_chk); one per (trip, supplier) while live (partial unique index). No foreign key: the
--      supplier row is trashed and purged on its own schedule; the trip erase deletes the conversation with the trip,
--      and the sender treats a supplier without an e-mail as "no supplier address". The supplier's address is read
--      from crm.agency_supplier.contact_email_enc at send time; it is never copied into the conversation.
--
-- Behaviour on apply: none. No line is requested and no conversation names a supplier until the AA-Partner code PR
-- deploys; the replaced confirm function accepts exactly what it accepted before plus requested lines.
--
-- Class: contract (ALTER of crm.booking_line and crm.conversation with new CHECKs, a widened status CHECK, rows in
-- crm.status_transition, a replaced function). MIG-4: this migration-only PR, then the code PR once it is applied on
-- Dev. DM-7.1: no new table (the new columns follow their rows' retention). No crm.erase_subject change (the columns go
-- with their rows).
--
-- Rollback (a NEW forward migration, after the code is reverted): UPDATE crm.booking_line SET status = 'planning'
-- WHERE status = 'requested' (as crm_owner); put back the crm-014 status CHECK and confirm function; DELETE FROM
-- crm.status_transition WHERE table_name = 'booking_line' AND 'requested' IN (from_status, to_status); ALTER TABLE
-- crm.booking_line DROP COLUMN requested_at, DROP COLUMN request_ref; ALTER TABLE crm.conversation DROP COLUMN
-- agency_supplier_id.
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL. Re-runnable (IF NOT EXISTS, DROP …
-- IF EXISTS before each ADD, CREATE OR REPLACE, ON CONFLICT DO NOTHING).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '5min';

-- ── Guard 0: runs as the owner, after crm-052 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-053: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-052') THEN
        RAISE EXCEPTION 'crm-053: crm-052 (AA-1069 service catalogue) lands first';
    END IF;
    IF to_regclass('crm.booking_line') IS NULL OR to_regclass('crm.conversation') IS NULL
       OR to_regprocedure('crm.booking_line_confirm_check(uuid)') IS NULL
       OR to_regprocedure('crm.booking_line_money_write(uuid, text, numeric, text, text, timestamptz)') IS NULL
       OR to_regprocedure('crm.enforce_status_transition()') IS NULL THEN
        RAISE EXCEPTION 'crm-053: the ledger (crm-014) or the mail tables (crm-015) are missing';
    END IF;
END $$;

-- ── 1. crm.booking_line: status requested, requested_at, request_ref ─────────────────────────────
ALTER TABLE crm.booking_line ADD COLUMN IF NOT EXISTS requested_at TIMESTAMPTZ;
ALTER TABLE crm.booking_line ADD COLUMN IF NOT EXISTS request_ref TEXT;
ALTER TABLE crm.booking_line DROP CONSTRAINT IF EXISTS booking_line_status_chk;
ALTER TABLE crm.booking_line ADD CONSTRAINT booking_line_status_chk
    CHECK (status IN ('planning', 'requested', 'confirmed', 'cancelled'));
ALTER TABLE crm.booking_line DROP CONSTRAINT IF EXISTS booking_line_request_chk;
ALTER TABLE crm.booking_line ADD CONSTRAINT booking_line_request_chk CHECK (
    (supplier_kind = 'agency' OR (status <> 'requested' AND requested_at IS NULL AND request_ref IS NULL))
    AND (status <> 'requested' OR requested_at IS NOT NULL)
    AND (request_ref IS NULL OR request_ref ~ '^[A-Za-z0-9:_.-]{1,80}$')
);
COMMENT ON COLUMN crm.booking_line.requested_at IS 'AA-1069 (crm-053, item crm-24): when the agency asked the supplier for this agency line (status requested); kept after the confirm, cleared when the line goes back to planning. NULL on AA lines';
COMMENT ON COLUMN crm.booking_line.request_ref IS 'AA-1069 (crm-053): the crm.message id of the supplier request e-mail that asked for this line (one e-mail per supplier per request run). Not personal data';
INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('booking_line', 'planning', 'requested'),
    ('booking_line', 'requested', 'confirmed'),
    ('booking_line', 'requested', 'planning'),
    ('booking_line', 'requested', 'cancelled')
ON CONFLICT DO NOTHING;

-- ── 2. crm.booking_line_confirm: a requested line is confirmed too ───────────────────────────────
CREATE OR REPLACE FUNCTION crm.booking_line_confirm(p_line uuid) RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_role text := COALESCE(current_setting('app.member_role', true), '');
    v_line record;
    v_missing text[];
    v_blocking text[];
    v_at timestamptz := now();
    v_frozen integer := 0;
    v_stale integer := 0;
    m record;
    v_id uuid;
BEGIN
    SELECT l.status, l.supplier_kind, l.deleted_at INTO v_line
      FROM crm.booking_line l WHERE l.booking_line_id = p_line FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'crm: subject_not_found (booking_line %)', p_line USING ERRCODE = 'CRM13';
    END IF;
    IF v_line.supplier_kind = 'aa' THEN
        RAISE EXCEPTION 'crm: aa_line_read_only (Adventure Asia lines come from the Booking feed)'
            USING ERRCODE = 'CRM24';
    END IF;
    IF v_line.status NOT IN ('planning', 'requested') OR v_line.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'crm: line_not_editable (only a planning or requested line is confirmed)' USING ERRCODE = 'CRM26';
    END IF;
    v_missing := crm.booking_line_confirm_check(p_line);
    -- R18: the assistant is never blocked by a missing commission (the API opens the owner task instead).
    SELECT COALESCE(array_agg(x), '{}') INTO v_blocking
      FROM unnest(v_missing) x WHERE NOT (x = 'commission' AND v_role = 'assistant');
    IF cardinality(v_blocking) > 0 THEN
        RAISE EXCEPTION 'crm: line_incomplete:%', array_to_string(v_blocking, ',') USING ERRCODE = 'CRM23';
    END IF;
    -- Freeze every unfrozen head at the confirmation date (fx_basis booking_date).
    FOR m IN SELECT h.kind, h.amount, h.currency FROM crm.booking_line_money h
              WHERE h.booking_line_id = p_line AND h.fx_rate IS NULL
                AND NOT EXISTS (SELECT 1 FROM crm.booking_line_money n WHERE n.supersedes_id = h.booking_line_money_id)
              ORDER BY h.kind LOOP
        v_id := crm.booking_line_money_write(p_line, m.kind, m.amount, m.currency, 'confirmed', v_at);
        v_frozen := v_frozen + 1;
        v_stale := GREATEST(v_stale, (SELECT x.stale_days FROM crm.booking_line_money x
                                       WHERE x.booking_line_money_id = v_id));
    END LOOP;
    UPDATE crm.booking_line SET status = 'confirmed', confirmed_at = v_at WHERE booking_line_id = p_line;
    RETURN jsonb_build_object('frozen', v_frozen, 'stale_days', v_stale, 'pending', to_jsonb(v_missing));
END;
$$;
REVOKE ALL ON FUNCTION crm.booking_line_confirm(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.booking_line_confirm(uuid) TO crm_app;
COMMENT ON FUNCTION crm.booking_line_confirm(uuid) IS 'AA-944 (crm-014, R17, R18), AA-1069 (crm-053: a requested line too): confirms a planning or requested agency line of the agency of app.tenant_id: the level''s missing codes refuse it (CRM23 line_incomplete:<codes>), except a missing commission for the assistant (returned in pending: the API opens the owner task); every unfrozen money head is frozen at the confirmation date (CRM25 fx_rate_missing); then status confirmed (the strict duplicate key may raise unique_violation booking_line_conf_uq). Returns {frozen, stale_days, pending}, codes and counts only. CRM13 unknown line, CRM24 aa line, CRM26 not planning / requested. SECURITY DEFINER; EXECUTE crm_app.';

-- ── 3. crm.conversation.agency_supplier_id: the supplier request thread of a trip ────────────────
ALTER TABLE crm.conversation ADD COLUMN IF NOT EXISTS agency_supplier_id UUID;
ALTER TABLE crm.conversation DROP CONSTRAINT IF EXISTS conversation_supplier_chk;
ALTER TABLE crm.conversation ADD CONSTRAINT conversation_supplier_chk CHECK (
    agency_supplier_id IS NULL OR (trip_id IS NOT NULL AND traveler_id IS NULL AND channel = 'email')
);
CREATE UNIQUE INDEX IF NOT EXISTS conversation_supplier_uq ON crm.conversation (tenant_id, trip_id, agency_supplier_id)
    WHERE agency_supplier_id IS NOT NULL AND deleted_at IS NULL;
COMMENT ON COLUMN crm.conversation.agency_supplier_id IS 'AA-1069 (crm-053, item crm-24): the own supplier (crm.agency_supplier) this e-mail conversation of the trip is with: the supplier request thread (no client, channel email; one live per trip and supplier). No foreign key (the supplier is trashed and purged on its own schedule; the conversation leaves with the trip). NULL = a client conversation';

-- ── Post-checks ──────────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM crm.status_transition
                    WHERE table_name = 'booking_line' AND from_status = 'requested' AND to_status = 'confirmed') THEN
        RAISE EXCEPTION 'crm-053: the requested -> confirmed transition is missing';
    END IF;
    IF NOT has_function_privilege('crm_app', 'crm.booking_line_confirm(uuid)', 'EXECUTE')
       OR NOT has_column_privilege('crm_app', 'crm.booking_line', 'requested_at', 'UPDATE')
       OR NOT has_column_privilege('crm_app', 'crm.conversation', 'agency_supplier_id', 'INSERT') THEN
        RAISE EXCEPTION 'crm-053: crm_app is missing a privilege on the changed objects';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-053', now(), 'AA-1069: supplier booking requests: crm.booking_line status requested + requested_at + request_ref, crm.booking_line_confirm accepts a requested line, crm.conversation.agency_supplier_id (the trip''s supplier request thread)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
