-- Migration bk-037: AA-1028 R1 slice 2 — booking.b2b_partners.projected_at, the marker of a row the bk_tenant_pull job
-- projects from the CIS tenant account.
--
-- Owner: AA-Booking (key bk-NNN). AA-CIS-Infra Migration Sync copies it byte for byte to
-- db/migrations/booking/037_b2b_partner_projection.sql; on Dev it is applied as bk_owner (the live owner of schema
-- booking since bk-014) by Infra Migration Apply once every job table is idle (root ADR 0017a), or by a person with DB
-- Migrate apply. Never run it from a laptop.
--
-- Why (root ADR 0019 d1 / d9): booking.b2b_partners becomes a read-only projection of the CIS tenant master, one row
-- for every CIS tenant, written by Booking's own pull job bk_tenant_pull from the CIS contract view
-- catalog.v_tenant_account_v1 (CIS 357). The job cannot use created_by / updated_by to mark its rows (both reference
-- booking.staff_users), and staff must not change the projected fields (agency_name, status, m2m_client_id) of such a
-- row while they keep editing Booking's commercial terms (billing_currency, credit_terms_ref).
--
-- What: ALTER TABLE booking.b2b_partners ADD COLUMN projected_at timestamptz (nullable, no default): set by
-- bk_tenant_pull on every row it creates or changes; NULL = a row staff registered that the pull has not projected yet.
-- Role booking keeps its table-level SELECT, INSERT, UPDATE (the new column is covered). No index (tens of rows).
--
-- Class: contract (ALTER of an existing table, root ADR 0017 d3), so a migration-only PR (MIG-4); the code PR raises
-- readiness to bk-037. Re-runnable (ADD COLUMN IF NOT EXISTS). DM-7.1: no new table (the row's retention is
-- b2b_partners').
-- Undo: ALTER TABLE booking.b2b_partners DROP COLUMN projected_at (a later bk- file, after the code is reverted).

BEGIN;

DO $$
BEGIN
    IF current_user <> 'bk_owner' THEN
        RAISE EXCEPTION 'bk-037: expected to run as bk_owner (live owner of schema booking), running as %', current_user;
    END IF;
    IF to_regclass('booking.b2b_partners') IS NULL THEN
        RAISE EXCEPTION 'bk-037: booking.b2b_partners is missing (bk-019)';
    END IF;
END $$;

ALTER TABLE booking.b2b_partners ADD COLUMN IF NOT EXISTS projected_at timestamptz;
COMMENT ON COLUMN booking.b2b_partners.projected_at IS
    'AA-1028 (bk-037): when bk_tenant_pull last wrote the row from the CIS tenant account (catalog.v_tenant_account_v1); '
    'NULL = never projected. On a projected row agency_name, status and m2m_client_id are read-only for staff.';

DO $$
BEGIN
    IF NOT has_column_privilege('booking', 'booking.b2b_partners', 'projected_at', 'UPDATE') THEN
        RAISE EXCEPTION 'bk-037: role booking cannot write booking.b2b_partners.projected_at';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-037', now(), 'AA-1028 R1 slice 2: booking.b2b_partners.projected_at (bk_tenant_pull projection marker)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
