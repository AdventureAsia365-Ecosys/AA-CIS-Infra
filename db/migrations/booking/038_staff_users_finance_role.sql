-- Migration bk-038: AA-1035 (R2 slice 1, S267) — booking.staff_users.role gains 'finance'.
--
-- Owner: AA-Booking (key bk-NNN). AA-CIS-Infra Migration Sync copies it byte for byte to
-- db/migrations/booking/038_staff_users_finance_role.sql; on Dev it is applied as bk_owner (the live owner of schema
-- booking since bk-014) by Infra Migration Apply once every job table is idle (root ADR 0017a), or by a person with DB
-- Migrate apply. Never run it from a laptop.
--
-- Why (root ADR 0019 d3 / d9, "all invoices in Booking"): Booking gains a finance role, read from the WORKFORCE group
-- booking-finance in cognito:groups (granted by the CIS Staff page through shared.staff_app_grant role 'finance', CIS
-- 363; the group is AA-CIS-Infra identity.tf). Every WORKFORCE sign-in writes the role of its booking-* group to
-- booking.staff_users.role (app/auth/staff.py sync_cognito_staff), and staff_users_role_chk (bk-003) allows only
-- admin / sales / contracting / content_creator, so a finance member's first request would fail on the CHECK.
--
-- What: staff_users_role_chk is replaced (drop + add, same name) by the same list plus 'finance'. A superset: every
-- existing row passes. No row changes. Roles keep their grants.
--
-- Class: contract (a replaced constraint on an existing table, root ADR 0017 d3), so a migration-only PR (MIG-4); the
-- code PR raises readiness to bk-038. Re-runnable (drop + add the same definition, ON CONFLICT DO NOTHING).
-- Locks: ADD CONSTRAINT CHECK scans the handful of staff rows under ACCESS EXCLUSIVE for milliseconds. lock_timeout 5s.
-- DM-7.1: no new table.
-- Undo (a later bk- file, after the code is reverted and no row holds 'finance'): the bk-003 list.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF current_user <> 'bk_owner' THEN
        RAISE EXCEPTION 'bk-038: expected to run as bk_owner (live owner of schema booking), running as %', current_user;
    END IF;
    IF to_regclass('booking.staff_users') IS NULL THEN
        RAISE EXCEPTION 'bk-038: needs bk-003 (booking.staff_users) first';
    END IF;
END $$;

ALTER TABLE booking.staff_users
    DROP CONSTRAINT IF EXISTS staff_users_role_chk,
    ADD CONSTRAINT staff_users_role_chk CHECK (role IN ('admin', 'sales', 'contracting', 'content_creator', 'finance'));

DO $$
DECLARE
    def text;
BEGIN
    SELECT pg_catalog.pg_get_constraintdef(oid) INTO def
      FROM pg_catalog.pg_constraint
     WHERE conrelid = 'booking.staff_users'::regclass AND conname = 'staff_users_role_chk' AND convalidated;
    IF def IS NULL OR position('''finance''' IN def) = 0 OR position('''content_creator''' IN def) = 0 THEN
        RAISE EXCEPTION 'bk-038: staff_users_role_chk is not the expected rule: %', def;
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-038', now(), 'AA-1035: booking.staff_users.role gains finance (WORKFORCE group booking-finance, root ADR 0019 d3 / d9)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
