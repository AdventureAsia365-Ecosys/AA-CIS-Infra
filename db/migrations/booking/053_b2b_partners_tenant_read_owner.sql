-- Migration bk-053: AA-1092 (S278 pre-PII review, residual item: bind the caller's tenant in the B2B API) — the tenant
-- policy of booking.b2b_partners also covers bk_owner, so a view owned by bk_owner reads the bound tenant's row.
--
-- Owner: AA-Booking (key bk-NNN). AA-CIS-Infra Migration Sync copies it byte for byte to
-- db/migrations/booking/053_b2b_partners_tenant_read_owner.sql; on Dev it is applied as bk_owner (the live owner of
-- schema booking since bk-014) by Infra Migration Apply once every job table is idle (root ADR 0017a), or by a person
-- with DB Migrate apply. Never run it from a laptop.
--
-- Why: bk-049 gave booking.b2b_partners two permissive policies: b2b_partners_back_office (ALL TO booking, bk_owner,
-- only while no tenant is bound) and b2b_partners_tenant (SELECT TO booking, the bound tenant's row). The AA-Booking
-- code PR of this residual item binds app.tenant_id on every connection a B2B API request takes. A view is read with
-- the privileges AND the row level security of its owner: booking.v_tenant_billing_status (bk-042, owner bk_owner)
-- reads b2b_partners, and under a bound session bk_owner matched neither policy (back office needs no tenant bound, the
-- tenant policy named only booking), so the view answered no row for the caller. The B2B hold path reads that view for
-- the credit stop (a past-due agency's holds are paused) and GET /billing-status and GET /terms read it too: without
-- this file the binding would silently turn the credit stop off. Adding bk_owner to b2b_partners_tenant makes a view
-- owned by bk_owner see exactly the bound tenant's row, the same fence as for role booking.
--
-- What: ALTER POLICY b2b_partners_tenant ... TO booking, bk_owner (SELECT, the same USING: tenant_id = the bound
-- app.tenant_id). Nothing else changes: with no tenant bound (the staff admin, the jobs, the migrations) bk_owner and
-- booking still match b2b_partners_back_office only and see every row; a bound session still writes nothing.
-- Other bk_owner views on the table: booking.v_ops_data_totals (staff only, never read with a tenant bound).
--
-- Class: contract (root ADR 0017 d3): it changes a policy of an existing table. MIG-4: this migration-only PR, then the
-- AA-Booking code PR that binds the tenant and raises readiness to bk-053. On Dev: Infra Migration Apply once every job
-- table is idle (root ADR 0017a).
--
-- Locks: ALTER POLICY takes ACCESS EXCLUSIVE on b2b_partners for an instant (a few rows, no rewrite). lock_timeout 5s.
-- Key guard: refuses to run when shared.schema_versions already holds bk-053 with another description.
-- Re-runnable (the integration tests replay every file): ALTER POLICY ... TO sets the same role list again.
-- Undo (a later bk- file, after the code PR is reverted): ALTER POLICY b2b_partners_tenant ON booking.b2b_partners
-- TO booking.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF current_user <> 'bk_owner' THEN
        RAISE EXCEPTION 'bk-053: expected to run as bk_owner (live owner of schema booking), running as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policy
                    WHERE polrelid = 'booking.b2b_partners'::regclass AND polname = 'b2b_partners_tenant') THEN
        RAISE EXCEPTION 'bk-053: needs bk-049 (policy b2b_partners_tenant on booking.b2b_partners) first';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.schema_versions
                WHERE version = 'bk-053' AND description NOT LIKE 'AA-1092 b2b_partners tenant policy%') THEN
        RAISE EXCEPTION 'bk-053: the key bk-053 is already held by another migration (not AA-1092): renumber one';
    END IF;
END $$;

ALTER POLICY b2b_partners_tenant ON booking.b2b_partners TO booking, bk_owner;

COMMENT ON POLICY b2b_partners_tenant ON booking.b2b_partners IS
    'bk-049 / bk-053 (AA-1092): a session that binds app.tenant_id (the B2B API, app/b2b/access.py) reads that tenant''s row only and writes none; bk_owner too, so a view it owns (v_tenant_billing_status) answers the bound tenant''s row.';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_policy
                    WHERE polrelid = 'booking.b2b_partners'::regclass AND polname = 'b2b_partners_tenant'
                      AND polcmd = 'r'
                      AND polroles @> ARRAY['booking'::regrole::oid, 'bk_owner'::regrole::oid]
                      AND cardinality(polroles) = 2) THEN
        RAISE EXCEPTION 'bk-053: b2b_partners_tenant is not SELECT TO booking, bk_owner';
    END IF;
    IF NOT (SELECT relrowsecurity AND relforcerowsecurity FROM pg_class WHERE oid = 'booking.b2b_partners'::regclass) THEN
        RAISE EXCEPTION 'bk-053: row level security is not enabled and forced on booking.b2b_partners';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-053', now(), 'AA-1092 b2b_partners tenant policy: b2b_partners_tenant SELECT TO booking, bk_owner (a bk_owner view reads the bound tenant''s row)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
