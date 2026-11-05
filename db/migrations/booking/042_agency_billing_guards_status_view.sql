-- Migration bk-042: AA-1037 R4 slice 1 — the database rules of agency billing (bk-041) and the contract view
-- booking.v_tenant_billing_status that CIS reads (root ADR 0019 d9: "Booking publishes the billing status, the CIS
-- tenant_billing_tick reads it; CIS stays the only writer of the account state").
--
-- Owner: AA-Booking (key bk-NNN). AA-CIS-Infra Migration Sync copies it byte for byte to
-- db/migrations/booking/042_agency_billing_guards_status_view.sql; on Dev it is applied as bk_owner (the live owner of
-- schema booking since bk-014) by Infra Migration Apply once every job table is idle (root ADR 0017a), or by a person
-- with DB Migrate apply. Never run it from a laptop.
--
-- Depends on bk-041 (the seven billing tables) and bk-017 (USAGE on schema booking for cis_app).
--
-- What:
--   1. Privileges: role booking loses DELETE on agency_payment, invoice_sequence, tax_rule and billing_entity (rows
--      are deactivated or decided, never deleted; the default privileges of bk-014 gave DELETE on every new table).
--      agency_invoice / agency_invoice_line / billing_terms keep DELETE: a draft and its lines may be removed, an
--      agency's terms override may be dropped (the guards below refuse the rest).
--   2. booking.agency_invoice_guard (BEFORE UPDATE OR DELETE): only a draft is deleted; an issued, paid or void
--      invoice keeps every fact (number, agency, kind, period, currency, money, snapshots, issue fields, due date);
--      the status moves only draft -> issued, issued -> paid (approved payments cover the total, checked here),
--      issued -> void (no approved payment); e_invoice_no is set once on an issued or paid invoice; staff_note stays
--      editable; updated_at follows.
--   3. booking.agency_invoice_line_guard (BEFORE INSERT OR UPDATE OR DELETE): lines change only while their invoice
--      is a draft; the one later change is voided = true when the invoice is void. A line never moves: its key
--      (invoice_id, invoice_kind, line_no) is fixed on UPDATE, so no line leaves an issued, paid or void invoice.
--   4. booking.agency_payment_guard (BEFORE INSERT OR UPDATE): a payment is recorded against an issued invoice, in
--      its currency, starting 'recorded'; afterwards only the decision (approve / reject, once) is written; an
--      approval never takes the approved total above the invoice total. AFTER: booking.agency_payment_settle marks
--      the invoice paid when the approved payments cover it (the money state is derived by the database, like
--      bk-028's invoice_settle).
--   5. updated_at triggers on billing_entity, tax_rule, billing_terms and agency_payment (booking.set_updated_at).
--   6. booking.v_tenant_billing_status: one row per B2B partner (= every CIS tenant, bk_tenant_pull): tenant_id,
--      status ok | warn | past_due, oldest_overdue_days, overdue_invoices, overdue_amount ({currency: amount}),
--      paid_through (the last day of the newest paid SaaS period), warn_after_days, suspend_after_days (the agency's
--      terms, else the default row). An invoice is overdue when it is issued, has a balance and its due date is past;
--      status = past_due from suspend_after_days overdue days, warn from warn_after_days (or as soon as it is
--      overdue when no terms row exists), else ok. No amount of a single invoice, no bill-to, no note leaves Booking.
--      SELECT to booking and to the CIS runtime role cis_app (contract read, AA-CIS-Infra db/owners.yaml
--      booking.consumer_grants + the isolation probe cell consumer.contract_grants.bk-042).
--
-- Class: contract (root ADR 0017 d3): new triggers and REVOKEs on existing tables, a replaced view definition and a
-- cross-owner grant. On Dev Migration Apply applies it when the job tables are idle (ADR 0017a); the code PR raises
-- readiness to bk-042 (MIG-4). DM-7.1: a view, no new table.
-- Locks: CREATE TRIGGER takes SHARE ROW EXCLUSIVE on the bk-041 tables (empty until the code ships). lock_timeout 5s.
-- Re-runnable (the Integration Tests replay every file): CREATE OR REPLACE, DROP TRIGGER IF EXISTS, repeatable grants.
-- Undo (a later bk- file, after the code and the CIS reader are reverted): DROP VIEW booking.v_tenant_billing_status;
-- DROP the four guard / settle triggers and functions; GRANT DELETE back.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF current_user <> 'bk_owner' THEN
        RAISE EXCEPTION 'bk-042: expected to run as bk_owner (live owner of schema booking), running as %', current_user;
    END IF;
    IF to_regclass('booking.agency_invoice') IS NULL OR to_regclass('booking.agency_payment') IS NULL
       OR to_regclass('booking.billing_terms') IS NULL THEN
        RAISE EXCEPTION 'bk-042: needs bk-041 (the agency billing tables) first';
    END IF;
END $$;

-- ── 1. Privileges ────────────────────────────────────────────────────────────────────────────────────────────────
REVOKE DELETE ON booking.agency_payment, booking.invoice_sequence, booking.tax_rule, booking.billing_entity FROM booking;

-- ── 2. Invoice guard ─────────────────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION booking.agency_invoice_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_paid numeric;
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.status <> 'draft' THEN
            RAISE EXCEPTION 'agency_invoice %: only a draft is deleted (this one is %)', OLD.id, OLD.status
                USING ERRCODE = 'restrict_violation';
        END IF;
        RETURN OLD;
    END IF;
    IF NEW.id IS DISTINCT FROM OLD.id OR NEW.created_at IS DISTINCT FROM OLD.created_at
       OR NEW.created_by IS DISTINCT FROM OLD.created_by OR NEW.source IS DISTINCT FROM OLD.source THEN
        RAISE EXCEPTION 'agency_invoice: id, created_at, created_by and source never change'
            USING ERRCODE = 'restrict_violation';
    END IF;
    IF OLD.status <> 'draft' THEN
        IF (NEW.number, NEW.party_tenant_id, NEW.invoice_kind, NEW.period_start, NEW.period_end, NEW.currency,
            NEW.subtotal, NEW.tax_rule_id, NEW.tax_rate, NEW.tax_amount, NEW.total, NEW.billing_entity_id, NEW.issuer,
            NEW.bill_to, NEW.footer_wording, NEW.issued_on, NEW.due_date, NEW.issued_at, NEW.issued_by,
            NEW.idempotency_key)
           IS DISTINCT FROM
           (OLD.number, OLD.party_tenant_id, OLD.invoice_kind, OLD.period_start, OLD.period_end, OLD.currency,
            OLD.subtotal, OLD.tax_rule_id, OLD.tax_rate, OLD.tax_amount, OLD.total, OLD.billing_entity_id, OLD.issuer,
            OLD.bill_to, OLD.footer_wording, OLD.issued_on, OLD.due_date, OLD.issued_at, OLD.issued_by,
            OLD.idempotency_key) THEN
            RAISE EXCEPTION 'agency_invoice %: an issued invoice keeps its facts (%)', OLD.number, OLD.status
                USING ERRCODE = 'restrict_violation';
        END IF;
        IF OLD.e_invoice_no IS NOT NULL
           AND (NEW.e_invoice_no, NEW.e_invoice_recorded_by, NEW.e_invoice_recorded_at)
               IS DISTINCT FROM (OLD.e_invoice_no, OLD.e_invoice_recorded_by, OLD.e_invoice_recorded_at) THEN
            RAISE EXCEPTION 'agency_invoice %: the e-invoice number is recorded once', OLD.number
                USING ERRCODE = 'restrict_violation';
        END IF;
        IF OLD.e_invoice_no IS NULL AND NEW.e_invoice_no IS NOT NULL AND OLD.status = 'void' THEN
            RAISE EXCEPTION 'agency_invoice %: a void invoice takes no e-invoice number', OLD.number
                USING ERRCODE = 'restrict_violation';
        END IF;
    END IF;
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        IF NOT ((OLD.status = 'draft' AND NEW.status = 'issued')
                OR (OLD.status = 'issued' AND NEW.status IN ('paid', 'void'))) THEN
            RAISE EXCEPTION 'agency_invoice: % -> % is not a move', OLD.status, NEW.status
                USING ERRCODE = 'check_violation';
        END IF;
        SELECT coalesce(sum(amount), 0) INTO v_paid
          FROM booking.agency_payment WHERE invoice_id = OLD.id AND status = 'approved';
        IF NEW.status = 'paid' AND v_paid < NEW.total THEN
            RAISE EXCEPTION 'agency_invoice %: paid needs approved payments covering % (approved %)', OLD.number,
                NEW.total, v_paid USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.status = 'void' AND v_paid > 0 THEN
            RAISE EXCEPTION 'agency_invoice %: an invoice with an approved payment is not voided', OLD.number
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
END
$$;
COMMENT ON FUNCTION booking.agency_invoice_guard() IS
    'AA-1037 (bk-042): only a draft is deleted; an issued invoice keeps its facts; draft -> issued -> paid | void; '
    'paid only when approved payments cover the total; e_invoice_no recorded once.';

DROP TRIGGER IF EXISTS agency_invoice_guard ON booking.agency_invoice;
CREATE TRIGGER agency_invoice_guard
    BEFORE UPDATE OR DELETE ON booking.agency_invoice
    FOR EACH ROW EXECUTE FUNCTION booking.agency_invoice_guard();

-- ── 3. Line guard ────────────────────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION booking.agency_invoice_line_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_status text;
BEGIN
    -- A line never moves to another invoice or position: the guard below reads one invoice's status only.
    IF TG_OP = 'UPDATE' AND (NEW.invoice_id, NEW.invoice_kind, NEW.line_no)
                            IS DISTINCT FROM (OLD.invoice_id, OLD.invoice_kind, OLD.line_no) THEN
        RAISE EXCEPTION 'agency_invoice_line: the key of a line (invoice, kind, line number) does not change'
            USING ERRCODE = 'restrict_violation';
    END IF;
    SELECT status INTO v_status FROM booking.agency_invoice
     WHERE id = CASE WHEN TG_OP = 'DELETE' THEN OLD.invoice_id ELSE NEW.invoice_id END;
    IF v_status IS NULL THEN
        -- the invoice itself is being deleted (a draft: ON DELETE CASCADE) or is missing (the FK refuses it)
        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    END IF;
    IF v_status = 'draft' THEN
        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    END IF;
    IF TG_OP = 'UPDATE' AND v_status = 'void' AND NOT OLD.voided AND NEW.voided
       AND (to_jsonb(NEW) - 'voided') = (to_jsonb(OLD) - 'voided') THEN
        RETURN NEW;
    END IF;
    RAISE EXCEPTION 'agency_invoice_line: the lines of a % invoice do not change', v_status
        USING ERRCODE = 'restrict_violation';
END
$$;
COMMENT ON FUNCTION booking.agency_invoice_line_guard() IS
    'AA-1037 (bk-042): lines change only while their invoice is a draft; voided = true once the invoice is void; '
    'a line''s key (invoice_id, invoice_kind, line_no) never changes.';

DROP TRIGGER IF EXISTS agency_invoice_line_guard ON booking.agency_invoice_line;
CREATE TRIGGER agency_invoice_line_guard
    BEFORE INSERT OR UPDATE OR DELETE ON booking.agency_invoice_line
    FOR EACH ROW EXECUTE FUNCTION booking.agency_invoice_line_guard();

-- ── 4. Payment guard + settle ────────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION booking.agency_payment_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_status   text;
    v_currency text;
    v_total    numeric;
    v_approved numeric;
BEGIN
    -- Lock the invoice first: two approvals of one invoice never race past its total.
    SELECT status, currency, total INTO v_status, v_currency, v_total
      FROM booking.agency_invoice WHERE id = NEW.invoice_id FOR UPDATE;
    IF TG_OP = 'INSERT' THEN
        IF v_status IS DISTINCT FROM 'issued' THEN
            RAISE EXCEPTION 'agency_payment: recorded against an issued invoice only (this one is %)',
                coalesce(v_status, 'missing') USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.currency IS DISTINCT FROM v_currency THEN
            RAISE EXCEPTION 'agency_payment: in the invoice currency %', v_currency USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.status <> 'recorded' THEN
            RAISE EXCEPTION 'agency_payment: a payment starts recorded' USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
    END IF;
    IF (NEW.id, NEW.invoice_id, NEW.amount, NEW.currency, NEW.method, NEW.received_on, NEW.reference,
        NEW.document_ref, NEW.note, NEW.recorded_by, NEW.recorded_at, NEW.idempotency_key, NEW.created_at)
       IS DISTINCT FROM
       (OLD.id, OLD.invoice_id, OLD.amount, OLD.currency, OLD.method, OLD.received_on, OLD.reference,
        OLD.document_ref, OLD.note, OLD.recorded_by, OLD.recorded_at, OLD.idempotency_key, OLD.created_at) THEN
        RAISE EXCEPTION 'agency_payment: a recorded payment keeps its facts' USING ERRCODE = 'restrict_violation';
    END IF;
    IF OLD.status <> 'recorded' THEN
        RAISE EXCEPTION 'agency_payment: the decision (%) is final', OLD.status USING ERRCODE = 'restrict_violation';
    END IF;
    IF NEW.status = 'approved' THEN
        IF v_status IS DISTINCT FROM 'issued' THEN
            RAISE EXCEPTION 'agency_payment: the invoice is % (approve against an issued invoice)',
                coalesce(v_status, 'missing') USING ERRCODE = 'check_violation';
        END IF;
        SELECT coalesce(sum(amount), 0) INTO v_approved
          FROM booking.agency_payment WHERE invoice_id = NEW.invoice_id AND status = 'approved' AND id <> NEW.id;
        IF v_approved + NEW.amount > v_total THEN
            RAISE EXCEPTION 'agency_payment: approving % would take the approved total above the invoice total %',
                NEW.amount, v_total USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END
$$;
COMMENT ON FUNCTION booking.agency_payment_guard() IS
    'AA-1037 (bk-042): recorded against an issued invoice in its currency; facts never change; one decision, final; '
    'approved payments never exceed the invoice total (the invoice row is locked first).';

DROP TRIGGER IF EXISTS agency_payment_guard ON booking.agency_payment;
CREATE TRIGGER agency_payment_guard
    BEFORE INSERT OR UPDATE ON booking.agency_payment
    FOR EACH ROW EXECUTE FUNCTION booking.agency_payment_guard();

CREATE OR REPLACE FUNCTION booking.agency_payment_settle() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    IF NEW.status = 'approved' AND OLD.status = 'recorded' THEN
        UPDATE booking.agency_invoice i
           SET status = 'paid'
         WHERE i.id = NEW.invoice_id AND i.status = 'issued'
           AND (SELECT coalesce(sum(p.amount), 0) FROM booking.agency_payment p
                 WHERE p.invoice_id = i.id AND p.status = 'approved') >= i.total;
    END IF;
    RETURN NULL;
END
$$;
COMMENT ON FUNCTION booking.agency_payment_settle() IS
    'AA-1037 (bk-042): an approval that covers the invoice total marks the invoice paid (derived money state).';

DROP TRIGGER IF EXISTS agency_payment_settle ON booking.agency_payment;
CREATE TRIGGER agency_payment_settle
    AFTER UPDATE OF status ON booking.agency_payment
    FOR EACH ROW EXECUTE FUNCTION booking.agency_payment_settle();

REVOKE ALL ON FUNCTION booking.agency_invoice_guard(), booking.agency_invoice_line_guard(),
    booking.agency_payment_guard(), booking.agency_payment_settle() FROM PUBLIC;

-- ── 5. updated_at ────────────────────────────────────────────────────────────────────────────────────────────────
DROP TRIGGER IF EXISTS billing_entity_set_updated_at ON booking.billing_entity;
CREATE TRIGGER billing_entity_set_updated_at
    BEFORE UPDATE ON booking.billing_entity FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();
DROP TRIGGER IF EXISTS tax_rule_set_updated_at ON booking.tax_rule;
CREATE TRIGGER tax_rule_set_updated_at
    BEFORE UPDATE ON booking.tax_rule FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();
DROP TRIGGER IF EXISTS billing_terms_set_updated_at ON booking.billing_terms;
CREATE TRIGGER billing_terms_set_updated_at
    BEFORE UPDATE ON booking.billing_terms FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();
DROP TRIGGER IF EXISTS agency_payment_set_updated_at ON booking.agency_payment;
CREATE TRIGGER agency_payment_set_updated_at
    BEFORE UPDATE ON booking.agency_payment FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();

-- ── 6. The CIS contract view ─────────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW booking.v_tenant_billing_status AS
WITH dflt AS (
    SELECT warn_after_days, suspend_after_days FROM booking.billing_terms WHERE party_tenant_id IS NULL
), approved AS (
    SELECT invoice_id, sum(amount) AS paid FROM booking.agency_payment WHERE status = 'approved' GROUP BY invoice_id
), overdue AS (
    SELECT i.party_tenant_id, i.currency, i.due_date, i.total - coalesce(a.paid, 0) AS balance
      FROM booking.agency_invoice i
      LEFT JOIN approved a ON a.invoice_id = i.id
     WHERE i.status = 'issued' AND i.due_date < current_date AND i.total - coalesce(a.paid, 0) > 0
), per_currency AS (
    SELECT party_tenant_id, currency, sum(balance) AS amount FROM overdue GROUP BY party_tenant_id, currency
), per_tenant AS (
    SELECT o.party_tenant_id, min(o.due_date) AS oldest_due, count(*) AS overdue_invoices,
           (SELECT jsonb_object_agg(c.currency, c.amount) FROM per_currency c
             WHERE c.party_tenant_id = o.party_tenant_id) AS overdue_amount
      FROM overdue o GROUP BY o.party_tenant_id
), paid_saas AS (
    SELECT party_tenant_id, max(period_end) - 1 AS paid_through
      FROM booking.agency_invoice WHERE invoice_kind = 'saas' AND status = 'paid' GROUP BY party_tenant_id
), terms AS (
    SELECT b.tenant_id,
           coalesce(t.warn_after_days, d.warn_after_days)::integer AS warn_after_days,
           coalesce(t.suspend_after_days, d.suspend_after_days)::integer AS suspend_after_days
      FROM booking.b2b_partners b
      LEFT JOIN booking.billing_terms t ON t.party_tenant_id = b.tenant_id
      LEFT JOIN dflt d ON true
)
SELECT tm.tenant_id,
       CASE
           WHEN pt.oldest_due IS NULL THEN 'ok'
           WHEN tm.suspend_after_days IS NOT NULL AND current_date - pt.oldest_due >= tm.suspend_after_days
               THEN 'past_due'
           WHEN tm.warn_after_days IS NULL OR current_date - pt.oldest_due >= tm.warn_after_days THEN 'warn'
           ELSE 'ok'
       END AS status,
       coalesce(current_date - pt.oldest_due, 0) AS oldest_overdue_days,
       coalesce(pt.overdue_invoices, 0)::integer AS overdue_invoices,
       coalesce(pt.overdue_amount, '{}'::jsonb) AS overdue_amount,
       ps.paid_through,
       tm.warn_after_days,
       tm.suspend_after_days
  FROM terms tm
  LEFT JOIN per_tenant pt ON pt.party_tenant_id = tm.tenant_id
  LEFT JOIN paid_saas ps ON ps.party_tenant_id = tm.tenant_id;

COMMENT ON VIEW booking.v_tenant_billing_status IS
    'AA-1037 (bk-042, root ADR 0019 d9): the billing status of every agency for the CIS tenant_billing_tick (the only '
    'writer of the account state). status ok | warn | past_due from the oldest overdue issued invoice with a balance '
    'against the agency''s warn / suspend days (billing_terms, else the default row); overdue_amount {currency: '
    'amount}; paid_through = the last day of the newest paid SaaS period. Aggregates only: no invoice line, bill-to or '
    'note. Columns are only appended.';

REVOKE INSERT, UPDATE, DELETE ON booking.v_tenant_billing_status FROM booking;
GRANT SELECT ON booking.v_tenant_billing_status TO booking;
GRANT USAGE ON SCHEMA booking TO cis_app;
GRANT SELECT ON booking.v_tenant_billing_status TO cis_app;

DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['booking.agency_invoice', 'booking.agency_invoice_line', 'booking.agency_payment',
                             'booking.billing_terms', 'booking.billing_entity', 'booking.tax_rule',
                             'booking.invoice_sequence'] LOOP
        IF has_table_privilege('cis_app', t, 'SELECT') THEN
            RAISE EXCEPTION 'bk-042: cis_app can read % (the status view only)', t;
        END IF;
    END LOOP;
    IF NOT has_table_privilege('cis_app', 'booking.v_tenant_billing_status', 'SELECT') THEN
        RAISE EXCEPTION 'bk-042: cis_app cannot read booking.v_tenant_billing_status';
    END IF;
    IF has_table_privilege('booking', 'booking.agency_payment', 'DELETE')
       OR has_table_privilege('booking', 'booking.invoice_sequence', 'DELETE') THEN
        RAISE EXCEPTION 'bk-042: role booking can still delete payments or number series';
    END IF;
    IF has_table_privilege('booking', 'booking.v_tenant_billing_status', 'INSERT') THEN
        RAISE EXCEPTION 'bk-042: booking.v_tenant_billing_status is writable';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-042', now(), 'AA-1037 R4: agency billing guards + booking.v_tenant_billing_status (CIS reader cis_app)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
