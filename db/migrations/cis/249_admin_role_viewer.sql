-- Migration 249: AA-878 — read-only 'viewer' staff role in shared.admin_role.
--
-- Why. The UI-smoke account that runs on every PR preview (GitHub E2E_ADMIN_* secrets) is a full admin
-- today, and every existing CIS role (admin / reviewer / content) holds content.write + review.act
-- (api/core/staff_authz.py ROLE_PERMS), so none of them is read-only. AA-878 needs an account that gets
-- 403 on a write. The role 'viewer' holds content.read only: it reads the content pages, is refused on
-- every write (backend staff_policy + the BFF) and on every admin-only read, gets no Booking token
-- (POST /auth/booking-token answers 403), and can not be assigned from the Staff page (the directory's
-- CIS_ROLES stay admin / reviewer / content). There is no Cognito group for it (cis-viewer is deferred
-- to AA-816 E1); the E2E account is a legacy password row.
--
-- What.
--   1. ALTER TYPE shared.admin_role ADD VALUE IF NOT EXISTS 'viewer' (after 'content').
--      ADD VALUE inside a transaction block is allowed on Postgres 12+ (Dev runs 15); the new value can
--      not be USED before this transaction commits (55P04 "unsafe use of new value"), so nothing in this
--      file uses it: no cast, no default, no row. The account row is created after apply by the main
--      session (scripts/create_staff_user.py --password-from-secret aa-cis/dev/e2e-test-viewer), never by
--      a migration (no password hash in git).
--   2. Register 249.
--
-- Guard 0 (RAISE, nothing changes): shared.admin_role exists (migration 074) and the runner owns it or is a
-- member of its owner (ALTER TYPE needs the type owner; after X1 245 DB Migrate runs cis/ files as
-- cis_owner, and 245 must transfer this type with the others).
--
-- Locks. ALTER TYPE … ADD VALUE takes a lock on the type only; readers of shared.admin_users are not
-- blocked. lock_timeout 5s. Not destructive (no `migrate:` directive). Re-running is a no-op (IF NOT EXISTS,
-- ON CONFLICT DO NOTHING).
--
-- X1. One BEGIN … COMMIT block, no role switch (role lint from 243, AA-CIS-Infra db/owners.yaml). No catalog.*
-- view is touched. 248 is AA-884 (audit append-only); 249 may apply before or after it (the runner keys
-- "applied" on the version only), the two touch different objects.
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/ (DB Migrate workflow); keep
-- the two byte-identical. After apply: regenerate docs/architecture/db-schema-reference.md (DB Schema Dump
-- workflow); expect `shared.admin_role`: 'admin', 'reviewer', 'content', 'viewer'.
--
-- Rollback. Postgres can not drop an enum value. While no row uses it, the value is harmless: the code
-- before this change does not know 'viewer' (verify-admin answers 401 for it). To remove it for real:
-- delete or re-role every 'viewer' row, then recreate the type (CREATE TYPE shared.admin_role_new AS ENUM
-- ('admin','reviewer','content'); ALTER TABLE shared.admin_users ALTER COLUMN role DROP DEFAULT, ALTER
-- COLUMN role TYPE shared.admin_role_new USING role::text::shared.admin_role_new, ALTER COLUMN role SET
-- DEFAULT 'reviewer'; DROP TYPE shared.admin_role; ALTER TYPE shared.admin_role_new RENAME TO admin_role),
-- then DELETE FROM shared.schema_versions WHERE version = '249'. That is a separate, reviewed migration.
BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Guard 0: the type exists and the runner may alter it ─────────────────────────────────────────
DO $$
DECLARE
    owner_name text;
BEGIN
    IF to_regtype('shared.admin_role') IS NULL THEN
        RAISE EXCEPTION 'migration 249: type shared.admin_role does not exist (migration 074)';
    END IF;
    SELECT pg_catalog.pg_get_userbyid(t.typowner) INTO owner_name
      FROM pg_catalog.pg_type t WHERE t.oid = 'shared.admin_role'::regtype;
    IF NOT pg_catalog.pg_has_role(current_user, owner_name, 'MEMBER') THEN
        RAISE EXCEPTION 'migration 249: shared.admin_role is owned by %, not by the runner % (ALTER TYPE needs the owner)',
            owner_name, current_user;
    END IF;
END $$;

-- ── 1. The read-only role ────────────────────────────────────────────────────────────────────────
ALTER TYPE shared.admin_role ADD VALUE IF NOT EXISTS 'viewer';

-- ── 2. Register ──────────────────────────────────────────────────────────────────────────────────
INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('249', now(), 'AA-878: shared.admin_role gains viewer (read-only staff role for the E2E account)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
