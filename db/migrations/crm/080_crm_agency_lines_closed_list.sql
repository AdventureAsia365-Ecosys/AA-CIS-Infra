-- Migration crm-080: AA-1144 (business rule of 19/11/2026, S285 decisions B5, B6, B9, B10, B11, T19) — every product
-- (hotel, transfer and vehicle, guide, ticket and entrance, meal, activity, DMC) is Adventure Asia's and its
-- suppliers'; an agency only sells it. The agency's own lines are a closed list: flight, visa, travel insurance and
-- its own service fee, typed by hand, never sent to AA (root ADR 0019 b6 as amended by AA-1144).
--
-- Owner: AA-Partner (api/migrations/080_crm_agency_lines_closed_list.sql). AA-CIS-Infra db/migrations/crm/ holds the
-- byte copy Migration Apply runs (Migration Copy Guard). Key crm-080, right after crm-079; if the numbers move,
-- renumber: file name, this header, Guard 0 and the registration below, app/db.py REQUIRED_SCHEMA_VERSIONS (code PR)
-- and the tests that name it (git grep '080_' and 'crm-080').
--
-- What:
--   1. crm.option.category and crm.booking_line.category (text, NULL allowed): what an agency item is, one of
--      flight | visa | insurance | fee. CHECK option_category_chk / booking_line_category_chk: NULL, or an agency
--      item (source 'agency' / supplier_kind 'agency') of the closed list. NULL stays legal for the agency items made
--      before this file (they stay readable and editable; the API asks every NEW agency item for its category) and is
--      the value of every AA item.
--   2. crm.aa_extra_night_request (B11): an agency asks Adventure Asia for hotel nights before or after the tour (the
--      place, the check-in day, nights, rooms, adults, children), instead of selling a hotel of its own. open ->
--      closed (quoted | not_needed). AA ground operations read the open ones on the staff console (crm-ops, no
--      personal data: no traveller name, no free text beyond the place). Base template, cascades from the trip, hold
--      guard crm.guard_held_change('trip_id'); crm_app SELECT / INSERT / UPDATE (no DELETE: the trash).
--   3. Data (T19: count first, never DELETE), one agency at a time (FORCE row security binds the owner; the agency
--      list is crm.audit_export_tenant, RLS not forced):
--        a. RAISE NOTICE the counts: own suppliers per blocked category (accommodation, transport, activity, guide,
--           restaurant, dmc), how many of them anything references (options, booking lines of any state, supplier
--           bills, departure costs, AA invoice rows, catalogue services, supplier request threads), catalogue
--           services of category transfer, and the agencies under an active legal hold that have such rows (the
--           hold guard refuses the change: the file stops and names the count).
--        b. own suppliers of a blocked category become category 'other' (every key stays);
--        c. the re-typed ones nothing references go to the trash (deleted_at, deleted_by 'migration:crm-080',
--           purge_after = now + the agency's trash_days, else the platform default of crm.agency_defaults.trash_days):
--           restorable from Trash until the daily crm_lifecycle run purges them; the referenced ones stay live as
--           'other' so old proposals, lines, bills and costs read as before;
--        d. live catalogue services of category transfer go to the trash the same way (the catalogue lists hide them;
--           the options already copied from them are snapshots and stay).
--   4. The CHECKs narrow:
--        agency_supplier_category_chk  the Adventure Asia row is 'dmc'; an own supplier is flight | insurance | visa |
--                                      other (other = the agency's own fee, a consolidator, ...)
--        agency_service_category_chk   flight | insurance | visa | fee (a trashed transfer row keeps its value)
--   5. Register crm-080.
--
-- Not here (code PR, readiness crm-080): the API refuses an agency item on a lodging / activity / transport / meal /
-- guide block, an agency item or line outside the closed list, a supplier or a service of a blocked category (422 with
-- a plain message), and serves the B11 request; the web hides the choices. The extras flow (accept -> agency lines,
-- attachments, invoice groups) is the next slice.
--
-- Class: contract (root ADR 0017 d3: ALTER of existing tables, new and narrowed CHECKs, an UPDATE of existing rows),
-- so no migrate directive. MIG-4: this migration-only PR, applied on Dev by Infra Migration Apply once every job table
-- is idle (root ADR 0017a), then the code PR. New table crm.aa_extra_night_request: its DM-7.1 retention row is in the
-- root PR merged before the Infra copy (the trip row: goes with its trip). No personal data in the new table, no
-- crm.erase_subject change.
--
-- Rollback (a NEW forward migration, MIG-14): widen the two CHECKs back to the crm-014 / crm-052 lists; restore trashed
-- rows from Trash (deleted_by 'migration:crm-080') before their purge; the columns and the table stay (NULL / unused).
--
-- Runs as crm_owner (Migration Apply live-owner switch), one BEGIN … COMMIT block, no role DDL. Re-runnable (ADD COLUMN
-- IF NOT EXISTS, CREATE TABLE IF NOT EXISTS, constraints replaced by name, the data steps touch only rows still to
-- change, the guard re-checks the result).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '120s';

-- ── Guard 0: runs as the owner, after crm-079 ─────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-080: must run as crm_owner (Migration Apply live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-079') THEN
        RAISE EXCEPTION 'crm-080: crm-079 lands first';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.schema_versions
                WHERE version = 'crm-080' AND description NOT LIKE 'AA-1144 agency lines:%') THEN
        RAISE EXCEPTION 'crm-080: the key crm-080 is already held by another migration (not AA-1144): renumber one';
    END IF;
    IF to_regclass('crm.agency_service') IS NULL OR to_regclass('crm.departure_cost') IS NULL
       OR to_regclass('crm.audit_export_tenant') IS NULL
       OR to_regprocedure('crm.guard_held_change()') IS NULL THEN
        RAISE EXCEPTION 'crm-080: crm.agency_service, crm.departure_cost, crm.audit_export_tenant or the hold guard is missing';
    END IF;
END $$;

-- ── 1. what an agency item is ────────────────────────────────────────────────────────────────────
ALTER TABLE crm.option ADD COLUMN IF NOT EXISTS category text;
ALTER TABLE crm.booking_line ADD COLUMN IF NOT EXISTS category text;
ALTER TABLE crm.option DROP CONSTRAINT IF EXISTS option_category_chk;
ALTER TABLE crm.option ADD CONSTRAINT option_category_chk CHECK (
    category IS NULL OR (source = 'agency' AND category IN ('flight', 'visa', 'insurance', 'fee'))
);
ALTER TABLE crm.booking_line DROP CONSTRAINT IF EXISTS booking_line_category_chk;
ALTER TABLE crm.booking_line ADD CONSTRAINT booking_line_category_chk CHECK (
    category IS NULL OR (supplier_kind = 'agency' AND category IN ('flight', 'visa', 'insurance', 'fee'))
);
COMMENT ON COLUMN crm.option.category IS 'AA-1144 (crm-080): what an agency item is: flight | visa | insurance | fee (root ADR 0019 b6 as amended). NULL on every AA item and on agency items made before crm-080 (read and edited as before); the API asks every new agency item for one.';
COMMENT ON COLUMN crm.booking_line.category IS 'AA-1144 (crm-080): what an agency line is: flight | visa | insurance | fee (root ADR 0019 b6 as amended). NULL on every AA line and on agency lines made before crm-080; the API asks every new agency line for one.';

-- ── 2. B11: the agency asks AA for extra hotel nights ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.aa_extra_night_request (
    request_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id    UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                 REFERENCES crm.tenant (tenant_id),
    trip_id      UUID NOT NULL,
    position     TEXT NOT NULL,
    place        TEXT NOT NULL,
    check_in     DATE NOT NULL,
    nights       SMALLINT NOT NULL,
    rooms        SMALLINT NOT NULL,
    adults       SMALLINT NOT NULL,
    children     SMALLINT NOT NULL DEFAULT 0,
    status       TEXT NOT NULL DEFAULT 'open',
    close_reason TEXT,
    closed_at    TIMESTAMPTZ,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at   TIMESTAMPTZ,
    deleted_by   TEXT,
    purge_after  TIMESTAMPTZ,
    CONSTRAINT aa_extra_night_request_tenant_id_uq UNIQUE (tenant_id, request_id),
    CONSTRAINT aa_extra_night_request_trip_fk FOREIGN KEY (tenant_id, trip_id)
        REFERENCES crm.trip (tenant_id, trip_id) ON DELETE CASCADE,
    CONSTRAINT aa_extra_night_request_values_chk CHECK (
        position IN ('before', 'after')
        AND char_length(btrim(place)) BETWEEN 1 AND 80 AND place !~ '[[:cntrl:]]'
        AND nights BETWEEN 1 AND 60
        AND rooms BETWEEN 1 AND 30
        AND adults BETWEEN 1 AND 60
        AND children BETWEEN 0 AND 60
    ),
    CONSTRAINT aa_extra_night_request_status_chk CHECK (
        status IN ('open', 'closed')
        AND (close_reason IS NULL OR close_reason IN ('quoted', 'not_needed'))
        AND ((status = 'open') = (closed_at IS NULL))
        AND ((status = 'open') = (close_reason IS NULL))
    ),
    CONSTRAINT aa_extra_night_request_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE INDEX IF NOT EXISTS aa_extra_night_request_trip_idx ON crm.aa_extra_night_request (tenant_id, trip_id);
CREATE INDEX IF NOT EXISTS aa_extra_night_request_open_idx ON crm.aa_extra_night_request (tenant_id, check_in)
    WHERE status = 'open' AND deleted_at IS NULL;
ALTER TABLE crm.aa_extra_night_request ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.aa_extra_night_request FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON crm.aa_extra_night_request;
CREATE POLICY tenant_isolation ON crm.aa_extra_night_request
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
REVOKE ALL ON crm.aa_extra_night_request FROM crm_app;
GRANT SELECT, INSERT, UPDATE ON crm.aa_extra_night_request TO crm_app;
CREATE OR REPLACE TRIGGER aa_extra_night_request_set_updated_at
    BEFORE UPDATE ON crm.aa_extra_night_request
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('aa_extra_night_request', 'open', 'closed')
ON CONFLICT DO NOTHING;
CREATE OR REPLACE TRIGGER aa_extra_night_request_status_transition
    BEFORE UPDATE OF status ON crm.aa_extra_night_request
    FOR EACH ROW EXECUTE FUNCTION crm.enforce_status_transition();
CREATE OR REPLACE TRIGGER aa_extra_night_request_hold_guard
    BEFORE DELETE OR UPDATE ON crm.aa_extra_night_request
    FOR EACH ROW EXECUTE FUNCTION crm.guard_held_change('trip_id');
COMMENT ON TABLE crm.aa_extra_night_request IS 'AA-1144 (crm-080, decision B11): an agency asks Adventure Asia for hotel nights before or after the tour of a trip (an agency never sells a hotel of its own). open -> closed (quoted: AA answered and the agent added the AA hotel item; not_needed). AA ground operations list the open requests on the staff console (crm-ops). Place, dates and counts only: no traveller name, no personal data. Cascades from the trip.';
COMMENT ON COLUMN crm.aa_extra_night_request.position IS 'before = nights before the tour starts, after = nights after it ends';
COMMENT ON COLUMN crm.aa_extra_night_request.place IS 'the city or area of the nights (no traveller name; 1 to 80 characters)';

-- ── 3. data: count, re-type, trash (one agency at a time) ────────────────────────────────────────
DO $$
DECLARE
    v_blocked  constant text[] := ARRAY['accommodation', 'transport', 'activity', 'guide', 'restaurant', 'dmc'];
    v_tenant   uuid;
    v_days     int;
    v_default  int;
    v_rows     int;
    v_moved    uuid[];
    v_own_blocked   int := 0;
    v_referenced    int := 0;
    v_transfer_svc  int := 0;
    v_aa_not_dmc    int := 0;
    v_held_agencies int := 0;
    v_retyped       int := 0;
    v_trashed       int := 0;
    v_svc_trashed   int := 0;
BEGIN
    SELECT (d.default_value #>> '{}')::int INTO v_default
      FROM crm.setting_definition d WHERE d.key = 'crm.agency_defaults.trash_days';
    v_default := COALESCE(v_default, 7);

    -- a. count first (read only).
    FOR v_tenant IN SELECT t.tenant_id FROM crm.audit_export_tenant t ORDER BY t.tenant_id LOOP
        PERFORM set_config('app.tenant_id', v_tenant::text, true);
        SELECT count(*) INTO v_rows FROM crm.agency_supplier s
         WHERE s.kind = 'own' AND s.category = ANY (v_blocked);
        v_own_blocked := v_own_blocked + v_rows;
        SELECT v_referenced + count(*) INTO v_referenced FROM crm.agency_supplier s
         WHERE s.kind = 'own' AND s.category = ANY (v_blocked)
           AND (EXISTS (SELECT 1 FROM crm.option o WHERE o.agency_supplier_id = s.agency_supplier_id)
                OR EXISTS (SELECT 1 FROM crm.booking_line l WHERE l.agency_supplier_id = s.agency_supplier_id)
                OR EXISTS (SELECT 1 FROM crm.supplier_bill b WHERE b.agency_supplier_id = s.agency_supplier_id)
                OR EXISTS (SELECT 1 FROM crm.departure_cost c WHERE c.agency_supplier_id = s.agency_supplier_id)
                OR EXISTS (SELECT 1 FROM crm.aa_invoice_cache i WHERE i.agency_supplier_id = s.agency_supplier_id)
                OR EXISTS (SELECT 1 FROM crm.agency_service v WHERE v.agency_supplier_id = s.agency_supplier_id)
                OR EXISTS (SELECT 1 FROM crm.conversation m WHERE m.agency_supplier_id = s.agency_supplier_id));
        SELECT v_transfer_svc + count(*) INTO v_transfer_svc FROM crm.agency_service v
         WHERE v.category = 'transfer' AND v.deleted_at IS NULL;
        SELECT v_aa_not_dmc + count(*) INTO v_aa_not_dmc FROM crm.agency_supplier s
         WHERE s.kind = 'aa' AND s.category <> 'dmc';
        IF v_rows > 0 OR EXISTS (SELECT 1 FROM crm.agency_service v
                                  WHERE v.category = 'transfer' AND v.deleted_at IS NULL) THEN
            IF EXISTS (SELECT 1 FROM crm.legal_hold h WHERE h.tenant_id = v_tenant AND h.status = 'active') THEN
                v_held_agencies := v_held_agencies + 1;
            END IF;
        END IF;
    END LOOP;
    RAISE NOTICE 'crm-080 counts: own suppliers of a blocked category % (referenced %, unreferenced %); live transfer catalogue services %; AA rows not dmc %; agencies under an active legal hold with such rows %',
        v_own_blocked, v_referenced, v_own_blocked - v_referenced, v_transfer_svc, v_aa_not_dmc, v_held_agencies;
    IF v_held_agencies > 0 THEN
        RAISE EXCEPTION 'crm-080: % agencies under an active legal hold have rows to re-type or trash (the hold guard refuses the change): lift or review the hold first', v_held_agencies;
    END IF;
    IF v_aa_not_dmc > 0 THEN
        RAISE EXCEPTION 'crm-080: % Adventure Asia supplier rows are not category dmc (crm.ensure_aa_supplier writes dmc)', v_aa_not_dmc;
    END IF;

    -- b-d. re-type, then trash what nothing references.
    FOR v_tenant IN SELECT t.tenant_id FROM crm.audit_export_tenant t ORDER BY t.tenant_id LOOP
        PERFORM set_config('app.tenant_id', v_tenant::text, true);
        SELECT COALESCE((SELECT ts.trash_days FROM crm.tenant_settings ts WHERE ts.tenant_id = v_tenant), v_default)
          INTO v_days;
        WITH moved AS (
            UPDATE crm.agency_supplier s SET category = 'other'
             WHERE s.kind = 'own' AND s.category = ANY (v_blocked)
            RETURNING s.agency_supplier_id, s.deleted_at
        )
        SELECT array_agg(m.agency_supplier_id) FILTER (WHERE m.deleted_at IS NULL), count(*)
          INTO v_moved, v_rows
          FROM moved m;
        v_retyped := v_retyped + v_rows;
        -- A second statement: one statement never updates the same row twice.
        UPDATE crm.agency_supplier s
           SET deleted_at = now(), deleted_by = 'migration:crm-080', purge_after = now() + make_interval(days => v_days)
         WHERE s.agency_supplier_id = ANY (COALESCE(v_moved, '{}'))
           AND NOT EXISTS (SELECT 1 FROM crm.option o WHERE o.agency_supplier_id = s.agency_supplier_id)
           AND NOT EXISTS (SELECT 1 FROM crm.booking_line l WHERE l.agency_supplier_id = s.agency_supplier_id)
           AND NOT EXISTS (SELECT 1 FROM crm.supplier_bill b WHERE b.agency_supplier_id = s.agency_supplier_id)
           AND NOT EXISTS (SELECT 1 FROM crm.departure_cost c WHERE c.agency_supplier_id = s.agency_supplier_id)
           AND NOT EXISTS (SELECT 1 FROM crm.aa_invoice_cache i WHERE i.agency_supplier_id = s.agency_supplier_id)
           AND NOT EXISTS (SELECT 1 FROM crm.agency_service v WHERE v.agency_supplier_id = s.agency_supplier_id)
           AND NOT EXISTS (SELECT 1 FROM crm.conversation c WHERE c.agency_supplier_id = s.agency_supplier_id);
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        v_trashed := v_trashed + v_rows;
        UPDATE crm.agency_service v
           SET deleted_at = now(), deleted_by = 'migration:crm-080', purge_after = now() + make_interval(days => v_days)
         WHERE v.category = 'transfer' AND v.deleted_at IS NULL;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        v_svc_trashed := v_svc_trashed + v_rows;
    END LOOP;
    PERFORM set_config('app.tenant_id', '', true);
    RAISE NOTICE 'crm-080 done: own suppliers re-typed to other %, of which moved to the trash % (kept live, referenced: %); transfer catalogue services moved to the trash %',
        v_retyped, v_trashed, v_retyped - v_trashed, v_svc_trashed;
END $$;

-- ── 4. the CHECKs narrow (validated over every row, whatever the row security) ───────────────────
ALTER TABLE crm.agency_supplier DROP CONSTRAINT IF EXISTS agency_supplier_category_chk;
ALTER TABLE crm.agency_supplier ADD CONSTRAINT agency_supplier_category_chk CHECK (
    (kind = 'aa' AND category = 'dmc') OR (kind = 'own' AND category IN ('flight', 'insurance', 'visa', 'other'))
);
ALTER TABLE crm.agency_service DROP CONSTRAINT IF EXISTS agency_service_category_chk;
ALTER TABLE crm.agency_service ADD CONSTRAINT agency_service_category_chk CHECK (
    category IN ('flight', 'insurance', 'visa', 'fee') OR (category = 'transfer' AND deleted_at IS NOT NULL)
);
COMMENT ON COLUMN crm.agency_supplier.category IS 'AA-1144 (crm-080): the Adventure Asia row is dmc; an own supplier is flight | insurance | visa | other (root ADR 0019 b6 as amended: hotels, transfers, guides, tickets, meals, activities and DMCs are AA''s). crm-080 re-typed the older own rows of those categories to other.';
COMMENT ON COLUMN crm.agency_service.category IS 'AA-1144 (crm-080): flight | insurance | visa | fee; a transfer row crm-080 moved to the trash keeps its value.';

-- ── guard: the result ────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'crm.option'::regclass AND conname = 'option_category_chk')
       OR NOT EXISTS (SELECT 1 FROM pg_constraint
                       WHERE conrelid = 'crm.booking_line'::regclass AND conname = 'booking_line_category_chk')
       OR NOT has_table_privilege('crm_app', 'crm.aa_extra_night_request', 'INSERT')
       OR has_table_privilege('crm_app', 'crm.aa_extra_night_request', 'DELETE') THEN
        RAISE EXCEPTION 'crm-080: a category CHECK or the crm_app grants of crm.aa_extra_night_request are not as planned';
    END IF;
    IF position('accommodation' IN pg_get_constraintdef(
            (SELECT oid FROM pg_constraint
              WHERE conrelid = 'crm.agency_supplier'::regclass AND conname = 'agency_supplier_category_chk'))) > 0 THEN
        RAISE EXCEPTION 'crm-080: agency_supplier_category_chk still allows a blocked category';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-080', now(), 'AA-1144 agency lines: crm.option.category + crm.booking_line.category (flight | visa | insurance | fee), crm.aa_extra_night_request (B11), own suppliers of a blocked category re-typed to other and the unreferenced ones trashed, transfer catalogue services trashed, agency_supplier / agency_service category CHECKs narrowed')
ON CONFLICT (version) DO NOTHING;

COMMIT;
