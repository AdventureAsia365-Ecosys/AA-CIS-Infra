-- migrate: expand
--
-- Migration bk-041: AA-1037 R4 slice 1 — agency billing tables: every invoice to an agency (the SaaS subscription and
-- the tour settlement) is issued from Booking (root ADR 0019 d9, b14 / b16 / b17; S265 clarifications TL-9, BO-14..17).
--
-- Owner: AA-Booking (key bk-NNN). AA-CIS-Infra Migration Sync copies it byte for byte to
-- db/migrations/booking/041_agency_billing_tables.sql and Migration Apply applies it on Dev as bk_owner (the runner's
-- role switch, live owner of schema booking since bk-014), with no hand step. Never run it from a laptop.
--
-- Depends on bk-019 (booking.b2b_partners, tenant_id UNIQUE) and bk-020 (booking.b2b_holds).
--
-- Why: booking.invoices is B2C only (bill_to_kind 'customer', trip_case_id NOT NULL) and frozen with the B2C side
-- (ADR 0019 d8), so the agency invoices get their own tables. Terms, tax and the issuing entity are data rows that
-- finance edits in the staff admin (BO-15..17: adjustable without code).
--
-- What (new tables only; every one starts empty except the two seed rows below):
--   * billing_entity       AA's issuing legal entity (b10); one row may be the default.
--   * tax_rule             tax rate, line and footer wording as data (b17), per invoice kind and recipient country,
--                          with an effective window.
--   * billing_terms        deposit %, balance days before departure, due days per kind, warn / suspend days and the
--                          SaaS currency: one default row (party_tenant_id NULL) + optional per-agency overrides.
--   * invoice_sequence     the gap-free number series per kind and year (AAS- software fee, AAT- tour settlement);
--                          a number is taken in the transaction that issues the invoice, so a rollback leaves no gap.
--   * agency_invoice       one invoice to one agency (party_tenant_id -> b2b_partners.tenant_id), kind saas |
--                          settlement, a period, a currency, totals, status draft | issued | paid | void, the manual
--                          VAT e-invoice number (phase 1, Decree 70/2025), and the issuer + bill-to snapshots taken at
--                          issue. One live invoice per (agency, kind, period start, currency): the draft jobs are
--                          idempotent per period.
--   * agency_invoice_line  lines; the composite FK (invoice_id, invoice_kind) makes every line carry its invoice's kind,
--                          and the role CHECK keeps software fees and tour money apart (b17). A settlement line names its
--                          B2B hold; one live line per (hold, role) so a deposit or balance is never billed twice.
--   * agency_payment       a payment recorded by hand (no provider, b14): maker-checker (recorded_by <> approved_by /
--                          rejected_by, CHECK), a document reference is required.
--
-- The guards that make issued invoices and decided payments immutable, the money state derived from approved payments,
-- the updated_at triggers and the CIS contract view booking.v_tenant_billing_status come in bk-042 (contract: triggers,
-- REVOKEs and a cross-owner grant are not expand). The app needs both (REQUIRED_SCHEMA_VERSIONS bk-042).
--
-- Class: expand (ADR 0017 d3): new tables, their indexes and constraints, seed rows into tables this file creates,
-- grants to the runtime role booking. No DO block (opaque to the expand lint): the runner checks the role.
-- DM-7.1: every new table has its row in the root data standards (root PR merged before the Infra copy).
-- DM-6.1: personal or payment data columns carry their tag here (bill_to, staff_note, reference, document_ref, note,
-- void / reject reasons).
-- Re-runnable (the Integration Tests replay every file): IF NOT EXISTS, ON CONFLICT DO NOTHING.
-- Undo (a later bk- file, after the code is reverted and no row matters): DROP TABLE of the seven tables.

BEGIN;

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS booking.billing_entity (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                  text NOT NULL,
    legal_entity          text NOT NULL,
    tax_code              text,
    registered_office     text,
    country_iso2          char(2),
    invoice_inbox         text,
    payment_instructions  text,
    is_default            boolean NOT NULL DEFAULT false,
    active                boolean NOT NULL DEFAULT true,
    created_at            timestamptz NOT NULL DEFAULT now(),
    updated_at            timestamptz NOT NULL DEFAULT now(),
    updated_by            text,
    CONSTRAINT billing_entity_code_chk CHECK (code ~ '^[A-Z][A-Z0-9_-]{1,31}$'),
    CONSTRAINT billing_entity_text_chk CHECK (
        length(btrim(legal_entity)) BETWEEN 1 AND 300
        AND (tax_code IS NULL OR length(btrim(tax_code)) BETWEEN 1 AND 64)
        AND (registered_office IS NULL OR length(btrim(registered_office)) BETWEEN 1 AND 1000)
        AND (invoice_inbox IS NULL OR (length(invoice_inbox) <= 254 AND invoice_inbox LIKE '%_@_%'))
        AND (payment_instructions IS NULL OR length(btrim(payment_instructions)) BETWEEN 1 AND 2000)
        AND (updated_by IS NULL OR length(updated_by) BETWEEN 1 AND 128)),
    CONSTRAINT billing_entity_country_chk CHECK (country_iso2 IS NULL OR country_iso2 ~ '^[A-Z]{2}$'),
    CONSTRAINT billing_entity_default_chk CHECK (NOT is_default OR active)
);
CREATE UNIQUE INDEX IF NOT EXISTS billing_entity_code_uq ON booking.billing_entity (code);
CREATE UNIQUE INDEX IF NOT EXISTS billing_entity_default_uq ON booking.billing_entity ((true)) WHERE is_default;
COMMENT ON TABLE booking.billing_entity IS
    'AA-1037 (bk-041): the AA legal entity that issues agency invoices (root ADR 0019 b10). Finance edits it in the '
    'staff admin; the invoice keeps a snapshot (agency_invoice.issuer) taken at issue. At most one default.';

CREATE TABLE IF NOT EXISTS booking.tax_rule (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                text NOT NULL,
    invoice_kind        text,
    recipient_country   char(2),
    rate                numeric(6, 4) NOT NULL,
    line_wording        text NOT NULL,
    footer_wording      text,
    effective_from      date NOT NULL,
    effective_to        date,
    active              boolean NOT NULL DEFAULT true,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    updated_by          text,
    CONSTRAINT tax_rule_code_chk CHECK (code ~ '^[A-Z][A-Z0-9_-]{1,31}$'),
    CONSTRAINT tax_rule_kind_chk CHECK (invoice_kind IS NULL OR invoice_kind IN ('saas', 'settlement')),
    CONSTRAINT tax_rule_country_chk CHECK (recipient_country IS NULL OR recipient_country ~ '^[A-Z]{2}$'),
    CONSTRAINT tax_rule_rate_chk CHECK (rate >= 0 AND rate < 1),
    CONSTRAINT tax_rule_text_chk CHECK (
        length(btrim(line_wording)) BETWEEN 1 AND 120
        AND (footer_wording IS NULL OR length(btrim(footer_wording)) BETWEEN 1 AND 1000)
        AND (updated_by IS NULL OR length(updated_by) BETWEEN 1 AND 128)),
    CONSTRAINT tax_rule_window_chk CHECK (effective_to IS NULL OR effective_to > effective_from)
);
CREATE UNIQUE INDEX IF NOT EXISTS tax_rule_code_uq ON booking.tax_rule (code);
COMMENT ON TABLE booking.tax_rule IS
    'AA-1037 (bk-041): tax and invoice footer wording as data (root ADR 0019 b17). The draft jobs pick the active rule '
    'in force on the issue day for the invoice kind and the recipient country, the most specific first (kind + '
    'country, country, kind, any). rate is a fraction (0.1000 = 10 %).';

CREATE TABLE IF NOT EXISTS booking.billing_terms (
    id                             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    party_tenant_id                uuid REFERENCES booking.b2b_partners (tenant_id),
    deposit_pct                    numeric(5, 4) NOT NULL,
    balance_days_before_departure  smallint NOT NULL,
    saas_due_days                  smallint NOT NULL,
    settlement_due_days            smallint NOT NULL,
    warn_after_days                smallint NOT NULL,
    suspend_after_days             smallint NOT NULL,
    saas_currency                  char(3) NOT NULL DEFAULT 'USD',
    created_at                     timestamptz NOT NULL DEFAULT now(),
    updated_at                     timestamptz NOT NULL DEFAULT now(),
    updated_by                     text,
    CONSTRAINT billing_terms_deposit_chk CHECK (deposit_pct >= 0 AND deposit_pct <= 1),
    CONSTRAINT billing_terms_days_chk CHECK (
        balance_days_before_departure BETWEEN 0 AND 365
        AND saas_due_days BETWEEN 0 AND 120
        AND settlement_due_days BETWEEN 0 AND 120
        AND warn_after_days BETWEEN 0 AND 365
        AND suspend_after_days BETWEEN 1 AND 365
        AND suspend_after_days > warn_after_days),
    CONSTRAINT billing_terms_currency_chk CHECK (saas_currency ~ '^[A-Z]{3}$'),
    CONSTRAINT billing_terms_actor_chk CHECK (updated_by IS NULL OR length(updated_by) BETWEEN 1 AND 128)
);
CREATE UNIQUE INDEX IF NOT EXISTS billing_terms_default_uq ON booking.billing_terms ((true)) WHERE party_tenant_id IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS billing_terms_party_uq ON booking.billing_terms (party_tenant_id)
    WHERE party_tenant_id IS NOT NULL;
COMMENT ON TABLE booking.billing_terms IS
    'AA-1037 (bk-041): agency payment terms as data (root ADR 0019 b16; BO-16 adjustable without code). The row with '
    'party_tenant_id NULL is the default; a row per agency overrides it whole. deposit_pct / '
    'balance_days_before_departure shape the settlement lines (deposit at confirmation, balance before departure, in '
    'full when booked late); *_due_days set the due date from the issue day; warn_after_days / suspend_after_days '
    'turn an overdue invoice into the billing status booking.v_tenant_billing_status serves CIS (bk-042).';

CREATE TABLE IF NOT EXISTS booking.invoice_sequence (
    series      text NOT NULL,
    year        smallint NOT NULL,
    last_no     integer NOT NULL DEFAULT 0,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT invoice_sequence_pkey PRIMARY KEY (series, year),
    CONSTRAINT invoice_sequence_series_chk CHECK (series IN ('AAS', 'AAT')),
    CONSTRAINT invoice_sequence_year_chk CHECK (year BETWEEN 2020 AND 2999),
    CONSTRAINT invoice_sequence_no_chk CHECK (last_no BETWEEN 0 AND 999999)
);
COMMENT ON TABLE booking.invoice_sequence IS
    'AA-1037 (bk-041): gap-free invoice numbers, one series per kind and calendar year: AAS-<year>-<6 digits> for the '
    'software fee (saas), AAT-<year>-<6 digits> for the tour settlement. The issue transaction takes the next number '
    '(INSERT ... ON CONFLICT DO UPDATE last_no + 1, row lock until commit), so a rolled-back issue leaves no gap.';

CREATE TABLE IF NOT EXISTS booking.agency_invoice (
    id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    number                 text,
    party_tenant_id        uuid NOT NULL REFERENCES booking.b2b_partners (tenant_id),
    invoice_kind           text NOT NULL,
    status                 text NOT NULL DEFAULT 'draft',
    period_start           date NOT NULL,
    period_end             date NOT NULL,
    currency               char(3) NOT NULL,
    subtotal               numeric(14, 2) NOT NULL DEFAULT 0,
    tax_rule_id            uuid REFERENCES booking.tax_rule (id),
    tax_rate               numeric(6, 4) NOT NULL DEFAULT 0,
    tax_amount             numeric(14, 2) NOT NULL DEFAULT 0,
    total                  numeric(14, 2) NOT NULL DEFAULT 0,
    billing_entity_id      uuid REFERENCES booking.billing_entity (id),
    issuer                 jsonb,
    bill_to                jsonb,
    footer_wording         text,
    issued_on              date,
    due_date               date,
    issued_at              timestamptz,
    issued_by              text,
    e_invoice_no           text,
    e_invoice_recorded_by  text,
    e_invoice_recorded_at  timestamptz,
    staff_note             text,
    voided_at              timestamptz,
    voided_by              text,
    void_reason            text,
    source                 text NOT NULL,
    created_by             text NOT NULL,
    idempotency_key        text NOT NULL,
    created_at             timestamptz NOT NULL DEFAULT now(),
    updated_at             timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT agency_invoice_id_kind_uq UNIQUE (id, invoice_kind),
    CONSTRAINT agency_invoice_kind_chk CHECK (invoice_kind IN ('saas', 'settlement')),
    CONSTRAINT agency_invoice_status_chk CHECK (status IN ('draft', 'issued', 'paid', 'void')),
    CONSTRAINT agency_invoice_period_chk CHECK (period_start < period_end),
    CONSTRAINT agency_invoice_currency_chk CHECK (currency ~ '^[A-Z]{3}$'),
    CONSTRAINT agency_invoice_number_chk CHECK (
        number IS NULL
        OR (invoice_kind = 'saas' AND number ~ '^AAS-[0-9]{4}-[0-9]{6}$')
        OR (invoice_kind = 'settlement' AND number ~ '^AAT-[0-9]{4}-[0-9]{6}$')),
    CONSTRAINT agency_invoice_money_chk CHECK (
        tax_rate >= 0 AND tax_rate < 1 AND total = subtotal + tax_amount),
    CONSTRAINT agency_invoice_issued_chk CHECK (
        ((status = 'draft') = (number IS NULL))
        AND ((number IS NULL) = (issued_at IS NULL))
        AND ((issued_at IS NULL) = (issued_by IS NULL))
        AND ((issued_at IS NULL) = (issued_on IS NULL))
        AND (issued_at IS NULL OR (due_date IS NOT NULL AND issuer IS NOT NULL AND bill_to IS NOT NULL
                                    AND billing_entity_id IS NOT NULL AND total >= 0))),
    CONSTRAINT agency_invoice_void_chk CHECK (
        ((status = 'void') = (voided_at IS NOT NULL))
        AND ((voided_at IS NULL) = (voided_by IS NULL))
        AND ((voided_at IS NULL) = (void_reason IS NULL))
        AND (void_reason IS NULL OR length(btrim(void_reason)) BETWEEN 1 AND 500)),
    CONSTRAINT agency_invoice_e_invoice_chk CHECK (
        (e_invoice_no IS NULL OR (length(btrim(e_invoice_no)) BETWEEN 1 AND 64 AND number IS NOT NULL))
        AND ((e_invoice_no IS NULL) = (e_invoice_recorded_at IS NULL))
        AND ((e_invoice_no IS NULL) = (e_invoice_recorded_by IS NULL))),
    CONSTRAINT agency_invoice_text_chk CHECK (
        (staff_note IS NULL OR length(btrim(staff_note)) BETWEEN 1 AND 2000)
        AND (footer_wording IS NULL OR length(footer_wording) BETWEEN 1 AND 1000)
        AND length(created_by) BETWEEN 1 AND 128
        AND (issued_by IS NULL OR length(issued_by) BETWEEN 1 AND 128)),
    CONSTRAINT agency_invoice_source_chk CHECK (source IN ('job', 'staff')),
    CONSTRAINT agency_invoice_key_chk CHECK (length(idempotency_key) BETWEEN 8 AND 200)
);
CREATE UNIQUE INDEX IF NOT EXISTS agency_invoice_number_uq ON booking.agency_invoice (number) WHERE number IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS agency_invoice_period_uq
    ON booking.agency_invoice (party_tenant_id, invoice_kind, period_start, currency) WHERE status <> 'void';
CREATE UNIQUE INDEX IF NOT EXISTS agency_invoice_idempotency_uq ON booking.agency_invoice (idempotency_key)
    WHERE status <> 'void';
CREATE INDEX IF NOT EXISTS agency_invoice_party_idx ON booking.agency_invoice (party_tenant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS agency_invoice_open_idx ON booking.agency_invoice (due_date) WHERE status = 'issued';
CREATE INDEX IF NOT EXISTS agency_invoice_status_idx ON booking.agency_invoice (status, created_at DESC);
COMMENT ON TABLE booking.agency_invoice IS
    'AA-1037 (bk-041, root ADR 0019 d9): an invoice from AA to an agency (party_tenant_id = the CIS tenant, '
    'b2b_partners.tenant_id). invoice_kind saas (software fee, AAS- numbers) or settlement (tour money, AAT- numbers), '
    'never mixed (b17). draft -> issued (number, issuer and bill-to snapshots, due date) -> paid (approved payments '
    'cover the total) | void (issued, no approved payment). e_invoice_no = the legal VAT e-invoice number the accountant '
    'issued in the e-invoice software (phase 1, Decree 70/2025).';
COMMENT ON COLUMN booking.agency_invoice.bill_to IS
    'pii:contact; also pii:name, pii:address, pii:government_id — the agency bill-to snapshot taken at issue from the '
    'CIS tenant (legal entity name, tax ID, billing e-mail and address, country; catalog.v_tenant_billing_v1).';
COMMENT ON COLUMN booking.agency_invoice.staff_note IS 'pii:free_text — finance note on the invoice.';
COMMENT ON COLUMN booking.agency_invoice.void_reason IS 'pii:free_text — why the issued invoice was voided.';
COMMENT ON COLUMN booking.agency_invoice.idempotency_key IS
    'The draft job key <kind>:<tenant>:<period start>:<currency> (one live invoice per period), or a staff key.';

CREATE TABLE IF NOT EXISTS booking.agency_invoice_line (
    invoice_id      uuid NOT NULL,
    invoice_kind    text NOT NULL,
    line_no         smallint NOT NULL,
    line_role       text NOT NULL,
    product         text,
    plan_key        text,
    source_hold_id  uuid REFERENCES booking.b2b_holds (id),
    description     text NOT NULL,
    quantity        numeric(10, 2) NOT NULL DEFAULT 1,
    unit_price      numeric(14, 2) NOT NULL,
    amount          numeric(14, 2) NOT NULL,
    voided          boolean NOT NULL DEFAULT false,
    created_by      text NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT agency_invoice_line_pkey PRIMARY KEY (invoice_id, line_no),
    CONSTRAINT agency_invoice_line_invoice_fk FOREIGN KEY (invoice_id, invoice_kind)
        REFERENCES booking.agency_invoice (id, invoice_kind) ON DELETE CASCADE,
    CONSTRAINT agency_invoice_line_no_chk CHECK (line_no BETWEEN 1 AND 500),
    CONSTRAINT agency_invoice_line_role_chk CHECK (
        (invoice_kind = 'saas' AND line_role IN ('subscription', 'extra_seats', 'adjustment'))
        OR (invoice_kind = 'settlement'
            AND line_role IN ('deposit', 'balance', 'full', 'cancellation_fee', 'adjustment'))),
    CONSTRAINT agency_invoice_line_source_chk CHECK (
        (line_role IN ('deposit', 'balance', 'full', 'cancellation_fee')) = (source_hold_id IS NOT NULL)
        AND ((line_role IN ('subscription', 'extra_seats')) = (product IS NOT NULL AND plan_key IS NOT NULL))),
    CONSTRAINT agency_invoice_line_product_chk CHECK (
        product IS NULL OR product IN ('content', 'crm', 'tripplanner')),
    CONSTRAINT agency_invoice_line_money_chk CHECK (
        quantity > 0 AND amount = round(quantity * unit_price, 2)
        AND (line_role IN ('adjustment', 'cancellation_fee') OR unit_price >= 0)),
    CONSTRAINT agency_invoice_line_text_chk CHECK (
        length(btrim(description)) BETWEEN 1 AND 300
        AND (plan_key IS NULL OR length(plan_key) BETWEEN 1 AND 64)
        AND length(created_by) BETWEEN 1 AND 128)
);
CREATE UNIQUE INDEX IF NOT EXISTS agency_invoice_line_hold_uq ON booking.agency_invoice_line (source_hold_id, line_role)
    WHERE source_hold_id IS NOT NULL AND NOT voided;
COMMENT ON TABLE booking.agency_invoice_line IS
    'AA-1037 (bk-041): the lines of an agency invoice. invoice_kind is the invoice''s (composite FK), so a software '
    'fee line can never sit on a settlement invoice (b17). saas roles: subscription, extra_seats (product + plan_key '
    'from the CIS subscription), adjustment; settlement roles: deposit, balance, full, cancellation_fee (each of one '
    'B2B hold, billed once while not voided; a cancellation fee is the fee less what was billed before, so it may be '
    'a credit), adjustment (may be negative). voided follows a voided invoice.';

CREATE TABLE IF NOT EXISTS booking.agency_payment (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    invoice_id       uuid NOT NULL REFERENCES booking.agency_invoice (id),
    amount           numeric(14, 2) NOT NULL,
    currency         char(3) NOT NULL,
    method           text NOT NULL,
    received_on      date NOT NULL,
    reference        text,
    document_ref     text NOT NULL,
    note             text,
    status           text NOT NULL DEFAULT 'recorded',
    recorded_by      text NOT NULL,
    recorded_at      timestamptz NOT NULL DEFAULT now(),
    approved_by      text,
    approved_at      timestamptz,
    rejected_by      text,
    rejected_at      timestamptz,
    reject_reason    text,
    idempotency_key  text NOT NULL,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT agency_payment_amount_chk CHECK (amount > 0),
    CONSTRAINT agency_payment_currency_chk CHECK (currency ~ '^[A-Z]{3}$'),
    CONSTRAINT agency_payment_method_chk CHECK (method IN ('bank_transfer', 'cash', 'card_offline', 'other')),
    CONSTRAINT agency_payment_received_on_chk CHECK (received_on >= DATE '2020-01-01'),
    CONSTRAINT agency_payment_status_chk CHECK (status IN ('recorded', 'approved', 'rejected')),
    CONSTRAINT agency_payment_maker_checker_chk CHECK (
        (approved_by IS NULL OR approved_by <> recorded_by) AND (rejected_by IS NULL OR rejected_by <> recorded_by)),
    CONSTRAINT agency_payment_decision_chk CHECK (
        ((status = 'approved') = (approved_by IS NOT NULL))
        AND ((approved_by IS NULL) = (approved_at IS NULL))
        AND ((status = 'rejected') = (rejected_by IS NOT NULL))
        AND ((rejected_by IS NULL) = (rejected_at IS NULL))
        AND ((rejected_by IS NULL) = (reject_reason IS NULL))),
    CONSTRAINT agency_payment_text_chk CHECK (
        length(btrim(document_ref)) BETWEEN 1 AND 300
        AND (reference IS NULL OR length(btrim(reference)) BETWEEN 1 AND 100)
        AND (note IS NULL OR length(btrim(note)) BETWEEN 1 AND 2000)
        AND (reject_reason IS NULL OR length(btrim(reject_reason)) BETWEEN 1 AND 500)
        AND length(recorded_by) BETWEEN 1 AND 128),
    CONSTRAINT agency_payment_key_chk CHECK (length(idempotency_key) BETWEEN 8 AND 200)
);
CREATE UNIQUE INDEX IF NOT EXISTS agency_payment_idempotency_uq ON booking.agency_payment (invoice_id, idempotency_key);
CREATE INDEX IF NOT EXISTS agency_payment_invoice_idx ON booking.agency_payment (invoice_id, recorded_at);
CREATE INDEX IF NOT EXISTS agency_payment_waiting_idx ON booking.agency_payment (recorded_at) WHERE status = 'recorded';
COMMENT ON TABLE booking.agency_payment IS
    'AA-1037 (bk-041): a payment of an agency invoice, marked by hand (no payment provider, root ADR 0019 b14). '
    'Maker-checker: finance records it with a document reference (bank slip, statement line, receipt), another '
    'finance or admin user approves or rejects it (never the recorder, CHECK). Only approved payments count.';
COMMENT ON COLUMN booking.agency_payment.reference IS 'pii:payment — the bank or receipt reference of the transfer.';
COMMENT ON COLUMN booking.agency_payment.document_ref IS
    'pii:payment — the evidence document: a bank statement line, a slip or receipt number, or an ops file id.';
COMMENT ON COLUMN booking.agency_payment.note IS 'pii:free_text — finance note on the payment.';
COMMENT ON COLUMN booking.agency_payment.reject_reason IS 'pii:free_text — why the checker rejected the payment.';

GRANT SELECT, INSERT, UPDATE ON booking.billing_entity, booking.tax_rule, booking.invoice_sequence,
    booking.agency_payment TO booking;
GRANT SELECT, INSERT, UPDATE, DELETE ON booking.billing_terms, booking.agency_invoice, booking.agency_invoice_line
    TO booking;

-- Starting policy data (root ADR 0019 b16 / b17; the tech lead's starting values, changed in the staff admin, never
-- in code): 30 % deposit, balance 30 days before departure, due in 14 days, warn from the first overdue day, suspend
-- after 30 overdue days, SaaS in USD; prices exclude tax (b17: "contracts say prices exclude tax").
INSERT INTO booking.billing_terms (party_tenant_id, deposit_pct, balance_days_before_departure, saas_due_days,
                                   settlement_due_days, warn_after_days, suspend_after_days, saas_currency, updated_by)
SELECT NULL, 0.3000, 30, 14, 14, 1, 30, 'USD', 'system:bk-041'
 WHERE NOT EXISTS (SELECT 1 FROM booking.billing_terms WHERE party_tenant_id IS NULL);

INSERT INTO booking.tax_rule (code, invoice_kind, recipient_country, rate, line_wording, footer_wording,
                              effective_from, updated_by)
VALUES ('EXCL_TAX', NULL, NULL, 0, 'Tax',
        'Prices exclude tax. Any tax due on this invoice in the recipient''s country is accounted for by the recipient '
        'under the contract terms.', DATE '2026-01-01', 'system:bk-041')
ON CONFLICT (code) DO NOTHING;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-041', now(), 'AA-1037 R4: agency billing tables (agency_invoice, lines, payments, sequence, entity, tax, terms)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
