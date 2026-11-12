-- Migration bk-049: AA-1092 (S278 system audit M24, pre-PII hardening) — row level security on booking.b2b_partners.
--
-- Owner: AA-Booking (key bk-NNN). AA-CIS-Infra Migration Sync copies it byte for byte to
-- db/migrations/booking/049_b2b_partners_rls.sql; on Dev it is applied as bk_owner (the live owner of schema booking
-- since bk-014) by Infra Migration Apply once every job table is idle (root ADR 0017a), or by a person with DB Migrate
-- apply. Never run it from a laptop.
--
-- What: booking.b2b_partners has a tenant_id column (the agency's CIS tenant) and was the one table of the RLS catalogue
-- guard (rule a) with RLS off. ENABLE + FORCE it, with two permissive policies that read app.tenant_id:
--   b2b_partners_back_office  ALL TO booking, bk_owner: every row while no tenant is bound (app.tenant_id unset or
--                             empty). Every reader today is AA's own back office: the staff admin (partner list, tiers,
--                             billing, departure board, desk bookings), the jobs (bk_tenant_pull, settlement drafts,
--                             reminders, retention) and the B2B API's partner lookup (app/b2b/access.py, by the
--                             tenant id the M2M client is bound to); none binds a tenant, so nothing changes for them.
--                             Writes are allowed only here (WITH CHECK the same condition).
--   b2b_partners_tenant       SELECT TO booking: a transaction that binds a tenant (SELECT set_config('app.tenant_id',
--                             <uuid>, true)) sees that tenant's row only and writes none. This is the database-side
--                             fence for a partner-facing path that binds its caller's tenant.
-- Readers checked (S278, AA-1092): only role `booking` holds a grant (db-schema-reference.md); bk_owner owns it and
-- runs the migrations (data files included); aa_cis_admin / db_migrator reach the policies through their bk_owner
-- membership. No other owner's role reads it (cross-schema FKs into it are booking's own; RI checks bypass RLS).
--
-- Class: contract (root ADR 0017 d3): it ALTERs an existing table and adds policies to it. A migration-only PR; no
-- code PR is needed (no code reads a new shape, and an unbound back-office transaction sees what it saw before). On
-- Dev: Infra Migration Apply once every job table is idle (root ADR 0017a).
--
-- Locks: ACCESS EXCLUSIVE on b2b_partners for the ALTER TABLE ... ROW LEVEL SECURITY statements (a few rows, no
-- rewrite). lock_timeout 5s.
-- Key guard: refuses to run when shared.schema_versions already holds bk-049 with another description.
-- Re-runnable (the integration tests replay every file): ENABLE / FORCE are idempotent, DROP POLICY IF EXISTS before
-- each CREATE POLICY.
-- Undo (a later bk- file): DROP POLICY b2b_partners_tenant, b2b_partners_back_office; ALTER TABLE booking.b2b_partners
-- NO FORCE ROW LEVEL SECURITY, DISABLE ROW LEVEL SECURITY.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF current_user <> 'bk_owner' THEN
        RAISE EXCEPTION 'bk-049: expected to run as bk_owner (live owner of schema booking), running as %', current_user;
    END IF;
    IF to_regclass('booking.b2b_partners') IS NULL THEN
        RAISE EXCEPTION 'bk-049: needs bk-019 (booking.b2b_partners) first';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.schema_versions
                WHERE version = 'bk-049' AND description NOT LIKE 'AA-1092 b2b_partners RLS:%') THEN
        RAISE EXCEPTION 'bk-049: the key bk-049 is already held by another migration (not AA-1092): renumber one';
    END IF;
END $$;

ALTER TABLE booking.b2b_partners ENABLE ROW LEVEL SECURITY;
ALTER TABLE booking.b2b_partners FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS b2b_partners_back_office ON booking.b2b_partners;
CREATE POLICY b2b_partners_back_office ON booking.b2b_partners
    AS PERMISSIVE FOR ALL TO booking, bk_owner
    USING (NULLIF(current_setting('app.tenant_id', true), '') IS NULL)
    WITH CHECK (NULLIF(current_setting('app.tenant_id', true), '') IS NULL);

DROP POLICY IF EXISTS b2b_partners_tenant ON booking.b2b_partners;
CREATE POLICY b2b_partners_tenant ON booking.b2b_partners
    AS PERMISSIVE FOR SELECT TO booking
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);

COMMENT ON POLICY b2b_partners_back_office ON booking.b2b_partners IS
    'bk-049 (AA-1092): AA back office (staff admin, jobs, the B2B partner lookup) with no tenant bound: every row, read and write.';
COMMENT ON POLICY b2b_partners_tenant ON booking.b2b_partners IS
    'bk-049 (AA-1092): a transaction that binds app.tenant_id reads that tenant''s row only and writes none.';

DO $$
BEGIN
    IF NOT (SELECT relrowsecurity AND relforcerowsecurity FROM pg_class WHERE oid = 'booking.b2b_partners'::regclass) THEN
        RAISE EXCEPTION 'bk-049: row level security is not enabled and forced on booking.b2b_partners';
    END IF;
    IF has_table_privilege('booking', 'booking.b2b_partners', 'DELETE')
       OR has_table_privilege('cis_app', 'booking.b2b_partners', 'SELECT') THEN
        RAISE EXCEPTION 'bk-049: role booking can delete partners, or cis_app can read them';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-049', now(), 'AA-1092 b2b_partners RLS: ENABLE + FORCE, policies b2b_partners_back_office (no tenant bound: every row, booking + bk_owner) and b2b_partners_tenant (app.tenant_id bound: own row, SELECT only)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
