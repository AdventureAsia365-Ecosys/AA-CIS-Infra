-- Migration crm-083: AA-1147 (S285 decisions T18, B10; advisory-crm-agency-extras.md items b to e) — the agency's own
-- items (flight, visa, insurance, agency fee; crm-080) follow the trip from the accepted proposal to the invoice.
--
-- Owner: AA-Partner (api/migrations/083_crm_agency_extras.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- Migration Apply runs (Migration Copy Guard). Key crm-083, right after crm-082; if the numbers move, renumber: file
-- name, this header, Guard 0 and the registration below, app/db.py REQUIRED_SCHEMA_VERSIONS (code PR) and the tests
-- that name it (git grep '083_' and 'crm-083').
--
-- What:
--   1. crm.booking_line
--        agency_supplier_id  NULL allowed on an agency line: NULL = "Handled by the agency" (no supplier to pick);
--                            booking_line_supplier_chk keeps it required on an AA line.
--        option_id           the agency item of the accepted proposal the line came from (provenance, no foreign key:
--                            an option leaves with its version's purge, the line stays); UNIQUE per agency, so an
--                            accept never writes one item twice.
--        due_at              the line's deadline (ticketing time limit, visa file, insurance purchase): the hourly
--                            workflow tick opens a task when it comes within the agency's lead time (setting
--                            crm.agency_lines.due_lead_days, crm-084).
--        bundled             a flight or agency fee folded into the tour price on the client's documents (T18: visa
--                            and insurance are always their own priced line).
--      booking_line_extras_chk: option_id / due_at / bundled only on an agency line; bundled only for flight | fee.
--      booking_line_trip_line_uq (tenant_id, trip_id, booking_line_id): the target of the same-trip keys of item 3.
--   2. crm.option.bundled (same rule, option_bundled_chk): the builder's "fold into the tour price" of an agency item.
--   3. crm.document.booking_line_id and crm.task.booking_line_id: a file or a task about one line of the same trip
--      (key (tenant_id, trip_id, booking_line_id) -> crm.booking_line, ON DELETE SET NULL (booking_line_id): the file
--      or task stays with its trip when the line is purged). *_line_trip_chk: a line link needs the trip.
--      crm.document.kind gains visa_letter (the invitation letter of a visa line).
--   4. crm.invoice_line_amount_chk: an "included" row of source agency_line may carry the line's sell (what the client
--      pays for that service, printed under "Services provided by <agency>"; never summed: totals and the issue check
--      read charge rows only). Every other included row keeps no amount.
--   5. crm.agency_lines_from_proposal(proposal, lines jsonb): SECURITY DEFINER, EXECUTE crm_app. The client's accept
--      (client link: no member role, so crm.booking_line_money_put refuses it) writes one planning agency line per
--      chosen agency item, with its sell (the item's share of the accepted total, never above the item's sell) and its
--      net as cost. Only an accepted builder version, only its live agency items; idempotent (option_id).
--   6. Register crm-083.
--
-- Class: contract (root ADR 0017 d3: ALTER of existing tables, new and widened CHECKs, new keys, a SECURITY DEFINER
-- function), so no migrate directive. MIG-4: this migration-only PR, applied on Dev by Infra Migration Apply once every
-- job table is idle (root ADR 0017a), then the code PR raises readiness to crm-083. The two settings the code reads
-- (crm.agency_lines.due_lead_days, crm.agency_lines.disclaimer) are crm-084, shipped with their readers in the code PR
-- like crm-082 (the settings lint binds seed, compiled defaults and readers). No new table (no DM-7.1 row), no
-- personal data (dates, a flag, ids), no crm.erase_subject change (the new keys SET NULL).
--
-- Rollback (a NEW forward migration, MIG-14): DROP the function; drop the two keys, booking_line_trip_line_uq and the
-- new CHECKs; restore the crm-024 invoice_line_amount_chk after clearing agency_line amounts; restore the crm-006
-- document_kind_chk after re-typing visa_letter rows; agency_supplier_id NOT NULL only after every agency line has a
-- supplier. The columns can stay (NULL / false).
--
-- Runs as crm_owner (Migration Apply live-owner switch), one BEGIN … COMMIT block, no role DDL. Re-runnable (ADD
-- COLUMN IF NOT EXISTS, CREATE INDEX IF NOT EXISTS, constraints replaced by name, CREATE OR REPLACE FUNCTION, ON
-- CONFLICT DO NOTHING).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '120s';

-- ── Guard 0: runs as the owner, after crm-082 ─────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-083: must run as crm_owner (Migration Apply live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-082') THEN
        RAISE EXCEPTION 'crm-083: crm-082 lands first';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.schema_versions
                WHERE version = 'crm-083' AND description NOT LIKE 'AA-1147 agency extras:%') THEN
        RAISE EXCEPTION 'crm-083: the key crm-083 is already held by another migration (not AA-1147): renumber one';
    END IF;
    IF to_regprocedure('crm.booking_line_money_write(uuid,text,numeric,text,text,timestamptz)') IS NULL THEN
        RAISE EXCEPTION 'crm-083: crm.booking_line_money_write (crm-014) is missing';
    END IF;
END $$;

-- ── 1. crm.booking_line ──────────────────────────────────────────────────────────────────────────
ALTER TABLE crm.booking_line ALTER COLUMN agency_supplier_id DROP NOT NULL;
ALTER TABLE crm.booking_line ADD COLUMN IF NOT EXISTS option_id uuid;
ALTER TABLE crm.booking_line ADD COLUMN IF NOT EXISTS due_at timestamptz;
ALTER TABLE crm.booking_line ADD COLUMN IF NOT EXISTS bundled boolean NOT NULL DEFAULT false;
ALTER TABLE crm.booking_line DROP CONSTRAINT IF EXISTS booking_line_supplier_chk;
ALTER TABLE crm.booking_line ADD CONSTRAINT booking_line_supplier_chk CHECK (
    supplier_kind = 'agency' OR agency_supplier_id IS NOT NULL
);
ALTER TABLE crm.booking_line DROP CONSTRAINT IF EXISTS booking_line_extras_chk;
ALTER TABLE crm.booking_line ADD CONSTRAINT booking_line_extras_chk CHECK (
    (supplier_kind = 'agency' OR (option_id IS NULL AND due_at IS NULL AND NOT bundled))
    AND (NOT bundled OR category IN ('flight', 'fee'))
);
CREATE UNIQUE INDEX IF NOT EXISTS booking_line_option_uq ON crm.booking_line (tenant_id, option_id)
    WHERE option_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS booking_line_trip_line_uq ON crm.booking_line (tenant_id, trip_id, booking_line_id);
CREATE INDEX IF NOT EXISTS booking_line_due_idx ON crm.booking_line (tenant_id, due_at)
    WHERE due_at IS NOT NULL AND deleted_at IS NULL;
COMMENT ON COLUMN crm.booking_line.agency_supplier_id IS 'crm-014: the supplier of the line (the Adventure Asia row on an aa line). AA-1147 (crm-083): NULL on an agency line = handled by the agency itself (booking_line_supplier_chk: required on an aa line).';
COMMENT ON COLUMN crm.booking_line.option_id IS 'AA-1147 (crm-083): the agency item (crm.option) of the accepted proposal this agency line was written from by crm.agency_lines_from_proposal; NULL for a line typed on the Lines tab. Provenance only (no foreign key: the option may be purged with its version); unique per agency.';
COMMENT ON COLUMN crm.booking_line.due_at IS 'AA-1147 (crm-083): the deadline of an agency line (ticketing time limit, visa file, insurance purchase). The hourly workflow tick opens a task when it comes within crm.agency_lines.due_lead_days.';
COMMENT ON COLUMN crm.booking_line.bundled IS 'AA-1147 (crm-083, decision T18): a flight or agency fee line folded into the tour price on the client''s documents (no price of its own there). Visa and insurance are never bundled.';

-- ── 2. crm.option.bundled ────────────────────────────────────────────────────────────────────────
ALTER TABLE crm.option ADD COLUMN IF NOT EXISTS bundled boolean NOT NULL DEFAULT false;
ALTER TABLE crm.option DROP CONSTRAINT IF EXISTS option_bundled_chk;
ALTER TABLE crm.option ADD CONSTRAINT option_bundled_chk CHECK (
    NOT bundled OR (source = 'agency' AND category IN ('flight', 'fee'))
);
COMMENT ON COLUMN crm.option.bundled IS 'AA-1147 (crm-083, decision T18): an agency flight or fee folded into the tour price on the proposal and the invoice (it stays in the total; no price of its own is printed). Visa and insurance are always their own priced line.';

-- ── 3. files and tasks about one line ────────────────────────────────────────────────────────────
ALTER TABLE crm.document ADD COLUMN IF NOT EXISTS booking_line_id uuid;
ALTER TABLE crm.document DROP CONSTRAINT IF EXISTS document_booking_line_fk;
ALTER TABLE crm.document ADD CONSTRAINT document_booking_line_fk FOREIGN KEY (tenant_id, trip_id, booking_line_id)
    REFERENCES crm.booking_line (tenant_id, trip_id, booking_line_id) ON DELETE SET NULL (booking_line_id);
ALTER TABLE crm.document DROP CONSTRAINT IF EXISTS document_line_trip_chk;
ALTER TABLE crm.document ADD CONSTRAINT document_line_trip_chk CHECK (booking_line_id IS NULL OR trip_id IS NOT NULL);
CREATE INDEX IF NOT EXISTS document_booking_line_idx ON crm.document (tenant_id, booking_line_id)
    WHERE booking_line_id IS NOT NULL;
ALTER TABLE crm.document DROP CONSTRAINT IF EXISTS document_kind_chk;
ALTER TABLE crm.document ADD CONSTRAINT document_kind_chk CHECK (
    kind IN ('passport_scan', 'waiver_pdf', 'terms_pdf', 'ticket', 'voucher', 'invoice_pdf', 'supplier_confirmation',
             'other', 'confirmation_pdf', 'proposal_pdf', 'visa_letter')
);
COMMENT ON COLUMN crm.document.booking_line_id IS 'AA-1147 (crm-083): the booking line of the same trip the file is about (an e-ticket, a visa letter, an insurance certificate); NULL = the whole trip or traveller. Set NULL when the line is purged.';

ALTER TABLE crm.task ADD COLUMN IF NOT EXISTS booking_line_id uuid;
ALTER TABLE crm.task DROP CONSTRAINT IF EXISTS task_booking_line_fk;
ALTER TABLE crm.task ADD CONSTRAINT task_booking_line_fk FOREIGN KEY (tenant_id, trip_id, booking_line_id)
    REFERENCES crm.booking_line (tenant_id, trip_id, booking_line_id) ON DELETE SET NULL (booking_line_id);
ALTER TABLE crm.task DROP CONSTRAINT IF EXISTS task_line_trip_chk;
ALTER TABLE crm.task ADD CONSTRAINT task_line_trip_chk CHECK (booking_line_id IS NULL OR trip_id IS NOT NULL);
CREATE INDEX IF NOT EXISTS task_booking_line_idx ON crm.task (tenant_id, booking_line_id)
    WHERE booking_line_id IS NOT NULL;
COMMENT ON COLUMN crm.task.booking_line_id IS 'AA-1147 (crm-083): the booking line of the same trip the task is about (an agency line nearing its deadline); NULL = the trip. Set NULL when the line is purged.';

-- ── 4. invoice: an included agency line may show its price ───────────────────────────────────────
ALTER TABLE crm.invoice_line DROP CONSTRAINT IF EXISTS invoice_line_amount_chk;
ALTER TABLE crm.invoice_line ADD CONSTRAINT invoice_line_amount_chk CHECK (
    (kind = 'charge' AND quantity > 0 AND quantity <= 9999 AND unit_amount > 0 AND amount > 0
     AND amount = round(quantity * unit_amount, 2))
    OR (kind = 'included' AND quantity IS NULL AND unit_amount IS NULL
        AND source IN ('agency_line', 'aa_line', 'manual')
        AND (amount IS NULL OR (source = 'agency_line' AND amount >= 0)))
);
COMMENT ON COLUMN crm.invoice_line.amount IS 'crm-024: quantity x unit_amount of a charge row. AA-1147 (crm-083): on an included agency_line row, the price the client pays for that agency service (printed under "Services provided by <agency>", never summed); NULL when it is folded into the tour price.';

-- ── 5. the accept writes the agency lines ────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION crm.agency_lines_from_proposal(p_proposal uuid, p_lines jsonb) RETURNS integer
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_tenant uuid := NULLIF(current_setting('app.tenant_id', true), '')::uuid;
    v_proposal record;
    v_item jsonb;
    v_option record;
    v_sell numeric;
    v_from date;
    v_line uuid;
    v_made integer := 0;
BEGIN
    IF v_tenant IS NULL THEN
        RAISE EXCEPTION 'crm: tenant_context_missing (app.tenant_id is not set)'
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) > 200 THEN
        RAISE EXCEPTION 'crm: lines_invalid (an array of at most 200 items)' USING ERRCODE = 'check_violation';
    END IF;
    SELECT p.proposal_id, p.trip_id, p.currency INTO v_proposal
      FROM crm.proposal p
     WHERE p.proposal_id = p_proposal AND p.tenant_id = v_tenant AND p.status = 'accepted' AND p.kind = 'builder'
       AND p.deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'crm: proposal_not_accepted (agency lines come from an accepted builder version)'
            USING ERRCODE = 'CRM13';
    END IF;
    FOR v_item IN SELECT x FROM jsonb_array_elements(p_lines) x LOOP
        SELECT o.option_id, o.trip_id, o.title, o.category, o.bundled, o.agency_supplier_id, o.sell_amount,
               o.net_amount, o.pay_on_arrival
          INTO v_option
          FROM crm.option o
         WHERE o.option_id = (v_item ->> 'option_id')::uuid AND o.tenant_id = v_tenant
           AND o.proposal_id = p_proposal AND o.source = 'agency' AND o.deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'crm: option_not_agency (an agency item of this version)' USING ERRCODE = 'check_violation';
        END IF;
        v_sell := round((v_item ->> 'sell')::numeric, 2);
        IF v_sell IS NULL OR v_sell < 0 OR v_sell > v_option.sell_amount THEN
            RAISE EXCEPTION 'crm: sell_invalid (from 0 to the item''s sell)' USING ERRCODE = 'check_violation';
        END IF;
        v_from := NULLIF(v_item ->> 'service_from', '')::date;
        INSERT INTO crm.booking_line (trip_id, supplier_kind, agency_supplier_id, status, title, service_from,
                                      service_to, collect, visible_to_travelers, category, option_id, bundled)
        VALUES (v_option.trip_id, 'agency', v_option.agency_supplier_id, 'planning', v_option.title, v_from, v_from,
                CASE WHEN v_option.pay_on_arrival THEN 'on_arrival' ELSE 'agency' END, false, v_option.category,
                v_option.option_id, v_option.bundled)
        ON CONFLICT (tenant_id, option_id) WHERE option_id IS NOT NULL DO NOTHING
        RETURNING booking_line_id INTO v_line;
        IF v_line IS NULL THEN
            CONTINUE;  -- written by an earlier call
        END IF;
        PERFORM crm.booking_line_money_write(v_line, 'sell', v_sell, v_proposal.currency, 'planning', NULL);
        IF v_option.net_amount IS NOT NULL THEN
            PERFORM crm.booking_line_money_write(v_line, 'cost', v_option.net_amount, v_proposal.currency, 'planning',
                                                 NULL);
        END IF;
        v_made := v_made + 1;
        v_line := NULL;
    END LOOP;
    RETURN v_made;
END;
$$;
REVOKE ALL ON FUNCTION crm.agency_lines_from_proposal(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.agency_lines_from_proposal(uuid, jsonb) TO crm_app;
COMMENT ON FUNCTION crm.agency_lines_from_proposal(uuid, jsonb) IS 'AA-1147 (crm-083): the accept of a builder version (client link, no member role) writes one planning agency line per chosen agency item: p_lines = [{option_id, sell, service_from}], sell from 0 to the item''s sell (its share of the accepted total), the item''s net as cost, the title, category, supplier (NULL = handled by the agency) and bundled flag copied, option_id kept (unique: a second call writes nothing). Only an accepted, live builder version of the agency of app.tenant_id and its live agency items (CRM13 / check_violation otherwise). Returns the lines written. SECURITY DEFINER; EXECUTE crm_app.';

-- ── Post-check ────────────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF (SELECT attnotnull FROM pg_attribute
         WHERE attrelid = 'crm.booking_line'::regclass AND attname = 'agency_supplier_id') THEN
        RAISE EXCEPTION 'crm-083: crm.booking_line.agency_supplier_id is still NOT NULL';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conrelid = 'crm.booking_line'::regclass AND conname = 'booking_line_supplier_chk')
       OR NOT EXISTS (SELECT 1 FROM pg_constraint
                       WHERE conrelid = 'crm.option'::regclass AND conname = 'option_bundled_chk')
       OR NOT EXISTS (SELECT 1 FROM pg_constraint
                       WHERE conrelid = 'crm.task'::regclass AND conname = 'task_booking_line_fk')
       OR NOT EXISTS (SELECT 1 FROM pg_constraint
                       WHERE conrelid = 'crm.document'::regclass AND conname = 'document_booking_line_fk') THEN
        RAISE EXCEPTION 'crm-083: a constraint of the agency extras is missing';
    END IF;
    IF NOT has_function_privilege('crm_app', 'crm.agency_lines_from_proposal(uuid,jsonb)', 'EXECUTE')
       OR has_function_privilege('public', 'crm.agency_lines_from_proposal(uuid,jsonb)', 'EXECUTE')
       OR has_function_privilege('crm_app', 'crm.booking_line_money_write(uuid,text,numeric,text,text,timestamptz)',
                                 'EXECUTE') THEN
        RAISE EXCEPTION 'crm-083: the EXECUTE grants of crm.agency_lines_from_proposal are not as planned (SEC-4)';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-083', now(), 'AA-1147 agency extras: booking_line supplier optional + option_id / due_at / bundled, option.bundled, document and task booking_line_id, visa_letter, included agency_line amounts on invoices, crm.agency_lines_from_proposal')
ON CONFLICT (version) DO NOTHING;

COMMIT;
