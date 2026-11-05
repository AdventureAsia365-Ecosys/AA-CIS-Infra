-- migrate: expand
--
-- Migration bk-044: AA-1037 R4 extras (S269, research note root docs/research/2026-11-05-asian-trails-b2b-benchmark,
-- gaps G4 and G6): the reminder log of overdue agency invoices and the partner terms clauses.
--
-- Owner: AA-Booking (key bk-NNN). AA-CIS-Infra Migration Sync copies it byte for byte to
-- db/migrations/booking/044_agency_reminders_terms_clauses.sql and Migration Apply applies it on Dev as bk_owner (the
-- runner's role switch, live owner of schema booking since bk-014), with no hand step. Never run it from a laptop.
--
-- Depends on bk-041 (booking.agency_invoice).
--
-- What (new tables only):
--   * agency_invoice_reminder  one row per (overdue agency invoice, reminder step) the job bk_agency_invoice_reminders
--                              handled: sent (the address and the SES message id) or skipped (no billing e-mail on the
--                              invoice). The primary key makes a step happen once per invoice, whatever the reruns.
--   * partner_terms_clause     the clauses of AA's terms to agencies as data, edited in the staff admin, starting as a
--                              draft; an approved clause (a second person, never its last editor) is what the
--                              booking.b2b.v1 terms answer shows (heading = the clause title). One seed row: the price-error clause (G6), DRAFT
--                              wording for the business owner to approve, with a free-cancel window.
--
-- Class: expand (ADR 0017 d3): new tables, their indexes and constraints, a seed row into a table this file creates,
-- grants to the runtime role booking. No DO block (opaque to the expand lint): the runner checks the role.
-- The app never deletes either table's rows (reminders are evidence, clauses are withdrawn by a new version); the
-- DELETE the bk-014 default privileges give role booking stays until a later contract file revokes it.
-- DM-7.1: both tables have their row in the root data standards (root PR merged before the Infra copy).
-- DM-6.1: agency_invoice_reminder.sent_to is the agency's billing e-mail (pii:contact), tagged below.
-- Re-runnable (the Integration Tests replay every file): IF NOT EXISTS, ON CONFLICT DO NOTHING.
-- Undo (a later bk- file, after the code is reverted and no row matters): DROP TABLE of the two tables.

BEGIN;

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS booking.agency_invoice_reminder (
    invoice_id    uuid NOT NULL REFERENCES booking.agency_invoice (id),
    step_days     smallint NOT NULL,
    step_kind     text NOT NULL,
    days_overdue  integer NOT NULL,
    outcome       text NOT NULL,
    skip_reason   text,
    sent_to       text,
    redirected    boolean NOT NULL DEFAULT false,
    delivery_ref  text,
    created_by    text NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT agency_invoice_reminder_pkey PRIMARY KEY (invoice_id, step_days),
    CONSTRAINT agency_invoice_reminder_step_chk CHECK (
        step_days BETWEEN 1 AND 365 AND step_kind IN ('reminder', 'credit_stop') AND days_overdue >= step_days),
    CONSTRAINT agency_invoice_reminder_outcome_chk CHECK (
        outcome IN ('sent', 'skipped')
        AND ((outcome = 'sent') = (delivery_ref IS NOT NULL AND sent_to IS NOT NULL))
        AND ((outcome = 'skipped') = (skip_reason IS NOT NULL))
        AND (skip_reason IS NULL OR skip_reason IN ('no_billing_email'))),
    CONSTRAINT agency_invoice_reminder_text_chk CHECK (
        (sent_to IS NULL OR (length(sent_to) <= 254 AND sent_to LIKE '%_@_%'))
        AND (delivery_ref IS NULL OR length(delivery_ref) BETWEEN 1 AND 200)
        AND length(created_by) BETWEEN 1 AND 128)
);

CREATE INDEX IF NOT EXISTS agency_invoice_reminder_created_idx ON booking.agency_invoice_reminder (created_at DESC);

COMMENT ON TABLE booking.agency_invoice_reminder IS
    'AA-1037 R4 extras (bk-044, G4): one row per (overdue agency invoice, reminder step) that the job '
    'bk_agency_invoice_reminders handled. step_days = the days overdue of the step (the setting '
    'agency_reminder_steps_days, default 1 / 7 / 14, plus the agency''s suspend_after_days as the credit_stop step: '
    'new B2B holds are refused from then on). sent = e-mailed through the Booking mailer (on Dev to the staff inbox, '
    'redirected true; delivery_ref = the SES message id); skipped = the invoice has no billing e-mail. The primary key '
    'makes each step happen once.';
COMMENT ON COLUMN booking.agency_invoice_reminder.sent_to IS
    'pii:contact — the address the reminder went to: the invoice''s bill-to billing e-mail, or the staff inbox on Dev.';

CREATE TABLE IF NOT EXISTS booking.partner_terms_clause (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code              text NOT NULL,
    position          smallint NOT NULL DEFAULT 100,
    heading           text NOT NULL,
    body              text NOT NULL,
    free_cancel_days  smallint,
    status            text NOT NULL DEFAULT 'draft',
    version           integer NOT NULL DEFAULT 1,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    updated_by        text NOT NULL,
    approved_by       text,
    approved_at       timestamptz,
    CONSTRAINT partner_terms_clause_code_chk CHECK (code ~ '^[a-z][a-z0-9_]{1,39}$'),
    CONSTRAINT partner_terms_clause_text_chk CHECK (
        length(btrim(heading)) BETWEEN 1 AND 120
        AND length(btrim(body)) BETWEEN 1 AND 4000
        AND length(updated_by) BETWEEN 1 AND 128
        AND (approved_by IS NULL OR length(approved_by) BETWEEN 1 AND 128)),
    CONSTRAINT partner_terms_clause_numbers_chk CHECK (
        position BETWEEN 1 AND 999 AND version >= 1
        AND (free_cancel_days IS NULL OR free_cancel_days BETWEEN 0 AND 60)),
    CONSTRAINT partner_terms_clause_status_chk CHECK (
        status IN ('draft', 'approved')
        AND ((status = 'approved') = (approved_by IS NOT NULL))
        AND ((approved_by IS NULL) = (approved_at IS NULL))
        AND (approved_by IS NULL OR approved_by <> updated_by))
);

CREATE UNIQUE INDEX IF NOT EXISTS partner_terms_clause_code_uq ON booking.partner_terms_clause (code);

COMMENT ON TABLE booking.partner_terms_clause IS
    'AA-1037 R4 extras (bk-044, G6): clauses of AA''s terms to agencies as data (no legal text in code). Finance or an '
    'admin edits a clause (it goes back to draft, version + 1); a second person approves it (never its last editor, '
    'CHECK). Only approved clauses are in the booking.b2b.v1 terms answer; drafts show in the staff admin marked '
    'draft. free_cancel_days: the days an agency may cancel free of charge after AA corrects a price (price_error).';

GRANT SELECT, INSERT ON booking.agency_invoice_reminder TO booking;
GRANT SELECT, INSERT, UPDATE ON booking.partner_terms_clause TO booking;

-- G6 starting row: DRAFT wording for the business owner to approve or reword in the staff admin (Agency billing ->
-- Settings -> Terms clauses). Never shown to agencies while it is a draft.
INSERT INTO booking.partner_terms_clause (code, position, heading, body, free_cancel_days, status, updated_by)
VALUES ('price_error', 10, 'Price errors',
        'If a price AA published or quoted is clearly wrong (for example a typing or system error far from the usual '
        'price of the service), AA may correct it before the services start. AA tells the agency the corrected price '
        'in writing. The agency may then keep the booking at the corrected price, or cancel it free of charge within '
        'the free-cancel window counted from that notice; amounts already paid for a booking cancelled this way are '
        'refunded in full. A price that is not clearly wrong is honoured as quoted.',
        2, 'draft', 'system:bk-044')
ON CONFLICT (code) DO NOTHING;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-044', now(), 'AA-1037 R4 extras: agency invoice reminder log + partner terms clauses (price-error draft)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
