-- Migration crm-024: AA-952 CRM-23 Module 7, slices 2 and 3 (design v3 group F, M7, R27; data-privacy-integrations
-- §2.7 invoice / payment / refund_request / payment_provider_account) — agency invoices (numbering, lines, tax, issue
-- and void) and payments against them (partial payments, refund requests with the §4.6 approval matrix, the agency's
-- own payment methods). The agency is always the merchant: money goes from the client to the agency's own account
-- (bank, cash, the agency's own provider account); no Adventure Asia account ever holds or moves it.
--
-- Owner: AA-Partner (api/migrations/024_crm_invoices_payments.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- DB Migrate applies (Migration Copy Guard). Key crm-024. crm.erase_subject below is the crm-023 text plus this file's
-- tenant tables; a later key that replaces it starts from THIS text. crm.erase_held is unchanged: every new row that
-- names a trip carries trip_id (crm.hold_trip covers it) and none names a traveller (the bill-to is read from the
-- trip's lead at render time, never copied). crm.trip_delete_blockers is unchanged: the API writes the invoice and
-- payment rows of crm.trip_commitment (kinds invoice / payment, crm-010), so a paid invoice or a succeeded or refunded
-- payment blocks a trip delete (has_money) and an open one does not (design §3.5). crm.lifecycle_purge_expired is
-- unchanged (crm-018).
--
-- What (DM-7: accounting records, "statutory exception, per the agency's jurisdiction", design §3.6; they leave with
-- their trip or agency through crm.erase_subject like every other tenant row):
--   1. crm.tenant_settings + the invoice settings (owner, Settings > Payments): invoice_prefix (default INV),
--      invoice_tax_label / invoice_tax_rate / invoice_tax_inclusive (default Tax, 0 %, inclusive), invoice_due_days
--      (default 7) and service_fee_enabled (default false, design Fix E3, R27).
--   2. crm.invoice_sequence (base template): one row per agency, last_number + 1 per issued invoice under the row lock
--      (gapless: a rolled-back issue rolls the number back); only +1 moves (crm.guard_invoice_sequence, CRM40).
--   3. crm.invoice (base template): kind deposit | balance (from a schedule row of the accepted proposal) |
--      service_fee | adjustment; status draft | open | payment_claimed | paid | paid_unfulfillable | void | expired
--      (design v3 §3.3 Fix A8; this key's code moves draft -> open -> paid, draft / open -> void); the number
--      (<prefix>-<6+ digits>) is given at issue; currency, subtotal + tax = total, the tax snapshot; one live invoice
--      per schedule row. Sealed once issued (crm.guard_sealed_row, CRM31); the issue checks the lines against the
--      totals (crm.guard_invoice, CRM39).
--   4. crm.invoice_line (base template): charge lines (quantity x unit amount = amount) and "included" lines (what the
--      invoice covers, from the trip's agency and AA booking lines: a title snapshot, no price: design §2.9 rule 3
--      never shows per-line prices or the B2B price); written only while the invoice is a draft (CRM39).
--   5. crm.payment (append-only, crm-016) + invoice_id, provider (manual | stripe | vn_gateway; the agency's own
--      account; only manual has code today), provider_ref (the agency's own reference, never card or bank data),
--      entry_kind payment | refund, refund_of (a refund names the payment it returns); schedule_id becomes nullable
--      (a service-fee invoice has no schedule row; schedule or invoice, at least one); payment_schedule_once_uq (one
--      payment per schedule row, crm-016) keeps its rule for the payments without an invoice only, so an invoice
--      takes partial payments.
--   6. crm.refund_request (base template): proposed -> approved | rejected, approved -> executed (the refund entry in
--      crm.payment); the approval follows the §4.6 matrix (an agent up to tenant_settings.refund_owner_threshold_base,
--      the owner any amount: the API). Sealed: the request once decided, the decision once executed (CRM31).
--   7. crm.payment_provider_account (base template): the agency's own payment methods (BYO, design §6.3): manual
--      (the pay-by instructions printed on its invoices, e.g. its own bank details) today; stripe (Connect Standard,
--      the agency's own account id, no secret) and vn_gateway later. One active account per provider.
--   8. crm.status_transition rows for invoice, refund_request and payment_provider_account.
--   9. crm.erase_subject (the crm-023 text) + refund_request (before payment: it names payments), invoice_line and
--      invoice (after payment: payments name invoices; before payment_schedule and proposal) in the trip and agency
--      scopes; payment_provider_account and invoice_sequence in the agency scope.
--   SQLSTATE: CRM39 (invoice_issued / invoice_empty / invoice_totals), CRM40 (sequence_step); the next key starts at
--   CRM41.
--
-- Class: contract (ADR 0017 §3: new constraints and columns on crm.payment and crm.tenant_settings, rows in
-- crm.status_transition, a replaced crm.erase_subject), so no `-- migrate: expand` header: MIG-4 order, this file's PR
-- first, the Infra copy, a manual DB Migrate apply, then the code PRs (invoices, then payments).
--
-- Order: after crm-023 (AA-993 G4b); Guard 0 refuses to run before it is registered (erase_subject builds on its text).
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL. Idempotent (IF NOT EXISTS, DROP …
-- IF EXISTS, CREATE OR REPLACE, ON CONFLICT DO NOTHING). Rollback: a forward crm- file (MIG-14); the code before
-- AA-952 slice 2 never reads the new tables and still writes crm.payment with a schedule row and the defaults of the
-- new columns (manual, payment), so it runs unchanged on this schema.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '15min';

-- ── Guard 0: runs as the owner, after crm-023 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-024: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-023') THEN
        RAISE EXCEPTION 'crm-024: crm-023 (AA-993 G4b dispatch attempt) lands first';
    END IF;
    IF to_regclass('crm.payment') IS NULL OR to_regclass('crm.payment_schedule') IS NULL
       OR to_regclass('crm.dispatch_attempt') IS NULL OR to_regclass('crm.tenant_settings') IS NULL
       OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint WHERE conrelid = 'crm.payment_schedule'::regclass
                        AND conname = 'payment_schedule_trip_uq')
       OR to_regprocedure('crm.erase_rows(text,text,uuid,uuid,boolean,text)') IS NULL
       OR to_regprocedure('crm.guard_sealed_row()') IS NULL OR to_regprocedure('crm.guard_held_change()') IS NULL
       OR to_regprocedure('crm.set_updated_at()') IS NULL THEN
        RAISE EXCEPTION 'crm-024: crm.payment / payment_schedule (crm-016), crm.dispatch_attempt (crm-023), crm.erase_rows (crm-010) or a guard function missing';
    END IF;
END $$;

-- ── 1. crm.tenant_settings: the invoice settings ─────────────────────────────────────────────────
ALTER TABLE crm.tenant_settings
    ADD COLUMN IF NOT EXISTS invoice_prefix TEXT NOT NULL DEFAULT 'INV',
    ADD COLUMN IF NOT EXISTS invoice_tax_label TEXT NOT NULL DEFAULT 'Tax',
    ADD COLUMN IF NOT EXISTS invoice_tax_rate NUMERIC(6, 3) NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS invoice_tax_inclusive BOOLEAN NOT NULL DEFAULT true,
    ADD COLUMN IF NOT EXISTS invoice_due_days SMALLINT NOT NULL DEFAULT 7,
    ADD COLUMN IF NOT EXISTS service_fee_enabled BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE crm.tenant_settings DROP CONSTRAINT IF EXISTS tenant_settings_invoice_chk;
ALTER TABLE crm.tenant_settings ADD CONSTRAINT tenant_settings_invoice_chk CHECK (
    invoice_prefix ~ '^[A-Z0-9][A-Z0-9-]{0,11}$'
    AND length(invoice_tax_label) BETWEEN 1 AND 24 AND invoice_tax_label !~ '[[:cntrl:]]'
    AND invoice_tax_rate >= 0 AND invoice_tax_rate <= 100
    AND invoice_due_days BETWEEN 0 AND 365
);
COMMENT ON COLUMN crm.tenant_settings.invoice_prefix IS 'AA-952 (crm-024): the agency''s invoice number prefix (A-Z, 0-9, -; default INV): numbers read <prefix>-<6+ digits>; a change applies to invoices issued afterwards';
COMMENT ON COLUMN crm.tenant_settings.invoice_tax_rate IS 'AA-952 (crm-024): the default tax rate in percent (0-100, default 0) a new invoice copies; the agency decides its tax, the CRM only prints it';
COMMENT ON COLUMN crm.tenant_settings.invoice_tax_inclusive IS 'AA-952 (crm-024): true (default) = amounts include the tax (the tax is shown inside the total); false = the tax is added on top. A deposit or balance invoice is always inclusive (it bills the amount the client accepted)';
COMMENT ON COLUMN crm.tenant_settings.service_fee_enabled IS 'AA-952 (crm-024, design Fix E3, R27): service-fee invoices allowed (default false)';

-- ── 2. crm.invoice_sequence ──────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.invoice_sequence (
    tenant_id    UUID PRIMARY KEY DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                 REFERENCES crm.tenant (tenant_id),
    last_number  BIGINT NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at   TIMESTAMPTZ,
    deleted_by   TEXT,
    purge_after  TIMESTAMPTZ,
    CONSTRAINT invoice_sequence_number_chk CHECK (last_number >= 1),
    CONSTRAINT invoice_sequence_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
COMMENT ON TABLE crm.invoice_sequence IS 'AA-952 (crm-024): the agency''s last issued invoice number. The issue runs INSERT (1) ON CONFLICT DO UPDATE last_number + 1 under the row lock, in the transaction that issues the invoice: gapless (a rollback gives the number back), serialised between members. Only +1 moves (crm.guard_invoice_sequence, CRM40). No personal data. Erased with its agency (crm.erase_subject)';

CREATE OR REPLACE FUNCTION crm.guard_invoice_sequence() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF current_user = 'crm_owner' AND current_setting('app.erasing', true) = 'on' THEN
        RETURN NEW;
    END IF;
    IF NEW.last_number IS DISTINCT FROM OLD.last_number + 1 OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id THEN
        RAISE EXCEPTION 'crm: sequence_step (an invoice number moves by one, never back or past a number)'
            USING ERRCODE = 'CRM40';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION crm.guard_invoice_sequence() FROM PUBLIC;
COMMENT ON FUNCTION crm.guard_invoice_sequence() IS 'AA-952 (crm-024): BEFORE UPDATE trigger on crm.invoice_sequence: last_number moves by exactly one (CRM40 sequence_step); crm.erase_subject (crm_owner with app.erasing on) passes.';

-- ── 3. crm.invoice ───────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.invoice (
    invoice_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                     REFERENCES crm.tenant (tenant_id),
    trip_id          UUID NOT NULL,
    kind             TEXT NOT NULL,
    status           TEXT NOT NULL DEFAULT 'draft',
    schedule_id      UUID,
    proposal_id      UUID,
    number_seq       BIGINT,
    number           TEXT,
    currency         CHAR(3) NOT NULL,
    subtotal_amount  NUMERIC(14, 2) NOT NULL DEFAULT 0,
    tax_amount       NUMERIC(14, 2) NOT NULL DEFAULT 0,
    total_amount     NUMERIC(14, 2) NOT NULL DEFAULT 0,
    tax_rate         NUMERIC(6, 3) NOT NULL DEFAULT 0,
    tax_label        TEXT NOT NULL DEFAULT 'Tax',
    tax_inclusive    BOOLEAN NOT NULL DEFAULT true,
    memo             TEXT,
    due_on           DATE,
    issue_date       DATE,
    issued_at        TIMESTAMPTZ,
    issued_by        TEXT,
    paid_at          TIMESTAMPTZ,
    voided_at        TIMESTAMPTZ,
    voided_by        TEXT,
    void_reason      TEXT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by       TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at       TIMESTAMPTZ,
    deleted_by       TEXT,
    purge_after      TIMESTAMPTZ,
    CONSTRAINT invoice_tenant_id_uq UNIQUE (tenant_id, invoice_id),
    CONSTRAINT invoice_trip_uq UNIQUE (tenant_id, invoice_id, trip_id),
    CONSTRAINT invoice_number_seq_uq UNIQUE (tenant_id, number_seq),
    CONSTRAINT invoice_number_uq UNIQUE (tenant_id, number),
    -- Same-agency keys (a foreign key check ignores RLS). No ON DELETE action: crm.erase_subject deletes the invoices
    -- (after their payments, before the schedule rows, the proposals and the trip).
    CONSTRAINT invoice_trip_fk FOREIGN KEY (tenant_id, trip_id) REFERENCES crm.trip (tenant_id, trip_id),
    CONSTRAINT invoice_schedule_fk FOREIGN KEY (tenant_id, schedule_id, trip_id)
        REFERENCES crm.payment_schedule (tenant_id, schedule_id, trip_id),
    CONSTRAINT invoice_proposal_fk FOREIGN KEY (tenant_id, proposal_id, trip_id)
        REFERENCES crm.proposal (tenant_id, proposal_id, trip_id),
    CONSTRAINT invoice_kind_chk CHECK (kind IN ('deposit', 'balance', 'service_fee', 'adjustment')),
    CONSTRAINT invoice_schedule_chk CHECK (
        (kind IN ('deposit', 'balance')) = (schedule_id IS NOT NULL)
        AND (schedule_id IS NULL OR (proposal_id IS NOT NULL AND tax_inclusive))
    ),
    CONSTRAINT invoice_status_chk CHECK (status IN (
        'draft', 'open', 'payment_claimed', 'paid', 'paid_unfulfillable', 'void', 'expired'
    )),
    CONSTRAINT invoice_currency_chk CHECK (currency ~ '^[A-Z]{3}$'),
    CONSTRAINT invoice_amounts_chk CHECK (
        subtotal_amount >= 0 AND tax_amount >= 0 AND total_amount = subtotal_amount + tax_amount
        AND total_amount <= 999999999999.99
    ),
    CONSTRAINT invoice_tax_chk CHECK (
        tax_rate >= 0 AND tax_rate <= 100
        AND length(tax_label) BETWEEN 1 AND 24 AND tax_label !~ '[[:cntrl:]]'
    ),
    CONSTRAINT invoice_issue_chk CHECK (
        (number IS NULL) = (issued_at IS NULL) AND (number_seq IS NULL) = (issued_at IS NULL)
        AND (issue_date IS NULL) = (issued_at IS NULL) AND (issued_by IS NULL) = (issued_at IS NULL)
        AND (status <> 'draft' OR issued_at IS NULL)
        AND (status IN ('draft', 'void') OR issued_at IS NOT NULL)
        AND (issued_at IS NULL OR (due_on IS NOT NULL AND due_on >= issue_date AND total_amount > 0))
        AND (number IS NULL OR (number ~ '^[A-Z0-9][A-Z0-9-]{0,11}-[0-9]{6,}$' AND number_seq >= 1))
    ),
    CONSTRAINT invoice_paid_chk CHECK ((paid_at IS NOT NULL) = (status IN ('paid', 'paid_unfulfillable'))),
    CONSTRAINT invoice_void_chk CHECK (
        (status = 'void') = (voided_at IS NOT NULL) AND (voided_at IS NULL) = (voided_by IS NULL)
        AND (voided_at IS NULL) = (void_reason IS NULL)
        AND (void_reason IS NULL OR (length(void_reason) BETWEEN 1 AND 500))
    ),
    CONSTRAINT invoice_memo_chk CHECK (memo IS NULL OR length(memo) BETWEEN 1 AND 2000),
    CONSTRAINT invoice_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
-- One live invoice per schedule row (a void one frees it for a corrected invoice).
CREATE UNIQUE INDEX IF NOT EXISTS invoice_schedule_live_uq ON crm.invoice (tenant_id, schedule_id)
    WHERE schedule_id IS NOT NULL AND status <> 'void';
CREATE INDEX IF NOT EXISTS invoice_trip_idx ON crm.invoice (tenant_id, trip_id);
CREATE INDEX IF NOT EXISTS invoice_receivables_idx ON crm.invoice (tenant_id, status, due_on);
COMMENT ON TABLE crm.invoice IS 'AA-952 (crm-024; design v3 group F, M7, R27): an invoice the agency issues to its client for a trip. kind deposit / balance (one schedule row of the accepted proposal: its amount, currency and due date; always tax-inclusive), service_fee (tenant_settings.service_fee_enabled), adjustment. draft (no number, lines editable) -> open (issued: the number <prefix>-<6+ digits> from crm.invoice_sequence, issue date, due date; sealed, CRM31) -> paid (the payments reach the total) | void (with a reason; a paid invoice is never void: refunds go through crm.refund_request). payment_claimed, paid_unfulfillable and expired are the card / bank-transfer states of design Fix A8 (C31), unused by this key''s code. The bill-to is the trip''s lead, read at render time (no traveller column, no copied name). Amounts are the client''s sell amounts (no margin). Retention: accounting record (design §3.6), with its trip / agency.';
COMMENT ON COLUMN crm.invoice.number IS 'AA-952 (crm-024): <invoice_prefix at issue>-<number_seq, 6+ digits>, unique per agency; NULL while a draft';
COMMENT ON COLUMN crm.invoice.tax_inclusive IS 'AA-952 (crm-024): true = the line amounts include the tax (total = the line sum, tax = total x rate / (100 + rate)); false = subtotal = the line sum, tax = subtotal x rate / 100';

CREATE OR REPLACE FUNCTION crm.guard_invoice() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_sum numeric;
    v_lines int;
BEGIN
    IF current_user = 'crm_owner' AND current_setting('app.erasing', true) = 'on' THEN
        RETURN NEW;
    END IF;
    IF OLD.status = 'draft' AND NEW.status = 'open' THEN
        SELECT count(*), coalesce(sum(l.amount), 0) INTO v_lines, v_sum
          FROM crm.invoice_line l WHERE l.invoice_id = NEW.invoice_id AND l.kind = 'charge';
        IF v_lines = 0 THEN
            RAISE EXCEPTION 'crm: invoice_empty (an invoice is issued with one charge line or more)'
                USING ERRCODE = 'CRM39';
        END IF;
        IF (NEW.tax_inclusive AND NEW.total_amount <> v_sum) OR (NOT NEW.tax_inclusive AND NEW.subtotal_amount <> v_sum) THEN
            RAISE EXCEPTION 'crm: invoice_totals (the totals do not match the charge lines, %)', v_sum
                USING ERRCODE = 'CRM39';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION crm.guard_invoice() FROM PUBLIC;
COMMENT ON FUNCTION crm.guard_invoice() IS 'AA-952 (crm-024): BEFORE UPDATE trigger on crm.invoice: the issue (draft -> open) needs one charge line or more (CRM39 invoice_empty) whose sum is the total (tax-inclusive) or the subtotal (tax on top) (CRM39 invoice_totals); crm.erase_subject passes.';

-- ── 4. crm.invoice_line ──────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.invoice_line (
    line_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id    UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                 REFERENCES crm.tenant (tenant_id),
    invoice_id   UUID NOT NULL,
    trip_id      UUID NOT NULL,
    position     SMALLINT NOT NULL,
    kind         TEXT NOT NULL,
    source       TEXT NOT NULL,
    description  TEXT NOT NULL,
    quantity     NUMERIC(10, 2),
    unit_amount  NUMERIC(14, 2),
    amount       NUMERIC(14, 2),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at   TIMESTAMPTZ,
    deleted_by   TEXT,
    purge_after  TIMESTAMPTZ,
    CONSTRAINT invoice_line_position_uq UNIQUE (tenant_id, invoice_id, position),
    CONSTRAINT invoice_line_invoice_fk FOREIGN KEY (tenant_id, invoice_id, trip_id)
        REFERENCES crm.invoice (tenant_id, invoice_id, trip_id),
    CONSTRAINT invoice_line_kind_chk CHECK (kind IN ('charge', 'included')),
    CONSTRAINT invoice_line_source_chk CHECK (source IN ('schedule', 'agency_line', 'aa_line', 'service_fee', 'manual')),
    CONSTRAINT invoice_line_position_chk CHECK (position BETWEEN 1 AND 200),
    CONSTRAINT invoice_line_description_chk CHECK (
        length(description) BETWEEN 1 AND 300 AND description !~ '[[:cntrl:]]'
    ),
    CONSTRAINT invoice_line_amount_chk CHECK (
        (kind = 'charge' AND quantity > 0 AND quantity <= 9999 AND unit_amount > 0 AND amount > 0
         AND amount = round(quantity * unit_amount, 2))
        OR (kind = 'included' AND quantity IS NULL AND unit_amount IS NULL AND amount IS NULL
            AND source IN ('agency_line', 'aa_line', 'manual'))
    ),
    CONSTRAINT invoice_line_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE INDEX IF NOT EXISTS invoice_line_invoice_idx ON crm.invoice_line (tenant_id, invoice_id);
CREATE INDEX IF NOT EXISTS invoice_line_trip_idx ON crm.invoice_line (tenant_id, trip_id);
COMMENT ON TABLE crm.invoice_line IS 'AA-952 (crm-024): the lines of an invoice. charge = quantity x unit amount (the schedule amount, a service fee or a manual charge); included = what the invoice covers (a title snapshot of the trip''s agency and AA booking lines, no price: design §2.9 rule 3). Written (insert, update, delete) only while its invoice is a draft (crm.guard_invoice_line, CRM39 invoice_issued). No personal data by design (product titles and the agency''s own wording). Erased with its invoice';

CREATE OR REPLACE FUNCTION crm.guard_invoice_line() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_status text;
    v_id uuid;
BEGIN
    IF current_user = 'crm_owner' AND current_setting('app.erasing', true) = 'on' THEN
        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    END IF;
    FOREACH v_id IN ARRAY CASE TG_OP WHEN 'INSERT' THEN ARRAY[NEW.invoice_id] WHEN 'DELETE' THEN ARRAY[OLD.invoice_id]
                              ELSE ARRAY[OLD.invoice_id, NEW.invoice_id] END LOOP
        -- FOR SHARE: an issue (UPDATE of the invoice row) waits for this line write, or this waits for the issue.
        SELECT i.status INTO v_status FROM crm.invoice i WHERE i.invoice_id = v_id FOR SHARE;
        IF v_status IS DISTINCT FROM 'draft' THEN
            RAISE EXCEPTION 'crm: invoice_issued (the lines of an issued or void invoice never change)'
                USING ERRCODE = 'CRM39';
        END IF;
    END LOOP;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;
REVOKE ALL ON FUNCTION crm.guard_invoice_line() FROM PUBLIC;
COMMENT ON FUNCTION crm.guard_invoice_line() IS 'AA-952 (crm-024): BEFORE INSERT OR UPDATE OR DELETE trigger on crm.invoice_line: only the lines of a draft invoice change (CRM39 invoice_issued; the invoice row is read FOR SHARE, so an issue and a line write serialise); crm.erase_subject passes.';

-- ── 5. crm.payment: invoices, providers, refunds ─────────────────────────────────────────────────
ALTER TABLE crm.payment
    ADD COLUMN IF NOT EXISTS invoice_id UUID,
    ADD COLUMN IF NOT EXISTS provider TEXT NOT NULL DEFAULT 'manual',
    ADD COLUMN IF NOT EXISTS provider_ref TEXT,
    ADD COLUMN IF NOT EXISTS entry_kind TEXT NOT NULL DEFAULT 'payment',
    ADD COLUMN IF NOT EXISTS refund_of UUID;
ALTER TABLE crm.payment ALTER COLUMN schedule_id DROP NOT NULL;
ALTER TABLE crm.payment DROP CONSTRAINT IF EXISTS payment_schedule_once_uq;
DROP INDEX IF EXISTS crm.payment_schedule_once_uq;
-- crm-016's rule for the payments without an invoice (the schedule's "Mark paid"): one per schedule row.
CREATE UNIQUE INDEX IF NOT EXISTS payment_schedule_once_uq ON crm.payment (tenant_id, schedule_id)
    WHERE invoice_id IS NULL AND entry_kind = 'payment';
ALTER TABLE crm.payment DROP CONSTRAINT IF EXISTS payment_invoice_fk;
ALTER TABLE crm.payment ADD CONSTRAINT payment_invoice_fk FOREIGN KEY (tenant_id, invoice_id, trip_id)
    REFERENCES crm.invoice (tenant_id, invoice_id, trip_id);
ALTER TABLE crm.payment DROP CONSTRAINT IF EXISTS payment_refund_of_fk;
ALTER TABLE crm.payment ADD CONSTRAINT payment_refund_of_fk FOREIGN KEY (tenant_id, refund_of)
    REFERENCES crm.payment (tenant_id, payment_id);
ALTER TABLE crm.payment DROP CONSTRAINT IF EXISTS payment_entry_chk;
ALTER TABLE crm.payment ADD CONSTRAINT payment_entry_chk CHECK (
    entry_kind IN ('payment', 'refund')
    AND (entry_kind = 'refund') = (refund_of IS NOT NULL)
    AND (entry_kind = 'payment' OR invoice_id IS NOT NULL)
    AND (schedule_id IS NOT NULL OR invoice_id IS NOT NULL)
);
ALTER TABLE crm.payment DROP CONSTRAINT IF EXISTS payment_provider_chk;
ALTER TABLE crm.payment ADD CONSTRAINT payment_provider_chk CHECK (
    provider IN ('manual', 'stripe', 'vn_gateway')
    AND (provider_ref IS NULL OR (length(provider_ref) BETWEEN 1 AND 120 AND provider_ref !~ '[[:cntrl:]]'))
);
CREATE INDEX IF NOT EXISTS payment_invoice_idx ON crm.payment (tenant_id, invoice_id) WHERE invoice_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS payment_refund_of_idx ON crm.payment (tenant_id, refund_of) WHERE refund_of IS NOT NULL;
COMMENT ON TABLE crm.payment IS 'AA-946 (crm-016; design v3 group F, M7 manual): money the agency received from its client, or returned to it. AA-952 (crm-024): a payment against an invoice (partial payments allowed; schedule_id = the invoice''s schedule row, NULL for a service-fee or adjustment invoice) or, as in crm-016, against a schedule row without an invoice (one per row, payment_schedule_once_uq); entry_kind refund = money returned (refund_of = the payment it returns, written only by the execution of an approved crm.refund_request). provider = the agency''s own account kind (manual today); provider_ref = the agency''s own reference, never card or bank data. Append-only (crm.ledger_append_only: DELETE only inside crm.erase_subject). The trip''s delete block reads the trip_commitment row (kind payment) the API writes with it.';
COMMENT ON COLUMN crm.payment.entry_kind IS 'AA-952 (crm-024): payment (money in, the default) | refund (money returned, refund_of names the payment; amount positive)';
COMMENT ON COLUMN crm.payment.provider IS 'AA-952 (crm-024): the kind of the agency''s own account the money moved through: manual (bank transfer, cash, a card terminal of its own: recorded by a member), stripe / vn_gateway (the agency''s own provider account, later). Never an Adventure Asia account';

-- ── 6. crm.refund_request ────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.refund_request (
    refund_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id          UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                       REFERENCES crm.tenant (tenant_id),
    trip_id            UUID NOT NULL,
    invoice_id         UUID NOT NULL,
    payment_id         UUID NOT NULL,
    amount             NUMERIC(14, 2) NOT NULL,
    currency           CHAR(3) NOT NULL,
    reason             TEXT NOT NULL,
    status             TEXT NOT NULL DEFAULT 'proposed',
    requested_by       TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    decided_by         TEXT,
    decided_at         TIMESTAMPTZ,
    decision_note      TEXT,
    base_currency      CHAR(3),
    base_amount        NUMERIC(14, 2),
    executed_at        TIMESTAMPTZ,
    refund_payment_id  UUID,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by         TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at         TIMESTAMPTZ,
    deleted_by         TEXT,
    purge_after        TIMESTAMPTZ,
    CONSTRAINT refund_request_tenant_id_uq UNIQUE (tenant_id, refund_id),
    CONSTRAINT refund_request_invoice_fk FOREIGN KEY (tenant_id, invoice_id, trip_id)
        REFERENCES crm.invoice (tenant_id, invoice_id, trip_id),
    CONSTRAINT refund_request_payment_fk FOREIGN KEY (tenant_id, payment_id) REFERENCES crm.payment (tenant_id, payment_id),
    CONSTRAINT refund_request_refund_payment_fk FOREIGN KEY (tenant_id, refund_payment_id)
        REFERENCES crm.payment (tenant_id, payment_id),
    CONSTRAINT refund_request_amount_chk CHECK (amount > 0 AND currency ~ '^[A-Z]{3}$'),
    CONSTRAINT refund_request_reason_chk CHECK (length(reason) BETWEEN 1 AND 500),
    CONSTRAINT refund_request_status_chk CHECK (status IN ('proposed', 'approved', 'rejected', 'executed')),
    CONSTRAINT refund_request_decision_chk CHECK (
        (status = 'proposed') = (decided_at IS NULL) AND (decided_at IS NULL) = (decided_by IS NULL)
        AND (decision_note IS NULL OR length(decision_note) BETWEEN 1 AND 500)
        AND (base_amount IS NULL) = (base_currency IS NULL)
        AND (base_currency IS NULL OR base_currency ~ '^[A-Z]{3}$')
    ),
    CONSTRAINT refund_request_executed_chk CHECK (
        (status = 'executed') = (executed_at IS NOT NULL) AND (executed_at IS NULL) = (refund_payment_id IS NULL)
    ),
    CONSTRAINT refund_request_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE INDEX IF NOT EXISTS refund_request_status_idx ON crm.refund_request (tenant_id, status);
CREATE INDEX IF NOT EXISTS refund_request_payment_idx ON crm.refund_request (tenant_id, payment_id);
CREATE INDEX IF NOT EXISTS refund_request_trip_idx ON crm.refund_request (tenant_id, trip_id);
COMMENT ON TABLE crm.refund_request IS 'AA-952 (crm-024; design v3 group F, §4.6, C12, C31): a refund of (part of) one payment. proposed (owner / agent) -> approved (the owner any amount, an agent up to tenant_settings.refund_owner_threshold_base, judged on base_amount = the amount in the base currency at the decision; the API) | rejected -> executed (the refund entry in crm.payment, refund_payment_id: for a manual account, the member records the money returned outside the CRM; a provider account refunds through its own API, later). The request is sealed once decided, the decision once executed (CRM31). Ids, amounts and the agency''s own reason: no personal data by design. Erased with its trip / agency (before crm.payment)';

-- ── 7. crm.payment_provider_account ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.payment_provider_account (
    account_id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id            UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                         REFERENCES crm.tenant (tenant_id),
    provider             TEXT NOT NULL,
    status               TEXT NOT NULL DEFAULT 'active',
    display_name         TEXT NOT NULL,
    instructions         TEXT,
    external_account_id  TEXT,
    default_currency     CHAR(3),
    charges_enabled      BOOLEAN NOT NULL DEFAULT false,
    connected_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    disconnected_at      TIMESTAMPTZ,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by           TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at           TIMESTAMPTZ,
    deleted_by           TEXT,
    purge_after          TIMESTAMPTZ,
    CONSTRAINT payment_provider_account_provider_chk CHECK (provider IN ('manual', 'stripe', 'vn_gateway')),
    CONSTRAINT payment_provider_account_status_chk CHECK (
        status IN ('active', 'disconnected') AND (status = 'disconnected') = (disconnected_at IS NOT NULL)
    ),
    CONSTRAINT payment_provider_account_text_chk CHECK (
        length(display_name) BETWEEN 1 AND 80 AND display_name !~ '[[:cntrl:]]'
        AND (instructions IS NULL OR length(instructions) BETWEEN 1 AND 2000)
        AND (default_currency IS NULL OR default_currency ~ '^[A-Z]{3}$')
    ),
    -- A manual account has no external id; a provider account names the agency's own account there (no secret).
    CONSTRAINT payment_provider_account_external_chk CHECK (
        (provider = 'manual') = (external_account_id IS NULL)
        AND (external_account_id IS NULL OR external_account_id ~ '^[A-Za-z0-9_-]{3,64}$')
        AND (provider <> 'manual' OR NOT charges_enabled)
    ),
    CONSTRAINT payment_provider_account_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS payment_provider_account_live_uq ON crm.payment_provider_account (tenant_id, provider)
    WHERE status = 'active' AND deleted_at IS NULL;
COMMENT ON TABLE crm.payment_provider_account IS 'AA-952 (crm-024; design v3 §6.3, D10 a, BYO): the agency''s own payment methods. manual: how a client pays the agency (instructions printed on its invoices, e.g. its own bank details; payments are recorded by a member); stripe (Connect Standard on the agency''s own account: external_account_id, charges_enabled, no secret, the platform key + Stripe-Account header) and vn_gateway are later. One active account per provider. The agency is the merchant of record; no Adventure Asia account ever holds the money. Owner-only (PAYMENT_SETTINGS, the API). Erased with its agency';

-- ── 8. Status moves, RLS, grants, triggers ───────────────────────────────────────────────────────
INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('invoice', 'draft', 'open'),
    ('invoice', 'draft', 'void'),
    ('invoice', 'open', 'void'),
    ('invoice', 'open', 'paid'),
    ('invoice', 'open', 'payment_claimed'),
    ('invoice', 'open', 'expired'),
    ('invoice', 'open', 'paid_unfulfillable'),
    ('invoice', 'payment_claimed', 'open'),
    ('invoice', 'payment_claimed', 'paid'),
    ('invoice', 'payment_claimed', 'paid_unfulfillable'),
    ('invoice', 'expired', 'open'),
    ('invoice', 'expired', 'void'),
    ('refund_request', 'proposed', 'approved'),
    ('refund_request', 'proposed', 'rejected'),
    ('refund_request', 'approved', 'executed'),
    ('payment_provider_account', 'active', 'disconnected'),
    ('payment_provider_account', 'disconnected', 'active')
ON CONFLICT DO NOTHING;

DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['invoice_sequence', 'invoice', 'invoice_line', 'refund_request',
                             'payment_provider_account'] LOOP
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
        -- crm_app reads and writes; it never truncates, and deletes only draft invoice lines (the guard above).
        EXECUTE format('REVOKE TRUNCATE ON crm.%I FROM crm_app', t);
        IF t <> 'invoice_line' THEN
            EXECUTE format('REVOKE DELETE ON crm.%I FROM crm_app', t);
            EXECUTE format('GRANT SELECT, INSERT, UPDATE ON crm.%I TO crm_app', t);
        ELSE
            EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON crm.%I TO crm_app', t);
        END IF;
    END LOOP;
    FOREACH t IN ARRAY ARRAY['invoice', 'refund_request', 'payment_provider_account'] LOOP
        EXECUTE format(
            'CREATE OR REPLACE TRIGGER %I BEFORE UPDATE OF status ON crm.%I '
            'FOR EACH ROW EXECUTE FUNCTION crm.enforce_status_transition()', t || '_status_transition', t);
    END LOOP;
    EXECUTE 'CREATE OR REPLACE TRIGGER invoice_sequence_step BEFORE UPDATE ON crm.invoice_sequence '
            'FOR EACH ROW EXECUTE FUNCTION crm.guard_invoice_sequence()';
    EXECUTE 'CREATE OR REPLACE TRIGGER invoice_issue_check BEFORE UPDATE ON crm.invoice '
            'FOR EACH ROW EXECUTE FUNCTION crm.guard_invoice()';
    EXECUTE 'CREATE OR REPLACE TRIGGER invoice_line_draft_only BEFORE INSERT OR UPDATE OR DELETE ON crm.invoice_line '
            'FOR EACH ROW EXECUTE FUNCTION crm.guard_invoice_line()';
    -- Sealed rows (CRM31): an issued invoice keeps its content; a decided refund request keeps the request and the
    -- decision, an executed one its execution.
    EXECUTE 'CREATE OR REPLACE TRIGGER invoice_sealed BEFORE UPDATE ON crm.invoice FOR EACH ROW '
            'EXECUTE FUNCTION crm.guard_sealed_row(''draft'', ''trip_id'', ''kind'', ''schedule_id'', ''proposal_id'', '
            '''currency'', ''subtotal_amount'', ''tax_amount'', ''total_amount'', ''tax_rate'', ''tax_label'', '
            '''tax_inclusive'', ''memo'', ''due_on'', ''number_seq'', ''number'', ''issue_date'', ''issued_at'', '
            '''issued_by'', ''tenant_id'')';
    EXECUTE 'CREATE OR REPLACE TRIGGER refund_request_sealed BEFORE UPDATE ON crm.refund_request FOR EACH ROW '
            'EXECUTE FUNCTION crm.guard_sealed_row(''proposed'', ''trip_id'', ''invoice_id'', ''payment_id'', '
            '''amount'', ''currency'', ''reason'', ''requested_by'', ''decided_by'', ''decided_at'', '
            '''decision_note'', ''base_currency'', ''base_amount'', ''tenant_id'')';
    EXECUTE 'CREATE OR REPLACE TRIGGER refund_request_execution_sealed BEFORE UPDATE ON crm.refund_request FOR EACH ROW '
            'EXECUTE FUNCTION crm.guard_sealed_row(''approved'', ''executed_at'', ''refund_payment_id'')';
    -- Hold rule 4h: rows that name a trip follow its hold; the agency-level rows follow the agency hold.
    FOREACH t IN ARRAY ARRAY['invoice', 'invoice_line', 'refund_request'] LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON crm.%I', t || '_hold_guard', t);
        EXECUTE format('CREATE TRIGGER %I BEFORE DELETE OR UPDATE ON crm.%I FOR EACH ROW '
                       'EXECUTE FUNCTION crm.guard_held_change(''trip_id'')', t || '_hold_guard', t);
    END LOOP;
    FOREACH t IN ARRAY ARRAY['invoice_sequence', 'payment_provider_account'] LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON crm.%I', t || '_hold_guard', t);
        EXECUTE format('CREATE TRIGGER %I BEFORE DELETE OR UPDATE ON crm.%I FOR EACH ROW '
                       'EXECUTE FUNCTION crm.guard_held_change()', t || '_hold_guard', t);
    END LOOP;
END $$;

-- ── 9. crm.erase_subject: the crm-023 text plus the invoice and payment tables ──────────────────
-- A later key that replaces it starts from THIS text.
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
    -- the lifecycle counts and the holds (ids and codes only).
    c_keep CONSTANT text[] := ARRAY['tenant', 'tenant_key', 'audit_event', 'audit_export_tenant',
                                    'audit_export_manifest', 'erasure_request', 'lifecycle_run', 'legal_hold'];
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
        FOREACH v_step SLICE 1 IN ARRAY ARRAY[
            ['proposal', 'accepted_name_enc IS NOT NULL AND link_id IN (SELECT l.link_id FROM crm.client_link l '
                         'WHERE l.traveler_id = $1)', 'accepted_name_enc = NULL, accepted_name_erased_at = now()'],
            ['signature_request', 'traveler_id = $1', ''],
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
        FOREACH v_step SLICE 1 IN ARRAY ARRAY[
            ['membership_inbox', ''], ['inbox_events', ''], ['booking_feed_state', ''], ['metric_event', ''],
            ['signature_request', ''], ['otp_challenge', ''], ['traveler_access', ''],
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
            ['integration_credential', ''], ['fx_rate_override', ''],
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

COMMENT ON FUNCTION crm.erase_subject(text, uuid, uuid, boolean) IS 'AA-942 (crm-010, design §4.10, Fix B16), extended by AA-943 (crm-012) to client_link and meeting_slot, by AA-978 (crm-013) to membership_inbox (agency scope), by AA-944 (crm-014) to the ledger (trip and agency scopes: booking_line_money, booking_line; agency scope: agency_supplier, fx_rate_override; new scopes booking_line and agency_supplier for the trash purge), by AA-945 (crm-015) to mail (trip, traveller and agency scopes: message, conversation; agency scope: saved_reply, mail_import, ingest_address, channel_account; new scope conversation for the trash purge), by AA-946 (crm-016) to the lifecycle tables (trip and agency scopes: signature_request, otp_challenge, traveler_access, payment, payment_schedule, proposal; traveller scope: signature_request, otp_challenge, traveler_access, and the typed acceptance name of the proposals their links carried (accepted_name_enc := NULL); agency scope: agreement_doc) by AA-947 (crm-017) to the AA lines (trip, booking_line and agency scopes: aa_request; agency scope: inbox_events, booking_feed_state) by AA-949 (crm-019) to the proposal builder (trip and agency scopes: selection, option_rule, option, option_block, proposal_day) by AA-950 (crm-021) to crm.metric_event (trip and agency scopes) by AA-951 (crm-022) to crm.prep_pack_selection (trip and agency scopes) and crm.message_template (agency scope) by AA-993 G4b (crm-023) to crm.dispatch_attempt (trip, traveller and agency scopes, before crm.dispatch_queue) and by AA-952 (crm-024) to the invoices and payments (trip and agency scopes: crm.refund_request before crm.payment, crm.invoice_line and crm.invoice after it and before crm.payment_schedule; agency scope: crm.payment_provider_account, crm.invoice_sequence): the only hard-delete path of agency data. Scopes trip, traveler (needs the decrypted F2 profile token), task, note, document, relation, booking_line, agency_supplier, conversation, tenant (status offboarding, except a dry run; every tenant table except the keep list). Used by the trash purge and by erasure / offboarding (which skip the trash). Refuses: CRM10 legal_hold (the hold rule: any held row among those the erase would delete or update, crm.erase_held), CRM11 delete_blocked, CRM12 traveler_on_trip, CRM13 subject_not_found, CRM14 tenant_not_offboarding, CRM15 profile token, CRM16 erase_incomplete, CRM22 the Adventure Asia supplier row, CRM27 a supplier lines name. Never touches audit_event. Takes LOCK TABLE crm.legal_hold IN SHARE MODE first (serialised with hold placement). EXECUTE: crm_eraser only (SET LOCAL ROLE inside the lifecycle context).';


-- ── Guard 1: the shape this file promises ────────────────────────────────────────────────────────
DO $$
DECLARE
    t text;
    r text;
    p text;
BEGIN
    FOREACH t IN ARRAY ARRAY['invoice_sequence', 'invoice', 'invoice_line', 'refund_request',
                             'payment_provider_account'] LOOP
        IF NOT (SELECT relrowsecurity AND relforcerowsecurity FROM pg_catalog.pg_class
                 WHERE oid = ('crm.' || t)::regclass) THEN
            RAISE EXCEPTION 'crm-024: crm.% must have ENABLE + FORCE row level security', t;
        END IF;
        FOREACH r IN ARRAY ARRAY['crm_ai_reader', 'crm_insights', 'crm_support_reader', 'crm_eraser'] LOOP
            FOREACH p IN ARRAY ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'] LOOP
                IF pg_catalog.has_table_privilege(r, 'crm.' || t, p) THEN
                    RAISE EXCEPTION 'crm-024: reader % may % on crm.%', r, p, t;
                END IF;
            END LOOP;
        END LOOP;
        IF pg_catalog.has_table_privilege('crm_app', 'crm.' || t, 'TRUNCATE')
           OR (t <> 'invoice_line' AND pg_catalog.has_table_privilege('crm_app', 'crm.' || t, 'DELETE'))
           OR NOT pg_catalog.has_table_privilege('crm_app', 'crm.' || t, 'INSERT')
           OR NOT pg_catalog.has_table_privilege('crm_app', 'crm.' || t, 'UPDATE') THEN
            RAISE EXCEPTION 'crm-024: crm_app reads, inserts and updates crm.% and never truncates it (deletes draft invoice lines only)', t;
        END IF;
    END LOOP;
    IF pg_catalog.has_table_privilege('crm_app', 'crm.payment', 'UPDATE')
       OR pg_catalog.has_table_privilege('crm_app', 'crm.payment', 'DELETE') THEN
        RAISE EXCEPTION 'crm-024: crm.payment stays append-only for crm_app';
    END IF;
    FOREACH t IN ARRAY ARRAY['invoice_sealed', 'invoice_issue_check', 'invoice_status_transition', 'invoice_hold_guard']
    LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger WHERE tgname = t AND tgrelid = 'crm.invoice'::regclass) THEN
            RAISE EXCEPTION 'crm-024: crm.invoice lost trigger %', t;
        END IF;
    END LOOP;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger WHERE tgname = 'invoice_line_draft_only'
                   AND tgrelid = 'crm.invoice_line'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger WHERE tgname = 'invoice_sequence_step'
                      AND tgrelid = 'crm.invoice_sequence'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger WHERE tgname = 'refund_request_sealed'
                      AND tgrelid = 'crm.refund_request'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger WHERE tgname = 'payment_append_only'
                      AND tgrelid = 'crm.payment'::regclass) THEN
        RAISE EXCEPTION 'crm-024: a guard trigger is missing (invoice lines, sequence, refund requests, payment ledger)';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_constraint WHERE conrelid = 'crm.payment'::regclass
               AND conname = 'payment_schedule_once_uq')
       OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_indexes WHERE schemaname = 'crm' AND tablename = 'payment'
                      AND indexname = 'payment_schedule_once_uq' AND indexdef LIKE '%WHERE%') THEN
        RAISE EXCEPTION 'crm-024: payment_schedule_once_uq must be the partial index (payments without an invoice)';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_policy pol JOIN pg_catalog.pg_class c ON c.oid = pol.polrelid
               WHERE c.relnamespace = 'crm'::regnamespace AND 0 = ANY (pol.polroles)) THEN
        RAISE EXCEPTION 'crm-024: a crm policy applies TO PUBLIC (catalogue rule b); name the CRM roles';
    END IF;
    IF pg_catalog.has_function_privilege('crm_app', 'crm.erase_subject(text,uuid,uuid,boolean)', 'EXECUTE')
       OR NOT pg_catalog.has_function_privilege('crm_eraser', 'crm.erase_subject(text,uuid,uuid,boolean)', 'EXECUTE')
       OR pg_catalog.has_function_privilege('public', 'crm.erase_subject(text,uuid,uuid,boolean)', 'EXECUTE') THEN
        RAISE EXCEPTION 'crm-024: crm.erase_subject must be executable by crm_eraser only';
    END IF;
    -- Every table an earlier key taught erase_subject, and this key's.
    FOREACH t IN ARRAY ARRAY['refund_request', 'invoice_line', 'invoice', 'payment_provider_account',
                             'invoice_sequence', 'dispatch_attempt', 'dispatch_queue', 'prep_pack_selection',
                             'message_template', 'metric_event', 'selection', 'option_rule', 'option', 'option_block',
                             'proposal_day', 'aa_request', 'inbox_events', 'booking_feed_state', 'signature_request',
                             'otp_challenge', 'traveler_access', 'payment', 'payment_schedule', 'proposal',
                             'agreement_doc', 'message', 'conversation', 'saved_reply', 'mail_import',
                             'ingest_address', 'channel_account', 'booking_line_money', 'booking_line',
                             'agency_supplier', 'fx_rate_override', 'membership_inbox', 'client_link',
                             'meeting_slot'] LOOP
        IF position(quote_literal(t) IN (SELECT prosrc FROM pg_catalog.pg_proc
                     WHERE oid = 'crm.erase_subject(text,uuid,uuid,boolean)'::regprocedure)) = 0 THEN
            RAISE EXCEPTION 'crm-024: crm.erase_subject does not erase crm.%', t;
        END IF;
    END LOOP;
    IF position('accepted_name_erased_at' IN (SELECT prosrc FROM pg_catalog.pg_proc
                 WHERE oid = 'crm.erase_subject(text,uuid,uuid,boolean)'::regprocedure)) = 0 THEN
        RAISE EXCEPTION 'crm-024: crm.erase_subject lost the crm-016 typed acceptance name step';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-024', now(), 'AA-952 CRM-23 slices 2-3: invoices (crm.invoice, crm.invoice_line, crm.invoice_sequence, invoice settings), payments against invoices and refunds (crm.payment + invoice_id / provider / entry_kind / refund_of, crm.refund_request), the agency''s own payment methods (crm.payment_provider_account), erase_subject + the new tables')
ON CONFLICT (version) DO NOTHING;

COMMIT;
