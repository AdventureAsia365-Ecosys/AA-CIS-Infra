-- Migration bk-030: AA-682 slice S4 — supplier bills (what a supplier asks AA to pay, matched to confirmed supplier
-- bookings) and supplier payouts (money AA paid out against an approved bill), with maker-checker and DB-enforced
-- states (operations MVP, S252 design §3.4 / §4, with the critic notes 2 and 9; the design names this key bk-029,
-- which AA-996 took for the catalog geo profiles).
--
-- Owner: AA-Booking (key bk-NNN). A byte-identical copy goes to AA-CIS-Infra
-- db/migrations/booking/030_supplier_bills_payouts.sql and is applied to Dev by the DB Migrate workflow (check, then
-- apply), as bk_owner (the live owner of schema booking since bk-014). Never run it from a laptop.
--
-- Depends on bk-003 (staff_users, set_updated_at), bk-008 (suppliers), bk-026 (ops_transitions, ops_check_transition,
-- ops_files, supplier_bookings) and bk-028 (ops_files_guard body for payment evidence, payments). Every grant names
-- its object.
--
-- What it adds (docs/implementation-notes/AA-682.md, section S4):
--   * booking.supplier_bills (BIL-000123): a supplier's bill (its own bill_number, unique per supplier among bills
--     that are not cancelled) in one currency, with an issue and a due date, optionally tied to one trip case.
--     status received -> approved -> paid, received / approved -> cancelled (with a reason; an approved bill only while
--     no payout is live), paid -> approved (a payout voided). While received the bill is a working draft: its facts,
--     its lines and its document change freely and need not add up. APPROVE is the check (the "amendment window" of
--     bk-028 without a flag: the received state is the window): approved_by <> created_by and <> facts_edited_by (the
--     last person who changed the money facts or the lines: maker-checker, CHECK and guard), at least one line, the
--     lines add up to the amount; from then on facts, lines and document are fixed.
--     paid is DERIVED: approved / paid must equal what the live payouts imply (paid <=> live payouts = amount), so the
--     application cannot mark a bill paid without recorded payouts. idempotency_key + request_sha256 (critic B6
--     rule of bk-028): a replayed create returns the stored bill, another body is a 409.
--   * booking.supplier_bill_items: the lines of a bill, one per supplier booking (PK bill + booking), amount in the
--     bill currency. A line names a CONFIRMED booking of the bill's supplier (and of the bill's case when the bill has
--     one), inserted or deleted only while the bill is received; never updated (the app deletes and inserts). A
--     booking may sit on several bills (a supplier deposit, then the balance). A line is inserted by the bill's
--     facts_edited_by (the app marks the bill edited by the person replacing its lines first), so a second person
--     cannot change the lines and then approve them.
--   * booking.supplier_payouts (SPO-000123): money AA paid a supplier against an APPROVED bill, recorded by hand: amount
--     in the bill currency, method, paid_on, reference (never a card number: the API refuses one), note, evidence file.
--     The recorder is never the person who entered the bill nor the last one who changed its money facts
--     (maker-checker, guard). The live payouts never exceed the
--     bill amount. Idempotency-Key unique per bill + request_sha256. Void is final, with a reason; the money facts
--     never change. supplier_payouts_settle (AFTER) settles the bill.
--   * booking.supplier_bill_settle(): locks the bill row FOR UPDATE FIRST (critic B4: two concurrent payouts would
--     otherwise each sum without the other's row under READ COMMITTED), then sets status approved / paid and paid_at
--     from the live payouts. supplier_payouts_guard locks the bill first too; so does supplier_bill_items_guard, so a
--     line insert racing an approve waits and is then refused.
--   * booking.v_supplier_bill_balance: per bill, the live payouts (count, sum), the balance, the paid share of each
--     line is not tracked (a payout pays the bill), overdue = an unpaid, not cancelled bill past its due date.
--   * ops_files_guard REPLACED: bk-026 / bk-028 rules + supplier bill documents (kind supplier_bill, entity
--     supplier_bill: only while the bill is received; never when the bill touches a B2B case, DM-6.8: a hotel bill
--     names its guests) and payout evidence (kind payout_evidence, entity supplier_payout: a bank slip of AA's own
--     transfer, allowed on every case, only while the payout is live). The current document of an approved / paid
--     bill and the current evidence of a live payout are never removed; a received bill's attached document is
--     detached first (the app does it).
--   * ops_transitions rows of entity supplier_bill (the entity value has existed since bk-026).
--   * settings row supplier_bill_due_soon_days 3 (policy data; bk_ops_reminders writes supplier_bill.due).
--
-- Not here: no trip case status, no outbox event, no customer data. B2B cases take bills and payouts (design D12) but
-- no bill document.
--
-- Locks: the three tables and the view are new and empty; CREATE OR REPLACE FUNCTION ops_files_guard takes no table
-- lock (its bk-026 trigger stays); the ops_transitions / settings inserts take ROW EXCLUSIVE. lock_timeout 5s.
-- Re-runnable (the Integration Tests replay every file): IF NOT EXISTS everywhere, CREATE OR REPLACE for functions,
-- triggers and the view (same column list), ON CONFLICT DO NOTHING for seed rows, grants repeat.
-- Undo (a later bk- file): DROP the view, supplier_payouts, supplier_bill_items, supplier_bills, their functions and
-- sequences, DELETE the supplier_bill edges and the settings row, restore the bk-028 body of ops_files_guard (only
-- while no ops_files row of kind supplier_bill / payout_evidence exists).

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF current_user <> 'bk_owner' THEN
        RAISE EXCEPTION 'bk-030: expected to run as bk_owner (live owner of schema booking), running as %', current_user;
    END IF;
    IF to_regclass('booking.supplier_bookings') IS NULL OR to_regclass('booking.ops_files') IS NULL
       OR to_regclass('booking.payments') IS NULL THEN
        RAISE EXCEPTION 'bk-030: needs bk-026 (supplier_bookings, ops_files) and bk-028 (payments) first';
    END IF;
END $$;

-- ── Edges: supplier bills (ops_transitions) ──────────────────────────────────

INSERT INTO booking.ops_transitions (entity, from_status, to_status) VALUES
    ('supplier_bill', 'received', 'approved'),
    ('supplier_bill', 'received', 'cancelled'),
    ('supplier_bill', 'approved', 'paid'),
    ('supplier_bill', 'approved', 'cancelled'),
    ('supplier_bill', 'paid', 'approved')
ON CONFLICT DO NOTHING;

-- ── Supplier bills ───────────────────────────────────────────────────────────

CREATE SEQUENCE IF NOT EXISTS booking.supplier_bill_code_seq;

CREATE TABLE IF NOT EXISTS booking.supplier_bills (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code              TEXT NOT NULL DEFAULT ('BIL-' || lpad(nextval('booking.supplier_bill_code_seq')::text, 6, '0')),
    supplier_id       UUID NOT NULL REFERENCES booking.suppliers (id),
    trip_case_id      UUID REFERENCES booking.trip_cases (id),
    bill_number       TEXT NOT NULL,
    currency          CHARACTER(3) NOT NULL,
    amount            NUMERIC(16, 2) NOT NULL,
    issue_date        DATE NOT NULL,
    due_date          DATE NOT NULL,
    document_file_id  UUID REFERENCES booking.ops_files (id),
    status            TEXT NOT NULL DEFAULT 'received',
    notes             TEXT,
    idempotency_key   TEXT NOT NULL,
    request_sha256    TEXT NOT NULL,
    created_by        TEXT NOT NULL REFERENCES booking.staff_users (cis_user_id),
    -- Set by supplier_bills_guard: created_by at insert, updated_by when the money facts change; the app sets it to
    -- the editor before it replaces the lines (supplier_bill_items_guard checks it).
    facts_edited_by   TEXT NOT NULL REFERENCES booking.staff_users (cis_user_id),
    approved_by       TEXT REFERENCES booking.staff_users (cis_user_id),
    approved_at       TIMESTAMPTZ,
    paid_at           TIMESTAMPTZ,
    cancelled_by      TEXT REFERENCES booking.staff_users (cis_user_id),
    cancelled_at      TIMESTAMPTZ,
    cancel_reason     TEXT,
    updated_by        TEXT REFERENCES booking.staff_users (cis_user_id),
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT supplier_bills_code_chk CHECK (code ~ '^BIL-[0-9]{6,}$'),
    CONSTRAINT supplier_bills_number_chk CHECK (length(bill_number) BETWEEN 1 AND 100),
    CONSTRAINT supplier_bills_currency_chk CHECK (currency ~ '^[A-Z]{3}$'),
    CONSTRAINT supplier_bills_amount_chk CHECK (amount > 0),
    CONSTRAINT supplier_bills_dates_chk CHECK (issue_date >= DATE '2020-01-01' AND due_date >= issue_date),
    CONSTRAINT supplier_bills_status_chk CHECK (status IN ('received', 'approved', 'paid', 'cancelled')),
    CONSTRAINT supplier_bills_notes_chk CHECK (notes IS NULL OR length(notes) BETWEEN 1 AND 2000),
    CONSTRAINT supplier_bills_idempotency_chk CHECK (
        length(idempotency_key) BETWEEN 8 AND 200 AND request_sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT supplier_bills_approved_chk CHECK (
        (approved_by IS NULL) = (approved_at IS NULL)
        AND (status <> 'received' OR approved_at IS NULL)
        AND (status NOT IN ('approved', 'paid') OR approved_at IS NOT NULL)),
    -- Maker-checker (design §5 bill.approve): the person who approves is never the person who entered the bill, nor
    -- the last person who changed its money facts or lines (review of S4: B edits A's bill, then B approves it).
    CONSTRAINT supplier_bills_maker_checker_chk CHECK (
        approved_by IS NULL OR (approved_by <> created_by AND approved_by <> facts_edited_by)),
    CONSTRAINT supplier_bills_paid_chk CHECK ((status = 'paid') = (paid_at IS NOT NULL)),
    CONSTRAINT supplier_bills_cancel_chk CHECK (
        (status = 'cancelled') = (cancelled_at IS NOT NULL AND cancel_reason IS NOT NULL AND cancelled_by IS NOT NULL)
        AND (cancel_reason IS NULL OR length(cancel_reason) BETWEEN 1 AND 500))
);

COMMENT ON TABLE booking.supplier_bills IS
    'bk-030 (AA-682 S4): a bill a supplier sent AA, matched to confirmed supplier bookings (supplier_bill_items). received (working draft) -> approved (another person; lines add up to the amount) -> paid (derived: live payouts = amount) ; received / approved -> cancelled (reason; no live payout); paid -> approved on a payout void. Edges in booking.ops_transitions (supplier_bill). Never deleted.';
COMMENT ON COLUMN booking.supplier_bills.bill_number IS
    'conf:commercial; the supplier''s own invoice number, unique per supplier among bills not cancelled (bk-030).';
COMMENT ON COLUMN booking.supplier_bills.amount IS
    'conf:commercial; what the supplier asks AA to pay, in currency; the lines add up to it at approval (bk-030).';
COMMENT ON COLUMN booking.supplier_bills.notes IS
    'pii:free_text; also conf:commercial (staff notes on the bill; may name a traveller, so the field help says: no traveller names on a B2B case, DM-6.8; bk-030).';
COMMENT ON COLUMN booking.supplier_bills.cancel_reason IS
    'pii:free_text; why the bill was cancelled (bk-030).';
COMMENT ON COLUMN booking.supplier_bills.trip_case_id IS
    'bk-030: the trip case the bill is for, when it is for one (a supplier''s monthly statement covers several); its lines then come from that case only.';
COMMENT ON COLUMN booking.supplier_bills.facts_edited_by IS
    'bk-030: the last staff user who set the money facts (bill number, currency, amount, dates, supplier, case) or the lines; never the approver nor the payout recorder (maker-checker). Set by supplier_bills_guard.';
COMMENT ON COLUMN booking.supplier_bills.idempotency_key IS
    'bk-030 (bk-028 critic B6 rule): the Idempotency-Key of the create call; with request_sha256 a replay returns this bill and another body is refused.';

CREATE UNIQUE INDEX IF NOT EXISTS supplier_bills_code_uq ON booking.supplier_bills (code);
CREATE UNIQUE INDEX IF NOT EXISTS supplier_bills_idempotency_uq ON booking.supplier_bills (idempotency_key);
-- The supplier's bill number once per supplier among the bills that are not cancelled (a cancelled one can be entered
-- again correctly).
CREATE UNIQUE INDEX IF NOT EXISTS supplier_bills_number_uq
    ON booking.supplier_bills (supplier_id, lower(bill_number)) WHERE status <> 'cancelled';
CREATE INDEX IF NOT EXISTS supplier_bills_supplier_idx ON booking.supplier_bills (supplier_id, due_date);
CREATE INDEX IF NOT EXISTS supplier_bills_open_idx
    ON booking.supplier_bills (due_date) WHERE status IN ('received', 'approved');
CREATE INDEX IF NOT EXISTS supplier_bills_trip_case_idx
    ON booking.supplier_bills (trip_case_id) WHERE trip_case_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS supplier_bills_document_idx
    ON booking.supplier_bills (document_file_id) WHERE document_file_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS supplier_bills_created_by_idx ON booking.supplier_bills (created_by);
CREATE INDEX IF NOT EXISTS supplier_bills_facts_edited_by_idx ON booking.supplier_bills (facts_edited_by);
CREATE INDEX IF NOT EXISTS supplier_bills_approved_by_idx
    ON booking.supplier_bills (approved_by) WHERE approved_by IS NOT NULL;
CREATE INDEX IF NOT EXISTS supplier_bills_cancelled_by_idx
    ON booking.supplier_bills (cancelled_by) WHERE cancelled_by IS NOT NULL;
CREATE INDEX IF NOT EXISTS supplier_bills_updated_by_idx
    ON booking.supplier_bills (updated_by) WHERE updated_by IS NOT NULL;

CREATE OR REPLACE TRIGGER supplier_bills_set_updated_at
    BEFORE UPDATE ON booking.supplier_bills
    FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();

CREATE OR REPLACE TRIGGER supplier_bills_check_transition
    BEFORE UPDATE OF status ON booking.supplier_bills
    FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status)
    EXECUTE FUNCTION booking.ops_check_transition('supplier_bill');

-- ── Lines ────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.supplier_bill_items (
    bill_id              UUID NOT NULL REFERENCES booking.supplier_bills (id),
    supplier_booking_id  UUID NOT NULL REFERENCES booking.supplier_bookings (id),
    amount               NUMERIC(16, 2) NOT NULL,
    created_by           TEXT REFERENCES booking.staff_users (cis_user_id),
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT supplier_bill_items_pk PRIMARY KEY (bill_id, supplier_booking_id),
    CONSTRAINT supplier_bill_items_amount_chk CHECK (amount > 0)
);

COMMENT ON TABLE booking.supplier_bill_items IS
    'bk-030 (AA-682 S4): one line of a supplier bill per confirmed supplier booking of the bill''s supplier (and case, when the bill has one), in the bill currency. Inserted / deleted only while the bill is received; never updated.';
COMMENT ON COLUMN booking.supplier_bill_items.amount IS
    'conf:commercial; the part of the bill for this supplier booking, in the bill currency (bk-030).';

CREATE INDEX IF NOT EXISTS supplier_bill_items_booking_idx ON booking.supplier_bill_items (supplier_booking_id);
CREATE INDEX IF NOT EXISTS supplier_bill_items_created_by_idx
    ON booking.supplier_bill_items (created_by) WHERE created_by IS NOT NULL;

-- ── Payouts ──────────────────────────────────────────────────────────────────

CREATE SEQUENCE IF NOT EXISTS booking.supplier_payout_code_seq;

CREATE TABLE IF NOT EXISTS booking.supplier_payouts (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code              TEXT NOT NULL DEFAULT ('SPO-' || lpad(nextval('booking.supplier_payout_code_seq')::text, 6, '0')),
    bill_id           UUID NOT NULL REFERENCES booking.supplier_bills (id),
    amount            NUMERIC(16, 2) NOT NULL,
    currency          CHARACTER(3) NOT NULL,
    method            TEXT NOT NULL,
    paid_on           DATE NOT NULL,
    reference         TEXT,
    note              TEXT,
    evidence_file_id  UUID REFERENCES booking.ops_files (id),
    idempotency_key   TEXT NOT NULL,
    request_sha256    TEXT NOT NULL,
    recorded_by       TEXT NOT NULL REFERENCES booking.staff_users (cis_user_id),
    recorded_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    voided_by         TEXT REFERENCES booking.staff_users (cis_user_id),
    voided_at         TIMESTAMPTZ,
    void_reason       TEXT,
    updated_by        TEXT REFERENCES booking.staff_users (cis_user_id),
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT supplier_payouts_code_chk CHECK (code ~ '^SPO-[0-9]{6,}$'),
    CONSTRAINT supplier_payouts_amount_chk CHECK (amount > 0),
    CONSTRAINT supplier_payouts_currency_chk CHECK (currency ~ '^[A-Z]{3}$'),
    CONSTRAINT supplier_payouts_method_chk CHECK (method IN ('bank_transfer', 'card_offline', 'cash', 'other')),
    CONSTRAINT supplier_payouts_paid_on_chk CHECK (paid_on >= DATE '2020-01-01'),
    CONSTRAINT supplier_payouts_text_chk CHECK (
        (reference IS NULL OR length(reference) BETWEEN 1 AND 100) AND (note IS NULL OR length(note) BETWEEN 1 AND 2000)),
    CONSTRAINT supplier_payouts_idempotency_chk CHECK (
        length(idempotency_key) BETWEEN 8 AND 200 AND request_sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT supplier_payouts_void_chk CHECK (
        (voided_at IS NULL) = (void_reason IS NULL) AND (voided_at IS NULL) = (voided_by IS NULL)
        AND (void_reason IS NULL OR length(void_reason) BETWEEN 1 AND 500))
);

COMMENT ON TABLE booking.supplier_payouts IS
    'bk-030 (AA-682 S4): money AA paid a supplier against an approved bill, recorded by hand (no provider) by someone other than the person who entered the bill. Live (not voided) payouts never exceed the bill amount and settle it (paid when they reach it). Void is final, with a reason. Idempotency-Key unique per bill. Never deleted.';
COMMENT ON COLUMN booking.supplier_payouts.amount IS
    'conf:commercial; paid to the supplier, in the bill currency (bk-030).';
COMMENT ON COLUMN booking.supplier_payouts.reference IS
    'conf:commercial; AA''s bank or receipt reference of the transfer, never a card number (the API refuses a card-like number; bk-030).';
COMMENT ON COLUMN booking.supplier_payouts.note IS
    'pii:free_text; staff note on the payout (bk-030).';
COMMENT ON COLUMN booking.supplier_payouts.void_reason IS
    'pii:free_text; why the payout was voided (bk-030).';
COMMENT ON COLUMN booking.supplier_payouts.idempotency_key IS
    'bk-030: the Idempotency-Key of the record call, unique per bill; with request_sha256 a replay returns this payout and another body is refused.';

CREATE UNIQUE INDEX IF NOT EXISTS supplier_payouts_code_uq ON booking.supplier_payouts (code);
CREATE UNIQUE INDEX IF NOT EXISTS supplier_payouts_idempotency_uq
    ON booking.supplier_payouts (bill_id, idempotency_key);
CREATE INDEX IF NOT EXISTS supplier_payouts_bill_idx ON booking.supplier_payouts (bill_id, recorded_at);
CREATE INDEX IF NOT EXISTS supplier_payouts_paid_on_idx ON booking.supplier_payouts (paid_on);
CREATE INDEX IF NOT EXISTS supplier_payouts_reference_idx
    ON booking.supplier_payouts (method, reference) WHERE voided_at IS NULL AND reference IS NOT NULL;
CREATE INDEX IF NOT EXISTS supplier_payouts_evidence_idx
    ON booking.supplier_payouts (evidence_file_id) WHERE evidence_file_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS supplier_payouts_recorded_by_idx ON booking.supplier_payouts (recorded_by);
CREATE INDEX IF NOT EXISTS supplier_payouts_voided_by_idx
    ON booking.supplier_payouts (voided_by) WHERE voided_by IS NOT NULL;
CREATE INDEX IF NOT EXISTS supplier_payouts_updated_by_idx
    ON booking.supplier_payouts (updated_by) WHERE updated_by IS NOT NULL;

CREATE OR REPLACE TRIGGER supplier_payouts_set_updated_at
    BEFORE UPDATE ON booking.supplier_payouts
    FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();

-- ── Money functions ──────────────────────────────────────────────────────────

-- Live (not voided) payouts of a bill.
CREATE OR REPLACE FUNCTION booking.supplier_bill_paid(p_bill UUID) RETURNS NUMERIC
    LANGUAGE sql
    STABLE
    SET search_path = pg_catalog
AS $$
    SELECT coalesce(sum(o.amount), 0) FROM booking.supplier_payouts o WHERE o.bill_id = p_bill AND o.voided_at IS NULL
$$;

COMMENT ON FUNCTION booking.supplier_bill_paid(UUID) IS
    'bk-030 (AA-682 S4): the sum of the live (not voided) payouts of a supplier bill.';

-- Recompute a bill's money state. Locks the bill row FIRST (critic B4), so concurrent payouts of one bill run one after
-- the other and the second one's next statement sees the first one's committed row.
CREATE OR REPLACE FUNCTION booking.supplier_bill_settle(p_bill UUID) RETURNS TEXT
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_status  TEXT;
    v_amount  NUMERIC;
    v_new     TEXT;
BEGIN
    SELECT status, amount INTO v_status, v_amount FROM booking.supplier_bills WHERE id = p_bill FOR UPDATE;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;
    v_new := v_status;
    IF v_status IN ('approved', 'paid') THEN
        v_new := CASE WHEN booking.supplier_bill_paid(p_bill) >= v_amount THEN 'paid' ELSE 'approved' END;
    END IF;
    UPDATE booking.supplier_bills
       SET status = v_new, paid_at = CASE WHEN v_new = 'paid' THEN coalesce(paid_at, now()) END
     WHERE id = p_bill AND status IS DISTINCT FROM v_new;
    RETURN v_new;
END $$;

COMMENT ON FUNCTION booking.supplier_bill_settle(UUID) IS
    'bk-030 (AA-682 S4, critic B4): lock the supplier bill row FOR UPDATE, then set an approved / paid bill to paid when its live payouts reach the amount, else approved (paid_at follows). Called by the payout trigger; never SECURITY DEFINER (runs as the writer).';

-- ── Guards ───────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION booking.supplier_bills_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_lines   INTEGER;
    v_sum     NUMERIC;
    v_paid    NUMERIC;
    v_live    INTEGER;
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'received' OR NEW.approved_at IS NOT NULL OR NEW.paid_at IS NOT NULL
           OR NEW.cancelled_at IS NOT NULL THEN
            RAISE EXCEPTION 'a supplier bill starts received' USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.document_file_id IS NOT NULL THEN
            RAISE EXCEPTION 'a supplier bill gets its document after it exists (upload with the bill as entity)'
                USING ERRCODE = 'check_violation';
        END IF;
        NEW.facts_edited_by := NEW.created_by;  -- whoever enters the bill set its facts
        RETURN NEW;
    END IF;
    IF (NEW.code, NEW.created_by, NEW.created_at, NEW.idempotency_key, NEW.request_sha256)
       IS DISTINCT FROM (OLD.code, OLD.created_by, OLD.created_at, OLD.idempotency_key, OLD.request_sha256) THEN
        RAISE EXCEPTION 'supplier bill %: code, creator and key never change', OLD.code
            USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.status = 'cancelled' THEN
        RAISE EXCEPTION 'supplier bill % is cancelled; it is final', OLD.code USING ERRCODE = 'check_violation';
    END IF;
    -- The facts and the document change only while the bill is received (the working draft) and stays received.
    IF (OLD.status <> 'received' OR NEW.status <> 'received')
       AND (NEW.supplier_id, NEW.trip_case_id, NEW.bill_number, NEW.currency, NEW.amount, NEW.issue_date, NEW.due_date,
            NEW.document_file_id)
           IS DISTINCT FROM
           (OLD.supplier_id, OLD.trip_case_id, OLD.bill_number, OLD.currency, OLD.amount, OLD.issue_date, OLD.due_date,
            OLD.document_file_id) THEN
        RAISE EXCEPTION 'supplier bill %: its facts and document change only while it is received', OLD.code
            USING ERRCODE = 'check_violation';
    END IF;
    -- Maker-checker input: who last set the money facts. A fact change records its author (updated_by); otherwise
    -- the app may only mark the editor of the lines (itself, while received) before it replaces them.
    IF (NEW.supplier_id, NEW.trip_case_id, NEW.bill_number, NEW.currency, NEW.amount, NEW.issue_date, NEW.due_date)
       IS DISTINCT FROM
       (OLD.supplier_id, OLD.trip_case_id, OLD.bill_number, OLD.currency, OLD.amount, OLD.issue_date, OLD.due_date) THEN
        IF NEW.updated_by IS NULL THEN
            RAISE EXCEPTION 'supplier bill %: say who changes its facts (updated_by)', OLD.code
                USING ERRCODE = 'check_violation';
        END IF;
        NEW.facts_edited_by := NEW.updated_by;
    ELSIF NEW.facts_edited_by IS DISTINCT FROM OLD.facts_edited_by
          AND (OLD.status <> 'received' OR NEW.status <> 'received'
               OR NEW.facts_edited_by IS DISTINCT FROM NEW.updated_by) THEN
        RAISE EXCEPTION 'supplier bill %: facts_edited_by names the person editing a received bill (updated_by)',
            OLD.code USING ERRCODE = 'check_violation';
    END IF;
    -- The lines were checked against the supplier and the case when they were added: those two stay while lines exist.
    IF (NEW.supplier_id, NEW.trip_case_id) IS DISTINCT FROM (OLD.supplier_id, OLD.trip_case_id)
       AND EXISTS (SELECT 1 FROM booking.supplier_bill_items WHERE bill_id = OLD.id) THEN
        RAISE EXCEPTION 'supplier bill %: remove its lines before changing the supplier or the trip case', OLD.code
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.document_file_id IS NOT NULL AND NEW.document_file_id IS DISTINCT FROM OLD.document_file_id THEN
        PERFORM 1 FROM booking.ops_files f
         WHERE f.id = NEW.document_file_id AND f.status = 'active' AND f.kind = 'supplier_bill'
           AND f.entity_type = 'supplier_bill' AND f.entity_id = NEW.id
           FOR SHARE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'file % is not an active document of supplier bill %', NEW.document_file_id, NEW.code
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    -- Approve: another person (CHECK too), at least one line, the lines add up to the amount.
    IF OLD.status = 'received' AND NEW.status = 'approved' THEN
        IF NEW.approved_by IS NOT DISTINCT FROM NEW.created_by THEN
            RAISE EXCEPTION 'supplier bill %: maker-checker, the person who entered it cannot approve it', OLD.code
                USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.approved_by IS NOT DISTINCT FROM NEW.facts_edited_by THEN
            RAISE EXCEPTION 'supplier bill %: maker-checker, the person who last changed its amounts cannot approve it',
                OLD.code USING ERRCODE = 'check_violation';
        END IF;
        SELECT count(*), coalesce(sum(amount), 0) INTO v_lines, v_sum
          FROM booking.supplier_bill_items WHERE bill_id = OLD.id;
        IF v_lines = 0 THEN
            RAISE EXCEPTION 'supplier bill %: match it to at least one confirmed supplier booking before approving',
                OLD.code USING ERRCODE = 'check_violation';
        END IF;
        IF v_sum <> NEW.amount THEN
            RAISE EXCEPTION 'supplier bill %: the lines add up to % but the bill is %', OLD.code, v_sum, NEW.amount
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    IF OLD.status IN ('approved', 'paid') AND NEW.approved_by IS DISTINCT FROM OLD.approved_by THEN
        RAISE EXCEPTION 'supplier bill %: the approval is fixed', OLD.code USING ERRCODE = 'check_violation';
    END IF;
    -- Money states are derived from the live payouts (paid only by payouts; a void steps back).
    IF NEW.status IN ('approved', 'paid') OR (NEW.status = 'cancelled' AND OLD.status IN ('approved', 'paid')) THEN
        SELECT coalesce(sum(o.amount), 0), count(*) INTO v_paid, v_live
          FROM booking.supplier_payouts o WHERE o.bill_id = OLD.id AND o.voided_at IS NULL;
        IF NEW.status = 'cancelled' AND v_live > 0 THEN
            RAISE EXCEPTION 'supplier bill % has % live payout(s); void them before cancelling', OLD.code, v_live
                USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.status = 'paid' AND v_paid < NEW.amount THEN
            RAISE EXCEPTION 'supplier bill %: paid needs payouts of % (live payouts: %)', OLD.code, NEW.amount, v_paid
                USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.status = 'approved' AND v_paid >= NEW.amount THEN
            RAISE EXCEPTION 'supplier bill %: its payouts cover it, it is paid', OLD.code
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.supplier_bills_guard() IS
    'bk-030 (AA-682 S4): a bill starts received with no document; code / creator / key never change; cancelled is final; facts and document change only while received (supplier and case stay while lines exist); the document is an active supplier_bill file of this bill; facts_edited_by follows the author of a fact change (or the app marks the editor of the lines while received); approve needs another person than created_by and facts_edited_by, >= 1 line and lines = amount; approved / paid equal the live payouts (paid <=> payouts = amount); cancel needs no live payout.';

CREATE OR REPLACE TRIGGER supplier_bills_guard
    BEFORE INSERT OR UPDATE ON booking.supplier_bills
    FOR EACH ROW EXECUTE FUNCTION booking.supplier_bills_guard();

CREATE OR REPLACE FUNCTION booking.supplier_bill_items_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_bill      booking.supplier_bills%ROWTYPE;
    v_booking   RECORD;
BEGIN
    -- Lock the bill first: a line change racing an approve waits for it and then sees the bill approved.
    SELECT * INTO v_bill FROM booking.supplier_bills
     WHERE id = CASE WHEN TG_OP = 'DELETE' THEN OLD.bill_id ELSE NEW.bill_id END FOR UPDATE;
    IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'a supplier bill line is never updated; delete it and add it again while the bill is received'
            USING ERRCODE = 'check_violation';
    END IF;
    IF v_bill.status IS DISTINCT FROM 'received' THEN
        RAISE EXCEPTION 'supplier bill % is %: its lines are fixed', v_bill.code, coalesce(v_bill.status, 'missing')
            USING ERRCODE = 'check_violation';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    -- Maker-checker: the person adding a line is the bill's last editor (the app marks the bill first), so whoever
    -- changes the lines can never approve them.
    IF NEW.created_by IS NULL OR NEW.created_by IS DISTINCT FROM v_bill.facts_edited_by THEN
        RAISE EXCEPTION 'supplier bill %: a line is added by the person editing the bill (set facts_edited_by first)',
            v_bill.code USING ERRCODE = 'check_violation';
    END IF;
    SELECT sb.code, sb.status, sb.supplier_id, sb.trip_case_id, tc.channel INTO v_booking
      FROM booking.supplier_bookings sb JOIN booking.trip_cases tc ON tc.id = sb.trip_case_id
     WHERE sb.id = NEW.supplier_booking_id;
    IF v_booking.status IS DISTINCT FROM 'confirmed' THEN
        RAISE EXCEPTION 'supplier booking % is %: a bill line names a confirmed booking',
            coalesce(v_booking.code, NEW.supplier_booking_id::text), coalesce(v_booking.status, 'missing')
            USING ERRCODE = 'check_violation';
    END IF;
    IF v_booking.supplier_id <> v_bill.supplier_id THEN
        RAISE EXCEPTION 'supplier booking % is with another supplier than bill %', v_booking.code, v_bill.code
            USING ERRCODE = 'check_violation';
    END IF;
    IF v_bill.trip_case_id IS NOT NULL AND v_booking.trip_case_id <> v_bill.trip_case_id THEN
        RAISE EXCEPTION 'supplier booking % is of another trip case than bill %', v_booking.code, v_bill.code
            USING ERRCODE = 'check_violation';
    END IF;
    -- DM-6.8: a bill with a document (it names guests) never covers a B2B booking.
    IF v_booking.channel = 'b2b' AND EXISTS (
        SELECT 1 FROM booking.ops_files f
         WHERE f.entity_type = 'supplier_bill' AND f.entity_id = v_bill.id AND f.status = 'active'
    ) THEN
        RAISE EXCEPTION 'supplier bill % has a document; it cannot cover the B2B booking % (DM-6.8)', v_bill.code,
            v_booking.code USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.supplier_bill_items_guard() IS
    'bk-030 (AA-682 S4): lines change (insert / delete, never update) only while the bill is received, after locking the bill row; a line is added by the bill''s facts_edited_by (maker-checker); a line names a confirmed booking of the bill''s supplier (and case); a bill with a document never covers a B2B booking (DM-6.8).';

CREATE OR REPLACE TRIGGER supplier_bill_items_guard
    BEFORE INSERT OR UPDATE OR DELETE ON booking.supplier_bill_items
    FOR EACH ROW EXECUTE FUNCTION booking.supplier_bill_items_guard();

CREATE OR REPLACE FUNCTION booking.supplier_payouts_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_bill  booking.supplier_bills%ROWTYPE;
BEGIN
    -- Lock the bill first (critic B4): payouts of one bill never race each other or a cancel.
    SELECT * INTO v_bill FROM booking.supplier_bills WHERE id = NEW.bill_id FOR UPDATE;
    IF TG_OP = 'INSERT' THEN
        IF v_bill.status IS DISTINCT FROM 'approved' THEN
            RAISE EXCEPTION 'a payout goes on an approved bill (bill % is %)', coalesce(v_bill.code, 'missing'),
                coalesce(v_bill.status, 'missing') USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.currency IS DISTINCT FROM v_bill.currency THEN
            RAISE EXCEPTION 'a payout is in its bill currency %', v_bill.currency USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.voided_at IS NOT NULL THEN
            RAISE EXCEPTION 'a payout starts live (not voided)' USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.recorded_by = v_bill.created_by OR NEW.recorded_by = v_bill.facts_edited_by THEN
            RAISE EXCEPTION 'bill %: maker-checker, the person who entered the bill or set its amounts does not pay it',
                v_bill.code USING ERRCODE = 'check_violation';
        END IF;
        IF booking.supplier_bill_paid(NEW.bill_id) + NEW.amount > v_bill.amount THEN
            RAISE EXCEPTION 'bill %: the payouts would exceed the bill amount % (already paid %)', v_bill.code,
                v_bill.amount, booking.supplier_bill_paid(NEW.bill_id) USING ERRCODE = 'check_violation';
        END IF;
    ELSE
        IF (NEW.bill_id, NEW.code, NEW.amount, NEW.currency, NEW.method, NEW.paid_on, NEW.reference, NEW.note,
            NEW.idempotency_key, NEW.request_sha256, NEW.recorded_by, NEW.recorded_at, NEW.created_at)
           IS DISTINCT FROM
           (OLD.bill_id, OLD.code, OLD.amount, OLD.currency, OLD.method, OLD.paid_on, OLD.reference, OLD.note,
            OLD.idempotency_key, OLD.request_sha256, OLD.recorded_by, OLD.recorded_at, OLD.created_at) THEN
            RAISE EXCEPTION 'payout %: its money facts never change (void it and record it again)', OLD.code
                USING ERRCODE = 'check_violation';
        END IF;
        IF OLD.voided_at IS NOT NULL THEN
            RAISE EXCEPTION 'payout % is voided; it is final', OLD.code USING ERRCODE = 'check_violation';
        END IF;
        IF OLD.evidence_file_id IS NOT NULL AND NEW.evidence_file_id IS NULL AND NEW.voided_at IS NULL THEN
            RAISE EXCEPTION 'payout %: the evidence of a live payout is replaced, never removed', OLD.code
                USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.voided_at IS NOT NULL AND v_bill.status NOT IN ('approved', 'paid') THEN
            RAISE EXCEPTION 'payout %: its bill is %', OLD.code, v_bill.status USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    IF NEW.evidence_file_id IS NOT NULL
       AND (TG_OP = 'INSERT' OR NEW.evidence_file_id IS DISTINCT FROM OLD.evidence_file_id) THEN
        PERFORM 1 FROM booking.ops_files f
         WHERE f.id = NEW.evidence_file_id AND f.status = 'active' AND f.kind = 'payout_evidence'
           AND f.entity_type = 'supplier_payout' AND f.entity_id = NEW.id
           FOR SHARE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'file % is not an active evidence file of payout %', NEW.evidence_file_id, NEW.code
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.supplier_payouts_guard() IS
    'bk-030 (AA-682 S4): lock the bill first; a payout goes on an approved bill, in its currency, by someone other than the bill''s creator and its facts_edited_by, and the live payouts never exceed the amount; its money facts never change; void is final and needs a live bill; the evidence of a live payout is replaced, never removed, and is an active payout_evidence file of this payout.';

CREATE OR REPLACE TRIGGER supplier_payouts_guard
    BEFORE INSERT OR UPDATE ON booking.supplier_payouts
    FOR EACH ROW EXECUTE FUNCTION booking.supplier_payouts_guard();

CREATE OR REPLACE FUNCTION booking.supplier_payouts_settle() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    PERFORM booking.supplier_bill_settle(NEW.bill_id);
    RETURN NULL;
END $$;

COMMENT ON FUNCTION booking.supplier_payouts_settle() IS
    'bk-030 (AA-682 S4, critic B4): AFTER a payout is recorded or voided, settle its bill (supplier_bill_settle locks the bill row first).';

CREATE OR REPLACE TRIGGER supplier_payouts_settle
    AFTER INSERT OR UPDATE ON booking.supplier_payouts
    FOR EACH ROW EXECUTE FUNCTION booking.supplier_payouts_settle();

-- Files: bk-026 + bk-028 rules + supplier bill documents and payout evidence.
CREATE OR REPLACE FUNCTION booking.ops_files_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_case      UUID;
    v_channel   TEXT;
    v_verified  TIMESTAMPTZ;
    v_voided    TIMESTAMPTZ;
    v_status    TEXT;
    v_b2b       BOOLEAN := false;
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
        -- bk-030: the document of an approved / paid bill stays; a received bill detaches it first.
        IF NEW.status = 'removed' AND OLD.status = 'active' AND OLD.entity_type = 'supplier_bill' THEN
            IF EXISTS (SELECT 1 FROM booking.supplier_bills b
                        WHERE b.document_file_id = OLD.id AND b.status IN ('approved', 'paid')) THEN
                RAISE EXCEPTION 'file % is the document of an approved supplier bill; it stays', OLD.id
                    USING ERRCODE = 'check_violation';
            END IF;
            IF EXISTS (SELECT 1 FROM booking.supplier_bills b
                        WHERE b.document_file_id = OLD.id AND b.status = 'received') THEN
                RAISE EXCEPTION 'file % is the attached document of a supplier bill; detach it before removing it',
                    OLD.id USING ERRCODE = 'check_violation';
            END IF;
        END IF;
        -- bk-030: the evidence a live payout points at stays (replace it with another file first).
        IF NEW.status = 'removed' AND OLD.status = 'active' AND OLD.entity_type = 'supplier_payout' THEN
            IF EXISTS (SELECT 1 FROM booking.supplier_payouts o
                        WHERE o.evidence_file_id = OLD.id AND o.voided_at IS NULL) THEN
                RAISE EXCEPTION 'file % is the evidence of a live payout; it stays (upload a replacement first)', OLD.id
                    USING ERRCODE = 'check_violation';
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
        v_b2b := v_channel = 'b2b';
    ELSIF NEW.entity_type = 'supplier_booking' THEN
        SELECT sb.trip_case_id, tc.channel INTO v_case, v_channel
          FROM booking.supplier_bookings sb JOIN booking.trip_cases tc ON tc.id = sb.trip_case_id
         WHERE sb.id = NEW.entity_id;
        IF v_case IS NULL THEN
            RAISE EXCEPTION 'file %: supplier booking % does not exist', NEW.id, NEW.entity_id
                USING ERRCODE = 'foreign_key_violation';
        END IF;
        v_b2b := v_channel = 'b2b';
    ELSIF NEW.entity_type = 'supplier_bill' THEN
        SELECT b.trip_case_id, b.status INTO v_case, v_status FROM booking.supplier_bills b WHERE b.id = NEW.entity_id;
        IF v_status IS NULL THEN
            RAISE EXCEPTION 'file %: supplier bill % does not exist', NEW.id, NEW.entity_id
                USING ERRCODE = 'foreign_key_violation';
        END IF;
        IF v_status <> 'received' THEN
            RAISE EXCEPTION 'file %: supplier bill % is %; its document is fixed', NEW.id, NEW.entity_id, v_status
                USING ERRCODE = 'check_violation';
        END IF;
        -- A supplier's bill names the guests: never on a bill that touches a B2B case (DM-6.8).
        v_b2b := EXISTS (SELECT 1 FROM booking.trip_cases tc WHERE tc.id = v_case AND tc.channel = 'b2b')
              OR EXISTS (SELECT 1 FROM booking.supplier_bill_items it
                           JOIN booking.supplier_bookings sb ON sb.id = it.supplier_booking_id
                           JOIN booking.trip_cases tc ON tc.id = sb.trip_case_id
                          WHERE it.bill_id = NEW.entity_id AND tc.channel = 'b2b');
    ELSIF NEW.entity_type = 'supplier_payout' THEN
        SELECT b.trip_case_id, o.voided_at INTO v_case, v_voided
          FROM booking.supplier_payouts o JOIN booking.supplier_bills b ON b.id = o.bill_id
         WHERE o.id = NEW.entity_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'file %: payout % does not exist', NEW.id, NEW.entity_id
                USING ERRCODE = 'foreign_key_violation';
        END IF;
        IF v_voided IS NOT NULL THEN
            RAISE EXCEPTION 'file %: payout % is voided; its evidence is fixed', NEW.id, NEW.entity_id
                USING ERRCODE = 'check_violation';
        END IF;
        -- AA's own bank slip to a supplier names no traveller: allowed on every case.
    ELSE
        RAISE EXCEPTION 'file %: unknown entity type %', NEW.id, NEW.entity_type USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.trip_case_id IS DISTINCT FROM v_case THEN
        RAISE EXCEPTION 'file %: trip_case_id must be the trip case of its % %', NEW.id, NEW.entity_type, NEW.entity_id
            USING ERRCODE = 'check_violation';
    END IF;
    IF v_b2b THEN
        RAISE EXCEPTION 'no supplier document on a B2B trip case (DM-6.8: confirmation ref only)'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.ops_files_guard() IS
    'bk-026 + bk-028 + bk-030 (AA-682 D10, D12): a file starts active, only its removal changes and removed is final; files of an existing supplier booking (B2C case only), payment evidence of an existing, unverified, non-voided payment (the evidence of a verified payment, or the file a non-voided payment points at, is never removed), supplier bill documents of a received bill that touches no B2B case (the document of an approved / paid bill stays, a received bill detaches it first), payout evidence of a live payout (the evidence a live payout points at stays).';

-- ── Derived view ─────────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW booking.v_supplier_bill_balance AS
SELECT b.id AS bill_id,
       b.supplier_id,
       b.status,
       b.currency,
       b.amount,
       coalesce(o.paid, 0)::numeric(16, 2) AS paid_amount,
       coalesce(o.live, 0) AS live_payouts,
       CASE WHEN b.status = 'cancelled' THEN 0 ELSE b.amount - coalesce(o.paid, 0) END::numeric(16, 2) AS balance,
       coalesce(l.lines, 0) AS line_count,
       coalesce(l.total, 0)::numeric(16, 2) AS lines_amount,
       b.due_date,
       (b.status IN ('received', 'approved') AND b.due_date < current_date) AS overdue
  FROM booking.supplier_bills b
  LEFT JOIN LATERAL (
      SELECT sum(p.amount) AS paid, count(*) AS live
        FROM booking.supplier_payouts p WHERE p.bill_id = b.id AND p.voided_at IS NULL
  ) o ON true
  LEFT JOIN LATERAL (
      SELECT count(*) AS lines, sum(i.amount) AS total FROM booking.supplier_bill_items i WHERE i.bill_id = b.id
  ) l ON true;

COMMENT ON VIEW booking.v_supplier_bill_balance IS
    'bk-030 (AA-682 S4): per supplier bill, the live payouts (count, sum), the balance (0 once cancelled), the lines (count, sum) and overdue = received / approved past the due date (session time zone).';

-- ── Settings (policy data) ───────────────────────────────────────────────────

INSERT INTO booking.settings (key, value, description) VALUES
    ('supplier_bill_due_soon_days', '3'::jsonb, 'Days before its due date an unpaid supplier bill is announced to staff (bk_ops_reminders supplier_bill.due; AA-682 S4, policy data).')
ON CONFLICT (key) DO NOTHING;

-- ── Grants (per object) ──────────────────────────────────────────────────────

-- supplier_bills: insert, then column updates only; never deleted.
REVOKE ALL ON booking.supplier_bills FROM booking;
GRANT SELECT, INSERT ON booking.supplier_bills TO booking;
GRANT UPDATE (supplier_id, trip_case_id, bill_number, currency, amount, issue_date, due_date, document_file_id, status,
              notes, facts_edited_by, approved_by, approved_at, paid_at, cancelled_by, cancelled_at, cancel_reason, updated_by,
              updated_at)
    ON booking.supplier_bills TO booking;
GRANT USAGE, SELECT ON SEQUENCE booking.supplier_bill_code_seq TO booking;

-- supplier_bill_items: insert and delete while the bill is received (guard); never updated, never truncated.
REVOKE ALL ON booking.supplier_bill_items FROM booking;
GRANT SELECT, INSERT, DELETE ON booking.supplier_bill_items TO booking;

-- supplier_payouts: insert, then the evidence and the void only; never deleted.
REVOKE ALL ON booking.supplier_payouts FROM booking;
GRANT SELECT, INSERT ON booking.supplier_payouts TO booking;
GRANT UPDATE (evidence_file_id, voided_by, voided_at, void_reason, updated_by, updated_at)
    ON booking.supplier_payouts TO booking;
GRANT USAGE, SELECT ON SEQUENCE booking.supplier_payout_code_seq TO booking;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON booking.v_supplier_bill_balance FROM booking;
GRANT SELECT ON booking.v_supplier_bill_balance TO booking;

GRANT EXECUTE ON FUNCTION booking.supplier_bill_paid(UUID) TO booking;
GRANT EXECUTE ON FUNCTION booking.supplier_bill_settle(UUID) TO booking;
GRANT EXECUTE ON FUNCTION booking.supplier_bills_guard() TO booking;
GRANT EXECUTE ON FUNCTION booking.supplier_bill_items_guard() TO booking;
GRANT EXECUTE ON FUNCTION booking.supplier_payouts_guard() TO booking;
GRANT EXECUTE ON FUNCTION booking.supplier_payouts_settle() TO booking;
GRANT EXECUTE ON FUNCTION booking.ops_files_guard() TO booking;

DO $$
DECLARE
    v_rel TEXT;
BEGIN
    FOREACH v_rel IN ARRAY ARRAY['booking.supplier_bills', 'booking.supplier_payouts',
                                 'booking.v_supplier_bill_balance'] LOOP
        IF has_table_privilege('booking', v_rel, 'DELETE') OR has_table_privilege('booking', v_rel, 'TRUNCATE') THEN
            RAISE EXCEPTION 'bk-030: role booking can delete from %', v_rel;
        END IF;
    END LOOP;
    IF has_table_privilege('booking', 'booking.supplier_bill_items', 'TRUNCATE')
       OR has_table_privilege('booking', 'booking.supplier_bill_items', 'UPDATE') THEN
        RAISE EXCEPTION 'bk-030: role booking can truncate or update supplier bill lines';
    END IF;
    IF has_column_privilege('booking', 'booking.supplier_bills', 'created_by', 'UPDATE')
       OR has_column_privilege('booking', 'booking.supplier_payouts', 'amount', 'UPDATE')
       OR has_column_privilege('booking', 'booking.supplier_payouts', 'recorded_by', 'UPDATE')
       OR has_column_privilege('booking', 'booking.supplier_payouts', 'bill_id', 'UPDATE') THEN
        RAISE EXCEPTION 'bk-030: role booking can rewrite a money fact';
    END IF;
    IF has_table_privilege('cis_app', 'booking.supplier_bills', 'SELECT')
       OR has_table_privilege('cis_app', 'booking.supplier_payouts', 'SELECT')
       OR has_table_privilege('cis_app', 'booking.supplier_bill_items', 'SELECT')
       OR has_table_privilege('cis_app', 'booking.v_supplier_bill_balance', 'SELECT') THEN
        RAISE EXCEPTION 'bk-030: cis_app can read supplier bills or payouts';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-030', now(), 'AA-682 S4: supplier_bills (BIL-, received -> approved (maker-checker, lines = amount) -> paid derived from payouts), supplier_bill_items (confirmed bookings of the bill''s supplier), supplier_payouts (SPO-, Idempotency-Key, recorder <> bill creator, never above the bill), supplier_bill_settle, v_supplier_bill_balance, supplier_bill edges, ops_files_guard replaced (bill documents, payout evidence), settings supplier_bill_due_soon_days')
ON CONFLICT (version) DO NOTHING;

COMMIT;
