-- Migration bk-071: AA-1158 part 2 follow-up (S289, tech lead decision 24/11/2026) — who approves a supplier bank
-- account change: the business owner, with the tech lead as the fallback approver.
--
-- Owner: AA-Booking (key bk-NNN). AA-CIS-Infra Migration Sync copies it byte for byte to
-- db/migrations/booking/071_supplier_bank_approver.sql and Migration Apply applies it on Dev as bk_owner once every
-- job table is idle (root ADR 0017a). Never run it from a laptop.
--
-- Depends on bk-064 (booking.owner_self_approval_guard, the CIS contract view shared.v_staff_booking_grant read as role
-- booking) and bk-067 (booking.supplier_bank_account).
--
-- Why: bk-067 lets any holder of supplier_bank.approve (every administrator) approve another person's bank account
-- entry after a call-back. A bank account change is the main payout fraud path, so the tech lead decided (S289) that
-- only the business owner approves it, with the tech lead as the fallback when she cannot. The API refuses anyone else
-- (403 bank_approver_not_allowed); this file is the database backstop, so a forged approver never passes either.
--
-- What:
--   1. booking.supplier_bank_account_approver_guard() + trigger supplier_bank_account_approver_guard (BEFORE INSERT
--      OR UPDATE): when approved_by is set or changes to another person than the one who entered the row, it must be
--      an active booking.staff_users row whose cognito_sub carries is_business_owner (the business owner) or
--      is_owner (the platform owner: the tech lead) in shared.v_staff_booking_grant (CIS 462), and whose e-mail is not
--      a Dev-only E2E address (@e2e-mail.lumiguides.it.com: the E2E owner of root ADR 0006a A10h holds is_owner but
--      is never the checker of a money change). Else check_violation. An approval by the person who entered the row
--      is left to the bk-067 CHECKs and the bk-064 owner trigger (only the business owner, flagged). Checked when set,
--      like the owner trigger: an approval that does not change keeps passing after a marker moves (superseding,
--      redaction and the owner's fixtures that age a row never touch approved_by). It binds every role, bk_owner
--      included. SECURITY INVOKER: role booking reads the view and staff_users; an unreadable view refuses the
--      approval (fail closed).
--
-- Class: contract (root ADR 0017 d3: a new trigger on an existing table). Migration-only PR first (MIG-4); the code PR
-- raises readiness to bk-071. The running code already approves only as a holder of supplier_bank.approve; with this
-- file an approval by an administrator who is neither the business owner nor the tech lead is refused by the
-- database (the API answers 403 maker_checker for a check violation) until the code PR answers 403
-- bank_approver_not_allowed before the write.
-- DM-6.1: no new column. DM-7.1: no new table.
-- Locks: SHARE ROW EXCLUSIVE on booking.supplier_bank_account (CREATE TRIGGER, a handful of rows); lock_timeout 5s.
-- Re-runnable (the Integration Tests replay every file): CREATE OR REPLACE FUNCTION / TRIGGER, ON CONFLICT DO NOTHING.
-- Number: owner main max + 1 (bk-070 on main). If it moves, renumber: file name, this header, the registration and the
-- tests that name it (git grep '071_' and 'bk-071').
-- Undo (a later bk- file, after the code is reverted): DROP TRIGGER supplier_bank_account_approver_guard ON
-- booking.supplier_bank_account and DROP FUNCTION booking.supplier_bank_account_approver_guard().

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF to_regclass('booking.supplier_bank_account') IS NULL
       OR to_regprocedure('booking.owner_self_approval_guard()') IS NULL THEN
        RAISE EXCEPTION 'bk-071: needs bk-064 and bk-067 first';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.schema_versions
                WHERE version = 'bk-071' AND description NOT LIKE 'AA-1158 %') THEN
        RAISE EXCEPTION 'bk-071: the key bk-071 is already held by another migration (not AA-1158): renumber one';
    END IF;
END $$;

CREATE OR REPLACE FUNCTION booking.supplier_bank_account_approver_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    IF NEW.approved_by IS NULL OR NEW.approved_by = NEW.entered_by
       OR (TG_OP = 'UPDATE' AND NEW.approved_by IS NOT DISTINCT FROM OLD.approved_by) THEN
        RETURN NEW;
    END IF;
    IF NOT EXISTS (
        SELECT 1
          FROM booking.staff_users s
          JOIN shared.v_staff_booking_grant g ON g.cognito_sub = s.cognito_sub
         WHERE s.cis_user_id = NEW.approved_by AND s.active
           AND (g.is_business_owner IS TRUE OR g.is_owner IS TRUE)
           AND lower(coalesce(s.email, '')) NOT LIKE '%@e2e-mail.lumiguides.it.com')
    THEN
        RAISE EXCEPTION 'supplier bank account %: % is neither the business owner nor the tech lead (bank_approver)',
            NEW.id, NEW.approved_by USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.supplier_bank_account_approver_guard() IS
    'bk-071 (AA-1158 part 2, tech lead S289): an approval of a supplier bank account by someone other than the person '
    'who entered it needs an active staff user whose cognito_sub carries is_business_owner (the business owner) or '
    'is_owner (the tech lead, the fallback approver) in shared.v_staff_booking_grant, never a Dev-only E2E address. '
    'Checked when approved_by is set or changes; binds every role. Security invoker (role booking reads the view); an '
    'unreadable view refuses the approval.';

GRANT EXECUTE ON FUNCTION booking.supplier_bank_account_approver_guard() TO booking;

CREATE OR REPLACE TRIGGER supplier_bank_account_approver_guard
    BEFORE INSERT OR UPDATE ON booking.supplier_bank_account
    FOR EACH ROW EXECUTE FUNCTION booking.supplier_bank_account_approver_guard();

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger
                    WHERE tgrelid = 'booking.supplier_bank_account'::regclass
                      AND tgname = 'supplier_bank_account_approver_guard' AND NOT tgisinternal) THEN
        RAISE EXCEPTION 'bk-071: the approver trigger is missing on booking.supplier_bank_account';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-071', now(), 'AA-1158 part 2 follow-up: a supplier bank account change is approved only by the business owner or the tech lead (fallback), never a Dev-only E2E identity (trigger supplier_bank_account_approver_guard)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
