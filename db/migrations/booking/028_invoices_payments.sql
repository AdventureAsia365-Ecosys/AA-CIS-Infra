-- Migration bk-028: AA-682 slice S3 — customer invoices (proforma payment requests), the payment schedule and manual
-- payments with maker-checker, the money edges of a trip case (operations MVP, S252 design §3.3, §4 with the critic
-- fixes B1, B4, B5, B6, B9 and notes 2, 3, 6, 12, 18).
--
-- Owner: AA-Booking (key bk-NNN). A byte-identical copy goes to AA-CIS-Infra
-- db/migrations/booking/028_invoices_payments.sql and is applied to Dev by the DB Migrate workflow (check, then
-- apply), as bk_owner (the live owner of schema booking since bk-014). Never run it from a laptop.
--
-- Depends on bk-003 (trip_cases, versions, staff_users, set_updated_at), bk-005 (settings, edges, customers),
-- bk-026 (ops_transitions, ops_check_transition, ops_files + its guard, trip_cases_post_sale_guard,
-- v_trip_case_supply_state) and bk-027 (v_trip_check_board, notifications_reminder_uq). Every grant names its object.
--
-- What it adds (docs/implementation-notes/AA-682.md, section S3):
--   * booking.invoices (INV-000123): ONE live invoice per B2C trip case (status <> cancelled, not deleted), a proforma
--     payment request (document_type proforma, prices tax-inclusive, no tax line; design D7) in the currency of the
--     case's approved version, billed to the case's customer (bill_to_kind customer; b2b_partner later, memo seam 5).
--     status draft -> sent -> partially_paid <-> paid, sent -> cancelled (net verified paid = 0 and no payment
--     waiting for verification; a partially_paid invoice always has net paid > 0, so it is refunded back to sent
--     first and there is no partially_paid -> cancelled edge). A draft is soft-deleted (deleted_at). The bill-to
--     snapshot is taken at send and fixed after it. total_amount is always the sum of the lines (guard). idempotency_key + request_sha256
--     (critic B6): the same key with the same body returns the stored invoice, another body is a 409.
--   * invoice money states are DERIVED (design D5): sent / partially_paid / paid can only be written when they equal
--     what the verified, non-voided payments imply (invoices_guard recomputes), so the application cannot mark an
--     invoice paid without recorded, verified money. booking.invoice_settle() writes them; it first locks the invoice
--     row FOR UPDATE (critic B4: two concurrent verifies on one invoice would otherwise each sum without the other's
--     row under READ COMMITTED), then recomputes the total from the lines and the state from the payments.
--   * booking.invoice_items: one version_total line (the approved version's total, locked) + adjustment lines with a
--     reason. While draft: adjustments are inserted, edited, deleted. After send: lines are only APPENDED as
--     adjustments (the amendment rule, critic B5: a trip that changes after the deposit is amended, not cancelled and
--     reissued); the total and the state follow.
--   * booking.payment_schedule: rows (seq 1-10, kind deposit / second / final / other, amount, due date). Free while
--     draft; after send a row already covered by verified payments (the waterfall, oldest due first) is frozen, the
--     others may change and new rows are added after the covered ones. Sum of the rows = the total for a sent invoice:
--     checked at send (invoices_guard) and at commit (deferred constraint triggers *_sums_check), so an amendment
--     may change lines and rows in one transaction.
--   * booking.payments (PMT-000123): receipts and refunds recorded by hand (no provider, design D6): kind, amount,
--     method, received_on, reference (bank / receipt reference, never a card number), note, evidence file, optional
--     received_amount / received_currency (what actually arrived, informational: critic note 4). recorded_by (maker)
--     -> verified_by (checker, CHECK verified_by <> recorded_by); only verified, non-voided payments count; verify
--     needs the evidence file unless the method is cash; a verified refund never takes the net paid below 0; void is
--     final, with a reason, on a live invoice only (a cancelled invoice's payments are final), and voiding a verified
--     receipt never takes the net paid below 0 (void the refund first). Only an invoice that is sent /
--     partially_paid / paid takes a payment. Idempotency-Key unique per invoice + request_sha256. payments_settle
--     (AFTER) settles the invoice.
--   * booking.v_payment_schedule_status: per schedule row, the waterfall coverage of the verified payments (oldest
--     due first) and the state scheduled / due (within payment_due_soon_days) / overdue / paid (cancelled for a
--     cancelled or deleted invoice). booking.v_invoice_balance: per invoice, verified received / refunded / net paid,
--     waiting-for-verification amount and count, balance, next due date, overdue amount.
--   * Money edges of a trip case (moved here from bk-026, critic B1): confirmed / supplier_confirming ->
--     invoice_sent -> payment_pending -> paid (+ invoice_sent -> paid), the back-steps of a void or a cancel
--     (payment_pending -> invoice_sent, paid -> payment_pending / invoice_sent, invoice_sent -> confirmed /
--     supplier_confirming), paid -> pre_departure, and cancel from invoice_sent / payment_pending / paid.
--   * trip_cases_post_sale_guard REPLACED (same trigger): invoice_sent / payment_pending / paid equal what the live
--     invoice implies (sent / partially_paid / paid) and never on a B2B case; a B2C case reaches pre_departure only
--     with its invoice paid; back to confirmed / supplier_confirming from a money status only when no sent invoice is
--     left; reopen (cancelled -> new_inquiry) refused while a live supplier booking, a non-cancelled invoice or a
--     non-voided payment exists (critic B9). Travel statuses never step back on a void (critic note 12).
--   * ops_files_guard REPLACED: payment evidence files (kind payment_evidence, entity payment) of an existing,
--     unverified, non-voided payment; the evidence of a verified payment is never removed, and the current evidence
--     (evidence_file_id) of a non-voided payment is never removed while it is attached (detach or replace it first;
--     review S253). payments_guard re-checks at verify that the evidence is still an active file and takes it FOR
--     SHARE, so a concurrent removal waits and is then refused. Supplier bill / payout files still wait for bk-029.
--   * v_trip_check_board REPLACED (same columns): payment_verified = the case's invoice is paid (B2C), NULL on B2B.
--   * settings rows (policy data, design §11 Q4 defaults; values change by migration or run-script, never by the app):
--     deposit_due_days 3, balance_due_days_before_start 30, payment_due_soon_days 7, payment_overdue_reminder_days
--     [1, 7], and PLACEHOLDERS for invoice_issuer and payment_instructions (AA-Booking is a public repo: the real
--     legal name, address and bank details are set by a DB Migrate run-script, never in a migration file).
--
-- Not here: supplier bills / payouts (bk-029), the customer routes (S5). No outbox change (no CRM-facing event, seam 8).
-- The reminder dedupe index notifications_reminder_uq already shipped with bk-027.
--
-- Locks: CREATE OR REPLACE FUNCTION takes no table lock (trip_cases_post_sale_guard and ops_files_guard keep their
-- bk-026 triggers; only the function bodies change). CREATE OR REPLACE VIEW v_trip_check_board takes a brief ACCESS
-- EXCLUSIVE lock on that view (readers of the check board wait for the commit); the ops_transitions /
-- trip_case_status_transitions / settings inserts take ROW EXCLUSIVE; the new tables are empty. lock_timeout 5s: the
-- apply fails rather than queueing behind the job worker or a long check-board read.
-- Re-runnable (the Integration Tests replay every file): IF NOT EXISTS everywhere, CREATE OR REPLACE for functions,
-- triggers and views (same column lists), DROP TRIGGER IF EXISTS before each CREATE CONSTRAINT TRIGGER (constraint
-- triggers take no OR REPLACE), ON CONFLICT DO NOTHING for seed rows, grants repeat.
-- Undo (a later bk- file): DROP the two views, payments, payment_schedule, invoice_items, invoices, their functions,
-- DELETE the bk-028 edges (case + invoice) and settings rows, restore the bk-026 / bk-027 bodies of
-- trip_cases_post_sale_guard, ops_files_guard and v_trip_check_board (only while no case is in a money status).

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF current_user <> 'bk_owner' THEN
        RAISE EXCEPTION 'bk-028: expected to run as bk_owner (live owner of schema booking), running as %', current_user;
    END IF;
    IF to_regclass('booking.v_trip_check_board') IS NULL OR to_regclass('booking.ops_files') IS NULL
       OR to_regclass('booking.notifications_reminder_uq') IS NULL THEN
        RAISE EXCEPTION 'bk-028: needs bk-026 (ops_files, ops_transitions) and bk-027 (v_trip_check_board, notifications_reminder_uq) first';
    END IF;
END $$;

-- ── Edges: invoices (ops_transitions) and the money track of a trip case ─────

INSERT INTO booking.ops_transitions (entity, from_status, to_status) VALUES
    ('invoice', 'draft', 'sent'),
    ('invoice', 'sent', 'partially_paid'),
    ('invoice', 'sent', 'paid'),
    ('invoice', 'partially_paid', 'paid'),
    ('invoice', 'partially_paid', 'sent'),
    ('invoice', 'paid', 'partially_paid'),
    ('invoice', 'paid', 'sent'),
    ('invoice', 'sent', 'cancelled')
ON CONFLICT DO NOTHING;

INSERT INTO booking.trip_case_status_transitions (from_status, to_status) VALUES
    ('confirmed', 'invoice_sent'),
    ('supplier_confirming', 'invoice_sent'),
    ('invoice_sent', 'payment_pending'),
    ('invoice_sent', 'paid'),
    ('payment_pending', 'paid'),
    ('payment_pending', 'invoice_sent'),
    ('paid', 'payment_pending'),
    ('paid', 'invoice_sent'),
    ('invoice_sent', 'confirmed'),
    ('invoice_sent', 'supplier_confirming'),
    ('paid', 'pre_departure'),
    ('invoice_sent', 'cancelled'),
    ('payment_pending', 'cancelled'),
    ('paid', 'cancelled')
ON CONFLICT DO NOTHING;

COMMENT ON TABLE booking.trip_case_status_transitions IS
    'bk-003 + bk-005 + bk-026 + bk-028: allowed trip case status edges (read-only for role booking). Pre-sale edges, proposal_sent -> confirmed (version approval), confirmed -> cancelled, cancelled -> new_inquiry (reopen); bk-026 (AA-682): the supply and travel edges; bk-028: the money edges (-> invoice_sent -> payment_pending -> paid, their back-steps on a void / cancel, paid -> pre_departure, cancel from the money statuses). Each post-sale edge is fact-checked by trip_cases_post_sale_guard.';

-- ── Invoices ─────────────────────────────────────────────────────────────────

CREATE SEQUENCE IF NOT EXISTS booking.invoice_number_seq;

CREATE TABLE IF NOT EXISTS booking.invoices (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    invoice_number   TEXT NOT NULL DEFAULT ('INV-' || lpad(nextval('booking.invoice_number_seq')::text, 6, '0')),
    trip_case_id     UUID NOT NULL REFERENCES booking.trip_cases (id),
    version_id       UUID NOT NULL REFERENCES booking.trip_case_versions (id),
    bill_to_kind     TEXT NOT NULL DEFAULT 'customer',
    customer_id      UUID REFERENCES booking.customers (id),
    bill_to_name     TEXT,
    bill_to_email    TEXT,
    bill_to_address  TEXT,
    document_type    TEXT NOT NULL DEFAULT 'proforma',
    currency         CHARACTER(3) NOT NULL,
    total_amount     NUMERIC(16, 2) NOT NULL DEFAULT 0,
    status           TEXT NOT NULL DEFAULT 'draft',
    issued_at        TIMESTAMPTZ,
    sent_by          TEXT REFERENCES booking.staff_users (cis_user_id),
    notes            TEXT,
    terms            TEXT,
    cancelled_at     TIMESTAMPTZ,
    cancelled_by     TEXT REFERENCES booking.staff_users (cis_user_id),
    cancel_reason    TEXT,
    idempotency_key  TEXT NOT NULL,
    request_sha256   TEXT NOT NULL,
    deleted_at       TIMESTAMPTZ,
    created_by       TEXT REFERENCES booking.staff_users (cis_user_id),
    updated_by       TEXT REFERENCES booking.staff_users (cis_user_id),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT invoices_number_chk CHECK (invoice_number ~ '^INV-[0-9]{6,}$'),
    CONSTRAINT invoices_bill_to_kind_chk CHECK (bill_to_kind IN ('customer')),
    CONSTRAINT invoices_customer_chk CHECK (bill_to_kind <> 'customer' OR customer_id IS NOT NULL),
    CONSTRAINT invoices_document_type_chk CHECK (document_type IN ('proforma')),
    CONSTRAINT invoices_currency_chk CHECK (currency ~ '^[A-Z]{3}$'),
    CONSTRAINT invoices_status_chk CHECK (status IN ('draft', 'sent', 'partially_paid', 'paid', 'cancelled')),
    CONSTRAINT invoices_total_chk CHECK (total_amount >= 0 AND (status IN ('draft', 'cancelled') OR total_amount > 0)),
    -- Sent once = issued, with the bill-to snapshot; a draft is neither.
    CONSTRAINT invoices_sent_chk CHECK (
        (status = 'draft') = (issued_at IS NULL)
        AND (status = 'draft' OR (bill_to_name IS NOT NULL AND sent_by IS NOT NULL))),
    CONSTRAINT invoices_bill_to_chk CHECK (
        (bill_to_name IS NULL OR length(bill_to_name) BETWEEN 1 AND 200)
        AND (bill_to_email IS NULL OR length(bill_to_email) BETWEEN 3 AND 320)
        AND (bill_to_address IS NULL OR length(bill_to_address) BETWEEN 1 AND 500)),
    CONSTRAINT invoices_text_chk CHECK (
        (notes IS NULL OR length(notes) BETWEEN 1 AND 2000) AND (terms IS NULL OR length(terms) BETWEEN 1 AND 2000)),
    CONSTRAINT invoices_cancel_chk CHECK (
        (status = 'cancelled') = (cancelled_at IS NOT NULL AND cancel_reason IS NOT NULL)
        AND (cancel_reason IS NULL OR length(cancel_reason) BETWEEN 1 AND 500)),
    CONSTRAINT invoices_deleted_chk CHECK (deleted_at IS NULL OR status = 'draft'),
    CONSTRAINT invoices_idempotency_chk CHECK (
        length(idempotency_key) BETWEEN 8 AND 200 AND request_sha256 ~ '^[0-9a-f]{64}$')
);

COMMENT ON TABLE booking.invoices IS
    'bk-028 (AA-682 S3): the customer invoice of a B2C trip case = a proforma payment request (design D7, tax-inclusive, no tax line) in the approved version''s currency. One live invoice per case. status draft -> sent -> partially_paid <-> paid, sent -> cancelled (net verified paid 0); the money states are derived from verified payments (invoices_guard, written by invoice_settle). Never deleted: a draft is soft-deleted.';
COMMENT ON COLUMN booking.invoices.bill_to_name IS
    'pii:name; the customer''s name as billed, snapshot taken at send (fixed after it; bk-028).';
COMMENT ON COLUMN booking.invoices.bill_to_email IS
    'pii:contact; the customer''s e-mail as billed, snapshot at send (bk-028).';
COMMENT ON COLUMN booking.invoices.bill_to_address IS
    'pii:address; the customer''s address as billed, snapshot at send (bk-028).';
COMMENT ON COLUMN booking.invoices.notes IS
    'pii:free_text; internal note on the invoice (bk-028), never shown to the customer.';
COMMENT ON COLUMN booking.invoices.terms IS
    'pii:free_text; payment terms printed on the payment request (bk-028).';
COMMENT ON COLUMN booking.invoices.cancel_reason IS
    'pii:free_text; why the invoice was cancelled (bk-028).';
COMMENT ON COLUMN booking.invoices.total_amount IS
    'bk-028: always the sum of booking.invoice_items.amount (invoices_guard); changes after send only through appended adjustment lines.';
COMMENT ON COLUMN booking.invoices.idempotency_key IS
    'bk-028 (critic B6): the Idempotency-Key of the create call, unique per trip case; with request_sha256 (hash of the canonical request body) a replay returns this invoice and another body is refused.';

CREATE UNIQUE INDEX IF NOT EXISTS invoices_number_uq ON booking.invoices (invoice_number);
CREATE UNIQUE INDEX IF NOT EXISTS invoices_idempotency_uq ON booking.invoices (trip_case_id, idempotency_key);
-- One live invoice per trip case.
CREATE UNIQUE INDEX IF NOT EXISTS invoices_live_per_case_uq
    ON booking.invoices (trip_case_id) WHERE status <> 'cancelled' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS invoices_status_idx ON booking.invoices (status, issued_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS invoices_version_idx ON booking.invoices (version_id);
CREATE INDEX IF NOT EXISTS invoices_customer_idx ON booking.invoices (customer_id) WHERE customer_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS invoices_sent_by_idx ON booking.invoices (sent_by) WHERE sent_by IS NOT NULL;
CREATE INDEX IF NOT EXISTS invoices_cancelled_by_idx ON booking.invoices (cancelled_by) WHERE cancelled_by IS NOT NULL;
CREATE INDEX IF NOT EXISTS invoices_created_by_idx ON booking.invoices (created_by) WHERE created_by IS NOT NULL;
CREATE INDEX IF NOT EXISTS invoices_updated_by_idx ON booking.invoices (updated_by) WHERE updated_by IS NOT NULL;

CREATE OR REPLACE TRIGGER invoices_set_updated_at
    BEFORE UPDATE ON booking.invoices
    FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();

CREATE OR REPLACE TRIGGER invoices_check_transition
    BEFORE UPDATE OF status ON booking.invoices
    FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status)
    EXECUTE FUNCTION booking.ops_check_transition('invoice');

-- ── Invoice lines ────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.invoice_items (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    invoice_id   UUID NOT NULL REFERENCES booking.invoices (id),
    position     SMALLINT NOT NULL,
    kind         TEXT NOT NULL,
    description  TEXT NOT NULL,
    quantity     NUMERIC(10, 2) NOT NULL DEFAULT 1,
    unit_price   NUMERIC(16, 2) NOT NULL,
    amount       NUMERIC(16, 2) NOT NULL,
    reason       TEXT,
    created_by   TEXT REFERENCES booking.staff_users (cis_user_id),
    updated_by   TEXT REFERENCES booking.staff_users (cis_user_id),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT invoice_items_position_chk CHECK (position BETWEEN 1 AND 200),
    CONSTRAINT invoice_items_kind_chk CHECK (kind IN ('version_total', 'adjustment')),
    CONSTRAINT invoice_items_description_chk CHECK (length(description) BETWEEN 1 AND 500),
    CONSTRAINT invoice_items_quantity_chk CHECK (quantity > 0 AND quantity <= 9999),
    CONSTRAINT invoice_items_amount_chk CHECK (amount = round(quantity * unit_price, 2)),
    CONSTRAINT invoice_items_reason_chk CHECK (
        (kind = 'adjustment') = (reason IS NOT NULL) AND (reason IS NULL OR length(reason) BETWEEN 1 AND 500)),
    CONSTRAINT invoice_items_version_total_chk CHECK (kind <> 'version_total' OR (quantity = 1 AND unit_price >= 0))
);

COMMENT ON TABLE booking.invoice_items IS
    'bk-028 (AA-682 S3, design D8 / Q24): the lines of an invoice: one version_total line (the approved version''s total, locked) and adjustment lines with a reason (unit_price may be negative). Draft: adjustments change freely; after send only appended (amendment rule, critic B5). The invoice total is their sum.';
COMMENT ON COLUMN booking.invoice_items.description IS
    'pii:free_text; what the line is for, shown on the payment request (bk-028).';
COMMENT ON COLUMN booking.invoice_items.reason IS
    'pii:free_text; why the adjustment was made (bk-028), required on adjustment lines.';

CREATE UNIQUE INDEX IF NOT EXISTS invoice_items_position_uq ON booking.invoice_items (invoice_id, position);
CREATE UNIQUE INDEX IF NOT EXISTS invoice_items_version_total_uq
    ON booking.invoice_items (invoice_id) WHERE kind = 'version_total';
CREATE INDEX IF NOT EXISTS invoice_items_created_by_idx ON booking.invoice_items (created_by) WHERE created_by IS NOT NULL;
CREATE INDEX IF NOT EXISTS invoice_items_updated_by_idx ON booking.invoice_items (updated_by) WHERE updated_by IS NOT NULL;

CREATE OR REPLACE TRIGGER invoice_items_set_updated_at
    BEFORE UPDATE ON booking.invoice_items
    FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();

-- ── Payment schedule ─────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.payment_schedule (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    invoice_id  UUID NOT NULL REFERENCES booking.invoices (id),
    seq         SMALLINT NOT NULL,
    kind        TEXT NOT NULL,
    amount      NUMERIC(16, 2) NOT NULL,
    due_date    DATE NOT NULL,
    created_by  TEXT REFERENCES booking.staff_users (cis_user_id),
    updated_by  TEXT REFERENCES booking.staff_users (cis_user_id),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT payment_schedule_seq_chk CHECK (seq BETWEEN 1 AND 10),
    CONSTRAINT payment_schedule_kind_chk CHECK (kind IN ('deposit', 'second', 'final', 'other')),
    CONSTRAINT payment_schedule_amount_chk CHECK (amount > 0)
);

COMMENT ON TABLE booking.payment_schedule IS
    'bk-028 (AA-682 S3, design D9): when the customer pays what (deposit, second, final, other). Paid / due / overdue is derived (v_payment_schedule_status: waterfall of verified payments, oldest due first), never stored. Sum of the rows = the invoice total once sent (checked at send and at commit). After send a covered row is frozen.';

CREATE UNIQUE INDEX IF NOT EXISTS payment_schedule_seq_uq ON booking.payment_schedule (invoice_id, seq);
CREATE INDEX IF NOT EXISTS payment_schedule_due_idx ON booking.payment_schedule (due_date);
CREATE INDEX IF NOT EXISTS payment_schedule_created_by_idx
    ON booking.payment_schedule (created_by) WHERE created_by IS NOT NULL;
CREATE INDEX IF NOT EXISTS payment_schedule_updated_by_idx
    ON booking.payment_schedule (updated_by) WHERE updated_by IS NOT NULL;

CREATE OR REPLACE TRIGGER payment_schedule_set_updated_at
    BEFORE UPDATE ON booking.payment_schedule
    FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();

-- ── Payments ─────────────────────────────────────────────────────────────────

CREATE SEQUENCE IF NOT EXISTS booking.payment_ref_seq;

CREATE TABLE IF NOT EXISTS booking.payments (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    ref                TEXT NOT NULL DEFAULT ('PMT-' || lpad(nextval('booking.payment_ref_seq')::text, 6, '0')),
    invoice_id         UUID NOT NULL REFERENCES booking.invoices (id),
    kind               TEXT NOT NULL,
    amount             NUMERIC(16, 2) NOT NULL,
    currency           CHARACTER(3) NOT NULL,
    method             TEXT NOT NULL,
    received_on        DATE NOT NULL,
    reference          TEXT,
    note               TEXT,
    received_amount    NUMERIC(16, 2),
    received_currency  CHARACTER(3),
    evidence_file_id   UUID REFERENCES booking.ops_files (id),
    idempotency_key    TEXT NOT NULL,
    request_sha256     TEXT NOT NULL,
    recorded_by        TEXT NOT NULL REFERENCES booking.staff_users (cis_user_id),
    recorded_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    verified_by        TEXT REFERENCES booking.staff_users (cis_user_id),
    verified_at        TIMESTAMPTZ,
    voided_by          TEXT REFERENCES booking.staff_users (cis_user_id),
    voided_at          TIMESTAMPTZ,
    void_reason        TEXT,
    updated_by         TEXT REFERENCES booking.staff_users (cis_user_id),
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT payments_ref_chk CHECK (ref ~ '^PMT-[0-9]{6,}$'),
    CONSTRAINT payments_kind_chk CHECK (kind IN ('receipt', 'refund')),
    CONSTRAINT payments_amount_chk CHECK (amount > 0),
    CONSTRAINT payments_currency_chk CHECK (currency ~ '^[A-Z]{3}$'),
    CONSTRAINT payments_method_chk CHECK (method IN ('bank_transfer', 'card_offline', 'cash', 'other')),
    CONSTRAINT payments_received_on_chk CHECK (received_on >= DATE '2020-01-01'),
    CONSTRAINT payments_text_chk CHECK (
        (reference IS NULL OR length(reference) BETWEEN 1 AND 100) AND (note IS NULL OR length(note) BETWEEN 1 AND 2000)),
    CONSTRAINT payments_received_chk CHECK (
        (received_amount IS NULL) = (received_currency IS NULL)
        AND (received_amount IS NULL OR received_amount > 0)
        AND (received_currency IS NULL OR received_currency ~ '^[A-Z]{3}$')),
    CONSTRAINT payments_idempotency_chk CHECK (
        length(idempotency_key) BETWEEN 8 AND 200 AND request_sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT payments_verified_chk CHECK ((verified_by IS NULL) = (verified_at IS NULL)),
    -- Maker-checker (design D6): the person who verifies is never the person who recorded.
    CONSTRAINT payments_maker_checker_chk CHECK (verified_by IS NULL OR verified_by <> recorded_by),
    CONSTRAINT payments_void_chk CHECK (
        (voided_at IS NULL) = (void_reason IS NULL) AND (voided_at IS NULL) = (voided_by IS NULL)
        AND (void_reason IS NULL OR length(void_reason) BETWEEN 1 AND 500))
);

COMMENT ON TABLE booking.payments IS
    'bk-028 (AA-682 S3, design D6): money received from (receipt) or paid back to (refund) the customer, recorded by hand (no payment provider). Recorded by one person, verified by another (CHECK), evidence required to verify unless cash; only verified, non-voided payments count; void is final. Idempotency-Key unique per invoice. Never deleted.';
COMMENT ON COLUMN booking.payments.reference IS
    'pii:payment; bank or receipt reference, never a card number (the API refuses a card-like number; bk-028).';
COMMENT ON COLUMN booking.payments.note IS
    'pii:free_text; staff note on the payment (bk-028).';
COMMENT ON COLUMN booking.payments.void_reason IS
    'pii:free_text; why the payment was voided (bk-028).';
COMMENT ON COLUMN booking.payments.received_amount IS
    'bk-028 (critic note 4): what actually arrived when it differs from the invoice currency (e.g. a VND transfer against a USD invoice); informational, never counted.';
COMMENT ON COLUMN booking.payments.idempotency_key IS
    'bk-028 (critic B6): the Idempotency-Key of the record call, unique per invoice; with request_sha256 a replay returns this payment and another body is refused.';

CREATE UNIQUE INDEX IF NOT EXISTS payments_ref_uq ON booking.payments (ref);
CREATE UNIQUE INDEX IF NOT EXISTS payments_idempotency_uq ON booking.payments (invoice_id, idempotency_key);
CREATE INDEX IF NOT EXISTS payments_invoice_idx ON booking.payments (invoice_id, recorded_at);
CREATE INDEX IF NOT EXISTS payments_awaiting_idx
    ON booking.payments (recorded_at) WHERE verified_at IS NULL AND voided_at IS NULL;
CREATE INDEX IF NOT EXISTS payments_reference_idx
    ON booking.payments (method, reference) WHERE voided_at IS NULL AND reference IS NOT NULL;
CREATE INDEX IF NOT EXISTS payments_received_on_idx ON booking.payments (received_on);
CREATE INDEX IF NOT EXISTS payments_evidence_idx
    ON booking.payments (evidence_file_id) WHERE evidence_file_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS payments_recorded_by_idx ON booking.payments (recorded_by);
CREATE INDEX IF NOT EXISTS payments_verified_by_idx ON booking.payments (verified_by) WHERE verified_by IS NOT NULL;
CREATE INDEX IF NOT EXISTS payments_voided_by_idx ON booking.payments (voided_by) WHERE voided_by IS NOT NULL;
CREATE INDEX IF NOT EXISTS payments_updated_by_idx ON booking.payments (updated_by) WHERE updated_by IS NOT NULL;

CREATE OR REPLACE TRIGGER payments_set_updated_at
    BEFORE UPDATE ON booking.payments
    FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();

-- ── Money functions ──────────────────────────────────────────────────────────

-- Net verified paid of an invoice: verified, non-voided receipts minus refunds.
CREATE OR REPLACE FUNCTION booking.invoice_net_paid(p_invoice UUID) RETURNS NUMERIC
    LANGUAGE sql
    STABLE
    SET search_path = pg_catalog
AS $$
    SELECT coalesce(sum(CASE WHEN p.kind = 'receipt' THEN p.amount ELSE -p.amount END), 0)
      FROM booking.payments p
     WHERE p.invoice_id = p_invoice AND p.verified_at IS NOT NULL AND p.voided_at IS NULL
$$;

COMMENT ON FUNCTION booking.invoice_net_paid(UUID) IS
    'bk-028 (AA-682 S3): verified, non-voided receipts minus refunds of an invoice.';

-- The money state a sent invoice must have for a total: paid (net >= total), partially_paid (net > 0) or sent.
CREATE OR REPLACE FUNCTION booking.invoice_money_state(p_invoice UUID, p_total NUMERIC) RETURNS TEXT
    LANGUAGE sql
    STABLE
    SET search_path = pg_catalog
AS $$
    SELECT CASE WHEN n.net >= p_total AND p_total > 0 THEN 'paid'
                WHEN n.net > 0 THEN 'partially_paid'
                ELSE 'sent' END
      FROM (SELECT booking.invoice_net_paid(p_invoice) AS net) n
$$;

COMMENT ON FUNCTION booking.invoice_money_state(UUID, NUMERIC) IS
    'bk-028 (AA-682 design D5): the status a sent invoice must have for a total, from its verified payments: paid when the net verified paid covers the total (an overpayment stays paid with a negative balance), partially_paid when some is paid, else sent.';

-- Recompute an invoice from its lines and payments. Locks the invoice row FIRST (critic B4), so concurrent verifies on
-- one invoice run one after the other and the second one's next statement sees the first one's committed payment.
CREATE OR REPLACE FUNCTION booking.invoice_settle(p_invoice UUID) RETURNS TEXT
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_status  TEXT;
    v_total   NUMERIC;
    v_new     TEXT;
BEGIN
    SELECT status INTO v_status FROM booking.invoices WHERE id = p_invoice FOR UPDATE;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;
    SELECT coalesce(sum(amount), 0) INTO v_total FROM booking.invoice_items WHERE invoice_id = p_invoice;
    v_new := v_status;
    IF v_status IN ('sent', 'partially_paid', 'paid') THEN
        v_new := booking.invoice_money_state(p_invoice, v_total);
    END IF;
    UPDATE booking.invoices SET total_amount = v_total, status = v_new
     WHERE id = p_invoice AND (total_amount IS DISTINCT FROM v_total OR status IS DISTINCT FROM v_new);
    RETURN v_new;
END $$;

COMMENT ON FUNCTION booking.invoice_settle(UUID) IS
    'bk-028 (AA-682 S3, critic B4): lock the invoice row FOR UPDATE, then set total_amount = sum of its lines and, for a sent invoice, the status its verified payments imply. Called by the line and payment triggers; never SECURITY DEFINER (runs as the writer).';

-- ── Guards ───────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION booking.invoices_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_channel   TEXT;
    v_customer  UUID;
    v_ok        BOOLEAN;
    v_price     NUMERIC;
    v_currency  TEXT;
    v_lines     NUMERIC;
    v_rows      INTEGER;
    v_sched     NUMERIC;
    v_state     TEXT;
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'draft' OR NEW.deleted_at IS NOT NULL OR NEW.total_amount <> 0 THEN
            RAISE EXCEPTION 'an invoice starts as an empty draft (its total follows its lines)'
                USING ERRCODE = 'check_violation';
        END IF;
        SELECT channel, customer_id INTO v_channel, v_customer
          FROM booking.trip_cases WHERE id = NEW.trip_case_id AND deleted_at IS NULL;
        IF v_channel IS NULL THEN
            RAISE EXCEPTION 'trip case % does not exist', NEW.trip_case_id USING ERRCODE = 'foreign_key_violation';
        END IF;
        IF v_channel <> 'b2c' THEN
            RAISE EXCEPTION 'no customer invoice on a B2B trip case (agency settlement is later, CRM O-10)'
                USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.bill_to_kind = 'customer' AND NEW.customer_id IS DISTINCT FROM v_customer THEN
            RAISE EXCEPTION 'the invoice bills the customer of its trip case' USING ERRCODE = 'check_violation';
        END IF;
        SELECT true, v.total_price, v.currency INTO v_ok, v_price, v_currency
          FROM booking.trip_case_versions v
         WHERE v.id = NEW.version_id AND v.trip_case_id = NEW.trip_case_id AND v.is_approved AND v.deleted_at IS NULL;
        IF v_ok IS NULL THEN
            RAISE EXCEPTION 'version % is not the approved version of trip case %', NEW.version_id, NEW.trip_case_id
                USING ERRCODE = 'check_violation';
        END IF;
        IF v_price IS NULL OR v_currency IS NULL THEN
            RAISE EXCEPTION 'version % has no price (critic note 18: price it first)', NEW.version_id
                USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.currency IS DISTINCT FROM v_currency THEN
            RAISE EXCEPTION 'the invoice currency is the version currency %', v_currency USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
    END IF;

    IF (NEW.id, NEW.invoice_number, NEW.trip_case_id, NEW.version_id, NEW.bill_to_kind, NEW.customer_id,
        NEW.document_type, NEW.currency, NEW.idempotency_key, NEW.request_sha256, NEW.created_by, NEW.created_at)
       IS DISTINCT FROM
       (OLD.id, OLD.invoice_number, OLD.trip_case_id, OLD.version_id, OLD.bill_to_kind, OLD.customer_id,
        OLD.document_type, OLD.currency, OLD.idempotency_key, OLD.request_sha256, OLD.created_by, OLD.created_at) THEN
        RAISE EXCEPTION 'invoice %: number, case, version, customer, currency and key never change', OLD.invoice_number
            USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'invoice % was deleted; nothing changes', OLD.invoice_number USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.status = 'cancelled' THEN
        RAISE EXCEPTION 'invoice % is cancelled; it is final', OLD.invoice_number USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.status <> 'draft'
       AND (NEW.bill_to_name, NEW.bill_to_email, NEW.bill_to_address, NEW.issued_at, NEW.sent_by)
           IS DISTINCT FROM (OLD.bill_to_name, OLD.bill_to_email, OLD.bill_to_address, OLD.issued_at, OLD.sent_by) THEN
        RAISE EXCEPTION 'invoice %: the bill-to snapshot and issue date are fixed once sent', OLD.invoice_number
            USING ERRCODE = 'check_violation';
    END IF;
    SELECT coalesce(sum(amount), 0) INTO v_lines FROM booking.invoice_items WHERE invoice_id = NEW.id;
    IF NEW.total_amount IS DISTINCT FROM v_lines THEN
        RAISE EXCEPTION 'invoice %: total_amount % is not the sum of its lines %', OLD.invoice_number,
            NEW.total_amount, v_lines USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.status IN ('sent', 'partially_paid', 'paid') THEN
        IF OLD.status = 'draft' THEN
            SELECT true, v.total_price INTO v_ok, v_price FROM booking.trip_case_versions v
             WHERE v.id = NEW.version_id AND v.is_approved AND v.deleted_at IS NULL;
            IF v_ok IS NULL OR v_price IS NULL THEN
                RAISE EXCEPTION 'invoice %: its version is no longer the approved, priced version', OLD.invoice_number
                    USING ERRCODE = 'check_violation';
            END IF;
            IF NOT EXISTS (SELECT 1 FROM booking.invoice_items WHERE invoice_id = NEW.id AND kind = 'version_total') THEN
                RAISE EXCEPTION 'invoice %: the version total line is missing', OLD.invoice_number
                    USING ERRCODE = 'check_violation';
            END IF;
            SELECT count(*), coalesce(sum(amount), 0) INTO v_rows, v_sched
              FROM booking.payment_schedule WHERE invoice_id = NEW.id;
            IF v_rows = 0 OR v_sched <> NEW.total_amount THEN
                RAISE EXCEPTION 'invoice %: the payment schedule adds up to % but the total is %', OLD.invoice_number,
                    v_sched, NEW.total_amount USING ERRCODE = 'check_violation';
            END IF;
        END IF;
        v_state := booking.invoice_money_state(NEW.id, NEW.total_amount);
        IF NEW.status <> v_state THEN
            RAISE EXCEPTION 'invoice %: status % does not match its verified payments (%)', OLD.invoice_number,
                NEW.status, v_state USING ERRCODE = 'check_violation';
        END IF;
    ELSIF NEW.status = 'cancelled' THEN
        IF booking.invoice_net_paid(NEW.id) <> 0 THEN
            RAISE EXCEPTION 'invoice %: refund every verified payment before cancelling it', OLD.invoice_number
                USING ERRCODE = 'check_violation';
        END IF;
        IF EXISTS (SELECT 1 FROM booking.payments
                    WHERE invoice_id = NEW.id AND verified_at IS NULL AND voided_at IS NULL) THEN
            RAISE EXCEPTION 'invoice %: void or verify the payments waiting for verification first', OLD.invoice_number
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.invoices_guard() IS
    'bk-028 (AA-682 S3, design D5): an invoice starts as an empty draft of a B2C case, for the customer of the case, on its approved priced version, in its currency; number / case / version / customer / currency / key never change; deleted and cancelled are final; the bill-to snapshot is fixed once sent; total = sum of lines; send needs the version total line and a schedule adding up to the total; sent / partially_paid / paid must equal what the verified payments imply; cancel needs net verified paid 0 and no payment waiting for verification.';

CREATE OR REPLACE TRIGGER invoices_guard
    BEFORE INSERT OR UPDATE ON booking.invoices
    FOR EACH ROW EXECUTE FUNCTION booking.invoices_guard();

CREATE OR REPLACE FUNCTION booking.invoice_items_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_invoice  UUID := CASE WHEN TG_OP = 'DELETE' THEN OLD.invoice_id ELSE NEW.invoice_id END;
    v_status   TEXT;
    v_deleted  TIMESTAMPTZ;
    v_version  UUID;
    v_price    NUMERIC;
BEGIN
    -- The invoice row lock comes first in the guard (review S253), the lock invoice_settle and payments_guard take:
    -- a line change and a verify on one invoice queue on the invoice row (no 40P01 from taking it late, in the AFTER
    -- settle), and the status read here cannot change before this line is written.
    SELECT status, deleted_at, version_id INTO v_status, v_deleted, v_version
      FROM booking.invoices WHERE id = v_invoice FOR UPDATE;
    IF TG_OP = 'UPDATE' AND (NEW.invoice_id, NEW.kind, NEW.created_by, NEW.created_at)
                            IS DISTINCT FROM (OLD.invoice_id, OLD.kind, OLD.created_by, OLD.created_at) THEN
        RAISE EXCEPTION 'invoice line %: its invoice and kind never change', OLD.id USING ERRCODE = 'check_violation';
    END IF;
    SELECT v.total_price INTO v_price FROM booking.trip_case_versions v WHERE v.id = v_version;
    IF v_deleted IS NOT NULL THEN
        RAISE EXCEPTION 'the invoice was deleted; its lines are fixed' USING ERRCODE = 'check_violation';
    END IF;
    IF v_status = 'draft' THEN
        IF TG_OP <> 'INSERT' AND OLD.kind = 'version_total' THEN
            RAISE EXCEPTION 'the version total line is locked' USING ERRCODE = 'check_violation';
        END IF;
        IF TG_OP = 'INSERT' AND NEW.kind = 'version_total' AND NEW.unit_price IS DISTINCT FROM v_price THEN
            RAISE EXCEPTION 'the version total line carries the approved version total %', v_price
                USING ERRCODE = 'check_violation';
        END IF;
    ELSIF v_status IN ('sent', 'partially_paid', 'paid') THEN
        IF TG_OP <> 'INSERT' OR NEW.kind <> 'adjustment' THEN
            RAISE EXCEPTION 'once sent, invoice lines are only appended as adjustments (amendment)'
                USING ERRCODE = 'check_violation';
        END IF;
    ELSE
        RAISE EXCEPTION 'the invoice is %; its lines are fixed', coalesce(v_status, 'missing')
            USING ERRCODE = 'check_violation';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.invoice_items_guard() IS
    'bk-028 (AA-682 S3, critic B5): locks the invoice row first (FOR UPDATE, the order of invoice_settle); lines change freely while the invoice is a draft, except the version total line (inserted once with the version total, then locked); once sent, lines are only appended as adjustments; a cancelled or deleted invoice''s lines are fixed.';

CREATE OR REPLACE TRIGGER invoice_items_guard
    BEFORE INSERT OR UPDATE OR DELETE ON booking.invoice_items
    FOR EACH ROW EXECUTE FUNCTION booking.invoice_items_guard();

CREATE OR REPLACE FUNCTION booking.invoice_items_settle() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    PERFORM booking.invoice_settle(CASE WHEN TG_OP = 'DELETE' THEN OLD.invoice_id ELSE NEW.invoice_id END);
    RETURN NULL;
END $$;

COMMENT ON FUNCTION booking.invoice_items_settle() IS
    'bk-028 (AA-682 S3): AFTER a line changes, recompute the invoice total and (sent) its state: an amendment can move a paid invoice back to partially_paid.';

CREATE OR REPLACE TRIGGER invoice_items_settle
    AFTER INSERT OR UPDATE OR DELETE ON booking.invoice_items
    FOR EACH ROW EXECUTE FUNCTION booking.invoice_items_settle();

-- Schedule rows: free while draft; after send a covered row is frozen and changes land after the covered rows.
CREATE OR REPLACE FUNCTION booking.payment_schedule_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_invoice  UUID := CASE WHEN TG_OP = 'DELETE' THEN OLD.invoice_id ELSE NEW.invoice_id END;
    v_status   TEXT;
    v_deleted  TIMESTAMPTZ;
    v_net      NUMERIC;
    v_before   NUMERIC;
    v_last_due DATE;
    v_last_seq SMALLINT;
BEGIN
    -- The invoice row lock comes first (review S253): a verify locks it too (payments_guard), so the net paid read
    -- below cannot change under this check (no covered row slips through) and the order matches invoice_settle.
    SELECT status, deleted_at INTO v_status, v_deleted FROM booking.invoices WHERE id = v_invoice FOR UPDATE;
    IF TG_OP = 'UPDATE' AND (NEW.invoice_id, NEW.created_by, NEW.created_at)
                            IS DISTINCT FROM (OLD.invoice_id, OLD.created_by, OLD.created_at) THEN
        RAISE EXCEPTION 'schedule row %: its invoice never changes', OLD.id USING ERRCODE = 'check_violation';
    END IF;
    IF v_deleted IS NOT NULL OR v_status IS NULL OR v_status = 'cancelled' THEN
        RAISE EXCEPTION 'the invoice is %; its payment schedule is fixed',
            CASE WHEN v_deleted IS NOT NULL THEN 'deleted' ELSE coalesce(v_status, 'missing') END
            USING ERRCODE = 'check_violation';
    END IF;
    IF v_status = 'draft' THEN
        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    END IF;
    v_net := booking.invoice_net_paid(v_invoice);
    IF v_net <= 0 THEN
        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    END IF;
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        SELECT coalesce(sum(s.amount), 0) INTO v_before FROM booking.payment_schedule s
         WHERE s.invoice_id = v_invoice AND s.id <> OLD.id AND (s.due_date, s.seq) < (OLD.due_date, OLD.seq);
        IF v_net > v_before THEN
            RAISE EXCEPTION 'schedule row % is covered by verified payments; it is fixed', OLD.seq
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        -- The last row the verified payments reach (waterfall, oldest due first), other than this one.
        SELECT w.due_date, w.seq INTO v_last_due, v_last_seq
          FROM (SELECT s.due_date, s.seq,
                       coalesce(sum(s.amount) OVER (ORDER BY s.due_date, s.seq
                                                    ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS before
                  FROM booking.payment_schedule s
                 WHERE s.invoice_id = v_invoice AND s.id <> NEW.id) w
         WHERE w.before < v_net
         ORDER BY w.due_date DESC, w.seq DESC
         LIMIT 1;
        IF v_last_due IS NOT NULL AND (NEW.due_date, NEW.seq) <= (v_last_due, v_last_seq) THEN
            RAISE EXCEPTION 'schedule row %: a changed row comes after the rows already paid (row %, due %)', NEW.seq,
                v_last_seq, v_last_due USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;

COMMENT ON FUNCTION booking.payment_schedule_guard() IS
    'bk-028 (AA-682 S3, critic B5): locks the invoice row first (FOR UPDATE, so a concurrent verify cannot cover a row while it changes); the schedule changes freely while draft; once sent, a row the verified payments already cover (waterfall, oldest due first) is frozen and a changed or new row comes after the covered rows; a cancelled or deleted invoice''s schedule is fixed. Sum = total is checked at commit (*_sums_check).';

CREATE OR REPLACE TRIGGER payment_schedule_guard
    BEFORE INSERT OR UPDATE OR DELETE ON booking.payment_schedule
    FOR EACH ROW EXECUTE FUNCTION booking.payment_schedule_guard();

-- Sum of the schedule = the total of a sent invoice, at commit (an amendment changes lines and rows in one go).
CREATE OR REPLACE FUNCTION booking.invoice_sums_check() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_invoice  UUID;
    v_status   TEXT;
    v_total    NUMERIC;
    v_rows     INTEGER;
    v_sched    NUMERIC;
BEGIN
    IF TG_TABLE_NAME = 'invoices' THEN
        v_invoice := NEW.id;
    ELSIF TG_OP = 'DELETE' THEN
        v_invoice := OLD.invoice_id;
    ELSE
        v_invoice := NEW.invoice_id;
    END IF;
    SELECT status, total_amount INTO v_status, v_total FROM booking.invoices WHERE id = v_invoice;
    IF v_status IN ('sent', 'partially_paid', 'paid') THEN
        SELECT count(*), coalesce(sum(amount), 0) INTO v_rows, v_sched
          FROM booking.payment_schedule WHERE invoice_id = v_invoice;
        IF v_rows = 0 OR v_sched <> v_total THEN
            RAISE EXCEPTION 'invoice %: the payment schedule adds up to % but the total is %', v_invoice, v_sched,
                v_total USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NULL;
END $$;

COMMENT ON FUNCTION booking.invoice_sums_check() IS
    'bk-028 (AA-682 S3): deferred constraint trigger on invoices, invoice_items and payment_schedule: at commit, a sent invoice has schedule rows that add up to its total.';

DROP TRIGGER IF EXISTS invoices_sums_check ON booking.invoices;
CREATE CONSTRAINT TRIGGER invoices_sums_check
    AFTER UPDATE ON booking.invoices
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION booking.invoice_sums_check();
DROP TRIGGER IF EXISTS invoice_items_sums_check ON booking.invoice_items;
CREATE CONSTRAINT TRIGGER invoice_items_sums_check
    AFTER INSERT OR UPDATE OR DELETE ON booking.invoice_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION booking.invoice_sums_check();
DROP TRIGGER IF EXISTS payment_schedule_sums_check ON booking.payment_schedule;
CREATE CONSTRAINT TRIGGER payment_schedule_sums_check
    AFTER INSERT OR UPDATE OR DELETE ON booking.payment_schedule
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION booking.invoice_sums_check();

CREATE OR REPLACE FUNCTION booking.payments_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_status    TEXT;
    v_deleted   TIMESTAMPTZ;
    v_currency  TEXT;
    v_evidence  BOOLEAN := false;
BEGIN
    -- Lock the invoice first (critic B4): a verify or a refund check never races another payment of the invoice.
    SELECT status, deleted_at, currency INTO v_status, v_deleted, v_currency
      FROM booking.invoices WHERE id = NEW.invoice_id FOR UPDATE;
    IF TG_OP = 'INSERT' THEN
        IF v_status IS NULL OR v_deleted IS NOT NULL OR v_status NOT IN ('sent', 'partially_paid', 'paid') THEN
            RAISE EXCEPTION 'a payment is recorded against a sent invoice only (this one is %)',
                coalesce(v_status, 'missing') USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.currency IS DISTINCT FROM v_currency THEN
            RAISE EXCEPTION 'a payment is in its invoice currency %', v_currency USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.verified_at IS NOT NULL OR NEW.voided_at IS NOT NULL THEN
            RAISE EXCEPTION 'a payment starts recorded (not verified, not voided)' USING ERRCODE = 'check_violation';
        END IF;
    ELSE
        IF (NEW.invoice_id, NEW.ref, NEW.kind, NEW.amount, NEW.currency, NEW.method, NEW.received_on,
            NEW.received_amount, NEW.received_currency, NEW.idempotency_key, NEW.request_sha256, NEW.recorded_by,
            NEW.recorded_at, NEW.created_at)
           IS DISTINCT FROM
           (OLD.invoice_id, OLD.ref, OLD.kind, OLD.amount, OLD.currency, OLD.method, OLD.received_on,
            OLD.received_amount, OLD.received_currency, OLD.idempotency_key, OLD.request_sha256, OLD.recorded_by,
            OLD.recorded_at, OLD.created_at) THEN
            RAISE EXCEPTION 'payment %: invoice, kind, amount, method, date and key never change', OLD.ref
                USING ERRCODE = 'check_violation';
        END IF;
        IF OLD.voided_at IS NOT NULL THEN
            RAISE EXCEPTION 'payment % is voided; it is final', OLD.ref USING ERRCODE = 'check_violation';
        END IF;
        IF OLD.verified_at IS NOT NULL
           AND (NEW.verified_at, NEW.verified_by, NEW.reference, NEW.note, NEW.evidence_file_id)
               IS DISTINCT FROM (OLD.verified_at, OLD.verified_by, OLD.reference, OLD.note, OLD.evidence_file_id) THEN
            RAISE EXCEPTION 'payment % is verified; only a void changes it', OLD.ref USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.verified_at IS NOT NULL AND OLD.verified_at IS NULL THEN
            IF NEW.voided_at IS NOT NULL THEN
                RAISE EXCEPTION 'payment %: verify or void, not both', OLD.ref USING ERRCODE = 'check_violation';
            END IF;
            IF NEW.verified_by IS NOT DISTINCT FROM NEW.recorded_by THEN
                RAISE EXCEPTION 'payment %: maker-checker, the person who recorded it cannot verify it', OLD.ref
                    USING ERRCODE = 'check_violation';
            END IF;
            IF v_status NOT IN ('sent', 'partially_paid', 'paid') THEN
                RAISE EXCEPTION 'payment %: its invoice is %', OLD.ref, v_status USING ERRCODE = 'check_violation';
            END IF;
            IF NEW.method <> 'cash' AND NEW.evidence_file_id IS NULL THEN
                RAISE EXCEPTION 'payment %: verifying needs the evidence file (bank slip, receipt) unless cash', OLD.ref
                    USING ERRCODE = 'check_violation';
            END IF;
            IF NEW.kind = 'refund' AND booking.invoice_net_paid(NEW.invoice_id) - NEW.amount < 0 THEN
                RAISE EXCEPTION 'payment %: a refund cannot take the net paid below zero', OLD.ref
                    USING ERRCODE = 'check_violation';
            END IF;
        END IF;
        -- A void keeps the money invariants (review S253): a cancelled invoice holds net verified paid 0 and its
        -- payments are final; voiding a verified receipt never takes the net paid below 0 (void the refund first).
        IF NEW.voided_at IS NOT NULL AND OLD.voided_at IS NULL THEN
            IF v_deleted IS NOT NULL OR v_status IS NULL OR v_status NOT IN ('sent', 'partially_paid', 'paid') THEN
                RAISE EXCEPTION 'payment %: its invoice is %; its payments are final', OLD.ref,
                    CASE WHEN v_deleted IS NOT NULL THEN 'deleted' ELSE coalesce(v_status, 'missing') END
                    USING ERRCODE = 'check_violation';
            END IF;
            IF OLD.verified_at IS NOT NULL AND NEW.kind = 'receipt'
               AND booking.invoice_net_paid(NEW.invoice_id) - NEW.amount < 0 THEN
                RAISE EXCEPTION 'payment %: voiding it would take the net paid below zero; void the refund first',
                    OLD.ref USING ERRCODE = 'check_violation';
            END IF;
        END IF;
    END IF;
    -- The evidence is an active payment_evidence file of this payment: checked when it is set or changed AND again
    -- at verify (review S253: a file removed after it was attached must not let the payment verify). The file row is
    -- taken FOR SHARE: a removal running at the same time waits for this transaction and is then refused by
    -- ops_files_guard (the evidence of a verified payment stays), or it commits first and this check finds no
    -- active file. Lock order: invoice, payment, file (the app's remove locks the payment before the file).
    IF NEW.evidence_file_id IS NOT NULL THEN
        IF TG_OP = 'INSERT' THEN
            v_evidence := true;
        ELSIF NEW.evidence_file_id IS DISTINCT FROM OLD.evidence_file_id
              OR (NEW.verified_at IS NOT NULL AND OLD.verified_at IS NULL) THEN
            v_evidence := true;
        END IF;
    END IF;
    IF v_evidence THEN
        PERFORM 1 FROM booking.ops_files f
         WHERE f.id = NEW.evidence_file_id AND f.status = 'active' AND f.kind = 'payment_evidence'
           AND f.entity_type = 'payment' AND f.entity_id = NEW.id
           FOR SHARE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'file % is not an active evidence file of payment %', NEW.evidence_file_id, NEW.ref
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.payments_guard() IS
    'bk-028 (AA-682 S3, design D6): a payment is recorded against a sent invoice, in its currency, unverified; its money facts never change; void is final; once verified only a void changes it; verify needs the evidence file unless cash (an active payment_evidence file of this payment, re-checked at verify and locked FOR SHARE against a concurrent removal), a live invoice, and a refund never takes the net paid below 0; a void needs a live invoice (a cancelled invoice''s payments are final) and voiding a verified receipt never takes the net paid below 0; the evidence is an active payment_evidence file of this payment.';

CREATE OR REPLACE TRIGGER payments_guard
    BEFORE INSERT OR UPDATE ON booking.payments
    FOR EACH ROW EXECUTE FUNCTION booking.payments_guard();

CREATE OR REPLACE FUNCTION booking.payments_settle() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    PERFORM booking.invoice_settle(NEW.invoice_id);
    RETURN NULL;
END $$;

COMMENT ON FUNCTION booking.payments_settle() IS
    'bk-028 (AA-682 S3, critic B4): AFTER a payment is recorded, verified or voided, settle its invoice (invoice_settle locks the invoice row first).';

CREATE OR REPLACE TRIGGER payments_settle
    AFTER INSERT OR UPDATE ON booking.payments
    FOR EACH ROW EXECUTE FUNCTION booking.payments_settle();

-- Files: bk-026 rules + payment evidence of an existing, unverified, non-voided payment; attached evidence stays put
-- (bk-029 adds bills, payouts).
CREATE OR REPLACE FUNCTION booking.ops_files_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_case      UUID;
    v_channel   TEXT;
    v_verified  TIMESTAMPTZ;
    v_voided    TIMESTAMPTZ;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF OLD.status = 'removed' AND NEW.status IS DISTINCT FROM OLD.status THEN
            RAISE EXCEPTION 'file % is removed; upload it again instead', OLD.id
                USING ERRCODE = 'object_not_in_prerequisite_state';
        END IF;
        IF (NEW.kind, NEW.entity_type, NEW.entity_id, NEW.trip_case_id, NEW.s3_bucket, NEW.s3_key, NEW.content_type,
            NEW.bytes, NEW.sha256, NEW.file_name, NEW.uploaded_by, NEW.created_at)
           IS DISTINCT FROM
           (OLD.kind, OLD.entity_type, OLD.entity_id, OLD.trip_case_id, OLD.s3_bucket, OLD.s3_key, OLD.content_type,
            OLD.bytes, OLD.sha256, OLD.file_name, OLD.uploaded_by, OLD.created_at) THEN
            RAISE EXCEPTION 'file %: only its removal changes', OLD.id USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.status = 'removed' AND OLD.status = 'active' AND OLD.entity_type = 'payment' THEN
            IF EXISTS (SELECT 1 FROM booking.payments p
                        WHERE p.evidence_file_id = OLD.id AND p.verified_at IS NOT NULL) THEN
                RAISE EXCEPTION 'file % is the evidence of a verified payment; it stays', OLD.id
                    USING ERRCODE = 'check_violation';
            END IF;
            -- Review S253: the evidence a payment still points at is never removed under it (else the payment could be
            -- verified on a removed file); detach or replace it first. A voided payment is final and lets it go.
            IF EXISTS (SELECT 1 FROM booking.payments p
                        WHERE p.evidence_file_id = OLD.id AND p.voided_at IS NULL) THEN
                RAISE EXCEPTION 'file % is the attached evidence of a payment; detach or replace it before removing it',
                    OLD.id USING ERRCODE = 'check_violation';
            END IF;
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.status <> 'active' THEN
        RAISE EXCEPTION 'a file starts active' USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.entity_type = 'payment' THEN
        SELECT i.trip_case_id, tc.channel, p.verified_at, p.voided_at INTO v_case, v_channel, v_verified, v_voided
          FROM booking.payments p
          JOIN booking.invoices i ON i.id = p.invoice_id
          JOIN booking.trip_cases tc ON tc.id = i.trip_case_id
         WHERE p.id = NEW.entity_id;
        IF v_case IS NULL THEN
            RAISE EXCEPTION 'file %: payment % does not exist', NEW.id, NEW.entity_id
                USING ERRCODE = 'foreign_key_violation';
        END IF;
        IF v_verified IS NOT NULL OR v_voided IS NOT NULL THEN
            RAISE EXCEPTION 'file %: payment % is %; its evidence is fixed', NEW.id, NEW.entity_id,
                CASE WHEN v_voided IS NOT NULL THEN 'voided' ELSE 'verified' END USING ERRCODE = 'check_violation';
        END IF;
    ELSIF NEW.entity_type = 'supplier_booking' THEN
        SELECT sb.trip_case_id, tc.channel INTO v_case, v_channel
          FROM booking.supplier_bookings sb JOIN booking.trip_cases tc ON tc.id = sb.trip_case_id
         WHERE sb.id = NEW.entity_id;
        IF v_case IS NULL THEN
            RAISE EXCEPTION 'file %: supplier booking % does not exist', NEW.id, NEW.entity_id
                USING ERRCODE = 'foreign_key_violation';
        END IF;
    ELSE
        -- Supplier bills and payouts (bk-029) do not exist yet; those files replace this function.
        RAISE EXCEPTION 'files of a % arrive with a later migration', NEW.entity_type USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.trip_case_id IS DISTINCT FROM v_case THEN
        RAISE EXCEPTION 'file %: trip_case_id must be the trip case of its % %', NEW.id, NEW.entity_type, NEW.entity_id
            USING ERRCODE = 'check_violation';
    END IF;
    IF v_channel = 'b2b' THEN
        RAISE EXCEPTION 'no supplier document on a B2B trip case (DM-6.8: confirmation ref only)'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.ops_files_guard() IS
    'bk-026 + bk-028 (AA-682 D10, D12): a file starts active, only its removal changes and removed is final; files of an existing supplier booking (B2C case only) or payment evidence of an existing, unverified, non-voided payment; the evidence of a verified payment is never removed, nor the file a non-voided payment has as its evidence_file_id (detach or replace it first). bk-029 replaces this function for supplier bills and payouts.';

-- ── Derived views ────────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW booking.v_payment_schedule_status AS
SELECT s.id AS schedule_id,
       s.invoice_id,
       s.seq,
       s.kind,
       s.amount,
       s.due_date,
       w.covered::numeric(16, 2) AS covered_amount,
       (s.amount - w.covered)::numeric(16, 2) AS remaining_amount,
       CASE
           WHEN s.invoice_deleted OR s.invoice_status = 'cancelled' THEN 'cancelled'
           WHEN w.covered >= s.amount THEN 'paid'
           WHEN s.invoice_status = 'draft' THEN 'scheduled'
           WHEN s.due_date < current_date THEN 'overdue'
           WHEN s.due_date <= current_date + s.soon_days THEN 'due'
           ELSE 'scheduled'
       END AS state,
       CASE
           WHEN NOT s.invoice_deleted AND s.invoice_status IN ('sent', 'partially_paid', 'paid')
                AND w.covered < s.amount AND s.due_date < current_date
           THEN current_date - s.due_date
       END AS days_overdue
FROM (
    SELECT ps.id, ps.invoice_id, ps.seq, ps.kind, ps.amount, ps.due_date,
           i.status AS invoice_status, i.deleted_at IS NOT NULL AS invoice_deleted,
           coalesce(np.net, 0) AS net_paid,
           coalesce(sum(ps.amount) OVER (PARTITION BY ps.invoice_id ORDER BY ps.due_date, ps.seq
                                         ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS before,
           soon.days AS soon_days
      FROM booking.payment_schedule ps
      JOIN booking.invoices i ON i.id = ps.invoice_id
      LEFT JOIN LATERAL (
          SELECT sum(CASE WHEN p.kind = 'receipt' THEN p.amount ELSE -p.amount END) AS net
            FROM booking.payments p
           WHERE p.invoice_id = ps.invoice_id AND p.verified_at IS NOT NULL AND p.voided_at IS NULL
      ) np ON true
      CROSS JOIN LATERAL (
          SELECT coalesce((SELECT CASE WHEN jsonb_typeof(st.value) = 'number'
                                       THEN (st.value #>> '{}')::numeric::integer END
                             FROM booking.settings st WHERE st.key = 'payment_due_soon_days'), 7) AS days
      ) soon
) s
CROSS JOIN LATERAL (SELECT least(s.amount, greatest(s.net_paid - s.before, 0)) AS covered) w;

COMMENT ON VIEW booking.v_payment_schedule_status IS
    'bk-028 (AA-682 S3, design D9): per schedule row, the part the verified net payments cover (waterfall over the rows, oldest due first), what remains and the state: paid, overdue (due date passed), due (within payment_due_soon_days), scheduled; draft rows are scheduled, rows of a cancelled or deleted invoice cancelled. Dates in the session time zone.';

CREATE OR REPLACE VIEW booking.v_invoice_balance AS
SELECT i.id AS invoice_id,
       i.invoice_number,
       i.trip_case_id,
       i.status,
       i.deleted_at IS NOT NULL AS is_deleted,
       i.currency,
       i.total_amount,
       coalesce(p.received, 0)::numeric(16, 2) AS verified_received,
       coalesce(p.refunded, 0)::numeric(16, 2) AS verified_refunded,
       (coalesce(p.received, 0) - coalesce(p.refunded, 0))::numeric(16, 2) AS net_paid,
       coalesce(p.waiting_amount, 0)::numeric(16, 2) AS unverified_amount,
       coalesce(p.waiting_count, 0)::int AS unverified_count,
       CASE WHEN i.status = 'cancelled' OR i.deleted_at IS NOT NULL THEN NULL
            ELSE (i.total_amount - coalesce(p.received, 0) + coalesce(p.refunded, 0))::numeric(16, 2) END AS balance,
       s.next_due_date,
       coalesce(s.overdue_amount, 0)::numeric(16, 2) AS overdue_amount,
       s.oldest_overdue_date
FROM booking.invoices i
LEFT JOIN LATERAL (
    SELECT sum(x.amount) FILTER (WHERE x.kind = 'receipt' AND x.verified_at IS NOT NULL AND x.voided_at IS NULL)
               AS received,
           sum(x.amount) FILTER (WHERE x.kind = 'refund' AND x.verified_at IS NOT NULL AND x.voided_at IS NULL)
               AS refunded,
           sum(CASE WHEN x.kind = 'receipt' THEN x.amount ELSE -x.amount END)
               FILTER (WHERE x.verified_at IS NULL AND x.voided_at IS NULL) AS waiting_amount,
           count(*) FILTER (WHERE x.verified_at IS NULL AND x.voided_at IS NULL) AS waiting_count
      FROM booking.payments x
     WHERE x.invoice_id = i.id
) p ON true
LEFT JOIN LATERAL (
    SELECT min(v.due_date) FILTER (WHERE v.state IN ('scheduled', 'due', 'overdue')) AS next_due_date,
           sum(v.remaining_amount) FILTER (WHERE v.state = 'overdue') AS overdue_amount,
           min(v.due_date) FILTER (WHERE v.state = 'overdue') AS oldest_overdue_date
      FROM booking.v_payment_schedule_status v
     WHERE v.invoice_id = i.id
) s ON true;

COMMENT ON VIEW booking.v_invoice_balance IS
    'bk-028 (AA-682 S3): per invoice, the verified receipts / refunds and the net paid, what waits for verification (net amount, count), the balance (total - net paid; negative = overpaid; NULL when cancelled or deleted), the next due date and the overdue amount of its schedule.';

-- The check board: payment_verified from the invoice (B2C), NULL on an agency trip (same column list as bk-027).
CREATE OR REPLACE VIEW booking.v_trip_check_board AS
SELECT tc.id AS trip_case_id,
       tc.code AS trip_case_code,
       tc.channel,
       tc.status AS case_status,
       tc.start_date,
       tc.end_date,
       coalesce(k.total, 0)::int AS checks_total,
       coalesce(k.open, 0)::int AS checks_open,
       coalesce(k.done, 0)::int AS checks_done,
       coalesce(k.not_applicable, 0)::int AS checks_not_applicable,
       coalesce(k.overdue, 0)::int AS checks_overdue,
       k.next_due AS next_due_date,
       s.state AS supply_state,
       s.state IN ('booked', 'none') AS suppliers_confirmed,
       CASE WHEN tc.channel = 'b2b' THEN NULL::boolean
            ELSE EXISTS (SELECT 1 FROM booking.invoices i
                          WHERE i.trip_case_id = tc.id AND i.deleted_at IS NULL AND i.status = 'paid') END
           AS payment_verified
FROM booking.trip_cases tc
JOIN booking.v_trip_case_supply_state s ON s.trip_case_id = tc.id
LEFT JOIN LATERAL (
    SELECT count(*) AS total,
           count(*) FILTER (WHERE c.status = 'open') AS open,
           count(*) FILTER (WHERE c.status = 'done') AS done,
           count(*) FILTER (WHERE c.status = 'not_applicable') AS not_applicable,
           count(*) FILTER (WHERE c.status = 'open' AND c.due_date < current_date) AS overdue,
           min(c.due_date) FILTER (WHERE c.status = 'open') AS next_due
      FROM booking.trip_case_checks c
     WHERE c.trip_case_id = tc.id
) k ON true
WHERE tc.deleted_at IS NULL
  AND tc.status IN ('confirmed', 'supplier_confirming', 'invoice_sent', 'payment_pending', 'paid', 'pre_departure',
                    'on_trip');

COMMENT ON VIEW booking.v_trip_check_board IS
    'bk-027 + bk-028 (AA-682 S2/S3): per open sold trip case (confirmed .. on_trip), the stored trip checks (total / open / done / not applicable / overdue = open with due_date before today, next due date) and the derived checks: suppliers_confirmed (supply state booked or none) and payment_verified (B2C: the case''s invoice is paid by verified payments; NULL on a B2B case, which has no customer invoice).';

-- ── Fact guard on post-sale case statuses, with the money track (critic B1, B9) ─

CREATE OR REPLACE FUNCTION booking.trip_cases_post_sale_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_live     INTEGER;
    v_state    TEXT;
    v_invoice  TEXT;
    v_implied  TEXT;
BEGIN
    SELECT count(*) INTO v_live FROM booking.supplier_bookings
     WHERE trip_case_id = NEW.id AND status IN ('pending', 'requested', 'confirmed');
    -- The sent invoice of the case, if any (sent / partially_paid / paid; one live invoice per case).
    SELECT status INTO v_invoice FROM booking.invoices
     WHERE trip_case_id = NEW.id AND deleted_at IS NULL AND status IN ('sent', 'partially_paid', 'paid');
    v_implied := CASE v_invoice WHEN 'sent' THEN 'invoice_sent' WHEN 'partially_paid' THEN 'payment_pending'
                                WHEN 'paid' THEN 'paid' END;

    IF NEW.status = 'supplier_confirming' AND v_live = 0 THEN
        RAISE EXCEPTION 'trip case %: supplier_confirming needs a live supplier booking', NEW.code
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.status = 'confirmed' AND OLD.status = 'supplier_confirming' AND v_live > 0 THEN
        RAISE EXCEPTION 'trip case %: back to confirmed only when no live supplier booking is left', NEW.code
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.status IN ('confirmed', 'supplier_confirming') AND OLD.status IN ('invoice_sent', 'payment_pending', 'paid')
       AND v_invoice IS NOT NULL THEN
        RAISE EXCEPTION 'trip case %: back from % only once its invoice is cancelled', NEW.code, OLD.status
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.status = 'pre_departure' THEN
        SELECT state INTO v_state FROM booking.v_trip_case_supply_state WHERE trip_case_id = NEW.id;
        IF v_state IS DISTINCT FROM 'booked' AND v_state IS DISTINCT FROM 'none' THEN
            RAISE EXCEPTION 'trip case %: pre_departure needs every supplier booking confirmed (supply is %)',
                NEW.code, v_state USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.channel <> 'b2b' AND v_invoice IS DISTINCT FROM 'paid' THEN
            RAISE EXCEPTION 'trip case %: a B2C case reaches pre_departure only once its invoice is paid', NEW.code
                USING ERRCODE = 'check_violation';
        END IF;
    ELSIF NEW.status = 'on_trip' AND (NEW.start_date IS NULL OR NEW.start_date > current_date) THEN
        RAISE EXCEPTION 'trip case %: on_trip only from its start date', NEW.code USING ERRCODE = 'check_violation';
    ELSIF NEW.status = 'completed' AND (NEW.end_date IS NULL OR NEW.end_date >= current_date) THEN
        RAISE EXCEPTION 'trip case %: completed only after its end date', NEW.code USING ERRCODE = 'check_violation';
    ELSIF NEW.status IN ('invoice_sent', 'payment_pending', 'paid') THEN
        IF NEW.channel = 'b2b' THEN
            RAISE EXCEPTION 'trip case %: a B2B case has no money status (no customer invoice)', NEW.code
                USING ERRCODE = 'check_violation';
        END IF;
        IF v_implied IS DISTINCT FROM NEW.status THEN
            RAISE EXCEPTION 'trip case %: % must be what its invoice says (%)', NEW.code, NEW.status,
                coalesce(v_invoice, 'no sent invoice') USING ERRCODE = 'check_violation';
        END IF;
    ELSIF NEW.status = 'new_inquiry' AND OLD.status = 'cancelled' THEN
        IF v_live > 0 THEN
            RAISE EXCEPTION 'trip case %: cancel its % live supplier booking(s) before reopening it', NEW.code, v_live
                USING ERRCODE = 'check_violation';
        END IF;
        IF EXISTS (SELECT 1 FROM booking.invoices
                    WHERE trip_case_id = NEW.id AND deleted_at IS NULL AND status <> 'cancelled') THEN
            RAISE EXCEPTION 'trip case %: cancel its invoice before reopening it', NEW.code
                USING ERRCODE = 'check_violation';
        END IF;
        IF EXISTS (SELECT 1 FROM booking.payments p JOIN booking.invoices i ON i.id = p.invoice_id
                    WHERE i.trip_case_id = NEW.id AND p.voided_at IS NULL AND p.verified_at IS NULL) THEN
            RAISE EXCEPTION 'trip case %: a payment still waits for verification', NEW.code
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.trip_cases_post_sale_guard() IS
    'bk-026 + bk-028 (AA-682 critic B1, B9): the fact behind each post-sale case status: supplier bookings, supply state, dates and (bk-028) the invoice: invoice_sent / payment_pending / paid equal its sent / partially_paid / paid state and never on a B2B case; a B2C case reaches pre_departure only once paid; back from a money status only once the invoice is cancelled; reopen refused while a live supplier booking, a non-cancelled invoice or a payment waiting for verification exists.';

-- ── Settings (policy data; Ms. Thu's answers change values by migration or run-script, design §11) ─

INSERT INTO booking.settings (key, value, description) VALUES
    ('deposit_due_days', '3'::jsonb, 'Days after the invoice is sent that the deposit (deposit_pct of the total) is due (AA-682 S3, design Q4; policy data, proposed for Ms. Thu).'),
    ('balance_due_days_before_start', '30'::jsonb, 'Days before the trip start date the balance is due; when that date is not after the deposit due date the invoice asks for one payment (AA-682 S3, design Q4; policy data).'),
    ('payment_due_soon_days', '7'::jsonb, 'Days before its due date a payment schedule row counts as due soon and reminds staff and the customer feed (AA-682 S3; policy data).'),
    ('payment_overdue_reminder_days', '[1, 7]'::jsonb, 'Days after the due date an unpaid schedule row reminds staff and the customer feed (once per step; AA-682 S3; policy data).'),
    ('invoice_issuer', '{"name": "Adventure Asia (legal name to be set)", "address": "(registered address to be set)"}'::jsonb, 'Who issues the payment request (legal name, address). PLACEHOLDER in the public migration; the real value is set by a DB Migrate run-script (AA-682 S3).'),
    ('payment_instructions', '"Payment details will be confirmed by your trip consultant."'::jsonb, 'How the customer pays (bank details text) shown on the payment request. PLACEHOLDER in the public migration; the real bank details are set by a DB Migrate run-script, never in Git (AA-682 S3).')
ON CONFLICT (key) DO NOTHING;

-- ── Grants (per object) ──────────────────────────────────────────────────────

-- invoices: insert, then the working columns change; the money state only through the guard; never deleted.
REVOKE ALL ON booking.invoices FROM booking;
GRANT SELECT, INSERT ON booking.invoices TO booking;
GRANT UPDATE (status, total_amount, issued_at, sent_by, bill_to_name, bill_to_email, bill_to_address, notes, terms,
              cancelled_at, cancelled_by, cancel_reason, deleted_at, updated_by, updated_at)
    ON booking.invoices TO booking;
GRANT USAGE, SELECT ON SEQUENCE booking.invoice_number_seq TO booking;

-- invoice_items / payment_schedule: DELETE is the draft edit (and the uncovered schedule rows of an amendment); the
-- guards refuse every other delete.
REVOKE ALL ON booking.invoice_items FROM booking;
GRANT SELECT, INSERT, DELETE ON booking.invoice_items TO booking;
GRANT UPDATE (position, description, quantity, unit_price, amount, reason, updated_by, updated_at)
    ON booking.invoice_items TO booking;

REVOKE ALL ON booking.payment_schedule FROM booking;
GRANT SELECT, INSERT, DELETE ON booking.payment_schedule TO booking;
GRANT UPDATE (seq, kind, amount, due_date, updated_by, updated_at) ON booking.payment_schedule TO booking;

-- payments: insert, then reference / note / evidence before verify, verify, void; never deleted.
REVOKE ALL ON booking.payments FROM booking;
GRANT SELECT, INSERT ON booking.payments TO booking;
GRANT UPDATE (reference, note, evidence_file_id, verified_by, verified_at, voided_by, voided_at, void_reason,
              updated_by, updated_at)
    ON booking.payments TO booking;
GRANT USAGE, SELECT ON SEQUENCE booking.payment_ref_seq TO booking;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON booking.v_payment_schedule_status FROM booking;
GRANT SELECT ON booking.v_payment_schedule_status TO booking;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON booking.v_invoice_balance FROM booking;
GRANT SELECT ON booking.v_invoice_balance TO booking;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON booking.v_trip_check_board FROM booking;
GRANT SELECT ON booking.v_trip_check_board TO booking;

GRANT EXECUTE ON FUNCTION booking.invoice_net_paid(UUID) TO booking;
GRANT EXECUTE ON FUNCTION booking.invoice_money_state(UUID, NUMERIC) TO booking;
GRANT EXECUTE ON FUNCTION booking.invoice_settle(UUID) TO booking;
GRANT EXECUTE ON FUNCTION booking.invoices_guard() TO booking;
GRANT EXECUTE ON FUNCTION booking.invoice_items_guard() TO booking;
GRANT EXECUTE ON FUNCTION booking.invoice_items_settle() TO booking;
GRANT EXECUTE ON FUNCTION booking.payment_schedule_guard() TO booking;
GRANT EXECUTE ON FUNCTION booking.invoice_sums_check() TO booking;
GRANT EXECUTE ON FUNCTION booking.payments_guard() TO booking;
GRANT EXECUTE ON FUNCTION booking.payments_settle() TO booking;
GRANT EXECUTE ON FUNCTION booking.ops_files_guard() TO booking;
GRANT EXECUTE ON FUNCTION booking.trip_cases_post_sale_guard() TO booking;

DO $$
DECLARE
    v_rel TEXT;
BEGIN
    FOREACH v_rel IN ARRAY ARRAY['booking.invoices', 'booking.payments', 'booking.v_payment_schedule_status',
                                 'booking.v_invoice_balance'] LOOP
        IF has_table_privilege('booking', v_rel, 'DELETE') OR has_table_privilege('booking', v_rel, 'TRUNCATE') THEN
            RAISE EXCEPTION 'bk-028: role booking can delete from %', v_rel;
        END IF;
    END LOOP;
    IF has_table_privilege('booking', 'booking.invoice_items', 'TRUNCATE')
       OR has_table_privilege('booking', 'booking.payment_schedule', 'TRUNCATE') THEN
        RAISE EXCEPTION 'bk-028: role booking can truncate invoice lines or the schedule';
    END IF;
    IF has_column_privilege('booking', 'booking.invoices', 'currency', 'UPDATE')
       OR has_column_privilege('booking', 'booking.invoices', 'trip_case_id', 'UPDATE')
       OR has_column_privilege('booking', 'booking.payments', 'amount', 'UPDATE')
       OR has_column_privilege('booking', 'booking.payments', 'recorded_by', 'UPDATE') THEN
        RAISE EXCEPTION 'bk-028: role booking can rewrite a money fact';
    END IF;
    IF has_table_privilege('cis_app', 'booking.invoices', 'SELECT')
       OR has_table_privilege('cis_app', 'booking.payments', 'SELECT')
       OR has_table_privilege('cis_app', 'booking.v_invoice_balance', 'SELECT') THEN
        RAISE EXCEPTION 'bk-028: cis_app can read invoices or payments';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-028', now(), 'AA-682 S3: invoices (proforma, one live per B2C case) + invoice_items + payment_schedule + payments (maker-checker, Idempotency-Key), money guard / settle / sums triggers, v_payment_schedule_status, v_invoice_balance, invoice + case money edges, trip_cases_post_sale_guard / ops_files_guard / v_trip_check_board replaced, settings deposit_due_days / balance_due_days_before_start / payment_due_soon_days / payment_overdue_reminder_days / invoice_issuer / payment_instructions (placeholders)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
