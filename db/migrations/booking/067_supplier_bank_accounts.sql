-- Migration bk-067: AA-1158 part 2 (S289; tech lead decisions S285 A1, Q5, Q10) — supplier profile fields, supplier
-- bank accounts encrypted under a KMS key and approved by a second person with a call-back, a payout lock after a bank
-- change, the supplier_bank.* capabilities in the content + operations role, and the DB backstop on the billing
-- entity part 1 left to the API (its bank text and default flag change only in the transaction that approved the
-- change).
--
-- Owner: AA-Booking (key bk-NNN). AA-CIS-Infra Migration Sync copies it byte for byte to
-- db/migrations/booking/067_supplier_bank_accounts.sql and Migration Apply applies it on Dev as bk_owner once every
-- job table is idle (root ADR 0017a). Never run it from a laptop.
--
-- Why: a supplier's bank account is where AA sends money, and changing it is the main payout fraud path. Suppliers
-- also lack a legal entity, a tax code, contacts by role and structured payment terms. Part 1 (bk-064) left two rules
-- to the API because the running code of that time broke them (MIG-4); the code on main since then follows both. The
-- billing entity rule ships here. The supplier INSERT rule (pending with a creator, default pending) stays API-only:
-- about 30 integration tests across 10+ files insert suppliers as role booking on the 'active' default, so it needs
-- its own fixture pass (follow-up recorded in docs/implementation-notes/AA-1158.md).
--
-- What:
--   1. booking.suppliers: legal_entity, tax_code, role_contacts (jsonb array of {role, name, email, phone}),
--      payment_terms (jsonb object {basis, deposit_percent, due_days, method, note}); suppliers_profile_chk keeps the
--      shapes (the API validates the fields). They are supplier data: an edit while the supplier is not live makes
--      the editor a writer (bk-064 suppliers_writers), so the activator never decided them.
--   2. billing_entity_guard (backstop deferred from part 1): for the application role an INSERT has no payment text
--      and is not the default; an UPDATE that changes payment_instructions or turns is_default on needs an approved
--      booking.billing_entity_change of that entity decided in this transaction (decided_at = now()) with the same
--      values; turning is_default off needs an approved make_default change of another entity decided now.
--   3. booking.supplier_bank_account: the supplier's bank account as ciphertext (AES-256-GCM in the app, the data key
--      wrapped by the KMS key alias aa-booking-<env>-supplier-bank under the context {purpose, supplier_id}; key id
--      kept per row), the masked last 4, the bank name, country and currency in clear, entered_by and a reason;
--      pending -> approved (a second person with supplier_bank.approve, a call-back note required: who confirmed the
--      details on a number AA already knew), rejected, withdrawn (the person who entered it); approved -> superseded
--      when a newer account is approved. Never the person who entered it approves it, unless the business owner,
--      flagged owner_self_approved (bk-064 owner_self_approval_guard checks the CIS marker). One pending and one
--      approved account per supplier. The guard fixes what was entered (ciphertext and all) and dates every decision
--      now(); decided rows are final; the free texts may be set to '[redacted]' alone (DM-6.7).
--   4. supplier_payouts_bank_lock (a new BEFORE INSERT trigger on supplier_payouts, not a change of the bk-064 guard):
--      no payout to a supplier while one of its bank accounts is pending, nor before the newest approval is
--      supplier_bank_payout_lock_hours old (a pricing policy parameter; no value in force refuses, fail closed). It
--      takes a share lock on the supplier row, so it serialises with an approval (the app locks the supplier FOR UPDATE).
--      A supplier with no bank account on file keeps today's payouts.
--   5. Pricing policy parameters (Pricing > Policy, section security, approver group admin), seeded like bk-063:
--      supplier_bank_payout_lock_hours version 1 = 24 (Q10), and supplier_bank_contact_change_days version 1 = 30 (how
--      far back the approval of a bank account looks for supplier contact changes: the API refuses the approval when
--      the person who entered the account changed the supplier's contacts within that many days, and shows anyone
--      else's change on the approval card, so a planted call-back number never confirms a forged account).
--   6. supplier_bank.write (entry only, Q10) added to the content + operations role custom_product_ops_accounting.
--      supplier_bank.read (it decrypts full account numbers) joins the approve class of the bk-062 CHECK
--      staff_role_capability_not_approve_chk, so no custom role ever holds it (built-in admin / finance only), like
--      supplier_bank.approve (caught by the .approve suffix).
--   7. booking.supplier_profile_option: the choices of the supplier profile (contact roles, payment terms bases,
--      payment methods) as data an administrator edits (label EN / VI, order, active), seeded with today's values. A
--      code never changes and a row is never deleted (a supplier may still name it); retiring one sets active = false.
--      The API checks role_contacts[].role, payment_terms.basis and payment_terms.method against the active rows (a
--      value the supplier already holds stays valid). The basis code deposit_balance keeps its deposit percentage rule
--      in the code.
--
-- Class: contract (root ADR 0017 d3: new tables with guards, new triggers on existing tables, a CHECK, config rows).
-- Migration-only PR first (MIG-4); the code PR raises readiness to bk-067. The running code edits a billing entity's
-- bank text or default only through an approved change and never writes the new table, so nothing it does changes; the role seed adds a capability the running code does not
-- know (the custom-role resolver drops unknown capabilities); the running code never reads the option table.
-- DM-6.1: supplier_bank_account holds bank details (pii:payment, as ciphertext; account_last4 pii:payment), staff keys,
-- free texts (pii:free_text). suppliers.role_contacts is pii:contact (also name). DM-7.1: supplier_bank_account has its
-- row in the root data standards (root PR merged before the Infra copy); supplier_profile_option too (configuration,
-- no personal data).
-- Locks: ACCESS EXCLUSIVE, briefly, on suppliers (ADD COLUMN with constant defaults, a CHECK on tens of rows) and
-- staff_role_capability (the approve CHECK re-added, a few dozen rows),
-- SHARE ROW EXCLUSIVE on billing_entity and supplier_payouts (CREATE TRIGGER); lock_timeout 5s.
-- Never reads shared.v_staff_booking_grant (bk_owner has no SELECT on it): no row of the new table exists yet.
-- Re-runnable (the Integration Tests replay every file): ADD COLUMN IF NOT EXISTS, DROP CONSTRAINT IF EXISTS + ADD,
-- CREATE OR REPLACE FUNCTION / TRIGGER, CREATE TABLE / INDEX IF NOT EXISTS, ON CONFLICT DO NOTHING.
-- Number: owner main max + 1 (bk-066 on main). If it moves, renumber: file name, this header, the registration, the
-- seed ids (…b67000…) and the tests that name it (git grep '067_' and 'bk-067').
-- Undo (a later bk- file, after the code is reverted): DROP the triggers billing_entity_guard, supplier_payouts_bank_lock and their functions; DELETE the bk-067 capability row and the seed:bk-067 policy rows; restore the bk-062 approve CHECK; DROP
-- booking.supplier_profile_option, booking.supplier_bank_account (destructive: DRY RUN; it holds the approval
-- evidence) and the four supplier columns.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF to_regclass('booking.billing_entity_change') IS NULL OR to_regclass('booking.staff_role_capability') IS NULL
       OR to_regprocedure('booking.owner_self_approval_guard()') IS NULL THEN
        RAISE EXCEPTION 'bk-067: needs bk-062 and bk-064 first';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.schema_versions
                WHERE version = 'bk-067' AND description NOT LIKE 'AA-1158 %') THEN
        RAISE EXCEPTION 'bk-067: the key bk-067 is already held by another migration (not AA-1158): renumber one';
    END IF;
END $$;

-- ── 1. Supplier profile ─────────────────────────────────────────────────────────────────────────────────────────

ALTER TABLE booking.suppliers
    ADD COLUMN IF NOT EXISTS legal_entity text,
    ADD COLUMN IF NOT EXISTS tax_code text,
    ADD COLUMN IF NOT EXISTS role_contacts jsonb NOT NULL DEFAULT '[]'::jsonb,
    ADD COLUMN IF NOT EXISTS payment_terms jsonb;

ALTER TABLE booking.suppliers DROP CONSTRAINT IF EXISTS suppliers_profile_chk;
ALTER TABLE booking.suppliers ADD CONSTRAINT suppliers_profile_chk CHECK (
    (legal_entity IS NULL OR char_length(btrim(legal_entity)) BETWEEN 1 AND 300)
    AND (tax_code IS NULL OR char_length(btrim(tax_code)) BETWEEN 1 AND 64)
    AND jsonb_typeof(role_contacts) = 'array' AND jsonb_array_length(role_contacts) <= 12
    AND (payment_terms IS NULL OR jsonb_typeof(payment_terms) = 'object'));

COMMENT ON COLUMN booking.suppliers.legal_entity IS
    'conf:commercial — bk-067 (AA-1158 part 2): the supplier''s registered company name (who AA contracts with and '
    'pays).';
COMMENT ON COLUMN booking.suppliers.tax_code IS
    'conf:commercial — bk-067 (AA-1158 part 2): the supplier''s tax identification number.';
COMMENT ON COLUMN booking.suppliers.role_contacts IS
    'pii:contact; also pii:name (bk-067, AA-1158 part 2: contacts by role, a JSON array (at most 12) of '
    '{role, name, email, phone}, role a code of booking.supplier_profile_option kind contact_role; the API checks the '
    'shape).';
COMMENT ON COLUMN booking.suppliers.payment_terms IS
    'conf:commercial — bk-067 (AA-1158 part 2): the supplier''s standard payment terms, a JSON object {basis, '
    'deposit_percent, due_days, method, note}, basis and method codes of booking.supplier_profile_option (kinds '
    'terms_basis, terms_method); a contract may state its own (supplier_contracts.payment_terms).';

-- ── 2. Billing entity: bank text and default flag only through an approved change (part 1 backstop) ─────────────

CREATE OR REPLACE FUNCTION booking.billing_entity_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    IF pg_has_role(current_user, 'bk_owner', 'USAGE') THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'INSERT' THEN
        IF NEW.payment_instructions IS NOT NULL OR NEW.is_default THEN
            RAISE EXCEPTION 'a new billing entity has no payment details and is not the default; request a change'
                USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.payment_instructions IS DISTINCT FROM OLD.payment_instructions OR (NEW.is_default AND NOT OLD.is_default)
    THEN
        IF NOT EXISTS (
            SELECT 1
              FROM booking.billing_entity_change c
             WHERE c.billing_entity_id = NEW.id AND c.status = 'approved' AND c.decided_at = now()
               AND (NEW.payment_instructions IS NOT DISTINCT FROM OLD.payment_instructions
                    OR (c.set_payment_instructions
                        AND c.payment_instructions IS NOT DISTINCT FROM NEW.payment_instructions))
               AND (NOT (NEW.is_default AND NOT OLD.is_default) OR c.make_default))
        THEN
            RAISE EXCEPTION 'billing entity %: payment details and the default flag change only by an approved change',
                OLD.code USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    IF OLD.is_default AND NOT NEW.is_default AND NOT EXISTS (
        SELECT 1
          FROM booking.billing_entity_change c
         WHERE c.billing_entity_id <> NEW.id AND c.status = 'approved' AND c.make_default AND c.decided_at = now())
    THEN
        RAISE EXCEPTION 'billing entity %: the default issuer moves only by approving another entity as the default',
            OLD.code USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.billing_entity_guard() IS
    'bk-067 (AA-1158 part 2, the part 1 backstop): for the application role a new entity has no payment text and is '
    'not the default; payment_instructions or is_default on change only with an approved billing_entity_change of the '
    'entity decided in this transaction (decided_at = now()) carrying the same values; is_default off only with an '
    'approved make_default change of another entity decided now. Members of bk_owner are exempt.';

GRANT EXECUTE ON FUNCTION booking.billing_entity_guard() TO booking;

CREATE OR REPLACE TRIGGER billing_entity_guard
    BEFORE INSERT OR UPDATE ON booking.billing_entity
    FOR EACH ROW EXECUTE FUNCTION booking.billing_entity_guard();

-- ── 3. Supplier bank accounts ───────────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.supplier_bank_account (
    id                  uuid         NOT NULL DEFAULT gen_random_uuid(),
    supplier_id         uuid         NOT NULL,
    status              text         NOT NULL DEFAULT 'pending',
    bank_name           text         NOT NULL,
    bank_country        character(2),
    currency            character(3) NOT NULL,
    account_last4       text         NOT NULL,
    ciphertext          bytea        NOT NULL,
    wrapped_key         bytea        NOT NULL,
    kms_key_id          text         NOT NULL,
    enc_alg             text         NOT NULL DEFAULT 'AES-256-GCM',
    reason              text         NOT NULL,
    entered_by          text         NOT NULL,
    entered_at          timestamptz  NOT NULL DEFAULT now(),
    approved_by         text,
    approved_at         timestamptz,
    callback_note       text,
    owner_self_approved boolean      NOT NULL DEFAULT false,
    closed_by           text,
    closed_at           timestamptz,
    close_reason        text,
    CONSTRAINT supplier_bank_account_pkey PRIMARY KEY (id),
    CONSTRAINT supplier_bank_account_supplier_fkey FOREIGN KEY (supplier_id)
        REFERENCES booking.suppliers (id) ON DELETE RESTRICT,
    CONSTRAINT supplier_bank_account_status_chk CHECK (
        status IN ('pending', 'approved', 'rejected', 'withdrawn', 'superseded')
        AND (approved_by IS NULL) = (approved_at IS NULL)
        AND (approved_by IS NULL) = (callback_note IS NULL)
        AND (status IN ('approved', 'superseded')) = (approved_by IS NOT NULL)
        AND (closed_by IS NULL) = (closed_at IS NULL)
        AND (status IN ('rejected', 'withdrawn', 'superseded')) = (closed_by IS NOT NULL)
        AND (status IN ('rejected', 'withdrawn')) = (close_reason IS NOT NULL)
        AND (status <> 'withdrawn' OR closed_by = entered_by)
        AND (status <> 'rejected' OR closed_by <> entered_by)),
    CONSTRAINT supplier_bank_account_maker_checker_chk CHECK (
        approved_by IS NULL OR approved_by <> entered_by OR owner_self_approved),
    CONSTRAINT supplier_bank_account_owner_self_chk CHECK (
        owner_self_approved = (approved_by IS NOT NULL AND approved_by = entered_by)),
    CONSTRAINT supplier_bank_account_text_chk CHECK (
        char_length(btrim(bank_name)) BETWEEN 1 AND 120
        AND (bank_country IS NULL OR bank_country ~ '^[A-Z]{2}$')
        AND currency ~ '^[A-Z]{3}$'
        AND account_last4 ~ '^[0-9A-Z]{2,4}$'
        AND octet_length(ciphertext) BETWEEN 29 AND 8192
        AND octet_length(wrapped_key) BETWEEN 16 AND 2048
        AND char_length(kms_key_id) BETWEEN 1 AND 2048
        AND enc_alg = 'AES-256-GCM'
        AND char_length(btrim(reason)) BETWEEN 1 AND 300
        AND char_length(entered_by) BETWEEN 1 AND 128
        AND (approved_by IS NULL OR char_length(approved_by) BETWEEN 1 AND 128)
        AND (closed_by IS NULL OR char_length(closed_by) BETWEEN 1 AND 128)
        AND (callback_note IS NULL OR char_length(btrim(callback_note)) BETWEEN 1 AND 500)
        AND (close_reason IS NULL OR char_length(btrim(close_reason)) BETWEEN 1 AND 300)),
    CONSTRAINT supplier_bank_account_time_chk CHECK (
        (approved_at IS NULL OR approved_at >= entered_at)
        AND (closed_at IS NULL OR closed_at >= entered_at))
);

-- ON DELETE RESTRICT: the rows are accounting evidence (who entered, who called back and approved where AA sent a
-- supplier's money), kept 10 years (root DM-7.1 row). A supplier with bank account rows is never deleted by a cascade:
-- an owner erasure (DRY RUN first) decides on these rows explicitly before the supplier (role booking has no DELETE on
-- either table).
CREATE UNIQUE INDEX IF NOT EXISTS supplier_bank_account_pending_uq
    ON booking.supplier_bank_account (supplier_id) WHERE status = 'pending';
CREATE UNIQUE INDEX IF NOT EXISTS supplier_bank_account_approved_uq
    ON booking.supplier_bank_account (supplier_id) WHERE status = 'approved';
CREATE INDEX IF NOT EXISTS supplier_bank_account_supplier_idx
    ON booking.supplier_bank_account (supplier_id, entered_at DESC);

COMMENT ON TABLE booking.supplier_bank_account IS
    'bk-067 (AA-1158 part 2): a supplier''s bank account, entered pending (supplier_bank.write), approved by a second '
    'person with supplier_bank.approve after a call-back (callback_note), or by the business owner flagged '
    'owner_self_approved; rejected, withdrawn by the person who entered it, or superseded by a newer approved one. The '
    'details are ciphertext (envelope: AES-256-GCM data key wrapped by KMS, context {purpose, supplier_id}); only '
    'account_last4, the bank name, country and currency are clear. No payout to the supplier while one is pending or '
    'before the newest approval is supplier_bank_payout_lock_hours old (supplier_payouts_bank_lock).';
COMMENT ON COLUMN booking.supplier_bank_account.ciphertext IS
    'pii:payment — the account holder, number / IBAN and bank codes as AES-256-GCM ciphertext (12-byte nonce, then the '
    'ciphertext with its 16-byte tag), associated data = supplier id + row id; never decrypted in the database.';
COMMENT ON COLUMN booking.supplier_bank_account.wrapped_key IS
    'conf:credential — the row''s AES data key encrypted by KMS (CiphertextBlob of GenerateDataKey); only the Booking '
    'task role can unwrap it.';
COMMENT ON COLUMN booking.supplier_bank_account.kms_key_id IS 'The ARN of the KMS key that wrapped the data key.';
COMMENT ON COLUMN booking.supplier_bank_account.bank_name IS
    'conf:commercial — the name of the supplier''s bank (a business), shown with the masked number to every reader.';
COMMENT ON COLUMN booking.supplier_bank_account.account_last4 IS
    'pii:payment — the last (up to) 4 characters of the account number, shown masked to every reader.';
COMMENT ON COLUMN booking.supplier_bank_account.reason IS 'pii:free_text — why the account was entered or changed.';
COMMENT ON COLUMN booking.supplier_bank_account.callback_note IS
    'pii:free_text — the approver''s call-back: who at the supplier confirmed the details, on which number AA already '
    'knew, and when.';
COMMENT ON COLUMN booking.supplier_bank_account.close_reason IS 'pii:free_text — why it was rejected or withdrawn.';

REVOKE ALL ON booking.supplier_bank_account FROM booking;
GRANT SELECT, INSERT ON booking.supplier_bank_account TO booking;
GRANT UPDATE (status, approved_by, approved_at, callback_note, owner_self_approved, closed_by, closed_at, close_reason)
    ON booking.supplier_bank_account TO booking;

CREATE OR REPLACE FUNCTION booking.supplier_bank_account_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_text CONSTANT text[] := ARRAY['reason', 'callback_note', 'close_reason'];
BEGIN
    -- The schema owner (migrations, run-script, fixtures that age a row) is exempt from the shape rules; the CHECKs and
    -- the owner self-approval trigger bind everyone.
    IF pg_has_role(current_user, 'bk_owner', 'USAGE') THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'pending' OR NEW.approved_by IS NOT NULL OR NEW.closed_by IS NOT NULL
           OR NEW.owner_self_approved OR NEW.entered_at IS DISTINCT FROM now() THEN
            RAISE EXCEPTION 'a supplier bank account starts pending, undecided and entered now'
                USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
    END IF;
    -- Erasure (DM-6.7): the free texts may be set to the fixed marker, nothing else in the same update.
    IF (to_jsonb(NEW) - v_text) = (to_jsonb(OLD) - v_text)
       AND (NEW.reason IS NOT DISTINCT FROM OLD.reason OR NEW.reason = '[redacted]')
       AND (NEW.callback_note IS NOT DISTINCT FROM OLD.callback_note OR NEW.callback_note = '[redacted]')
       AND (NEW.close_reason IS NOT DISTINCT FROM OLD.close_reason OR NEW.close_reason = '[redacted]') THEN
        RETURN NEW;
    END IF;
    IF (to_jsonb(NEW) - ARRAY['status', 'approved_by', 'approved_at', 'callback_note', 'owner_self_approved',
                              'closed_by', 'closed_at', 'close_reason'])
       IS DISTINCT FROM
       (to_jsonb(OLD) - ARRAY['status', 'approved_by', 'approved_at', 'callback_note', 'owner_self_approved',
                              'closed_by', 'closed_at', 'close_reason']) THEN
        RAISE EXCEPTION 'supplier bank account %: what was entered never changes (enter a new one)', OLD.id
            USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.status = 'pending' AND NEW.status = 'approved' THEN
        IF NEW.approved_at IS DISTINCT FROM now() OR NEW.closed_by IS NOT NULL THEN
            RAISE EXCEPTION 'supplier bank account %: an approval is dated now', OLD.id USING ERRCODE = 'check_violation';
        END IF;
    ELSIF OLD.status = 'pending' AND NEW.status IN ('rejected', 'withdrawn') THEN
        IF NEW.closed_at IS DISTINCT FROM now() OR NEW.approved_by IS NOT NULL THEN
            RAISE EXCEPTION 'supplier bank account %: a decision is dated now', OLD.id USING ERRCODE = 'check_violation';
        END IF;
    ELSIF OLD.status = 'approved' AND NEW.status = 'superseded' THEN
        IF NEW.closed_at IS DISTINCT FROM now()
           OR (NEW.approved_by, NEW.approved_at, NEW.callback_note, NEW.owner_self_approved)
              IS DISTINCT FROM (OLD.approved_by, OLD.approved_at, OLD.callback_note, OLD.owner_self_approved) THEN
            RAISE EXCEPTION 'supplier bank account %: superseded now, its approval kept', OLD.id
                USING ERRCODE = 'check_violation';
        END IF;
    ELSE
        RAISE EXCEPTION 'supplier bank account % is %; only pending -> approved / rejected / withdrawn and approved -> '
            'superseded', OLD.id, OLD.status USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.supplier_bank_account_guard() IS
    'bk-067 (AA-1158 part 2): for the application role an account starts pending, undecided and entered now; what was '
    'entered never changes; only pending -> approved / rejected / withdrawn and approved -> superseded, dated now(); '
    'decided rows are otherwise final; reason, callback_note and close_reason may be set to [redacted], alone '
    '(DM-6.7). Members of bk_owner are exempt (the CHECKs and the owner self-approval trigger are not).';

GRANT EXECUTE ON FUNCTION booking.supplier_bank_account_guard() TO booking;

CREATE OR REPLACE TRIGGER supplier_bank_account_guard
    BEFORE INSERT OR UPDATE ON booking.supplier_bank_account
    FOR EACH ROW EXECUTE FUNCTION booking.supplier_bank_account_guard();

CREATE OR REPLACE TRIGGER supplier_bank_account_owner_self_approval
    BEFORE INSERT OR UPDATE ON booking.supplier_bank_account
    FOR EACH ROW EXECUTE FUNCTION booking.owner_self_approval_guard('approved_by', 'owner_self_approved', 'final');

-- ── 4. The payout lock after a bank change ──────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION booking.supplier_payouts_bank_lock() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_supplier uuid;
    v_pending  boolean;
    v_last     timestamptz;
    v_hours    numeric;
BEGIN
    SELECT b.supplier_id INTO v_supplier FROM booking.supplier_bills b WHERE b.id = NEW.bill_id;
    IF v_supplier IS NULL THEN
        RETURN NEW;  -- supplier_payouts_guard refuses a payout without its bill
    END IF;
    -- A share lock on the supplier: an approval (the app locks the supplier FOR UPDATE first) and a payout never pass
    -- each other.
    PERFORM 1 FROM booking.suppliers s WHERE s.id = v_supplier FOR SHARE;
    SELECT coalesce(bool_or(a.status = 'pending'), false), max(a.approved_at) FILTER (WHERE a.status = 'approved')
      INTO v_pending, v_last
      FROM booking.supplier_bank_account a
     WHERE a.supplier_id = v_supplier;
    IF v_pending THEN
        RAISE EXCEPTION 'bank_account_pending: the supplier has a bank account change waiting for approval; no payout '
            'until it is decided' USING ERRCODE = 'check_violation';
    END IF;
    IF v_last IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT (p.value #>> '{}')::numeric INTO v_hours
      FROM booking.pricing_policy p
      JOIN booking.pricing_policy_events e ON e.policy_id = p.id AND e.event = 'approved'
     WHERE p.param_key = 'supplier_bank_payout_lock_hours'
       AND p.effective_from <= (now() AT TIME ZONE 'UTC')::date
     ORDER BY p.effective_from DESC, e.created_at DESC, p.version_no DESC
     LIMIT 1;
    IF v_hours IS NULL THEN
        RAISE EXCEPTION 'bank_payout_lock_unavailable: no approved supplier_bank_payout_lock_hours is in force'
            USING ERRCODE = 'check_violation';
    END IF;
    IF now() < v_last + v_hours * interval '1 hour' THEN
        RAISE EXCEPTION 'bank_payout_locked: the supplier''s bank account was approved at %; payouts open at %', v_last,
            v_last + v_hours * interval '1 hour' USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.supplier_payouts_bank_lock() IS
    'bk-067 (AA-1158 part 2): no payout to a supplier while one of its bank accounts is pending, nor before its newest '
    'approved account is supplier_bank_payout_lock_hours old (pricing policy, value in force today; none refuses). A '
    'supplier with no bank account on file is not locked. Share-locks the supplier row.';

GRANT EXECUTE ON FUNCTION booking.supplier_payouts_bank_lock() TO booking;

CREATE OR REPLACE TRIGGER supplier_payouts_bank_lock
    BEFORE INSERT ON booking.supplier_payouts
    FOR EACH ROW EXECUTE FUNCTION booking.supplier_payouts_bank_lock();

-- ── 5. Policy parameter (Pricing > Policy, section security, approver group admin) ──────────────────────────────

INSERT INTO booking.pricing_policy (id, param_key, version_no, value, unit, effective_from, reason, created_by)
VALUES
    ('00000000-0000-4000-8000-0000b6700000', 'supplier_bank_payout_lock_hours', 1, '24'::jsonb, 'hours',
     DATE '2026-01-01',
     'Tech lead decision Q10: no supplier payout for 24 hours after a bank account change is approved.', 'seed:bk-067'),
    ('00000000-0000-4000-8000-0000b6700010', 'supplier_bank_contact_change_days', 1, '30'::jsonb, 'days',
     DATE '2026-01-01',
     'Seeded default (proposed, the administrator group may change it): a bank account change is not approved when the '
     'person who entered it changed the supplier contacts in the last 30 days.', 'seed:bk-067')
ON CONFLICT DO NOTHING;

INSERT INTO booking.pricing_policy_events (id, policy_id, maker, event, actor)
SELECT v.id, p.id, p.created_by, 'submitted', p.created_by
  FROM (VALUES ('00000000-0000-4000-8000-0000b6700001'::uuid, '00000000-0000-4000-8000-0000b6700000'::uuid),
               ('00000000-0000-4000-8000-0000b6700011'::uuid, '00000000-0000-4000-8000-0000b6700010'::uuid)) AS v (id, pid)
  JOIN booking.pricing_policy p ON p.id = v.pid AND p.created_by = 'seed:bk-067'
ON CONFLICT DO NOTHING;

INSERT INTO booking.pricing_policy_events (id, policy_id, maker, event, actor)
SELECT v.id, p.id, p.created_by, 'approved', v.actor
  FROM (VALUES ('00000000-0000-4000-8000-0000b6700002'::uuid, '00000000-0000-4000-8000-0000b6700000'::uuid,
                'tech lead S285 (Q10 decision)'),
               ('00000000-0000-4000-8000-0000b6700012'::uuid, '00000000-0000-4000-8000-0000b6700010'::uuid,
                'tech lead S279 (thresholds rule: seeded defaults)')) AS v (id, pid, actor)
  JOIN booking.pricing_policy p ON p.id = v.pid AND p.created_by = 'seed:bk-067'
ON CONFLICT DO NOTHING;

-- ── 6. supplier_bank.write (entry only) in the content + operations role (Q10) ──────────────────────────────────

INSERT INTO booking.staff_role_capability (role_code, capability, created_by)
SELECT r.code, 'supplier_bank.write', 'migration:bk-067'
  FROM booking.staff_role r
 WHERE r.code = 'custom_product_ops_accounting'
ON CONFLICT (role_code, capability) DO NOTHING;

-- supplier_bank.read decrypts a full account number: in the approve class (never a custom role), the code's
-- app.auth.custom_roles.APPROVE_NAMED and this CHECK in step (unit test test_aa1155_role_editor). No row holds it
-- (the code before bk-067 did not know the capability), so the CHECK validates at once.
ALTER TABLE booking.staff_role_capability
    DROP CONSTRAINT IF EXISTS staff_role_capability_not_approve_chk,
    ADD CONSTRAINT staff_role_capability_not_approve_chk CHECK (
        capability !~ '\.approve(_[a-z0-9_]+)?$'
        AND capability NOT IN ('supplier.activate', 'contract.publish', 'stop_sale.approve', 'payout.write',
                               'payment.verify', 'billing_config.write', 'staff.admin', 'supplier_bank.read'));

-- ── 7. The choices of the supplier profile, as data an administrator edits ────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.supplier_profile_option (
    id         uuid        NOT NULL DEFAULT gen_random_uuid(),
    kind       text        NOT NULL,
    code       text        NOT NULL,
    label_en   text        NOT NULL,
    label_vi   text        NOT NULL,
    position   smallint    NOT NULL DEFAULT 100,
    active     boolean     NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    created_by text        NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    updated_by text        NOT NULL,
    CONSTRAINT supplier_profile_option_pkey PRIMARY KEY (id),
    CONSTRAINT supplier_profile_option_code_uq UNIQUE (kind, code),
    CONSTRAINT supplier_profile_option_kind_chk CHECK (kind IN ('contact_role', 'terms_basis', 'terms_method')),
    CONSTRAINT supplier_profile_option_text_chk CHECK (
        code ~ '^[a-z][a-z0-9_]{1,39}$'
        AND char_length(btrim(label_en)) BETWEEN 1 AND 80 AND label_en !~ '[[:cntrl:]]'
        AND char_length(btrim(label_vi)) BETWEEN 1 AND 80 AND label_vi !~ '[[:cntrl:]]'
        AND position BETWEEN 1 AND 999
        AND char_length(created_by) BETWEEN 1 AND 128 AND char_length(updated_by) BETWEEN 1 AND 128),
    CONSTRAINT supplier_profile_option_time_chk CHECK (updated_at >= created_at)
);

COMMENT ON TABLE booking.supplier_profile_option IS
    'bk-067 (AA-1158 part 2): the choices of the supplier profile: contact roles (suppliers.role_contacts[].role), '
    'payment terms bases and methods (suppliers.payment_terms.basis / method). Edited by an administrator (labels, '
    'order, active) and audited in booking.audit_logs; a code never changes and a row is never deleted (a supplier may '
    'still name it): retiring one sets active = false. The API accepts an active code, or the one the supplier already '
    'holds. The basis deposit_balance carries the deposit percentage rule in the code.';
COMMENT ON COLUMN booking.supplier_profile_option.code IS
    'The stored value (in the supplier''s JSON); never changes once created.';

REVOKE ALL ON booking.supplier_profile_option FROM booking;
GRANT SELECT, INSERT ON booking.supplier_profile_option TO booking;
GRANT UPDATE (label_en, label_vi, position, active, updated_at, updated_by)
    ON booking.supplier_profile_option TO booking;

INSERT INTO booking.supplier_profile_option (id, kind, code, label_en, label_vi, position, created_by, updated_by)
VALUES
    ('00000000-0000-4000-8000-0000b6700101', 'contact_role', 'reservations', 'Reservations', 'Đặt chỗ', 10,
     'seed:bk-067', 'seed:bk-067'),
    ('00000000-0000-4000-8000-0000b6700102', 'contact_role', 'accounts', 'Accounts', 'Kế toán', 20,
     'seed:bk-067', 'seed:bk-067'),
    ('00000000-0000-4000-8000-0000b6700103', 'contact_role', 'sales', 'Sales', 'Kinh doanh', 30,
     'seed:bk-067', 'seed:bk-067'),
    ('00000000-0000-4000-8000-0000b6700104', 'contact_role', 'operations', 'Operations', 'Điều hành', 40,
     'seed:bk-067', 'seed:bk-067'),
    ('00000000-0000-4000-8000-0000b6700105', 'contact_role', 'emergency', 'Emergency', 'Khẩn cấp', 50,
     'seed:bk-067', 'seed:bk-067'),
    ('00000000-0000-4000-8000-0000b6700106', 'contact_role', 'management', 'Management', 'Ban quản lý', 60,
     'seed:bk-067', 'seed:bk-067'),
    ('00000000-0000-4000-8000-0000b6700111', 'terms_basis', 'prepayment', 'Prepayment before the service',
     'Trả trước khi sử dụng dịch vụ', 10, 'seed:bk-067', 'seed:bk-067'),
    ('00000000-0000-4000-8000-0000b6700112', 'terms_basis', 'deposit_balance', 'Deposit, then the balance',
     'Đặt cọc, sau đó trả phần còn lại', 20, 'seed:bk-067', 'seed:bk-067'),
    ('00000000-0000-4000-8000-0000b6700113', 'terms_basis', 'on_arrival', 'On arrival', 'Khi khách đến', 30,
     'seed:bk-067', 'seed:bk-067'),
    ('00000000-0000-4000-8000-0000b6700114', 'terms_basis', 'after_service', 'After the service',
     'Sau khi sử dụng dịch vụ', 40, 'seed:bk-067', 'seed:bk-067'),
    ('00000000-0000-4000-8000-0000b6700115', 'terms_basis', 'monthly_statement', 'Monthly statement',
     'Theo bảng kê hằng tháng', 50, 'seed:bk-067', 'seed:bk-067'),
    ('00000000-0000-4000-8000-0000b6700121', 'terms_method', 'bank_transfer', 'Bank transfer', 'Chuyển khoản', 10,
     'seed:bk-067', 'seed:bk-067'),
    ('00000000-0000-4000-8000-0000b6700122', 'terms_method', 'card', 'Card', 'Thẻ', 20, 'seed:bk-067', 'seed:bk-067'),
    ('00000000-0000-4000-8000-0000b6700123', 'terms_method', 'cash', 'Cash', 'Tiền mặt', 30, 'seed:bk-067',
     'seed:bk-067'),
    ('00000000-0000-4000-8000-0000b6700124', 'terms_method', 'other', 'Other', 'Khác', 40, 'seed:bk-067', 'seed:bk-067')
ON CONFLICT DO NOTHING;

-- ── Guards: what this file promises (catalog and seeds only; never the CIS view) ─────────────────────────────────

DO $$
DECLARE
    missing text;
    n integer;
BEGIN
    SELECT string_agg(want, ', ' ORDER BY want) INTO missing
      FROM unnest(ARRAY[
          'suppliers.suppliers_profile_chk', 'supplier_bank_account.supplier_bank_account_status_chk',
          'supplier_bank_account.supplier_bank_account_maker_checker_chk',
          'supplier_bank_account.supplier_bank_account_owner_self_chk',
          'supplier_bank_account.supplier_bank_account_text_chk', 'supplier_bank_account.supplier_bank_account_time_chk',
          'supplier_profile_option.supplier_profile_option_kind_chk',
          'supplier_profile_option.supplier_profile_option_text_chk'
      ]) AS want
     WHERE NOT EXISTS (
         SELECT 1 FROM pg_constraint c
          WHERE c.conrelid = to_regclass('booking.' || split_part(want, '.', 1))
            AND c.conname = split_part(want, '.', 2) AND c.contype = 'c' AND c.convalidated);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'bk-067: missing CHECKs: %', missing;
    END IF;
    SELECT string_agg(want, ', ' ORDER BY want) INTO missing
      FROM unnest(ARRAY[
          'billing_entity.billing_entity_guard',
          'supplier_bank_account.supplier_bank_account_guard',
          'supplier_bank_account.supplier_bank_account_owner_self_approval',
          'supplier_payouts.supplier_payouts_bank_lock'
      ]) AS want
     WHERE NOT EXISTS (
         SELECT 1 FROM pg_trigger t
          WHERE t.tgrelid = to_regclass('booking.' || split_part(want, '.', 1))
            AND t.tgname = split_part(want, '.', 2) AND NOT t.tgisinternal AND t.tgenabled = 'O');
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'bk-067: missing or disabled triggers: %', missing;
    END IF;
    IF pg_has_role('booking', 'bk_owner', 'USAGE') THEN
        RAISE EXCEPTION 'bk-067: role booking is a member of bk_owner; the guards would not bind it';
    END IF;
    IF has_table_privilege('booking', 'booking.supplier_bank_account', 'DELETE')
       OR has_column_privilege('booking', 'booking.supplier_bank_account', 'ciphertext', 'UPDATE')
       OR has_column_privilege('booking', 'booking.supplier_bank_account', 'wrapped_key', 'UPDATE')
       OR has_column_privilege('booking', 'booking.supplier_bank_account', 'entered_by', 'UPDATE')
       OR NOT has_column_privilege('booking', 'booking.supplier_bank_account', 'approved_by', 'UPDATE')
       OR NOT has_table_privilege('booking', 'booking.supplier_bank_account', 'INSERT') THEN
        RAISE EXCEPTION 'bk-067: role booking grants on supplier_bank_account differ from this file';
    END IF;
    IF has_table_privilege('booking', 'booking.supplier_profile_option', 'DELETE')
       OR has_column_privilege('booking', 'booking.supplier_profile_option', 'code', 'UPDATE')
       OR has_column_privilege('booking', 'booking.supplier_profile_option', 'kind', 'UPDATE')
       OR NOT has_column_privilege('booking', 'booking.supplier_profile_option', 'active', 'UPDATE') THEN
        RAISE EXCEPTION 'bk-067: role booking grants on supplier_profile_option differ from this file';
    END IF;
    SELECT count(*) INTO n FROM booking.supplier_profile_option WHERE created_by = 'seed:bk-067';
    IF n <> 15 THEN
        RAISE EXCEPTION 'bk-067: % of the 15 seeded supplier profile options exist', n;
    END IF;
    SELECT count(*) INTO n
      FROM booking.pricing_policy p
      JOIN booking.pricing_policy_events a ON a.policy_id = p.id AND a.event = 'approved'
     WHERE p.created_by = 'seed:bk-067' AND p.version_no = 1;
    IF n <> 2 THEN
        RAISE EXCEPTION 'bk-067: % of the 2 new pricing policy parameters have an approved version 1', n
            USING HINT = 'A key already had a version 1 made by someone else; the seed must not overwrite it.';
    END IF;
    IF EXISTS (SELECT 1 FROM booking.staff_role WHERE code = 'custom_product_ops_accounting')
       AND NOT EXISTS (SELECT 1 FROM booking.staff_role_capability
                        WHERE role_code = 'custom_product_ops_accounting' AND capability = 'supplier_bank.write') THEN
        RAISE EXCEPTION 'bk-067: the content + operations role lacks supplier_bank.write';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conrelid = 'booking.staff_role_capability'::regclass
                      AND conname = 'staff_role_capability_not_approve_chk' AND convalidated
                      AND pg_get_constraintdef(oid) LIKE '%supplier_bank.read%') THEN
        RAISE EXCEPTION 'bk-067: staff_role_capability_not_approve_chk does not hold supplier_bank.read';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_constraint
                WHERE conrelid = 'booking.supplier_bank_account'::regclass
                  AND conname = 'supplier_bank_account_supplier_fkey' AND confdeltype <> 'r') THEN
        RAISE EXCEPTION 'bk-067: supplier_bank_account_supplier_fkey must be ON DELETE RESTRICT (accounting evidence)';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-067', now(), 'AA-1158 part 2: supplier profile fields and their admin-edited choices (booking.supplier_profile_option), booking.supplier_bank_account (KMS envelope ciphertext, approved by a second person with a call-back, owner self-approval flagged), the payout lock after a bank change (supplier_bank_payout_lock_hours), the contact change window of a call-back (supplier_bank_contact_change_days), supplier_bank.write in the content + operations role, supplier_bank.read in the approve class, the DB backstop on the billing entity bank text / default flag')
ON CONFLICT (version) DO NOTHING;

COMMIT;
