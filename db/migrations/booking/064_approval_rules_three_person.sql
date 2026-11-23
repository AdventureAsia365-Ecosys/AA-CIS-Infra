-- Migration bk-064: AA-1158 part 1 (S288; tech lead decisions S285 Q4, Q5, Q9) — approval rules for a three-person
-- team: suppliers start pending and a second person activates them, the contract writer list, the bill approver never
-- records the payout (the business owner may, flagged), business-owner self-approval as a DB-checked flag, pending
-- changes for the bank details AA prints on agency invoices, and the two policy switches.
--
-- Owner: AA-Booking (key bk-NNN). AA-CIS-Infra Migration Sync copies it byte for byte to
-- db/migrations/booking/064_approval_rules_three_person.sql and Migration Apply applies it on Dev as bk_owner once every
-- job table is idle (root ADR 0017a). Never run it from a laptop.
--
-- Why: with three people, strict maker != checker blocks the business owner's own work, and some approval gaps remain:
-- a supplier made by a holder of supplier.activate is active at once (R5); the contract maker check reads only
-- coalesce(updated_by, created_by), so an earlier writer may publish (R4); the bill approver may record the payout
-- (R3); one person with billing_config.write changes AA's payment_instructions and is_default. The business-owner
-- marker comes from the CIS contract view shared.v_staff_booking_grant (CIS 462, AA-1155, root ADR 0006a A14).
--
-- What:
--   0. booking.owner_self_approval_guard(approver_column, flag_column, final|mutable[, recheck_column ...]): a generic
--      BEFORE INSERT OR UPDATE trigger function. When the flag is set (on INSERT, or when the approver column, the flag
--      or one of the optional recheck columns changes on UPDATE; suppliers pass activated_at, so a flagged
--      re-activation by the same former owner is checked again) the approver must be an active staff_users row whose
--      cognito_sub carries is_business_owner in shared.v_staff_booking_grant; else check_violation. "final": a set flag is never cleared. The DB refuses a
--      forged flag, not only the API. SECURITY INVOKER: it runs as role booking, which reads the view and staff_users.
--      If the view is unreadable, a self-approval fails and a normal approval is untouched.
--   1. suppliers: status pending, activated_by, activated_at, owner_self_approved, writers. writers (kept by trigger
--      suppliers_writers, the client value is ignored): INSERT = [created_by]; an UPDATE that changes the supplier's
--      data while it is not live (pending or inactive, before or after the statement: a rejected or deactivated
--      supplier's data is not approved either) appends updated_by (also when the same statement activates or
--      deactivates it); only an edit of a supplier that stays active is free. suppliers_status_chk (same name) adds
--      pending; suppliers_activation_chk; suppliers_maker_checker_chk (the activator is neither the creator nor a
--      writer of the not-live data, unless flagged); suppliers_owner_self_chk (NULL-safe: the flag = the activator
--      is the creator or a writer). The list only grows (a person who once wrote the not-live data never activates
--      it alone again). Existing rows keep writers '{}' (no backfill: the CHECKs name
--      created_by too, so no row is touched). Trigger
--      suppliers_activation_guard (for every role except members of bk_owner, i.e. the app): an INSERT has no
--      activation; the creator never changes; a supplier never goes back to pending; becoming
--      active records activated_by = updated_by (filled from updated_by when the statement names no activator, so the
--      running code's activate is checked too) and activated_at = now(); the activation columns change only with an
--      activation. Owner trigger in mutable mode (a later re-activation by someone else clears the flag), with
--      activated_at as recheck column (a flagged re-activation is checked against the marker again).
--      Existing rows: active ones keep activated_by NULL (legacy), inactive ones stay inactive.
--      MIG-4 compatibility (the running code must keep its integration tests green on this PR): the INSERT of an
--      active supplier (the running code does it for a holder of supplier.activate), an INSERT without a creator
--      (older tests as role booking) and the column default active stay; the code PR inserts pending with its
--      creator. The part 2 migration (S289) refuses any INSERT but pending with a creator and sets the default to
--      pending.
--   2. supplier_contracts: writers text[] (kept by trigger supplier_contracts_writers: INSERT = [created_by]; UPDATE
--      keeps the old list and appends updated_by while the contract is a draft) and owner_self_approved.
--      supplier_contracts_maker_checker_chk (same name): the publisher is not a writer, unless flagged;
--      supplier_contracts_owner_self_chk. Backfill: drafts only (the bk-008 lock refuses any UPDATE of a published or
--      expired contract; their writers stay '{}', which both CHECKs accept). The backfill runs before the trigger.
--   3. supplier_bills: owner_self_approved (+ column UPDATE grant). supplier_bills_maker_checker_chk (same name)
--      relaxed by the flag; supplier_bills_owner_self_chk. supplier_bills_guard(): the bk-045 body with the two
--      maker-checker RAISEs skipped when the bill is flagged.
--   4. supplier_payouts: same_approver_payer. supplier_payouts_guard(): the bk-030 body; the creator and the facts
--      editor of the bill still never pay it; the bill approver pays it only flagged (same_approver_payer, and the
--      owner trigger requires the business owner); the flag is never set otherwise and never changes.
--   5. price_list_versions: owner_self_approved (+ grant); price_list_versions_approved_chk (same name) relaxed;
--      owner_self_chk. Rejected / withdrawn stay strict.
--   6. season_ranges (kind season only, never a stop-sale and never an end) and holiday_events: owner_self_approved
--      (+ grant); *_status_chk (same names) relaxed for an approval; owner_self_chk. *_end_chk stay strict.
--   7. agency_payment and departure_price_adjustments: owner_self_approved (+ grant where column grants apply);
--      *_maker_checker_chk / *_approved_chk (same names) relaxed for an approval; owner_self_chk.
--   8. booking.billing_entity_change: one pending change of a billing entity's payment_instructions and / or making
--      it the default, applied on a decision by a second person (or a flagged owner self-approval). Guard: an INSERT
--      is pending and undecided; only pending -> approved / rejected / withdrawn, dated now(); decided rows are final.
--      Erasure (DM-6.7): one update may set reason and / or reject_reason to the fixed marker '[redacted]' with every
--      other column unchanged, on any row (it runs as bk_owner in a reviewed DB Migrate run-script, root
--      docs/legal/dsar-erasure-runbook.md; role booking has no UPDATE grant on reason).
--      The DB guard on billing_entity itself (payment_instructions / is_default change only in the transaction that
--      approved a matching change) would refuse the running code's direct edit, so it ships with the part 2 migration
--      (S289) together with the same guard for supplier bank accounts; until then the code PR is the control.
--   9. Two pricing policy parameters (Pricing > Policy, section security, approver group admin): owner_self_approval_
--      allowed and owner_payout_after_approval_allowed, version 1 = true (tech lead Q5 / Q4), seeded like bk-061.
--  10. audit_logs_owner_self_idx: the audit filter owner_self_approved = true.
--
-- Class: contract (root ADR 0017 d3: replaced CHECKs and guard functions, new triggers, a new table, a seed).
-- Migration-only PR first (MIG-4); the code PR raises readiness to bk-064. The running code never sets the new flags
-- and always names a creator. What changes for it: a supplier's creator can no longer activate it, a contract writer
-- other than the last one can no longer publish it, the bill approver can no longer record its payout (each answers
-- 403 maker_checker or 500 until the code PR), the old existing-test expectations are updated in this PR.
-- DM-6.1: no new personal data (staff keys, flags; billing_entity_change.payment_instructions is AA's own bank text,
-- conf:commercial; reason / reject_reason staff free text, pii:free_text by rule).
-- DM-7.1: billing_entity_change has its row in the root data standards (root PR merged before the Infra copy).
-- Locks: ACCESS EXCLUSIVE, briefly, on the ten tables for ADD COLUMN / CHECK swaps (each tens to a few hundred
-- rows); audit_logs a SHARE lock for the index (about 500 rows); lock_timeout 5s.
-- Never reads shared.v_staff_booking_grant itself (bk_owner has no SELECT on it): every backfill keeps the flags
-- false, and the post-checks read the catalog only.
-- Re-runnable (the Integration Tests replay every file): ADD COLUMN IF NOT EXISTS, DROP CONSTRAINT IF EXISTS + ADD,
-- CREATE OR REPLACE FUNCTION / TRIGGER, CREATE TABLE / INDEX IF NOT EXISTS, ON CONFLICT DO NOTHING, guarded backfills.
-- Number: owner main max + 1 (bk-063 on main). If it moves, renumber: file name, this header, the registration, the
-- seed ids (…b64000…) and the tests that name it (git grep '064_' and 'bk-064').
-- Undo (a later bk- file, after the code is reverted): DROP the new triggers and owner_self_approval_guard; put back
-- the bk-008 / bk-030 / bk-045 / bk-054 / bk-055 / bk-041 / bk-048 CHECK texts and the bk-030 / bk-045 guard bodies
-- (they RAISE while a flagged, pending or same_approver_payer row exists); DROP the new columns and
-- booking.billing_entity_change (destructive: DRY RUN), DELETE the seed:bk-064 policy rows.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF to_regclass('booking.staff_role') IS NULL OR to_regclass('booking.price_list_versions') IS NULL
       OR to_regclass('booking.season_ranges') IS NULL OR to_regclass('booking.departure_price_adjustments') IS NULL
       OR to_regclass('booking.billing_entity') IS NULL THEN
        RAISE EXCEPTION 'bk-064: needs bk-041, bk-048, bk-054, bk-055 and bk-062 first';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.schema_versions
                WHERE version = 'bk-064' AND description NOT LIKE 'AA-1158 %') THEN
        RAISE EXCEPTION 'bk-064: the key bk-064 is already held by another migration (not AA-1158): renumber one';
    END IF;
END $$;

-- ── 0. Business-owner self-approval: one generic guard ──────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION booking.owner_self_approval_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_col     text := TG_ARGV[0];
    v_flag    text := TG_ARGV[1];
    v_mode    text := TG_ARGV[2];
    v_new     jsonb := to_jsonb(NEW);
    v_old     jsonb;
    v_set     boolean := coalesce((to_jsonb(NEW) ->> TG_ARGV[1])::boolean, false);
    v_was     boolean := false;
    v_same    boolean;
    i         integer;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        v_old := to_jsonb(OLD);
        v_was := coalesce((v_old ->> v_flag)::boolean, false);
        IF v_mode = 'final' AND v_was AND NOT v_set THEN
            RAISE EXCEPTION '%: a business-owner self-approval stays recorded (% is final)', TG_TABLE_NAME, v_flag
                USING ERRCODE = 'check_violation';
        END IF;
        -- Checked when it was set: an unchanged approval keeps its flag even after the marker moves (critique 3). The
        -- approval is the approver column plus the optional recheck columns (TG_ARGV[3..]): a supplier's flagged
        -- re-activation by the same person moves activated_at, so it is checked again. Not status: a deactivation by
        -- someone else keeps the activation columns and must stay possible after the marker moves.
        v_same := (v_new ->> v_col) IS NOT DISTINCT FROM (v_old ->> v_col);
        FOR i IN 3 .. TG_NARGS - 1 LOOP
            v_same := v_same AND (v_new -> TG_ARGV[i]) IS NOT DISTINCT FROM (v_old -> TG_ARGV[i]);
        END LOOP;
        IF NOT v_set OR (v_was AND v_same) THEN
            RETURN NEW;
        END IF;
    ELSIF NOT v_set THEN
        RETURN NEW;
    END IF;
    IF (v_new ->> v_col) IS NULL OR NOT EXISTS (
        SELECT 1
          FROM booking.staff_users s
          JOIN shared.v_staff_booking_grant g ON g.cognito_sub = s.cognito_sub
         WHERE s.cis_user_id = (v_new ->> v_col) AND s.active AND g.is_business_owner IS TRUE)
    THEN
        RAISE EXCEPTION '%: % is set but % is not the business owner', TG_TABLE_NAME, v_flag, v_col
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.owner_self_approval_guard() IS
    'bk-064 (AA-1158): TG_ARGV approver column, flag column, final|mutable, then optional recheck columns. A set flag '
    '(on INSERT, or when the approver, the flag or a recheck column changes) needs the approver to be an active staff '
    'user whose cognito_sub carries is_business_owner in shared.v_staff_booking_grant (CIS 462); final: a set flag is never cleared. Security invoker (role booking reads '
    'the view); an unreadable view refuses the self-approval only.';

GRANT EXECUTE ON FUNCTION booking.owner_self_approval_guard() TO booking;

-- ── 1. Suppliers: pending, then activated by a second person ────────────────────────────────────────────────────

ALTER TABLE booking.suppliers
    ADD COLUMN IF NOT EXISTS activated_by text,
    ADD COLUMN IF NOT EXISTS activated_at timestamptz,
    ADD COLUMN IF NOT EXISTS owner_self_approved boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS writers text[] NOT NULL DEFAULT '{}';

ALTER TABLE booking.suppliers DROP CONSTRAINT IF EXISTS suppliers_status_chk;
ALTER TABLE booking.suppliers ADD CONSTRAINT suppliers_status_chk CHECK (status IN ('pending', 'active', 'inactive'));
ALTER TABLE booking.suppliers DROP CONSTRAINT IF EXISTS suppliers_activation_chk;
ALTER TABLE booking.suppliers ADD CONSTRAINT suppliers_activation_chk CHECK (
    (activated_by IS NULL) = (activated_at IS NULL)
    AND (status <> 'pending' OR activated_by IS NULL)
    AND (activated_by IS NULL OR char_length(activated_by) BETWEEN 1 AND 128));
ALTER TABLE booking.suppliers DROP CONSTRAINT IF EXISTS suppliers_maker_checker_chk;
ALTER TABLE booking.suppliers ADD CONSTRAINT suppliers_maker_checker_chk CHECK (
    activated_by IS NULL OR owner_self_approved
    OR (activated_by IS DISTINCT FROM created_by AND NOT (activated_by = ANY (writers))));
ALTER TABLE booking.suppliers DROP CONSTRAINT IF EXISTS suppliers_owner_self_chk;
ALTER TABLE booking.suppliers ADD CONSTRAINT suppliers_owner_self_chk CHECK (
    owner_self_approved = (activated_by IS NOT NULL
                           AND (activated_by IS NOT DISTINCT FROM created_by OR activated_by = ANY (writers))));

COMMENT ON COLUMN booking.suppliers.activated_by IS
    'bk-064 (AA-1158 R5): the staff key of the person who last activated the supplier (never its creator nor one of '
    'its writers unless owner_self_approved). NULL on suppliers active before bk-064 (legacy) and on pending ones.';
COMMENT ON COLUMN booking.suppliers.owner_self_approved IS
    'bk-064 (AA-1158 Q5): the business owner activated a supplier she created or edited while not live (checked '
    'against the CIS marker by booking.owner_self_approval_guard at each activation). Cleared by a later activation by '
    'someone else; the audit keeps the history.';
COMMENT ON COLUMN booking.suppliers.writers IS
    'bk-064 (AA-1158 R5): every staff key that decided the supplier''s data while it was not live (its creator, then '
    'each updated_by of an UPDATE that changed the data of a pending or inactive supplier, or in the statement that '
    'activates or deactivates it; kept by trigger suppliers_writers, the client value is ignored). The activator is never one of them unless owner_self_approved. ''{}'' on suppliers made before bk-064.';

CREATE OR REPLACE FUNCTION booking.suppliers_activation_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    -- The schema owner and the master (migrations, DB Migrate run-script, test fixtures) own the table and could
    -- drop this trigger; the rule binds the application role (booking is never a member of bk_owner, post-check).
    IF pg_has_role(current_user, 'bk_owner', 'USAGE') THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'INSERT' THEN
        -- MIG-4 compatibility: the running code still inserts active for a holder of supplier.activate (legacy shape,
        -- no activator), and older tests insert as role booking without a creator; the code PR inserts pending with
        -- its creator, and the part 2 migration refuses anything but pending with a creator.
        IF NEW.activated_by IS NOT NULL OR NEW.activated_at IS NOT NULL OR NEW.owner_self_approved THEN
            RAISE EXCEPTION 'a new supplier has no activation yet; a second person activates it'
                USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.created_by IS DISTINCT FROM OLD.created_by THEN
        RAISE EXCEPTION 'supplier %: its creator never changes', OLD.code USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.status = 'pending' AND OLD.status <> 'pending' THEN
        RAISE EXCEPTION 'supplier %: a supplier never goes back to pending', OLD.code USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.status = 'active' AND OLD.status <> 'active' THEN
        -- The activator is the author of this update. A statement that does not name it (the running code before the
        -- AA-1158 code PR) gets it from updated_by, unflagged; suppliers_maker_checker_chk then refuses its creator.
        IF NEW.activated_at IS NOT DISTINCT FROM OLD.activated_at THEN
            NEW.activated_by := NEW.updated_by;
            NEW.activated_at := now();
            NEW.owner_self_approved := false;
        END IF;
        IF NEW.activated_by IS NULL OR NEW.activated_by IS DISTINCT FROM NEW.updated_by
           OR NEW.activated_at IS DISTINCT FROM now() THEN
            RAISE EXCEPTION 'supplier %: an activation names its author (activated_by = updated_by) and is dated now',
                OLD.code USING ERRCODE = 'check_violation';
        END IF;
    ELSIF (NEW.activated_by, NEW.activated_at, NEW.owner_self_approved)
          IS DISTINCT FROM (OLD.activated_by, OLD.activated_at, OLD.owner_self_approved) THEN
        RAISE EXCEPTION 'supplier %: the activation columns change only with an activation', OLD.code
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.suppliers_activation_guard() IS
    'bk-064 (AA-1158 R5): for the application role, a new supplier has no activation; the creator never changes; '
    'never back to pending; becoming active records activated_by = updated_by (filled from it when the statement '
    'names no activator) and activated_at = now(); the activation columns change only with an '
    'activation. Members of bk_owner (migrations, run-script, fixtures) are exempt.';

GRANT EXECUTE ON FUNCTION booking.suppliers_activation_guard() TO booking;

CREATE OR REPLACE TRIGGER suppliers_activation_guard
    BEFORE INSERT OR UPDATE ON booking.suppliers
    FOR EACH ROW EXECUTE FUNCTION booking.suppliers_activation_guard();

CREATE OR REPLACE TRIGGER suppliers_owner_self_approval
    BEFORE INSERT OR UPDATE ON booking.suppliers
    FOR EACH ROW
    EXECUTE FUNCTION booking.owner_self_approval_guard('activated_by', 'owner_self_approved', 'mutable', 'activated_at');

CREATE OR REPLACE FUNCTION booking.suppliers_writers() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    -- Not the supplier's data: the status move, its activation and the bookkeeping columns.
    v_meta CONSTANT text[] := ARRAY['status', 'activated_by', 'activated_at', 'owner_self_approved', 'writers',
                                    'updated_by', 'updated_at'];
BEGIN
    IF TG_OP = 'INSERT' THEN
        NEW.writers := array_remove(ARRAY[NEW.created_by], NULL);
        RETURN NEW;
    END IF;
    NEW.writers := OLD.writers;
    -- Whoever changes the data of a supplier that is not live decided what goes live, so never activates it (R5, like
    -- the contract writers of R4 and the bill facts editor of bk-045). Pending and inactive alike: a rejected supplier
    -- (pending -> inactive) or a legacy one never activated holds data nobody approved, and an inactive one edited
    -- after its approval holds new data. An edit in the statement that activates or deactivates it counts too; only
    -- an edit of a supplier that stays active is free (it is live already, R5 governs going live).
    IF (OLD.status <> 'active' OR NEW.status <> 'active')
       AND NEW.updated_by IS NOT NULL AND NOT (NEW.updated_by = ANY (OLD.writers))
       AND (to_jsonb(NEW) - v_meta) IS DISTINCT FROM (to_jsonb(OLD) - v_meta) THEN
        NEW.writers := OLD.writers || NEW.updated_by;
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.suppliers_writers() IS
    'bk-064 (AA-1158 R5): writers = [created_by] on INSERT; on UPDATE the old list, plus updated_by when the update '
    'changes the data of a supplier that is not active before or after it (status, activation and bookkeeping '
    'columns are not data).';

GRANT EXECUTE ON FUNCTION booking.suppliers_writers() TO booking;

-- Fires after suppliers_activation_guard and suppliers_set_updated_at (name order); the CHECKs read its result.
CREATE OR REPLACE TRIGGER suppliers_writers
    BEFORE INSERT OR UPDATE ON booking.suppliers
    FOR EACH ROW EXECUTE FUNCTION booking.suppliers_writers();

-- ── 2. Contracts: the writer list ───────────────────────────────────────────────────────────────────────────────

ALTER TABLE booking.supplier_contracts
    ADD COLUMN IF NOT EXISTS writers text[] NOT NULL DEFAULT '{}',
    ADD COLUMN IF NOT EXISTS owner_self_approved boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN booking.supplier_contracts.writers IS
    'bk-064 (AA-1158 R4): every staff key that wrote the draft (its creator, then each updated_by while a draft; kept '
    'by trigger supplier_contracts_writers, the client value is ignored). The publisher is never one of them unless '
    'owner_self_approved. Contracts published before bk-064 keep ''{}'' (the bk-008 lock fixes them).';
COMMENT ON COLUMN booking.supplier_contracts.owner_self_approved IS
    'bk-064 (AA-1158 Q5): the business owner published a draft she wrote (checked against the CIS marker). Final.';

-- Drafts only, before the trigger exists (it would overwrite NEW.writers with OLD.writers). Bumps updated_at.
UPDATE booking.supplier_contracts
   SET writers = ARRAY(SELECT DISTINCT w FROM unnest(ARRAY[created_by, updated_by]) AS w WHERE w IS NOT NULL ORDER BY w)
 WHERE status = 'draft' AND writers = '{}';

CREATE OR REPLACE FUNCTION booking.supplier_contracts_writers() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        NEW.writers := ARRAY[NEW.created_by];
        RETURN NEW;
    END IF;
    NEW.writers := OLD.writers;
    -- Only drafts take a new writer (the bk-008 lock fixes published and expired contracts anyway).
    IF OLD.status = 'draft' AND NEW.updated_by IS NOT NULL AND NOT (NEW.updated_by = ANY (OLD.writers)) THEN
        NEW.writers := OLD.writers || NEW.updated_by;
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.supplier_contracts_writers() IS
    'bk-064 (AA-1158 R4): writers = [created_by] on INSERT; on UPDATE the old list, plus updated_by while a draft.';

GRANT EXECUTE ON FUNCTION booking.supplier_contracts_writers() TO booking;

-- Named after supplier_contracts_lock so the lock refusals still come first (triggers fire in name order).
CREATE OR REPLACE TRIGGER supplier_contracts_writers
    BEFORE INSERT OR UPDATE ON booking.supplier_contracts
    FOR EACH ROW EXECUTE FUNCTION booking.supplier_contracts_writers();

ALTER TABLE booking.supplier_contracts DROP CONSTRAINT IF EXISTS supplier_contracts_maker_checker_chk;
ALTER TABLE booking.supplier_contracts ADD CONSTRAINT supplier_contracts_maker_checker_chk CHECK (
    published_by IS NULL OR NOT (published_by = ANY (writers)) OR owner_self_approved);
ALTER TABLE booking.supplier_contracts DROP CONSTRAINT IF EXISTS supplier_contracts_owner_self_chk;
ALTER TABLE booking.supplier_contracts ADD CONSTRAINT supplier_contracts_owner_self_chk CHECK (
    owner_self_approved = (published_by IS NOT NULL AND published_by = ANY (writers)));

CREATE OR REPLACE TRIGGER supplier_contracts_owner_self_approval
    BEFORE INSERT OR UPDATE ON booking.supplier_contracts
    FOR EACH ROW EXECUTE FUNCTION booking.owner_self_approval_guard('published_by', 'owner_self_approved', 'final');

-- ── 3. Supplier bills ───────────────────────────────────────────────────────────────────────────────────────────

ALTER TABLE booking.supplier_bills ADD COLUMN IF NOT EXISTS owner_self_approved boolean NOT NULL DEFAULT false;
GRANT UPDATE (owner_self_approved) ON booking.supplier_bills TO booking;
COMMENT ON COLUMN booking.supplier_bills.owner_self_approved IS
    'bk-064 (AA-1158 Q5): the business owner approved a bill she entered or last edited (checked against the CIS '
    'marker). Final.';

ALTER TABLE booking.supplier_bills DROP CONSTRAINT IF EXISTS supplier_bills_maker_checker_chk;
ALTER TABLE booking.supplier_bills ADD CONSTRAINT supplier_bills_maker_checker_chk CHECK (
    approved_by IS NULL OR (approved_by <> created_by AND approved_by <> facts_edited_by) OR owner_self_approved);
ALTER TABLE booking.supplier_bills DROP CONSTRAINT IF EXISTS supplier_bills_owner_self_chk;
ALTER TABLE booking.supplier_bills ADD CONSTRAINT supplier_bills_owner_self_chk CHECK (
    owner_self_approved = (approved_by IS NOT NULL AND (approved_by = created_by OR approved_by = facts_edited_by)));

-- The bk-045 body; only the two maker-checker RAISEs of the approval skip a flagged bill.
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
           OR NEW.cancelled_at IS NOT NULL OR NEW.fx_rate_per_usd IS NOT NULL THEN
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
       AND (NEW.supplier_id, NEW.trip_case_id, NEW.departure_id, NEW.bill_number, NEW.currency, NEW.amount,
            NEW.issue_date, NEW.due_date, NEW.document_file_id)
           IS DISTINCT FROM
           (OLD.supplier_id, OLD.trip_case_id, OLD.departure_id, OLD.bill_number, OLD.currency, OLD.amount,
            OLD.issue_date, OLD.due_date, OLD.document_file_id) THEN
        RAISE EXCEPTION 'supplier bill %: its facts and document change only while it is received', OLD.code
            USING ERRCODE = 'check_violation';
    END IF;
    -- The FX snapshot is taken with the approval and fixed from then.
    IF (NEW.fx_rate_per_usd, NEW.fx_as_of) IS DISTINCT FROM (OLD.fx_rate_per_usd, OLD.fx_as_of)
       AND NOT (OLD.status = 'received' AND NEW.status = 'approved' AND OLD.fx_rate_per_usd IS NULL) THEN
        RAISE EXCEPTION 'supplier bill %: its FX snapshot is set once, with the approval', OLD.code
            USING ERRCODE = 'check_violation';
    END IF;
    -- Maker-checker input: who last set the money facts. A fact change records its author (updated_by); otherwise
    -- the app may only mark the editor of the lines (itself, while received) before it replaces them.
    IF (NEW.supplier_id, NEW.trip_case_id, NEW.departure_id, NEW.bill_number, NEW.currency, NEW.amount, NEW.issue_date,
        NEW.due_date)
       IS DISTINCT FROM
       (OLD.supplier_id, OLD.trip_case_id, OLD.departure_id, OLD.bill_number, OLD.currency, OLD.amount, OLD.issue_date,
        OLD.due_date) THEN
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
    -- The lines were checked against the supplier, the case and the departure when they were added: those stay while
    -- lines exist.
    IF (NEW.supplier_id, NEW.trip_case_id, NEW.departure_id) IS DISTINCT FROM (OLD.supplier_id, OLD.trip_case_id, OLD.departure_id)
       AND EXISTS (SELECT 1 FROM booking.supplier_bill_items WHERE bill_id = OLD.id) THEN
        RAISE EXCEPTION 'supplier bill %: remove its lines before changing the supplier, the trip case or the departure',
            OLD.code USING ERRCODE = 'check_violation';
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
    -- Approve: another person (CHECK too) unless a flagged business-owner self-approval (bk-064, checked by
    -- booking.owner_self_approval_guard), at least one line, the lines add up to the amount.
    IF OLD.status = 'received' AND NEW.status = 'approved' THEN
        IF NEW.approved_by IS NOT DISTINCT FROM NEW.created_by AND NOT NEW.owner_self_approved THEN
            RAISE EXCEPTION 'supplier bill %: maker-checker, the person who entered it cannot approve it', OLD.code
                USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.approved_by IS NOT DISTINCT FROM NEW.facts_edited_by AND NOT NEW.owner_self_approved THEN
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
    'bk-030 (AA-682 S4) + bk-045 (AA-1074) + bk-064 (AA-1158): a bill starts received with no document and no FX snapshot; code / creator / key never change; cancelled is final; facts (departure included) and document change only while received (supplier, case and departure stay while lines exist); the FX snapshot is set once with the approval; the document is an active supplier_bill file of this bill; facts_edited_by follows the author of a fact change; approve needs another person than created_by and facts_edited_by (unless a flagged business-owner self-approval), >= 1 line and lines = amount; approved / paid equal the live payouts; cancel needs no live payout.';

GRANT EXECUTE ON FUNCTION booking.supplier_bills_guard() TO booking;

CREATE OR REPLACE TRIGGER supplier_bills_owner_self_approval
    BEFORE INSERT OR UPDATE ON booking.supplier_bills
    FOR EACH ROW EXECUTE FUNCTION booking.owner_self_approval_guard('approved_by', 'owner_self_approved', 'final');

-- ── 4. Supplier payouts: the bill approver pays only flagged ────────────────────────────────────────────────────

ALTER TABLE booking.supplier_payouts ADD COLUMN IF NOT EXISTS same_approver_payer boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN booking.supplier_payouts.same_approver_payer IS
    'bk-064 (AA-1158 Q4): recorded by the person who approved the bill, allowed only for the business owner (checked '
    'against the CIS marker by booking.owner_self_approval_guard). Never changes.';

-- The bk-030 body with the approver rule. The insert checks are one list so part 2 adds the bank-change payout lock
-- (a pricing policy parameter, never a constant) in this place.
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
        IF NEW.recorded_by IS NOT DISTINCT FROM v_bill.approved_by AND NOT NEW.same_approver_payer THEN
            RAISE EXCEPTION 'bill %: the person who approved it does not record its payout (the business owner may, flagged)',
                v_bill.code USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.same_approver_payer AND NEW.recorded_by IS DISTINCT FROM v_bill.approved_by THEN
            RAISE EXCEPTION 'bill %: same_approver_payer marks a payout recorded by the bill approver only', v_bill.code
                USING ERRCODE = 'check_violation';
        END IF;
        IF booking.supplier_bill_paid(NEW.bill_id) + NEW.amount > v_bill.amount THEN
            RAISE EXCEPTION 'bill %: the payouts would exceed the bill amount % (already paid %)', v_bill.code,
                v_bill.amount, booking.supplier_bill_paid(NEW.bill_id) USING ERRCODE = 'check_violation';
        END IF;
    ELSE
        IF (NEW.bill_id, NEW.code, NEW.amount, NEW.currency, NEW.method, NEW.paid_on, NEW.reference, NEW.note,
            NEW.idempotency_key, NEW.request_sha256, NEW.recorded_by, NEW.recorded_at, NEW.created_at,
            NEW.same_approver_payer)
           IS DISTINCT FROM
           (OLD.bill_id, OLD.code, OLD.amount, OLD.currency, OLD.method, OLD.paid_on, OLD.reference, OLD.note,
            OLD.idempotency_key, OLD.request_sha256, OLD.recorded_by, OLD.recorded_at, OLD.created_at,
            OLD.same_approver_payer) THEN
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
    'bk-030 (AA-682 S4) + bk-064 (AA-1158 R3 / Q4): lock the bill first; a payout goes on an approved bill, in its currency, by someone other than the bill''s creator and its facts_edited_by; by the bill''s approver only with same_approver_payer (the business owner, checked by booking.owner_self_approval_guard); the live payouts never exceed the amount; its money facts and the flag never change; void is final and needs a live bill; the evidence of a live payout is replaced, never removed, and is an active payout_evidence file of this payout.';

GRANT EXECUTE ON FUNCTION booking.supplier_payouts_guard() TO booking;

CREATE OR REPLACE TRIGGER supplier_payouts_owner_self_approval
    BEFORE INSERT OR UPDATE ON booking.supplier_payouts
    FOR EACH ROW EXECUTE FUNCTION booking.owner_self_approval_guard('recorded_by', 'same_approver_payer', 'final');

-- ── 5. Price list versions ──────────────────────────────────────────────────────────────────────────────────────

ALTER TABLE booking.price_list_versions ADD COLUMN IF NOT EXISTS owner_self_approved boolean NOT NULL DEFAULT false;
GRANT UPDATE (owner_self_approved) ON booking.price_list_versions TO booking;
COMMENT ON COLUMN booking.price_list_versions.owner_self_approved IS
    'bk-064 (AA-1158 Q5): the business owner approved a version she made (checked against the CIS marker). Final.';

ALTER TABLE booking.price_list_versions DROP CONSTRAINT IF EXISTS price_list_versions_approved_chk;
ALTER TABLE booking.price_list_versions ADD CONSTRAINT price_list_versions_approved_chk CHECK (
    (approved_by IS NULL) = (approved_at IS NULL)
    AND (approved_by IS NULL OR approved_by <> created_by OR owner_self_approved)
    AND (status IN ('published', 'superseded')) <= (approved_at IS NOT NULL)
    AND (approved_at IS NULL OR status IN ('published', 'superseded', 'withdrawn')));
ALTER TABLE booking.price_list_versions DROP CONSTRAINT IF EXISTS price_list_versions_owner_self_chk;
ALTER TABLE booking.price_list_versions ADD CONSTRAINT price_list_versions_owner_self_chk CHECK (
    owner_self_approved = (approved_by IS NOT NULL AND approved_by = created_by));

CREATE OR REPLACE TRIGGER price_list_versions_owner_self_approval
    BEFORE INSERT OR UPDATE ON booking.price_list_versions
    FOR EACH ROW EXECUTE FUNCTION booking.owner_self_approval_guard('approved_by', 'owner_self_approved', 'final');

-- ── 6. Season ranges (kind season only) and holiday events ──────────────────────────────────────────────────────

ALTER TABLE booking.season_ranges ADD COLUMN IF NOT EXISTS owner_self_approved boolean NOT NULL DEFAULT false;
GRANT UPDATE (owner_self_approved) ON booking.season_ranges TO booking;
COMMENT ON COLUMN booking.season_ranges.owner_self_approved IS
    'bk-064 (AA-1158 Q5): the business owner approved a season range she proposed (kind season only; a stop-sale and '
    'every end keep two people). Checked against the CIS marker. Final.';

ALTER TABLE booking.season_ranges DROP CONSTRAINT IF EXISTS season_ranges_status_chk;
ALTER TABLE booking.season_ranges ADD CONSTRAINT season_ranges_status_chk CHECK (
    status IN ('pending', 'approved', 'rejected', 'withdrawn')
    AND (status = 'pending') = (decided_by IS NULL)
    AND (decided_by IS NULL) = (decided_at IS NULL)
    AND (status NOT IN ('approved', 'rejected') OR decided_by <> created_by
         OR (owner_self_approved AND status = 'approved' AND kind = 'season'))
    AND (status <> 'withdrawn' OR decided_by = created_by)
    AND (status = 'rejected') = (reject_reason IS NOT NULL)
    AND (status = 'withdrawn') = (withdraw_reason IS NOT NULL));
ALTER TABLE booking.season_ranges DROP CONSTRAINT IF EXISTS season_ranges_owner_self_chk;
ALTER TABLE booking.season_ranges ADD CONSTRAINT season_ranges_owner_self_chk CHECK (
    owner_self_approved = (status = 'approved' AND kind = 'season' AND decided_by = created_by));

CREATE OR REPLACE TRIGGER season_ranges_owner_self_approval
    BEFORE INSERT OR UPDATE ON booking.season_ranges
    FOR EACH ROW EXECUTE FUNCTION booking.owner_self_approval_guard('decided_by', 'owner_self_approved', 'final');

ALTER TABLE booking.holiday_events ADD COLUMN IF NOT EXISTS owner_self_approved boolean NOT NULL DEFAULT false;
GRANT UPDATE (owner_self_approved) ON booking.holiday_events TO booking;
COMMENT ON COLUMN booking.holiday_events.owner_self_approved IS
    'bk-064 (AA-1158 Q5): the business owner approved a holiday event she proposed (its end keeps two people). '
    'Checked against the CIS marker. Final.';

ALTER TABLE booking.holiday_events DROP CONSTRAINT IF EXISTS holiday_events_status_chk;
ALTER TABLE booking.holiday_events ADD CONSTRAINT holiday_events_status_chk CHECK (
    status IN ('pending', 'approved', 'rejected', 'withdrawn')
    AND (status = 'pending') = (decided_by IS NULL)
    AND (decided_by IS NULL) = (decided_at IS NULL)
    AND (status NOT IN ('approved', 'rejected') OR decided_by <> created_by
         OR (owner_self_approved AND status = 'approved'))
    AND (status <> 'withdrawn' OR decided_by = created_by)
    AND (status = 'rejected') = (reject_reason IS NOT NULL)
    AND (status = 'withdrawn') = (withdraw_reason IS NOT NULL));
ALTER TABLE booking.holiday_events DROP CONSTRAINT IF EXISTS holiday_events_owner_self_chk;
ALTER TABLE booking.holiday_events ADD CONSTRAINT holiday_events_owner_self_chk CHECK (
    owner_self_approved = (status = 'approved' AND decided_by = created_by));

CREATE OR REPLACE TRIGGER holiday_events_owner_self_approval
    BEFORE INSERT OR UPDATE ON booking.holiday_events
    FOR EACH ROW EXECUTE FUNCTION booking.owner_self_approval_guard('decided_by', 'owner_self_approved', 'final');

-- ── 7. Agency payments and departure price adjustments ──────────────────────────────────────────────────────────

ALTER TABLE booking.agency_payment ADD COLUMN IF NOT EXISTS owner_self_approved boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN booking.agency_payment.owner_self_approved IS
    'bk-064 (AA-1158 Q5): the business owner approved a payment she recorded (checked against the CIS marker; a '
    'rejection keeps two people). Final.';

ALTER TABLE booking.agency_payment DROP CONSTRAINT IF EXISTS agency_payment_maker_checker_chk;
ALTER TABLE booking.agency_payment ADD CONSTRAINT agency_payment_maker_checker_chk CHECK (
    (approved_by IS NULL OR approved_by <> recorded_by OR owner_self_approved)
    AND (rejected_by IS NULL OR rejected_by <> recorded_by));
ALTER TABLE booking.agency_payment DROP CONSTRAINT IF EXISTS agency_payment_owner_self_chk;
ALTER TABLE booking.agency_payment ADD CONSTRAINT agency_payment_owner_self_chk CHECK (
    owner_self_approved = (approved_by IS NOT NULL AND approved_by = recorded_by));

CREATE OR REPLACE TRIGGER agency_payment_owner_self_approval
    BEFORE INSERT OR UPDATE ON booking.agency_payment
    FOR EACH ROW EXECUTE FUNCTION booking.owner_self_approval_guard('approved_by', 'owner_self_approved', 'final');

ALTER TABLE booking.departure_price_adjustments
    ADD COLUMN IF NOT EXISTS owner_self_approved boolean NOT NULL DEFAULT false;
GRANT UPDATE (owner_self_approved) ON booking.departure_price_adjustments TO booking;
COMMENT ON COLUMN booking.departure_price_adjustments.owner_self_approved IS
    'bk-064 (AA-1158 Q5): the business owner approved a price adjustment she made (checked against the CIS marker). '
    'Final.';

ALTER TABLE booking.departure_price_adjustments DROP CONSTRAINT IF EXISTS departure_price_adjustments_approved_chk;
ALTER TABLE booking.departure_price_adjustments ADD CONSTRAINT departure_price_adjustments_approved_chk CHECK (
    (approved_by IS NULL) = (approved_at IS NULL)
    AND (approved_by IS NULL
         OR ((approved_by <> created_by OR owner_self_approved) AND length(approved_by) BETWEEN 1 AND 128))
    AND (approved_at IS NULL OR approved_at >= created_at));
ALTER TABLE booking.departure_price_adjustments DROP CONSTRAINT IF EXISTS departure_price_adjustments_owner_self_chk;
ALTER TABLE booking.departure_price_adjustments ADD CONSTRAINT departure_price_adjustments_owner_self_chk CHECK (
    owner_self_approved = (approved_by IS NOT NULL AND approved_by = created_by));

CREATE OR REPLACE TRIGGER departure_price_adjustments_owner_self_approval
    BEFORE INSERT OR UPDATE ON booking.departure_price_adjustments
    FOR EACH ROW EXECUTE FUNCTION booking.owner_self_approval_guard('approved_by', 'owner_self_approved', 'final');

-- ── 8. Billing entity: bank details and the default issuer change on approval ───────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.billing_entity_change (
    id                        uuid         NOT NULL DEFAULT gen_random_uuid(),
    billing_entity_id         uuid         NOT NULL,
    set_payment_instructions  boolean      NOT NULL,
    payment_instructions      text,
    make_default              boolean      NOT NULL DEFAULT false,
    reason                    text         NOT NULL,
    status                    text         NOT NULL DEFAULT 'pending',
    requested_by              text         NOT NULL,
    requested_at              timestamptz  NOT NULL DEFAULT now(),
    decided_by                text,
    decided_at                timestamptz,
    reject_reason             text,
    owner_self_approved       boolean      NOT NULL DEFAULT false,
    CONSTRAINT billing_entity_change_pkey PRIMARY KEY (id),
    CONSTRAINT billing_entity_change_entity_fkey FOREIGN KEY (billing_entity_id)
        REFERENCES booking.billing_entity (id) ON DELETE CASCADE,
    CONSTRAINT billing_entity_change_what_chk CHECK (
        (set_payment_instructions OR make_default)
        AND (set_payment_instructions OR payment_instructions IS NULL)
        AND (payment_instructions IS NULL OR char_length(btrim(payment_instructions)) BETWEEN 1 AND 2000)),
    CONSTRAINT billing_entity_change_text_chk CHECK (
        char_length(btrim(reason)) BETWEEN 1 AND 300
        AND char_length(requested_by) BETWEEN 1 AND 128
        AND (decided_by IS NULL OR char_length(decided_by) BETWEEN 1 AND 128)
        AND (reject_reason IS NULL OR char_length(btrim(reject_reason)) BETWEEN 1 AND 300)),
    CONSTRAINT billing_entity_change_status_chk CHECK (
        status IN ('pending', 'approved', 'rejected', 'withdrawn')
        AND (status = 'pending') = (decided_by IS NULL)
        AND (decided_by IS NULL) = (decided_at IS NULL)
        AND (status = 'rejected') = (reject_reason IS NOT NULL)
        AND (status <> 'withdrawn' OR decided_by = requested_by)
        AND (status NOT IN ('approved', 'rejected') OR decided_by <> requested_by
             OR (status = 'approved' AND owner_self_approved))),
    CONSTRAINT billing_entity_change_owner_self_chk CHECK (
        owner_self_approved = (status = 'approved' AND decided_by = requested_by))
);

-- ON DELETE CASCADE: an entity is never deleted by the app (no DELETE grant on billing_entity for role booking); the
-- cascade only follows a fixture or erasure delete of the entity itself.
CREATE UNIQUE INDEX IF NOT EXISTS billing_entity_change_pending_uq
    ON booking.billing_entity_change (billing_entity_id) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS billing_entity_change_entity_idx
    ON booking.billing_entity_change (billing_entity_id, requested_at DESC);

COMMENT ON TABLE booking.billing_entity_change IS
    'bk-064 (AA-1158): a requested change of a billing entity''s payment_instructions (the bank details printed on '
    'agency invoices) and / or making it the default issuer. Pending until a second person with billing_config.approve '
    'decides (or the business owner self-approves, flagged); the approval applies it to the entity in the same '
    'transaction. Decided rows are final.';
COMMENT ON COLUMN booking.billing_entity_change.payment_instructions IS
    'conf:commercial — the requested bank details text (AA''s own account, not personal data); NULL with '
    'set_payment_instructions clears them.';
COMMENT ON COLUMN booking.billing_entity_change.reason IS
    'pii:free_text — why the requester changes the billing entity (staff text, required).';
COMMENT ON COLUMN booking.billing_entity_change.reject_reason IS 'pii:free_text — why the checker rejected the change.';

REVOKE ALL ON booking.billing_entity_change FROM booking;
GRANT SELECT, INSERT ON booking.billing_entity_change TO booking;
GRANT UPDATE (status, decided_by, decided_at, reject_reason, owner_self_approved)
    ON booking.billing_entity_change TO booking;

CREATE OR REPLACE FUNCTION booking.billing_entity_change_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'pending' OR NEW.decided_by IS NOT NULL OR NEW.decided_at IS NOT NULL
           OR NEW.reject_reason IS NOT NULL OR NEW.owner_self_approved THEN
            RAISE EXCEPTION 'a billing entity change starts pending and undecided' USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
    END IF;
    -- Erasure (DM-6.7): the staff reasons may be set to the fixed marker, nothing else in the same update.
    IF (to_jsonb(NEW) - 'reason' - 'reject_reason') = (to_jsonb(OLD) - 'reason' - 'reject_reason')
       AND (NEW.reason, NEW.reject_reason) IS DISTINCT FROM (OLD.reason, OLD.reject_reason)
       AND (NEW.reason IS NOT DISTINCT FROM OLD.reason OR NEW.reason = '[redacted]')
       AND (NEW.reject_reason IS NOT DISTINCT FROM OLD.reject_reason OR NEW.reject_reason = '[redacted]') THEN
        RETURN NEW;
    END IF;
    IF OLD.status <> 'pending' THEN
        RAISE EXCEPTION 'billing entity change % is %; it is final', OLD.id, OLD.status
            USING ERRCODE = 'check_violation';
    END IF;
    IF (NEW.billing_entity_id, NEW.set_payment_instructions, NEW.payment_instructions, NEW.make_default, NEW.reason,
        NEW.requested_by, NEW.requested_at)
       IS DISTINCT FROM
       (OLD.billing_entity_id, OLD.set_payment_instructions, OLD.payment_instructions, OLD.make_default, OLD.reason,
        OLD.requested_by, OLD.requested_at) THEN
        RAISE EXCEPTION 'billing entity change %: what was requested never changes', OLD.id
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.status <> 'pending' AND NEW.decided_at IS DISTINCT FROM now() THEN
        RAISE EXCEPTION 'billing entity change %: a decision is dated now', OLD.id USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.billing_entity_change_guard() IS
    'bk-064 (AA-1158): a change starts pending and undecided; what was requested never changes; only pending -> '
    'approved / rejected / withdrawn, dated now(); decided rows are final; on erasure (DM-6.7) reason and '
    'reject_reason may be set to [redacted], alone.';

GRANT EXECUTE ON FUNCTION booking.billing_entity_change_guard() TO booking;

CREATE OR REPLACE TRIGGER billing_entity_change_guard
    BEFORE INSERT OR UPDATE ON booking.billing_entity_change
    FOR EACH ROW EXECUTE FUNCTION booking.billing_entity_change_guard();

CREATE OR REPLACE TRIGGER billing_entity_change_owner_self_approval
    BEFORE INSERT OR UPDATE ON booking.billing_entity_change
    FOR EACH ROW EXECUTE FUNCTION booking.owner_self_approval_guard('decided_by', 'owner_self_approved', 'final');

-- ── 9. Policy switches (Pricing > Policy, section security, approver group admin) ───────────────────────────────

INSERT INTO booking.pricing_policy (id, param_key, version_no, value, unit, effective_from, reason, created_by)
VALUES
    ('00000000-0000-4000-8000-0000b6400000', 'owner_self_approval_allowed', 1, 'true'::jsonb, NULL, DATE '2026-01-01',
     'Tech lead decision Q5: the business owner may approve her own work, flagged and audited.',
     'seed:bk-064'),
    ('00000000-0000-4000-8000-0000b6400010', 'owner_payout_after_approval_allowed', 1, 'true'::jsonb, NULL,
     DATE '2026-01-01',
     'Tech lead decision Q4: the business owner may record the payout of a bill she approved, flagged.',
     'seed:bk-064')
ON CONFLICT DO NOTHING;

INSERT INTO booking.pricing_policy_events (id, policy_id, maker, event, actor)
SELECT e.id, p.id, p.created_by, 'submitted', p.created_by
FROM (VALUES ('00000000-0000-4000-8000-0000b6400001'::uuid, '00000000-0000-4000-8000-0000b6400000'::uuid),
             ('00000000-0000-4000-8000-0000b6400011'::uuid, '00000000-0000-4000-8000-0000b6400010'::uuid)) AS e (id, pid)
JOIN booking.pricing_policy p ON p.id = e.pid AND p.created_by = 'seed:bk-064'
ON CONFLICT DO NOTHING;

INSERT INTO booking.pricing_policy_events (id, policy_id, maker, event, actor)
SELECT e.id, p.id, p.created_by, 'approved', 'tech lead S285 (Q4, Q5 decisions)'
FROM (VALUES ('00000000-0000-4000-8000-0000b6400002'::uuid, '00000000-0000-4000-8000-0000b6400000'::uuid),
             ('00000000-0000-4000-8000-0000b6400012'::uuid, '00000000-0000-4000-8000-0000b6400010'::uuid)) AS e (id, pid)
JOIN booking.pricing_policy p ON p.id = e.pid AND p.created_by = 'seed:bk-064'
ON CONFLICT DO NOTHING;

-- ── 10. The audit filter ────────────────────────────────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS audit_logs_owner_self_idx
    ON booking.audit_logs (created_at DESC) WHERE (after ->> 'owner_self_approved') = 'true';

-- ── Guards: what this file promises (catalog only; never the CIS view) ──────────────────────────────────────────

DO $$
DECLARE
    missing text;
    n integer;
BEGIN
    SELECT string_agg(want, ', ' ORDER BY want) INTO missing
      FROM unnest(ARRAY[
          'suppliers.suppliers_status_chk', 'suppliers.suppliers_activation_chk', 'suppliers.suppliers_maker_checker_chk',
          'suppliers.suppliers_owner_self_chk',
          'supplier_contracts.supplier_contracts_maker_checker_chk', 'supplier_contracts.supplier_contracts_owner_self_chk',
          'supplier_bills.supplier_bills_maker_checker_chk', 'supplier_bills.supplier_bills_owner_self_chk',
          'price_list_versions.price_list_versions_approved_chk', 'price_list_versions.price_list_versions_owner_self_chk',
          'season_ranges.season_ranges_status_chk', 'season_ranges.season_ranges_owner_self_chk',
          'holiday_events.holiday_events_status_chk', 'holiday_events.holiday_events_owner_self_chk',
          'agency_payment.agency_payment_maker_checker_chk', 'agency_payment.agency_payment_owner_self_chk',
          'departure_price_adjustments.departure_price_adjustments_approved_chk',
          'departure_price_adjustments.departure_price_adjustments_owner_self_chk',
          'billing_entity_change.billing_entity_change_status_chk',
          'billing_entity_change.billing_entity_change_owner_self_chk'
      ]) AS want
     WHERE NOT EXISTS (
         SELECT 1 FROM pg_constraint c
          WHERE c.conrelid = to_regclass('booking.' || split_part(want, '.', 1))
            AND c.conname = split_part(want, '.', 2) AND c.contype = 'c' AND c.convalidated);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'bk-064: missing CHECKs: %', missing;
    END IF;
    SELECT string_agg(want, ', ' ORDER BY want) INTO missing
      FROM unnest(ARRAY[
          'suppliers.suppliers_activation_guard', 'suppliers.suppliers_owner_self_approval', 'suppliers.suppliers_writers',
          'supplier_contracts.supplier_contracts_writers', 'supplier_contracts.supplier_contracts_owner_self_approval',
          'supplier_bills.supplier_bills_owner_self_approval', 'supplier_payouts.supplier_payouts_owner_self_approval',
          'price_list_versions.price_list_versions_owner_self_approval', 'season_ranges.season_ranges_owner_self_approval',
          'holiday_events.holiday_events_owner_self_approval', 'agency_payment.agency_payment_owner_self_approval',
          'departure_price_adjustments.departure_price_adjustments_owner_self_approval',
          'billing_entity_change.billing_entity_change_guard',
          'billing_entity_change.billing_entity_change_owner_self_approval'
      ]) AS want
     WHERE NOT EXISTS (
         SELECT 1 FROM pg_trigger t
          WHERE t.tgrelid = to_regclass('booking.' || split_part(want, '.', 1))
            AND t.tgname = split_part(want, '.', 2) AND NOT t.tgisinternal AND t.tgenabled = 'O');
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'bk-064: missing or disabled triggers: %', missing;
    END IF;
    IF to_regprocedure('booking.owner_self_approval_guard()') IS NULL THEN
        RAISE EXCEPTION 'bk-064: booking.owner_self_approval_guard() is missing';
    END IF;
    -- The application role is bound by the activation guard only while it is not an owner member.
    IF pg_has_role('booking', 'bk_owner', 'USAGE') THEN
        RAISE EXCEPTION 'bk-064: role booking is a member of bk_owner; the guards would not bind it';
    END IF;
    IF has_table_privilege('booking', 'booking.billing_entity_change', 'DELETE')
       OR has_column_privilege('booking', 'booking.billing_entity_change', 'payment_instructions', 'UPDATE')
       OR has_column_privilege('booking', 'booking.billing_entity_change', 'requested_by', 'UPDATE')
       OR NOT has_column_privilege('booking', 'booking.billing_entity_change', 'decided_by', 'UPDATE')
       OR NOT has_column_privilege('booking', 'booking.supplier_bills', 'owner_self_approved', 'UPDATE')
       OR NOT has_column_privilege('booking', 'booking.price_list_versions', 'owner_self_approved', 'UPDATE')
       OR NOT has_column_privilege('booking', 'booking.season_ranges', 'owner_self_approved', 'UPDATE')
       OR NOT has_column_privilege('booking', 'booking.holiday_events', 'owner_self_approved', 'UPDATE')
       OR NOT has_column_privilege('booking', 'booking.departure_price_adjustments', 'owner_self_approved', 'UPDATE')
       OR has_column_privilege('booking', 'booking.supplier_payouts', 'same_approver_payer', 'UPDATE') THEN
        RAISE EXCEPTION 'bk-064: role booking grants differ from this file';
    END IF;
    SELECT count(*) INTO n
      FROM booking.pricing_policy p
      JOIN booking.pricing_policy_events a ON a.policy_id = p.id AND a.event = 'approved'
     WHERE p.created_by = 'seed:bk-064' AND p.version_no = 1;
    IF n <> 2 THEN
        RAISE EXCEPTION 'bk-064: % of the 2 new pricing policy parameters have an approved version 1', n
            USING HINT = 'A key already had a version 1 made by someone else; the seed must not overwrite it.';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-064', now(), 'AA-1158 approval rules (three-person team): suppliers pending + activated_by + writers, contract writers, bill approver pays only flagged (same_approver_payer), owner_self_approved flags checked against the CIS business-owner marker (booking.owner_self_approval_guard), booking.billing_entity_change, policy switches owner_self_approval_allowed / owner_payout_after_approval_allowed')
ON CONFLICT (version) DO NOTHING;

COMMIT;
