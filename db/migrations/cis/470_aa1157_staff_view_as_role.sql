-- Migration 470: AA-1157 (S288) — shared.staff_view_as_session also logs a read-only "view as a lower staff role"
-- session (tenant_id NULL, view_role set), next to the "view as tenant" sessions of CIS 364.
--
-- Why. An owner (the tech lead, the business owner) must see what a lower staff role sees without a second account:
-- read-only, at most 60 minutes, logged, never touching the sign-in (root ADR 0019 d5, widened by the AA-1157
-- amendment). CIS 364 made tenant_id NOT NULL, so the log can only name a tenant. This file lets one row name either a
-- tenant (the existing kind) or a staff role, never both, never neither; every existing rule of the log stays (reason
-- 3-500 characters, a window of at most 60 minutes, an end set once, append-only).
--
-- What.
--   1. tenant_id DROP NOT NULL; ADD COLUMN view_role text (the role code viewed: a built-in CIS role or a CIS custom
--      role code; not personal data). The FK to shared.tenants stays (a NULL key is never checked).
--   2. CHECK staff_view_as_session_kind_chk: exactly one of tenant_id / view_role. CHECK
--      staff_view_as_session_view_role_chk: the code's format only (^[a-z][a-z0-9_]{1,62}$); the API checks the code
--      against the built-in roles and the CIS custom roles, so a new role needs no migration.
--   3. CREATE OR REPLACE shared.staff_view_as_session_guard():
--        UPDATE: the immutable tuple gains view_role (an UPDATE still only ends an open session);
--        DELETE: a tenant row only once its tenant is offboarded or deleted (as before: AA-839 erasure, FK cascade);
--          a staff-role row only once it has ended and started more than 24 months ago (the DM-7.1 retention window;
--          no purge job exists yet). Without the explicit NULL branch, shared.tenant_account_closed(NULL) is TRUE
--          (NOT EXISTS over a NULL key), so the 364 body would let any staff-role row be deleted;
--        TRUNCATE: still refused.
--   4. Comments (table, view_role, tenant_id).
--   5. Grants: unchanged (cis_app keeps SELECT, INSERT, UPDATE, DELETE from 364; the guard limits UPDATE / DELETE).
--   6. Register 470.
--
-- Guards (RAISE, nothing changes): 0. before: CIS 364 applied (the table exists), CIS 462 applied (shared.staff_role
-- exists: custom role codes), role cis_app exists. 1. after: both CHECKs exist; a staff-role row passes the CHECK and
-- its DELETE is refused by the guard; a row naming both kinds or neither is refused; an UPDATE of view_role is refused
-- (all inside a savepoint that is rolled back, so the guard writes nothing).
--
-- Class: CONTRACT (root ADR 0017 d3: DROP NOT NULL, a new CHECK and CREATE OR REPLACE FUNCTION). No migrate directive
-- line. MIG-4: a migration-only PR, applied on Dev by Infra Migration Apply once every job table is idle (ADR 0017a),
-- then the code PR (readiness raises to 470; the staff view-as routes write role rows). DM-6.1: view_role is a role
-- code, not personal data. DM-7.1: the table's row in root data standards Part B section 7 says it also holds staff-role
-- sessions (root PR of this change, merged before the Infra copy).
--
-- Number. 469 is the newest CIS migration on main (23/11/2026); 471 / 472 are reserved for other S288 lanes. If the
-- owner main max + 1 differs at merge, renumber (git grep '470_' and "'470'": this file,
-- tests/integration/test_aa1157_migration_470.py, tests/integration/test_aa1035_migrations_362_364.py,
-- api/core/readiness.py and the code PR's tests and notes).
--
-- Behaviour on apply: none for running code. Every existing row has tenant_id set and view_role NULL, so the kind CHECK
-- validates at once; code on main inserts only tenant rows (tenant_id, no view_role), which pass both CHECKs.
--
-- Locks. ALTER TABLE takes ACCESS EXCLUSIVE briefly on a small table (a handful of rows; read by the view-as gate per
-- tenant view-as request). lock_timeout 5s. Re-runnable (DROP NOT NULL and ADD COLUMN IF NOT EXISTS are idempotent,
-- each CHECK is dropped if it exists and added again, CREATE OR REPLACE FUNCTION, ON CONFLICT DO NOTHING).
--
-- Rollback (a new forward migration, after the code is reverted; destructive, DRY RUN first per
-- skill/aa-cis-schema/references/destructive-ops.md): put back the 364 guard body first (this guard refuses the DELETE
-- of a recent staff-role row), then DELETE FROM shared.staff_view_as_session WHERE tenant_id IS NULL; DROP the two
-- CHECKs; ALTER COLUMN tenant_id SET NOT NULL; DROP COLUMN view_role; register the rollback number.
--
-- X1. One BEGIN … COMMIT block, no role switch (the runner is cis_owner, the owner of schema shared).

BEGIN;

SET LOCAL lock_timeout = '5s';

-- ── Guard 0: what this file needs ─────────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF to_regclass('shared.staff_view_as_session') IS NULL THEN
        RAISE EXCEPTION 'migration 470: shared.staff_view_as_session does not exist (migration 364)';
    END IF;
    IF to_regclass('shared.staff_role') IS NULL THEN
        RAISE EXCEPTION 'migration 470: shared.staff_role does not exist (migration 462)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'cis_app') THEN
        RAISE EXCEPTION 'migration 470: role cis_app does not exist';
    END IF;
END $$;

-- ── 1. Columns ─────────────────────────────────────────────────────────────────────────────────────────────────────
ALTER TABLE shared.staff_view_as_session ALTER COLUMN tenant_id DROP NOT NULL;
ALTER TABLE shared.staff_view_as_session ADD COLUMN IF NOT EXISTS view_role text;

-- ── 2. Checks: exactly one kind; the role code's format ───────────────────────────────────────────────────────────
ALTER TABLE shared.staff_view_as_session DROP CONSTRAINT IF EXISTS staff_view_as_session_kind_chk;
ALTER TABLE shared.staff_view_as_session ADD CONSTRAINT staff_view_as_session_kind_chk
    CHECK ((tenant_id IS NULL) <> (view_role IS NULL));
ALTER TABLE shared.staff_view_as_session DROP CONSTRAINT IF EXISTS staff_view_as_session_view_role_chk;
ALTER TABLE shared.staff_view_as_session ADD CONSTRAINT staff_view_as_session_view_role_chk
    CHECK (view_role IS NULL OR view_role ~ '^[a-z][a-z0-9_]{1,62}$');

-- ── 3. Guard: append-only for both kinds ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION shared.staff_view_as_session_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, shared
AS $$
BEGIN
    IF TG_OP = 'TRUNCATE' THEN
        RAISE EXCEPTION 'shared.staff_view_as_session is append-only: TRUNCATE refused'
            USING ERRCODE = 'restrict_violation';
    ELSIF TG_OP = 'UPDATE' THEN
        IF OLD.ended_at IS NOT NULL OR NEW.ended_at IS NULL
           OR (NEW.session_id, NEW.admin_user_id, NEW.tenant_id, NEW.view_role, NEW.reason, NEW.ticket_ref,
               NEW.started_at, NEW.expires_at)
              IS DISTINCT FROM
              (OLD.session_id, OLD.admin_user_id, OLD.tenant_id, OLD.view_role, OLD.reason, OLD.ticket_ref,
               OLD.started_at, OLD.expires_at) THEN
            RAISE EXCEPTION 'shared.staff_view_as_session: an UPDATE only ends an open session'
                USING ERRCODE = 'restrict_violation';
        END IF;
        RETURN NEW;
    END IF;
    -- DELETE. A staff-role row (tenant_id NULL): only an ended one past the DM-7.1 window of 24 months.
    IF OLD.tenant_id IS NULL THEN
        IF OLD.ended_at IS NULL OR OLD.started_at >= now() - interval '24 months' THEN
            RAISE EXCEPTION 'shared.staff_view_as_session: a staff-role session is kept for 24 months'
                USING ERRCODE = 'restrict_violation';
        END IF;
        RETURN OLD;
    END IF;
    -- A tenant row: only the rows of an offboarded or deleted tenant (AA-839 erasure, FK cascade; DM-7.1 row).
    IF NOT coalesce(shared.tenant_account_closed(OLD.tenant_id), false) THEN
        RAISE EXCEPTION 'shared.staff_view_as_session: a session of a live tenant is never deleted'
            USING ERRCODE = 'restrict_violation';
    END IF;
    RETURN OLD;
END
$$;
REVOKE ALL ON FUNCTION shared.staff_view_as_session_guard() FROM PUBLIC;

-- ── 4. Comments ────────────────────────────────────────────────────────────────────────────────────────────────────
COMMENT ON TABLE shared.staff_view_as_session IS
    'AA-1035 (CIS 364, root ADR 0019 d5) + AA-1157 (CIS 470): one row per read-only view-as session of an AA staff '
    'member: who, what was viewed (a tenant: tenant_id; or a lower staff role: view_role; exactly one), the reason or '
    'ticket, start, expiry (at most 60 minutes) and end. Append-only (guard trigger): an UPDATE only ends an open '
    'session; a DELETE only removes the rows of an offboarded or deleted tenant (AA-839 erasure, FK cascade) or an '
    'ended staff-role row older than 24 months (DM-7.1).';
COMMENT ON COLUMN shared.staff_view_as_session.tenant_id IS
    'AA-1035 (364): the tenant viewed. AA-1157 (470): NULL for a staff-role session (view_role set instead).';
COMMENT ON COLUMN shared.staff_view_as_session.view_role IS
    'AA-1157 (470): the staff role viewed (a built-in CIS role or a CIS custom role code); NULL for a tenant session. '
    'A role code, not personal data.';

-- ── Guard 1: the table as this file leaves it ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_staff uuid;
    v_session uuid;
BEGIN
    IF (SELECT count(*) FROM pg_catalog.pg_constraint
         WHERE conrelid = 'shared.staff_view_as_session'::regclass
           AND conname IN ('staff_view_as_session_kind_chk', 'staff_view_as_session_view_role_chk')) <> 2 THEN
        RAISE EXCEPTION 'migration 470: the kind / view_role CHECKs are missing';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_attribute
                WHERE attrelid = 'shared.staff_view_as_session'::regclass AND attname = 'tenant_id' AND attnotnull) THEN
        RAISE EXCEPTION 'migration 470: tenant_id is still NOT NULL';
    END IF;
    SELECT id INTO v_staff FROM shared.admin_users ORDER BY created_at NULLS LAST LIMIT 1;
    IF v_staff IS NULL THEN
        RETURN;   -- an empty directory (a fresh test database): the behaviour checks need a staff row
    END IF;
    BEGIN
        INSERT INTO shared.staff_view_as_session (admin_user_id, view_role, reason, expires_at)
        VALUES (v_staff, 'content', 'migration 470 guard check', now() + interval '5 minutes')
        RETURNING session_id INTO v_session;
        BEGIN
            DELETE FROM shared.staff_view_as_session WHERE session_id = v_session;
            RAISE EXCEPTION 'migration 470: the guard let a staff-role row be deleted' USING ERRCODE = 'P0470';
        EXCEPTION WHEN restrict_violation THEN NULL;
        END;
        BEGIN
            UPDATE shared.staff_view_as_session SET view_role = 'admin', ended_at = now(), end_reason = 'ended'
             WHERE session_id = v_session;
            RAISE EXCEPTION 'migration 470: the guard let view_role change' USING ERRCODE = 'P0470';
        EXCEPTION WHEN restrict_violation THEN NULL;
        END;
        BEGIN
            INSERT INTO shared.staff_view_as_session (admin_user_id, reason, expires_at)
            VALUES (v_staff, 'migration 470 guard check', now() + interval '5 minutes');
            RAISE EXCEPTION 'migration 470: a row naming neither a tenant nor a role passed' USING ERRCODE = 'P0470';
        EXCEPTION WHEN check_violation THEN NULL;
        END;
        -- Undo the probe row: a savepoint rollback through the outer block's exception handler.
        RAISE EXCEPTION 'migration 470: probe done' USING ERRCODE = 'P0471';
    EXCEPTION WHEN SQLSTATE 'P0471' THEN NULL;
    END;
END $$;

-- ── 6. Register ────────────────────────────────────────────────────────────────────────────────────────────────────
INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('470', now(), 'AA-1157: shared.staff_view_as_session also logs view-as-a-staff-role sessions (tenant_id NULL + view_role, guard updated)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
