-- Migration crm-051: AA-1068 (S275 study of a tour and travel app, root docs/research/2026-11-10-odoo-tour-travel-plugin-
-- comparison.md, items crm-25, crm-26, crm-30, crm-31, crm-32) — CRM finance: the profit of a trip, the agency's AA
-- invoices as its actual AA cost, supplier bills against the planned cost, and the group departure costs split per
-- traveller.
--
-- Owner: AA-Partner (api/migrations/051_crm_trip_finance.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- DB Migrate applies (Migration Copy Guard). Key crm-051: crm-049 and crm-050 (cancellation, payment schedule) come first; if main moves,
-- renumber: file name, this header, the post-check and the registration below, app/db.py REQUIRED_SCHEMA_VERSIONS and
-- the tests that name it (git grep '051_' and 'crm-051'). Needs crm-049 (crm.cancellation_charge, read by the view).
--
-- What:
--   1. crm.trip.group_code (NULL, else 1-80 characters [A-Za-z0-9:_.-]): the agency's own code for a group departure
--      that has no AA departure id (its tour leader, its group flight block). A booked trip is on a departure when one
--      of its confirmed AA lines carries that departure_id, or when its group_code is that code (crm.v_departure_trip).
--   2. crm.booking_line_money: kind + 'actual_cost' (what the supplier billed for an agency line, the sum of its bill
--      lines, crm-25), fx_basis + 'bill_date' (frozen at the rate of the latest bill's date). Written only by
--      crm.booking_line_actual_cost (SECURITY DEFINER), never by crm.booking_line_money_put (its kinds are unchanged).
--   3. crm.supplier_bill (recorded -> paid | void, paid -> void) and crm.supplier_bill_line (the part of a bill that
--      pays one agency line of the same supplier, guard crm.guard_supplier_bill_line, SQLSTATE CRM51). The bill's FX is
--      frozen when it is recorded (the bill date's rate, crm.fx_resolve, in the agency's base currency at that time).
--      A bill never changes after it is recorded except its status, paid_on and note: a wrong bill is voided and entered
--      again. Owner / agent only (margin policy).
--   4. crm.aa_invoice_cache: the agency's AA invoices as booking.b2b.v1 1.5 GET /invoices and /invoices/{number}
--      answered them the last time the CRM read them (number, kind, status, currency, total, balance, issue / due day,
--      overdue days, and per AA booking the amount invoiced with the roles of its lines). The CRM page reads Booking
--      live on every open and keeps this copy for the trip P&L and the mismatch flag. Owner / agent only.
--   5. crm.departure_cost: a cost the agency carries for a whole group departure (an AA departure id or its own
--      group_code): per_departure (split by pax over the departure's live trips) or per_pax (amount per traveller),
--      FX frozen at the cost day. Owner / agent only.
--   6. crm.v_departure_trip: the booked trips (booked, pre_departure, travelling, completed) on each departure ref with
--      their pax. A lead that only has a quote for the departure (a planning line) takes no share of its costs.
--   7. crm.v_trip_pnl: one row per live trip, in the agency's base currency: revenue (issued invoices net of tax, by
--      kind, minus refunds net of tax; a trip cancelled with a charge, crm.cancellation_charge of crm-049 (applied
--      before this key): the charge net of tax in place of its sales, their refunds and its fee invoices), costs (AA lines at the quote, or at the AA invoice once it bills the booking in
--      full, spread over the booking's lines by their quoted cost; agency lines at the supplier bill once billed, else planned; AA cancellation fees; the departure share;
--      the sales partner commission, 0 until that card), supplier commission income, margin, margin % and per pax.
--      security_invoker: the money rows reach owner / agent only (crm-014 policy), so the view is read through the
--      margin-gated API only.
--
-- Behaviour on apply: none. No trip has a group code, no line an actual cost, no agency a bill, an AA invoice copy or
-- a departure cost, until the AA-Partner code PR deploys. The two views are new.
--
-- Class: contract (ALTER of crm.trip and crm.booking_line_money, rows in crm.status_transition). MIG-4: this
-- migration-only PR, then the code PR once it is applied on Dev. DM-7.1: crm.supplier_bill and crm.supplier_bill_line
-- go with the agency (a bill line with its booking line too), crm.aa_invoice_cache and crm.departure_cost with the
-- agency (root data standards Part B §7 rows added with this key). Erasure by cascade (no crm.erase_subject change):
-- every new table cascades from crm.agency_supplier (the agency erase deletes it), a bill line from its booking line too.
--
-- Rollback (a NEW forward migration, after the code is reverted): DROP VIEW crm.v_trip_pnl, crm.v_departure_trip;
-- DROP TABLE crm.departure_cost, crm.aa_invoice_cache, crm.supplier_bill_line, crm.supplier_bill; DROP FUNCTION
-- crm.booking_line_actual_cost(uuid), crm.guard_supplier_bill_line(); DELETE FROM crm.status_transition WHERE
-- table_name = 'supplier_bill'; delete the actual_cost money rows (with app.erasing) and put back the crm-035 kind CHECK
-- and the crm-014 FX CHECK; ALTER TABLE crm.trip DROP COLUMN group_code.
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL. Re-runnable (IF NOT EXISTS, DROP …
-- IF EXISTS before each ADD, CREATE OR REPLACE, ON CONFLICT DO NOTHING).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '5min';

-- ── Guard 0: runs as the owner, after crm-048 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-051: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-048') THEN
        RAISE EXCEPTION 'crm-051: crm-048 (AA-1066) lands first';
    END IF;
    IF to_regclass('crm.booking_line_money') IS NULL OR to_regclass('crm.invoice') IS NULL
       OR to_regclass('crm.payment') IS NULL OR to_regclass('crm.commission') IS NULL
       OR to_regprocedure('crm.fx_resolve(text, text, date)') IS NULL
       OR to_regprocedure('crm.enforce_status_transition()') IS NULL THEN
        RAISE EXCEPTION 'crm-051: the ledger (crm-014), invoices and payments (crm-024), commissions (crm-035) or crm.fx_resolve missing';
    END IF;
END $$;

-- ── 1. crm.trip.group_code ───────────────────────────────────────────────────────────────────────
ALTER TABLE crm.trip ADD COLUMN IF NOT EXISTS group_code TEXT;
ALTER TABLE crm.trip DROP CONSTRAINT IF EXISTS trip_group_code_chk;
ALTER TABLE crm.trip ADD CONSTRAINT trip_group_code_chk CHECK (
    group_code IS NULL OR group_code ~ '^[A-Za-z0-9:_.-]{1,80}$'
);
CREATE INDEX IF NOT EXISTS trip_group_code_idx ON crm.trip (tenant_id, group_code)
    WHERE group_code IS NOT NULL AND deleted_at IS NULL;
COMMENT ON COLUMN crm.trip.group_code IS 'AA-1068 (crm-051, item crm-32): the agency''s own code of a group departure without an AA departure id; the trip shares that departure''s costs (crm.departure_cost) by pax. NULL = none. Not personal data.';
-- The departure of an AA line, to find the trips of a departure.
CREATE INDEX IF NOT EXISTS booking_line_departure_idx ON crm.booking_line (tenant_id, departure_id)
    WHERE departure_id IS NOT NULL AND deleted_at IS NULL;

-- ── 2. crm.booking_line_money: kind actual_cost, FX basis bill_date ──────────────────────────────
ALTER TABLE crm.booking_line_money DROP CONSTRAINT IF EXISTS booking_line_money_kind_chk;
ALTER TABLE crm.booking_line_money ADD CONSTRAINT booking_line_money_kind_chk
    CHECK (kind IN ('cost', 'sell', 'commission_expected', 'cancellation_cost', 'actual_cost'));
ALTER TABLE crm.booking_line_money DROP CONSTRAINT IF EXISTS booking_line_money_fx_chk;
ALTER TABLE crm.booking_line_money ADD CONSTRAINT booking_line_money_fx_chk CHECK (
    num_nulls(base_currency, amount_base, fx_rate, fx_rate_date, fx_source, fx_basis, stale_days) IN (0, 7)
    AND (base_currency IS NULL OR (
        base_currency ~ '^[A-Z]{3}$' AND fx_rate > 0 AND amount_base = round(amount * fx_rate, 2)
        AND (base_currency <> currency OR fx_rate = 1)
        AND fx_source IN ('aa_quote_lock', 'platform_daily', 'manual')
        AND fx_basis IN ('booking_date', 'receipt_date', 'quote_lock', 'bill_date')
        AND stale_days BETWEEN 0 AND 366
    ))
);

-- ── 3. crm.supplier_bill and crm.supplier_bill_line ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.supplier_bill (
    supplier_bill_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id          UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                       REFERENCES crm.tenant (tenant_id),
    agency_supplier_id UUID NOT NULL,
    number             TEXT NOT NULL,
    bill_date          DATE NOT NULL,
    currency           CHAR(3) NOT NULL,
    amount             NUMERIC(14,2) NOT NULL,
    status             TEXT NOT NULL DEFAULT 'recorded',
    paid_on            DATE,
    note               TEXT,
    base_currency      CHAR(3) NOT NULL,
    amount_base        NUMERIC(14,2) NOT NULL,
    fx_rate            NUMERIC(20,10) NOT NULL,
    fx_rate_date       DATE NOT NULL,
    fx_source          TEXT NOT NULL,
    stale_days         SMALLINT NOT NULL,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by         TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at         TIMESTAMPTZ,
    deleted_by         TEXT,
    purge_after        TIMESTAMPTZ,
    CONSTRAINT supplier_bill_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    ),
    CONSTRAINT supplier_bill_tenant_id_uq UNIQUE (tenant_id, supplier_bill_id),
    CONSTRAINT supplier_bill_supplier_fk FOREIGN KEY (tenant_id, agency_supplier_id)
        REFERENCES crm.agency_supplier (tenant_id, agency_supplier_id) ON DELETE CASCADE,
    CONSTRAINT supplier_bill_values_chk CHECK (
        char_length(btrim(number)) BETWEEN 1 AND 80 AND number !~ '[[:cntrl:]]'
        AND currency ~ '^[A-Z]{3}$' AND amount > 0 AND amount <= 99999999999.99
        AND (note IS NULL OR (char_length(btrim(note)) BETWEEN 1 AND 500 AND note !~ '[[:cntrl:]]'))
    ),
    CONSTRAINT supplier_bill_status_chk CHECK (
        status IN ('recorded', 'paid', 'void')
        AND (status <> 'paid' OR paid_on IS NOT NULL)
        AND (status <> 'recorded' OR paid_on IS NULL)
        AND (paid_on IS NULL OR paid_on >= bill_date)
    ),
    CONSTRAINT supplier_bill_fx_chk CHECK (
        base_currency ~ '^[A-Z]{3}$' AND fx_rate > 0 AND amount_base = round(amount * fx_rate, 2)
        AND (base_currency <> currency OR fx_rate = 1)
        AND fx_source IN ('platform_daily', 'manual') AND stale_days BETWEEN 0 AND 366
    )
);
-- One live bill per supplier number (a voided bill's number may be entered again).
CREATE UNIQUE INDEX IF NOT EXISTS supplier_bill_number_uq ON crm.supplier_bill (tenant_id, agency_supplier_id, number)
    WHERE status <> 'void';
CREATE INDEX IF NOT EXISTS supplier_bill_date_idx ON crm.supplier_bill (tenant_id, bill_date DESC);
COMMENT ON TABLE crm.supplier_bill IS 'AA-1068 (crm-051, item crm-25): a bill one of the agency''s own suppliers sent: number, bill date, currency, amount, the FX of the bill date frozen when recorded (crm.fx_resolve into the base currency of that time). recorded -> paid (paid_on) | void, paid -> void; nothing else changes after it is recorded (column grants: status, paid_on, note). Its lines (crm.supplier_bill_line) are the agency lines it pays; each billed line gets an actual_cost money row (crm.booking_line_actual_cost). Owner / agent only (RESTRICTIVE supplier_bill_margin_roles). Cascades from its supplier. Commercial, no personal data.';
COMMENT ON COLUMN crm.supplier_bill.amount IS 'conf:commercial; the bill total in its currency (the lines may cover less: the rest is not a trip cost)';
COMMENT ON COLUMN crm.supplier_bill.amount_base IS 'conf:commercial; round(amount * fx_rate, 2) in base_currency';
COMMENT ON COLUMN crm.supplier_bill.note IS 'conf:commercial; the agency''s note (no personal data by the form''s hint)';

CREATE TABLE IF NOT EXISTS crm.supplier_bill_line (
    supplier_bill_line_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id             UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                          REFERENCES crm.tenant (tenant_id),
    supplier_bill_id      UUID NOT NULL,
    booking_line_id       UUID NOT NULL,
    amount                NUMERIC(14,2) NOT NULL,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by            TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at            TIMESTAMPTZ,
    deleted_by            TEXT,
    purge_after           TIMESTAMPTZ,
    CONSTRAINT supplier_bill_line_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    ),
    CONSTRAINT supplier_bill_line_tenant_id_uq UNIQUE (tenant_id, supplier_bill_line_id),
    CONSTRAINT supplier_bill_line_once_uq UNIQUE (tenant_id, supplier_bill_id, booking_line_id),
    CONSTRAINT supplier_bill_line_bill_fk FOREIGN KEY (tenant_id, supplier_bill_id)
        REFERENCES crm.supplier_bill (tenant_id, supplier_bill_id) ON DELETE CASCADE,
    CONSTRAINT supplier_bill_line_line_fk FOREIGN KEY (tenant_id, booking_line_id)
        REFERENCES crm.booking_line (tenant_id, booking_line_id) ON DELETE CASCADE,
    CONSTRAINT supplier_bill_line_amount_chk CHECK (amount >= 0 AND amount <= 99999999999.99)
);
CREATE INDEX IF NOT EXISTS supplier_bill_line_line_idx ON crm.supplier_bill_line (tenant_id, booking_line_id);
COMMENT ON TABLE crm.supplier_bill_line IS 'AA-1068 (crm-051, item crm-25): the part of a supplier bill that pays one agency line of the same supplier (guard crm.guard_supplier_bill_line, CRM51), in the bill''s currency. Written once with its bill, never changed (no UPDATE / DELETE for crm_app). Owner / agent only. Cascades from its bill and from its booking line. Commercial, no personal data.';
COMMENT ON COLUMN crm.supplier_bill_line.amount IS 'conf:commercial; in the bill''s currency';

CREATE OR REPLACE FUNCTION crm.guard_supplier_bill_line() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_bill record;
    v_line record;
BEGIN
    IF current_user = 'crm_owner' THEN
        RETURN NEW;  -- migrations and tests
    END IF;
    SELECT b.agency_supplier_id, b.status INTO v_bill
      FROM crm.supplier_bill b WHERE b.tenant_id = NEW.tenant_id AND b.supplier_bill_id = NEW.supplier_bill_id;
    SELECT l.supplier_kind, l.agency_supplier_id, l.deleted_at INTO v_line
      FROM crm.booking_line l WHERE l.tenant_id = NEW.tenant_id AND l.booking_line_id = NEW.booking_line_id;
    IF v_bill.agency_supplier_id IS NULL OR v_line.supplier_kind IS NULL THEN
        RETURN NEW;  -- the foreign keys answer
    END IF;
    IF v_bill.status = 'void' THEN
        RAISE EXCEPTION 'crm: bill_line_guard (a void bill takes no line)' USING ERRCODE = 'CRM51';
    END IF;
    IF v_line.supplier_kind <> 'agency' OR v_line.agency_supplier_id <> v_bill.agency_supplier_id
       OR v_line.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'crm: bill_line_guard (a bill pays live agency lines of its own supplier)' USING ERRCODE = 'CRM51';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION crm.guard_supplier_bill_line() FROM PUBLIC;
COMMENT ON FUNCTION crm.guard_supplier_bill_line() IS 'AA-1068 (crm-051, SQLSTATE CRM51): a supplier bill line names a live agency booking line of the bill''s own supplier, on a bill that is not void. crm_owner unguarded (migrations, tests). Invoker rights.';

-- ── 4. crm.aa_invoice_cache ──────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.aa_invoice_cache (
    tenant_id          UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                       REFERENCES crm.tenant (tenant_id),
    number             TEXT NOT NULL,
    agency_supplier_id UUID NOT NULL,
    invoice_kind       TEXT NOT NULL,
    aa_status          TEXT NOT NULL,
    currency           CHAR(3) NOT NULL,
    total_amount       NUMERIC(14,2) NOT NULL,
    balance_amount     NUMERIC(14,2) NOT NULL,
    issued_on          DATE NOT NULL,
    due_on             DATE NOT NULL,
    overdue_days       INTEGER NOT NULL DEFAULT 0,
    booking_amounts    JSONB NOT NULL DEFAULT '{}'::jsonb,
    detail_read        BOOLEAN NOT NULL DEFAULT false,
    refreshed_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by         TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at         TIMESTAMPTZ,
    deleted_by         TEXT,
    purge_after        TIMESTAMPTZ,
    CONSTRAINT aa_invoice_cache_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    ),
    CONSTRAINT aa_invoice_cache_pkey PRIMARY KEY (tenant_id, number),
    CONSTRAINT aa_invoice_cache_supplier_fk FOREIGN KEY (tenant_id, agency_supplier_id)
        REFERENCES crm.agency_supplier (tenant_id, agency_supplier_id) ON DELETE CASCADE,
    CONSTRAINT aa_invoice_cache_values_chk CHECK (
        number ~ '^AA[ST]-[0-9]{4}-[0-9]{6}$'
        AND invoice_kind IN ('saas', 'settlement') AND aa_status IN ('issued', 'paid', 'void')
        AND currency ~ '^[A-Z]{3}$'
        AND abs(total_amount) <= 99999999999.99 AND abs(balance_amount) <= 99999999999.99
        AND overdue_days BETWEEN 0 AND 36500
        AND jsonb_typeof(booking_amounts) = 'object' AND octet_length(booking_amounts::text) <= 65536
    )
);
CREATE INDEX IF NOT EXISTS aa_invoice_cache_due_idx ON crm.aa_invoice_cache (tenant_id, aa_status, due_on);
COMMENT ON TABLE crm.aa_invoice_cache IS 'AA-1068 (crm-051, item crm-26): the agency''s AA invoices (booking.b2b.v1 1.5 GET /invoices, settlement detail from GET /invoices/{number}) as the CRM read them last (refreshed_at): kind saas | settlement, aa_status issued | paid | void (Booking''s status, mirrored: no CRM state machine), currency, total, balance, issue / due day, overdue days, and booking_amounts {AA booking id: {"amount": "<sum of its live deposit / balance / full / adjustment lines>", "complete": <a balance or full line billed>}} (detail_read once the lines were read). The "Bookings with AA" page reads Booking live and keeps this copy; the trip P&L uses it as the AA cost once a booking is billed in full. Cascades from the agency''s Adventure Asia supplier row. Owner / agent only (RESTRICTIVE aa_invoice_cache_margin_roles). Commercial, no personal data.';
COMMENT ON COLUMN crm.aa_invoice_cache.total_amount IS 'conf:commercial; the AA B2B amount billed (the agency''s AA cost)';
COMMENT ON COLUMN crm.aa_invoice_cache.booking_amounts IS 'conf:commercial; per AA booking id: {"amount", "complete"}';

-- ── 5. crm.departure_cost ────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.departure_cost (
    departure_cost_id  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id          UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                       REFERENCES crm.tenant (tenant_id),
    departure_ref      TEXT NOT NULL,
    agency_supplier_id UUID NOT NULL,
    title              TEXT NOT NULL,
    amount             NUMERIC(14,2) NOT NULL,
    currency           CHAR(3) NOT NULL,
    basis              TEXT NOT NULL,
    cost_date          DATE NOT NULL,
    base_currency      CHAR(3) NOT NULL,
    amount_base        NUMERIC(14,2) NOT NULL,
    fx_rate            NUMERIC(20,10) NOT NULL,
    fx_rate_date       DATE NOT NULL,
    fx_source          TEXT NOT NULL,
    stale_days         SMALLINT NOT NULL,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by         TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at         TIMESTAMPTZ,
    deleted_by         TEXT,
    purge_after        TIMESTAMPTZ,
    CONSTRAINT departure_cost_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    ),
    CONSTRAINT departure_cost_tenant_id_uq UNIQUE (tenant_id, departure_cost_id),
    CONSTRAINT departure_cost_supplier_fk FOREIGN KEY (tenant_id, agency_supplier_id)
        REFERENCES crm.agency_supplier (tenant_id, agency_supplier_id) ON DELETE CASCADE,
    CONSTRAINT departure_cost_values_chk CHECK (
        departure_ref ~ '^[A-Za-z0-9:_.-]{1,80}$'
        AND char_length(btrim(title)) BETWEEN 1 AND 120 AND title !~ '[[:cntrl:]]'
        AND currency ~ '^[A-Z]{3}$' AND amount > 0 AND amount <= 99999999999.99
        AND basis IN ('per_departure', 'per_pax')
    ),
    CONSTRAINT departure_cost_fx_chk CHECK (
        base_currency ~ '^[A-Z]{3}$' AND fx_rate > 0 AND amount_base = round(amount * fx_rate, 2)
        AND (base_currency <> currency OR fx_rate = 1)
        AND fx_source IN ('platform_daily', 'manual') AND stale_days BETWEEN 0 AND 366
    )
);
CREATE INDEX IF NOT EXISTS departure_cost_ref_idx ON crm.departure_cost (tenant_id, departure_ref);
COMMENT ON TABLE crm.departure_cost IS 'AA-1068 (crm-051, item crm-32): a cost the agency carries for a whole group departure (its own tour leader, a group flight block, a welcome dinner): departure_ref = an AA departure id or the agency''s crm.trip.group_code; basis per_departure (amount split by pax over the departure''s live trips, crm.v_departure_trip) or per_pax (amount per traveller); FX of cost_date frozen when recorded. Edited or deleted by the owner / agent (no trash: agency set-up data). Owner / agent only (RESTRICTIVE departure_cost_margin_roles). Cascades from its supplier. Commercial, no personal data.';
COMMENT ON COLUMN crm.departure_cost.amount IS 'conf:commercial; per departure or per traveller (basis)';
COMMENT ON COLUMN crm.departure_cost.amount_base IS 'conf:commercial; round(amount * fx_rate, 2) in base_currency';

-- ── RLS, margin policies, triggers, grants of the four tables ────────────────────────────────────
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['supplier_bill', 'supplier_bill_line', 'aa_invoice_cache', 'departure_cost'] LOOP
        EXECUTE format('ALTER TABLE crm.%I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE crm.%I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON crm.%I', t);
        EXECUTE format(
            'CREATE POLICY tenant_isolation ON crm.%I '
            'TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser '
            'USING (tenant_id = NULLIF(current_setting(''app.tenant_id'', true), '''')::uuid) '
            'WITH CHECK (tenant_id = NULLIF(current_setting(''app.tenant_id'', true), '''')::uuid)', t);
        -- The crm-014 margin rule on reads and writes: an owner or an agent, or a job / seed actor without a role.
        EXECUTE format('DROP POLICY IF EXISTS %I ON crm.%I', t || '_margin_roles', t);
        EXECUTE format(
            'CREATE POLICY %I ON crm.%I AS RESTRICTIVE FOR ALL TO crm_app '
            'USING ((COALESCE(current_setting(''app.member_role'', true), '''') IN (''owner'', ''agent'')) '
            '       OR (COALESCE(current_setting(''app.member_role'', true), '''') = '''' '
            '           AND COALESCE(current_setting(''app.actor'', true), '''') ~ ''^(job|seed):'')) '
            'WITH CHECK ((COALESCE(current_setting(''app.member_role'', true), '''') IN (''owner'', ''agent'')) '
            '       OR (COALESCE(current_setting(''app.member_role'', true), '''') = '''' '
            '           AND COALESCE(current_setting(''app.actor'', true), '''') ~ ''^(job|seed):''))',
            t || '_margin_roles', t);
    END LOOP;
    FOREACH t IN ARRAY ARRAY['supplier_bill', 'supplier_bill_line', 'aa_invoice_cache', 'departure_cost'] LOOP
        EXECUTE format(
            'CREATE OR REPLACE TRIGGER %I BEFORE UPDATE ON crm.%I FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at()',
            t || '_set_updated_at', t);
    END LOOP;
    EXECUTE 'CREATE OR REPLACE TRIGGER supplier_bill_line_guard BEFORE INSERT OR UPDATE ON crm.supplier_bill_line '
            'FOR EACH ROW EXECUTE FUNCTION crm.guard_supplier_bill_line()';
    -- crm_app: the default privileges gave table-wide DML; narrow it. A bill changes only its status, paid day and
    -- note; its lines are written once; the AA invoice copy and the departure costs are the app's to rewrite.
    EXECUTE 'REVOKE ALL ON crm.supplier_bill, crm.supplier_bill_line, crm.aa_invoice_cache, crm.departure_cost FROM crm_app';
    EXECUTE 'GRANT SELECT, INSERT ON crm.supplier_bill, crm.supplier_bill_line TO crm_app';
    EXECUTE 'GRANT UPDATE (status, paid_on, note) ON crm.supplier_bill TO crm_app';
    EXECUTE 'GRANT SELECT, INSERT, UPDATE, DELETE ON crm.aa_invoice_cache, crm.departure_cost TO crm_app';
END $$;

-- ── Status moves of crm.supplier_bill ────────────────────────────────────────────────────────────
INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('supplier_bill', 'recorded', 'paid'),
    ('supplier_bill', 'recorded', 'void'),
    ('supplier_bill', 'paid', 'void')
ON CONFLICT DO NOTHING;
CREATE OR REPLACE TRIGGER supplier_bill_status_transition
    BEFORE UPDATE OF status ON crm.supplier_bill
    FOR EACH ROW EXECUTE FUNCTION crm.enforce_status_transition();

-- ── crm.booking_line_actual_cost: the actual_cost head of an agency line from its bills ──────────
CREATE OR REPLACE FUNCTION crm.booking_line_actual_cost(p_line uuid) RETURNS uuid
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_role text := COALESCE(current_setting('app.member_role', true), '');
    v_actor text := COALESCE(current_setting('app.actor', true), '');
    v_kind text;
    v_sum record;
    v_last record;
    v_head record;
    v_id uuid;
BEGIN
    IF NOT (v_role IN ('owner', 'agent') OR (v_role = '' AND v_actor ~ '^(job|seed):')) THEN
        RAISE EXCEPTION 'crm: margin_forbidden (only an owner or an agent records supplier bills)'
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    SELECT l.supplier_kind INTO v_kind FROM crm.booking_line l WHERE l.booking_line_id = p_line FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'crm: subject_not_found (booking_line %)', p_line USING ERRCODE = 'CRM13';
    END IF;
    IF v_kind <> 'agency' THEN
        RAISE EXCEPTION 'crm: aa_line_read_only (an AA line''s cost comes from AA)' USING ERRCODE = 'CRM24';
    END IF;
    -- The live bills of the line: one currency (the app refuses a second one), the sum of their lines.
    SELECT count(DISTINCT b.currency) AS currencies, min(b.currency) AS currency, sum(bl.amount) AS amount
      INTO v_sum
      FROM crm.supplier_bill_line bl
      JOIN crm.supplier_bill b ON b.supplier_bill_id = bl.supplier_bill_id
     WHERE bl.booking_line_id = p_line AND b.status <> 'void';
    IF v_sum.currencies = 0 THEN
        RETURN NULL;  -- not billed (any older actual_cost head is ignored: the P&L reads it only while billed)
    END IF;
    IF v_sum.currencies > 1 THEN
        RAISE EXCEPTION 'crm: bill_currency_mixed (the bills of one line share one currency)'
            USING ERRCODE = 'CRM51';
    END IF;
    -- The FX of the latest bill (bill date, then the latest recorded): "at bill FX".
    SELECT b.base_currency, b.fx_rate, b.fx_rate_date, b.fx_source, b.stale_days INTO v_last
      FROM crm.supplier_bill_line bl
      JOIN crm.supplier_bill b ON b.supplier_bill_id = bl.supplier_bill_id
     WHERE bl.booking_line_id = p_line AND b.status <> 'void'
     ORDER BY b.bill_date DESC, b.created_at DESC, b.supplier_bill_id DESC
     LIMIT 1;
    SELECT m.* INTO v_head
      FROM crm.booking_line_money m
     WHERE m.booking_line_id = p_line AND m.kind = 'actual_cost'
       AND NOT EXISTS (SELECT 1 FROM crm.booking_line_money n WHERE n.supersedes_id = m.booking_line_money_id);
    IF v_head.booking_line_money_id IS NOT NULL AND v_head.amount = v_sum.amount AND v_head.currency = v_sum.currency
       AND v_head.fx_rate = v_last.fx_rate AND v_head.base_currency = v_last.base_currency THEN
        RETURN v_head.booking_line_money_id;  -- nothing changes
    END IF;
    INSERT INTO crm.booking_line_money (booking_line_id, kind, amount, currency, base_currency, amount_base, fx_rate,
                                        fx_rate_date, fx_source, fx_basis, stale_days, supersedes_id)
    VALUES (p_line, 'actual_cost', v_sum.amount, v_sum.currency, v_last.base_currency,
            round(v_sum.amount * v_last.fx_rate, 2), v_last.fx_rate, v_last.fx_rate_date, v_last.fx_source,
            'bill_date', v_last.stale_days, v_head.booking_line_money_id)
    RETURNING booking_line_money_id INTO v_id;
    RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION crm.booking_line_actual_cost(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.booking_line_actual_cost(uuid) TO crm_app;
COMMENT ON FUNCTION crm.booking_line_actual_cost(uuid) IS 'AA-1068 (crm-051, item crm-25): writes the actual_cost head of an agency line of the agency of app.tenant_id from its live (not void) supplier bill lines: their sum in the bills'' one currency (CRM51 bill_currency_mixed otherwise), frozen at the FX of the latest bill (fx_basis bill_date). Nothing when the head already has it; NULL when no live bill names the line (the P&L then ignores any older head). Owner / agent, or a job / seed actor without a member role (42501 margin_forbidden otherwise); an AA line CRM24; unknown line CRM13. SECURITY DEFINER; EXECUTE crm_app.';

-- ── 6. crm.v_departure_trip ──────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW crm.v_departure_trip WITH (security_invoker = true) AS
SELECT t.tenant_id, r.departure_ref, t.trip_id, t.stage, t.start_date,
       (t.party_adults + cardinality(t.party_child_ages))::integer AS pax
  FROM crm.trip t
 CROSS JOIN LATERAL (
        SELECT l.departure_id AS departure_ref
          FROM crm.booking_line l
         WHERE l.tenant_id = t.tenant_id AND l.trip_id = t.trip_id AND l.departure_id IS NOT NULL
           AND l.supplier_kind = 'aa' AND l.status = 'confirmed' AND l.deleted_at IS NULL
        UNION
        SELECT t.group_code WHERE t.group_code IS NOT NULL
       ) r
 -- Booked trips only: a quote sets a line's departure_id (planning), so a lead in inquiry / qualifying / proposal would
 -- otherwise take a share of the group's costs that the booked trips then miss. A cancelled trip takes no share.
 WHERE t.deleted_at IS NULL AND t.stage IN ('booked', 'pre_departure', 'travelling', 'completed');
REVOKE ALL ON crm.v_departure_trip FROM crm_app;
GRANT SELECT ON crm.v_departure_trip TO crm_app;
COMMENT ON VIEW crm.v_departure_trip IS 'AA-1068 (crm-051, item crm-32): the booked trips (stage booked, pre_departure, travelling or completed) on each departure ref (the departure_id of a confirmed AA line, or the trip''s group_code) with their pax (adults + children): the trips that share the departure''s costs. A lead that only has a quote for the departure, a lost or a cancelled trip is not on it. security_invoker.';

-- ── 7. crm.v_trip_pnl ────────────────────────────────────────────────────────────────────────────
-- Read per trip (WHERE trip_id = $1) or for the agency (the profit cube). Every amount in the agency's base currency
-- now (crm.tenant_settings.base_currency, default USD); a money row frozen in an earlier base currency is left out and
-- counted in lines_other_base. Invoices and refunds convert at crm.fx_resolve of their issue / receipt day (a day with
-- no rate within 30 days: left out, counted in revenue_unconverted).
CREATE OR REPLACE VIEW crm.v_trip_pnl WITH (security_invoker = true) AS
SELECT x.*,
       (x.aa_cost_base + x.agency_cost_base + x.cancellation_cost_base + x.departure_cost_base
        + x.partner_commission_base)::numeric(14,2) AS total_cost_base,
       (x.revenue_base + x.commission_income_base
        - (x.aa_cost_base + x.agency_cost_base + x.cancellation_cost_base + x.departure_cost_base
           + x.partner_commission_base))::numeric(14,2) AS margin_base,
       CASE WHEN x.revenue_base > 0 THEN
            round((x.revenue_base + x.commission_income_base
                   - (x.aa_cost_base + x.agency_cost_base + x.cancellation_cost_base + x.departure_cost_base
                      + x.partner_commission_base)) * 100 / x.revenue_base, 2)
       END AS margin_pct,
       round((x.revenue_base + x.commission_income_base
              - (x.aa_cost_base + x.agency_cost_base + x.cancellation_cost_base + x.departure_cost_base
                 + x.partner_commission_base)) / x.pax, 2) AS margin_per_pax_base
  FROM (
    SELECT t.tenant_id, t.trip_id, t.stage, t.start_date, t.owner_member_id, t.lead_source, t.group_code,
           b.base_currency,
           (t.party_adults + cardinality(t.party_child_ages))::integer AS pax,
           NULL::uuid AS sales_partner_id,
           r.revenue_sales_base, r.revenue_service_fee_base, r.revenue_cancellation_fee_base, r.refunds_base,
           (r.revenue_sales_base + r.revenue_service_fee_base + r.revenue_cancellation_fee_base
            - r.refunds_base)::numeric(14,2) AS revenue_base,
           r.revenue_unconverted, r.cancellation_charged,
           ln.aa_sell_base, ln.agency_sell_base,
           ln.aa_cost_quoted_base, ln.aa_cost_base, ln.aa_lines_invoiced, ln.aa_lines_mismatch,
           ln.agency_cost_planned_base, ln.agency_cost_base, ln.cost_variance_base, ln.lines_billed,
           ln.cancellation_cost_base, ln.commission_income_base, ln.lines_confirmed, ln.lines_planning,
           ln.lines_other_base,
           dp.departure_cost_base, dp.departure_costs,
           0::numeric(14,2) AS partner_commission_base
      FROM crm.trip t
     CROSS JOIN LATERAL (
            SELECT COALESCE((SELECT ts.base_currency::text FROM crm.tenant_settings ts
                              WHERE ts.tenant_id = t.tenant_id), 'USD') AS base_currency
           ) b
     -- The cancellation charge of a cancelled trip (crm.cancellation_charge, crm-049, one row per trip): once a trip
     -- is cancelled with a charge, what the client owes is the charge (fee = charge_amount), net of tax by the net share
     -- of the trip's issued invoices in the charge currency (none: 1), at the rate of the cancel day. It replaces the
     -- sale invoices, their refunds and the cancellation fee invoice (that invoice bills only the charge not covered by
     -- money kept, and a kept sale invoice may still show an unpaid rest), so no fee is counted twice. Service fee
     -- invoices still count. A waived charge is 0.
     LEFT JOIN LATERAL (
            SELECT true AS charged,
                   round(round(c.charge_amount * COALESCE(ns.share, 1), 2) * fx.rate, 2) AS fee_base
              FROM crm.cancellation_charge c
             CROSS JOIN LATERAL (
                    SELECT sum(i.subtotal_amount) / NULLIF(sum(i.total_amount), 0) AS share
                      FROM crm.invoice i
                     WHERE i.tenant_id = c.tenant_id AND i.trip_id = c.trip_id AND i.deleted_at IS NULL
                       AND i.issued_at IS NOT NULL AND i.kind::text <> 'service_fee' AND i.currency = c.currency
                   ) ns
              LEFT JOIN LATERAL crm.fx_resolve(c.currency::text, b.base_currency, c.created_at::date) fx ON true
             WHERE c.tenant_id = t.tenant_id AND c.trip_id = t.trip_id AND c.deleted_at IS NULL
           ) cc ON true
     -- Revenue: issued invoices (open, payment claimed, paid, paid but unfulfillable) net of tax; refunds net of tax
     -- (the refund times the invoice's net share). An invoice kind other than a service fee or a cancellation fee
     -- (deposit, balance, adjustment, instalment, any later kind) is a sale. A trip cancelled with a charge: the charge
     -- in place of its sales, their refunds and its cancellation fee invoices (above).
     CROSS JOIN LATERAL (
            SELECT COALESCE(sum(v.net_base) FILTER (
                       WHERE v.src = 'invoice' AND v.kind NOT IN ('service_fee', 'cancellation_fee') AND NOT v.charged),
                       0)::numeric(14,2) AS revenue_sales_base,
                   COALESCE(sum(v.net_base) FILTER (WHERE v.src = 'invoice' AND v.kind = 'service_fee'), 0)::numeric(14,2)
                       AS revenue_service_fee_base,
                   (CASE WHEN COALESCE(cc.charged, false) THEN COALESCE(cc.fee_base, 0)
                         ELSE COALESCE(sum(v.net_base) FILTER (WHERE v.src = 'invoice' AND v.kind = 'cancellation_fee'), 0)
                    END)::numeric(14,2) AS revenue_cancellation_fee_base,
                   COALESCE(sum(v.net_base) FILTER (
                       WHERE v.src = 'refund' AND (v.kind = 'service_fee' OR NOT v.charged)), 0)::numeric(14,2)
                       AS refunds_base,
                   ((count(*) FILTER (WHERE v.net_base IS NULL AND (v.kind = 'service_fee' OR NOT v.charged)))
                    + CASE WHEN COALESCE(cc.charged, false) AND cc.fee_base IS NULL THEN 1 ELSE 0 END)::integer
                       AS revenue_unconverted,
                   COALESCE(cc.charged, false) AS cancellation_charged
              FROM (
                    SELECT 'invoice'::text AS src, i.kind::text AS kind, round(i.subtotal_amount * fx.rate, 2) AS net_base,
                           COALESCE(cc.charged, false) AS charged
                      FROM crm.invoice i
                      LEFT JOIN LATERAL crm.fx_resolve(i.currency::text, b.base_currency, i.issue_date) fx ON true
                     WHERE i.tenant_id = t.tenant_id AND i.trip_id = t.trip_id AND i.deleted_at IS NULL
                       AND i.issued_at IS NOT NULL
                       AND i.status IN ('open', 'payment_claimed', 'paid', 'paid_unfulfillable')
                    UNION ALL
                    SELECT 'refund', i.kind::text,
                           round(round(p.amount * i.subtotal_amount / i.total_amount, 2) * fx.rate, 2),
                           COALESCE(cc.charged, false)
                      FROM crm.payment p
                      JOIN crm.invoice i ON i.tenant_id = p.tenant_id AND i.invoice_id = p.invoice_id
                      LEFT JOIN LATERAL crm.fx_resolve(p.currency::text, b.base_currency, p.received_on) fx ON true
                     WHERE p.tenant_id = t.tenant_id AND p.trip_id = t.trip_id AND p.entry_kind = 'refund'
                       AND i.deleted_at IS NULL AND i.issued_at IS NOT NULL
                       AND i.status IN ('open', 'payment_claimed', 'paid', 'paid_unfulfillable')
                   ) v
           ) r
     -- Costs from the booking lines (confirmed lines count; planning lines are pipeline, counted apart).
     CROSS JOIN LATERAL (
            SELECT COALESCE(sum(q.sell_base) FILTER (WHERE q.supplier_kind = 'aa' AND q.status = 'confirmed'), 0)::numeric(14,2)
                       AS aa_sell_base,
                   COALESCE(sum(q.sell_base) FILTER (WHERE q.supplier_kind = 'agency' AND q.status = 'confirmed'), 0)::numeric(14,2)
                       AS agency_sell_base,
                   COALESCE(sum(q.cost_base) FILTER (WHERE q.supplier_kind = 'aa' AND q.status = 'confirmed'), 0)::numeric(14,2)
                       AS aa_cost_quoted_base,
                   COALESCE(sum(q.aa_cost) FILTER (WHERE q.supplier_kind = 'aa' AND q.status = 'confirmed'), 0)::numeric(14,2)
                       AS aa_cost_base,
                   (count(*) FILTER (WHERE q.aa_invoiced AND q.status = 'confirmed'))::integer AS aa_lines_invoiced,
                   (count(*) FILTER (WHERE q.aa_mismatch AND q.status = 'confirmed'))::integer AS aa_lines_mismatch,
                   COALESCE(sum(q.cost_base) FILTER (WHERE q.supplier_kind = 'agency' AND q.status = 'confirmed'), 0)::numeric(14,2)
                       AS agency_cost_planned_base,
                   -- Billed: the actual cost (a cancelled line the supplier still billed counts too); else planned.
                   COALESCE(sum(CASE WHEN q.billed THEN q.actual_base ELSE q.cost_base END) FILTER (
                       WHERE q.supplier_kind = 'agency' AND (q.status = 'confirmed' OR (q.status = 'cancelled' AND q.billed))),
                       0)::numeric(14,2) AS agency_cost_base,
                   COALESCE(sum(q.actual_base - COALESCE(q.cost_base, 0)) FILTER (
                       WHERE q.supplier_kind = 'agency' AND q.billed AND q.status IN ('confirmed', 'cancelled')),
                       0)::numeric(14,2) AS cost_variance_base,
                   (count(*) FILTER (WHERE q.supplier_kind = 'agency' AND q.billed))::integer AS lines_billed,
                   COALESCE(sum(q.cancel_base), 0)::numeric(14,2) AS cancellation_cost_base,
                   COALESCE(sum(q.commission_base) FILTER (WHERE q.supplier_kind = 'agency' AND q.status = 'confirmed'),
                       0)::numeric(14,2) AS commission_income_base,
                   (count(*) FILTER (WHERE q.status = 'confirmed'))::integer AS lines_confirmed,
                   (count(*) FILTER (WHERE q.status = 'planning'))::integer AS lines_planning,
                   (count(*) FILTER (WHERE q.other_base))::integer AS lines_other_base
              FROM (
                    SELECT l.booking_line_id, l.supplier_kind, l.status, h.cost_base, h.sell_base, h.commission_base,
                           h.cancel_base, h.other_base,
                           (h.actual_base IS NOT NULL AND bill.live) AS billed, h.actual_base,
                           -- An AA booking billed in full: its invoiced amount at the quote rate, spread over the
                           -- booking's confirmed lines by their quoted cost (cumulative rounding in line id order, so
                           -- the shares add up to round(invoiced x rate, 2) once per booking).
                           CASE WHEN l.supplier_kind = 'aa' AND ai.complete AND ai.currency = h.cost_currency
                                     AND bk.currencies = 1 AND NOT bk.unquoted AND bk.tot_w > 0
                                     AND h.cost_rate IS NOT NULL
                                THEN round(ai.invoiced * h.cost_rate * bk.cum_w / bk.tot_w, 2)
                                     - round(ai.invoiced * h.cost_rate * (bk.cum_w - bk.w) / bk.tot_w, 2)
                                ELSE h.cost_base END AS aa_cost,
                           (l.supplier_kind = 'aa' AND COALESCE(ai.complete, false)) AS aa_invoiced,
                           -- The booking's invoiced sum against the sum of its lines' quoted cost (one currency).
                           (l.supplier_kind = 'aa' AND COALESCE(ai.complete, false)
                            AND (ai.currency IS DISTINCT FROM h.cost_currency
                                 OR bk.currencies IS DISTINCT FROM 1::bigint OR COALESCE(bk.unquoted, true)
                                 OR ai.invoiced IS DISTINCT FROM bk.quoted)) AS aa_mismatch
                      FROM crm.booking_line l
                     CROSS JOIN LATERAL (
                            SELECT max(m.amount_base) FILTER (WHERE m.kind = 'cost' AND m.base_currency = b.base_currency)
                                       AS cost_base,
                                   max(m.amount) FILTER (WHERE m.kind = 'cost') AS cost_amount,
                                   max(m.currency::text) FILTER (WHERE m.kind = 'cost') AS cost_currency,
                                   max(m.fx_rate) FILTER (WHERE m.kind = 'cost' AND m.base_currency = b.base_currency)
                                       AS cost_rate,
                                   max(m.amount_base) FILTER (WHERE m.kind = 'sell' AND m.base_currency = b.base_currency)
                                       AS sell_base,
                                   max(m.amount_base) FILTER (
                                       WHERE m.kind = 'actual_cost' AND m.base_currency = b.base_currency) AS actual_base,
                                   max(m.amount_base) FILTER (
                                       WHERE m.kind = 'commission_expected' AND m.base_currency = b.base_currency)
                                       AS commission_base,
                                   max(m.amount_base) FILTER (
                                       WHERE m.kind = 'cancellation_cost' AND m.base_currency = b.base_currency)
                                       AS cancel_base,
                                   COALESCE(bool_or(m.fx_rate IS NOT NULL AND m.base_currency <> b.base_currency), false)
                                       AS other_base
                              FROM crm.v_booking_line_money_current m
                             WHERE m.tenant_id = l.tenant_id AND m.booking_line_id = l.booking_line_id
                           ) h
                     CROSS JOIN LATERAL (
                            SELECT EXISTS (SELECT 1 FROM crm.supplier_bill_line sl
                                             JOIN crm.supplier_bill sb ON sb.supplier_bill_id = sl.supplier_bill_id
                                            WHERE sl.tenant_id = l.tenant_id AND sl.booking_line_id = l.booking_line_id
                                              AND sb.status <> 'void') AS live
                           ) bill
                      LEFT JOIN LATERAL (
                            SELECT c.currency::text AS currency, sum((e.value ->> 'amount')::numeric) AS invoiced,
                                   bool_or(COALESCE((e.value ->> 'complete')::boolean, false)) AS complete
                              FROM crm.aa_invoice_cache c
                             CROSS JOIN LATERAL jsonb_each(c.booking_amounts) e
                             WHERE c.tenant_id = l.tenant_id AND l.bk_booking_id IS NOT NULL
                               AND e.key = l.bk_booking_id AND c.invoice_kind = 'settlement' AND c.aa_status <> 'void'
                             GROUP BY c.currency
                             ORDER BY c.currency
                             LIMIT 1
                           ) ai ON true
                     -- The confirmed AA lines of the same AA booking (several lines of one accepted proposal share
                     -- one Booking booking): their quoted cost and this line's weight for the invoiced amount.
                      LEFT JOIN LATERAL (
                            SELECT g.quoted, g.currencies, g.unquoted,
                                   CASE WHEN g.quoted > 0 THEN h.cost_amount ELSE 1 END AS w,
                                   CASE WHEN g.quoted > 0 THEN g.cum_quoted ELSE g.cum_n END AS cum_w,
                                   CASE WHEN g.quoted > 0 THEN g.quoted ELSE g.n END AS tot_w
                              FROM (
                                    SELECT sum(oc.amount) AS quoted,
                                           sum(oc.amount) FILTER (WHERE o.booking_line_id <= l.booking_line_id)
                                               AS cum_quoted,
                                           count(*) AS n,
                                           count(*) FILTER (WHERE o.booking_line_id <= l.booking_line_id) AS cum_n,
                                           count(DISTINCT oc.currency) AS currencies,
                                           bool_or(oc.amount IS NULL) AS unquoted
                                      FROM crm.booking_line o
                                      LEFT JOIN crm.v_booking_line_money_current oc
                                        ON oc.tenant_id = o.tenant_id AND oc.booking_line_id = o.booking_line_id
                                       AND oc.kind = 'cost'
                                     WHERE o.tenant_id = l.tenant_id AND o.bk_booking_id = l.bk_booking_id
                                       AND o.supplier_kind = 'aa' AND o.status = 'confirmed' AND o.deleted_at IS NULL
                                   ) g
                             WHERE l.supplier_kind = 'aa' AND l.status = 'confirmed' AND l.bk_booking_id IS NOT NULL
                           ) bk ON true
                     WHERE l.tenant_id = t.tenant_id AND l.trip_id = t.trip_id AND l.deleted_at IS NULL
                   ) q
           ) ln
     -- The trip's share of its departures' costs: per_pax = amount x the trip's pax; per_departure = split by pax over
     -- the departure's booked trips (crm.v_departure_trip), by cumulative rounding in trip id order (the shares of the
     -- booked trips add up to the cost exactly; a lead with only a quote takes none).
     CROSS JOIN LATERAL (
            SELECT COALESCE(sum(CASE WHEN d.basis = 'per_pax' THEN round(d.amount_base * s.pax, 2)
                                     ELSE round(d.amount_base * s.cum_pax / s.total_pax, 2)
                                          - round(d.amount_base * (s.cum_pax - s.pax) / s.total_pax, 2) END), 0)::numeric(14,2)
                       AS departure_cost_base,
                   count(d.departure_cost_id)::integer AS departure_costs
              FROM crm.departure_cost d
             CROSS JOIN LATERAL (
                    SELECT (t.party_adults + cardinality(t.party_child_ages))::numeric AS pax,
                           sum(o.pax) AS total_pax,
                           sum(o.pax) FILTER (WHERE o.trip_id <= t.trip_id) AS cum_pax
                      FROM crm.v_departure_trip o
                     WHERE o.tenant_id = d.tenant_id AND o.departure_ref = d.departure_ref
                   ) s
             WHERE d.tenant_id = t.tenant_id AND d.base_currency = b.base_currency AND s.total_pax > 0
               AND EXISTS (SELECT 1 FROM crm.v_departure_trip me
                            WHERE me.tenant_id = t.tenant_id AND me.trip_id = t.trip_id
                              AND me.departure_ref = d.departure_ref)
           ) dp
     WHERE t.deleted_at IS NULL
  ) x;
REVOKE ALL ON crm.v_trip_pnl FROM crm_app;
GRANT SELECT ON crm.v_trip_pnl TO crm_app;
COMMENT ON VIEW crm.v_trip_pnl IS 'AA-1068 (crm-051, item crm-30): the profit of each live trip in the agency''s base currency: revenue_base = issued invoices (open, payment_claimed, paid, paid_unfulfillable) net of tax by kind (sales = every kind but service_fee and cancellation_fee) minus refunds net of tax, at crm.fx_resolve of the issue / receipt day; a trip cancelled with a charge (crm.cancellation_charge, crm-049) counts the charge net of tax at the cancel day''s rate in place of its sales, their refunds and its cancellation fee invoices (cancellation_charged); costs = AA lines (the quote''s frozen cost, or the AA settlement invoice of the booking once billed in full, crm.aa_invoice_cache, at the quote rate, spread over the booking''s confirmed lines by their quoted cost; aa_lines_mismatch = the confirmed AA lines of a booking billed in full at another amount or currency than the sum of its lines'' quotes) + agency lines (actual_cost while a live supplier bill names the line, else the planned cost) + AA cancellation fees (cancellation_cost) + the departure share (crm.departure_cost by pax over the booked trips of crm.v_departure_trip) + the sales partner commission (0 until crm-28); commission_income_base = the expected supplier commission of confirmed agency lines; margin_base = revenue + commission income - costs, margin_pct of revenue, margin_per_pax_base. Confirmed lines count, planning ones are counted apart. security_invoker: money rows reach owner / agent only (crm-014), so read it only through the margin-gated API.';

-- ── Post-checks ──────────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT has_table_privilege('crm_app', 'crm.supplier_bill', 'INSERT')
       OR NOT has_table_privilege('crm_app', 'crm.supplier_bill_line', 'INSERT')
       OR NOT has_table_privilege('crm_app', 'crm.aa_invoice_cache', 'UPDATE')
       OR NOT has_table_privilege('crm_app', 'crm.departure_cost', 'DELETE')
       OR NOT has_table_privilege('crm_app', 'crm.v_trip_pnl', 'SELECT')
       OR NOT has_table_privilege('crm_app', 'crm.v_departure_trip', 'SELECT') THEN
        RAISE EXCEPTION 'crm-051: crm_app is missing a privilege on the new objects';
    END IF;
    IF has_table_privilege('crm_app', 'crm.supplier_bill', 'DELETE')
       OR has_table_privilege('crm_app', 'crm.supplier_bill_line', 'UPDATE')
       OR has_table_privilege('crm_app', 'crm.supplier_bill_line', 'DELETE')
       OR has_column_privilege('crm_app', 'crm.supplier_bill', 'amount', 'UPDATE')
       OR has_table_privilege('crm_app', 'crm.booking_line_money', 'INSERT') THEN
        RAISE EXCEPTION 'crm-051: crm_app may change a recorded bill or write money rows directly';
    END IF;
    IF has_table_privilege('crm_support_reader', 'crm.supplier_bill', 'SELECT')
       OR has_table_privilege('crm_insights', 'crm.v_trip_pnl', 'SELECT')
       OR has_table_privilege('crm_ai_reader', 'crm.departure_cost', 'SELECT') THEN
        RAISE EXCEPTION 'crm-051: a reader role must not read the finance data';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-051', now(), 'AA-1068: CRM finance: crm.v_trip_pnl (profit per trip), crm.supplier_bill + supplier_bill_line (money kind actual_cost at bill FX, CRM51), crm.aa_invoice_cache (AA invoices of Booking 1.5), crm.departure_cost + crm.v_departure_trip (group costs split by pax), crm.trip.group_code')
ON CONFLICT (version) DO NOTHING;

COMMIT;
